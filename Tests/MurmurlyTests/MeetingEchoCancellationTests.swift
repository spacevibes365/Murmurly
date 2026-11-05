import AVFoundation
import FluidAudio
import Foundation
import XCTest
@testable import Murmurly

/// Deterministic generator (SplitMix64) so every run sees the same signals.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Synthetic speech-like signals and the echo of them a microphone would pick
/// up from a loudspeaker, for testing the echo canceller without any real
/// recording. The recipe matches the WebRTCAEC3 package's own tests.
private enum Signals {
    static let rate = 16_000

    static func whiteNoise(count: Int, seed: UInt64) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            let sum = (0..<4).reduce(Float(0)) { acc, _ in acc + Float.random(in: -1...1, using: &rng) }
            return sum * 0.5
        }
    }

    static func speechLike(
        seconds: Double, seed: UInt64, syllableHz: Double, formants: (Double, Double), level: Float
    ) -> [Float] {
        let count = Int(seconds * Double(rate))
        let noise = whiteNoise(count: count, seed: seed)
        var out = [Float](repeating: 0, count: count)
        let r1 = resonator(centre: formants.0, bandwidth: 120)
        let r2 = resonator(centre: formants.1, bandwidth: 200)
        var y1 = (Float(0), Float(0)), y2 = (Float(0), Float(0))
        var rng = SeededGenerator(seed: seed ^ 0xABCD)
        var gate = [Float](repeating: 0, count: count)
        var i = 0
        var talking = true
        while i < count {
            let length = Int(Double.random(in: talking ? 0.4...1.2 : 0.2...0.8, using: &rng) * Double(rate))
            if talking { for j in i..<min(count, i + length) { gate[j] = 1 } }
            i += length
            talking.toggle()
        }
        for n in 0..<count {
            let t = Double(n) / Double(rate)
            let envelope = Float(0.5 + 0.5 * sin(2 * .pi * syllableHz * t))
            let a = r1.b0 * noise[n] - r1.a1 * y1.0 - r1.a2 * y1.1
            y1 = (a, y1.0)
            let b = r2.b0 * noise[n] - r2.a1 * y2.0 - r2.a2 * y2.1
            y2 = (b, y2.0)
            out[n] = (a + 0.7 * b) * envelope * gate[n] * level
        }
        return out
    }

    private static func resonator(centre: Double, bandwidth: Double) -> (b0: Float, a1: Float, a2: Float) {
        let r = exp(-.pi * bandwidth / Double(rate))
        let theta = 2 * .pi * centre / Double(rate)
        return (Float(1 - r), Float(-2 * r * cos(theta)), Float(r * r))
    }

    /// What a microphone hears of the loudspeaker: gain 0.5 after 24 ms plus a
    /// short decaying tail (a small room), and a -60 dB noise floor.
    static func echo(of reference: [Float], seed: UInt64) -> [Float] {
        let delay = 24 * rate / 1000
        var taps = [Float](repeating: 0, count: 240)
        taps[0] = 1
        var rng = SeededGenerator(seed: seed)
        for k in 1..<taps.count {
            taps[k] = Float.random(in: -1...1, using: &rng) * 0.35 * exp(-Float(k) / 60)
        }
        var out = [Float](repeating: 0, count: reference.count)
        for n in 0..<reference.count {
            var acc: Float = 0
            for k in 0..<taps.count where n - delay - k >= 0 { acc += taps[k] * reference[n - delay - k] }
            out[n] = 0.5 * acc
        }
        let floor = whiteNoise(count: reference.count, seed: seed ^ 0x5151)
        for n in 0..<out.count { out[n] += floor[n] * 0.001 }
        return out
    }

    static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    static func db(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }
}

/// Remembers every block of samples handed to it for the microphone and
/// returns no speech ranges, so the engine is never called: the detector is
/// the probe, and nothing past it (recognition, the transcript) runs.
private final class DetectorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[Float]] = []

    var detector: MeetingTranscriber.SpeechDetector {
        { [self] source in
            var samples = [Float](repeating: 0, count: source.sampleCount)
            try samples.withUnsafeMutableBufferPointer {
                try source.copySamples(into: $0.baseAddress!, offset: 0, count: $0.count)
            }
            self.lock.withLock { self.calls.append(samples) }
            return []
        }
    }

    /// The microphone is always read first (before the system track, which
    /// this test's detector also sees but never relies on).
    func microphoneSamples() -> [Float]? { lock.withLock { calls.first } }
    func callCount() -> Int { lock.withLock { calls.count } }
    func reset() { lock.withLock { calls.removeAll() } }
}

private struct NeverCalledEngineFactory: WhisperEngineFactory {
    struct Unexpected: LocalizedError {
        var errorDescription: String? { "no chunk should reach the engine in this test" }
    }
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { throw Unexpected() }
}

@MainActor
final class MeetingEchoCancellationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-echo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Tests

    /// `live(...)` turns AEC on; a plain, element-wise build does not
    /// (`cancelsEcho` defaults to `false`). On the code before this card, the
    /// microphone the detector sees is the raw, un-cancelled track either way,
    /// so this must fail there.
    func testLiveMeetingRemovesEchoBeforeSpeechDetection() async throws {
        let far = Signals.speechLike(seconds: 8, seed: 1, syllableHz: 4, formants: (700, 1800), level: 0.6)
        let microphone = Signals.echo(of: far, seed: 3)
        let folder = try makeFolder(microphone: microphone, system: far)

        let rawSpy = DetectorSpy()
        let plain = plainBuild(detector: rawSpy.detector)
        _ = try await plain.transcribe(try .inspect(folder)) { _ in }
        let raw = try XCTUnwrap(rawSpy.microphoneSamples())

        let cleanedSpy = DetectorSpy()
        let (settings, models) = try liveFixture()
        let live = MeetingTranscriber.live(
            settings: settings, models: models,
            cache: WhisperKitCache(factory: NeverCalledEngineFactory()),
            speechDetector: { _ in cleanedSpy.detector }
        )
        let started = ContinuousClock.now
        _ = try await live.transcribe(try .inspect(folder)) { _ in }
        let elapsed = started.duration(to: .now)
        let cleaned = try XCTUnwrap(cleanedSpy.microphoneSamples())

        XCTAssertEqual(cleaned.count, raw.count)
        let window = 48_000..<128_000   // 3-8 s
        let reduction = Signals.db(Signals.rms(Array(raw[window])) / Signals.rms(Array(cleaned[window])))
        print("MEASURED echo reduction dB = \(reduction)")
        print("MEASURED live transcribe seconds = \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
        XCTAssertGreaterThanOrEqual(reduction, 20)
    }

    /// No system track: the microphone reaches the detector exactly as read,
    /// AEC or not — there is nothing to cancel against.
    func testWithoutASystemTrackTheMicrophoneReachesTheDetectorUnchanged() async throws {
        let near = Signals.speechLike(seconds: 8, seed: 2, syllableHz: 3, formants: (450, 2300), level: 0.12)
        let folder = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTrack(folder.appendingPathComponent("microphone.caf"), samples: near)

        let plainSpy = DetectorSpy()
        let plain = plainBuild(detector: plainSpy.detector)
        _ = try await plain.transcribe(try .inspect(folder)) { _ in }

        let liveSpy = DetectorSpy()
        let (settings, models) = try liveFixture()
        let live = MeetingTranscriber.live(
            settings: settings, models: models,
            cache: WhisperKitCache(factory: NeverCalledEngineFactory()),
            speechDetector: { _ in liveSpy.detector }
        )
        _ = try await live.transcribe(try .inspect(folder)) { _ in }

        let plainSamples = try XCTUnwrap(plainSpy.microphoneSamples())
        let liveSamples = try XCTUnwrap(liveSpy.microphoneSamples())
        XCTAssertEqual(plainSamples, liveSamples)
    }

    /// A near-end voice alone, with a short, silent system track (also checks
    /// that a shorter reference is padded with zeros rather than failing):
    /// AEC must not bend the level of speech that was never echo.
    func testNearEndVoiceAloneKeepsItsLevel() async throws {
        let near = Signals.speechLike(seconds: 8, seed: 2, syllableHz: 3, formants: (450, 2300), level: 0.12)
        let silence = [Float](repeating: 0, count: 4 * Signals.rate)
        let folder = try makeFolder(microphone: near, system: silence)

        let rawSpy = DetectorSpy()
        let plain = plainBuild(detector: rawSpy.detector)
        _ = try await plain.transcribe(try .inspect(folder)) { _ in }
        let raw = try XCTUnwrap(rawSpy.microphoneSamples())

        let cleanedSpy = DetectorSpy()
        let (settings, models) = try liveFixture()
        let live = MeetingTranscriber.live(
            settings: settings, models: models,
            cache: WhisperKitCache(factory: NeverCalledEngineFactory()),
            speechDetector: { _ in cleanedSpy.detector }
        )
        _ = try await live.transcribe(try .inspect(folder)) { _ in }
        let cleaned = try XCTUnwrap(cleanedSpy.microphoneSamples())

        XCTAssertEqual(cleaned.count, raw.count)
        let window = 48_000..<128_000
        let delta = abs(Signals.db(Signals.rms(Array(cleaned[window])) / Signals.rms(Array(raw[window]))))
        XCTAssertLessThanOrEqual(delta, 1)
    }

    /// Cancelling the task while the microphone track is being read (AEC's own
    /// checkpoint, before the VAD) throws `CancellationError` and writes
    /// nothing; the detector is never reached.
    func testCancelDuringEchoCancellationWritesNothing() async throws {
        let far = Signals.speechLike(seconds: 8, seed: 1, syllableHz: 4, formants: (700, 1800), level: 0.6)
        let microphone = Signals.echo(of: far, seed: 3)
        let folder = try makeFolder(microphone: microphone, system: far)

        let spy = DetectorSpy()
        let (settings, models) = try liveFixture()
        let live = MeetingTranscriber.live(
            settings: settings, models: models,
            cache: WhisperKitCache(factory: NeverCalledEngineFactory()),
            speechDetector: { _ in spy.detector }
        )
        let microphoneLabel = String(localized: "microphone")
        let task = Task {
            try await live.transcribe(try .inspect(folder)) { step in
                if case .reading(let track) = step, track == microphoneLabel {
                    // The progress callback runs inside this very task, so the
                    // current task at this point is the one to cancel.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        var threw: Error?
        do {
            _ = try await task.value
        } catch {
            threw = error
        }
        XCTAssertTrue(threw is CancellationError, "expected CancellationError, got \(String(describing: threw))")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".md") })
        XCTAssertEqual(spy.callCount(), 0)
    }

    /// `live(...)` wires AEC on; a plain, element-wise build (as other tests
    /// and StageGate build it) does not, so the two differ by at least 20 dB
    /// on the same echoey folder, and the plain one is bit-for-bit what a
    /// second plain run produces.
    func testLiveWiringCancelsEchoWhileThePlainBuildDoesNot() async throws {
        let far = Signals.speechLike(seconds: 8, seed: 1, syllableHz: 4, formants: (700, 1800), level: 0.6)
        let microphone = Signals.echo(of: far, seed: 3)
        let folder = try makeFolder(microphone: microphone, system: far)

        let firstSpy = DetectorSpy()
        let plainFirst = plainBuild(detector: firstSpy.detector)
        _ = try await plainFirst.transcribe(try .inspect(folder)) { _ in }
        let first = try XCTUnwrap(firstSpy.microphoneSamples())

        let secondSpy = DetectorSpy()
        let plainSecond = plainBuild(detector: secondSpy.detector)
        _ = try await plainSecond.transcribe(try .inspect(folder)) { _ in }
        let second = try XCTUnwrap(secondSpy.microphoneSamples())

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) { XCTAssertEqual(a, b, accuracy: 1e-6) }

        let liveSpy = DetectorSpy()
        let (settings, models) = try liveFixture()
        let live = MeetingTranscriber.live(
            settings: settings, models: models,
            cache: WhisperKitCache(factory: NeverCalledEngineFactory()),
            speechDetector: { _ in liveSpy.detector }
        )
        _ = try await live.transcribe(try .inspect(folder)) { _ in }
        let cleaned = try XCTUnwrap(liveSpy.microphoneSamples())

        XCTAssertEqual(cleaned.count, first.count)
        let window = 48_000..<128_000
        let reduction = Signals.db(Signals.rms(Array(first[window])) / Signals.rms(Array(cleaned[window])))
        XCTAssertGreaterThanOrEqual(reduction, 20)
    }

    // MARK: - Helpers

    private func makeFolder(microphone: [Float], system: [Float], name: String = "meeting") throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTrack(folder.appendingPathComponent("microphone.caf"), samples: microphone)
        try writeTrack(folder.appendingPathComponent("system.caf"), samples: system)
        return folder
    }

    /// 16 kHz Float32 mono CAF, the sample rate `MeetingTranscriber` reads
    /// tracks at, so the disk-backed source's own resampling does not enter
    /// into what these tests measure.
    private func writeTrack(_ url: URL, samples: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Signals.rate), channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }

    /// A plain, element-wise build, made exactly as the existing tests and
    /// StageGate build one: `cancelsEcho` stays at its default, `false`.
    private func plainBuild(detector: @escaping MeetingTranscriber.SpeechDetector) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: WhisperKitCache(factory: NeverCalledEngineFactory()),
            loadSpeechDetector: { _ in detector },
            currentEngine: { _ in throw NeverCalledEngineFactory.Unexpected() },
            temporaryRoot: root
        )
    }

    /// Settings and a models folder good enough for `MeetingTranscriber.live`'s
    /// own checks (model files present, so it does not refuse before AEC runs).
    private func liveFixture() throws -> (SettingsStore, ModelDownloader) {
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
        let modelsRoot = root.appendingPathComponent("Models", isDirectory: true)
        for source: ModelSource in [.parakeet, .whisper, .whisperTokenizer, .vad] {
            for path in source.required {
                let file = modelsRoot.appendingPathComponent(source.destination).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("model".utf8).write(to: file)
            }
        }
        return (settings, ModelDownloader(root: modelsRoot))
    }
}
