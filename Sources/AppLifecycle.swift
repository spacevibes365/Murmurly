import AppKit
import Combine

/// Production launches as a menu-bar accessory. UI tests opt into a normal app
/// so XCUITest can reliably discover and drive the on-demand settings window.
///
/// Every quit path (menu, ⌘Q, logout, SIGTERM from install.sh) ends in
/// `applicationShouldTerminate`. With active recordings quit runs in two
/// phases: the request is cancelled, the recordings are finished in the normal
/// event loop, and the app quits again on its own once they are confirmed
/// saved. Otherwise quit stays refused and the app keeps running.
///
/// Work that nothing redoes by itself — a transcription or the copy of its
/// transcript, a recording that will not be queued for one, Files' run and
/// its unsaved text — makes a person's quit warn first; quitting again soon
/// goes ahead. Logout and signals never wait for a person, so they only log
/// what is lost.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// What a quit now would lose. Only work already published in memory;
    /// audio is on disk and not counted.
    enum QuitLoss: CaseIterable, Hashable, Sendable {
        case meetingTranscription
        /// The transcript is written; its copy into the chosen transcripts
        /// folder is made once, by this job, and no scan makes it later.
        case transcriptCopy
        case recordingToTranscribe
        case fileTranscription
        case unsavedFileText
        /// A meeting's name, star or speakers' names the user set, still
        /// being written to a folder that is not on this Mac.
        case unsavedMeetingMark
        /// A meeting's transcript being written to the file the user chose.
        case transcriptFile
        /// "Recognize Again" is recognizing a saved dictation's audio; quit
        /// would cancel it before it can replace the entry's text. The entry
        /// and its audio are unaffected either way.
        case recognizeAgain

        /// Alone in the pill: what is lost and the way out.
        var warning: String {
            switch self {
            case .meetingTranscription:
                String(localized: "A meeting is being transcribed — quit again to stop it. Transcribe it later with Transcribe Meeting…")
            case .transcriptCopy:
                String(localized: "A meeting transcript is being copied to your transcripts folder — quit again to stop; the transcript stays in the meeting folder")
            case .recordingToTranscribe:
                String(localized: "A meeting is being recorded — quit again to stop and save it; it won’t be transcribed")
            case .fileTranscription:
                String(localized: "A file is being transcribed in Files — quit again to stop it")
            case .unsavedFileText:
                String(localized: "Files has unsaved text — save it as .md, or quit again to discard it")
            case .unsavedMeetingMark:
                String(localized: "A meeting’s changes aren’t saved yet — quit again to lose them")
            case .transcriptFile:
                String(localized: "A transcript is being saved as a file — quit again to stop; the file may not be written")
            case .recognizeAgain:
                String(localized: "A dictation is being recognized again — quit again to stop; the entry keeps its text")
            }
        }

        /// One item of the list when several are lost at once.
        var listName: String {
            switch self {
            case .meetingTranscription: String(localized: "meeting transcription")
            case .transcriptCopy: String(localized: "copy of a meeting transcript")
            case .recordingToTranscribe: String(localized: "transcription of this meeting")
            case .fileTranscription: String(localized: "file transcription")
            case .unsavedFileText: String(localized: "unsaved Files text")
            case .unsavedMeetingMark: String(localized: "changes to a meeting")
            case .transcriptFile: String(localized: "a transcript being saved as a file")
            case .recognizeAgain: String(localized: "recognizing a dictation again")
            }
        }
    }

    /// Who asked to quit. Sparkle's quit after Install and Relaunch carries no
    /// reason, so it is a person's quit on purpose: unsaved Files text warns.
    enum QuitRoute: Equatable, Sendable { case user, system, signal }

    /// Long enough to archive a five-minute dictation. Past it quit is
    /// refused, never forced: the unfinished work keeps running.
    var terminationDeadline: Duration = .seconds(20)
    /// Second phase of quit: true means the recordings are saved and the app
    /// quits for real. Injected by tests, which must not end their host process.
    var finishTermination: @MainActor (Bool) -> Void = { saved in
        if saved { NSApp.terminate(nil) }
    }
    /// What Files would lose; empty until Files is wired in.
    var fileLosses: @MainActor () -> Set<QuitLoss> = { [] }
    /// What the meetings window would lose: a meeting's changes not saved
    /// yet, a transcript being saved as a file.
    var meetingLosses: @MainActor () -> Set<QuitLoss> = { [] }
    /// Opens or raises the main window; set by the menu bar label, which can
    /// open windows. Nothing until then.
    var showMainWindow: @MainActor () -> Void = {}
    /// A warned quit repeated within this time, losing nothing new, goes
    /// ahead. A consent that never expired would let a later quit end new work.
    var repeatWindow: Duration = .seconds(10)
    /// Clock and quit reason, stood in for by tests.
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    var quitReason: @MainActor () -> OSType? = { AppDelegate.currentQuitReason() }
    /// Set by the SIGTERM handler right before it asks to quit; read once.
    var signalled = false
    private weak var dictation: DictationCoordinator?
    private weak var meeting: MeetingRecorder?
    private weak var settings: SettingsStore?
    private var signalSource: DispatchSourceSignal?
    private var appearanceSubscription: AnyCancellable?
    private var finishingRecordings = false
    private var terminationConfirmed = false
    /// What the last warning named, and when. In memory only.
    private var warned: (losses: Set<QuitLoss>, at: ContinuousClock.Instant)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let testing = ProcessInfo.processInfo.arguments.contains("-UITesting")
        NSApp.setActivationPolicy(testing ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Default SIGTERM kills the process before AppKit hears of it; route it
        // through the ordinary quit so recordings are saved first.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                AppLog.info("app", "quit requested (SIGTERM)")
                self?.signalled = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        signalSource = source
    }

    /// The app opened again while it runs (Finder, Launchpad, the Dock): the
    /// main window, opened or raised, whatever else is on screen. Settings
    /// open and the meetings out of sight is the case this is for. Handled
    /// here, so SwiftUI opens nothing of its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppLog.info("app", "reopened; showing the main window")
        showMainWindow()
        return false
    }

    /// The chosen look for every window, sheet and menu, from now on. Called
    /// at launch before any window opens. `@Published` sends a new value before
    /// the property changes, so the value sent is the one applied.
    func followAppearance(of settings: SettingsStore) {
        appearanceSubscription = settings.$appearance.sink { appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    func attach(dictation: DictationCoordinator, meeting: MeetingRecorder, settings: SettingsStore? = nil) {
        self.dictation = dictation
        self.meeting = meeting
        self.settings = settings
    }

    nonisolated static func route(quitReason: OSType?, signalled: Bool) -> QuitRoute {
        if signalled { return .signal }
        let system: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
            OSType(kAERestart), OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
        ]
        guard let quitReason, system.contains(quitReason) else { return .user }
        return .system
    }

    /// The reason macOS gave in the quit Apple event, if a quit event is
    /// being handled: logout, restart and shutdown carry one.
    private static func currentQuitReason() -> OSType? {
        NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
            .enumCodeValue
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Read once, whatever answers: a stale mark would hide the next warning.
        let signalled = self.signalled
        self.signalled = false
        // The app's own second phase: the person already chose to quit.
        if terminationConfirmed { return .terminateNow }
        // Never `.terminateLater`: AppKit would then wait in a nested modal run
        // loop inside `terminate`. Called from a main-queue block (a MainActor
        // task, the SIGTERM source) that loop cannot drain the main queue, so the
        // work that has to answer never runs. Cancel instead, finish in the
        // normal event loop and quit again once saved.
        if finishingRecordings { return .terminateCancel }
        let route = Self.route(quitReason: quitReason(), signalled: signalled)
        let losses = quitLosses()
        if !losses.isEmpty {
            let names = QuitLoss.allCases.filter(losses.contains).map { "\($0)" }.joined(separator: ", ")
            if route == .user, !isConfirmedRepeat(losses) {
                warned = (losses, now())
                AppLog.info("app", "quit postponed: it would end \(names)")
                dictation?.showQuitWarning(Self.warning(for: losses))
                return .terminateCancel
            }
            AppLog.info("app", "quit (\(route)) ends \(names)")
        }
        let dictation = self.dictation
        let meeting = self.meeting
        guard dictation?.hasUnfinishedWork == true || meeting?.hasUnfinishedWork == true else {
            AppLog.info("app", "quit: nothing to finish")
            // Nothing to wait for by `hasUnfinishedWork`'s own account, but a
            // ⌃⌘V not yet delivered, or a "Recognize Again" quit chose not to
            // warn about this time, must still be stopped before this reply.
            dictation?.prepareForImmediateQuit()
            return .terminateNow
        }
        AppLog.info("app", "quit: finishing active recordings first")
        finishingRecordings = true
        // Both start at once, so neither recorder can begin anything new while
        // the other is still finishing.
        let work = [dictation?.beginTermination(), meeting?.beginTermination()].compactMap { $0 }
        let deadline = terminationDeadline
        Task { [weak self] in
            let saved = await Self.outcome(of: work, deadline: deadline)
            guard let self else { return }
            self.finishingRecordings = false
            if saved {
                AppLog.info("app", "quit: recordings saved; quitting")
                self.terminationConfirmed = true
            } else {
                AppLog.error("app", "quit refused: saving not confirmed")
                dictation?.cancelTermination()
                meeting?.cancelTermination()
                dictation?.showTerminationDeferred()
            }
            self.finishTermination(saved)
        }
        return .terminateCancel
    }

    private func quitLosses() -> Set<QuitLoss> {
        var losses = fileLosses().union(meetingLosses())
        if dictation?.recognizeAgainWouldBeLost == true {
            losses.insert(.recognizeAgain)
        }
        if let transcripts = meeting?.transcripts {
            if transcripts.isTranscribing || transcripts.pending.contains(where: \.transcribe) {
                losses.insert(.meetingTranscription)
            }
            // After the transcription the job copies the transcript, then
            // compresses and moves the folder; only the copy is not redone by
            // the launch scan. Compression and the move report their step.
            if transcripts.activeJob?.transcribe == true, !transcripts.isTranscribing,
               transcripts.step == nil, settings?.transcriptsFolderPath != nil {
                losses.insert(.transcriptCopy)
            }
        }
        // Quit saves the recording but never queues it for a transcription.
        if meeting?.isBusy == true, settings?.meetingAfterStop == .transcribe {
            losses.insert(.recordingToTranscribe)
        }
        return losses
    }

    /// A second quit soon after the warning, which loses nothing it did not name.
    private func isConfirmedRepeat(_ losses: Set<QuitLoss>) -> Bool {
        guard let warned else { return false }
        return warned.at.duration(to: now()) <= repeatWindow && losses.isSubset(of: warned.losses)
    }

    static func warning(for losses: Set<QuitLoss>) -> String {
        let named = QuitLoss.allCases.filter(losses.contains)
        if named.count == 1, let only = named.first { return only.warning }
        let list = ListFormatter.localizedString(byJoining: named.map(\.listName))
        return String(localized: "Quitting now loses: \(list) — quit again to quit anyway")
    }

    /// The work's result, or false at the deadline, whichever comes first. The
    /// work is never joined here: a start or stop stuck in Core Audio must not
    /// hold the answer, and it keeps running after a refused quit.
    private static func outcome(of work: [Task<Bool, Never>], deadline: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = SingleAnswer(continuation)
            Task {
                var saved = true
                for item in work {
                    let finished = await item.value
                    saved = saved && finished
                }
                answer.give(saved)
            }
            Task {
                try? await Task.sleep(for: deadline)
                answer.give(false)
            }
        }
    }
}

/// Resumes a continuation once; later answers are ignored.
private final class SingleAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func give(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Hybrid Dock behavior: Dock icon (`.regular`) only while a real window is open;
/// menu-bar-only (`.accessory`) otherwise. The recording indicator (an `NSPanel`)
/// must NOT count as a real window, or it would pin the app to `.regular` during
/// dictation and never flip back.
@MainActor
enum AppWindowController {
    /// A "real" app window = a normal, becomes-main window. Excludes the indicator
    /// (`NonKeyPanel`/`NSPanel`, `canBecomeMain == false`) and transient panels.
    static func isRealWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain
    }

    static func visibleRealWindowCount(in windows: [NSWindow]) -> Int {
        windows.reduce(into: 0) { count, window in
            if window.isVisible, isRealWindow(window) { count += 1 }
        }
    }

    /// Bring the app forward so a window can show. Order: policy → activate, THEN
    /// the caller opens/raises the window.
    static func enterRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// A menu-bar action runs while its transient popup is closing. Give AppKit
    /// time to make a normal window key before asking TCC to present a consent
    /// alert; otherwise macOS can reject the prompt as non-presentable.
    static func waitUntilPermissionPromptCanBePresented(
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if NSApp.isActive, NSApp.windows.contains(where: {
                $0.isVisible && isRealWindow($0)
            }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A folder picked in a panel shown over every other app. After the menu
    /// has closed: an accessory app's panel would otherwise open behind other
    /// apps' windows. Not `runModal`: nested modal loops already cost the
    /// quit path and the Files tab. An accessory view is shown open, and the
    /// delegate may refuse the choice; the caller keeps both alive until the
    /// completion, which the panel holds. It needs no window: the menu asks
    /// with none open. No test process opens it: `begin`, AppKit's last
    /// call, comes only after this process's rule, which a test checks with
    /// a `begin` that counts. `show` is a test's own stand-in for the whole
    /// of it, to see the panel that would be shown.
    static func chooseFolder(
        message: String,
        prompt: String,
        directory: URL?,
        accessory: NSView? = nil,
        delegate: (any NSOpenSavePanelDelegate)? = nil,
        begin: @escaping FolderPanel = AppWindowController.begin,
        show: FolderPanel? = nil,
        completion: @escaping @MainActor (URL) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = directory
            panel.message = message
            panel.prompt = prompt
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = accessory != nil
            panel.delegate = delegate
            (show ?? folderPanels(testProcess: TestIsolation.isTestProcess, begin: begin))(panel, completion)
        }
    }

    /// Shows a folder panel and hands its folder on.
    typealias FolderPanel = @MainActor (_ panel: NSOpenPanel, _ completion: @escaping @MainActor (URL) -> Void) -> Void

    /// AppKit's panel outside tests; a test process never opens one,
    /// whatever it was told.
    static func folderPanels(testProcess: Bool, begin: @escaping FolderPanel) -> FolderPanel {
        guard testProcess else { return begin }
        return { panel, _ in AppLog.info("app", "no folder panel in a test process: \(panel.message ?? "")") }
    }

    /// The folder panel itself, over every other app.
    static func begin(_ panel: NSOpenPanel, completion: @escaping @MainActor (URL) -> Void) {
        enterRegular()
        panel.begin { response in
            MainActor.assumeIsolated {
                defer { windowDidClose() }
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        }
    }

    /// Call when a window closes; flip back to `.accessory` if no real window remains.
    static func windowDidClose() {
        DispatchQueue.main.async {
            if visibleRealWindowCount(in: NSApp.windows) == 0 {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
