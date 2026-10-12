import AVFoundation
import FluidAudio
import XCTest
@testable import Murmurly

/// Saves every stop as a finished folder with real tracks and metadata naming
/// them, as `SystemAudioCapture` does.
private actor CompressibleMeetingCapture: MeetingCaptureBackend {
    let root: URL
    let rate: Double
    private var stops = 0

    init(root: URL, rate: Double) {
        self.root = root
        self.rate = rate
    }

    nonisolated static func folder(_ index: Int, in root: URL) -> URL {
        root.appendingPathComponent("2026-10-06 16-00-0\(index) Meeting", isDirectory: true)
    }

    func start() async throws -> Date { Date(timeIntervalSinceReferenceDate: 1_000) }

    func stop() async throws -> [URL] {
        stops += 1
        // One second at the recording's rate.
        var microphone = MeetingAudio.noise(count: Int(rate), amplitude: 0.4, seed: UInt32(stops))
        microphone[100] = 1.4
        let folder = try MeetingAudio.folder(
            Self.folder(stops, in: root).lastPathComponent,
            in: root,
            microphone: [microphone],
            system: [MeetingAudio.noise(count: Int(rate), amplitude: 0.4, seed: UInt32(stops + 50))],
            rate: rate
        )
        return ["system.caf", "microphone.caf"].map { folder.appendingPathComponent($0) }
    }
}

private actor QuietMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct SilentEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { SilentEngine() }
}

private actor SilentEngine: WhisperEngine {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        ([], "ru")
    }
}

/// The junctions "stop → queue → compression" and "scan → queue": the real
/// recorder, queue and settings; only the capture and the VAD stand in.
@MainActor
final class MeetingCompressionQueueTests: XCTestCase {
    private static let suiteName = "io.github.spacevibes365.MurmurlyTests.MeetingCompressionQueue"
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testNothingSettingCompressesWithoutTranscription() async throws {
        let setup = makeRecorder(afterStop: .nothing)

        try await record(setup.recorder)
        let folder = CompressibleMeetingCapture.folder(1, in: root)
        let compressed = await eventually { self.isCompressed(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(compressed)
        XCTAssertEqual(setup.transcriptions.value, 0)
        XCTAssertNil(setup.queue.lastOutcome)
        XCTAssertEqual(setup.queue.issues, [:])
        let inspected = try MeetingTranscriber.Folder.inspect(folder)
        XCTAssertLessThan(inspected.microphoneGain, 1)
        XCTAssertEqual(inspected.systemGain, 1)
    }

    func testTranscriptionComesFirstThenCompression() async throws {
        let read = Locked<[String]>([])
        let setup = makeRecorder(afterStop: .transcribe, detector: { source in
            // What the transcription read: still the CAF at this point.
            read.mutate { $0.append("\(source.sampleCount)") }
            return []
        })

        try await record(setup.recorder)
        let folder = CompressibleMeetingCapture.folder(1, in: root)
        let done = await eventually { self.isCompressed(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(setup.transcriptions.value, 1)
        XCTAssertEqual(setup.queue.lastOutcome, .noSpeech(folder: folder.standardizedFileURL))
        XCTAssertEqual(read.get(), ["16000", "16000"], "both tracks were transcribed before compression")
    }

    /// AirPods in headset mode: both tracks at the shared 24 kHz clock go the
    /// whole way, read for the transcription at their own rate and compressed
    /// sample for sample at it.
    func testHeadsetRateMeetingIsTranscribedThenCompressedAtItsRate() async throws {
        let read = Locked<[String]>([])
        let setup = makeRecorder(afterStop: .transcribe, rate: 24_000, detector: { source in
            read.mutate { $0.append("\(source.sampleCount)") }
            return []
        })

        try await record(setup.recorder)
        let folder = CompressibleMeetingCapture.folder(1, in: root)
        let done = await eventually { self.isCompressed(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(setup.queue.issues, [:])
        XCTAssertEqual(read.get(), ["16000", "16000"], "one second of each track, at 16 kHz for the models")
        for name in ["microphone.m4a", "system.m4a"] {
            let format = try MeetingAudio.dataFormat(of: folder.appendingPathComponent(name))
            XCTAssertEqual(format.mFormatID, kAudioFormatAppleLossless, name)
            XCTAssertEqual(format.mSampleRate, 24_000, name)
        }
        // The first stop's system track, as the capture made it.
        let system = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 51)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("system.m4a"), equals: [system], gain: 1)
    }

    /// The junction "dropout → queue": a recording that skipped a moment when
    /// the headset dropped out is saved with its warning and transcribed and
    /// compressed like any saved one (live, it failed and waited for a
    /// manual "Transcribe Meeting…").
    func testRecordingWithADropoutIsTranscribedAndKeepsItsWarning() async throws {
        let read = Locked<[String]>([])
        let folder = root.appendingPathComponent("2026-10-10 16-27-43 Meeting", isDirectory: true)
        let setup = makeRecorder(
            afterStop: .transcribe,
            capture: AdoptedMeetingCapture(directory: folder, cycles: AdoptedMeetingCapture.dropout),
            detector: { source in
                read.mutate { $0.append("\(source.sampleCount)") }
                return []
            }
        )

        try await record(setup.recorder)
        let done = await eventually { self.isCompressed(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(setup.transcriptions.value, 1)
        XCTAssertEqual(read.get(), ["6400", "6400"], "both tracks, 0.4 s at 16 kHz")
        let warning = try XCTUnwrap(setup.recorder.recordingWarning)
        XCTAssertEqual(warning.directory.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(warning.issues.count, 1, "\(warning.issues)")
    }

    /// The junction "silent microphone → queue": a recording whose microphone
    /// sent only exact zeros for a while is saved with its warning, and
    /// transcribed and compressed like any saved one.
    func testRecordingWithASilentMicrophoneIsTranscribedAndKeepsItsWarning() async throws {
        let read = Locked<[String]>([])
        let folder = root.appendingPathComponent("2026-10-10 18-41-46 Meeting", isDirectory: true)
        let setup = makeRecorder(
            afterStop: .transcribe,
            capture: AdoptedMeetingCapture(
                directory: folder,
                cycles: IOProcCycle.steady(1) + IOProcCycle.steady(11, microphone: 0),
                elapsed: 12
            ),
            detector: { source in
                read.mutate { $0.append("\(source.sampleCount)") }
                return []
            }
        )

        try await record(setup.recorder)
        let done = await eventually { self.isCompressed(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(setup.transcriptions.value, 1)
        XCTAssertEqual(read.get(), ["192000", "192000"], "both tracks, 12 s at 16 kHz")
        let warning = try XCTUnwrap(setup.recorder.recordingWarning)
        XCTAssertEqual(warning.directory.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(
            warning.issues,
            ["The microphone sent only silence for 0:11 between 0:01 and 0:12: it was muted or taken by another device"]
        )
    }

    func testStoppingTheTranscriptionStillCompressesTheFolder() async throws {
        let entered = Counter()
        let setup = makeRecorder(afterStop: .transcribe, detector: { _ in
            entered.increment()
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        })

        try await record(setup.recorder)
        let running = await eventually { entered.value == 1 && setup.queue.isTranscribing }
        XCTAssertTrue(running)
        setup.queue.cancelCurrent()
        let folder = CompressibleMeetingCapture.folder(1, in: root)
        let done = await eventually { self.isCompressed(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(setup.queue.lastOutcome, .cancelled(folder: folder.standardizedFileURL))
        XCTAssertFalse(setup.queue.isTranscribing)
    }

    /// The recording in progress has no `metadata.json` yet: a scan passes it
    /// by. While the recorder is starting or stopping a scan does nothing.
    func testScanSkipsTheRecordingInProgressAndWaitsWhileTheRecorderIsBusy() async throws {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 1)]
        let inProgress = root.appendingPathComponent("2026-10-06 17-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: inProgress, withIntermediateDirectories: true)
        try MeetingAudio.write(samples, to: inProgress.appendingPathComponent("system.caf"))
        try MeetingAudio.write(samples, to: inProgress.appendingPathComponent("microphone.caf"))
        let finished = try MeetingAudio.folder("2026-10-06 17-00-01 Meeting", in: root, microphone: samples, system: samples)
        let before = try MeetingAudio.digests(of: inProgress)
        let queue = makeQueue(detector: nil, transcriptions: Counter())
        let busy = Locked(true)
        queue.isRecorderBusy = { busy.get() }

        queue.scanLocalFolders()
        let touched = await eventually(within: .milliseconds(500)) { queue.finishedJobs > 0 }
        XCTAssertFalse(touched, "a busy recorder holds the scan")
        XCTAssertFalse(isCompressed(finished))

        busy.mutate { $0 = false }
        queue.scanLocalFolders()
        let done = await eventually { self.isCompressed(finished) && queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(queue.finishedJobs, 1)
        XCTAssertEqual(try MeetingAudio.digests(of: inProgress), before)
    }

    /// Launch: old folders, including one a quit-time stop left, are found.
    func testActivationCompressesFoldersLeftFromBefore() async throws {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 2)]
        let old = try MeetingAudio.folder("2026-08-27 10-31-15 Meeting", in: root, microphone: samples, system: samples)

        let setup = makeRecorder(afterStop: .transcribe)
        let done = await eventually { self.isCompressed(old) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(setup.transcriptions.value, 0, "a scan never transcribes")
    }

    /// Killed after the last commit, before the CAF it replaced was removed:
    /// the metadata names only m4a. The launch scan still finds the CAF left
    /// beside its m4a and removes it, with no meetings folder chosen.
    func testActivationRemovesACAFLeftAfterTheLastCommit() async throws {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 5)]
        let folder = try MeetingAudio.folder("2026-10-06 20-00-00 Meeting", in: root, microphone: samples, system: samples)
        _ = await MeetingStorage.compress(folder)
        try MeetingAudio.write(samples, to: folder.appendingPathComponent("microphone.caf"))
        let compressed = try Data(contentsOf: folder.appendingPathComponent("microphone.m4a"))
        let queue = makeQueue(detector: nil, transcriptions: Counter())

        queue.activate()
        let done = await eventually { self.isCompressed(folder) && queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            ["metadata.json", "microphone.m4a", "system.m4a"]
        )
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("microphone.m4a")), compressed)
    }

    /// A scan may queue a folder first; the user's request to transcribe it
    /// afterwards must not be swallowed as a duplicate.
    func testTranscriptionAskedForAfterAScanQueuedTheFolderIsKept() async throws {
        let release = Counter()
        let transcriptions = Counter()
        let queue = makeQueue(detector: { _ in
            while release.value == 0 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            return []
        }, transcriptions: transcriptions)
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 3)]
        let first = try MeetingAudio.folder("2026-10-06 18-00-00 Meeting", in: root, microphone: samples, system: samples)
        let second = try MeetingAudio.folder("2026-10-06 18-00-01 Meeting", in: root, microphone: samples, system: samples)

        queue.enqueue(first)
        queue.enqueue(second, transcribe: false)
        queue.enqueue(second, transcribe: false)
        queue.enqueue(second)
        XCTAssertEqual(queue.pending, [.init(folder: second.standardizedFileURL, transcribe: true)])
        release.increment()
        let done = await eventually { queue.activeFolder == nil && queue.pending.isEmpty }

        XCTAssertTrue(done)
        XCTAssertEqual(transcriptions.value, 2)
        XCTAssertTrue(isCompressed(first))
        XCTAssertTrue(isCompressed(second))
    }

    func testFolderOutsideTheMeetingsRootIsOnlyTranscribed() async throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 4)]
        let folder = try MeetingAudio.folder("2026-10-06 19-00-00 Meeting", in: elsewhere, microphone: samples, system: samples)
        let transcriptions = Counter()
        let queue = makeQueue(detector: nil, transcriptions: transcriptions)

        queue.enqueue(folder)
        let done = await eventually { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(transcriptions.value, 1)
        XCTAssertFalse(isCompressed(folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))
    }

    // MARK: - Helpers

    private func isCompressed(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains("microphone.m4a") && names.contains("system.m4a")
            && !names.contains { $0.hasSuffix(".caf") }
    }

    private func makeQueue(
        detector: MeetingTranscriber.SpeechDetector?,
        transcriptions: Counter
    ) -> MeetingTranscriptionQueue {
        MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: SilentEngineFactory()),
                loadSpeechDetector: {
                    transcriptions.increment()
                    return detector ?? { _ in [] }
                },
                currentEngine: { throw TranscriptionError.engineUnavailable("not used: no speech") },
                temporaryRoot: root
            ),
            meetingsRoot: root
        )
    }

    private func makeRecorder(
        afterStop: MeetingAfterStop,
        rate: Double = 48_000,
        capture: (any MeetingCaptureBackend)? = nil,
        detector: MeetingTranscriber.SpeechDetector? = nil
    ) -> (recorder: MeetingRecorder, queue: MeetingTranscriptionQueue, transcriptions: Counter, settings: SettingsStore) {
        let transcriptions = Counter()
        let queue = makeQueue(detector: detector, transcriptions: transcriptions)
        let settings = SettingsStore(defaults: defaults)
        settings.meetingAfterStop = afterStop
        let recorder = MeetingRecorder(
            capture: capture ?? CompressibleMeetingCapture(root: root, rate: rate),
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
            dictation: DictationCoordinator(mic: QuietMic(), indicator: RecordingIndicator(renderingEnabled: false))
        )
        return (recorder, queue, transcriptions, settings)
    }

    private func record(_ recorder: MeetingRecorder) async throws {
        recorder.toggle()
        let started = await eventually { recorder.state == .recording }
        XCTAssertTrue(started)
        recorder.toggle()
        let stopped = await eventually { recorder.state == .idle }
        XCTAssertTrue(stopped)
    }

    /// Polls with a deadline, so a wedged queue fails instead of hanging the run.
    private func eventually(
        within limit: Duration = .seconds(10),
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

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}
