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
    static let pasteLastDictation = Self(
        "pasteLastDictation",
        initial: TestIsolation.isEnabled ? nil : .init(.v, modifiers: [.control, .command])
    )
    static let copyLastDictation = Self(
        "copyLastDictation",
        initial: TestIsolation.isEnabled ? nil : .init(.c, modifiers: [.control, .command])
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
    private var onHoldBegan: () -> Void = {}
    private var onHoldEnded: () -> Void = {}
    private var onEscape: () -> Void = {}
    /// The tasks iterating each registered shortcut's stream, by shortcut; a
    /// shortcut's own handle is what "listening" for it means — no separate
    /// flag that could fall out of sync with it.
    private var escapeListeners: [KeyboardShortcuts.Shortcut: (id: UUID, task: Task<Void, Never>)] = [:]
    /// A test copy's stand-in streams: same open/closed life as the real
    /// ones, but no system hotkey.
    private var escapeContinuations: [KeyboardShortcuts.Shortcut: AsyncStream<KeyboardShortcuts.EventType>.Continuation] = [:]

    /// A test copy installs no system handlers unless a test asks for them.
    init(installsSystemHandlers: Bool = !TestIsolation.isEnabled) {
        self.installsSystemHandlers = installsSystemHandlers
    }

    isolated deinit {
        settingsCancellable?.cancel()
        tearDownDictationRegistration()
        closeEscapeListener()
    }

    /// Esc is taken from every app while registered: open exactly
    /// `shortcuts`, close the rest. Idempotent; a shortcut already open only
    /// gets the new callback.
    func listenForEscape(_ shortcuts: Set<KeyboardShortcuts.Shortcut>, onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        for shortcut in escapeListeners.keys where !shortcuts.contains(shortcut) {
            closeEscapeListener(for: shortcut)
        }
        for shortcut in shortcuts where escapeListeners[shortcut] == nil {
            openEscapeListener(for: shortcut)
        }
    }

    /// Ending a stream (by cancelling the task that iterates it) is what
    /// unregisters its Carbon hotkey; KeyboardShortcuts does that on the next
    /// main-actor turn.
    func closeEscapeListener() {
        listenForEscape([]) {}
    }

    private func openEscapeListener(for shortcut: KeyboardShortcuts.Shortcut) {
        let events: AsyncStream<KeyboardShortcuts.EventType>
        if installsSystemHandlers {
            #if DEBUG
            Self.systemRegistrationsForTesting += 1
            #endif
            events = KeyboardShortcuts.events(for: shortcut)
        } else {
            let (stream, continuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
            escapeContinuations[shortcut] = continuation
            events = stream
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            for await event in events where event == .keyDown {
                self?.onEscape()
            }
            self?.escapeListenerEnded(shortcut, id)
        }
        escapeListeners[shortcut] = (id, task)
    }

    private func closeEscapeListener(for shortcut: KeyboardShortcuts.Shortcut) {
        escapeListeners[shortcut]?.task.cancel()
        escapeListeners[shortcut] = nil
        escapeContinuations[shortcut]?.finish()
        escapeContinuations[shortcut] = nil
    }

    private func escapeListenerEnded(_ shortcut: KeyboardShortcuts.Shortcut, _ id: UUID) {
        if escapeListeners[shortcut]?.id == id { escapeListeners[shortcut] = nil }
    }

    /// Esc as pressed while holding `shortcut`: its modifiers stay down, so
    /// the system sees ⌥Esc, not Esc. nil when that is just Esc or the held
    /// shortcut has no modifiers (`.function` is dropped: Carbon has no
    /// fn modifier).
    static func escapeChord(holding shortcut: KeyboardShortcuts.Shortcut?) -> KeyboardShortcuts.Shortcut? {
        guard let shortcut, shortcut.key != .escape else { return nil }
        let modifiers = shortcut.modifiers.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else { return nil }
        return .init(.escape, modifiers: modifiers)
    }

    func activate(
        settings: SettingsStore,
        onToggle: @escaping () -> Void,
        isRecording: @escaping () -> Bool,
        onHoldBegan: @escaping () -> Void = {},
        onHoldEnded: @escaping () -> Void = {}
    ) {
        self.onToggle = onToggle
        self.isRecording = isRecording
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded

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

        if configuration.activation == .hold {
            #if DEBUG
            Self.systemRegistrationsForTesting += 1
            #endif
            KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
                self?.shortcutKeyUp()
            }
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
        guard let configuration else { return }
        if configuration.activation == .hold {
            onHoldBegan()
        } else {
            onToggle()
        }
    }

    private func shortcutKeyUp() {
        guard configuration?.activation == .hold else { return }
        onHoldEnded()
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

    func shortcutKeyUpForTesting() {
        shortcutKeyUp()
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

    /// What is registered (or, in a test copy, would be): the live handles,
    /// never a separate list that could drift from them.
    var escapeShortcutsForTesting: Set<KeyboardShortcuts.Shortcut> {
        Set(escapeListeners.filter { !$0.value.task.isCancelled }.keys)
    }

    /// Reads the listeners' real handles: open only while at least one task
    /// is alive and not cancelled, never a separate flag that could drift
    /// from it.
    var isEscapeListenerOpenForTesting: Bool { !escapeShortcutsForTesting.isEmpty }

    /// Puts a key-down on that shortcut's stand-in stream, the same path a
    /// real Esc takes. Returns whether there was a listener to receive it; a
    /// shortcut that is not registered never calls `onEscape`, and the
    /// caller still has to confirm the event was handled (not just queued).
    @discardableResult
    func pressEscapeForTesting(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        guard let continuation = escapeContinuations[shortcut] else { return false }
        continuation.yield(.keyDown)
        return true
    }

    @discardableResult
    func pressEscapeForTesting() -> Bool { pressEscapeForTesting(.init(.escape)) }
    #endif

    static func registerMeeting(onToggle: @escaping () -> Void) {
        // A test copy must not take the user's meeting hotkey.
        guard !TestIsolation.isEnabled else { return }
        #if DEBUG
        Self.systemRegistrationsForTesting += 1
        #endif
        KeyboardShortcuts.onKeyDown(for: .meeting, action: onToggle)
    }

    /// The target is the app in front at key-down; the paste itself waits for
    /// key-up, as the chord's own keys are still down at key-down.
    static func registerLastDictation(
        onPasteDown: @escaping () -> Void,
        onPasteUp: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) {
        // A test copy must not take the user's shortcuts.
        guard !TestIsolation.isEnabled else { return }
        #if DEBUG
        Self.systemRegistrationsForTesting += 3
        #endif
        KeyboardShortcuts.onKeyDown(for: .pasteLastDictation, action: onPasteDown)
        KeyboardShortcuts.onKeyUp(for: .pasteLastDictation, action: onPasteUp)
        KeyboardShortcuts.onKeyDown(for: .copyLastDictation, action: onCopy)
    }
}
