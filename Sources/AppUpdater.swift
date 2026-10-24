import Combine
import Foundation
import Sparkle

/// Sparkle's standard updater: the daily check, the window with the release
/// notes and "Install and Relaunch". The only place the app talks to Sparkle.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case testCopy
        case noKey
        case failed(String)
        case running
    }

    /// Kept in memory only: whether checks run at all is Sparkle's own setting.
    @Published private(set) var state: State = .testCopy
    /// False while a check is already running, and always when the updater is off.
    @Published private(set) var canCheckForUpdates = false
    /// Set when a relaunch was refused, in memory only: Sparkle closes its
    /// window then, so the menu and Settings say what happens instead.
    @Published private(set) var installsAtQuit = false
    private var controller: SPUStandardUpdaterController?
    private var isBusy = false
    private var subscriptions: Set<AnyCancellable> = []

    var isRunning: Bool { state == .running }

    init(busy: some Publisher<Bool, Never>) {
        super.init()
        busy.sink { [weak self] in self?.isBusy = $0 }.store(in: &subscriptions)
        // A test copy must never reach the feed or show Sparkle's windows.
        guard !TestIsolation.isTestProcess else { return }
        // Sparkle cannot verify a download without the key, and a fork or a
        // Local.xcconfig may leave it empty: the updater stays off instead of
        // failing at launch.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty else {
            state = .noKey
            AppLog.info("updates", "off: this build has no SUPublicEDKey (see Signing.xcconfig)")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
        )
        // Started here rather than by the controller: on failure it would
        // show its alert through a nested modal run loop, which this app avoids
        // (quit and the file tab both hung on one). Settings show the reason.
        do {
            try controller.updater.start()
        } catch {
            state = .failed(error.localizedDescription)
            AppLog.error("updates", "failed to start: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        state = .running
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        AppLog.info("updates", "on; feed → \(controller.updater.feedURL?.absoluteString ?? "none")")
    }

    /// True while a relaunch would cut something short that does not resume
    /// by itself: a meeting being recorded or saved, a dictation, a dictation
    /// being recognized again (its save included) or ⌃⌘V until its clipboard
    /// is restored, a meeting transcription queued or under way, a file
    /// being transcribed in Files, a meeting's changes not saved yet or a
    /// transcript being written to the file chosen for it (both end by
    /// themselves). A job that transcribes counts until it ends, its copy
    /// into the transcripts folder included: the launch-time scan queues the
    /// folder again, but without either. Compression and moves of their own
    /// are not counted, since the scan does queue them again.
    ///
    /// Files' unsaved text is not counted either: it never ends by itself, so
    /// waiting for it would hold the update until the text is saved. The quit
    /// Sparkle sends instead is a person's quit, which warns about the text
    /// and stays cancelled; the update installs at the next quit.
    static func busy(
        meeting: MeetingRecorder,
        dictation: DictationCoordinator,
        transcripts: MeetingTranscriptionQueue,
        files: FilesModel,
        library: MeetingLibrary
    ) -> AnyPublisher<Bool, Never> {
        // @Published sends the new value before the property changes, so the
        // values are read from the stream, never from the objects.
        let dictationBusy = Publishers.CombineLatest3(
            dictation.$state,
            dictation.$recognizingAgainID,
            dictation.$isPastingLast
        )
        .map { $0 != .idle || $1 != nil || $2 }
        return Publishers.CombineLatest3(
            Publishers.CombineLatest4(
                meeting.$state.map(\.isBusy),
                dictationBusy,
                transcripts.$activeJob.map { $0?.transcribe == true },
                transcripts.$pending.map { $0.contains(where: \.transcribe) }
            )
            .map { $0 || $1 || $2 || $3 },
            files.$isTranscribing,
            // A meeting's changes not saved yet, being written to a folder
            // that is not on this Mac; a transcript being written to a file.
            Publishers.CombineLatest(library.$pendingMarks, library.$exporting).map { !$0.isEmpty || $1?.writing == true }
        )
        .map { $0 || $1 || $2 }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    /// Sparkle keeps the user's choice in the app's defaults; the Info.plist
    /// only provides the default.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// "Install and Relaunch" quits through the ordinary quit, which would
    /// stop a call being recorded and leave a transcription unfinished.
    /// Sparkle asks on every attempt, including from the window it shows
    /// again later. Refused, it closes its window and keeps the prepared
    /// update: it installs when the app quits, and "Check for Updates…"
    /// offers "Install and Relaunch" / "Install on Quit" again. Postponing
    /// instead would leave Sparkle's "Ready to Install" window on screen,
    /// unclosable and with a dead button, for the whole call.
    func relaunchNow() -> Bool {
        guard isBusy else { return true }
        installsAtQuit = true
        AppLog.info("updates", "not now: a recording or transcription is under way; the update installs at quit")
        return false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        relaunchNow()
    }

    /// Sparkle let the relaunch through and is about to quit the app. A quit
    /// that is then cancelled — Files' unsaved text warns — leaves the update
    /// for the next quit, which relaunches the app, so the menu and Settings
    /// must say so; a quit that goes ahead shows nothing.
    func willRelaunch() {
        installsAtQuit = true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRelaunch()
    }

    /// "Install on Quit" in Sparkle's own window keeps the update waiting for
    /// the quit; skipping drops it, and installing asks `relaunchNow` again.
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        installsAtQuit = choice == .dismiss && state.stage == .installing
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// Sparkle's install stage brings the app into the Dock, and its windows
    /// are not ours, so their closing never sends the app back. Its update
    /// session ends with every one of its windows closed: the Dock is checked
    /// then, as after any window of the app. The delegate is not isolated to
    /// the main actor, hence the hop.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in AppWindowController.windowDidClose() }
    }
}
