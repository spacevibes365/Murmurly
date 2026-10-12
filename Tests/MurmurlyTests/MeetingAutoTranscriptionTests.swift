import AVFoundation
import FluidAudio
import XCTest
@testable import Murmurly

/// A meeting backend that saves a real (silent) recording, so the queue's job
/// can read the folder like one written by `SystemAudioCapture`. Shared with
/// `AppUpdaterTests`.
actor SavingMeetingCapture: MeetingCaptureBackend {
    enum StopMode: Sendable { case clean, partlySaved }
    let root: URL
    let stopMode: StopMode
    private var stops = 0

    init(root: URL, stopMode: StopMode = .clean) {
        self.root = root
        self.stopMode = stopMode
    }

    /// Each session gets its own folder, as `RecordingsStore.createSession` does.
    nonisolated static func folder(_ index: Int, in root: URL) -> URL {
        root.appendingPathComponent("2026-10-06 13-00-0\(index) Meeting", isDirectory: true)
    }

    func start() async throws -> Date { Date(timeIntervalSinceReferenceDate: 1_000) }

    func stop() async throws -> [URL] {
        stops += 1
        let directory = Self.folder(stops, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracks = ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
        for track in tracks { try Self.writeSilence(to: track) }
        let metadata = MeetingMetadata(
            startedAt: "2026-10-06T10:00:00Z",
            endedAt: "2026-10-06T10:01:00Z",
            sampleRate: 48_000,
            state: stopMode == .clean ? "done" : "failed",
            segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        if stopMode == .partlySaved {
            throw SystemAudioCaptureError.captureFailed(message: "partial", savedAt: directory)
        }
        return tracks
    }

    private static func writeSilence(to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000) else { return }
        buffer.frameLength = 144_000
        for index in 0..<144_000 { buffer.floatChannelData![0][index] = 0 }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }
}

private actor SilentMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// What a test's Finder was asked to show.
@MainActor
private final class ShownFolders {
    var urls: [URL] = []
}

final class JobCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// The junction "setting → stop → queue": the real recorder, the real queue,
/// only the capture and the VAD stand in.
@MainActor
final class MeetingAutoTranscriptionTests: XCTestCase {
    // One fixed suite, cleared around every test: per-test UUID suites exhaust
    // cfprefsd's descriptors under repeated runs.
    private static let suiteName = "io.github.spacevibes365.MurmurlyTests.MeetingAutoTranscription"
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testTranscribeSettingQueuesACleanlyStoppedRecording() async throws {
        let setup = makeRecorder(afterStop: .transcribe)

        try await record(setup.recorder)

        let queued = await eventually { setup.queue.lastOutcome != nil }
        XCTAssertTrue(queued)
        guard case .noSpeech(let folder)? = setup.queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: setup.queue.lastOutcome))")
        }
        XCTAssertEqual(folder.path, setup.folder.path)
        XCTAssertEqual(setup.jobs.value, 1)
    }

    func testNothingSettingStartsNoTranscription() async throws {
        let setup = makeRecorder(afterStop: .nothing)

        try await record(setup.recorder)

        let started = await eventually(within: .milliseconds(500)) { setup.jobs.value > 0 }
        XCTAssertFalse(started)
        XCTAssertNil(setup.queue.lastOutcome)
        XCTAssertNil(setup.queue.activeFolder)
    }

    func testQuitTimeStopIsNotQueued() async throws {
        let setup = makeRecorder(afterStop: .transcribe)
        setup.recorder.toggle()
        try await waitUntil { setup.recorder.state == .recording }

        let saved = await setup.recorder.beginTermination().value

        XCTAssertTrue(saved)
        XCTAssertEqual(setup.recorder.state, .idle)
        let started = await eventually(within: .milliseconds(500)) { setup.jobs.value > 0 }
        XCTAssertFalse(started)
        XCTAssertNil(setup.queue.activeFolder)
        XCTAssertTrue(setup.queue.pending.isEmpty)
    }

    func testPartlySavedRecordingIsNotQueued() async throws {
        let setup = makeRecorder(afterStop: .transcribe, stopMode: .partlySaved)
        setup.recorder.toggle()
        try await waitUntil { setup.recorder.state == .recording }

        setup.recorder.toggle()
        try await waitUntil { !setup.recorder.isBusy }

        XCTAssertNotNil(setup.recorder.recordingWarning)
        let started = await eventually(within: .milliseconds(500)) { setup.jobs.value > 0 }
        XCTAssertFalse(started)
        XCTAssertNil(setup.queue.lastOutcome)
    }

    func testStopAndQuitDoNotWaitForARunningTranscription() async throws {
        let entered = JobCounter()
        let release = JobCounter()
        let setup = makeRecorder(afterStop: .transcribe, detector: { _ in
            entered.increment()
            while release.value == 0 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            return []
        })

        try await record(setup.recorder)
        let running = await eventually { entered.value == 1 }

        XCTAssertTrue(running)
        XCTAssertNotNil(setup.queue.activeFolder)
        // Quit asks only the recorders; a transcription in progress is not theirs.
        XCTAssertFalse(setup.recorder.hasUnfinishedWork)
        setup.recorder.toggle()
        try await waitUntil { setup.recorder.state == .recording }
        setup.recorder.toggle()
        try await waitUntil { setup.recorder.state == .idle }
        XCTAssertEqual(setup.queue.pending.count, 1, "the second recording waits its turn")

        release.increment()
        let drained = await eventually { setup.queue.activeFolder == nil && setup.queue.pending.isEmpty }
        XCTAssertTrue(drained)
        XCTAssertEqual(setup.jobs.value, 2, "both recordings were transcribed, one after the other")
    }

    func testDefaultIsTranscribeAndTheChoiceIsKept() {
        XCTAssertEqual(SettingsStore(defaults: defaults).meetingAfterStop, .transcribe)
        SettingsStore(defaults: defaults).meetingAfterStop = .nothing
        XCTAssertEqual(SettingsStore(defaults: defaults).meetingAfterStop, .nothing)
    }

    func testCutShortTranscriptIsReportedWithItsReason() async throws {
        let folder = SavingMeetingCapture.folder(1, in: root)
        _ = try await SavingMeetingCapture(root: root).stop()
        let calls = JobCounter()
        let queue = MeetingTranscriptionQueue(transcriber: MeetingTranscriber(
            cache: WhisperKitCache(factory: ConstantEngineFactory()),
            loadSpeechDetector: { { _ in [0..<16_000, 32_000..<48_000] } },
            currentEngine: {
                calls.increment()
                if calls.value > 2 { throw TranscriptionError.engineUnavailable("model removed") }
                return MeetingTranscriber.Engine(
                    descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                    request: .whisper(WhisperDecodeRequest(language: "ru")),
                    label: "Whisper (whisper)"
                )
            },
            temporaryRoot: root
        ))

        queue.enqueue(folder)
        let finished = await eventually { queue.lastOutcome != nil }

        XCTAssertTrue(finished)
        guard case .cutShort(let transcript, let reason)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertEqual(transcript.lastPathComponent, "transcript.md")
        XCTAssertTrue(reason.contains("model removed"), reason)
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains(reason))
    }

    /// A meeting moved to the meetings folder is shown where it
    /// went after the folder setting changes: "Show Last Recording…" and "Show
    /// Transcript" follow the move, not today's setting.
    func testMovedMeetingIsShownWhereItWentAfterTheFolderIsReset() async throws {
        // Outside the local root: a folder inside it cannot be a meetings folder.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let settings = SettingsStore(defaults: defaults)
        settings.meetingAfterStop = .transcribe
        settings.meetingsFolderPath = target.path
        let shown = ShownFolders()
        let queue = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: ConstantEngineFactory()),
                loadSpeechDetector: { { _ in [0..<16_000] } },
                currentEngine: {
                    MeetingTranscriber.Engine(
                        descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                        request: .whisper(WhisperDecodeRequest(language: "ru")),
                        label: "Whisper (whisper)"
                    )
                },
                temporaryRoot: work
            ),
            meetingsRoot: root,
            destinations: { settings.meetingDestinations },
            fileViewer: { shown.urls.append($0) }
        )
        let recorder = MeetingRecorder(
            capture: SavingMeetingCapture(root: root),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            fileViewer: { shown.urls.append($0) }
        )
        recorder.transcripts = queue
        recorder.activate(
            settings: settings,
            permissions: PermissionManager(),
            dictation: DictationCoordinator(mic: SilentMic(), indicator: RecordingIndicator(renderingEnabled: false))
        )
        let name = SavingMeetingCapture.folder(1, in: root).lastPathComponent
        let moved = target.appendingPathComponent(name, isDirectory: true)

        try await record(recorder)
        let done = await eventually(within: .seconds(30)) {
            FileManager.default.fileExists(atPath: moved.path)
                && queue.activeFolder == nil && queue.pending.isEmpty
        }
        XCTAssertTrue(done, "the meeting was not moved — the check proves nothing")
        guard case .saved? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }

        settings.meetingsFolderPath = nil
        recorder.revealLastRecording()
        queue.revealOutcome()

        XCTAssertEqual(shown.urls.map(\.standardizedFileURL.path), [
            moved.standardizedFileURL.path,
            moved.appendingPathComponent("transcript.md").standardizedFileURL.path,
        ])
    }

    // MARK: - Helpers

    private func makeRecorder(
        afterStop: MeetingAfterStop,
        stopMode: SavingMeetingCapture.StopMode = .clean,
        detector: MeetingTranscriber.SpeechDetector? = nil
    ) -> (
        recorder: MeetingRecorder, queue: MeetingTranscriptionQueue, folder: URL, jobs: JobCounter,
        settings: SettingsStore
    ) {
        let folder = SavingMeetingCapture.folder(1, in: root)
        let jobs = JobCounter()
        let queue = MeetingTranscriptionQueue(transcriber: MeetingTranscriber(
            cache: WhisperKitCache(factory: ConstantEngineFactory()),
            loadSpeechDetector: {
                jobs.increment()
                return detector ?? { _ in [] }
            },
            currentEngine: { throw TranscriptionError.engineUnavailable("not used: no speech") },
            temporaryRoot: root
        ))
        let settings = SettingsStore(defaults: defaults)
        settings.meetingAfterStop = afterStop
        let recorder = MeetingRecorder(
            capture: SavingMeetingCapture(root: root, stopMode: stopMode),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
        recorder.transcripts = queue
        recorder.activate(
            settings: settings,
            permissions: PermissionManager(),
            dictation: DictationCoordinator(mic: SilentMic(), indicator: RecordingIndicator(renderingEnabled: false))
        )
        // The recorder holds settings and queue weakly, as the app's state
        // objects do; the caller keeps them alive.
        return (recorder, queue, folder, jobs, settings)
    }

    private func record(_ recorder: MeetingRecorder) async throws {
        recorder.toggle()
        try await waitUntil { recorder.state == .recording }
        recorder.toggle()
        try await waitUntil { recorder.state == .idle }
    }

    private func waitUntil(_ done: @MainActor () -> Bool) async throws {
        let reached = await eventually(done)
        XCTAssertTrue(reached)
    }

    /// Polls with a deadline, so a wedged queue fails instead of hanging the run.
    private func eventually(
        within limit: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Answers every chunk with the same line; only the cut-short test and
/// `AppUpdaterTests` speak.
struct ConstantEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { ConstantEngine() }
}

private actor ConstantEngine: WhisperEngine {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        ([WhisperSegmentDTO(text: "успели расслышать", start: 0)], "ru")
    }
}
