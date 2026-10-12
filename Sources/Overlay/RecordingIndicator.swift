import AppKit
import Combine
import SwiftUI

/// A floating panel that must never become key. Synthetic paste is routed to
/// the key window, so allowing this panel to take focus would swallow ⌘V.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IndicatorHostingView: NSHostingView<IndicatorView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class RecordingIndicator: NSObject, ObservableObject, NSWindowDelegate {
    private struct Flash {
        let state: IndicatorState
        let generation: UInt
        let deadline: ContinuousClock.Instant
    }

    @Published private(set) var compactPositionText = String(localized: "Position: default")

    private let renderingEnabled: Bool
    private let levelMeter: MicrophoneLevelMeter
    private weak var settings: SettingsStore?
    private var overlayEnabled: Bool
    private var placement: OverlayPlacement?
    private var panel: NSPanel?
    private var hostingView: IndicatorHostingView?
    private var base: IndicatorState?
    private var flash: Flash?
    private var flashGeneration: UInt = 0
    private var flashTask: Task<Void, Never>?
    private var moveSaveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: SettingsStore,
        levelMeter: MicrophoneLevelMeter,
        renderingEnabled: Bool = true
    ) {
        self.settings = settings
        self.levelMeter = levelMeter
        self.renderingEnabled = renderingEnabled
        overlayEnabled = settings.overlayEnabled
        placement = settings.overlayPlacement
        super.init()
        observe(settings: settings)
        updateCompactPositionText()
    }

    /// State-only tests do not need a settings domain or a live AppKit panel.
    convenience init(renderingEnabled: Bool) {
        precondition(!renderingEnabled)
        self.init(
            settings: nil,
            levelMeter: MicrophoneLevelMeter(),
            renderingEnabled: false
        )
    }

    private init(
        settings: SettingsStore?,
        levelMeter: MicrophoneLevelMeter,
        renderingEnabled: Bool
    ) {
        self.settings = settings
        self.levelMeter = levelMeter
        self.renderingEnabled = renderingEnabled
        overlayEnabled = settings?.overlayEnabled ?? true
        placement = settings?.overlayPlacement
        super.init()
    }

    var presentedState: IndicatorState? { flash?.state ?? base }

    /// With the indicator off, errors still show, and so does why a dictation
    /// or a recording was refused: without it the shortcut looks dead.
    var visibleState: IndicatorState? {
        guard let state = presentedState else { return nil }
        return overlayEnabled || state.visualKind == .failure || state.isConflictFlash ? state : nil
    }

    /// Set or advance durable work. A new operation supersedes a terminal flash,
    /// while a conflict notice remains above the latest durable state.
    func setBase(_ state: IndicatorState) {
        if flash?.state.isConflictFlash != true {
            clearFlash()
        }
        base = state
        render()
    }

    /// Clear durable work without disturbing a transient notice already shown.
    func clearBase() {
        base = nil
        render()
    }

    /// End durable work and show its terminal result.
    @discardableResult
    func finish(with state: IndicatorState) -> UInt {
        base = nil
        return showFlash(state)
    }

    @discardableResult
    func showFlash(_ state: IndicatorState) -> UInt {
        guard let autoHide = state.autoHide else {
            assertionFailure("A persistent indicator state cannot be shown as a flash")
            return flashGeneration
        }
        flashTask?.cancel()
        flashGeneration &+= 1
        let generation = flashGeneration
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(autoHide))
        flash = Flash(state: state, generation: generation, deadline: deadline)
        render()
        flashTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.expireFlash(generation: generation)
        }
        return generation
    }

    func expireFlash(generation: UInt) {
        guard flash?.generation == generation else { return }
        flash = nil
        flashTask = nil
        render()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel,
              notification.object as? NSWindow === panel,
              NSApp.currentEvent?.type == .leftMouseDragged
                || NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let movedFrame = panel.frame
        guard let screen = OverlayGeometry.screen(
            containing: movedFrame,
            screens: screenGeometries
        ) else { return }
        moveSaveTask?.cancel()
        moveSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            self?.save(frame: movedFrame, on: screen)
        }
    }

    private func observe(settings: SettingsStore) {
        settings.$overlayEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled, self?.overlayEnabled == false {
                    self?.levelMeter.reset()
                }
                self?.overlayEnabled = enabled
                self?.render()
            }
            .store(in: &cancellables)
        settings.$overlayPlacement
            .removeDuplicates()
            .sink { [weak self] placement in
                self?.placement = placement
                self?.updateCompactPositionText()
                self?.render()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            self?.updateCompactPositionText()
            self?.render()
        }
        .store(in: &cancellables)
    }

    private func clearFlash() {
        flashTask?.cancel()
        flashTask = nil
        flash = nil
    }

    private func render() {
        guard renderingEnabled else { return }
        guard let state = visibleState else {
            if let hostingView {
                hostingView.rootView = IndicatorView(state: nil, levelMeter: levelMeter)
            }
            panel?.orderOut(nil)
            return
        }

        buildPanel()
        guard let panel, let hostingView else { return }
        hostingView.rootView = IndicatorView(state: state, levelMeter: levelMeter)
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard let frame = targetFrame(for: size) else { return }
        panel.setFrame(frame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    private func targetFrame(for panelSize: CGSize) -> CGRect? {
        let screens = screenGeometries
        let mainDisplayID = NSScreen.main?.indicatorGeometry?.displayID
        if let placement {
            return OverlayGeometry.frame(
                for: placement,
                panelSize: panelSize,
                screens: screens,
                mainDisplayID: mainDisplayID
            )
        }
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return nil }
        return OverlayGeometry.defaultFrame(panelSize: panelSize, visibleFrame: visibleFrame)
    }

    private func save(frame: CGRect, on screen: IndicatorScreenGeometry) {
        let newPlacement = OverlayGeometry.placement(of: frame, on: screen)
        guard newPlacement != placement else { return }
        settings?.overlayPlacement = newPlacement
    }

    private func updateCompactPositionText() {
        guard let placement else {
            compactPositionText = String(localized: "Position: default")
            return
        }
        let screens = screenGeometries
        let mainDisplayID = NSScreen.main?.indicatorGeometry?.displayID
        let compactSize = compactRecordingSize()
        guard let frame = OverlayGeometry.frame(
            for: placement,
            panelSize: compactSize,
            screens: screens,
            mainDisplayID: mainDisplayID
        ), let screen = OverlayGeometry.screen(containing: frame, screens: screens) else {
            compactPositionText = String(localized: "Position: default")
            return
        }
        let offset = OverlayGeometry.topLeftOffset(of: frame, in: screen.visibleFrame)
        compactPositionText = String(localized: "Position: remembered (\(Int(offset.x.rounded())), \(Int(offset.y.rounded())))")
    }

    /// Measured with the widest label a dictation shows: the countdown,
    /// which a recording that ends now displays at once.
    private func compactRecordingSize() -> CGSize {
        let now = Date()
        let view = NSHostingView(
            rootView: IndicatorView(
                state: .recordingDictation(startedAt: now, endsAt: now),
                levelMeter: nil
            )
        )
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private var screenGeometries: [IndicatorScreenGeometry] {
        NSScreen.screens.compactMap(\.indicatorGeometry)
    }

    private func buildPanel() {
        guard panel == nil else { return }
        let hostingView = IndicatorHostingView(
            rootView: IndicatorView(state: nil, levelMeter: levelMeter)
        )
        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hostingView
        panel.delegate = self
        self.hostingView = hostingView
        self.panel = panel
    }
}
