import AppKit
import AVFoundation
import Combine
import Foundation
import KeyboardShortcuts

@MainActor
final class DictationCoordinator: ObservableObject {
    enum State: Equatable, Sendable { case idle, starting, recording, transcribing }
    enum MicGate: Equatable, Sendable { case proceed, promptViaMenu, openSettings }
    /// Whether dictation will work now, in the order the person has to fix it.
    enum Readiness: Equatable, Sendable {
        case needsModel, modelFailed, needsMicrophone, preparing, waitingForEngine, notPrepared, ready
    }

    /// Recognized text whose history save failed. Kept in memory only, until
    /// quit or explicit removal; the source audio is a temporary file.
    struct UnsavedDictation: Identifiable, Equatable, Sendable {
        let id: UUID
        let at: Date
        let text: String
        let sourceAudio: URL
    }

    /// Metadata fixed when recording stops: enough to index the audio later
    /// without the pipeline.
    private struct DictationRecord: Sendable {
        let id = UUID()
        let startedAt: Date
        let selectedLanguage: String
        let engine: String?
        let targetBundleID: String?
        let targetApplicationName: String?
        var interruption: String?
        var actualLanguage = ""
        var text = ""
        /// The text before the dictionary changed it, nil when it did not.
        /// Worked out once, with the text, and carried as is to every retry.
        var rawText: String?
        var recognitionFailed = false
        var recognitionSkipped = false
        /// Ended by the length limit, not by the person. Not archived.
        var stoppedAtLimit = false

        init(startedAt: Date, snapshot: SettingsSnapshot?, target: NSRunningApplication?) {
            self.startedAt = startedAt
            selectedLanguage = snapshot?.dictationLanguage ?? ""
            engine = snapshot?.dictationEngine.rawValue
            targetBundleID = target?.bundleIdentifier
            targetApplicationName = target?.localizedName
        }

        func entry(audioPath: String, duration: TimeInterval) -> DictationHistoryEntry {
            DictationHistoryEntry(
                id: id,
                at: startedAt,
                duration: duration,
                selectedLanguage: selectedLanguage,
                actualLanguage: actualLanguage,
                engine: engine,
                targetBundleID: targetBundleID,
                targetApplicationName: targetApplicationName,
                audioPath: audioPath,
                text: text,
                rawText: rawText,
                interrupted: interruption == nil ? nil : true,
                recognitionFailed: recognitionFailed ? true : nil,
                recognitionSkipped: recognitionSkipped ? true : nil
            )
        }
    }

    private enum StopOutcome: Sendable {
        case nothing
        case source(URL, interruption: String?)
        case failed(any Error)
    }

    private enum SaveOutcome: Sendable {
        /// nil: the audio was kept without an index line (no settings, or
        /// recognition failed on a complete recording).
        case saved(DictationHistoryEntry?)
        case failed(any Error)
    }

    /// The dictation between stop and its confirmed save. Exactly one side owns
    /// it: the pipeline, or quit once `claimed` is set.
    private struct DictationJob {
        enum Phase {
            case stopping, recognizing, saving(Task<SaveOutcome, Never>)
            /// Carries the save result: delivery also runs after a
            /// failed save, so "delivering" alone proves nothing.
            case delivering(SaveOutcome)
        }

        var record: DictationRecord
        let snapshot: SettingsSnapshot?
        let dictionary: DictionarySnapshot?
        let target: NSRunningApplication?
        let stop: Task<StopOutcome, Never>
        var source: URL?
        var phase = Phase.stopping
        var claimed = false
        /// Esc said "don't paste": recognition and the save go on as usual,
        /// only `deliver` is skipped. Only `escapePressed` sets this; a plain
        /// `toggle`, a hold's release and the 5-minute limit never do.
        var skipsDelivery = false
    }

    /// A quit-time save that is not confirmed. It blocks quit until a retry
    /// succeeds or the user removes the dictation from the menu.
    private struct PendingSave {
        var record: DictationRecord
        let source: URL
        /// Set after an append failure: the audio is already in the archive.
        var archived: (path: String, duration: TimeInterval)?
    }

    // Pop/Bottle were chosen by listening to them as a pair in the real dictation
    // rhythm. Six custom tones were rejected: high ones sounded shrill, low ones dry.
    private static let recordingStartedSoundName = NSSound.Name("Pop")
    private static let insertionSucceededSoundName = NSSound.Name("Bottle")
    private static let historyNotSavedFlash = IndicatorState.dictationFailure(
        message: String(localized: "History not saved — the text is in the “M” menu")
    )
    /// macOS named the focused field a password field: never pasted or put on
    /// the clipboard. The text itself was still recognized and kept, so the
    /// flash only says where it is.
    static let passwordFieldPastedFlash = IndicatorState.dictationFailure(
        message: String(localized: "Password field — not pasted; the text is in Dictations")
    )
    static let passwordFieldHistoryNotSavedFlash = IndicatorState.dictationFailure(
        message: String(localized: "Password field — not pasted; the text is in the “M” menu")
    )
    static let modelMissingFlash = IndicatorState.dictationFailure(
        message: String(localized: "Download a model: “M” menu → “Download Model…”")
    )
    static let nothingToPasteFlash = IndicatorState.dictationFailure(
        message: String(localized: "No dictation yet")
    )
    static let lastNotRecognizedFlash = IndicatorState.dictationFailure(
        message: String(localized: "The last dictation wasn’t recognized — it’s in Dictations")
    )
    static let lastUnsavedNotRecognizedFlash = IndicatorState.dictationFailure(
        message: String(localized: "The last dictation wasn’t recognized — it’s in the “M” menu")
    )
    static let releaseKeysFlash = IndicatorState.dictationFailure(
        message: String(localized: "Release the keys to paste")
    )
    static let historyUnreadableFlash = IndicatorState.dictationFailure(
        message: String(localized: "Couldn’t read Dictations — try again")
    )
    static let releasedBeforeRecordingFlash = IndicatorState.dictationFailure(
        message: String(localized: "Released before recording started — hold until the indicator shows recording")
    )

    /// `dictation.autoPaste` off and the history saved: where to find the
    /// text, naming the shortcut when one is set.
    private static func autoPasteOffSavedMessage(shortcut: String?) -> String {
        guard let shortcut else { return String(localized: "Saved to Dictations") }
        return String(localized: "Saved — \(shortcut) pastes it")
    }

    /// Same as `autoPasteOffSavedMessage`, for a dictation the 5-minute limit
    /// ended: never pasted or put on the clipboard, so the message differs
    /// from the auto-paste ones in `deliver`.
    private static func autoPasteOffLimitMessage(shortcut: String?) -> String {
        guard let shortcut else {
            return String(localized: "Saved to Dictations — stopped at the 5-minute limit")
        }
        return String(localized: "Saved, not pasted — stopped at the 5-minute limit; \(shortcut) pastes it")
    }

    /// Esc during the dictation: saved, never pasted; names ⌃⌘V when one is set.
    private static func cancelledNotPastedMessage(shortcut: String?) -> String {
        guard let shortcut else { return String(localized: "Cancelled — the text is in Dictations") }
        return String(localized: "Cancelled — not pasted. \(shortcut) pastes it")
    }

    /// The fragment is in the history or unsaved submenu either way. Without
    /// text it promises only the kept source, not that it will play.
    private static func interruptedMessage(
        reason: String,
        hasText: Bool,
        recognitionFailed: Bool
    ) -> String {
        if hasText { return String(localized: "Recording interrupted (\(reason)) — the fragment is in the “M” menu") }
        if recognitionFailed {
            return String(localized: "Recording interrupted (\(reason)), fragment not recognized — the source audio is kept")
        }
        return String(localized: "Recording interrupted (\(reason)), no speech recognized — the source audio is kept")
    }

    @Published private(set) var state: State = .idle {
        didSet { updateEscapeListener() }
    }
    @Published private(set) var modelState: WhisperModelState = .cold
    /// Why the selected model could not be prepared, in memory only. Not a
    /// model state: that type is also what the cache reports. Cleared by the
    /// next attempt, by another engine, or once the model is ready.
    @Published private(set) var modelFailure: String?
    /// The last dictation was ended by the length limit; in memory, until
    /// the next one ends.
    @Published private(set) var lastDictationHitLimit = false
    @Published private(set) var recentDictations: [DictationHistoryEntry] = []
    @Published private(set) var unsavedDictations: [UnsavedDictation] = []
    /// Unsaved dictations that quit could not confirm; each one blocks quit.
    @Published private(set) var quitBlockingIDs: Set<UUID> = []
    /// The history entry "Recognize Again" is recognizing right now, if any;
    /// only one at a time. A new dictation meanwhile is not refused by this —
    /// it waits its turn for the engine cache, like any job in another engine.
    @Published private(set) var recognizingAgainID: UUID?

    private let mic: any MicCapturing
    private let whisperCache: WhisperKitCache
    private let models: ModelDownloader
    /// Off in test processes: the test host must not load real models.
    private let warmsUp: Bool
    private let historyStore: DictationHistoryStore
    private let deliveryOverride: (@MainActor @Sendable (String, NSRunningApplication?) async -> Void)?
    private let indicator: RecordingIndicator
    private let frontmostApplication: @MainActor @Sendable () -> NSRunningApplication?
    private let feedbackPlayer: @MainActor @Sendable (NSSound.Name) -> Void
    private let beepPlayer: @MainActor @Sendable () -> Void
    private let ownProcessIdentifier: pid_t
    private let maxRecordingSeconds: TimeInterval
    /// How long after a dictation its engine stays held (`heldEngine`): the
    /// next one often follows within it.
    private let engineHold: Duration
    /// When the last dictation ended; nil before the first, so a fresh
    /// launch holds nothing.
    private var finishedAt: ContinuousClock.Instant?
    private let startTimeout: TimeInterval
    private let hotkeyManager: HotkeyManager
    private weak var settings: SettingsStore?
    private weak var permissions: PermissionManager?
    weak var meetingPeer: MeetingRecorder?
    private var activated = false
    private var startInjectTarget: NSRunningApplication?
    private var injectTarget: NSRunningApplication?
    private var recordingStartedAt: Date?
    private var recordingSnapshot: SettingsSnapshot?
    /// Taken with `recordingSnapshot`: an edit during the dictation applies
    /// to the next one.
    private var recordingDictionary: DictionarySnapshot?
    private var startAttempt: UInt = 0
    private var startTask: Task<Void, Never>?
    private var startWatchdogTask: Task<Void, Never>?
    /// The hold under way: the start attempt it began and when its shortcut
    /// went down. Only the release of that very attempt counts.
    private struct Hold {
        let attempt: UInt
        let since: ContinuousClock.Instant
        /// Esc as pressed while this hold's shortcut stays down (⌥Esc for
        /// ⌥Space); nil for Press/double-modifier activation or a shortcut
        /// Esc already is.
        let escapeChord: KeyboardShortcuts.Shortcut?
    }
    private var hold: Hold? {
        didSet { updateEscapeListener() }
    }
    /// The start attempt a release abandoned while the microphone was starting.
    /// Its late success is stopped and its audio deleted: the user let go before
    /// anything was recorded. Other abandoned starts (timeout, quit) keep their
    /// own handling.
    private var releasedStartAttempt: UInt?
    /// Shorter holds are taken for a slip of the finger (Wispr's threshold).
    static let minimumHold: Duration = .milliseconds(500)
    private var autoStopTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var engineSettingsCancellable: AnyCancellable?
    private var installsCancellable: AnyCancellable?
    private var selectedDescriptor: EngineDescriptor?
    private var modelGeneration: UInt = 0
    /// The recent menu follows the store's own change signal and is replaced
    /// by a fresh read each time, never patched by hand.
    private let historyChanges: DictationHistoryChanges
    private var historyChangesSubscription: AnyCancellable?
    private var recentRefresh: UInt = 0
    private var job: DictationJob? {
        didSet { updateEscapeListener() }
    }
    /// The target and the fresh lookup of the last dictation, captured at
    /// ⌃⌘V's key-down: the paste itself starts only at key-up.
    private struct PastePress {
        let target: NSRunningApplication?
        let lookup: Task<LastLookup, Never>
    }
    private var pastePress: PastePress?
    private var pasteLastTask: Task<Void, Never>?
    /// ⌃⌘V from key-up until its own task ends; for `AppUpdater.busy`, so a
    /// relaunch waits for the clipboard to be restored.
    @Published private(set) var isPastingLast = false
    /// True only once the clipboard has actually been overwritten and ⌘V
    /// sent (or `deliveryOverride` is running in its place), for ⌃⌘V and an
    /// ordinary dictation's own delivery alike: quit then waits for it
    /// instead of cancelling it.
    private var pasteDelivering = false
    /// The task the paste itself runs in while `pasteDelivering` is true, for
    /// ⌃⌘V and an ordinary dictation alike: quit waits for exactly this.
    private var pasteDelivery: Task<Void, Never>?
    private var isTerminating = false
    private var quitRequested = false
    private var terminationTask: Task<Bool, Never>?
    /// "Recognize Again" under way: its own task, its save once begun, and
    /// whether quit has taken it over — then a late result writes nothing.
    private struct RecognizeAgainRun {
        let task: Task<Void, any Error>
        var save: Task<Void, any Error>?
        var claimed = false
    }
    private var recognizeAgainRun: RecognizeAgainRun?
    private var pendingSaves: [PendingSave] = [] {
        didSet { quitBlockingIDs = Set(pendingSaves.map(\.record.id)) }
    }

    init(
        mic: any MicCapturing,
        indicator: RecordingIndicator,
        startTimeout: TimeInterval = 8,
        maxRecordingSeconds: TimeInterval = 300,
        engineHold: Duration = .seconds(30),
        hotkeyManager: HotkeyManager = HotkeyManager(),
        whisperCache: WhisperKitCache = .shared,
        models: ModelDownloader = ModelDownloader(),
        warmsUp: Bool = !TestIsolation.isTestProcess,
        historyStore: DictationHistoryStore = .shared,
        deliveryOverride: (@MainActor @Sendable (String, NSRunningApplication?) async -> Void)? = nil,
        frontmostApplication: @escaping @MainActor @Sendable () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        feedbackPlayer: @escaping @MainActor @Sendable (NSSound.Name) -> Void = {
            DictationCoordinator.playFeedback(named: $0)
        },
        beepPlayer: @escaping @MainActor @Sendable () -> Void = { NSSound.beep() }
    ) {
        self.mic = mic
        self.indicator = indicator
        self.startTimeout = startTimeout
        self.maxRecordingSeconds = maxRecordingSeconds
        self.engineHold = engineHold
        self.hotkeyManager = hotkeyManager
        self.whisperCache = whisperCache
        self.models = models
        self.warmsUp = warmsUp
        self.historyStore = historyStore
        // Subscribed before any read, so no change of this store is missed.
        historyChanges = DictationHistoryChanges(store: historyStore)
        self.deliveryOverride = deliveryOverride
        self.frontmostApplication = frontmostApplication
        self.ownProcessIdentifier = ownProcessIdentifier
        self.feedbackPlayer = feedbackPlayer
        self.beepPlayer = beepPlayer
        historyChangesSubscription = historyChanges.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.refreshRecentDictations() }
    }

    /// Esc is taken from every app while registered (see `updateEscapeListener`);
    /// a coordinator torn down mid-dictation (a stage-gate test cut short, for
    /// one) must not leave it taken.
    isolated deinit {
        hotkeyManager.closeEscapeListener()
    }

    /// The one answer for every place that says whether dictation is ready.
    /// Accessibility is not part of it: without it the text goes to the
    /// clipboard. Only a prepared model is "ready".
    nonisolated static func readiness(
        modelDownloaded: Bool,
        microphoneGranted: Bool,
        modelState: WhisperModelState,
        modelFailure: String?
    ) -> Readiness {
        guard modelDownloaded else { return .needsModel }
        guard modelFailure == nil else { return .modelFailed }
        guard microphoneGranted else { return .needsMicrophone }
        switch modelState {
        case .loading: return .preparing
        case .waiting: return .waitingForEngine
        case .cold: return .notPrepared
        case .ready: return .ready
        }
    }

    nonisolated static func micGate(_ status: AVAuthorizationStatus) -> MicGate {
        switch status {
        case .authorized: return .proceed
        case .notDetermined: return .promptViaMenu
        case .denied, .restricted: return .openSettings
        @unknown default: return .openSettings
        }
    }

    func activate(settings: SettingsStore, permissions: PermissionManager) {
        self.settings = settings
        self.permissions = permissions
        guard !activated else { return }
        activated = true
        hotkeyManager.activate(
            settings: settings,
            onToggle: { [weak self] in self?.toggle() },
            isRecording: { [weak self] in self?.state == .recording },
            onHoldBegan: { [weak self] in self?.holdBegan() },
            onHoldEnded: { [weak self] in self?.holdEnded() }
        )
        HotkeyManager.registerLastDictation(
            onPasteDown: { [weak self] in self?.pasteLastKeyDown() },
            onPasteUp: { [weak self] in self?.pasteLastKeyUp() },
            onCopy: { [weak self] in Task { await self?.copyLastDictation() } }
        )
        AppLog.info(
            "dictation",
            TestIsolation.isEnabled
                ? "activated; test isolation: no global hotkey"
                : "activated; hotkey ⌥Space"
        )
        startHistoryLoad()
        engineSettingsCancellable = settings.$dictationEngine
            .sink { [weak self] engine in
                self?.engineSelectionDidChange(
                    descriptor: EngineDescriptor(engine: engine, modelPath: SettingsStore.modelPath(for: engine))
                )
            }
        installsCancellable = models.$installs
            .dropFirst()
            .sink { [weak self] _ in self?.retryModelPreparation() }
    }

    var isBusy: Bool { state != .idle }

    /// The engine a meeting job leaves alone now: the dictation's while it
    /// starts, records or is recognized, and for `engineHold` after it ends.
    /// The cache holds one engine, and a job in another engine would make
    /// each dictation load its model back. nil when nothing is held.
    func heldEngine(at now: ContinuousClock.Instant = .now) -> EngineDescriptor? {
        if state != .idle { return (recordingSnapshot ?? settings?.snapshot)?.dictationDescriptor }
        guard let finishedAt, now < finishedAt + engineHold else { return nil }
        return settings?.snapshot.dictationDescriptor
    }

    /// Whether Esc can still change anything. The coordinator may stay busy
    /// longer than this (a hung microphone, a save still in flight), but Esc
    /// goes back to other apps the moment it would no longer matter: a
    /// cancel has been accepted (`job.skipsDelivery`), an abandoned start or
    /// a short hold is winding down (no `job` yet, `state == .transcribing`),
    /// or recording stopped with auto-paste off (nothing to cancel the paste
    /// of).
    private var escapeCancels: Bool {
        guard !isTerminating else { return false }
        switch state {
        case .idle:
            return false
        case .starting, .recording:
            return true
        case .transcribing:
            // `.delivering` is deliberately left open: an Esc pressed there
            // already does nothing (`escapePressed` guards it), but closing
            // the listener here as well is a separate, untested change —
            // left for a follow-up (see the report).
            guard let job, !job.claimed, !job.skipsDelivery else { return false }
            return job.snapshot?.autoPaste == true
        }
    }

    /// Esc is taken from every app while it can still cancel something
    /// (`escapeCancels`), and — while a Hold-mode shortcut is held — also
    /// with that shortcut's modifiers (⌥Esc for ⌥Space), so the system call
    /// matches what is physically pressed. Recomputed on every change of
    /// `state`, `job` or `hold`.
    private func updateEscapeListener() {
        var shortcuts: Set<KeyboardShortcuts.Shortcut> = []
        if escapeCancels {
            shortcuts.insert(.init(.escape))
            if let chord = hold?.escapeChord { shortcuts.insert(chord) }
        }
        hotkeyManager.listenForEscape(shortcuts) { [weak self] in self?.escapePressed() }
    }

    /// Esc during a dictation: nothing is pasted, nothing is lost — the text
    /// still goes to the history as usual and ⌃⌘V brings it back.
    private func escapePressed() {
        #if DEBUG
        defer { escapeEventsHandled += 1 } // a test waits for this, ignored presses included
        #endif
        guard !isTerminating else { return }
        switch state {
        case .idle:
            return
        case .starting:
            hold = nil
            abandonStart(
                flash: .notice(message: String(localized: "Cancelled")),
                log: "escape before the microphone started — start abandoned"
            )
        case .recording:
            hold = nil
            stopAndTranscribe()
            // Same main-actor turn as `beginStop`: the pipeline task has not
            // run yet, so marking the job right after is safe.
            job?.skipsDelivery = true
        case .transcribing:
            // No job: a release or a short hold is winding down, nothing to
            // paste either way. A job quit already claimed, or one whose
            // delivery already began, is left alone — too late to matter.
            guard let current = job, !current.claimed else { return }
            if case .delivering = current.phase { return }
            job?.skipsDelivery = true
        }
        AppLog.info("dictation", "escape — not pasting")
    }

    func toggle() {
        guard !isTerminating else {
            AppLog.info("dictation", "quitting — toggle ignored")
            return
        }
        if let meetingPeer, meetingPeer.isBusy {
            indicator.showFlash(.busyWithMeeting)
            AppLog.info("dictation", "meeting recording active — toggle ignored")
            return
        }
        switch state {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .starting, .transcribing:
            AppLog.info("dictation", "busy (\(state)) — toggle ignored")
        }
    }

    func holdBegan() {
        let pressedAt = holdNow() // the moment the shortcut went down — before the start
        guard state == .idle else {
            // A key-repeat or a second press while already starting, recording
            // or winding down must not reset the hold's clock.
            AppLog.info("dictation", "hold already under way (\(state)) — ignored")
            return
        }
        toggle() // the same refusals as a press: quit, a meeting, no model, no microphone
        guard state == .starting else { return } // refused: stayed .idle, no hold to track
        hold = Hold(
            attempt: startAttempt,
            since: pressedAt,
            escapeChord: HotkeyManager.escapeChord(holding: KeyboardShortcuts.getShortcut(for: .dictate))
        )
    }

    func holdEnded() {
        guard let hold else { return }
        self.hold = nil
        guard hold.attempt == startAttempt else { return }
        switch state {
        case .starting:
            releaseBeforeRecording()
        case .recording:
            if holdNow() - hold.since >= Self.minimumHold {
                stopAndTranscribe()
            } else {
                discardShortHold()
            }
        case .idle, .transcribing:
            return
        }
    }

    /// Abandons the current start attempt before the microphone began
    /// recording — a release or Esc — as the start timeout does, but the
    /// coordinator stays busy until both stops of this start are over — the
    /// one here and the one a late success makes in `captureDidStart` — so a
    /// new start cannot reach the capture before them and be ended by their
    /// late `stop`.
    private func abandonStart(flash: IndicatorState, log: String) {
        let released = startAttempt
        let start = startTask
        startAttempt &+= 1
        releasedStartAttempt = released
        startTask?.cancel()
        startTask = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        state = .transcribing
        startInjectTarget = nil
        injectTarget = nil
        recordingSnapshot = nil
        recordingDictionary = nil
        indicator.finish(with: flash)
        AppLog.info("dictation", log)
        let mic = self.mic
        transcriptionTask = Task { [weak self] in
            Self.discard(await Self.stopOutcome(of: mic)) // stop #1 (as the timeout does)
            await start?.value // the start finished: a refusal, a cancellation or a late success with its own stop #2
            guard let self else { return }
            if self.releasedStartAttempt == released { self.releasedStartAttempt = nil }
            self.finishDictation()
        }
    }

    /// The shortcut came up before the microphone started.
    private func releaseBeforeRecording() {
        abandonStart(
            flash: Self.releasedBeforeRecordingFlash,
            log: "released before the microphone started — start abandoned"
        )
    }

    /// A hold shorter than `minimumHold` is a slip: nothing is recognized,
    /// saved or pasted. Busy until the microphone has stopped, so a new start
    /// cannot reach the capture while it is being torn down.
    private func discardShortHold() {
        autoStopTask?.cancel()
        autoStopTask = nil
        state = .transcribing
        indicator.finish(with: Self.shortHoldFlash(shortcut: settings?.dictationShortcutDescription))
        AppLog.info("dictation", "hold shorter than 0.5 s — recording discarded")
        let mic = self.mic
        transcriptionTask = Task { [weak self] in
            Self.discard(await Self.stopOutcome(of: mic))
            self?.finishDictation()
        }
    }

    private static func shortHoldFlash(shortcut: String?) -> IndicatorState {
        .dictationFailure(message: shortcut.map { String(localized: "Hold \($0) while you speak") }
            ?? String(localized: "Hold the shortcut while you speak"))
    }

    private func holdNow() -> ContinuousClock.Instant {
        #if DEBUG
        if let holdClockForTesting { return holdClockForTesting() }
        #endif
        return .now
    }

    private func startRecording() {
        #if DEBUG
        if startSkipsDeviceGatesForTesting {
            beginCapture()
            return
        }
        #endif
        // Without a model the recording could only be archived unrecognized;
        // say where to get one instead.
        if let engine = settings?.dictationEngine, !models.isReady(engine) {
            indicator.showFlash(Self.modelMissingFlash)
            AppLog.info("dictation", "no \(engine.rawValue) model — not recording")
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch Self.micGate(status) {
        case .proceed:
            beginCapture()
            showModelPreparationIfNeeded()
        case .promptViaMenu:
            permissions?.refresh()
            indicator.showFlash(.microphoneAccessUndetermined)
        case .openSettings:
            permissions?.refresh()
            indicator.showFlash(.microphoneAccessDenied)
        }
    }

    private func beginCapture() {
        guard !isTerminating else { return }
        startAttempt &+= 1
        let attempt = startAttempt
        recordingSnapshot = settings?.snapshot
        recordingDictionary = settings?.dictionarySnapshot
        startInjectTarget = Self.preferredInjectionTarget(
            startedWith: nil,
            stoppedWith: frontmostApplication(),
            isOwnApplication: { $0.processIdentifier == ownProcessIdentifier }
        )
        state = .starting
        startTask?.cancel()
        startWatchdogTask?.cancel()

        let mic = self.mic
        startTask = Task { [weak self] in
            do {
                try await mic.start()
                await self?.captureDidStart(attempt: attempt)
            } catch {
                await self?.captureStartFailed(error, attempt: attempt)
            }
        }
        startWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.startTimeout ?? 0))
                await self?.captureStartTimedOut(attempt: attempt)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func captureDidStart(attempt: UInt) async {
        guard attempt == startAttempt, state == .starting else {
            // The watchdog, a newer attempt, a release before recording or
            // quit won. Tear down this late success; under quit it may
            // already hold speech worth keeping.
            if attempt == releasedStartAttempt {
                Self.discard(await Self.stopOutcome(of: mic))
            } else if isTerminating {
                await keepLateStartAudio()
            } else {
                _ = try? await mic.stop()
            }
            return
        }
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        startTask = nil
        state = .recording
        let startedAt = Date()
        recordingStartedAt = startedAt
        playRecordingStartFeedback()
        indicator.setBase(.recordingDictation(
            startedAt: startedAt,
            endsAt: startedAt.addingTimeInterval(maxRecordingSeconds)
        ))
        AppLog.info("dictation", "recording…")

        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.maxRecordingSeconds ?? 0))
            } catch {
                return
            }
            guard let self, self.state == .recording, self.startAttempt == attempt else { return }
            AppLog.info("dictation", "max duration reached — auto-stop")
            self.stopAndTranscribe(atLimit: true)
        }
    }

    private func captureStartFailed(_ error: Error, attempt: UInt) async {
        guard attempt == startAttempt, state == .starting else { return }
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        startTask = nil
        state = .idle
        hotkeyManager.dictationDidBecomeIdle()
        startInjectTarget = nil
        injectTarget = nil
        recordingSnapshot = nil
        recordingDictionary = nil
        if error is CancellationError {
            indicator.clearBase()
            return
        }
        indicator.finish(with: .dictationFailure(message: error.localizedDescription))
        AppLog.error("dictation", "mic start failed: \(error.localizedDescription)")
    }

    private func captureStartTimedOut(attempt: UInt) async {
        guard attempt == startAttempt, state == .starting else { return }
        startAttempt &+= 1
        startTask?.cancel()
        startTask = nil
        startWatchdogTask = nil
        state = .idle
        hotkeyManager.dictationDidBecomeIdle()
        startInjectTarget = nil
        injectTarget = nil
        recordingSnapshot = nil
        recordingDictionary = nil
        indicator.finish(with: .microphoneTimedOut)
        AppLog.error("dictation", "microphone start timed out")
        _ = try? await mic.stop()
    }

    private func stopAndTranscribe(atLimit: Bool = false) {
        guard state == .recording else { return }
        let entryID = beginStop(atLimit: atLimit)
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in await self?.runPipeline(entryID) }
    }

    /// Ends capture as a job that quit can finish on its own. `mic.stop` involves
    /// no model, so both the pipeline and quit may wait for it.
    @discardableResult
    private func beginStop(atLimit: Bool = false) -> UUID {
        autoStopTask?.cancel()
        autoStopTask = nil
        lastDictationHitLimit = atLimit
        injectTarget = Self.preferredInjectionTarget(
            startedWith: startInjectTarget,
            stoppedWith: frontmostApplication(),
            isOwnApplication: { $0.processIdentifier == ownProcessIdentifier }
        )
        indicator.setBase(.finishingRecording)
        var record = DictationRecord(
            startedAt: recordingStartedAt ?? Date(),
            snapshot: recordingSnapshot,
            target: injectTarget
        )
        record.stoppedAtLimit = atLimit
        let mic = self.mic
        // Assigned before `state` changes: both are watched by
        // `updateEscapeListener`, and setting `job` first means the listener
        // is recomputed once, already seeing the new job, instead of closing
        // and reopening Carbon's registration in the same turn.
        job = DictationJob(
            record: record,
            snapshot: recordingSnapshot,
            dictionary: recordingDictionary,
            target: injectTarget,
            stop: Task { await Self.stopOutcome(of: mic) }
        )
        state = .transcribing
        return record.id
    }

    private func runPipeline(_ entryID: UUID) async {
        guard let stop = job?.stop else { return }
        let outcome = await stop.value
        // After every await quit may own the dictation; from then on the
        // pipeline must not save, paste, flash or delete the source.
        guard owns(entryID), let current = job else { return }
        let url: URL
        switch outcome {
        case .nothing:
            finishDictation()
            return
        case let .failed(error):
            failPipeline(error)
            return
        case let .source(source, interruption):
            // Audio captured before a capture failure follows the normal save
            // path, but a cut-off dictation is never pasted.
            url = source
            job?.source = source
            job?.record.interruption = interruption
        }
        let store = historyStore
        let startedAt = current.record.startedAt
        guard let snapshot = current.snapshot else {
            let result = await save(entryID) {
                let archived = try await store.preserveSourceCAF(from: url, id: entryID, at: startedAt)
                AppLog.error("dictation-history", "saved CAF without metadata: \(archived.relativePath)")
                return nil
            }
            guard owns(entryID) else { return }
            if case let .failed(error) = result {
                AppLog.error(
                    "dictation-history",
                    "failed to preserve CAF without settings: \(error.localizedDescription)"
                )
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            finishDictation()
            return
        }

        job?.phase = .recognizing
        let recognition: Result<Recognized, any Error>
        do {
            recognition = .success(try await transcribe(url: url, snapshot: snapshot, dictionary: current.dictionary))
        } catch {
            recognition = .failure(error)
        }
        guard owns(entryID), var record = job?.record else { return }
        let decodeDuration: TimeInterval
        var replacements = 0
        switch recognition {
        case let .success(result):
            record.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = result.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            record.rawText = raw == record.text ? nil : raw
            record.actualLanguage = result.language
            decodeDuration = result.decodeDuration
            replacements = result.replacements
        case let .failure(error):
            // Archived with a history line like any dictation, marked so the
            // error is never shown as silence: it can be found and tried again
            // in Files. A model that never got ready is the reason, and Settings
            // says so, unless another engine was chosen meanwhile; a decode
            // error of a ready model is not.
            if modelState != .ready {
                modelState = .cold
                if selectedDescriptor == snapshot.dictationDescriptor {
                    modelFailure = error.localizedDescription
                }
            }
            AppLog.error("dictation", "not recognized: \(error.localizedDescription)")
            record.recognitionFailed = true
            decodeDuration = 0
        }
        job?.record = record

        // Recognition is over: a storage failure must not cost the text, so it
        // is handled here instead of failing the pipeline.
        let saveRecord = record
        let result = await save(entryID) {
            try await store.saveDictation(
                from: url,
                id: entryID,
                at: startedAt,
                // Byte for byte: the file a failed decode could not read is
                // the evidence, not something to convert.
                preserveSource: saveRecord.interruption != nil || saveRecord.recognitionFailed,
                // Empty text is a failed recognition to the person; with the
                // audio off it would leave an entry with nothing to replay.
                saveAudio: snapshot.saveDictationAudio || saveRecord.text.isEmpty
            ) { audioPath, duration in
                saveRecord.entry(audioPath: audioPath, duration: duration)
            }
        }
        guard owns(entryID) else { return }
        job?.phase = .delivering(result)
        let text = record.text
        let saved: DictationHistoryEntry?
        let saveError: Error?
        switch result {
        case let .saved(entry):
            saved = entry
            saveError = nil
        case let .failed(error):
            saved = nil
            saveError = error
            AppLog.error(
                "dictation-history",
                "history not saved; source kept at \(url.path): \(error.localizedDescription)"
            )
        }
        if saved != nil {
            try? FileManager.default.removeItem(at: url)
        }
        let audioDuration = saved?.duration ?? 0
        let rtfx = decodeDuration > 0 ? audioDuration / decodeDuration : 0
        // The count only: the log never holds dictated words.
        AppLog.info(
            "dictation",
            String(format: "engine=%@ audio=%.1fs decode=%.2fs rtfx=%.1fx replacements=%d",
                   locale: Locale(identifier: "en_US_POSIX"),
                   snapshot.dictationEngine.rawValue, audioDuration, decodeDuration, rtfx, replacements)
        )
        if let interruption = record.interruption {
            if saved == nil { insertUnsaved(record, source: url) }
            finishDictation()
            indicator.showFlash(.dictationFailure(message: Self.interruptedMessage(
                reason: interruption,
                hasText: !text.isEmpty,
                recognitionFailed: record.recognitionFailed
            )))
            return
        }
        if record.recognitionFailed {
            if saved == nil { insertUnsaved(record, source: url) }
            finishDictation()
            indicator.showFlash(.dictationFailure(message: saved == nil
                ? String(localized: "Not recognized; the audio is kept in the “M” menu until you quit")
                : String(localized: "Not recognized — the audio is in Dictations; try it in Files")))
            return
        }
        guard !text.isEmpty else {
            finishDictation()
            if let saveError {
                indicator.showFlash(.dictationFailure(
                    message: String(localized: "History not saved: \(saveError.localizedDescription)")
                ))
            } else {
                indicator.showFlash(.noSpeech)
            }
            return
        }
        if saved == nil { insertUnsaved(record, source: url) }
        // Esc already said "don't paste": the text is recognized and saved as
        // usual, but delivery never runs. Read from `job`, not the `current`
        // snapshot taken at the top — Esc may have marked it since.
        if job?.skipsDelivery == true {
            finishDictation()
            indicator.showFlash(saved == nil
                // Never promises "Dictations" when the archive write failed:
                // the text is only in the "M" menu either way.
                ? Self.historyNotSavedFlash
                : .notice(message: Self.cancelledNotPastedMessage(
                    shortcut: settings?.pasteLastDictationShortcutDescription
                )))
            return
        }
        let blockedByPasswordField = await deliver(
            text,
            to: current.target,
            historySaved: saved != nil,
            stoppedAtLimit: record.stoppedAtLimit,
            autoPaste: snapshot.autoPaste,
            entryID: entryID
        )
        guard owns(entryID) else { return }
        finishDictation()
        if saved == nil, !blockedByPasswordField {
            indicator.showFlash(Self.historyNotSavedFlash)
        }
    }

    /// Runs one store operation as the job's save, so quit can wait for exactly
    /// that operation rather than for delivery or the whole pipeline.
    private func save(
        _ entryID: UUID,
        _ operation: @escaping @Sendable () async throws -> DictationHistoryEntry?
    ) async -> SaveOutcome {
        let task = Task<SaveOutcome, Never> {
            do {
                return .saved(try await operation())
            } catch {
                return .failed(error)
            }
        }
        if job?.record.id == entryID { job?.phase = .saving(task) }
        return await task.value
    }

    private nonisolated static func stopOutcome(of mic: any MicCapturing) async -> StopOutcome {
        do {
            guard let url = try await mic.stop() else { return .nothing }
            return .source(url, interruption: nil)
        } catch let partial as MicCapture.PartialRecording {
            return .source(partial.url, interruption: partial.reason)
        } catch {
            return .failed(error)
        }
    }

    /// Deletes what a stop handed back, a partial recording included: used only
    /// where the user's own gesture said nothing was meant to be recorded.
    private nonisolated static func discard(_ outcome: StopOutcome) {
        if case let .source(url, _) = outcome { try? FileManager.default.removeItem(at: url) }
    }

    private func owns(_ entryID: UUID) -> Bool {
        guard let job, job.record.id == entryID else { return false }
        return !job.claimed
    }

    private func insertUnsaved(_ record: DictationRecord, source: URL) {
        guard !unsavedDictations.contains(where: { $0.id == record.id }) else { return }
        unsavedDictations.insert(
            UnsavedDictation(id: record.id, at: record.startedAt, text: record.text, sourceAudio: source),
            at: 0
        )
    }

    private func failPipeline(_ error: any Error) {
        if modelState != .ready {
            modelState = .cold
        }
        finishDictation()
        indicator.showFlash(.dictationFailure(message: error.localizedDescription))
        AppLog.error("dictation", "pipeline failed: \(error.localizedDescription)")
    }

    /// `historySaved == false` replaces every "the text is in the history" message: the
    /// text is then reachable only from the unsaved list in the menu. A
    /// dictation the limit ended says so in a failure-style pill, which shows
    /// even with the indicator turned off.
    ///
    /// Returns whether a password field already blocked delivery and showed
    /// its own flash: the caller must not overwrite that flash with its own.
    @discardableResult
    private func deliver(
        _ text: String,
        to target: NSRunningApplication?,
        historySaved: Bool = true,
        stoppedAtLimit: Bool = false,
        autoPaste: Bool = true,
        entryID: UUID
    ) async -> Bool {
        // Checked before every side effect that follows an await: once quit
        // accepted or took this dictation, no new paste, fallback or feedback
        // starts, even if that quit was refused meanwhile. A posted chord stays.
        func stillOwned() -> Bool { !isTerminating && owns(entryID) }
        guard stillOwned() else { return false }
        // Off: never pastes, never touches the clipboard. A failed history
        // save still gets the caller's own flash (the text is in the "M" menu
        // either way), so only a saved dictation gets a message of its own.
        guard autoPaste else {
            guard historySaved else { return false }
            indicator.showFlash(stoppedAtLimit
                ? .dictationFailure(message: Self.autoPasteOffLimitMessage(
                    shortcut: settings?.pasteLastDictationShortcutDescription
                ))
                : .notice(message: Self.autoPasteOffSavedMessage(
                    shortcut: settings?.pasteLastDictationShortcutDescription
                )))
            return false
        }
        func showPasswordFieldFlash() {
            indicator.showFlash(historySaved ? Self.passwordFieldPastedFlash : Self.passwordFieldHistoryNotSavedFlash)
        }
        // Checked first, before any clipboard write, activation or fallback:
        // a password field never gets the text, by any path.
        if focusedFieldIsSecure() == true {
            showPasswordFieldFlash()
            return true
        }
        var pasted = false
        if let deliveryOverride {
            // Stands in for the paste itself; the feedback below is real.
            await deliveringPaste { await deliveryOverride(text, target) }
            pasted = true
        } else if isAccessibilityTrusted(),
           let target,
           target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           target.activate() {
            indicator.clearBase()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(20))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    guard stillOwned() else { return false }
                    // Checked again now that the target is frontmost and the
                    // focus it reports is this field: the first check was
                    // only before activation.
                    if focusedFieldIsSecure() == true {
                        showPasswordFieldFlash()
                        return true
                    }
                    let injected = await deliveringPaste { await TextInjector.inject(text) }
                    // Quit took the dictation over meanwhile: the chord stays and
                    // inject restores the clipboard itself, but no late feedback;
                    // quit waits for it (`deliveringPaste`), the chord included.
                    guard stillOwned() else { return false }
                    guard injected else {
                        indicator.showFlash(historySaved ? .injectionFailed : Self.historyNotSavedFlash)
                        return false
                    }
                    pasted = true
                    break
                }
            }
        }
        guard stillOwned() else { return false }
        if pasted {
            // `inject` proves that the full ⌘V chord was posted, not that
            // the target application accepted it; this is the strongest
            // success signal AppKit exposes for the auto-paste path.
            playInsertionSucceededFeedback()
            indicator.showFlash(stoppedAtLimit
                ? .dictationFailure(message: String(
                    localized: "Pasted · \(text.count) — stopped at the 5-minute limit; dictate again to continue"
                ))
                : .inserted(characterCount: text.count))
            return false
        }
        playClipboardFallbackFeedback()
        if placeLocallyFallback(text) {
            indicator.showFlash(stoppedAtLimit
                ? .dictationFailure(message: String(
                    localized: "On the clipboard — press ⌘V; stopped at the 5-minute limit"
                ))
                : .clipboardFallback)
        } else {
            indicator.showFlash(historySaved ? .clipboardFailed : Self.historyNotSavedFlash)
        }
        return false
    }

    /// Whether macOS itself names the focused element a password field. nil
    /// (no trust, no focused element, an error or a timeout) pastes as before:
    /// the promise is only about fields macOS names as secure.
    private func focusedFieldIsSecure() -> Bool? {
        #if DEBUG
        if let secureFieldCheckForTesting { return secureFieldCheckForTesting() }
        #endif
        // A test process without an explicit answer must not reach real
        // Accessibility; a real launch (including the stage gate, which opts
        // out of isolation) always does.
        guard !TestIsolation.isEnabled else { return nil }
        return AccessibilityAuthorization.focusedFieldIsSecure()
    }

    private func isAccessibilityTrusted() -> Bool {
        #if DEBUG
        if let accessibilityTrustedForTesting { return accessibilityTrustedForTesting }
        #endif
        return AccessibilityAuthorization.isTrusted
    }

    private func placeLocallyFallback(_ text: String) -> Bool {
        #if DEBUG
        if let placeLocallyForTesting { return placeLocallyForTesting(text) }
        #endif
        return TextInjector.placeLocally(text)
    }

    private func finishDictation() {
        state = .idle
        finishedAt = .now
        hotkeyManager.dictationDidBecomeIdle()
        startInjectTarget = nil
        injectTarget = nil
        recordingStartedAt = nil
        recordingSnapshot = nil
        recordingDictionary = nil
        transcriptionTask = nil
        job = nil
        indicator.clearBase()
        if !isTerminating, let snapshot = settings?.snapshot {
            startModelWarmup(descriptor: snapshot.dictationDescriptor)
        }
    }

    private static func playFeedback(named name: NSSound.Name) {
        guard let sound = NSSound(named: name) else {
            NSSound.beep()
            return
        }
        _ = sound.play()
    }

    private func playRecordingStartFeedback() {
        guard settings?.soundOnRecordingStart == true else { return }
        feedbackPlayer(Self.recordingStartedSoundName)
    }

    private func playInsertionSucceededFeedback() {
        #if DEBUG
        deliveryFeedbackCountForTesting += 1
        #endif
        guard settings?.soundOnInsert == true else { return }
        feedbackPlayer(Self.insertionSucceededSoundName)
    }

    private func playClipboardFallbackFeedback() {
        #if DEBUG
        deliveryFeedbackCountForTesting += 1
        #endif
        guard settings?.soundsEnabled == true else { return }
        beepPlayer()
    }

    /// `text` is after the personal dictionary, `rawText` the engine's
    /// segments as joined, before it.
    private typealias Recognized = (
        text: String, rawText: String, language: String, decodeDuration: TimeInterval, replacements: Int
    )

    private func transcribe(
        url: URL,
        snapshot: SettingsSnapshot,
        dictionary: DictionarySnapshot?,
        followsModelProgress: Bool = true
    ) async throws -> Recognized {
        let descriptor = snapshot.dictationDescriptor
        // "Recognize Again" touches neither the indicator's bubble nor
        // `modelState` / `modelFailure`: it is not a dictation.
        let progress: @Sendable (WhisperModelState) -> Void
        if followsModelProgress {
            progress = modelProgress(descriptor: descriptor, generation: modelGeneration, showOverlay: true)
        } else {
            progress = { _ in }
        }
        let decoded = try await whisperCache.transcribe(
            audioPath: url.path,
            descriptor: descriptor,
            request: snapshot.decodeRequest,
            progress: progress
        )
        let raw = decoded.segments.map(\.text).joined(separator: " ")
        // Never throws: a dictionary problem is not a recognition failure.
        let replaced = await Self.replacing(in: raw, dictionary: dictionary)
        return (replaced.text, raw, decoded.language, decoded.decodeDuration, replaced.count)
    }

    /// Off the main actor: preparing the dictionary and the replacement both
    /// call macOS's tagger.
    private nonisolated static func replacing(
        in text: String,
        dictionary: DictionarySnapshot?
    ) async -> (text: String, count: Int) {
        guard !text.isEmpty, let replacer = dictionary?.replacer(for: .dictation) else { return (text, 0) }
        return replacer.replacing(in: text)
    }

    /// Why "Recognize Again" left the history line as it was.
    enum RecognizeAgainFailure: LocalizedError {
        /// A dictation is under way, the app is quitting, or another
        /// "Recognize Again" is already running.
        case busy
        case modelMissing
        case noSpeech
        /// Quit took the operation over before it reached (or finished) its
        /// save; the entry keeps whatever text it had before this call.
        case stoppedByQuit

        var errorDescription: String? {
            switch self {
            case .busy:
                return String(localized: "Dictation in progress — finish it first")
            case .modelMissing:
                return String(localized: "Download a model: “M” menu → “Download Model…”")
            case .noSpeech:
                return String(localized: "No speech recognized — the entry is unchanged")
            case .stoppedByQuit:
                return String(localized: "Quit stopped Recognize Again — the entry is unchanged")
            }
        }
    }

    /// Whether the dictation engine's model is in place; a test overrides
    /// this so a fixture's injected engine need not have real model files.
    private func modelIsReady(_ engine: DictationEngine) -> Bool {
        #if DEBUG
        if let recognizeAgainModelReadyForTesting { return recognizeAgainModelReadyForTesting }
        #endif
        return models.isReady(engine)
    }

    /// Recognizes `entry`'s saved audio again with the dictation's current
    /// engine, language and dictionary (`settings.snapshot`, the same path
    /// as an ordinary dictation's `transcribe`), and replaces its text in the
    /// same history line; the audio and every other field stay. Nothing is
    /// pasted or copied. Refused while a dictation is under way, while
    /// quitting, or while another "Recognize Again" runs; a new dictation
    /// started meanwhile is not refused by this — it only waits its turn at
    /// the engine cache, like any job in another engine would. An empty
    /// result or a recognition error leaves the line untouched and rethrows.
    /// Quit visible while this runs (`hasUnfinishedWork`, `AppUpdater.busy`)
    /// takes it over in the same turn it is accepted: recognition is
    /// cancelled and a late result writes nothing, but a save already begun
    /// is waited for and its failure (the entry keeps its old text) is not
    /// turned into `.stoppedByQuit`.
    func recognizeAgain(_ entry: DictationHistoryEntry) async throws {
        // Everything up to and including setting `recognizingAgainID` runs
        // synchronously on the main actor, before the first `await`: a
        // second call made while this one is still between the guard and
        // the id assignment would otherwise pass the guard too (K1).
        guard recognizingAgainID == nil, state == .idle, !isTerminating else {
            throw RecognizeAgainFailure.busy
        }
        guard let settings else { throw RecognizeAgainFailure.busy }
        let engine = settings.dictationEngine
        guard modelIsReady(engine) else { throw RecognizeAgainFailure.modelMissing }
        let snapshot = settings.snapshot
        let dictionary = settings.dictionarySnapshot

        recognizingAgainID = entry.id
        // Created, and stored in `recognizeAgainRun`, before this function's
        // first `await`: quit's `claimForTermination()` (itself synchronous,
        // inside `beginTermination()`) can then only ever see this run fully
        // in place or not created at all, never half-built.
        let work = Task<Void, any Error> { [weak self] in
            guard let self else { return }
            defer {
                self.recognizingAgainID = nil
                self.recognizeAgainRun = nil
            }
            try await self.recognizeAgainWork(entry, engine: engine, snapshot: snapshot, dictionary: dictionary)
        }
        recognizeAgainRun = RecognizeAgainRun(task: work)
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// The actual recognition and save, run inside `recognizeAgain`'s own
    /// unstructured task so quit can own it independently of the caller.
    private func recognizeAgainWork(
        _ entry: DictationHistoryEntry,
        engine: DictationEngine,
        snapshot: SettingsSnapshot,
        dictionary: DictionarySnapshot?
    ) async throws {
        // Checked right after every `await` below: quit may claim this run
        // (or simply cancel `work`) between any two suspension points.
        func owned() throws {
            if Task.isCancelled || isTerminating || recognizeAgainRun?.claimed == true {
                throw RecognizeAgainFailure.stoppedByQuit
            }
        }

        let save: Task<Void, any Error>
        do {
            guard let url = await historyStore.audioURL(for: entry) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try owned()

            let decoded = try await transcribe(
                url: url, snapshot: snapshot, dictionary: dictionary, followsModelProgress: false
            )
            try owned()

            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawText = decoded.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw RecognizeAgainFailure.noSpeech
            }

            // A separate unstructured task: once started, quit waits for it
            // instead of cancelling `work`, so a save already under way
            // always finishes.
            let saveTask = Task<Void, any Error> { [historyStore] in
                _ = try await historyStore.replaceRecognition(
                    id: entry.id,
                    text: text,
                    rawText: text == rawText ? nil : rawText,
                    actualLanguage: decoded.language,
                    engine: engine.rawValue
                )
            }
            recognizeAgainRun?.save = saveTask
            save = saveTask
        } catch {
            // Only an error from before the save started is remapped: once
            // `save` exists, its own failure (owner notified, entry kept) is
            // never hidden behind "quit stopped this".
            if recognizeAgainRun?.claimed == true || isTerminating {
                throw RecognizeAgainFailure.stoppedByQuit
            }
            throw error
        }
        try await save.value
    }

    func copyHistoryEntry(_ entry: DictationHistoryEntry) {
        guard !entry.text.isEmpty else { return }
        TextInjector.place(entry.text)
    }

    /// Copying never removes the item; only an explicit "Remove" does.
    @discardableResult
    func copyUnsavedDictation(
        _ item: UnsavedDictation,
        place: @MainActor (String) -> Bool = { TextInjector.place($0) }
    ) -> Bool {
        guard place(item.text) else {
            indicator.showFlash(.dictationFailure(
                message: String(localized: "Couldn’t copy — the text stays in the “M” menu")
            ))
            return false
        }
        return true
    }

    func revealUnsavedDictationAudio(_ item: UnsavedDictation) {
        guard FileManager.default.fileExists(atPath: item.sourceAudio.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.sourceAudio])
    }

    /// Removes the menu item only; the temporary audio is left to the system.
    /// For a dictation that blocks quit this is the user's explicit choice to
    /// give it up, so quit is no longer held for it.
    func removeUnsavedDictation(id: UUID) {
        unsavedDictations.removeAll { $0.id == id }
        pendingSaves.removeAll { $0.record.id == id }
    }

    // MARK: - Last dictation

    private enum LastLookup: Sendable {
        case text(String, inHistory: Bool)
        case unrecognized(inHistory: Bool)
        case nothing
        case unreadable
    }

    /// Read fresh at the press, never from `recentDictations`: the newest of
    /// a fresh history read and the unsaved list, the history winning a tie.
    /// A history that cannot be read refuses rather than guess at an unsaved
    /// one's being newer.
    private func lookUpLast() async -> LastLookup {
        let saved: DictationHistoryEntry?
        do {
            saved = try await historyStore.recent(limit: 1).first
        } catch {
            AppLog.error("dictation", "last dictation: couldn’t read history: \(error.localizedDescription)")
            return .unreadable
        }
        let unsaved = unsavedDictations.first
        let newest: (text: String, at: Date, inHistory: Bool)?
        if let unsaved, let saved {
            newest = unsaved.at > saved.at
                ? (unsaved.text, unsaved.at, false)
                : (saved.text, saved.at, true)
        } else if let unsaved {
            newest = (unsaved.text, unsaved.at, false)
        } else if let saved {
            newest = (saved.text, saved.at, true)
        } else {
            newest = nil
        }
        guard let newest else { return .nothing }
        guard !newest.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unrecognized(inHistory: newest.inHistory)
        }
        return .text(newest.text, inHistory: newest.inHistory)
    }

    private func showRefusal(_ lookup: LastLookup) {
        switch lookup {
        case .nothing:
            indicator.showFlash(Self.nothingToPasteFlash)
        case let .unrecognized(inHistory):
            indicator.showFlash(inHistory ? Self.lastNotRecognizedFlash : Self.lastUnsavedNotRecognizedFlash)
        case .unreadable:
            indicator.showFlash(Self.historyUnreadableFlash)
        case .text:
            break
        }
    }

    private func pasteTarget() -> NSRunningApplication? {
        #if DEBUG
        if let frontmostApplicationForTesting { return frontmostApplicationForTesting() }
        #endif
        return frontmostApplication()
    }

    private func currentModifierFlags() -> NSEvent.ModifierFlags {
        #if DEBUG
        if let modifierFlagsForTesting { return modifierFlagsForTesting() }
        #endif
        return NSEvent.modifierFlags
    }

    private func pasteLastKeyDown() {
        // A press while the previous paste is still running changes neither
        // its target nor its text; both events are skipped.
        guard pasteLastTask == nil else { return }
        guard !isTerminating else { return }
        guard state == .idle else {
            indicator.showFlash(.busyWithDictation)
            return
        }
        // An earlier press whose release never came is replaced: it had not
        // done anything yet.
        pastePress?.lookup.cancel()
        let target = pasteTarget()
        pastePress = PastePress(target: target, lookup: Task { await self.lookUpLast() })
    }

    private func pasteLastKeyUp() {
        guard pasteLastTask == nil, let press = pastePress else { return }
        pastePress = nil
        isPastingLast = true
        pasteLastTask = Task { [weak self] in
            await self?.runPasteLast(press)
            self?.pasteLastTask = nil
            self?.isPastingLast = false
        }
    }

    /// Runs a paste in a task of its own so quit can wait for exactly that
    /// task, and never cancel it: an unstructured task does not inherit the
    /// caller's cancellation, so neither a cancelled ⌃⌘V nor anything else
    /// cuts `TextInjector.inject`'s pause short.
    private func deliveringPaste<T: Sendable>(
        _ body: @escaping @MainActor @Sendable () async -> T
    ) async -> T {
        let work = Task { await body() }
        let delivery = Task { _ = await work.value }
        pasteDelivery = delivery
        pasteDelivering = true
        defer {
            // A later paste may have taken the slot meanwhile; it clears its own.
            if pasteDelivery == delivery {
                pasteDelivering = false
                pasteDelivery = nil
            }
        }
        return await work.value
    }

    private func runPasteLast(_ press: PastePress) async {
        func stillAllowed() -> Bool { !Task.isCancelled && !isTerminating && state == .idle }

        let found = await press.lookup.value
        guard !Task.isCancelled, !isTerminating else { return }
        guard state == .idle else {
            indicator.showFlash(.busyWithDictation)
            return
        }
        guard case let .text(text, inHistory) = found else {
            showRefusal(found)
            return
        }

        // A synthetic ⌘V sent while ⌃ is still down would arrive as ⌃⌘V.
        let held: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_500))
        while !currentModifierFlags().intersection(held).isEmpty {
            if ContinuousClock.now >= deadline {
                guard !Task.isCancelled, !isTerminating else { return }
                guard state == .idle else {
                    indicator.showFlash(.busyWithDictation)
                    return
                }
                indicator.showFlash(Self.releaseKeysFlash)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
        guard !Task.isCancelled, !isTerminating else { return }
        guard state == .idle else {
            indicator.showFlash(.busyWithDictation)
            return
        }

        func showPasswordFieldFlash() {
            indicator.showFlash(inHistory ? Self.passwordFieldPastedFlash : Self.passwordFieldHistoryNotSavedFlash)
        }
        if focusedFieldIsSecure() == true {
            showPasswordFieldFlash()
            return
        }

        var pasted = false
        if let deliveryOverride {
            await deliveringPaste { await deliveryOverride(text, press.target) }
            pasted = true
        } else if isAccessibilityTrusted(),
           let target = press.target,
           target.processIdentifier != ownProcessIdentifier,
           target.activate() {
            for _ in 0..<30 {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    guard stillAllowed() else { return }
                    if focusedFieldIsSecure() == true {
                        showPasswordFieldFlash()
                        return
                    }
                    let injected = await deliveringPaste { await TextInjector.inject(text) }
                    guard stillAllowed() else { return }
                    guard injected else {
                        indicator.showFlash(inHistory ? .injectionFailed : Self.historyNotSavedFlash)
                        return
                    }
                    pasted = true
                    break
                }
            }
        }

        guard stillAllowed() else { return }
        AppLog.info("dictation", "paste last: \(text.count) characters")
        if pasted {
            playInsertionSucceededFeedback()
            indicator.showFlash(.inserted(characterCount: text.count))
            return
        }
        playClipboardFallbackFeedback()
        if placeLocallyFallback(text) {
            indicator.showFlash(.clipboardFallback)
        } else {
            indicator.showFlash(inHistory ? .clipboardFailed : Self.historyNotSavedFlash)
        }
    }

    func copyLastDictation(place: @MainActor (String) -> Bool = { TextInjector.place($0) }) async {
        guard !isTerminating else { return }
        guard state == .idle else {
            indicator.showFlash(.busyWithDictation)
            return
        }
        let found = await lookUpLast()
        guard !isTerminating else { return }
        guard state == .idle else {
            indicator.showFlash(.busyWithDictation)
            return
        }
        guard case let .text(text, inHistory) = found else {
            showRefusal(found)
            return
        }
        if place(text) {
            indicator.showFlash(.notice(message: String(localized: "Copied · \(text.count)")))
        } else {
            indicator.showFlash(inHistory
                ? .clipboardFailed
                : .dictationFailure(message: String(localized: "Couldn’t copy — the text stays in the “M” menu")))
        }
    }

    // MARK: - Quit

    /// Anything quit still has to save or wait for.
    var hasUnfinishedWork: Bool {
        state != .idle || terminationTask != nil || !pendingSaves.isEmpty
            || (recognizeAgainRun.map { !$0.claimed || $0.save != nil } ?? false)
            || pasteDelivering
    }

    /// "Recognize Again" is still recognizing and not yet claimed by a quit:
    /// quitting now would lose its work, though the entry keeps its old
    /// text. Named separately from `hasUnfinishedWork` because this is the
    /// one quit should *warn* about rather than silently wait for.
    var recognizeAgainWouldBeLost: Bool {
        recognizeAgainRun.map { !$0.claimed && $0.save == nil } ?? false
    }

    /// What a just-accepted quit must still wait for, captured synchronously
    /// by `claimForTermination()`.
    private struct TerminationWaits {
        var recognizeAgainSave: Task<Void, any Error>?
        var paste: Task<Void, Never>?
    }

    /// Takes over "Recognize Again" and ⌃⌘V in the same main-actor turn that
    /// quit is accepted — before the termination task is even created — so
    /// neither can start a save or a delivery of its own afterwards. A save
    /// or a delivery already begun — ⌃⌘V's or an ordinary dictation's own —
    /// is handed back to be waited for, never cancelled.
    private func claimForTermination() -> TerminationWaits {
        var recognizeAgainSave: Task<Void, any Error>?
        if var run = recognizeAgainRun {
            run.claimed = true
            recognizeAgainRun = run
            if run.save == nil {
                run.task.cancel()
            }
            recognizeAgainSave = run.save
        }
        let paste = pasteDelivering ? pasteDelivery : nil
        if !pasteDelivering {
            dropUndeliveredPaste()
        }
        return TerminationWaits(recognizeAgainSave: recognizeAgainSave, paste: paste)
    }

    /// Cancels a ⌃⌘V not delivered yet (an ordinary dictation's own delivery
    /// is never cancelled here, by `owns`/`stillOwned`): the clipboard was
    /// never touched, so there is nothing worth waiting for.
    private func dropUndeliveredPaste() {
        pastePress?.lookup.cancel()
        pastePress = nil
        pasteLastTask?.cancel()
    }

    /// Starts the quit-time work or joins the running one. New starts stay
    /// blocked until that work actually ends, even if this quit is abandoned.
    func beginTermination() -> Task<Bool, Never> {
        quitRequested = true
        isTerminating = true
        hotkeyManager.closeEscapeListener()
        let waits = claimForTermination()
        if let terminationTask { return terminationTask }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return true }
            let saved = await self.finishForTermination(waitingFor: waits)
            self.terminationTask = nil
            if !self.quitRequested { self.isTerminating = false }
            return saved
        }
        terminationTask = task
        return task
    }

    /// Quit was answered "no". Starts are allowed again once no quit-time work
    /// is still running; a still-running one unblocks them when it ends.
    func cancelTermination() {
        quitRequested = false
        if terminationTask == nil { isTerminating = false }
    }

    /// Quit was allowed at once (nothing in `hasUnfinishedWork`): nothing may
    /// start or be delivered after it. A ⌃⌘V not delivered yet is dropped
    /// the same way a two-phase quit would drop it; one already delivering —
    /// ⌃⌘V's or an ordinary dictation's own — is not possible here, since
    /// that sets `pasteDelivering`, which this branch of quit never reaches.
    func prepareForImmediateQuit() {
        quitRequested = true
        isTerminating = true
        dropUndeliveredPaste()
    }

    /// Quit was held back because it would lose work; the pill names it.
    /// A failure-style pill, so it shows with the indicator turned off too.
    func showQuitWarning(_ message: String) {
        indicator.showFlash(.meetingFailure(message: message))
    }

    func showTerminationDeferred() {
        indicator.showFlash(.dictationFailure(
            message: String(localized: "Quit postponed: saving not confirmed — details in the “M” menu")
        ))
    }

    /// True only when nothing unsaved remains. Never waits for a model.
    private func finishForTermination(waitingFor waits: TerminationWaits) async -> Bool {
        switch state {
        case .starting:
            // Invalidate the attempt; a late success is kept or dropped by
            // `keepLateStartAudio`. Starting involves no model, and the caller's
            // deadline answers quit if Core Audio stalls here.
            startAttempt &+= 1
            startWatchdogTask?.cancel()
            startWatchdogTask = nil
            if let startTask { await startTask.value }
            startTask = nil
            if state == .starting { finishDictation() }
        case .recording:
            beginStop()
        case .idle, .transcribing:
            break
        }
        // Saves left over from an earlier quit are retried; one that fails in
        // this pass is not retried again until the next quit.
        let earlier = pendingSaves
        await finishJobForTermination()
        for pending in earlier where pendingSaves.contains(where: { $0.record.id == pending.record.id }) {
            await saveForTermination(pending)
        }
        // A "Recognize Again" save already begun is waited for, win or lose:
        // its failure does not refuse quit (the entry and its audio stay),
        // but the text this run would have written is lost, so it is logged.
        if let save = waits.recognizeAgainSave {
            do {
                try await save.value
            } catch {
                let failure = error as NSError
                AppLog.error(
                    "dictation",
                    "quit: Recognize Again's save failed (\(failure.domain) \(failure.code)); the entry keeps its old text"
                )
            }
        }
        // A paste already delivering — ⌃⌘V's or a dictation's own — is
        // waited for until the clipboard is restored; it is never cancelled.
        await waits.paste?.value
        return pendingSaves.isEmpty
    }

    /// Takes the current dictation over from the pipeline. Recognition is
    /// cancelled without waiting for it; a save already running is the only
    /// thing awaited.
    private func finishJobForTermination() async {
        guard var current = job, !current.claimed else { return }
        current.claimed = true
        job = current
        // Progress callbacks of the abandoned decode must not touch the indicator.
        modelGeneration &+= 1
        switch current.phase {
        case .stopping, .recognizing:
            transcriptionTask?.cancel()
            if case let .source(url, interruption) = await current.stop.value {
                var record = current.record
                record.interruption = interruption
                record.recognitionSkipped = true
                await saveForTermination(PendingSave(record: record, source: url, archived: nil))
            }
        case let .saving(task):
            settle(current, outcome: await task.value)
        case let .delivering(outcome):
            settle(current, outcome: outcome)
        }
        finishDictation()
    }

    /// A save the pipeline already ran. Confirmed → the source goes; failed →
    /// text and source stay pending, reusing the archived copy if there is one.
    private func settle(_ job: DictationJob, outcome: SaveOutcome) {
        guard let source = job.source else { return }
        switch outcome {
        case .saved:
            try? FileManager.default.removeItem(at: source)
        case let .failed(error):
            let index = error as? DictationHistoryStore.IndexWriteFailed
            keepPending(
                PendingSave(
                    record: job.record,
                    source: source,
                    archived: index.map { (path: $0.audioPath, duration: $0.duration) }
                ),
                error: error
            )
        }
    }

    /// Saves raw audio and any text already recognized; the source is removed
    /// only after the save is confirmed.
    private func saveForTermination(_ pending: PendingSave) async {
        let record = pending.record
        do {
            if let archived = pending.archived {
                do {
                    try await historyStore.indexArchivedDictation(
                        record.entry(audioPath: archived.path, duration: archived.duration)
                    )
                } catch is DictationHistoryStore.ArchivedAudioMissing {
                    try await saveRawSource(of: pending)
                }
            } else {
                try await saveRawSource(of: pending)
            }
            try? FileManager.default.removeItem(at: pending.source)
            pendingSaves.removeAll { $0.record.id == record.id }
            unsavedDictations.removeAll { $0.id == record.id }
        } catch {
            var failed = pending
            if let index = error as? DictationHistoryStore.IndexWriteFailed {
                failed.archived = (path: index.audioPath, duration: index.duration)
            }
            keepPending(failed, error: error)
        }
    }

    private func saveRawSource(of pending: PendingSave) async throws {
        let record = pending.record
        _ = try await historyStore.saveDictation(
            from: pending.source,
            id: record.id,
            at: record.startedAt,
            preserveSource: true
        ) { audioPath, duration in
            record.entry(audioPath: audioPath, duration: duration)
        }
    }

    private func keepPending(_ pending: PendingSave, error: any Error) {
        AppLog.error(
            "dictation-history",
            "quit-time save not confirmed; source kept at \(pending.source.path): \(error.localizedDescription)"
        )
        if let index = pendingSaves.firstIndex(where: { $0.record.id == pending.record.id }) {
            pendingSaves[index] = pending
        } else {
            pendingSaves.append(pending)
        }
        insertUnsaved(pending.record, source: pending.source)
    }

    /// A start that succeeded after quit invalidated it may already hold speech:
    /// anything with audio is kept, only a provably empty file is dropped.
    private func keepLateStartAudio() async {
        guard case let .source(url, interruption) = await Self.stopOutcome(of: mic) else { return }
        guard !MicCapture.holdsNoAudio(url) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var record = DictationRecord(
            startedAt: Date(),
            snapshot: recordingSnapshot ?? settings?.snapshot,
            target: startInjectTarget
        )
        record.interruption = interruption
        record.recognitionSkipped = true
        await saveForTermination(PendingSave(record: record, source: url, archived: nil))
    }

    private func startHistoryLoad() {
        guard !TestIsolation.isTestProcess else { return }
        refreshRecentDictations()
    }

    /// Replaces the recent menu with a fresh read of the store. A newer refresh
    /// wins over an older one that returns later.
    private func refreshRecentDictations() {
        recentRefresh &+= 1
        let requested = recentRefresh
        let store = historyStore
        Task { [weak self] in
            do {
                let stored = try await store.recent(limit: 10)
                guard let self, requested == self.recentRefresh else { return }
                self.recentDictations = stored
            } catch {
                AppLog.error(
                    "dictation-history",
                    "failed to load recent entries: \(error.localizedDescription)"
                )
            }
        }
    }

    private func engineSelectionDidChange(descriptor: EngineDescriptor) {
        guard descriptor != selectedDescriptor else { return }
        selectedDescriptor = descriptor
        modelGeneration &+= 1
        warmTask?.cancel()
        warmTask = nil
        modelState = .cold
        modelFailure = nil
        guard state == .idle else { return }
        startModelWarmup(descriptor: descriptor)
    }

    /// After meeting jobs or a Files run in an engine of their own, which
    /// took the cache: the selected model goes back by the warm-up's own
    /// rules. Only while idle (a dictation under way warms it as it ends),
    /// only with its model there, and under the selection's generation, so a
    /// later change of the settings wins over it. A failure shows as the
    /// warm-up's would; the job's result is in already.
    func prepareAfterOtherEngineJob() {
        guard state == .idle, let engine = settings?.dictationEngine else { return }
        startModelWarmup(descriptor: EngineDescriptor(engine: engine, modelPath: SettingsStore.modelPath(for: engine)))
    }

    /// Prepares the selected model again: after a download, which may be the
    /// first model the engine ever had, or when the person asks after a
    /// failure. A model already warm or in use is left alone: the download
    /// was for something else, and a dictation re-warms when it ends.
    func retryModelPreparation() {
        guard state == .idle, modelState == .cold || modelFailure != nil,
              let engine = settings?.dictationEngine else { return }
        selectedDescriptor = nil
        engineSelectionDidChange(
            descriptor: EngineDescriptor(engine: engine, modelPath: SettingsStore.modelPath(for: engine))
        )
    }

    private func startModelWarmup(descriptor: EngineDescriptor) {
        guard warmsUp else {
            AppLog.info("engine", "warmup skipped for testing")
            return
        }
        guard warmTask == nil else { return }
        guard models.isReady(descriptor.engine) else {
            AppLog.info("engine", "warmup skipped: no \(descriptor.engine.rawValue) model")
            return
        }
        selectedDescriptor = descriptor
        modelFailure = nil
        let generation = modelGeneration
        let cache = whisperCache
        let progress = modelProgress(
            descriptor: descriptor,
            generation: generation,
            showOverlay: false
        )
        warmTask = Task { [weak self] in
            do {
                await cache.updateDesired(descriptor, generation: generation)
                try await cache.prepareDesired(progress: progress)
                guard self?.modelGeneration == generation,
                      self?.selectedDescriptor == descriptor else { return }
                AppLog.info("engine", "warmup completed engine=\(descriptor.engine.rawValue)")
            } catch is CancellationError {
                guard self?.modelGeneration == generation else { return }
                self?.modelState = .cold
                AppLog.info("engine", "warmup cancelled engine=\(descriptor.engine.rawValue)")
            } catch {
                // An older selection's failure must not show on the new one.
                guard self?.modelGeneration == generation else { return }
                self?.modelState = .cold
                self?.modelFailure = error.localizedDescription
                AppLog.error("engine", "warmup failed: \(error.localizedDescription)")
            }
            if self?.modelGeneration == generation { self?.warmTask = nil }
        }
    }

    private func modelProgress(
        descriptor: EngineDescriptor,
        generation: UInt,
        showOverlay: Bool
    ) -> @Sendable (WhisperModelState) -> Void {
        { [weak self] newState in
            Task { @MainActor [weak self] in
                guard self?.selectedDescriptor == descriptor,
                      self?.modelGeneration == generation else { return }
                self?.applyModelProgress(newState, showOverlay: showOverlay)
            }
        }
    }

    private func applyModelProgress(_ newState: WhisperModelState, showOverlay: Bool) {
        if newState == .waiting, showOverlay, modelState == .loading, warmTask != nil {
            indicator.setBase(.loadingModel)
            return
        }
        modelState = newState
        if newState == .ready { modelFailure = nil }
        guard showOverlay else { return }
        switch newState {
        case .cold, .loading:
            indicator.setBase(.loadingModel)
        case .waiting:
            indicator.setBase(.waitingEngine)
        case .ready:
            indicator.setBase(.recognizing)
        }
    }

    private func showModelPreparationIfNeeded() {
        switch modelState {
        case .cold, .loading:
            indicator.setBase(.loadingModel)
        case .waiting:
            indicator.setBase(.waitingEngine)
        case .ready:
            break
        }
    }

    #if DEBUG
    // Test hooks for the real attempt-token and production-Whisper gates without TCC.
    func beginCaptureForTesting() { beginCapture() }
    func configureForTesting(settings: SettingsStore) {
        self.settings = settings
        selectedDescriptor = settings.snapshot.dictationDescriptor
    }
    /// Overrides `recognizeAgain`'s model-readiness check: set so a fixture's
    /// injected engine need not have real model files on disk.
    var recognizeAgainModelReadyForTesting: Bool?
    var selectedDescriptorForTesting: EngineDescriptor? { selectedDescriptor }
    var hasStartInjectTargetForTesting: Bool { startInjectTarget != nil }
    func playInsertionSucceededFeedbackForTesting() { playInsertionSucceededFeedback() }
    func playClipboardFallbackFeedbackForTesting() { playClipboardFallbackFeedback() }
    /// Stands in for `AccessibilityAuthorization.focusedFieldIsSecure()`. Set,
    /// it wins over every other rule, including test isolation.
    var secureFieldCheckForTesting: (() -> Bool?)?
    /// Stands in for `AccessibilityAuthorization.isTrusted` in `deliver`.
    var accessibilityTrustedForTesting: Bool?
    /// Stands in for `TextInjector.placeLocally(_:)`: a test writes to its own
    /// pasteboard instead of the real one.
    var placeLocallyForTesting: ((String) -> Bool)?
    /// Stands in for `NSEvent.modifierFlags` while waiting for ⌃⌘V's keys to
    /// release.
    var modifierFlagsForTesting: (() -> NSEvent.ModifierFlags)?
    /// Stands in for the frontmost application read at ⌃⌘V's key-down only:
    /// the fixture's injected `frontmostApplication()` is fixed for the whole
    /// coordinator, but a test needs the front app to change between the
    /// press and the release.
    var frontmostApplicationForTesting: (() -> NSRunningApplication?)?
    func pasteLastKeyDownForTesting() { pasteLastKeyDown() }
    @discardableResult
    func pasteLastKeyUpForTesting() -> Task<Void, Never>? {
        pasteLastKeyUp()
        return pasteLastTask
    }
    func cancelPasteLastForTesting() {
        dropUndeliveredPaste()
    }
    /// Counts calls to both feedback functions, from the top, before either
    /// checks its sound setting: the fixture's `feedbackPlayer`/`beepPlayer`
    /// stubs are silent, so a test otherwise cannot tell a skipped paste from
    /// one that played no sound only because the setting was off.
    private(set) var deliveryFeedbackCountForTesting = 0
    /// Skips the model and microphone gates, which the test host cannot pass.
    var startSkipsDeviceGatesForTesting = false
    /// Stands in for the clock a hold is measured with.
    var holdClockForTesting: (() -> ContinuousClock.Instant)?
    var hotkeyManagerForTesting: HotkeyManager { hotkeyManager }
    /// Counts every Esc the listener's stream handed to `escapePressed`,
    /// ignored presses (idle, already delivering) included: a test waits on
    /// this instead of guessing when the event was actually processed.
    private(set) var escapeEventsHandled = 0
    var escapeEventsHandledForTesting: Int { escapeEventsHandled }
    /// Whether the current job is actually marked "don't paste" — read live,
    /// not from a snapshot taken earlier in the pipeline.
    var skipsDeliveryForTesting: Bool { job?.skipsDelivery ?? false }
    var isEscapeListenerOpenForTesting: Bool { hotkeyManager.isEscapeListenerOpenForTesting }
    var escapeShortcutsForTesting: Set<KeyboardShortcuts.Shortcut> { hotkeyManager.escapeShortcutsForTesting }
    @discardableResult
    func pressEscapeForTesting() -> Bool { hotkeyManager.pressEscapeForTesting() }
    @discardableResult
    func pressEscapeForTesting(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        hotkeyManager.pressEscapeForTesting(shortcut)
    }
    /// Calls the handler directly, bypassing the listener's stream: only for
    /// asserting that an idle coordinator ignores Esc synchronously.
    func escapePressedForTesting() { escapePressed() }
    #endif

    static func preferredInjectionTarget<Application>(
        startedWith: Application?,
        stoppedWith: Application?,
        isOwnApplication: (Application) -> Bool
    ) -> Application? {
        if let stoppedWith, !isOwnApplication(stoppedWith) { return stoppedWith }
        if let startedWith, !isOwnApplication(startedWith) { return startedWith }
        return nil
    }
}
