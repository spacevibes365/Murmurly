import AppKit
import CoreGraphics
import XCTest
@testable import Murmurly

/// A recording that starts and stops instantly, so these tests only need to
/// wait for `MeetingRecorder.state` to move.
private actor FakeNotepadCapture: MeetingCaptureBackend {
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

/// A fictional, unrecoverable failure: `savedDirectory` is never offered, so
/// the stop reports `.failed`, never `.saved(warning: true)`.
private struct FictionalStopFailure: Error, LocalizedError {
    var errorDescription: String? { "a fictional stop failure" }
}

private actor FailingNotepadCapture: MeetingCaptureBackend {
    func start(in directory: URL) async throws -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000)
    }

    func stop() async throws -> [URL] {
        throw FictionalStopFailure()
    }
}

private struct FakeNotepadMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

@MainActor
final class NotepadWindowTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func isolatedSettings() throws -> SettingsStore {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.NotepadWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return SettingsStore(defaults: defaults)
    }

    private func recorder(capture: any MeetingCaptureBackend, snapshotSource: @escaping MeetingWatchdog.SnapshotSource = { [] }) -> MeetingRecorder {
        MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: snapshotSource,
            beepPlayer: {}
        )
    }

    private func activate(_ recorder: MeetingRecorder, settings: SettingsStore) {
        let dictation = DictationCoordinator(
            mic: FakeNotepadMic(),
            indicator: RecordingIndicator(renderingEnabled: false)
        )
        recorder.activate(settings: settings, permissions: PermissionManager(), dictation: dictation)
    }

    private func wait(_ recorder: MeetingRecorder, for state: MeetingRecorder.State) async throws {
        for _ in 0..<100 where recorder.state != state { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, state)
    }

    private func waitForFailure(_ recorder: MeetingRecorder) async throws {
        for _ in 0..<100 {
            if case .failed = recorder.state { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the recorder never reached .failed")
    }

    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private static func makeLines() -> [LiveLine] {
        let now = Date.timeIntervalSinceReferenceDate
        return [
            LiveLine(
                id: UUID(), track: .microphone, start: now, end: now + 2,
                rawText: "Let’s check the agenda.", displayText: "Let’s check the agenda.",
                name: nil, isFinal: true
            ),
            LiveLine(
                id: UUID(), track: .system, start: now + 4, end: now + 6,
                rawText: "Sounds good.", displayText: "Sounds good.",
                name: nil, isFinal: true
            )
        ]
    }

    // MARK: - 1. Stop keeps the model's lines and the same meeting

    func testStopKeepsTheModelsLinesAndTheSameMeeting() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(capture: FakeNotepadCapture(tracks: [directory.appendingPathComponent("system.caf")]))
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }
        let lines = Self.makeLines()
        recorder.liveTranscriptModel?.publishForTesting(lines: lines, state: .running)
        let session = try XCTUnwrap(recorder.currentSession)

        recorder.toggle()
        // Synchronous: the snapshot is already in place the moment `state`
        // leaves `.recording`.
        XCTAssertEqual(recorder.state, .stopping)
        XCTAssertEqual(panel.notepad.keptLines, lines)
        XCTAssertNil(panel.notepad.liveModel)
        XCTAssertEqual(panel.notepad.meeting, NotepadMeeting(
            identity: session.identity, folder: session.directory, startedAt: session.startedAt, isRecording: false
        ))
        XCTAssertTrue(panel.isShown)

        try await wait(recorder, for: .idle)
        XCTAssertEqual(panel.notepad.keptLines, lines)
        XCTAssertEqual(recorder.stoppedLiveTranscript?.outcome, .saved(warning: false))
    }

    // MARK: - 2. A stop at the automatic 4-hour limit keeps the lines too

    func testStopAtTheLimitKeepsTheLines() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        MeetingWatchdog.periodicTicksDisabledForTesting = true
        defer { MeetingWatchdog.periodicTicksDisabledForTesting = false }
        let snapshot = [MeetingWatchdog.ProcessSnapshot(pid: 4242, bundleID: "fictional.call", isRunningInput: true)]
        let recorder = recorder(
            capture: FakeNotepadCapture(tracks: [directory.appendingPathComponent("system.caf")]),
            snapshotSource: { snapshot }
        )
        activate(recorder, settings: settings)
        let activatedAt = Date()
        try await wait(recorder, for: .recording)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)
        try await wait { panel.isShown }
        let lines = Self.makeLines()
        recorder.liveTranscriptModel?.publishForTesting(lines: lines, state: .running)

        recorder.tickWatchdogForTesting(now: activatedAt.addingTimeInterval(MeetingWatchdog.maximumAutomaticDuration + 1))
        XCTAssertEqual(recorder.state, .stopping, "an automatic recording stops at the 4-hour limit")
        XCTAssertEqual(panel.notepad.keptLines, lines)
        XCTAssertTrue(panel.isShown)

        try await wait(recorder, for: .idle)
        XCTAssertEqual(recorder.stoppedLiveTranscript?.outcome, .saved(warning: true), "the limit is a warning, not a failure")
    }

    // MARK: - 3. A stop that fails to save still keeps the lines

    func testFailedStopKeepsTheLines() async throws {
        let settings = try isolatedSettings()
        let recorder = recorder(capture: FailingNotepadCapture())
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }
        let lines = Self.makeLines()
        recorder.liveTranscriptModel?.publishForTesting(lines: lines, state: .running)

        recorder.toggle()
        try await waitForFailure(recorder)
        XCTAssertEqual(panel.notepad.keptLines, lines)
        XCTAssertTrue(panel.isShown)
        guard case let .failed(reason)? = recorder.stoppedLiveTranscript?.outcome else {
            return XCTFail("expected the notepad's snapshot to carry a failed outcome")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - 4. A new recording moves the notepad to the new meeting

    func testANewRecordingMovesTheWindowToTheNewMeeting() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(capture: FakeNotepadCapture(tracks: [directory.appendingPathComponent("system.caf")]))
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }
        let firstFolder = panel.notepad.meeting?.folder
        recorder.toggle()
        try await wait(recorder, for: .idle)

        panel.notepad.notes = [MeetingNote(id: UUID(), t: nil, kind: .note, text: "A fictional note.")]
        panel.notepad.searchQuery = "fictional"

        recorder.toggle()
        try await wait(recorder, for: .recording)

        XCTAssertNotEqual(panel.notepad.meeting?.folder, firstFolder)
        XCTAssertEqual(panel.notepad.meeting?.isRecording, true)
        XCTAssertNotNil(panel.notepad.liveModel)
        XCTAssertTrue(panel.notepad.keptLines.isEmpty)
        XCTAssertTrue(panel.notepad.notes.isEmpty)
        XCTAssertTrue(panel.notepad.searchQuery.isEmpty)

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    // MARK: - 5. Close after the stop closes it; the menu brings back the last meeting

    func testCloseAfterStopClosesAndShowBringsBackTheLastMeeting() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try isolatedSettings()
        let recorder = recorder(capture: FakeNotepadCapture(tracks: [directory.appendingPathComponent("system.caf")]))
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        try await wait { panel.isShown }
        let lines = Self.makeLines()
        recorder.liveTranscriptModel?.publishForTesting(lines: lines, state: .running)
        recorder.toggle()
        try await wait(recorder, for: .idle)
        let folder = panel.notepad.meeting?.folder

        panel.close()
        XCTAssertFalse(panel.isShown)
        XCTAssertTrue(panel.canReopen)

        panel.show()
        XCTAssertTrue(panel.isShown)
        XCTAssertTrue(panel.canReopen, "the menu item stays offered while shown, to raise it over another window")
        XCTAssertEqual(panel.notepad.meeting?.folder, folder)
        XCTAssertEqual(panel.notepad.keptLines, lines)

        settings.liveTranscript = false
        XCTAssertFalse(panel.isShown)
        XCTAssertFalse(panel.canReopen)
        settings.liveTranscript = true
    }

    // MARK: - 6. The pin switches the level and the Spaces behavior, off by default

    func testKeepOnTopSwitchesLevelAndSpacesAndDefaultsOffWithoutWriting() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.NotepadWindowPin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let recorder = recorder(capture: FakeNotepadCapture(tracks: [directory().appendingPathComponent("system.caf")]))
        activate(recorder, settings: settings)
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: true)
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting)

        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.notepad.isPinned)
        XCTAssertNil(defaults.object(forKey: "liveTranscript.keepOnTop"), "reading the pin's default must not write it")

        settings.liveTranscriptKeepOnTop = true
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.notepad.isPinned)

        settings.liveTranscriptKeepOnTop = false
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.notepad.isPinned)
    }

    // MARK: - 7. The stopped status follows the recorder's outcome and the queue

    func testStoppedStatusFollowsTheRecorderAndTheQueue() {
        XCTAssertEqual(
            NotepadStatusView.stoppedText(outcome: .saving, step: nil, isQueued: false),
            String(localized: "Saving the recording…")
        )
        let reason = "a fictional stop failure"
        XCTAssertEqual(
            NotepadStatusView.stoppedText(outcome: .failed(reason), step: nil, isQueued: false),
            String(localized: "Stopped: \(reason)")
        )
        XCTAssertEqual(
            NotepadStatusView.stoppedText(
                outcome: .saved(warning: false), step: "Transcribing the meeting…", isQueued: false
            ),
            "Transcribing the meeting…"
        )
        XCTAssertEqual(
            NotepadStatusView.stoppedText(outcome: .saved(warning: false), step: nil, isQueued: true),
            String(localized: "Waiting to be transcribed")
        )
        XCTAssertEqual(
            NotepadStatusView.stoppedText(outcome: .saved(warning: true), step: nil, isQueued: false),
            String(localized: "Meeting saved with a warning — details in the “M” menu")
        )
        XCTAssertEqual(
            NotepadStatusView.stoppedText(outcome: .saved(warning: false), step: nil, isQueued: false),
            String(localized: "Meeting saved")
        )
    }

    // MARK: - 8. A line's time is clickable only once the recording is saved

    func testTimeIsClickableOnlyOnceTheRecordingIsSaved() {
        let liveMeeting = NotepadMeeting(
            identity: nil, folder: URL(fileURLWithPath: "/tmp/fictional-meeting"), startedAt: nil, isRecording: true
        )
        let savedMeeting = NotepadMeeting(
            identity: nil, folder: URL(fileURLWithPath: "/tmp/fictional-meeting"), startedAt: nil, isRecording: false
        )
        XCTAssertFalse(NotepadTimeButton.isAvailable(recorder: .idle, meeting: nil))
        XCTAssertFalse(NotepadTimeButton.isAvailable(recorder: .recording, meeting: liveMeeting))
        XCTAssertFalse(NotepadTimeButton.isAvailable(recorder: .starting, meeting: savedMeeting))
        XCTAssertFalse(NotepadTimeButton.isAvailable(recorder: .recording, meeting: savedMeeting))
        XCTAssertFalse(NotepadTimeButton.isAvailable(recorder: .stopping, meeting: savedMeeting))
        XCTAssertTrue(NotepadTimeButton.isAvailable(recorder: .idle, meeting: savedMeeting))
        XCTAssertTrue(NotepadTimeButton.isAvailable(recorder: .failed("fictional"), meeting: savedMeeting))
    }

    // MARK: - 9. The window maps the editing shortcuts itself, by key code

    func testWindowHandlesEditingShortcutsItself() throws {
        let window = NotepadNSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = "abc"
        window.contentView = textView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func selectAllEvent(characters: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            ))
        }

        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.performKeyEquivalent(with: try selectAllEvent(characters: "a")))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 3))

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // The physical A key on a Russian layout, so the fix must key off
        // `keyCode`, not the character.
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.performKeyEquivalent(with: try selectAllEvent(characters: "ф")))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 3))
    }

    /// ⌘W reaches `performClose` through the window's own key-code mapping,
    /// not through a main menu item (there is none to send it while another
    /// app is active): the physical W key, on a Russian layout too.
    func testCommandWClosesThroughTheWindowItself() throws {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting as? NotepadNSWindow)
        var called = false
        window.closeRequest = { called = true }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "ц", charactersIgnoringModifiers: "ц", isARepeat: false, keyCode: 13
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(called)
    }

    // MARK: - 10. ⌘W / File → Close acts exactly like the ✕ button

    func testCloseCommandActsLikeTheCloseButton() {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = panel.windowForTesting as! NotepadNSWindow
        var called = false
        window.closeRequest = { called = true }

        window.performClose(nil)

        XCTAssertTrue(called)
    }

    /// Front-to-back on-screen window numbers, as `CGWindowListCopyWindowInfo`
    /// reports them: the same query `NotepadWindowUITests` uses to prove
    /// ordering, since `NSApp.orderedWindows`'s own notion of order does not
    /// reliably reflect what `orderFrontRegardless` just did in this host.
    private func frontToBackWindowNumbers() -> [Int] {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])?
            .compactMap { $0[kCGWindowNumber as String] as? Int } ?? []
    }

    /// `orderFrontRegardless` returns before the window server has actually
    /// mapped the window on screen, so a `CGWindowListCopyWindowInfo` query
    /// right after it can still miss it; poll until both windows are listed.
    private func waitUntilBothOnScreen(
        _ a: NSWindow, _ b: NSWindow, timeout: TimeInterval = 2
    ) -> [Int] {
        let deadline = Date().addingTimeInterval(timeout)
        var order = frontToBackWindowNumbers()
        while Date() < deadline, !(order.contains(a.windowNumber) && order.contains(b.windowNumber)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            order = frontToBackWindowNumbers()
        }
        return order
    }

    // MARK: - 12. Activation raises the notepad when no real window is open

    /// Mission Control's own window picker (and any other activation of
    /// Murmurly that is not a click on the notepad itself) delivers no click
    /// of its own, so the panel listens for activation itself. With the
    /// notepad marked shown and nothing else of this app's windows open,
    /// activation must bring it back exactly as a click would. Built through
    /// `forPanelTestingOnly`/`setShownForTesting`, not a recorded meeting:
    /// the recorder's own `render()` only shows the window once a real
    /// `MeetingTranscriptionQueue` is wired in (`meeting.transcripts`, set by
    /// `MurmurlyApp`), which these fixtures do not carry.
    func testActivationRaisesTheNotepadWhenNoRealWindowIsOpen() throws {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting)
        window.orderFrontRegardless()
        panel.setShownForTesting(true)
        defer { window.orderOut(nil) }

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible, "the window must actually be hidden for this test to prove anything")

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

        XCTAssertTrue(
            window.isVisible,
            "activation did not raise the notepad; other windows: \(visibleWindowsDescription(excluding: window))"
        )
    }

    // MARK: - 13. Activation leaves the notepad alone while a real window is open

    /// The owner's own main window counts as a real window
    /// (`AppWindowController.isRealWindow`): activation must not fight
    /// whatever that window's own front-most order already is.
    func testActivationLeavesTheNotepadBelowARealWindow() async throws {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting)
        window.orderFrontRegardless()
        panel.setShownForTesting(true)
        defer { window.orderOut(nil) }

        let realWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        realWindow.isReleasedWhenClosed = false
        realWindow.orderFrontRegardless()
        defer { realWindow.orderOut(nil) }

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        // A negative assertion: give the sink a moment to run, then confirm
        // it did nothing, rather than wait for an event that must not happen.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(
            window.isVisible,
            "a real window open must keep the notepad from being raised; other windows: \(visibleWindowsDescription(excluding: window))"
        )
    }

    // MARK: - 14. Activation leaves the notepad below an open panel

    /// `NSOpenPanel`'s own window is an `NSPanel` at the ordinary level, so
    /// `AppWindowController.isRealWindow` never counted it — yet it is what
    /// the activation (from `AppWindowController.chooseFolder`'s
    /// `enterRegular()` → `NSApp.activate()`) is for. A plain `NSPanel` at
    /// the default level stands in for it here.
    func testActivationLeavesTheNotepadBelowAnOpenPanel() async throws {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting)
        window.orderFrontRegardless()
        panel.setShownForTesting(true)
        defer { window.orderOut(nil) }

        let openPanel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        openPanel.isReleasedWhenClosed = false
        openPanel.orderFrontRegardless()
        defer { openPanel.orderOut(nil) }

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(
            window.isVisible,
            "an open panel must keep the notepad from being raised; other windows: \(visibleWindowsDescription(excluding: window))"
        )
    }

    // MARK: - 15. Activation still raises the notepad over the recording indicator's level

    /// A visible window at the recording indicator's own level
    /// (`.statusBar`, `RecordingIndicator.swift`) must never block the
    /// raise: the menu bar's own windows sit there and above.
    func testActivationRaisesTheNotepadOverTheRecordingIndicatorLevel() throws {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting)
        window.orderFrontRegardless()
        panel.setShownForTesting(true)
        defer { window.orderOut(nil) }

        let indicator = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 40, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        indicator.isReleasedWhenClosed = false
        indicator.level = .statusBar
        indicator.orderFrontRegardless()
        defer { indicator.orderOut(nil) }

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

        XCTAssertTrue(
            window.isVisible,
            "the recording indicator's level must not block the raise; other windows: \(visibleWindowsDescription(excluding: window))"
        )
    }

    private func visibleWindowsDescription(excluding window: NSWindow) -> String {
        NSApp.windows
            .filter { $0 !== window && $0.isVisible }
            .map { "\(type(of: $0)) level=\($0.level.rawValue)" }
            .joined(separator: ", ")
    }

    // MARK: - 16. `show()` raises the notepad over another window by activating Murmurly

    /// "Show Live Transcript" (`show()`) activates Murmurly and orders the
    /// panel front directly (`orderFrontRegardless`, then `makeKey`), not
    /// through the `didBecomeActiveNotification` path above
    /// (`raiseOnActivation`): it must win over another window already in
    /// front, on its own.
    /// `forPanelTestingOnly`/`setShownForTesting`: `render()` with no
    /// meeting at all only sets `isShown` back to `false` and returns
    /// without touching the window, so `show()` still orders it front.
    func testShowRaisesTheNotepadOverAnotherWindow() throws {
        let panel = LiveTranscriptPanel(forPanelTestingOnly: ())
        panel.buildWindowForTesting()
        let window = try XCTUnwrap(panel.windowForTesting)
        window.orderFrontRegardless()
        panel.setShownForTesting(true)
        defer { window.orderOut(nil) }

        let other = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        other.isReleasedWhenClosed = false
        defer { other.orderOut(nil) }

        window.orderOut(nil)
        other.orderFrontRegardless()
        var order = waitUntilBothOnScreen(window, other)
        let otherBefore = try XCTUnwrap(order.firstIndex(of: other.windowNumber))
        let notepadBefore = try XCTUnwrap(order.firstIndex(of: window.windowNumber))
        XCTAssertLessThan(otherBefore, notepadBefore, "the other window must start on top")

        panel.show()

        let deadline = Date().addingTimeInterval(2)
        order = waitUntilBothOnScreen(window, other)
        while Date() < deadline,
              let notepadIndex = order.firstIndex(of: window.windowNumber),
              let otherIndex = order.firstIndex(of: other.windowNumber),
              notepadIndex > otherIndex {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            order = waitUntilBothOnScreen(window, other)
        }
        let notepadAfter = try XCTUnwrap(order.firstIndex(of: window.windowNumber))
        let otherAfter = try XCTUnwrap(order.firstIndex(of: other.windowNumber))
        XCTAssertLessThan(notepadAfter, otherAfter, "show() must raise the notepad over the other window")
    }
}
