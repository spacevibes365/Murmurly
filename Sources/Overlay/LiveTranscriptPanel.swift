import AppKit
import Combine
import SwiftUI

/// The live-transcript panel's own frame, in screen points. Stored as plain
/// numbers (not a fraction of a screen, unlike `OverlayPlacement`): the panel
/// is user-resizable, so its remembered frame must carry a size, and
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

/// A floating panel that must never become key or main, like the recording
/// indicator: a paste must not land in it, and it must never pull the app to
/// `.regular` by itself (`AppWindowController.isRealWindow` excludes every
/// `NSPanel`).
private final class NonKeyTranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LiveTranscriptHostingView: NSHostingView<LiveTranscriptContentView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the recording's `LiveTranscriptModel` like subtitles, floating above
/// ordinary windows on every Space and over full-screen apps. Unlike the
/// recording indicator it is user-movable and user-resizable, and its colours
/// follow the app's own appearance (set globally on `NSApp` by
/// `AppDelegate.followAppearance`), not a fixed dark look.
///
/// No stored flag says whether it is shown: visibility is computed from the
/// recorder's state, its live-transcript model and the in-memory "hidden for
/// this recording" flag the ✕ button sets.
@MainActor
final class LiveTranscriptPanel: NSObject, ObservableObject, NSWindowDelegate {
    static let minimumSize = CGSize(width: 320, height: 160)
    private static let defaultSize = CGSize(width: 380, height: 240)

    /// Whether the panel is on screen right now.
    @Published private(set) var isShown = false
    /// Whether "Show Live Transcript" in the menu would bring it back: only
    /// the ✕ hid it, during a recording with the setting on. With the setting
    /// turned off mid-recording the item would do nothing, so it is not offered.
    @Published private(set) var canReopen = false

    private weak var settings: SettingsStore?
    private weak var meeting: MeetingRecorder?
    private let renderingEnabled: Bool
    private var panel: NSPanel?
    private var hostingView: LiveTranscriptHostingView?
    /// In memory only, for the ✕ button: cleared whenever the recorder
    /// starts a fresh model (a new recording), never written to disk.
    private var dismissedForSession = false
    /// From the combined latest of `meeting.$liveTranscriptModel` and
    /// `meeting.$state`, never read directly from `meeting` inside the sink:
    /// `@Published` publishes in `willSet`, so a sink on one of the two
    /// reading the other property straight off `meeting` can still see the
    /// value from before this very change.
    private var latestModel: LiveTranscriptModel?
    private var latestState: MeetingRecorder.State = .idle
    /// Mid-recording on/off: the panel itself follows the setting live, so
    /// flipping it hides or shows the panel at once. The recorder only reads
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
    }

    /// State-only tests do not need a settings domain or a live AppKit panel.
    convenience init(renderingEnabled: Bool) {
        precondition(!renderingEnabled)
        self.init(settings: nil, meeting: nil, renderingEnabled: false)
    }

    private init(settings: SettingsStore?, meeting: MeetingRecorder?, renderingEnabled: Bool) {
        self.settings = settings
        self.meeting = meeting
        self.renderingEnabled = renderingEnabled
        super.init()
    }

    /// The ✕ button: hides until this recording ends.
    func hideForThisRecording() {
        dismissedForSession = true
        render()
    }

    /// "Show Live Transcript" in the menu.
    func show() {
        dismissedForSession = false
        render()
    }

    private func observe(meeting: MeetingRecorder) {
        Publishers.CombineLatest(meeting.$liveTranscriptModel, meeting.$state)
            .sink { [weak self] model, state in
                guard let self else { return }
                // A new recording starts a new `LiveTranscriptModel` object: the
                // ✕ is forgotten only then, by identity, never on a republish of
                // the same model (state changes, new lines) during one recording.
                if let model, model !== self.latestModel { self.dismissedForSession = false }
                self.latestModel = model
                self.latestState = state
                self.render()
            }
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
        guard let panel, notification.object as? NSWindow === panel else { return false }
        return NSApp.currentEvent?.type == .leftMouseDragged || NSEvent.pressedMouseButtons & 1 != 0
    }

    private func scheduleSave() {
        guard let panel else { return }
        let frame = panel.frame
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

    private func render() {
        let recordingWithText = latestModel != nil && latestState == .recording && settingEnabled
        let shouldShow = recordingWithText && !dismissedForSession
        isShown = shouldShow
        canReopen = recordingWithText && dismissedForSession
        guard renderingEnabled else { return }
        guard shouldShow, let model = latestModel else {
            panel?.orderOut(nil)
            return
        }
        buildPanelIfNeeded()
        guard let panel, let hostingView else { return }
        if hostingView.rootView.model !== model {
            hostingView.rootView = LiveTranscriptContentView(
                model: model,
                onClose: { [weak self] in self?.hideForThisRecording() }
            )
        }
        if !panel.isVisible {
            panel.setFrame(targetFrame(), display: true)
        }
        panel.orderFrontRegardless()
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

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let hostingView = LiveTranscriptHostingView(
            rootView: LiveTranscriptContentView(model: LiveTranscriptModel(), onClose: {})
        )
        hostingView.sizingOptions = []
        let panel = NonKeyTranscriptPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minimumSize
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hostingView
        panel.delegate = self
        self.hostingView = hostingView
        self.panel = panel
    }

    #if DEBUG
    /// For `LiveTranscriptPanelTests`: builds the real panel without the
    /// settings/recorder wiring, so a test can check it is never key or
    /// main and is not an `AppWindowController` real window.
    convenience init(forPanelTestingOnly: Void = ()) {
        self.init(settings: nil, meeting: nil, renderingEnabled: true)
    }

    func buildPanelForTesting() { buildPanelIfNeeded() }
    var panelForTesting: NSPanel? { panel }
    #endif
}

/// The panel's content: the model's state on top, then the most recent lines
/// that fit, newest at the bottom.
struct LiveTranscriptContentView: View {
    @ObservedObject var model: LiveTranscriptModel
    let onClose: () -> Void

    /// An upper bound, not a target: a taller panel shows more lines, a
    /// shorter one fewer, clipped to what actually fits (`.clipped()` below).
    static let defaultVisibleLines = 12

    var body: some View {
        ZStack {
            // A separate background layer carries the drag gesture: the panel
            // has no title bar to drag by (`.titleVisibility(.hidden)`), and
            // `isMovableByWindowBackground` does not reliably see through a
            // SwiftUI hosting view, so dragging needs its own gesture here —
            // never on the foreground content, or it would swallow the ✕
            // button's own click (`WindowDragGesture` is a macOS 15 API).
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .gesture(WindowDragGesture())

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Self.stateText(model.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("liveTranscriptStateLabel")
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("liveTranscriptCloseButton")
                    .accessibilityLabel(Text("Hide Live Transcript"))
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Spacer(minLength: 0)
                    ForEach(model.lines.suffix(Self.defaultVisibleLines)) { line in
                        LiveTranscriptLineView(line: line)
                            .accessibilityIdentifier("liveTranscriptLine")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipped()
            }
            .padding(12)
        }
        .frame(minWidth: LiveTranscriptPanel.minimumSize.width, maxWidth: .infinity, maxHeight: .infinity)
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
}

private struct LiveTranscriptLineView: View {
    let line: LiveLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(speaker).bold()
            Text(line.displayText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
        // `.combine` keeps this a single static-text element (what a UI test
        // finds by identifier); its automatic label's exact shape (what goes
        // in `label` vs. `value`) is not guaranteed, so the explicit label
        // below — which takes priority over it — carries the full text.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speaker): \(line.displayText)")
    }

    private var speaker: String {
        line.name ?? (line.track == .microphone
            ? MeetingTranscript.microphoneLabel
            : MeetingTranscript.systemLabel)
    }
}
