import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Murmurly

@MainActor
private final class GestureProbe {
    var recording = false
    var toggles = 0
}

/// Mouse and double press at the seam monitors → adapter → reducer → dispatch, with real NSEvents
/// let through by the production mask. The real HotkeyManager runs with
/// double right ⌘ and a 250 ms threshold; the mouse is reported as idle unless
/// a test holds a button.
@MainActor
final class HotkeyMouseModifierTests: XCTestCase {
    // MARK: A chord made with the mouse is not a tap

    func testCommandLeftClickWhileRecordingDoesNotStop() throws {
        try assertClickWithModifierDoesNotStop(.leftMouseDown, .leftMouseUp)
    }

    func testCommandRightClickWhileRecordingDoesNotStop() throws {
        try assertClickWithModifierDoesNotStop(.rightMouseDown, .rightMouseUp)
    }

    func testCommandMiddleClickWhileRecordingDoesNotStop() throws {
        try assertClickWithModifierDoesNotStop(.otherMouseDown, .otherMouseUp)
    }

    func testCommandScrollWhileRecordingDoesNotStop() throws {
        let (manager, probe, cleanup) = try makeManager(recording: true)
        defer { cleanup() }
        let scrolling = try scroll(command: true, momentum: false)
        manager.monitoredEventForTesting(modifier(down: true, at: 100))
        manager.monitoredEventForTesting(scrolling)
        manager.monitoredEventForTesting(modifier(down: false, at: 100.1))
        XCTAssertEqual(probe.toggles, 0, "⌘ + scrolling stopped the dictation")
    }

    func testCommandWithButtonAlreadyHeldDoesNotStop() throws {
        let (manager, probe, cleanup) = try makeManager(recording: true)
        defer { cleanup() }
        manager.pressedMouseButtonsForTesting = 1
        manager.monitoredEventForTesting(modifier(down: true, at: 100))
        manager.monitoredEventForTesting(modifier(down: false, at: 100.1))
        XCTAssertEqual(probe.toggles, 0, "⌘ with a mouse button held stopped the dictation")
    }

    func testTwoQuickCommandClicksDoNotStartDictation() throws {
        let (manager, probe, cleanup) = try makeManager(recording: false)
        defer { cleanup() }
        commandClick(manager, at: 100)
        commandClick(manager, at: 100.15)
        XCTAssertEqual(probe.toggles, 0, "two ⌘-clicks started a dictation")
    }

    // MARK: Controls: the gesture itself still works

    func testSingleTapStillStopsRecording() throws {
        let (manager, probe, cleanup) = try makeManager(recording: true)
        defer { cleanup() }
        tap(manager, at: 100)
        XCTAssertEqual(probe.toggles, 1)
    }

    func testDoubleTapStillStarts() throws {
        let (manager, probe, cleanup) = try makeManager(recording: false)
        defer { cleanup() }
        tap(manager, at: 100)
        tap(manager, at: 100.15)
        XCTAssertEqual(probe.toggles, 1)
    }

    func testPointerMovementDoesNotBreakTheDoubleTap() throws {
        let (manager, probe, cleanup) = try makeManager(recording: false)
        defer { cleanup() }
        manager.monitoredEventForTesting(mouse(.mouseMoved, command: false, at: 99.9))
        manager.monitoredEventForTesting(modifier(down: true, at: 100))
        manager.monitoredEventForTesting(mouse(.mouseMoved, command: true, at: 100.02))
        manager.monitoredEventForTesting(modifier(down: false, at: 100.05))
        manager.monitoredEventForTesting(mouse(.mouseMoved, command: false, at: 100.1))
        manager.monitoredEventForTesting(modifier(down: true, at: 100.15))
        manager.monitoredEventForTesting(mouse(.mouseMoved, command: true, at: 100.17))
        manager.monitoredEventForTesting(modifier(down: false, at: 100.2))
        XCTAssertEqual(probe.toggles, 1, "moving the mouse without buttons broke the double tap")
    }

    func testMomentumScrollDoesNotBreakTheDoubleTap() throws {
        let (manager, probe, cleanup) = try makeManager(recording: false)
        defer { cleanup() }
        let momentum = try scroll(command: true, momentum: true)
        for start in [100, 100.15] {
            manager.monitoredEventForTesting(modifier(down: true, at: start))
            manager.monitoredEventForTesting(momentum)
            manager.monitoredEventForTesting(modifier(down: false, at: start + 0.05))
        }
        XCTAssertEqual(probe.toggles, 1, "momentum scrolling broke the double tap")
    }

    func testClickWithoutModifierBetweenTapsKeepsTheDoubleTap() throws {
        let (manager, probe, cleanup) = try makeManager(recording: false)
        defer { cleanup() }
        tap(manager, at: 100)
        manager.monitoredEventForTesting(mouse(.leftMouseDown, command: false, at: 100.08))
        manager.monitoredEventForTesting(mouse(.leftMouseUp, command: false, at: 100.1))
        tap(manager, at: 100.15)
        XCTAssertEqual(probe.toggles, 1)
    }

    // MARK: Helpers

    private func makeManager(
        recording: Bool
    ) throws -> (manager: HotkeyManager, probe: GestureProbe, cleanup: () -> Void) {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.MouseModifier.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = SettingsStore(defaults: defaults)
        settings.hotkeyActivation = .doubleModifier
        settings.doubleTapModifier = .rightCommand
        settings.doubleTapThresholdMS = 250
        let probe = GestureProbe()
        probe.recording = recording
        let manager = HotkeyManager(installsSystemHandlers: false)
        // The real mouse state of the test machine must not decide the result.
        manager.pressedMouseButtonsForTesting = 0
        manager.activate(
            settings: settings,
            onToggle: { probe.toggles += 1 },
            isRecording: { probe.recording }
        )
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
            withExtendedLifetime(settings) {}
        }
        return (manager, probe, cleanup)
    }

    private func assertClickWithModifierDoesNotStop(
        _ down: NSEvent.EventType, _ up: NSEvent.EventType,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let (manager, probe, cleanup) = try makeManager(recording: true)
        defer { cleanup() }
        manager.monitoredEventForTesting(modifier(down: true, at: 100))
        manager.monitoredEventForTesting(mouse(down, command: true, at: 100.03))
        manager.monitoredEventForTesting(mouse(up, command: true, at: 100.06))
        manager.monitoredEventForTesting(modifier(down: false, at: 100.1))
        XCTAssertEqual(probe.toggles, 0, "⌘ + click (\(down)) stopped the dictation", file: file, line: line)
    }

    private func tap(_ manager: HotkeyManager, at time: TimeInterval) {
        manager.monitoredEventForTesting(modifier(down: true, at: time))
        manager.monitoredEventForTesting(modifier(down: false, at: time + 0.05))
    }

    private func commandClick(_ manager: HotkeyManager, at time: TimeInterval) {
        manager.monitoredEventForTesting(modifier(down: true, at: time))
        manager.monitoredEventForTesting(mouse(.leftMouseDown, command: true, at: time + 0.01))
        manager.monitoredEventForTesting(mouse(.leftMouseUp, command: true, at: time + 0.03))
        manager.monitoredEventForTesting(modifier(down: false, at: time + 0.05))
    }

    private func modifier(down: Bool, at time: TimeInterval) -> NSEvent {
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

    private func mouse(_ type: NSEvent.EventType, command: Bool, at time: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: time,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func scroll(command: Bool, momentum: Bool) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0
        ))
        event.flags = command ? .maskCommand : []
        if momentum {
            // kCGMomentumScrollPhaseContinue: inertia after the fingers left.
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        } else {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))
        }
        let converted = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertEqual(converted.type, .scrollWheel)
        XCTAssertEqual(!converted.momentumPhase.isEmpty, momentum, "the scroll fixture is built wrong")
        return converted
    }
}
