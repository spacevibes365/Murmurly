import AppKit
import XCTest
@testable import Murmurly

/// A recording that starts and stops instantly, so these tests only need to
/// wait for `MeetingRecorder.state` to move.
private actor FakeLiveTranscriptCapture: MeetingCaptureBackend {
    private let tracks: [URL]

    init(tracks: [URL]) {
        self.tracks = tracks
    }

    func start(in directory: URL) async throws -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000)
    }

    func stop() async throws -> [URL] {
        if let directory = tracks.first?.deletingLastPathComponent() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metadata = MeetingMetadata(
                startedAt: "2026-08-07T10:00:00Z",
                endedAt: "2026-08-07T11:00:00Z",
                sampleRate: 48_000,
                state: "done",
                segments: []
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: directory.appendingPathComponent("metadata.json"))
        }
        return tracks
    }
}

private struct FakeLiveTranscriptMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

@MainActor
final class LiveTranscriptPanelTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func isolatedSettings() throws -> SettingsStore {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.LiveTranscriptPanel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return SettingsStore(defaults: defaults)
    }

    private func recorder(tracksIn directory: URL) -> MeetingRecorder {
        MeetingRecorder(
            capture: FakeLiveTranscriptCapture(tracks: [directory.appendingPathComponent("system.caf")]),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
    }

    private func activate(_ recorder: MeetingRecorder, settings: SettingsStore) {
        let dictation = DictationCoordinator(
            mic: FakeLiveTranscriptMic(),
            indicator: RecordingIndicator(renderingEnabled: false)
        )
        recorder.activate(settings: settings, permissions: PermissionManager(), dictation: dictation)
    }

    private func wait(_ recorder: MeetingRecorder, for state: MeetingRecorder.State) async throws {
        for _ in 0..<100 where recorder.state != state { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, state)
    }

    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    // MARK: - The panel itself

    /// A paste must never land in it, and `AppWindowController` must never
    /// count it among real windows (or the Dock icon would appear while a
    /// meeting records).
    func testPanelNeverBecomesKeyOrMainAndIsNotARealWindow() throws {
        let transcript = LiveTranscriptPanel(forPanelTestingOnly: ())
        transcript.buildPanelForTesting()
        let panel = try XCTUnwrap(transcript.panelForTesting)

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(AppWindowController.isRealWindow(panel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    // MARK: - Settings

    func testLiveTranscriptSettingDefaultsOnAndWritesNothing() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.LiveTranscriptDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        XCTAssertTrue(settings.liveTranscript)
        XCTAssertNil(defaults.object(forKey: "meeting.liveTranscript"))
    }

    func testDisabledSettingKeepsTheRecorderFromMakingAModel() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        settings.liveTranscript = false
        let recorder = recorder(tracksIn: directory)
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)

        XCTAssertNil(recorder.liveTranscriptModel)
        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    // MARK: - Lifecycle: stop hides it, ✕ hides it for the session, a new
    // recording and the menu bring it back.

    func testStopHidesCloseHidesForTheSessionAndANewRecordingShowsAgain() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(tracksIn: directory)
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        XCTAssertFalse(panel.isShown)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }

        // The ✕ button: hidden until this recording ends.
        panel.hideForThisRecording()
        XCTAssertFalse(panel.isShown)

        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertFalse(panel.isShown)

        // A new recording resets the ✕ dismissal.
        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }

        // Stopping hides it again, without the ✕.
        recorder.toggle()
        try await wait(recorder, for: .idle)
        XCTAssertFalse(panel.isShown)
    }

    func testShowBringsBackAPanelHiddenByTheCloseButton() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(tracksIn: directory)
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }

        panel.hideForThisRecording()
        XCTAssertFalse(panel.isShown)
        XCTAssertTrue(panel.canReopen, "the menu offers the panel back only after the ✕")

        // With the setting turned off mid-recording, the menu item would show
        // nothing, so it is not offered; turned back on, it is again.
        settings.liveTranscript = false
        XCTAssertFalse(panel.canReopen)
        settings.liveTranscript = true
        XCTAssertTrue(panel.canReopen)

        // "Show Live Transcript" in the menu.
        panel.show()
        XCTAssertTrue(panel.isShown)
        XCTAssertFalse(panel.canReopen)

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    // MARK: - The setting is followed live, mid-recording

    func testTogglingTheSettingMidRecordingHidesAndShowsThePanelAtOnce() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(tracksIn: directory)
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }

        settings.liveTranscript = false
        XCTAssertFalse(panel.isShown)

        settings.liveTranscript = true
        XCTAssertTrue(panel.isShown)

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    // MARK: - The ✕ resets only on a genuinely new model, by identity

    func testCloseButtonStaysDismissedOnARepublishOfTheSameModel() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(tracksIn: directory)
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }

        panel.hideForThisRecording()
        XCTAssertFalse(panel.isShown)

        // The very same model object, republished (as a later state change
        // during the same recording would do): the ✕ must stay in effect.
        recorder.publishLiveTranscriptForTesting(state: .recording, model: recorder.liveTranscriptModel)
        XCTAssertFalse(panel.isShown)

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }
}
