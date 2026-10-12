import Foundation
import WhisperKit

struct WhisperDecodeRequest: Sendable, Equatable {
    /// nil: the engine detects the language and takes it as is.
    let language: String?
}

extension DictationEngine {
    /// The languages the engine can be told to recognize. Parakeet v3 knows
    /// 25 European languages; FluidAudio's `Language` also lists be, sr and
    /// bs, which this model does not support. Whisper takes WhisperKit's own
    /// list, the codes its tokenizer accepts.
    var languages: Set<String> {
        switch self {
        case .whisper:
            return Constants.languageCodes
        case .parakeet:
            return ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                    "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"]
        }
    }

    /// The language a setting asks this engine for; nil leaves it to the
    /// engine. A code the engine does not know counts as "auto" without
    /// rewriting the setting, so it comes back with the engine it belongs to.
    func language(for setting: String) -> String? {
        languages.contains(setting) ? setting : nil
    }

    /// In the current locale; a code macOS has no name for stays a code.
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// For the pickers, by name. Some locales, Russian among them, write
    /// language names in lower case; a list item starts with a capital.
    var languageChoices: [(code: String, name: String)] {
        languages.map { code in
            let name = Self.languageName(code)
            return (code: code, name: name.prefix(1).uppercased() + name.dropFirst())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension SettingsSnapshot {
    /// The one place the language setting becomes an engine request:
    /// dictation, meetings and the Files tab all start from it.
    var decodeRequest: EngineDecodeRequest {
        let language = dictationEngine.language(for: dictationLanguage)
        switch dictationEngine {
        case .whisper: return .whisper(WhisperDecodeRequest(language: language))
        case .parakeet: return .parakeet(language)
        }
    }
}

struct WhisperSegmentDTO: Sendable, Hashable {
    let text: String
    let start: Double

    // Seeded from hallucinations Whisper produced on long silences in real
    // dictations and common RU/EN YouTube subtitle/outro artifacts. Extend as new
    // exact whole-segment phrases are observed; never match substrings of live speech.
    private static let knownSubtitleHallucinations: Set<String> = [
        "продолжение следует",
        "спасибо за просмотр",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "редактор субтитров",
        "подписывайтесь на канал",
        "спасибо за внимание",
        "thanks for watching",
        "subscribe",
        "thank you for watching",
    ]

    static func removingKnownSubtitleHallucinations(
        from segments: [WhisperSegmentDTO]
    ) -> [WhisperSegmentDTO] {
        segments.filter { segment in
            !knownSubtitleHallucinations.contains(normalizedForHallucinationMatch(segment.text))
        }
    }

    private static func normalizedForHallucinationMatch(_ text: String) -> String {
        var normalized = text
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        while let last = normalized.last,
              last.isWhitespace || last == "." || last == "…" || last == "!" {
            normalized.removeLast()
        }
        return normalized
    }
}

enum EngineDecodeRequest: Sendable, Equatable {
    case whisper(WhisperDecodeRequest)
    /// nil: no script filter, the model decides.
    case parakeet(String?)
}

struct EngineTranscriptDTO: Sendable {
    let segments: [WhisperSegmentDTO]
    let language: String
    let decodeDuration: TimeInterval
}

/// The cache never sees WhisperKit reference types. Implementations must keep
/// third-party values behind their own isolation boundary and return app DTOs.
protocol WhisperEngine: Sendable {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String)
}

protocol WhisperEngineFactory: Sendable {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine
}

struct LiveWhisperEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelFolder, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TranscriptionError.engineUnavailable(String(localized: "The Whisper model is not downloaded: \(modelFolder)"))
        }
        let engine = WhisperKitEngine()
        try await engine.load(modelFolder: modelFolder, prewarm: prewarm)
        return engine
    }
}

/// The tokenizer is a repository of its own; the downloader puts it next to
/// the model. It is checked before WhisperKit sees it: WhisperKit would fetch
/// a missing one from the network into whatever folder it was given.
enum WhisperTokenizerLocator {
    static func folder(for modelFolder: URL, fileManager: FileManager = .default) -> URL? {
        let folder = modelFolder.deletingLastPathComponent()
            .appendingPathComponent(ModelSource.whisperTokenizer.destination, isDirectory: true)
            .standardizedFileURL
        return isCompleteTokenizerFolder(folder, fileManager: fileManager) ? folder : nil
    }

    static func isCompleteTokenizerFolder(
        _ folder: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let requiredFiles = ["config.json", "tokenizer.json"]
        return requiredFiles.allSatisfy {
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent($0).path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }
}

/// Sole owner of the non-Sendable WhisperKit instance. DecodingOptions,
/// TranscriptionResult and every other WhisperKit value are created and consumed
/// inside this actor.
actor WhisperKitEngine: WhisperEngine {
    private var kit: WhisperKit?

    func load(modelFolder: String, prewarm: Bool) async throws {
        let modelURL = URL(fileURLWithPath: modelFolder, isDirectory: true).standardizedFileURL
        guard let tokenizerFolder = WhisperTokenizerLocator.folder(for: modelURL) else {
            throw TranscriptionError.engineUnavailable(
                String(localized: "The Whisper model is only partly downloaded: no tokenizer next to \(modelFolder)")
            )
        }
        AppLog.info("whisper", "using local tokenizer: \(tokenizerFolder.path)")
        kit = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: modelURL.path,
                tokenizerFolder: tokenizerFolder,
                prewarm: prewarm,
                load: true,
                download: false
            )
        )
    }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        guard let kit else {
            throw TranscriptionError.engineUnavailable(String(localized: "The Whisper model is not loaded"))
        }
        // Detected once for the whole request, from its first 30 s, so the
        // text and the language reported for it agree.
        let language: String
        if let asked = request.language {
            language = asked
        } else {
            language = try await kit.detectLanguage(audioPath: audioPath).language
            try Task.checkCancellation()
        }
        // VAD chunking is not cosmetic: with the default strategy WhisperKit
        // hallucinated a [0.02–13.40] segment on a 55 s Russian monologue and then
        // jumped to [32.84], silently dropping the speech in between. Measured on
        // this exact WhisperKit version and model.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )
        let results = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)
        let segments: [WhisperSegmentDTO] = results.flatMap { result in
            result.segments.compactMap { segment -> WhisperSegmentDTO? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return WhisperSegmentDTO(text: text, start: Double(segment.start))
            }
        }
        return (WhisperSegmentDTO.removingKnownSubtitleHallucinations(from: segments), language)
    }
}

enum WhisperModelState: Equatable, Sendable {
    case cold
    case loading
    case ready
    case waiting
}

/// Caches one engine and serializes all loads/decodes through a cancellation-aware
/// FIFO. A path switch evicts the prior engine before the replacement starts, and
/// loadedPath is committed only after a successful factory result.
actor WhisperKitCache {
    static let shared = WhisperKitCache(
        factory: LiveWhisperEngineFactory(),
        parakeetFactory: LiveParakeetEngineFactory()
    )

    private enum ResidentEngine: Sendable {
        case whisper(any WhisperEngine)
        case parakeet(any ParakeetEngine)
    }

    private struct LoadedEngine: Sendable {
        let descriptor: EngineDescriptor
        let engine: ResidentEngine
    }

    private struct Loading: Sendable {
        let descriptor: EngineDescriptor
        let generation: UInt
        let task: Task<ResidentEngine, Error>
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let factory: any WhisperEngineFactory
    private let parakeetFactory: any ParakeetEngineFactory
    private var loaded: LoadedEngine?
    private var loading: Loading?
    private var generation: UInt = 0
    private var busy = false
    private var waiters: [Waiter] = []
    private var activeOperationID: UUID?
    private var desiredDescriptor: EngineDescriptor?
    private var desiredGeneration: UInt = 0

    init(
        factory: any WhisperEngineFactory,
        parakeetFactory: any ParakeetEngineFactory = LiveParakeetEngineFactory()
    ) {
        self.factory = factory
        self.parakeetFactory = parakeetFactory
    }

    func transcribe(
        audioPath: String,
        modelFolder: String,
        request: WhisperDecodeRequest,
        progress: @Sendable @escaping (WhisperModelState) -> Void = { _ in }
    ) async throws -> EngineTranscriptDTO {
        try await transcribe(
            audioPath: audioPath,
            descriptor: EngineDescriptor(engine: .whisper, modelPath: modelFolder),
            request: .whisper(request),
            progress: progress
        )
    }

    func transcribe(
        audioPath: String,
        descriptor: EngineDescriptor,
        request: EngineDecodeRequest,
        progress: @Sendable @escaping (WhisperModelState) -> Void = { _ in }
    ) async throws -> EngineTranscriptDTO {
        try await withEngine(descriptor: descriptor, prewarm: false, progress: progress) { engine in
            let clock = ContinuousClock()
            let started = clock.now
            let decoded: (segments: [WhisperSegmentDTO], language: String)
            switch (engine, request) {
            case let (.whisper(engine), .whisper(request)):
                decoded = try await engine.transcribe(audioPath: audioPath, request: request)
            case let (.parakeet(engine), .parakeet(language)):
                decoded = try await engine.transcribe(audioPath: audioPath, language: language)
            default:
                throw TranscriptionError.engineUnavailable(String(localized: "The request does not match the engine"))
            }
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            return EngineTranscriptDTO(
                segments: decoded.segments,
                language: decoded.language,
                decodeDuration: seconds
            )
        }
    }

    func prepare(
        modelFolder: String,
        progress: @Sendable @escaping (WhisperModelState) -> Void = { _ in }
    ) async throws {
        try await withEngine(
            descriptor: EngineDescriptor(engine: .whisper, modelPath: modelFolder),
            prewarm: true,
            progress: progress
        ) { _ in () }
    }

    func updateDesired(_ descriptor: EngineDescriptor, generation: UInt = 0) {
        guard generation == 0 || generation >= desiredGeneration else { return }
        if generation > 0 { desiredGeneration = generation }
        desiredDescriptor = descriptor
    }

    func prepareDesired(
        progress: @Sendable @escaping (WhisperModelState) -> Void = { _ in }
    ) async throws {
        while let descriptor = desiredDescriptor {
            try await withEngine(descriptor: descriptor, prewarm: true, progress: progress) { _ in () }
            if desiredDescriptor == descriptor { return }
        }
    }

    private func withEngine<Result: Sendable>(
        descriptor: EngineDescriptor,
        prewarm: Bool,
        progress: @Sendable @escaping (WhisperModelState) -> Void,
        operation: @Sendable (ResidentEngine) async throws -> Result
    ) async throws -> Result {
        try await acquire(progress: progress)
        let operationID = UUID()
        activeOperationID = operationID
        defer {
            if activeOperationID == operationID { activeOperationID = nil }
            releaseExclusive()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let engine = try await engine(
                for: descriptor,
                prewarm: prewarm,
                progress: progress
            )
            progress(.ready)
            try Task.checkCancellation()
            return try await operation(engine)
        } onCancel: {
            Task { await self.cancelActiveLoad(ownedBy: operationID) }
        }
    }

    private func cancelActiveLoad(ownedBy operationID: UUID) {
        guard activeOperationID == operationID, loading != nil else { return }
        generation &+= 1
        loading?.task.cancel()
        loading = nil
    }

    private func acquire(
        progress: @Sendable @escaping (WhisperModelState) -> Void
    ) async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }

        let id = UUID()
        progress(.waiting)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Reaching this line means releaseExclusive() already handed us the queue.
        // A cancellation that raced the hand-off must not throw before withEngine
        // installs the defer that releases it; withEngine re-checks cancellation.
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseExclusive() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func engine(
        for descriptor: EngineDescriptor,
        prewarm: Bool,
        progress: @Sendable @escaping (WhisperModelState) -> Void
    ) async throws -> ResidentEngine {
        if let loaded, loaded.descriptor == descriptor {
            return loaded.engine
        }
        if let loading, loading.descriptor == descriptor {
            return try await finish(loading)
        }

        // A different path is a hard cache boundary. The old engine cannot be a
        // fallback if construction of the new one fails.
        generation &+= 1
        let currentGeneration = generation
        if let loaded { AppLog.info("engine", "resident=\(loaded.descriptor.engine.rawValue) released") }
        loaded = nil
        loading?.task.cancel()
        loading = nil

        AppLog.info("engine", "loading engine=\(descriptor.engine.rawValue) path=\(descriptor.modelPath)")
        progress(.loading)
        let factory = self.factory
        let parakeetFactory = self.parakeetFactory
        let task = Task<ResidentEngine, Error> {
            switch descriptor.engine {
            case .whisper:
                return .whisper(try await factory.make(
                    modelFolder: descriptor.modelPath,
                    prewarm: prewarm
                ))
            case .parakeet:
                return .parakeet(try await parakeetFactory.make(
                    modelFolder: descriptor.modelPath
                ))
            }
        }
        let pending = Loading(descriptor: descriptor, generation: currentGeneration, task: task)
        loading = pending
        return try await finish(pending)
    }

    private func finish(_ pending: Loading) async throws -> ResidentEngine {
        do {
            let engine = try await pending.task.value
            guard generation == pending.generation,
                  loading?.generation == pending.generation else {
                throw CancellationError()
            }
            loaded = LoadedEngine(descriptor: pending.descriptor, engine: engine)
            loading = nil
            AppLog.info("engine", "resident=\(pending.descriptor.engine.rawValue) ready")
            return engine
        } catch {
            if loading?.generation == pending.generation {
                loading = nil
            }
            throw error
        }
    }

    /// Prevent an in-flight load from re-populating the cache after a settings
    /// change or explicit memory release.
    func release() {
        generation &+= 1
        loading?.task.cancel()
        loading = nil
        loaded = nil
        AppLog.info("engine", "resident released (evicted)")
    }

    #if DEBUG
    func residentDescriptorForTesting() -> EngineDescriptor? { loaded?.descriptor }
    #endif
}
