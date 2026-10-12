import AppKit
import Combine
import Foundation
import KeyboardShortcuts

/// Global shortcuts remain Carbon-backed. Only double-modifier activation uses
/// NSEvent monitors, which need Accessibility but not Input Monitoring.
extension KeyboardShortcuts.Name {
    // Keep the historical UserDefaults keys while allowing the recorder to
    // continue changing the concrete combinations at runtime. The library
    // writes an initial combination into UserDefaults.standard the first time
    // such a name is touched, so a test copy declares none.
    static let dictate = Self(
        "dictate",
        initial: TestIsolation.isEnabled ? nil : .init(.space, modifiers: [.option])
    )
    static let meeting = Self(
        "meeting",
        initial: TestIsolation.isEnabled ? nil : .init(.r, modifiers: [.option, .shift])
    )
}

@MainActor
final class HotkeyManager {
    private struct Configuration: Equatable {
        let activation: HotkeyActivation
        let modifier: TapModifier
        let thresholdMilliseconds: Int
    }

    // A mouse button or live scrolling used with the modifier held is input
    // like a key. Plain pointer movement is not, so it stays out of the mask.
    private static let doubleModifierEventMask: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .scrollWheel,
    ]
    private static let recorderStatusDidChange = Notification.Name(
        "KeyboardShortcuts_recorderActiveStatusDidChange"
    )
    private static let chordModifierFlags: NSEvent.ModifierFlags = [
        .shift, .control, .option, .command, .function,
    ]

    private let installsSystemHandlers: Bool
    #if DEBUG
    /// Test-only: counts handlers handed to the system (each global hotkey and
    /// each NSEvent monitor), so a test can prove a copy registered none.
    static var systemRegistrationsForTesting = 0
    #endif
    private var configuration: Configuration?
    private var doubleModifierReducer = DoubleModifierReducer(
        modifier: .rightCommand,
        thresholdMilliseconds: 250
    )
    private var settingsCancellable: AnyCancellable?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var recorderObserver: NSObjectProtocol?
    private var onToggle: () -> Void = {}
    private var isRecording: () -> Bool = { false }

    /// A test copy installs no system handlers unless a test asks for them.
    init(installsSystemHandlers: Bool = !TestIsolation.isEnabled) {
        self.installsSystemHandlers = installsSystemHandlers
    }

    isolated deinit {
        settingsCancellable?.cancel()
        tearDownDictationRegistration()
    }

    func activate(
        settings: SettingsStore,
        onToggle: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.onToggle = onToggle
        self.isRecording = isRecording

        settingsCancellable?.cancel()
        settingsCancellable = Publishers.CombineLatest3(
            settings.$hotkeyActivation,
            settings.$doubleTapModifier,
            settings.$doubleTapThresholdMS
        )
        .map { values in
            Configuration(
                activation: values.0,
                modifier: values.1,
                thresholdMilliseconds: values.2
            )
        }
        .removeDuplicates()
        .sink { [weak self] configuration in
            self?.apply(configuration)
        }
    }

    private func apply(_ configuration: Configuration) {
        // KeyboardShortcuts appends legacy handlers, so remove the previous one
        // before every registration to prevent multiplicative taps.
        tearDownDictationRegistration()
        self.configuration = configuration
        doubleModifierReducer = DoubleModifierReducer(
            modifier: configuration.modifier,
            thresholdMilliseconds: configuration.thresholdMilliseconds
        )

        guard installsSystemHandlers else { return }
        #if DEBUG
        Self.systemRegistrationsForTesting += 1
        #endif
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            self?.shortcutKeyDown()
        }

        if configuration.activation == .doubleModifier {
            installDoubleModifierMonitors()
        }
        AppLog.info(
            "dictation",
            "hotkey activation → \(configuration.activation.rawValue)"
        )
    }

    private func shortcutKeyDown() {
        guard configuration != nil else { return }
        onToggle()
    }

    func dictationDidBecomeIdle() {
        doubleModifierReducer.reset()
    }

    private func installDoubleModifierMonitors() {
        #if DEBUG
        Self.systemRegistrationsForTesting += 1
        #endif
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: Self.doubleModifierEventMask
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMonitoredEvent(event)
            }
        }
        #if DEBUG
        Self.systemRegistrationsForTesting += 1
        #endif
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: Self.doubleModifierEventMask
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMonitoredEvent(event)
            }
            return event
        }

        // KeyboardShortcuts 3.0.1 exposes neither its pause flag nor this
        // notification publicly. The exact dependency pin makes the string a
        // controlled edge signal; active state is still read live from AppKit.
        recorderObserver = NotificationCenter.default.addObserver(
            forName: Self.recorderStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.doubleModifierReducer.reset()
            }
        }
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
        guard let configuration, configuration.activation == .doubleModifier else { return }
        guard !Self.recorderIsActive(in: NSApp.keyWindow) else {
            doubleModifierReducer.reset()
            return
        }

        let selectedFlag = configuration.modifier.eventFlag
        let selectedModifierDown = event.modifierFlags.contains(selectedFlag)
        let result: DoubleModifierResult?
        switch event.type {
        case .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            // A key or a mouse button used with the modifier held makes a
            // chord, not a tap: both take the reducer's `.keyDown` path.
            result = doubleModifierReducer.handle(
                .keyDown(selectedModifierDown: selectedModifierDown)
            )
        case .scrollWheel:
            // Momentum keeps arriving after the fingers have left the trackpad;
            // it must not cancel a tap made right after scrolling.
            guard event.momentumPhase.isEmpty else { return }
            result = doubleModifierReducer.handle(
                .keyDown(selectedModifierDown: selectedModifierDown)
            )
        case .flagsChanged:
            guard TapModifier(keyCode: event.keyCode) == configuration.modifier else {
                result = doubleModifierReducer.handle(
                    .otherModifierChanged(selectedModifierDown: selectedModifierDown)
                )
                break
            }
            let otherFlags = event.modifierFlags
                .intersection(Self.chordModifierFlags)
                .subtracting(selectedFlag)
            result = doubleModifierReducer.handle(
                .modifierChanged(
                    configuration.modifier,
                    isDown: selectedModifierDown,
                    // A mouse button already held (⌘ pressed mid-drag) makes a
                    // chord too; no mouse event arrives to say so.
                    otherModifiersDown: !otherFlags.isEmpty || pressedMouseButtons != 0,
                    timestamp: event.timestamp
                )
            )
        default:
            return
        }
        dispatchDoubleModifierResult(result)
    }

    private var pressedMouseButtons: Int {
        #if DEBUG
        if let pressedMouseButtonsForTesting { return pressedMouseButtonsForTesting }
        #endif
        return NSEvent.pressedMouseButtons
    }

    private func dispatchDoubleModifierResult(_ result: DoubleModifierResult?) {
        guard case .tapCompleted(let completesDoubleTap) = result else { return }
        if isRecording() {
            doubleModifierReducer.reset()
            onToggle()
        } else if completesDoubleTap {
            onToggle()
        }
    }

    private func tearDownDictationRegistration() {
        if installsSystemHandlers {
            KeyboardShortcuts.removeHandler(for: .dictate)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let recorderObserver {
            NotificationCenter.default.removeObserver(recorderObserver)
            self.recorderObserver = nil
        }
    }

    /// RecorderCocoa is an NSSearchField, so its field editor—not the control—
    /// becomes first responder while a shortcut is being captured.
    static func recorderIsActive(in window: NSWindow?) -> Bool {
        guard
            let window,
            let firstResponder = window.firstResponder,
            let contentView = window.contentView
        else { return false }
        return containsActiveRecorder(in: contentView, firstResponder: firstResponder)
    }

    private static func containsActiveRecorder(
        in view: NSView,
        firstResponder: NSResponder
    ) -> Bool {
        if let recorder = view as? KeyboardShortcuts.RecorderCocoa,
           recorder.currentEditor() === firstResponder {
            return true
        }
        return view.subviews.contains {
            containsActiveRecorder(in: $0, firstResponder: firstResponder)
        }
    }

    #if DEBUG
    func shortcutKeyDownForTesting() {
        shortcutKeyDown()
    }

    func resetDoubleModifierSequenceForTesting() {
        doubleModifierReducer.reset()
    }

    func doubleModifierEventForTesting(_ event: DoubleModifierEvent) {
        let result = doubleModifierReducer.handle(event)
        dispatchDoubleModifierResult(result)
    }

    /// Test-only: delivers an event the way the installed monitors do, only if
    /// the production mask lets its type through.
    func monitoredEventForTesting(_ event: NSEvent) {
        guard Self.doubleModifierEventMask.contains(NSEvent.EventTypeMask(type: event.type)) else { return }
        handleMonitoredEvent(event)
    }

    /// Test-only stand-in for `NSEvent.pressedMouseButtons`.
    var pressedMouseButtonsForTesting: Int?
    #endif

    static func registerMeeting(onToggle: @escaping () -> Void) {
        // A test copy must not take the user's meeting hotkey.
        guard !TestIsolation.isEnabled else { return }
        #if DEBUG
        Self.systemRegistrationsForTesting += 1
        #endif
        KeyboardShortcuts.onKeyDown(for: .meeting, action: onToggle)
    }
}
