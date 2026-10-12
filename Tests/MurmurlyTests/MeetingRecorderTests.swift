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

    func start() async throws -> Date {
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
        XCTAssertNil(try metadata(in: directory).trigger)
        let calls = await capture.counts()
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)
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
        let menu = NSHostingMenu(rootView: DictationMenuView(
            dictation: DictationCoordinator(
                mic: TestMeetingMic(), indicator: RecordingIndicator(renderingEnabled: false), models: models
            ),
            meeting: recorder,
            meetingTranscripts: MeetingTranscriptionQueue(transcriber: .live(settings: settings, models: models)),
            permissions: PermissionManager(),
            settings: settings,
            models: models,
            updater: AppUpdater(busy: Just(false))
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
