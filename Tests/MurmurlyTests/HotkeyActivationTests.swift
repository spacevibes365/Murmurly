import AppKit
import Foundation
import KeyboardShortcuts
import XCTest
@testable import Murmurly

private actor ImmediateHotkeyMic: MicCapturing {
    private(set) var stopCount = 0

    func start() async throws {}

    func stop() async throws -> URL? {
        stopCount += 1
        return nil
    }
}

private enum HotkeyWaitError: Error {
    case timedOut
}

@MainActor
final class HotkeyActivationTests: XCTestCase {
    func testPressGestureHintUsesAssignedShortcutAndIsSymmetric() {
        let hint = dictationGestureHint(
            activation: .press,
            modifier: .rightCommand,
            shortcutDescription: "⌃⌥D",
            doubleModifierAvailable: true
        )

        XCTAssertEqual(hint, DictationGestureHint(start: "⌃⌥D", stop: "⌃⌥D"))
    }

    func testPressGestureHintReportsRemovedShortcut() {
        let hint = dictationGestureHint(
            activation: .press,
            modifier: .rightCommand,
            shortcutDescription: nil,
            doubleModifierAvailable: true
        )

        XCTAssertEqual(hint, DictationGestureHint(start: "Not set", stop: "Not set"))
    }

    func testDoubleModifierGestureHintsCoverEveryModifierAndAreAsymmetric() {
        let cases: [(TapModifier, String, String)] = [
            (.rightCommand, "2× Right ⌘", "Right ⌘"),
            (.leftCommand, "2× Left ⌘", "Left ⌘"),
            (.rightOption, "2× Right ⌥", "Right ⌥"),
            (.leftOption, "2× Left ⌥", "Left ⌥"),
        ]

        for (modifier, start, stop) in cases {
            let hint = dictationGestureHint(
                activation: .doubleModifier,
                modifier: modifier,
                shortcutDescription: "⌥Space",
                doubleModifierAvailable: true
            )
            XCTAssertEqual(hint, DictationGestureHint(start: start, stop: stop))
            XCTAssertNotEqual(hint.start, hint.stop)
        }
    }

    func testUnavailableDoubleModifierFallsBackToAssignedShortcut() {
        let assigned = dictationGestureHint(
            activation: .doubleModifier,
            modifier: .rightCommand,
            shortcutDescription: "⌥Space",
            doubleModifierAvailable: false
        )
        let removed = dictationGestureHint(
            activation: .doubleModifier,
            modifier: .rightCommand,
            shortcutDescription: nil,
            doubleModifierAvailable: false
        )
        let pressWithoutShortcut = dictationGestureHint(
            activation: .press,
            modifier: .rightCommand,
            shortcutDescription: nil,
            doubleModifierAvailable: false
        )

        XCTAssertEqual(assigned, DictationGestureHint(start: "⌥Space", stop: "⌥Space"))
        XCTAssertEqual(
            removed,
            DictationGestureHint(start: "No gesture available", stop: "No gesture available")
        )
        XCTAssertEqual(pressWithoutShortcut, removed)
    }

    func testDoubleModifierFiresInsideThresholdButNotOutside() {
        for thresholdMilliseconds in [150, 500] {
            let threshold = Double(thresholdMilliseconds) / 1_000
            var atBoundary = DoubleModifierReducer(
                modifier: .rightCommand,
                thresholdMilliseconds: thresholdMilliseconds
            )
            XCTAssertFalse(change(&atBoundary, .rightCommand, down: true, at: 0))
            XCTAssertFalse(change(&atBoundary, .rightCommand, down: false, at: 0.02))
            XCTAssertFalse(change(&atBoundary, .rightCommand, down: true, at: threshold))
            XCTAssertTrue(change(&atBoundary, .rightCommand, down: false, at: threshold + 0.02))

            var outside = DoubleModifierReducer(
                modifier: .rightCommand,
                thresholdMilliseconds: thresholdMilliseconds
            )
            XCTAssertFalse(change(&outside, .rightCommand, down: true, at: 0))
            XCTAssertFalse(change(&outside, .rightCommand, down: false, at: 0.02))
            XCTAssertFalse(change(
                &outside,
                .rightCommand,
                down: true,
                at: threshold + 0.001
            ))
            XCTAssertFalse(change(
                &outside,
                .rightCommand,
                down: false,
                at: threshold + 0.02
            ))
        }
    }

    func testThirdModifierTapDoesNotFireTwice() {
        var reducer = DoubleModifierReducer(
            modifier: .rightCommand,
            thresholdMilliseconds: 250
        )
        XCTAssertFalse(tap(&reducer, .rightCommand, downAt: 0, upAt: 0.02))
        XCTAssertTrue(tap(&reducer, .rightCommand, downAt: 0.10, upAt: 0.12))
        XCTAssertFalse(tap(&reducer, .rightCommand, downAt: 0.20, upAt: 0.22))
    }

    func testChordAndOrdinaryKeyCancelModifierTap() {
        var chord = DoubleModifierReducer(
            modifier: .rightOption,
            thresholdMilliseconds: 250
        )
        XCTAssertFalse(change(
            &chord,
            .rightOption,
            down: true,
            otherModifiersDown: true,
            at: 0
        ))
        XCTAssertFalse(change(&chord, .rightOption, down: false, at: 0.02))
        XCTAssertFalse(tap(&chord, .rightOption, downAt: 0.10, upAt: 0.12))

        var ordinaryKey = DoubleModifierReducer(
            modifier: .rightOption,
            thresholdMilliseconds: 250
        )
        XCTAssertFalse(change(&ordinaryKey, .rightOption, down: true, at: 0))
        XCTAssertNil(ordinaryKey.handle(.keyDown(selectedModifierDown: true)))
        XCTAssertFalse(change(&ordinaryKey, .rightOption, down: false, at: 0.02))
        XCTAssertFalse(tap(&ordinaryKey, .rightOption, downAt: 0.10, upAt: 0.12))

        var interveningModifier = DoubleModifierReducer(
            modifier: .rightOption,
            thresholdMilliseconds: 250
        )
        XCTAssertFalse(tap(&interveningModifier, .rightOption, downAt: 0, upAt: 0.02))
        XCTAssertNil(interveningModifier.handle(
            .otherModifierChanged(selectedModifierDown: false)
        ))
        XCTAssertFalse(tap(
            &interveningModifier,
            .rightOption,
            downAt: 0.10,
            upAt: 0.12
        ))
    }

    func testLeftAndRightModifiersAreDistinct() {
        XCTAssertNotEqual(TapModifier.leftCommand.keyCode, TapModifier.rightCommand.keyCode)
        XCTAssertNotEqual(TapModifier.leftOption.keyCode, TapModifier.rightOption.keyCode)

        var reducer = DoubleModifierReducer(
            modifier: .rightCommand,
            thresholdMilliseconds: 250
        )
        XCTAssertFalse(tap(&reducer, .leftCommand, downAt: 0, upAt: 0.02))
        XCTAssertFalse(tap(&reducer, .leftCommand, downAt: 0.10, upAt: 0.12))
        XCTAssertFalse(tap(&reducer, .rightCommand, downAt: 0.20, upAt: 0.22))
        XCTAssertTrue(tap(&reducer, .rightCommand, downAt: 0.30, upAt: 0.32))
    }

    func testReconfigurationKeepsOneShortcutAction() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let manager = HotkeyManager(installsSystemHandlers: false)
        var toggles = 0
        manager.activate(
            settings: settings,
            onToggle: { toggles += 1 },
            isRecording: { false }
        )

        settings.hotkeyActivation = .doubleModifier
        settings.hotkeyActivation = .press
        settings.hotkeyActivation = .doubleModifier
        manager.shortcutKeyDownForTesting()
        XCTAssertEqual(toggles, 1)
    }

    func testRecorderActivityUsesFieldEditorInsteadOfStoredFlag() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .dictate)
        recorder.frame = NSRect(x: 20, y: 30, width: 180, height: 24)
        window.contentView?.addSubview(recorder)
        window.makeKeyAndOrderFront(nil)
        await Task.yield()

        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(HotkeyManager.recorderIsActive(in: window))
        XCTAssertTrue(window.firstResponder is NSTextView)

        window.makeFirstResponder(nil)
        XCTAssertFalse(HotkeyManager.recorderIsActive(in: window))
        window.orderOut(nil)
    }

    func testRecorderEdgeResetPreventsTapAcrossRecordingSession() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.hotkeyActivation = .doubleModifier
        let manager = HotkeyManager(installsSystemHandlers: false)
        var toggles = 0
        manager.activate(
            settings: settings,
            onToggle: { toggles += 1 },
            isRecording: { false }
        )

        manager.doubleModifierEventForTesting(.modifierChanged(
            .rightCommand,
            isDown: true,
            otherModifiersDown: false,
            timestamp: 0
        ))
        manager.doubleModifierEventForTesting(.modifierChanged(
            .rightCommand,
            isDown: false,
            otherModifiersDown: false,
            timestamp: 0.02
        ))
        manager.resetDoubleModifierSequenceForTesting()
        manager.doubleModifierEventForTesting(.modifierChanged(
            .rightCommand,
            isDown: true,
            otherModifiersDown: false,
            timestamp: 0.10
        ))
        manager.doubleModifierEventForTesting(.modifierChanged(
            .rightCommand,
            isDown: false,
            otherModifiersDown: false,
            timestamp: 0.12
        ))
        XCTAssertEqual(toggles, 0)
    }

    func testModeChangeDoesNotStopRecordingAndNewPressDoes() async throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.soundsEnabled = false
        let manager = HotkeyManager(installsSystemHandlers: false)
        let mic = ImmediateHotkeyMic()
        let coordinator = DictationCoordinator(
            mic: mic,
            indicator: RecordingIndicator(renderingEnabled: false),
            hotkeyManager: manager
        )
        coordinator.activate(settings: settings, permissions: PermissionManager())
        coordinator.beginCaptureForTesting()
        try await waitUntil { coordinator.state == .recording }

        settings.hotkeyActivation = .doubleModifier
        XCTAssertEqual(coordinator.state, .recording)
        settings.hotkeyActivation = .press
        XCTAssertEqual(coordinator.state, .recording)
        manager.shortcutKeyDownForTesting()
        try await waitUntil { coordinator.state == .idle }
        let stopCount = await mic.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testSingleModifierTapStopsAnExistingRecording() async throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.soundsEnabled = false
        settings.hotkeyActivation = .doubleModifier
        let manager = HotkeyManager(installsSystemHandlers: false)
        let mic = ImmediateHotkeyMic()
        let coordinator = DictationCoordinator(
            mic: mic,
            indicator: RecordingIndicator(renderingEnabled: false),
            hotkeyManager: manager
        )
        coordinator.activate(settings: settings, permissions: PermissionManager())
        coordinator.beginCaptureForTesting()
        try await waitUntil { coordinator.state == .recording }

        sendTap(to: manager, downAt: 0, upAt: 0.02)

        try await waitUntil { coordinator.state == .idle }
        let stopCount = await mic.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testSingleModifierTapDoesNotStartWhenIdle() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.hotkeyActivation = .doubleModifier
        let manager = HotkeyManager(installsSystemHandlers: false)
        var toggles = 0
        manager.activate(
            settings: settings,
            onToggle: { toggles += 1 },
            isRecording: { false }
        )

        sendTap(to: manager, downAt: 0, upAt: 0.02)

        XCTAssertEqual(toggles, 0)
    }

    func testStoppingTapDoesNotBecomeFirstTapOfNextStart() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.hotkeyActivation = .doubleModifier
        let manager = HotkeyManager(installsSystemHandlers: false)
        var recording = true
        var toggles = 0
        manager.activate(
            settings: settings,
            onToggle: {
                toggles += 1
                recording = false
            },
            isRecording: { recording }
        )

        sendTap(to: manager, downAt: 0, upAt: 0.02)
        sendTap(to: manager, downAt: 0.10, upAt: 0.12)

        XCTAssertEqual(toggles, 1)
    }

    func testChordDuringRecordingDoesNotStopIt() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.hotkeyActivation = .doubleModifier
        let manager = HotkeyManager(installsSystemHandlers: false)
        var toggles = 0
        manager.activate(
            settings: settings,
            onToggle: { toggles += 1 },
            isRecording: { true }
        )

        manager.doubleModifierEventForTesting(.modifierChanged(
            .rightCommand,
            isDown: true,
            otherModifiersDown: false,
            timestamp: 0
        ))
        manager.doubleModifierEventForTesting(.keyDown(selectedModifierDown: true))
        manager.doubleModifierEventForTesting(.modifierChanged(
            .rightCommand,
            isDown: false,
            otherModifiersDown: false,
            timestamp: 0.02
        ))

        XCTAssertEqual(toggles, 0)
    }

    func testIdleFeedbackClearsTapIgnoredWhileBusy() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.hotkeyActivation = .doubleModifier
        let manager = HotkeyManager(installsSystemHandlers: false)
        var toggles = 0
        manager.activate(
            settings: settings,
            onToggle: { toggles += 1 },
            isRecording: { false }
        )

        sendTap(to: manager, downAt: 0, upAt: 0.02)
        manager.dictationDidBecomeIdle()
        sendTap(to: manager, downAt: 0.10, upAt: 0.12)

        XCTAssertEqual(toggles, 0)
    }

    private func change(
        _ reducer: inout DoubleModifierReducer,
        _ modifier: TapModifier,
        down: Bool,
        otherModifiersDown: Bool = false,
        at timestamp: TimeInterval
    ) -> Bool {
        reducer.handle(.modifierChanged(
            modifier,
            isDown: down,
            otherModifiersDown: otherModifiersDown,
            timestamp: timestamp
        )) == .tapCompleted(completesDoubleTap: true)
    }

    private func tap(
        _ reducer: inout DoubleModifierReducer,
        _ modifier: TapModifier,
        downAt: TimeInterval,
        upAt: TimeInterval
    ) -> Bool {
        _ = change(&reducer, modifier, down: true, at: downAt)
        return change(&reducer, modifier, down: false, at: upAt)
    }

    private func sendTap(
        to manager: HotkeyManager,
        modifier: TapModifier = .rightCommand,
        downAt: TimeInterval,
        upAt: TimeInterval
    ) {
        manager.doubleModifierEventForTesting(.modifierChanged(
            modifier,
            isDown: true,
            otherModifiersDown: false,
            timestamp: downAt
        ))
        manager.doubleModifierEventForTesting(.modifierChanged(
            modifier,
            isDown: false,
            otherModifiersDown: false,
            timestamp: upAt
        ))
    }

    private func makeSettings() throws -> (SettingsStore, () -> Void) {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.Hotkey.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (
            SettingsStore(defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                throw HotkeyWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
