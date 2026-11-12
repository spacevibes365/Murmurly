import AppKit
import Combine
import SwiftUI

/// The notepad window's own frame, in screen points. Stored as plain
/// numbers (not a fraction of a screen, unlike `OverlayPlacement`): the
/// window is user-resizable, so its remembered frame must carry a size, and
/// `OverlayGeometry.fittedFrame` pulls it back on-screen if the monitor it
/// was on is gone.
struct LiveTranscriptPanelFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The panel for the meeting's notepad: a click on it behaves as a click on
/// any app's window, activating Murmurly and making the panel front and key.
/// It is never main (`canBecomeMain == false`), which along with being an
/// `NSPanel` keeps `AppWindowController.isRealWindow` from counting it, so
/// there is no Dock icon. There is no main menu to dispatch editing
/// shortcuts from while the app stays `.accessory` even once active, so the
/// window matches them itself, by key code rather than by the current
/// keyboard layout's character, ⌘W included (no menu item to send it there
/// either).
@MainActor
final class NotepadNSWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘W / File → Close and the ✕ both end up here: returning `false` from
    /// `windowShouldClose` still has AppKit beep, so the close itself is
    /// overridden instead of refused through the delegate.
    var closeRequest: (@MainActor () -> Void)?

    override func performClose(_ sender: Any?) {
        closeRequest?()
    }

    /// ANSI key codes, not characters: on a non-Latin layout the physical
    /// A/C/V/X/Z/W keys produce other characters, and
    /// `charactersIgnoringModifiers` would miss them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 13, modifiers == [.command] {
            performClose(nil)
            return true
        }
        let selector: Selector?
        switch (event.keyCode, modifiers) {
        case (7, [.command]): selector = #selector(NSText.cut(_:))
        case (8, [.command]): selector = #selector(NSText.copy(_:))
        case (9, [.command]): selector = #selector(NSText.paste(_:))
        case (0, [.command]): selector = #selector(NSText.selectAll(_:))
        case (6, [.command]): selector = Selector(("undo:"))
        case (6, [.command, .shift]): selector = Selector(("redo:"))
        default: selector = nil
        }
        // `to: firstResponder`, not `to: nil`: a nil target resolves
        // through `NSApp.keyWindow`, which this window will be in ordinary
        // use (AppKit calls `performKeyEquivalent` only on the key window's
        // chain) but need not be the instant this is called directly — the
        // walk itself still starts at this window's own first responder and
        // climbs its chain, exactly as a nil target would for the key window.
        if let selector, NSApp.sendAction(selector, to: firstResponder, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

}

private final class LiveTranscriptHostingView: NSHostingView<NotepadHostedView> {
    /// The first click on a button (Stop, ★, the pin, ✕) activates the app
    /// and still presses the button, instead of only activating the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The library the notepad's "Open in Murmurly" and a click on a time go
/// through; nil until the menu bar label sets `MeetingRecorder.notepadLinks`
/// (soon after launch, but a recording's first render need not wait for
/// it), and again if the weak reference it holds is ever let go. A plain
/// environment slot, not `@EnvironmentObject`: that crashes outright while
/// the object is missing, and the window must show with nothing to open
/// rather than wait on it or crash.
private struct NotepadLibraryKey: EnvironmentKey {
    static let defaultValue: MeetingLibrary? = nil
}

extension EnvironmentValues {
    var notepadLibrary: MeetingLibrary? {
        get { self[NotepadLibraryKey.self] }
        set { self[NotepadLibraryKey.self] = newValue }
    }
}

/// Wraps `LiveTranscriptContentView` with the environment objects its slots
/// need (the same types the main window hands its own views): they reach the
/// recorder, the queue and the settings through `.environmentObject`, and
/// the library — which may still be missing — through `\.notepadLibrary`.
struct NotepadHostedView: View {
    let content: LiveTranscriptContentView
    let settings: SettingsStore
    let meeting: MeetingRecorder
    let queue: MeetingTranscriptionQueue
    let library: MeetingLibrary?

    var body: some View {
        content
            .environmentObject(settings)
            .environmentObject(meeting)
            .environmentObject(queue)
            .environment(\.notepadLibrary, library)
    }
}

/// Shows the recording's `LiveTranscriptModel` as a floating notepad: the
/// meeting's live text, time-stamped notes, search. Unlike the recording
/// indicator it is an ordinary, user-movable, user-resizable window, and it
/// stays open on the meeting it showed once the recording stops, until
/// closed or a new recording with live text begins.
///
/// No stored flag says whether it is shown: visibility is computed from the
/// recorder's state, its live-transcript model, its stopped snapshot and the
/// in-memory "closed by the user" flag the ✕/⌘W set.
@MainActor
final class LiveTranscriptPanel: NSObject, ObservableObject, NSWindowDelegate {
    static let minimumSize = CGSize(width: 320, height: 160)
    private static let defaultSize = CGSize(width: 380, height: 240)

    /// Whether the window is on screen right now.
    @Published private(set) var isShown = false
    /// Whether "Show Live Transcript" in the menu would do something: the
    /// setting is on and there is a meeting to show it for, whatever its
    /// own visibility — hidden by the ✕, or merely covered by another app's
    /// window. With the setting off, or nothing to show, the item would do
    /// nothing, so it is not offered.
    @Published private(set) var canReopen = false

    /// One notepad model per panel, handed to `LiveTranscriptContentView` and
    /// its slots; `render()` keeps it in step with the recording's own.
    let notepad = NotepadModel()
    private weak var settings: SettingsStore?
    private weak var meeting: MeetingRecorder?
    private let renderingEnabled: Bool
    private var window: NotepadNSWindow?
    private var hostingView: LiveTranscriptHostingView?
    /// The ✕/⌘W, in memory only: during a recording this hides the window
    /// until it ends; once the meeting is stopped it closes the window.
    /// Cleared whenever the notepad moves to a genuinely new meeting, never
    /// written to disk.
    private var closedByUser = false

    private enum Displayed {
        case live(LiveTranscriptModel, MeetingRecorder.Session?)
        case stopped(MeetingRecorder.StoppedLiveTranscript)
    }

    /// What meeting the notepad is on now, so a stop on the same directory
    /// (live → stopped) is never mistaken for a new meeting: only a
    /// genuinely different directory — or, lacking one (a bare test probe),
    /// a different model object — resets the ✕ and the notepad's fields.
    private enum MeetingKey: Equatable {
        case none
        case directory(String)
        case model(ObjectIdentifier)
    }

    private var currentMeetingKey: MeetingKey = .none

    /// From the combined latest of the recorder's own published properties,
    /// never read directly from `meeting` inside the sink: `@Published`
    /// publishes in `willSet`, so a sink on one of these reading another
    /// straight off `meeting` can still see the value from before this very
    /// change.
    private var latestModel: LiveTranscriptModel?
    private var latestState: MeetingRecorder.State = .idle
    private var latestSession: MeetingRecorder.Session?
    private var latestStopped: MeetingRecorder.StoppedLiveTranscript?
    /// Mid-recording on/off: the window itself follows the setting live, so
    /// flipping it hides or shows the window at once. The recorder only reads
    /// the setting once, when a recording starts, to decide whether to build
    /// a model at all — a change mid-recording cannot make it build one.
    private var settingEnabled = true
    private var moveSaveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, meeting: MeetingRecorder, renderingEnabled: Bool = true) {
        self.settings = settings
        self.meeting = meeting
        self.renderingEnabled = renderingEnabled
        self.settingEnabled = settings.liveTranscript
        super.init()
        observe(meeting: meeting)
        observe(settings: settings)
        observeActivation()
        #if DEBUG
        NotepadProbe.applyIfRequested(to: meeting)
        #endif
    }

    /// State-only tests do not need a settings domain or a live AppKit window.
    convenience init(renderingEnabled: Bool) {
        precondition(!renderingEnabled)
        self.init(settings: nil, meeting: nil, renderingEnabled: false)
    }

    private init(settings: SettingsStore?, meeting: MeetingRecorder?, renderingEnabled: Bool) {
        self.settings = settings
        self.meeting = meeting
        self.renderingEnabled = renderingEnabled
        super.init()
        observeActivation()
    }

    /// The ✕/⌘W: hides the notepad while recording, closes it once stopped.
    func close() {
        closedByUser = true
        render()
    }

    /// "Show Live Transcript" in the menu: brings back the last meeting if
    /// the ✕ hid it, and either way activates Murmurly and brings the
    /// notepad front and key — the menu item itself does not activate the
    /// app, so without this the notepad would only reappear behind whatever
    /// app is in front. `orderFrontRegardless()` does the actual raise, as
    /// elsewhere in this file: `NSApp.activate()` is asynchronous, and
    /// `makeKeyAndOrderFront` alone does not reliably win the raise before
    /// activation completes.
    func show() {
        closedByUser = false
        render()
        guard renderingEnabled else { return }
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    private func observe(meeting: MeetingRecorder) {
        Publishers.CombineLatest4(
            meeting.$liveTranscriptModel, meeting.$state, meeting.$currentSession, meeting.$stoppedLiveTranscript
        )
        .sink { [weak self] model, state, session, stopped in
            guard let self else { return }
            self.latestModel = model
            self.latestState = state
            self.latestSession = session
            self.latestStopped = stopped
            self.render()
        }
        .store(in: &cancellables)
        meeting.$notepadLinks
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    private func observe(settings: SettingsStore) {
        settings.$liveTranscript
            .sink { [weak self] enabled in
                guard let self else { return }
                self.settingEnabled = enabled
                self.render()
            }
            .store(in: &cancellables)
        settings.$liveTranscriptKeepOnTop
            .sink { [weak self] pinned in
                guard let self else { return }
                self.notepad.isPinned = pinned
                self.applyKeepOnTop(pinned)
            }
            .store(in: &cancellables)
    }

    /// Mission Control's own window picker, and any other activation of
    /// Murmurly that is not a click on the notepad itself, do not raise the
    /// panel on their own. If the activation actually reaches the app (the
    /// Dock, Mission Control and WindowServer decide it, not this code;
    /// Mission Control's choice was seen to reach it) while the panel is visible and
    /// no real window of this app is open, raise it the same way a click
    /// would.
    private func observeActivation() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.raiseOnActivation() }
            .store(in: &cancellables)
    }

    private func raiseOnActivation() {
        guard renderingEnabled, isShown, let window else { return }
        // Any other window of this app on screen (a real window, the folder
        // panel of Transcribe Meeting…, a sheet, a modal one, Sparkle's) is
        // what the activation was for; the recording indicator and the menu
        // bar's own windows sit at the status-bar level and above, so they
        // never count. `occlusionState` was tried as a tighter check (an
        // `isVisible` window can be off screen, as AppKit's own accessory
        // window for a disclosed folder-panel accessory is) but a headless
        // CI run never settles it to `.visible` for freshly ordered-front
        // test windows either, real blockers included, so both of
        // `NotepadWindowTests`' activation-blocked tests broke on it; the
        // accessory window's leak is closed at its source instead (the test
        // that built it now closes every window it adds).
        guard NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.level < .statusBar })
        else { return }
        window.orderFrontRegardless()
        AppLog.info("notepad", "raised on activation")
    }

    func windowDidMove(_ notification: Notification) {
        guard isUserDriven(notification) else { return }
        scheduleSave()
    }

    func windowDidResize(_ notification: Notification) {
        guard isUserDriven(notification) else { return }
        scheduleSave()
    }

    private func isUserDriven(_ notification: Notification) -> Bool {
        guard let window, notification.object as? NSWindow === window else { return false }
        return NSApp.currentEvent?.type == .leftMouseDragged || NSEvent.pressedMouseButtons & 1 != 0
    }

    private func scheduleSave() {
        guard let window else { return }
        let frame = window.frame
        moveSaveTask?.cancel()
        moveSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            self?.settings?.liveTranscriptPanelFrame = LiveTranscriptPanelFrame(frame)
        }
    }

    private static func meetingKey(for displayed: Displayed?) -> MeetingKey {
        switch displayed {
        case nil:
            return .none
        case .live(let model, let session):
            if let session { return .directory(session.directory.standardizedFileURL.path) }
            return .model(ObjectIdentifier(model))
        case .stopped(let stopped):
            return .directory(stopped.directory.standardizedFileURL.path)
        }
    }

    private func render() {
        let isLive = latestModel != nil && latestState == .recording
        let displayed: Displayed?
        if isLive, let model = latestModel {
            displayed = .live(model, latestSession)
        } else if let stopped = latestStopped {
            displayed = .stopped(stopped)
        } else {
            displayed = nil
        }

        let newKey = Self.meetingKey(for: displayed)
        var isNewMeeting = false
        if newKey != currentMeetingKey {
            currentMeetingKey = newKey
            if newKey != .none {
                closedByUser = false
                notepad.resetForMeeting()
                isNewMeeting = true
            }
        }

        guard let displayed else {
            isShown = false
            canReopen = false
            return
        }

        switch displayed {
        case .live(let model, let session):
            if notepad.liveModel !== model { notepad.liveModel = model }
            let liveMeeting = session.map {
                NotepadMeeting(identity: $0.identity, folder: $0.directory, startedAt: $0.startedAt, isRecording: true)
            }
            if notepad.meeting != liveMeeting { notepad.meeting = liveMeeting }
        case .stopped(let stopped):
            if notepad.liveModel != nil { notepad.liveModel = nil }
            if notepad.keptLines != stopped.lines { notepad.keptLines = stopped.lines }
            // The notepad keeps the meeting's own address and identity even
            // after the queue moves the folder: the marks writer follows the
            // move itself (`MeetingLibrary.writeMarks`/`followMove`), and only
            // showing and opening go through `queue.location(of:)`.
            let stoppedMeeting = NotepadMeeting(
                identity: stopped.identity, folder: stopped.directory, startedAt: stopped.startedAt, isRecording: false
            )
            if notepad.meeting != stoppedMeeting { notepad.meeting = stoppedMeeting }
        }

        let shouldShow = settingEnabled && !closedByUser
        isShown = shouldShow
        canReopen = settingEnabled
        guard renderingEnabled else { return }
        guard shouldShow else {
            window?.orderOut(nil)
            return
        }
        buildWindowIfNeeded()
        guard installContentIfPossible(), let window else { return }
        if !window.isVisible {
            window.setFrame(targetFrame(), display: true)
            window.orderFrontRegardless()
        } else if isNewMeeting {
            window.orderFrontRegardless()
        }
    }

    private func targetFrame() -> CGRect {
        let screens = screenGeometries
        if let stored = settings?.liveTranscriptPanelFrame?.rect,
           let fitted = OverlayGeometry.fittedFrame(stored, minSize: Self.minimumSize, screens: screens) {
            return fitted
        }
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return CGRect(origin: .zero, size: Self.defaultSize)
        }
        return OverlayGeometry.defaultFrame(panelSize: Self.defaultSize, visibleFrame: visibleFrame)
    }

    private var screenGeometries: [IndicatorScreenGeometry] {
        NSScreen.screens.compactMap(\.indicatorGeometry)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let window = NotepadNSWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        // An NSPanel hides on deactivation by default; the notepad must stay
        // on screen while the user is back in the call app.
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isFloatingPanel = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = Self.minimumSize
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.title = String(localized: "Live transcript")
        window.identifier = NSUserInterfaceItemIdentifier("notepadWindow")
        window.delegate = self
        window.closeRequest = { [weak self] in self?.close() }
        self.window = window
        // "Edit Note" from the context menu reaches a field without a click
        // on the window (a secondary click does not activate the app), so it
        // must activate Murmurly and make the panel key itself, or the
        // typing that follows would go to whatever app is in front.
        notepad.requestKeyboard = { [weak window] in
            NSApp.activate()
            window?.orderFrontRegardless()
            window?.makeKey()
        }
        applyKeepOnTop(notepad.isPinned)
    }

    /// Only once `settings`, the recorder and its queue are available (in
    /// practice from the first render: the recorder already carries its
    /// queue by the time this panel is built). The slots reach those three
    /// through `.environmentObject`, which crashes outright if one is
    /// missing; the library is different — it arrives later than the rest,
    /// through `meeting.notepadLinks`, set by the menu bar label — so it
    /// goes through the plain, optional `\.notepadLibrary` slot instead, and
    /// is refreshed into the already-built content on every call rather
    /// than gating it: a slot reading a missing library simply has nothing
    /// to open yet.
    @discardableResult
    private func installContentIfPossible() -> Bool {
        guard let window, let settings, let meeting, let queue = meeting.transcripts else { return false }
        let rootView = NotepadHostedView(
            content: LiveTranscriptContentView(notepad: notepad, onClose: { [weak self] in self?.close() }),
            settings: settings,
            meeting: meeting,
            queue: queue,
            library: meeting.notepadLinks?.library
        )
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = LiveTranscriptHostingView(rootView: rootView)
            hostingView.sizingOptions = []
            window.contentView = hostingView
            self.hostingView = hostingView
        }
        return true
    }

    private func applyKeepOnTop(_ pinned: Bool) {
        guard let window else { return }
        if pinned {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            window.level = .normal
            window.collectionBehavior = [.fullScreenNone]
        }
    }

    #if DEBUG
    /// For `LiveTranscriptPanelTests`/`NotepadWindowTests`: builds the real
    /// window without the settings/recorder wiring, so a test can check it
    /// activates on a click, is never main, and is not an
    /// `AppWindowController` real window.
    convenience init(forPanelTestingOnly: Void = ()) {
        self.init(settings: nil, meeting: nil, renderingEnabled: true)
    }

    func buildWindowForTesting() { buildWindowIfNeeded() }
    var windowForTesting: NSWindow? { window }

    /// `isShown` is otherwise only ever set by `render()`, which needs a
    /// real recorder and queue; this lets `NotepadWindowTests` exercise
    /// `raiseOnActivation()` without wiring one.
    func setShownForTesting(_ shown: Bool) { isShown = shown }
    #endif
}

/// `-UITesting -NotepadProbe`: fakes `.recording` with a model already
/// carrying made-up lines, and optionally its stop, without a capture or an
/// engine, so `NotepadWindowUITests` has a notepad to look at. Kept apart
/// from `LiveTranscriptProbe.swift`, used by `LiveTranscriptPanelUITests`,
/// so the two probes' made-up lines are never mistaken for each other.
#if DEBUG
enum NotepadProbe {
    @MainActor
    static func applyIfRequested(to meeting: MeetingRecorder) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-UITesting"), arguments.contains("-NotepadProbe") else { return }
        let startAfter = argument(arguments, named: "-NotepadProbeStartAfter") ?? 0
        let stopAfter = argument(arguments, named: "-NotepadProbeStopAfter")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(startAfter))
            let model = LiveTranscriptModel()
            model.publishForTesting(lines: madeUpLines(), state: .running)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString) Meeting")
            meeting.publishLiveTranscriptForTesting(state: .recording, model: model, directory: directory)
            guard let stopAfter else { return }
            try? await Task.sleep(for: .seconds(stopAfter))
            meeting.stopLiveTranscriptForTesting()
        }
    }

    private static func argument(_ arguments: [String], named name: String) -> Double? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return Double(arguments[index + 1])
    }

    /// Fictional lines, no owner data, deliberately different from
    /// `LiveTranscriptProbe`'s own so the two never get mistaken for each
    /// other on screen.
    private static func madeUpLines() -> [LiveLine] {
        let now = Date.timeIntervalSinceReferenceDate
        let speakers: [(LiveTranscript.Track, String)] = [
            (.microphone, "Let’s check the agenda."),
            (.system, "Sounds good."),
            (.microphone, "Next, the release date.")
        ]
        return speakers.enumerated().map { offset, entry in
            let (track, text) = entry
            let start = now + Double(offset) * 4
            return LiveLine(
                id: UUID(), track: track, start: start, end: start + 2,
                rawText: text, displayText: text, name: nil, isFinal: true
            )
        }
    }
}
#endif

/// The notepad's state label, top left: while recording, the live-transcript
/// model's state; once stopped, the recording's own outcome and, for this
/// meeting, the transcription queue's step.
struct NotepadStatusView: View {
    @ObservedObject var notepad: NotepadModel
    @EnvironmentObject private var meeting: MeetingRecorder
    @EnvironmentObject private var queue: MeetingTranscriptionQueue

    var body: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(statusText)
            .accessibilityIdentifier("liveTranscriptStateLabel")
    }

    private var statusText: String {
        if let liveModel = notepad.liveModel {
            return Self.stateText(liveModel.state)
        }
        guard let outcome = meeting.stoppedLiveTranscript?.outcome else {
            return Self.stateText(.waitingForSpeech)
        }
        // The notepad keeps the meeting's own, pre-move address; the queue's
        // own move gives its pending and active work the new one.
        let path = notepad.meeting.map { queue.location(of: $0.folder).standardizedFileURL.path }
        let isActive = path != nil && queue.activeFolder?.standardizedFileURL.path == path
        let step = isActive ? queue.stepLabel : nil
        let isQueued = path != nil && queue.pending.contains {
            $0.transcribe && $0.folder.standardizedFileURL.path == path
        }
        return Self.stoppedText(outcome: outcome, step: step, isQueued: isQueued)
    }

    static func stateText(_ state: LiveTranscriptModel.State) -> String {
        switch state {
        case .waitingForSpeech:
            return String(localized: "Waiting for speech…")
        case .preparingModel:
            return String(localized: "Preparing model…")
        case .running:
            return String(localized: "Live transcript")
        case .lagging:
            return String(localized: "Falling behind…")
        case .skipped(let count):
            return String(localized: "Skipped \(count) chunks")
        case .stopped(let reason):
            return String(localized: "Stopped: \(reason)")
        case .noModel:
            return String(localized: "No model downloaded. Download one in Settings → Dictation.")
        }
    }

    /// `step`: this meeting's own `queue.stepLabel`, only while the queue is
    /// actively working on it (not another meeting's). `isQueued`: this
    /// meeting is in `queue.pending` with `transcribe` set.
    static func stoppedText(
        outcome: MeetingRecorder.StoppedLiveTranscript.Outcome, step: String?, isQueued: Bool
    ) -> String {
        switch outcome {
        case .saving:
            return String(localized: "Saving the recording…")
        case .failed(let reason):
            return String(localized: "Stopped: \(reason)")
        case .saved(let warning):
            if let step {
                return step
            }
            if isQueued {
                return String(localized: "Waiting to be transcribed")
            }
            return warning
                ? String(localized: "Meeting saved with a warning — details in the “M” menu")
                : String(localized: "Meeting saved")
        }
    }
}

/// Top right: during a recording, Stop; once stopped, this meeting's queue
/// status and "Open in Murmurly"; always the pin and the ✕.
struct NotepadWindowControls: View {
    @ObservedObject var notepad: NotepadModel
    let onClose: () -> Void
    @EnvironmentObject private var meeting: MeetingRecorder
    @EnvironmentObject private var queue: MeetingTranscriptionQueue
    @Environment(\.notepadLibrary) private var library: MeetingLibrary?
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 6) {
            if notepad.liveModel != nil, meeting.state == .recording {
                Button {
                    meeting.toggle()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .accessibilityIdentifier("notepadStopButton")
            } else if let stopped = meeting.stoppedLiveTranscript, notepad.meeting?.isRecording == false {
                Button(String(localized: "Open in Murmurly")) {
                    guard let library else { return }
                    library.open(queue.location(of: stopped.directory))
                    MeetingLibrary.showMainWindow?()
                }
                .controlSize(.small)
                .accessibilityIdentifier("notepadOpenButton")
            }
            Toggle(isOn: $settings.liveTranscriptKeepOnTop) {
                Image(systemName: settings.liveTranscriptKeepOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .help("Keep on Top")
            .accessibilityIdentifier("notepadPinButton")
            .accessibilityLabel(Text("Keep on Top"))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("liveTranscriptCloseButton")
            .accessibilityLabel(Text("Hide Live Transcript"))
        }
    }
}

/// A line's or a note's recording time in the notepad, shown beside every
/// live line and every note. A click opens the saved meeting there
/// (`MeetingLibrary.openAndPlay`); unavailable while the recorder is busy or
/// there is no saved meeting yet.
struct NotepadTimeButton: View {
    let seconds: Double
    @ObservedObject var notepad: NotepadModel
    @EnvironmentObject private var meeting: MeetingRecorder
    @EnvironmentObject private var queue: MeetingTranscriptionQueue
    @Environment(\.notepadLibrary) private var library: MeetingLibrary?
    @State private var refusal: String?

    static func isAvailable(recorder: MeetingRecorder.State, meeting: NotepadMeeting?) -> Bool {
        guard let meeting, !meeting.isRecording else { return false }
        return !recorder.isBusy
    }

    private var isAvailable: Bool {
        Self.isAvailable(recorder: meeting.state, meeting: notepad.meeting)
    }

    var body: some View {
        Button {
            guard let library, let folder = notepad.meeting?.folder else { return }
            refusal = library.openAndPlay(folder: queue.location(of: folder), at: seconds)
        } label: {
            Text(verbatim: TranscriptSegment.timecode(seconds))
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(isAvailable ? "" : String(localized: "Available once the recording is saved"))
        .accessibilityIdentifier("notepadTimeButton")
        .popover(isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            if let refusal { Text(refusal).padding(8) }
        }
    }
}

extension NotepadModel {
    /// A genuinely new meeting under the notepad drops every field that
    /// belongs to the meeting just left; `isPinned` is a setting, not part
    /// of a meeting, and is left as it is.
    func resetForMeeting() {
        keptLines = []
        notes = []
        lineSelection = nil
        momentLineIDs = [:]
        pendingNoteIDs = []
        noteFailures = [:]
        searchQuery = ""
        matchLineIDs = []
        currentMatch = nil
        highlightedLineID = nil
        isFollowingBottom = true
        // A note's draft lives in the view's own `NoteDraftController`, not
        // here: this counter tells it a genuinely new meeting began, so a
        // draft started on the meeting just left is dropped rather than
        // delivered to the new one.
        meetingGeneration += 1
    }
}
