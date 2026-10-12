import FluidAudio
import Foundation

protocol ParakeetEngine: Sendable {
    /// `language` is not a hint but a script filter (FluidAudio's
    /// `TokenLanguageFilter`): "ru" forbids Latin letters, so English terms
    /// come out in Cyrillic. nil leaves the choice to the model.
    func transcribe(audioPath: String, language: String?) async throws
        -> (segments: [WhisperSegmentDTO], language: String)
}
protocol ParakeetEngineFactory: Sendable { func make(modelFolder: String) async throws -> any ParakeetEngine }
struct LiveParakeetEngineFactory: ParakeetEngineFactory {
    typealias Loader = @Sendable (URL) async throws -> any ParakeetEngine
    private let loader: Loader
    init(loader: @escaping Loader = FluidParakeetEngine.load(from:)) { self.loader = loader }
    func make(modelFolder: String) async throws -> any ParakeetEngine {
        ModelHub.offlineMode = true
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelFolder, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TranscriptionError.engineUnavailable(String(localized: "The Parakeet model is not downloaded: \(modelFolder)"))
        }
        return try await loader(URL(fileURLWithPath: modelFolder, isDirectory: true))
    }
}
actor FluidParakeetEngine: ParakeetEngine {
    private let manager: AsrManager
    private init(manager: AsrManager) { self.manager = manager }
    static func load(from modelFolder: URL) async throws -> any ParakeetEngine {
        let models = try await AsrModels.load(from: modelFolder, version: .v3, encoderPrecision: .int8)
        return FluidParakeetEngine(manager: AsrManager(models: models))
    }
    func transcribe(audioPath: String, language: String?) async throws
        -> (segments: [WhisperSegmentDTO], language: String) {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(URL(fileURLWithPath: audioPath),
                                                  decoderState: &decoderState,
                                                  language: language.flatMap(Language.init(rawValue:)))
        // The model has no token for the Russian letter yo or for angle
        // quotes and writes <unk> in their place; a script filter used to
        // hide it by picking another letter.
        let text = result.text.replacingOccurrences(of: "<unk>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = text.isEmpty ? [] : [WhisperSegmentDTO(text: text, start: 0)]
        return (segments, language ?? "auto")
    }
}
