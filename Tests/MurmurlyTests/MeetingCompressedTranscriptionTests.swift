import AVFoundation
import FluidAudio
import XCTest
@testable import Murmurly

/// Replies by the median level of the chunk it is given, so the reply proves
/// at what level the audio reached the engine.
private actor GainLevelEngine: WhisperEngine {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return ([], "ru") }
        try file.read(into: buffer)
        let levels = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            .map { abs($0) }.sorted()
        let level = levels.isEmpty ? 0 : levels[levels.count / 2]
        let replies: [Float: String] = [1.6: "громко", 0.3: "тихо", 0.5: "собеседник"]
        let reply = replies.min { abs($0.key - level) < abs($1.key - level) }?.value ?? ""
        return ([WhisperSegmentDTO(text: reply, start: 0)], "ru")
    }
}

private struct GainLevelEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { GainLevelEngine() }
}

private final class SampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tracks: [[Float]] = []
    func append(_ samples: [Float]) { lock.withLock { tracks.append(samples) } }
    func all() -> [[Float]] { lock.withLock { tracks } }
}

/// Recognition of a compressed meeting. Compression scales a track down so its
/// peaks fit 24-bit ALAC and records the gain; the VAD and the engine must get
/// the original level back, since a quieter track is recognized worse. The
/// compressed folder is built by hand with the API M1 already had, so this
/// test also runs on the code before compression existed — and fails there.
@MainActor
final class MeetingCompressedTranscriptionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-gain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompressedMeetingIsHeardAtItsOriginalLevel() async throws {
        let rate = 48_000
        var microphone = [Float](repeating: 0, count: rate * 7)
        for index in rate..<(2 * rate) { microphone[index] = 1.6 }
        for index in (3 * rate)..<(4 * rate) { microphone[index] = 0.3 }
        var system = [Float](repeating: 0, count: rate * 7)
        for index in (5 * rate)..<(6 * rate) { system[index] = 0.5 }
        let gain: Float = 0.5

        let original = root.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try write(microphone, to: original.appendingPathComponent("microphone.caf"))
        try write(system, to: original.appendingPathComponent("system.caf"))

        let compressed = root.appendingPathComponent("compressed", isDirectory: true)
        try FileManager.default.createDirectory(at: compressed, withIntermediateDirectories: true)
        try writeALAC(microphone.map { $0 * gain }, to: compressed.appendingPathComponent("microphone.m4a"))
        try write(system, to: compressed.appendingPathComponent("system.caf"))
        let metadata = """
        {"startedAt":"2026-10-06T10:00:00Z","endedAt":"2026-10-06T10:01:00Z","sampleRate":48000,\
        "state":"done","segments":[{"index":0,"mic":"microphone.m4a","system":"system.caf","micGain":0.5}]}
        """
        try Data(metadata.utf8).write(to: compressed.appendingPathComponent("metadata.json"))

        let heardOriginal = SampleLog()
        let heardCompressed = SampleLog()
        let first = try await transcribe(original, log: heardOriginal)
        let second = try await transcribe(compressed, log: heardCompressed)

        XCTAssertEqual(first.microphone.map(\.text), ["громко", "тихо"])
        XCTAssertEqual(second.microphone.map(\.text), first.microphone.map(\.text), "the engine heard another level")
        XCTAssertEqual(second.lines.map(\.text), first.lines.map(\.text))
        let (originalTracks, compressedTracks) = (heardOriginal.all(), heardCompressed.all())
        XCTAssertEqual(compressedTracks.count, 2)
        XCTAssertEqual(originalTracks.count, 2)
        for (heard, expected) in zip(compressedTracks, originalTracks) {
            XCTAssertEqual(heard.count, expected.count)
            let worst = zip(heard, expected).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertLessThan(worst, 1e-4, "the speech detector heard another level")
        }
    }

    private func transcribe(_ folder: URL, log: SampleLog) async throws -> MeetingTranscriber.Report {
        let detector: MeetingTranscriber.SpeechDetector = { source in
            var samples = [Float](repeating: 0, count: source.sampleCount)
            try samples.withUnsafeMutableBufferPointer {
                try source.copySamples(into: $0.baseAddress!, offset: 0, count: $0.count)
            }
            log.append(samples)
            return Self.runs(in: samples)
        }
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: GainLevelEngineFactory()),
            loadSpeechDetector: { _ in detector },
            currentEngine: { _ in
                MeetingTranscriber.Engine(
                    descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                    request: .whisper(WhisperDecodeRequest(language: "ru")),
                    label: "Whisper (whisper)"
                )
            },
            temporaryRoot: root
        )
        return try await transcriber.transcribe(try .inspect(folder)) { _ in }
    }

    /// Runs of samples above a small threshold, as speech.
    nonisolated private static func runs(in samples: [Float]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, sample) in samples.enumerated() {
            if abs(sample) > 0.02 {
                if start == nil { start = index }
            } else if let open = start {
                runs.append(open..<index)
                start = nil
            }
        }
        if let open = start { runs.append(open..<samples.count) }
        return runs.filter { $0.count > 8_000 }
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer(samples, format: format))
    }

    /// 24-bit ALAC, as compression writes it; closed before anyone reads it.
    private func writeALAC(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 24,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer(samples, format: format))
    }

    private func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
