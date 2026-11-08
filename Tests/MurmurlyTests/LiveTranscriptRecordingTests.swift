import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// Deterministic generator, separate from the ones private to other test
/// files.
private struct RecordingSeededGenerator: RandomNumberGenerator {
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

private func recordingRMS(_ block: [Float]) -> Float {
    guard !block.isEmpty else { return 0 }
    let sum = block.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(block.count)).squareRoot()
}

/// Classifies a block as speech by its own loudness, the same trick
/// `LiveTranscriptTests` uses, so no real Silero model is needed.
private func recordingLevelDetector(threshold: Float = 0.05) -> LiveTranscript.Detector {
    LiveTranscript.Detector { block, state in
        (recordingRMS(block) > threshold ? Float(1.0) : Float(0.0), state)
    }
}

private final class RecordingPassthroughCanceller: LiveTranscript.EchoCancelling {
    func process(microphone: [Float], reference: [Float]) throws -> [Float] { microphone }
    func finish() throws -> [Float] { [] }
}

/// A door the test opens by hand, for a VAD or an engine load stuck on it.
private actor RecordingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasEntered = false

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func wait() async {
        wasEntered = true
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Answers by the median absolute sample of the chunk file it is asked to
/// transcribe, the same trick `LiveTranscriptTests`' `LiveLevelEngine` uses.
/// Stands in for either engine, since a test's settings may pick Parakeet.
private actor RecordingLevelEngine: WhisperEngine, ParakeetEngine {
    let replies: [Float: String]
    init(replies: [Float: String]) { self.replies = replies }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        try reply(audioPath, language: request.language ?? "en")
    }

    func transcribe(audioPath: String, language: String?) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        try reply(audioPath, language: language ?? "en")
    }

    private func reply(_ audioPath: String, language: String) throws -> (segments: [WhisperSegmentDTO], language: String) {
        let level = try Self.level(of: URL(fileURLWithPath: audioPath))
        let reply = replies.min { abs($0.key - level) < abs($1.key - level) }?.value ?? ""
        return ([WhisperSegmentDTO(text: reply, start: 0)], language)
    }

    static func level(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return 0 }
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let sorted = samples.map { abs($0) }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private struct RecordingLevelEngineFactory: WhisperEngineFactory, ParakeetEngineFactory {
    let replies: [Float: String]
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        RecordingLevelEngine(replies: replies)
    }
    func make(modelFolder: String) async throws -> any ParakeetEngine {
        RecordingLevelEngine(replies: replies)
    }
}

private struct RecordingChunkFailure: LocalizedError {
    var errorDescription: String? { "recording chunk request failed on purpose" }
}

private struct RecordingAlwaysFailingEngine: WhisperEngine, ParakeetEngine {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        throw RecordingChunkFailure()
    }
    func transcribe(audioPath: String, language: String?) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        throw RecordingChunkFailure()
    }
}

private struct RecordingAlwaysFailingEngineFactory: WhisperEngineFactory, ParakeetEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        RecordingAlwaysFailingEngine()
    }
    func make(modelFolder: String) async throws -> any ParakeetEngine {
        RecordingAlwaysFailingEngine()
    }
}

/// Gates the engine's *load*, not a request — a stand-in for a model still
/// being prepared. Gates whichever engine the settings pick.
private struct RecordingGatedLoadFactory: WhisperEngineFactory, ParakeetEngineFactory {
    let gate: RecordingGate
    let replies: [Float: String]
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        await gate.wait()
        return RecordingLevelEngine(replies: replies)
    }
    func make(modelFolder: String) async throws -> any ParakeetEngine {
        await gate.wait()
        return RecordingLevelEngine(replies: replies)
    }
}

/// A capture whose start and stop can each be held, independent of the
/// other, and that keeps a queue of `LiveAudio` snapshots a test pushes by
/// hand — the recording never needs a real IOProc except in the one test
/// that asks for it (`AdoptingCapture`, below).
private actor LiveFeedCapture: MeetingCaptureBackend {
    var failStart = false
    private var directory: URL?
    private var startHeld = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopHeld = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopInProgress = false
    private(set) var stops = 0
    private(set) var liveAudioCalls = 0
    private(set) var liveAudioCallsDuringStop = 0
    private var queue: [LiveAudio] = []

    func setFailStart(_ value: Bool) { failStart = value }

    func holdStart() { startHeld = true }
    func releaseStart() {
        startHeld = false
        let pending = startWaiters
        startWaiters = []
        pending.forEach { $0.resume() }
    }

    func holdStop() { stopHeld = true }
    func releaseStop() {
        stopHeld = false
        let pending = stopWaiters
        stopWaiters = []
        pending.forEach { $0.resume() }
    }

    func push(_ audio: LiveAudio) { queue.append(audio) }

    func start(in directory: URL) async throws -> Date {
        self.directory = directory
        if startHeld {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        if failStart { throw SystemAudioCaptureError.microphoneUnavailable }
        for name in ["system.caf", "microphone.caf"] {
            try Data([0]).write(to: directory.appendingPathComponent(name))
        }
        return Date(timeIntervalSinceReferenceDate: 1_000)
    }

    func writtenSeconds() async -> TimeInterval? { 0 }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        stops += 1
        stopInProgress = true
        if stopHeld {
            await withCheckedContinuation { stopWaiters.append($0) }
        }
        stopInProgress = false
        let metadata = MeetingMetadata(
            startedAt: "2026-11-07T10:00:00Z", endedAt: "2026-11-07T10:01:00Z",
            sampleRate: 16_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }

    func liveAudio() async -> LiveAudio? {
        liveAudioCalls += 1
        if stopInProgress { liveAudioCallsDuringStop += 1 }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}

/// Wraps the real `SystemAudioCapture` so one test can prove the recording's
/// own IOProc ring reaches the line model, not only a synthetic source.
private actor AdoptingCapture: MeetingCaptureBackend {
    private let real = SystemAudioCapture()

    func start(in directory: URL) async throws -> Date {
        let date = Date()
        try await real.adoptSessionForTesting(
            directory: directory, sampleRate: 24_000, systemFrames: 24_000, microphoneFrames: 24_000,
            enqueuedFrames: 24_000, startedAt: date, liveCapacityFrames: 240_000
        )
        return date
    }

    func stop() async throws -> [URL] { try await real.stop() }
    func writtenSeconds() async -> TimeInterval? { await real.writtenSeconds() }
    func liveAudio() async -> LiveAudio? { await real.liveAudio() }

    func deliver(frames: [UInt32], system: [Float]? = nil, microphone: [Float]? = nil) async {
        _ = await real.deliverCycleForTesting(frames: frames, systemSamples: system, microphoneSamples: microphone)
    }
}

private actor RecordingQuietMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// Holds one async result, written once, read by polling — used to observe
/// whether a `Task` has finished without blocking the test on it.
private actor RecordingResultBox<T: Sendable> {
    private(set) var value: T?
    func set(_ newValue: T) { value = newValue }
}

@MainActor
final class LiveTranscriptRecordingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func isolatedSettings() throws -> SettingsStore {
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
        settings.meetingAfterStop = .nothing
        settings.namesFromCallWindow = false
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "en"
        return settings
    }

    private func installedModels() throws -> ModelDownloader {
        let modelsRoot = root.appendingPathComponent("Models", isDirectory: true)
        for source: ModelSource in [.parakeet, .vad] {
            for path in source.required {
                let file = modelsRoot.appendingPathComponent(source.destination).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("model".utf8).write(to: file)
            }
        }
        return ModelDownloader(root: modelsRoot)
    }

    private func makeRecorder(
        capture: any MeetingCaptureBackend,
        liveTranscription: MeetingRecorder.LiveTranscription?
    ) -> MeetingRecorder {
        MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { [root] in try RecordingsStore().createSession(root: root!) },
            liveTranscription: liveTranscription
        )
    }

    private func activate(_ recorder: MeetingRecorder, settings: SettingsStore) {
        let dictation = DictationCoordinator(mic: RecordingQuietMic(), indicator: RecordingIndicator(renderingEnabled: false))
        recorder.activate(settings: settings, permissions: PermissionManager(), dictation: dictation)
    }

    private func waitUntil(timeout: Int = 500, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never became true")
    }

    private func wait(_ recorder: MeetingRecorder, for state: MeetingRecorder.State) async throws {
        try await waitUntil { recorder.state == state }
        XCTAssertEqual(recorder.state, state)
    }

    /// Up to 300 ms of observation: a count must not keep growing.
    private func assertCountSettles(_ count: @escaping @MainActor () -> Int, baseline: Int) async throws {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertLessThanOrEqual(count(), baseline, "kept growing")
        }
    }

    private func blockFrames(rate: Double, block16: Int = 4096) -> Int {
        Int((Double(block16) * rate / 16_000.0).rounded())
    }

    /// Builds a mono signal from a block-aligned pattern of silence/speech
    /// spans at a constant level, so the level engine's reply key matches
    /// exactly.
    private func segmentSignal(pattern: [(speech: Bool, blocks: Int, level: Float)], rate: Double) -> [Float] {
        let frames = blockFrames(rate: rate)
        var samples: [Float] = []
        for segment in pattern {
            for _ in 0..<(segment.blocks * frames) {
                samples.append(segment.speech ? segment.level : 0)
            }
        }
        return samples
    }

    private func makeSnapshots(
        system: [Float], microphone: [Float], rate: Double, firstFrame: Int64, blockSize: Int
    ) -> [LiveAudio] {
        var result: [LiveAudio] = []
        var offset = 0
        var frame = firstFrame
        while offset < system.count {
            let count = max(1, min(blockSize, system.count - offset))
            result.append(LiveAudio(
                sampleRate: rate, microphoneChannels: 1, firstFrame: frame,
                system: Array(system[offset..<(offset + count)]),
                microphone: Array(microphone[offset..<(offset + count)]),
                dropped: 0
            ))
            offset += count
            frame += Int64(count)
        }
        return result
    }

    // MARK: - 1. The real ring reaches the line model

    func testRecordingRingReachesTheLineModel() async throws {
        let capture = AdoptingCapture()
        let live = MeetingRecorder.LiveTranscription(
            models: try installedModels(),
            cache: {
                let factory = RecordingLevelEngineFactory(replies: [0.3: "живая строка"])
                return WhisperKitCache(factory: factory, parakeetFactory: factory)
            }(),
            detector: { _ in recordingLevelDetector() },
            makeEchoCanceller: { RecordingPassthroughCanceller() },
            pollInterval: .milliseconds(10)
        )
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)

        let silence = [Float](repeating: 0, count: 24_000 / 2)
        let speech = [Float](repeating: 0.3, count: Int(24_000 * 1.5))
        let after = [Float](repeating: 0, count: 24_000)
        let system = silence + speech + after
        let microphone = [Float](repeating: 0, count: system.count)
        for start in stride(from: 0, to: system.count, by: 480) {
            let end = min(start + 480, system.count)
            await capture.deliver(
                frames: [UInt32(end - start), UInt32(end - start)],
                system: Array(system[start..<end]), microphone: Array(microphone[start..<end])
            )
        }

        let model = try XCTUnwrap(recorder.liveTranscriptModel)
        var found = false
        for _ in 0..<500 {
            if model.lines.contains(where: { $0.rawText == "живая строка" }) { found = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(found, "the real ring must reach the line model")
        if let line = model.lines.first(where: { $0.rawText == "живая строка" }) {
            XCTAssertEqual(line.track, .system)
            // ~1 s enqueued before the ring (never seen), 0.5 s silence, then
            // speech; the VAD block straddling the silence/speech boundary
            // can already cross the entry threshold, opening the chunk up to
            // one block (0.256 s at 16 kHz) early. The exact instant is the
            // VAD's own cut, not a value this test fixes precisely.
            XCTAssertEqual(line.start, 1.4, accuracy: 0.5)
        }

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    // MARK: - 2. A failed or cancelled start creates no live transcript

    func testFailedStartCreatesNoLiveTranscript() async throws {
        let capture = LiveFeedCapture()
        await capture.setFailStart(true)
        let live = MeetingRecorder.LiveTranscription(models: try installedModels())
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await waitUntil { recorder.isBusy == false }
        let calls = await capture.liveAudioCalls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(recorder.liveTranscriptEngine)
        XCTAssertNil(recorder.liveTranscriptModel)
    }

    func testCancelledStartCreatesNoLiveTranscript() async throws {
        let capture = LiveFeedCapture()
        await capture.holdStart()
        let live = MeetingRecorder.LiveTranscription(models: try installedModels())
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .starting)
        let quit = recorder.beginTermination()
        await capture.releaseStart()
        _ = await quit.value
        let calls = await capture.liveAudioCalls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(recorder.liveTranscriptEngine)
    }

    // MARK: - 4. Stop ends the live transcript before the capture stops

    func testStopEndsTheLiveTranscriptBeforeTheCaptureStops() async throws {
        let capture = LiveFeedCapture()
        let live = MeetingRecorder.LiveTranscription(
            models: try installedModels(),
            cache: {
                let factory = RecordingLevelEngineFactory(replies: [:])
                return WhisperKitCache(factory: factory, parakeetFactory: factory)
            }(),
            detector: { _ in recordingLevelDetector() },
            makeEchoCanceller: { RecordingPassthroughCanceller() },
            pollInterval: .milliseconds(10)
        )
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await waitUntil { recorder.liveTranscriptEngine != nil }

        await capture.holdStop()
        recorder.toggle()
        try await waitUntil(timeout: 100) { recorder.state == .stopping }
        let baseline = await capture.liveAudioCallsDuringStop
        try await Task.sleep(for: .milliseconds(300))
        let duringStop = await capture.liveAudioCallsDuringStop
        XCTAssertEqual(duringStop, baseline, "the live transcript must be finished before capture.stop() is awaited")
        XCTAssertNil(recorder.liveTranscriptEngine)
        await capture.releaseStop()
        try await wait(recorder, for: .idle)
    }

    // MARK: - 5. A pipeline failure leaves the recording alone

    func testPipelineFailureLeavesTheRecordingAlone() async throws {
        let capture = LiveFeedCapture()
        let live = MeetingRecorder.LiveTranscription(
            models: try installedModels(),
            cache: {
                let factory = RecordingAlwaysFailingEngineFactory()
                return WhisperKitCache(factory: factory, parakeetFactory: factory)
            }(),
            detector: { _ in recordingLevelDetector() },
            makeEchoCanceller: { RecordingPassthroughCanceller() },
            pollInterval: .milliseconds(10)
        )
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        let model = try XCTUnwrap(recorder.liveTranscriptModel)

        let rate = 16_000.0
        let signal = segmentSignal(
            pattern: [
                (false, 2, 0), (true, 6, 0.3), (false, 2, 0),
                (false, 2, 0), (true, 6, 0.3), (false, 2, 0),
                (false, 2, 0), (true, 6, 0.3), (false, 2, 0),
                (false, 2, 0), (true, 6, 0.3), (false, 2, 0),
            ], rate: rate
        )
        for snapshot in makeSnapshots(system: signal, microphone: [Float](repeating: 0, count: signal.count), rate: rate, firstFrame: 0, blockSize: 4096) {
            await capture.push(snapshot)
        }

        var stopped = false
        for _ in 0..<500 {
            if case .stopped = model.state { stopped = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(stopped, "three failures in a row must stop the pipeline")
        XCTAssertEqual(recorder.state, .recording, "the recording itself must be unaffected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recorder.currentSession?.directory.appendingPathComponent("system.caf").path)))

        recorder.toggle()
        try await wait(recorder, for: .idle)
        let directory = try XCTUnwrap(recorder.lastRecordingDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path))
    }

    // MARK: - 6. The setting off builds no pipeline; on by default and silent

    func testSettingOffBuildsNoPipeline() async throws {
        let capture = LiveFeedCapture()
        let live = MeetingRecorder.LiveTranscription(models: try installedModels())
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        settings.liveTranscript = false
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await Task.sleep(for: .milliseconds(300))
        let calls = await capture.liveAudioCalls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(recorder.liveTranscriptEngine)
        XCTAssertNil(recorder.liveTranscriptModel)
        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    func testLiveTranscriptIsOnByDefaultAndWritesNothing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings-default").path))
        let fresh = SettingsStore(defaults: defaults)
        XCTAssertTrue(fresh.liveTranscript)
        XCTAssertNil(defaults.object(forKey: "meeting.liveTranscript"))
        fresh.liveTranscript = false
        XCTAssertEqual(defaults.object(forKey: "meeting.liveTranscript") as? Bool, false)
        let again = SettingsStore(defaults: defaults)
        XCTAssertFalse(again.liveTranscript)
    }

    // MARK: - 8. Quit during a hung model load finishes the stop

    func testQuitDuringAHungModelLoadFinishesTheStop() async throws {
        let gate = RecordingGate()
        let capture = LiveFeedCapture()
        let live = MeetingRecorder.LiveTranscription(
            models: try installedModels(),
            cache: {
                let factory = RecordingGatedLoadFactory(gate: gate, replies: [0.3: "кусок"])
                return WhisperKitCache(factory: factory, parakeetFactory: factory)
            }(),
            detector: { _ in recordingLevelDetector() },
            makeEchoCanceller: { RecordingPassthroughCanceller() },
            pollInterval: .milliseconds(10)
        )
        defer { Task { await gate.open() } }
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        let model = try XCTUnwrap(recorder.liveTranscriptModel)

        let rate = 16_000.0
        let signal = segmentSignal(pattern: [(false, 2, 0), (true, 6, 0.3), (false, 2, 0)], rate: rate)
        for snapshot in makeSnapshots(system: signal, microphone: [Float](repeating: 0, count: signal.count), rate: rate, firstFrame: 0, blockSize: 4096) {
            await capture.push(snapshot)
        }
        try await waitUntil(timeout: 1_000) { model.state == .preparingModel }

        let quit = recorder.beginTermination()
        try await waitUntil(timeout: 500) { recorder.state == .idle }
        let saved = await quit.value
        XCTAssertTrue(saved)
        let stops = await capture.stops
        XCTAssertEqual(stops, 1)
    }

    // MARK: - 9. Lines of a stopped meeting never reach the next

    func testLinesOfAStoppedMeetingNeverReachTheNext() async throws {
        let gate = RecordingGate()
        let capture = LiveFeedCapture()
        let live = MeetingRecorder.LiveTranscription(
            models: try installedModels(),
            cache: {
                let factory = RecordingGatedLoadFactory(
                    gate: gate, replies: [0.3: "первая встреча", 0.6: "вторая встреча"]
                )
                return WhisperKitCache(factory: factory, parakeetFactory: factory)
            }(),
            detector: { _ in recordingLevelDetector() },
            makeEchoCanceller: { RecordingPassthroughCanceller() },
            pollInterval: .milliseconds(10)
        )
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let firstModel = try XCTUnwrap(recorder.liveTranscriptModel)
        let rate = 16_000.0
        let firstSignal = segmentSignal(pattern: [(false, 2, 0), (true, 6, 0.3), (false, 2, 0)], rate: rate)
        for snapshot in makeSnapshots(
            system: firstSignal, microphone: [Float](repeating: 0, count: firstSignal.count),
            rate: rate, firstFrame: 0, blockSize: 4096
        ) {
            await capture.push(snapshot)
        }
        // The engine's single load is gated, so the first meeting's chunk
        // never gets a reply before the stop below cancels it — it stays
        // orphaned inside the cache until the gate opens, well after the
        // second meeting has already started.
        try await waitUntil(timeout: 1_000) { firstModel.state == .preparingModel }

        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertTrue(firstModel.lines.isEmpty, "the first meeting's chunk never got a reply before the stop")

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let secondModel = try XCTUnwrap(recorder.liveTranscriptModel)
        XCTAssertTrue(secondModel !== firstModel)
        XCTAssertTrue(secondModel.lines.isEmpty)

        await gate.open()

        let signal = segmentSignal(pattern: [(false, 2, 0), (true, 6, 0.6), (false, 2, 0)], rate: rate)
        for snapshot in makeSnapshots(system: signal, microphone: [Float](repeating: 0, count: signal.count), rate: rate, firstFrame: 0, blockSize: 4096) {
            await capture.push(snapshot)
        }
        var gotSecond = false
        for _ in 0..<500 {
            if secondModel.lines.contains(where: { $0.rawText == "вторая встреча" }) { gotSecond = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gotSecond)
        XCTAssertFalse(secondModel.lines.contains(where: { $0.rawText == "первая встреча" }))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(secondModel.lines.contains(where: { $0.rawText == "первая встреча" }))

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    // MARK: - 10. (fix) Stop during live preparation is awaited by quit

    func testStopDuringLivePreparationIsAwaitedByQuit() async throws {
        let gate = RecordingGate()
        let capture = LiveFeedCapture()
        let live = MeetingRecorder.LiveTranscription(
            models: try installedModels(),
            detector: { _ in await gate.wait(); return recordingLevelDetector() },
            makeEchoCanceller: { RecordingPassthroughCanceller() },
            pollInterval: .milliseconds(10)
        )
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        await capture.holdStop()
        recorder.toggle()
        try await wait(recorder, for: .recording)

        var startTaskFinished = false
        recorder.startTaskFinishedForTesting = { startTaskFinished = true }
        recorder.toggle()
        try await waitUntil(timeout: 100) { recorder.state == .stopping }
        await gate.open()
        try await waitUntil(timeout: 1_000) { startTaskFinished }

        let quit = recorder.beginTermination()
        let box = RecordingResultBox<Bool>()
        Task {
            let saved = await quit.value
            await box.set(saved)
        }
        // 300 ms of observation: without the K1 fix, quit answers "saved"
        // right away, while the stop is still held.
        try await Task.sleep(for: .milliseconds(300))
        let early = await box.value
        XCTAssertNil(early, "quit must wait for the held stop, not answer while capture.stop() is still running")

        await capture.releaseStop()
        var saved: Bool?
        for _ in 0..<500 {
            saved = await box.value
            if saved != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(saved, true)
        let stops = await capture.stops
        XCTAssertEqual(stops, 1)
        let calls = await capture.liveAudioCalls
        XCTAssertEqual(calls, 0)
    }

    // MARK: - 11. No model at the start shows .noModel and holds nothing

    func testNoModelAtStartShowsNoModelAndHoldsNothing() async throws {
        let capture = LiveFeedCapture()
        let emptyModels = ModelDownloader(root: root.appendingPathComponent("EmptyModels", isDirectory: true))
        let live = MeetingRecorder.LiveTranscription(models: emptyModels)
        let recorder = makeRecorder(capture: capture, liveTranscription: live)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        let model = try XCTUnwrap(recorder.liveTranscriptModel)
        try await waitUntil { model.state == .noModel }
        XCTAssertNil(recorder.liveTranscriptEngine)
        try await Task.sleep(for: .milliseconds(200))
        let calls = await capture.liveAudioCalls
        XCTAssertEqual(calls, 0)
        recorder.toggle()
        try await wait(recorder, for: .idle)
    }
}
