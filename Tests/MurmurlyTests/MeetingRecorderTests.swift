import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import Murmurly

private actor TestMeetingCapture: MeetingCaptureBackend {
    enum StartMode: Equatable, Sendable { case success, cancelOnce }
    enum StopMode: Equatable, Sendable { case success, partialFailure }
    private let tracks: [URL]
    private let startMode: StartMode
    private let stopMode: StopMode
    private let startedAt: Date
    private var startCalls = 0
    private var stopCalls = 0

    init(
        tracks: [URL], startMode: StartMode = .success,
        stopMode: StopMode = .success,
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) {
        self.tracks = tracks
        self.startMode = startMode
        self.stopMode = stopMode
        self.startedAt = startedAt
    }

    func start(in _: URL) async throws -> Date {
        startCalls += 1
        if startMode == .cancelOnce, startCalls == 1 { throw CancellationError() }
        return startedAt
    }

    func stop() async throws -> [URL] {
        stopCalls += 1
        if let directory = tracks.first?.deletingLastPathComponent() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metadata = MeetingMetadata(
                startedAt: "2026-08-07T10:00:00Z",
                endedAt: "2026-08-07T11:00:00Z",
                sampleRate: 48_000,
                state: stopMode == .success ? "done" : "failed",
                segments: []
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: directory.appendingPathComponent("metadata.json"))
            if stopMode == .partialFailure {
                throw SystemAudioCaptureError.captureFailed(message: "partial", savedAt: directory)
            }
        }
        return tracks
    }

    func counts() -> (starts: Int, stops: Int) { (startCalls, stopCalls) }
}

/// Records into the folder the recorder made, as the real backend does: the
/// tracks appear as the capture starts, `metadata.json` only at the stop. It
/// can hold its start until the test lets it go, or refuse it.
private actor FolderCapture: MeetingCaptureBackend {
    static let startedAt = Date(timeIntervalSinceReferenceDate: 5_000)
    private(set) var given: URL?
    private var holding: Bool
    private let refuses: Bool
    private var directory: URL?

    init(holdsStart: Bool = false, refuses: Bool = false) {
        holding = holdsStart
        self.refuses = refuses
    }

    func release() { holding = false }

    func start(in directory: URL) async throws -> Date {
        given = directory
        while holding { try await Task.sleep(for: .milliseconds(5)) }
        if refuses { throw SystemAudioCaptureError.microphoneUnavailable }
        for name in ["system.caf", "microphone.caf"] {
            try MeetingAudio.write([[Float](repeating: 0, count: 4_800)], to: directory.appendingPathComponent(name))
        }
        self.directory = directory
        return Self.startedAt
    }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        self.directory = nil
        let metadata = MeetingMetadata(
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:00Z",
            sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

private actor TestMeetingMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

@MainActor
private final class TestSnapshotSource {
    var value: [MeetingWatchdog.ProcessSnapshot]
    init(_ value: [MeetingWatchdog.ProcessSnapshot]) { self.value = value }
}

@MainActor
private final class MeetingBeepProbe {
    var count = 0
    func play() { count += 1 }
}

@MainActor
final class MeetingRecorderTests: XCTestCase {
    private typealias Snapshot = MeetingWatchdog.ProcessSnapshot
    private let holder = Snapshot(pid: 42, bundleID: "company.call", isRunningInput: true)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func recorder(
        _ capture: TestMeetingCapture,
        snapshots: @escaping MeetingWatchdog.SnapshotSource = { [] },
        indicator: RecordingIndicator? = nil,
        beepPlayer: @escaping @MainActor @Sendable () -> Void = {}
    ) -> MeetingRecorder {
        MeetingRecorder(
            capture: capture,
            indicator: indicator ?? RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: snapshots,
            beepPlayer: beepPlayer
        )
    }

    /// A recorder whose sessions are made in `root`, as the app makes them.
    private func folderRecorder(_ capture: FolderCapture, root: URL) -> MeetingRecorder {
        MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { try RecordingsStore().createSession(root: root) }
        )
    }

    /// A settings store of its own; an absolute suite path keeps its file in `root`.
    private func isolatedSettings(in root: URL) throws -> SettingsStore {
        SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
    }

    private func waitUntilCapture(_ capture: FolderCapture, given: @Sendable (URL?) -> Bool) async throws {
        for _ in 0..<100 {
            if given(await capture.given) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the capture was not given the session's folder")
    }

    private func waitUntil(_ done: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done())
    }

    private func wait(_ recorder: MeetingRecorder, for state: MeetingRecorder.State) async throws {
        try await waitUntil { recorder.state == state }
    }

    private func wait(_ capture: TestMeetingCapture, forStarts expected: Int) async throws {
        for _ in 0..<100 {
            if await capture.counts().starts >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(expected) capture starts")
    }

    private func assertCounts(
        _ capture: TestMeetingCapture, starts: Int? = nil, stops: Int? = nil
    ) async {
        let counts = await capture.counts()
        if let starts { XCTAssertEqual(counts.starts, starts) }
        if let stops { XCTAssertEqual(counts.stops, stops) }
    }

    private func metadata(in directory: URL) throws -> MeetingMetadata {
        try JSONDecoder().decode(
            MeetingMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        )
    }

    private func activate(
        _ recorder: MeetingRecorder,
        dictation: DictationCoordinator? = nil,
        settings: SettingsStore = SettingsStore()
    ) {
        let dictation = dictation ?? DictationCoordinator(
            mic: TestMeetingMic(),
            indicator: RecordingIndicator(renderingEnabled: false)
        )
        recorder.activate(
            settings: settings, permissions: PermissionManager(), dictation: dictation
        )
    }

    func testStartStopAndExposeSavedDirectory() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let capture = TestMeetingCapture(
            tracks: [directory.appendingPathComponent("system.caf")],
            startedAt: startedAt
        )
        let indicator = RecordingIndicator(renderingEnabled: false)
        let recorder = recorder(capture, indicator: indicator)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        XCTAssertEqual(
            indicator.presentedState,
            .recordingMeeting(startedAt: startedAt, automatic: false)
        )
        XCTAssertNil(indicator.presentedState?.meetingExplanation)
        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertEqual(recorder.lastRecordingDirectory?.path, directory.path)
        XCTAssertEqual(try metadata(in: directory).trigger, "manual", "a recording started by hand says so")
        let calls = await capture.counts()
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)
    }

    // MARK: - The session's folder

    /// The recorder makes the folder before it awaits the start, so a folder
    /// without metadata is known to be this recording from its first moment,
    /// not taken for one that broke off.
    func testSessionFolderIsKnownFromTheFirstMomentOfStarting() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FolderCapture(holdsStart: true)
        let recorder = folderRecorder(capture, root: root)

        recorder.toggle()

        XCTAssertEqual(recorder.state, .starting)
        let session = try XCTUnwrap(recorder.currentSession, "no session while the start is awaited")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path), "the folder is made before the start")
        XCTAssertEqual(session.directory.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertNil(session.startedAt)
        XCTAssertNil(session.trigger)
        try await waitUntilCapture(capture) { $0 == session.directory }

        await capture.release()
        try await wait(recorder, for: .recording)
        XCTAssertEqual(recorder.currentSession?.directory, session.directory)
        XCTAssertEqual(recorder.currentSession?.startedAt, FolderCapture.startedAt)

        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertNil(recorder.currentSession)
        XCTAssertEqual(recorder.lastRecordingDirectory?.path, session.directory.path)
        XCTAssertEqual(try metadata(in: session.directory).trigger, "manual")
    }

    /// The session ends only once the stop's result is out: the folder has
    /// its metadata, the recorder its last recording, and the queue its job,
    /// so the window goes from the live row straight to the queued meeting.
    func testSessionEndsOnlyOnceTheStopIsPublished() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try isolatedSettings(in: root)
        settings.meetingAfterStop = .transcribe
        let queue = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: ConstantEngineFactory()),
                loadSpeechDetector: { _ in { _ in [] } },
                currentEngine: { _ in throw TranscriptionError.engineUnavailable("not used: no speech") },
                temporaryRoot: root
            ),
            meetingsRoot: root
        )
        let recorder = folderRecorder(FolderCapture(), root: root)
        recorder.transcripts = queue
        activate(recorder, settings: settings)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        let session = try XCTUnwrap(recorder.currentSession)
        var atEnd: (state: MeetingRecorder.State, last: URL?, metadata: Bool, jobs: [URL])?
        // `@Published` sends before the property changes: what is read here
        // is everything published before the session ends.
        let watch = recorder.$currentSession.dropFirst().sink { value in
            guard value == nil, atEnd == nil else { return }
            atEnd = (
                recorder.state,
                recorder.lastRecordingDirectory,
                FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("metadata.json").path),
                (queue.pending.map(\.folder) + [queue.activeJob?.folder].compactMap { $0 }).map(\.standardizedFileURL)
            )
        }
        defer { watch.cancel() }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let end = try XCTUnwrap(atEnd, "the session never ended")
        XCTAssertEqual(end.state, .idle)
        XCTAssertEqual(end.last?.path, session.directory.path)
        XCTAssertTrue(end.metadata, "the session ended before its metadata was written")
        XCTAssertTrue(end.jobs.contains(session.directory.standardizedFileURL), "the session ended before the job was queued")
        try await waitUntil { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// A start that never runs leaves no session behind: a capture that
    /// refuses, and a folder that cannot be made, which no capture is asked
    /// to record into.
    func testFailedStartEndsTheSession() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let refusing = folderRecorder(FolderCapture(refuses: true), root: root)
        refusing.toggle()
        XCTAssertNotNil(refusing.currentSession)
        try await waitUntil { if case .failed = refusing.state { true } else { false } }
        XCTAssertNil(refusing.currentSession)

        let capture = FolderCapture()
        let noFolder = MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { throw CocoaError(.fileWriteNoPermission) }
        )
        noFolder.toggle()
        guard case .failed = noFolder.state else { return XCTFail("state \(noFolder.state)") }
        XCTAssertNil(noFolder.currentSession)
        let given = await capture.given
        XCTAssertNil(given, "the capture was started without a folder")
    }

    func testMissingMicrophonePermissionDoesNotStartBackend() async {
        let capture = TestMeetingCapture(tracks: [])
        let recorder = MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { false },
            permissionPromptDelay: .zero
        )
        recorder.toggle()
        XCTAssertEqual(recorder.state, .idle)
        let calls = await capture.counts()
        XCTAssertEqual(calls.starts, 0)
        XCTAssertEqual(calls.stops, 0)
    }

    func testQuickManualStopOfAutomaticRecordingDoesNotRestart() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = TestMeetingCapture(tracks: [directory.appendingPathComponent("system.caf")])
        let recorder = recorder(capture, snapshots: { [self.holder] })
        activate(recorder)
        try await wait(recorder, for: .recording)
        recorder.toggle()
        try await wait(recorder, for: .idle)
        recorder.tickWatchdogForTesting(now: Date(timeIntervalSince1970: 1))
        recorder.tickWatchdogForTesting(now: Date(timeIntervalSince1970: 2))
        await assertCounts(capture, starts: 1)
        XCTAssertEqual(try metadata(in: directory).trigger, "company.call")
    }

    func testAutomaticRecordingStartsAndStopsAfterHysteresis() async throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        let capture = TestMeetingCapture(tracks: [], startedAt: startedAt)
        let snapshots = TestSnapshotSource([holder])
        let indicator = RecordingIndicator(renderingEnabled: false)
        let recorder = recorder(
            capture,
            snapshots: { snapshots.value },
            indicator: indicator
        )
        activate(recorder)
        try await wait(recorder, for: .recording)
        XCTAssertEqual(
            indicator.presentedState,
            .recordingMeeting(startedAt: startedAt, automatic: true)
        )
        XCTAssertEqual(
            indicator.presentedState?.meetingExplanation?.hasPrefix("Looks like a meeting · "),
            true
        )
        snapshots.value = []
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.tickWatchdogForTesting(now: now)
        recorder.tickWatchdogForTesting(now: now.addingTimeInterval(30))
        try await wait(recorder, for: .idle)
        let calls = await capture.counts()
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)
    }

    func testBusyDictationDefersAutomaticStartUntilNextTick() async throws {
        let capture = TestMeetingCapture(tracks: [])
        let recorder = recorder(capture, snapshots: { [self.holder] })
        let dictation = DictationCoordinator(
            mic: TestMeetingMic(),
            indicator: RecordingIndicator(renderingEnabled: false)
        )
        dictation.beginCaptureForTesting()
        try await waitUntil { dictation.state == .recording }
        activate(recorder, dictation: dictation)
        await assertCounts(capture, starts: 0)
        dictation.toggle()
        try await waitUntil { dictation.state == .idle }
        recorder.tickWatchdogForTesting(now: Date())
        try await wait(recorder, for: .recording)
        await assertCounts(capture, starts: 1)
        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    func testCancelledAutomaticStartRetriesOnNextTick() async throws {
        let capture = TestMeetingCapture(tracks: [], startMode: .cancelOnce)
        let recorder = recorder(capture, snapshots: { [self.holder] })
        activate(recorder)
        try await wait(capture, forStarts: 1)
        try await wait(recorder, for: .idle)

        recorder.tickWatchdogForTesting(now: Date())
        try await wait(recorder, for: .recording)
        await assertCounts(capture, starts: 2)
        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    func testManualRecordingAfterCancelledAutomaticStartIsNotAutoStopped() async throws {
        let capture = TestMeetingCapture(tracks: [], startMode: .cancelOnce)
        let snapshots = TestSnapshotSource([holder])
        let recorder = recorder(capture, snapshots: { snapshots.value })
        activate(recorder)
        try await wait(capture, forStarts: 1)
        try await wait(recorder, for: .idle)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        snapshots.value = []
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.tickWatchdogForTesting(now: now)
        recorder.tickWatchdogForTesting(now: now.addingTimeInterval(30))
        XCTAssertEqual(recorder.state, .recording)
        await assertCounts(capture, stops: 1)
        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    func testAutomaticTriggerSurvivesPartialStopFailure() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = TestMeetingCapture(
            tracks: [directory.appendingPathComponent("system.caf")], stopMode: .partialFailure
        )
        let recorder = recorder(capture, snapshots: { [self.holder] })
        activate(recorder)
        try await wait(recorder, for: .recording)
        recorder.toggle()
        try await waitUntil { !recorder.isBusy }
        XCTAssertEqual(try metadata(in: directory).trigger, "company.call")
        XCTAssertEqual(recorder.lastRecordingDirectory?.path, directory.path)
    }

    func testSleepStopsManualRecording() async throws {
        let capture = TestMeetingCapture(tracks: [])
        let recorder = recorder(capture)
        activate(recorder)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification, object: nil
        )
        try await wait(recorder, for: .idle)
        await assertCounts(capture, stops: 1)
    }

    func testSoundParentBlocksBothMeetingBeeps() async throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.MeetingSounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.soundsEnabled = false
        let probe = MeetingBeepProbe()
        let capture = TestMeetingCapture(tracks: [])
        let recorder = recorder(capture, beepPlayer: { probe.play() })
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertEqual(probe.count, 0)

        settings.soundsEnabled = true
        recorder.toggle()
        try await wait(recorder, for: .recording)
        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertEqual(probe.count, 2)
    }

    /// The menu as AppKit receives it from SwiftUI: a state is marked by the
    /// item's image, not by an emoji or a glyph in the title, so the title is
    /// the translated text alone.
    func testMenuMarksMeetingStatesWithSymbolsNotEmoji() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = recorder(TestMeetingCapture(tracks: [directory.appendingPathComponent("system.caf")]))
        let settings = SettingsStore()
        let models = ModelDownloader(root: directory.appendingPathComponent("Models"))
        let queue = MeetingTranscriptionQueue(transcriber: .live(settings: settings, models: models))
        let menu = NSHostingMenu(rootView: DictationMenuView(
            dictation: DictationCoordinator(
                mic: TestMeetingMic(), indicator: RecordingIndicator(renderingEnabled: false), models: models
            ),
            meeting: recorder,
            meetingTranscripts: queue,
            permissions: PermissionManager(),
            settings: settings,
            models: models,
            updater: AppUpdater(busy: Just(false)),
            library: MeetingLibrary(recorder: recorder, queue: queue, settings: settings)
        ))
        // SwiftUI rebuilds the items after a state change on a later turn.
        // A whole word: "Record Meeting" must not find "Record Meetings
        // Automatically".
        func item(_ prefix: String) async throws -> NSMenuItem {
            var found: NSMenuItem?
            for _ in 0..<100 {
                menu.update()
                found = menu.items.first { $0.title == prefix || $0.title.hasPrefix(prefix + " ") }
                if found != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(found, "no “\(prefix)…” among \(menu.items.map(\.title))")
        }
        let emoji = CharacterSet(charactersIn: "\u{1F534}\u{23F3}\u{1F3A4}\u{26A0}\u{25CF}\u{25A0}")
        func assertNoEmoji() {
            for item in menu.items {
                XCTAssertNil(item.title.rangeOfCharacter(from: emoji), "an emoji in “\(item.title)”")
            }
        }

        let open = try await item("Open Murmurly")
        XCTAssertEqual(menu.items.first, open, "the window's item is not the menu's first")
        let record = try await item("Record Meeting")
        XCTAssertNotNil(record.image, "Record Meeting has no symbol")
        assertNoEmoji()

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let recording = try await item("Meeting: recording")
        let stop = try await item("Stop Recording Meeting")
        XCTAssertNotNil(recording.image, "the recording line has no symbol")
        XCTAssertNotNil(stop.image, "Stop Recording Meeting has no symbol")
        assertNoEmoji()

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }
}
