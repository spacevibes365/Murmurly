import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import XCTest
@testable import Murmurly

/// A clock a hold is measured against, stood in through
/// `DictationCoordinator.holdClockForTesting`: it lets a test assert a
/// 500 ms threshold without waiting 500 ms of wall time.
@MainActor
private final class HoldClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

/// Stands in for the real microphone at the seam `holdBegan`/`holdEnded`
/// exercise: `start()` models both orders a release during `.starting` can
/// race against a late microphone success, and ignores cancellation — the
/// real capture would also keep running past a cancelled start until the
/// coordinator's own `stop` reaches it.
private actor HoldMic: MicCapturing {
    enum StartMode {
        /// The microphone is already recording by the time anyone asks.
        case immediate
        /// `start()` suspends before recording begins: a stop raised while
        /// suspended finds nothing to stop.
        case heldBeforeRecording
        /// `start()` marks recording, then suspends: a stop raised while
        /// suspended still finds the file.
        case heldAfterRecording
    }

    private let template: URL
    private let mode: StartMode
    private var gate: CheckedContinuation<Void, Never>?
    private var recording = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var sources: [URL] = []

    init(template: URL, mode: StartMode) {
        self.template = template
        self.mode = mode
    }

    func start() async throws {
        starts += 1
        switch mode {
        case .immediate:
            recording = true
        case .heldBeforeRecording:
            await withCheckedContinuation { gate = $0 }
            recording = true
        case .heldAfterRecording:
            recording = true
            await withCheckedContinuation { gate = $0 }
        }
    }

    func isHoldingStart() -> Bool { gate != nil }

    func releaseStart() {
        gate?.resume()
        gate = nil
    }

    func isRecording() -> Bool { recording }

    func stop() async throws -> URL? {
        stops += 1
        guard recording else { return nil }
        recording = false
        let url = template.deletingLastPathComponent()
            .appendingPathComponent("hold-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: template, to: url)
        sources.append(url)
        return url
    }
}

@MainActor
final class HoldToTalkTests: XCTestCase {
    private func makeFixture(
        text: String,
        maxRecordingSeconds: TimeInterval = 300,
        mode: HoldMic.StartMode
    ) throws -> (fixture: DictationPipelineFixture, mic: HoldMic, clock: HoldClock) {
        let fixture = try DictationPipelineFixture(
            text: text,
            maxRecordingSeconds: maxRecordingSeconds,
            makeMic: { HoldMic(template: $0, mode: mode) }
        )
        let mic = try XCTUnwrap(fixture.activeMic as? HoldMic)
        let clock = HoldClock()
        fixture.coordinator.startSkipsDeviceGatesForTesting = true
        fixture.coordinator.holdClockForTesting = { clock.now }
        return (fixture, mic, clock)
    }

    /// Nothing the hold touched is kept: no file, no running microphone, no
    /// recognition request, no delivery, no history line, no unsaved entry.
    private func assertNothingKept(
        _ fixture: DictationPipelineFixture,
        _ mic: HoldMic,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sources = await mic.sources
        for url in sources {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "file not deleted: \(url.path)",
                file: file, line: line
            )
        }
        let recording = await mic.isRecording()
        XCTAssertFalse(recording, "microphone still recording", file: file, line: line)
        let requests = await fixture.engine.requests
        XCTAssertTrue(requests.isEmpty, "engine was asked to recognize", file: file, line: line)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty, "text was delivered", file: file, line: line)
        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty, "a history line was written", file: file, line: line)
        XCTAssertTrue(
            fixture.coordinator.unsavedDictations.isEmpty,
            "an unsaved dictation was kept",
            file: file, line: line
        )
    }

    /// Waits until a discarded hold's stop is fully wound down: one file was
    /// handed out, that file no longer exists, and the microphone reports it
    /// stopped. Checking the counters alone races the deletion, which runs
    /// after the stop returns, inside the coordinator's own task.
    private func waitForDiscardedHold(_ mic: HoldMic, timeout: Duration = .seconds(5)) async throws {
        try await waitForDictation(timeout: timeout) {
            let sources = await mic.sources
            guard let url = sources.first else { return false }
            guard !FileManager.default.fileExists(atPath: url.path) else { return false }
            return await !mic.isRecording()
        }
    }

    /// KeyboardShortcuts reads only `UserDefaults.standard`; the value goes
    /// into this process's volatile argument domain instead, read first and
    /// restored in `defer`, for the whole body including every wait inside it.
    private func withDictateShortcut(
        _ value: Any,
        _ body: () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overridden = original
        overridden["KeyboardShortcuts_dictate"] = value
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        try await body()
    }

    /// Runs a test body that may leave a gate (the mic's held start, the
    /// engine's held decode) suspended, releasing it whether the body
    /// succeeds, fails an assertion that throws, or is cancelled — a
    /// `Task` spawned from `defer` would not be awaited, and the gate would
    /// then stay open on a fixture `cleanup()` is about to delete.
    private func runReleasingGate(
        releasing: @escaping @MainActor () async -> Void,
        _ body: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            await releasing()
            throw error
        }
        await releasing()
    }

    /// Ends a test that holds gates the same way whether the body succeeds or
    /// throws: release every gate, wait (bounded) until the coordinator is
    /// idle and no Esc is registered, and only then let the caller's own
    /// `defer { fixture.cleanup() }` delete files and settings.
    private func runSettling(
        _ fixture: DictationPipelineFixture,
        releasing: @escaping @MainActor () async -> Void,
        _ body: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            await settle(fixture, releasing)
            throw error
        }
        await settle(fixture, releasing)
    }

    private func settle(
        _ fixture: DictationPipelineFixture,
        _ releasing: @MainActor () async -> Void
    ) async {
        await releasing()
        try? await waitForDictation(timeout: .seconds(30)) {
            fixture.coordinator.state == .idle && !fixture.coordinator.isEscapeListenerOpenForTesting
        }
    }

    private func makeHoldSettings() throws -> (SettingsStore, () -> Void) {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.HoldToTalk.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (
            SettingsStore(defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func rightCommandFlagsChanged(down: Bool, at time: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: down ? [.command] : [],
            timestamp: time,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_RightCommand)
        )!
    }

    func testHoldAndReleaseDictatesAndPastes() async throws {
        let (fixture, mic, clock) = try makeFixture(text: "hello world", mode: .immediate)
        defer { fixture.cleanup() }

        fixture.coordinator.holdBegan()
        try await waitForDictation { fixture.coordinator.state == .recording }
        clock.advance(.milliseconds(500))
        fixture.coordinator.holdEnded()
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["hello world"])
        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["hello world"])
        let starts = await mic.starts
        XCTAssertEqual(starts, 1)
    }

    func testShortHoldIsDiscardedWithoutHistory() async throws {
        let (fixture, mic, clock) = try makeFixture(text: "unused", mode: .immediate)
        defer { fixture.cleanup() }
        let custom = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))

        try await withDictateShortcut(stored) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { fixture.coordinator.state == .recording }
            clock.advance(.milliseconds(200))
            fixture.coordinator.holdEnded()
            XCTAssertEqual(fixture.coordinator.state, .transcribing)
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

            let sources = await mic.sources
            XCTAssertEqual(sources.count, 1)
            XCTAssertEqual(
                fixture.indicator.presentedState,
                .dictationFailure(message: "Hold \(custom.description) while you speak")
            )
            try await assertNothingKept(fixture, mic)
        }
    }

    func testReleaseWhileTheMicrophoneStartsDiscards() async throws {
        let (fixture, mic, clock) = try makeFixture(text: "unused", mode: .heldAfterRecording)
        defer { fixture.cleanup() }

        try await runReleasingGate(releasing: { await mic.releaseStart() }) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { await mic.isHoldingStart() }
            XCTAssertEqual(fixture.coordinator.state, .starting)
            clock.advance(.seconds(2)) // a long hold does not save an attempt with nothing recorded
            fixture.coordinator.holdEnded()
            XCTAssertEqual(fixture.coordinator.state, .transcribing)
            XCTAssertEqual(fixture.indicator.presentedState, DictationCoordinator.releasedBeforeRecordingFlash)

            try await self.waitForDiscardedHold(mic)
            let stopsAfterDiscard = await mic.stops
            XCTAssertEqual(stopsAfterDiscard, 1)
            let sourcesAfterDiscard = await mic.sources
            XCTAssertEqual(sourcesAfterDiscard.count, 1)

            // A new hold must not reach the capture while the abandoned one is
            // still winding down (both its stops are not over yet).
            fixture.coordinator.holdBegan()
            XCTAssertEqual(fixture.coordinator.state, .transcribing)
            let startsAfterSecondHold = await mic.starts
            XCTAssertEqual(startsAfterSecondHold, 1)

            await mic.releaseStart()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            let stopsFinal = await mic.stops
            XCTAssertEqual(stopsFinal, 2)
            try await self.assertNothingKept(fixture, mic)
        }
    }

    func testLateMicrophoneSuccessAfterReleaseIsWoundDown() async throws {
        let (fixture, mic, clock) = try makeFixture(text: "unused", mode: .heldBeforeRecording)
        defer { fixture.cleanup() }

        try await runReleasingGate(releasing: { await mic.releaseStart() }) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { await mic.isHoldingStart() }
            clock.advance(.milliseconds(50))
            fixture.coordinator.holdEnded()
            try await waitForDictation { await mic.stops == 1 }
            let sourcesAfterFirstStop = await mic.sources
            XCTAssertTrue(sourcesAfterFirstStop.isEmpty, "the first stop should have found nothing recording yet")
            XCTAssertEqual(fixture.coordinator.state, .transcribing)

            await mic.releaseStart()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            let stopsFinal = await mic.stops
            XCTAssertEqual(stopsFinal, 2)
            let startsFinal = await mic.starts
            XCTAssertEqual(startsFinal, 1)
            try await self.assertNothingKept(fixture, mic)
        }
    }

    func testReleaseAfterALongStartStillDictates() async throws {
        let (fixture, mic, clock) = try makeFixture(text: "late start", mode: .heldBeforeRecording)
        defer { fixture.cleanup() }

        try await runReleasingGate(releasing: { await mic.releaseStart() }) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { await mic.isHoldingStart() }
            clock.advance(.milliseconds(600))
            await mic.releaseStart()
            try await waitForDictation { fixture.coordinator.state == .recording }
            clock.advance(.milliseconds(100))
            fixture.coordinator.holdEnded()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

            let delivered = await fixture.probe.deliveredTexts
            XCTAssertEqual(delivered, ["late start"])
            let recent = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(recent.map(\.text), ["late start"])
        }
    }

    func testSecondHoldWhileRecordingIsIgnored() async throws {
        let (fixture, mic, clock) = try makeFixture(text: "clip", mode: .immediate)
        defer { fixture.cleanup() }

        fixture.coordinator.holdBegan()
        try await waitForDictation { fixture.coordinator.state == .recording }
        clock.advance(.milliseconds(400))
        fixture.coordinator.holdBegan() // a key-repeat or a second press
        XCTAssertEqual(fixture.coordinator.state, .recording)
        let starts = await mic.starts
        XCTAssertEqual(starts, 1)
        clock.advance(.milliseconds(200)) // 600 ms total; 200 ms alone would be a short hold
        fixture.coordinator.holdEnded()
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["clip"])
        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["clip"])
    }

    func testReleaseAfterTheLimitStopIsIgnored() async throws {
        let (fixture, _, clock) = try makeFixture(text: "clip", maxRecordingSeconds: 0.3, mode: .immediate)
        defer { fixture.cleanup() }
        await fixture.engine.holdDecodes()

        try await runReleasingGate(releasing: { await fixture.engine.releaseHeldDecode() }) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { fixture.coordinator.state == .recording }
            try await waitForDictation {
                fixture.coordinator.state == .transcribing && fixture.coordinator.lastDictationHitLimit
            }
            clock.advance(.milliseconds(100)) // short; the attempt is no longer the hold's own
            fixture.coordinator.holdEnded()
            XCTAssertEqual(fixture.coordinator.state, .transcribing)

            try await waitForDictation { await fixture.engine.isHoldingDecode() }
            await fixture.engine.releaseHeldDecode()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

            let recent = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(recent.map(\.text), ["clip"])
        }
    }

    func testHoldModeIsStoredAndRead() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.HoldStored.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.hotkeyActivation = .hold

        XCTAssertEqual(defaults.string(forKey: "dictation.hotkey.activation"), "hold")
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkeyActivation, .hold)
        XCTAssertEqual(HotkeyActivation.allCases, [.press, .hold, .doubleModifier])
        XCTAssertEqual(
            HotkeyActivation.hold.explanation,
            "Hold the shortcut while you speak; release it to paste."
        )
    }

    func testGestureHintForHold() {
        for available in [true, false] {
            let hint = dictationGestureHint(
                activation: .hold,
                modifier: .rightCommand,
                shortcutDescription: "⌥Space",
                doubleModifierAvailable: available
            )
            XCTAssertEqual(hint, DictationGestureHint(start: "Hold ⌥Space", stop: "Release ⌥Space"))
        }
        let custom = dictationGestureHint(
            activation: .hold,
            modifier: .rightCommand,
            shortcutDescription: "⌃⌥D",
            doubleModifierAvailable: true
        )
        XCTAssertEqual(custom, DictationGestureHint(start: "Hold ⌃⌥D", stop: "Release ⌃⌥D"))

        let withoutShortcutAvailable = dictationGestureHint(
            activation: .hold,
            modifier: .rightCommand,
            shortcutDescription: nil,
            doubleModifierAvailable: true
        )
        XCTAssertEqual(withoutShortcutAvailable, DictationGestureHint(start: "Not set", stop: "Not set"))
        let withoutShortcutUnavailable = dictationGestureHint(
            activation: .hold,
            modifier: .rightCommand,
            shortcutDescription: nil,
            doubleModifierAvailable: false
        )
        XCTAssertEqual(
            withoutShortcutUnavailable,
            DictationGestureHint(start: "No gesture available", stop: "No gesture available")
        )
    }

    func testHoldModeInstallsNoDoubleModifierMonitorsInATestCopy() async throws {
        // (a) A test copy's default manager installs nothing, in any mode.
        let (settingsA, cleanupA) = try makeHoldSettings()
        defer { cleanupA() }
        settingsA.hotkeyActivation = .hold
        let before = HotkeyManager.systemRegistrationsForTesting
        let managerA = HotkeyManager()
        managerA.activate(settings: settingsA, onToggle: {}, isRecording: { false })
        XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)

        // (b) Counted callbacks, with the installer forced off: holdBegan and
        // holdEnded fire on key-down/key-up and never on a double-modifier tap.
        let (settingsB, cleanupB) = try makeHoldSettings()
        defer { cleanupB() }
        settingsB.hotkeyActivation = .hold
        let managerB = HotkeyManager(installsSystemHandlers: false)
        var holdBeganCount = 0
        var holdEndedCount = 0
        var toggles = 0
        managerB.activate(
            settings: settingsB,
            onToggle: { toggles += 1 },
            isRecording: { false },
            onHoldBegan: { holdBeganCount += 1 },
            onHoldEnded: { holdEndedCount += 1 }
        )
        managerB.shortcutKeyDownForTesting()
        XCTAssertEqual(holdBeganCount, 1)
        XCTAssertEqual(toggles, 0)
        managerB.shortcutKeyUpForTesting()
        XCTAssertEqual(holdEndedCount, 1)

        managerB.monitoredEventForTesting(rightCommandFlagsChanged(down: true, at: 100))
        managerB.monitoredEventForTesting(rightCommandFlagsChanged(down: false, at: 100.05))
        managerB.monitoredEventForTesting(rightCommandFlagsChanged(down: true, at: 100.15))
        managerB.monitoredEventForTesting(rightCommandFlagsChanged(down: false, at: 100.2))
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(holdBeganCount, 1)

        settingsB.hotkeyActivation = .press
        managerB.shortcutKeyUpForTesting() // no longer hold mode: key-up does nothing
        XCTAssertEqual(holdEndedCount, 1)
        managerB.shortcutKeyDownForTesting()
        XCTAssertEqual(toggles, 1)

        // (c) The real chain: settings → HotkeyManager.keyDown → coordinator.holdBegan.
        // Without either binding in `DictationCoordinator.activate`, this hangs at .idle.
        let (fixture, mic, clock) = try makeFixture(text: "chained", mode: .immediate)
        defer { fixture.cleanup() }
        fixture.settings.hotkeyActivation = .hold
        fixture.coordinator.activate(settings: fixture.settings, permissions: PermissionManager(runningTests: true))
        let manager = fixture.coordinator.hotkeyManagerForTesting

        manager.shortcutKeyDownForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        let starts = await mic.starts
        XCTAssertEqual(starts, 1)
        clock.advance(.milliseconds(600))
        manager.shortcutKeyUpForTesting()
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["chained"])
    }

    // MARK: - Esc with the held shortcut's modifiers cancels a hold

    func testOptionEscapeDuringHoldIsRegisteredAndCancels() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _, clock) = try makeFixture(text: "option escape words", mode: .immediate)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let custom = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))
        let bare = KeyboardShortcuts.Shortcut(.escape)
        let chord = KeyboardShortcuts.Shortcut(.escape, modifiers: [.option])
        await fixture.engine.holdDecodes()

        try await withDictateShortcut(stored) {
            try await self.runSettling(fixture, releasing: { await fixture.engine.releaseHeldDecode() }) {
                fixture.coordinator.holdBegan()
                try await waitForDictation { fixture.coordinator.state == .recording }
                XCTAssertEqual(fixture.coordinator.escapeShortcutsForTesting, [bare, chord])

                clock.advance(.seconds(1))
                let handled = fixture.coordinator.escapeEventsHandledForTesting
                // The event goes only to the chord's own stand-in stream.
                XCTAssertTrue(fixture.coordinator.pressEscapeForTesting(chord))
                try await waitForDictation(timeout: .seconds(5)) {
                    fixture.coordinator.escapeEventsHandledForTesting == handled + 1
                }
                try await waitForDictation { await fixture.engine.isHoldingDecode() }
                XCTAssertTrue(fixture.coordinator.skipsDeliveryForTesting)
                // Freed at once, even though recognition is still held.
                XCTAssertEqual(fixture.coordinator.escapeShortcutsForTesting, [])

                fixture.coordinator.holdEnded() // already ended by Esc: nothing left to do
            }
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["option escape words"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }

    func testCustomChordEscapeDuringHoldIsRegisteredAndCancels() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _, clock) = try makeFixture(text: "chord escape words", mode: .immediate)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let custom = KeyboardShortcuts.Shortcut(.d, modifiers: [.control, .command])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))
        let bare = KeyboardShortcuts.Shortcut(.escape)
        let chord = KeyboardShortcuts.Shortcut(.escape, modifiers: [.control, .command])
        await fixture.engine.holdDecodes()

        try await withDictateShortcut(stored) {
            try await self.runSettling(fixture, releasing: { await fixture.engine.releaseHeldDecode() }) {
                fixture.coordinator.holdBegan()
                try await waitForDictation { fixture.coordinator.state == .recording }
                XCTAssertEqual(fixture.coordinator.escapeShortcutsForTesting, [bare, chord])

                clock.advance(.seconds(1))
                let handled = fixture.coordinator.escapeEventsHandledForTesting
                XCTAssertTrue(fixture.coordinator.pressEscapeForTesting(chord))
                try await waitForDictation(timeout: .seconds(5)) {
                    fixture.coordinator.escapeEventsHandledForTesting == handled + 1
                }
                try await waitForDictation { await fixture.engine.isHoldingDecode() }
                XCTAssertTrue(fixture.coordinator.skipsDeliveryForTesting)
                XCTAssertEqual(fixture.coordinator.escapeShortcutsForTesting, [])

                fixture.coordinator.holdEnded()
            }
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["chord escape words"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }

    /// Guards the chord's removal: after the hold ends by itself (a long
    /// hold, released normally), the chord must no longer cancel anything —
    /// only the bare Esc still can, since recognition is still under way.
    /// Distinguishes the two synchronously, so neither assertion can be
    /// satisfied by the other event.
    func testHoldChordEscapeEndsWithTheHold() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _, clock) = try makeFixture(text: "hold ended words", mode: .immediate)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let custom = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))
        let bare = KeyboardShortcuts.Shortcut(.escape)
        let chord = KeyboardShortcuts.Shortcut(.escape, modifiers: [.option])
        await fixture.engine.holdDecodes()

        try await withDictateShortcut(stored) {
            try await self.runSettling(fixture, releasing: { await fixture.engine.releaseHeldDecode() }) {
                fixture.coordinator.holdBegan()
                try await waitForDictation { fixture.coordinator.state == .recording }
                XCTAssertTrue(fixture.coordinator.escapeShortcutsForTesting.contains(chord))

                clock.advance(.seconds(1)) // well past the 500 ms threshold: a real stop, not a slip
                fixture.coordinator.holdEnded()
                try await waitForDictation { await fixture.engine.isHoldingDecode() }

                // The chord is withdrawn together with the hold; auto-paste
                // is on and recognition is under way, so the bare Esc alone
                // still matters.
                XCTAssertEqual(fixture.coordinator.escapeShortcutsForTesting, [bare])

                let handled = fixture.coordinator.escapeEventsHandledForTesting
                // No stand-in stream left for the chord: this fails to
                // deliver synchronously, not because of a race against a
                // task that has not run yet.
                XCTAssertFalse(fixture.coordinator.pressEscapeForTesting(chord))
                XCTAssertEqual(fixture.coordinator.escapeEventsHandledForTesting, handled)
                XCTAssertFalse(fixture.coordinator.skipsDeliveryForTesting)

                // Only now does the bare Esc actually cancel.
                XCTAssertTrue(fixture.coordinator.pressEscapeForTesting())
                try await waitForDictation(timeout: .seconds(5)) {
                    fixture.coordinator.escapeEventsHandledForTesting == handled + 1
                }
                XCTAssertTrue(fixture.coordinator.skipsDeliveryForTesting)
                XCTAssertEqual(fixture.coordinator.escapeShortcutsForTesting, [])
            }
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["hold ended words"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }
}
