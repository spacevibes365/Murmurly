import AppKit
import AVFoundation
import Combine
import Foundation

protocol MeetingCaptureBackend: Sendable {
    /// Records into `directory`, which the recorder has just made for this
    /// session. A start that fails or is cancelled removes it.
    func start(in directory: URL) async throws -> Date
    func stop() async throws -> [URL]
}

/// Owns the production meeting flow: menu/hotkey -> system audio + microphone
/// capture -> durable separate CAF tracks. Post-call transcription is the next
/// layer; a stopped recording is already usable and never discarded.
@MainActor
final class MeetingRecorder: ObservableObject {
    enum State: Equatable, Sendable {
        case idle, starting, recording, stopping
        /// `cause`: the capture's own reason, when it gave one; the menu's
        /// next step depends on it.
        case failed(String, cause: SystemAudioCaptureError? = nil)

        var isBusy: Bool {
            switch self {
            case .idle, .failed: return false
            case .starting, .recording, .stopping: return true
            }
        }

        /// The menu's next step under a failure.
        var failureHint: String? {
            guard case let .failed(_, cause) = self else { return nil }
            switch cause {
            case .noInputDevice?:
                // The Mac has no microphone: the permission is not what to check.
                return String(localized: "Connect a microphone, then choose Record Meeting")
            case .microphoneNotReady?:
                return String(localized: "Wait a moment, then choose Record Meeting")
            case .microphoneUnavailable?, .coreAudio?:
                // Refused at the start: the microphone permission, or Core
                // Audio not starting the recording, most often for want of the
                // system audio permission.
                return String(localized: "Check Settings → Permissions, then choose Record Meeting")
            default:
                // A recording that broke off was saved as far as it went; the
                // permissions are not what to check.
                return nil
            }
        }
    }

    /// A quit-time stop without proof that the recording was saved. It blocks
    /// quit until a retry finds the proof or the user gives it up.
    struct UnconfirmedRecording: Equatable, Sendable {
        let directory: URL?
        let reason: String
    }

    /// What the last stop of a started session proved.
    private enum StopEvidence {
        case saved
        case failed(directory: URL?, reason: String)
    }

    /// The session under way, from the moment its folder exists until the
    /// result of its stop is published, the queue's job included: a folder
    /// without `metadata.json` is this recording, not one that broke off.
    struct Session: Equatable, Sendable {
        let directory: URL
        /// The folder itself, read as it is made (on this Mac): a deletion
        /// of it at any other address is refused while it lives.
        var identity: FolderIdentity? = nil
        /// Set once the capture runs.
        var startedAt: Date?
        /// The automatic recording's app or `pid:<n>`; nil when started by hand.
        let trigger: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSession: Session?
    @Published private(set) var lastRecordingDirectory: URL?
    @Published private(set) var unconfirmedRecording: UnconfirmedRecording?

    /// A recording saved with problems, tied to its own folder so a later clean
    /// recording neither clears nor relabels it; a later problem replaces it.
    struct RecordingWarning: Equatable, Sendable {
        let directory: URL
        let issues: [String]
    }

    @Published private(set) var recordingWarning: RecordingWarning?
    private let capture: any MeetingCaptureBackend
    private let hasMicrophoneAccess: @MainActor @Sendable () -> Bool
    private let permissionPromptDelay: Duration
    private let watchdogSnapshotSource: MeetingWatchdog.SnapshotSource
    private let indicator: RecordingIndicator
    private let beepPlayer: @MainActor @Sendable () -> Void
    private let fileViewer: @MainActor @Sendable (URL) -> Void
    private let createSession: @MainActor () throws -> URL
    private weak var settings: SettingsStore?
    private weak var permissions: PermissionManager?
    private weak var dictation: DictationCoordinator?
    /// Set only on the recorder the app builds, not the quit probe's, so a
    /// probe's stop never starts a real transcription or compression.
    weak var transcripts: MeetingTranscriptionQueue? {
        didSet {
            transcripts?.isRecorderBusy = { [weak self] in self?.isBusy ?? false }
            transcripts?.currentRecording = { [weak self] in self?.currentSession?.directory }
            transcripts?.currentRecordingIdentity = { [weak self] in self?.currentSession?.identity }
            // The dictation as `activate` hands it over, whichever comes first.
            transcripts?.heldByDictation = { [weak self] in self?.dictation?.heldEngine() }
            transcripts?.prepareDictationEngine = { [weak self] in self?.dictation?.prepareAfterOtherEngineJob() }
        }
    }
    private var activated = false
    private var operationTask: Task<Void, Never>?
    private var watchdog: MeetingWatchdog?
    private var settingsCancellable: AnyCancellable?
    private var stopAutomaticWhenStarted = false
    private var recordingTrigger: String?
    private var stopEvidence: StopEvidence?
    private var isTerminating = false
    private var quitRequested = false
    private var terminationTask: Task<Bool, Never>?

    init(
        capture: any MeetingCaptureBackend,
        indicator: RecordingIndicator,
        hasMicrophoneAccess: @escaping @MainActor @Sendable () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        permissionPromptDelay: Duration = .milliseconds(150),
        watchdogSnapshotSource: @escaping MeetingWatchdog.SnapshotSource =
            MeetingWatchdog.readSystemSnapshot,
        beepPlayer: @escaping @MainActor @Sendable () -> Void = { NSSound.beep() },
        fileViewer: @escaping @MainActor @Sendable (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        },
        createSession: @escaping @MainActor () throws -> URL = { try RecordingsStore().createSession() }
    ) {
        self.capture = capture
        self.indicator = indicator
        self.hasMicrophoneAccess = hasMicrophoneAccess
        self.permissionPromptDelay = permissionPromptDelay
        self.watchdogSnapshotSource = watchdogSnapshotSource
        self.beepPlayer = beepPlayer
        self.fileViewer = fileViewer
        self.createSession = createSession
    }

    var isBusy: Bool { state.isBusy }

    func activate(
        settings: SettingsStore,
        permissions: PermissionManager,
        dictation: DictationCoordinator,
        showGettingStarted: () -> Void = {}
    ) {
        self.settings = settings
        self.permissions = permissions
        self.dictation = dictation
        dictation.meetingPeer = self
        guard !activated else { return }
        activated = true
        if settings.prepareGettingStarted() { showGettingStarted() }
        HotkeyManager.registerMeeting { [weak self] in self?.toggle() }
        let watchdog = MeetingWatchdog(
            snapshotSource: watchdogSnapshotSource,
            recorderState: { [weak self] in self?.state ?? .idle },
            requestStart: { [weak self] trigger in
                self?.beginStart(trigger: trigger) ?? false
            },
            requestStop: { [weak self] in self?.stopFromWatchdog() },
            requestLimitStop: { [weak self] in self?.stopFromWatchdog(atLimit: true) }
        )
        self.watchdog = watchdog
        settingsCancellable = Publishers.CombineLatest(
            settings.$autoRecordMeetings, settings.$meetingExcludedBundleIDs
        ).sink { [weak watchdog] enabled, excluded in
            watchdog?.updateSettings(enabled: enabled, excludedBundleIDs: excluded)
        }
        watchdog.start()
        // Recordings stopped by an earlier quit, old ones from before
        // compression existed and ones still waiting to move are found now.
        transcripts?.activate()
        AppLog.info(
            "meeting",
            TestIsolation.isEnabled
                ? "activated; test isolation: no global hotkey, no process snapshot"
                : "activated; meeting hotkey \(settings.meetingShortcutDescription ?? "not set")"
        )
    }

    func toggle() {
        guard !isTerminating else {
            AppLog.info("meeting", "quitting — toggle ignored")
            return
        }
        switch state {
        case .idle, .failed: beginStart()
        case .recording: beginStop()
        case .starting, .stopping:
            AppLog.info("meeting", "busy (\(state)) — toggle ignored")
        }
    }

    /// Where the last recording is now, for "Show Last Recording…".
    var lastRecordingLocation: URL? {
        lastRecordingDirectory.map(location(of:))
    }

    var automaticRecordingBundleID: String? {
        guard let recordingTrigger, !recordingTrigger.hasPrefix("pid:"),
              state == .starting || state == .recording else { return nil }
        return recordingTrigger
    }

    private func stopFromWatchdog(atLimit: Bool = false) {
        if state == .starting, recordingTrigger != nil {
            // Do not cancel capture.start: its cancellation cleanup removes
            // the folder. A late success must use the ordinary durable stop.
            stopAutomaticWhenStarted = true
        } else {
            beginStop(atLimit: atLimit)
        }
    }

    /// A recording may have moved to the meetings folder since it was saved.
    /// The queue moved the folder and knows where to; without it, the
    /// current meetings folder is the guess.
    private func location(of directory: URL) -> URL {
        transcripts?.location(of: directory) ?? RecordingsStore.currentLocation(
            of: directory,
            meetingsFolder: settings?.meetingDestinations.meetings
        )
    }

    @discardableResult
    private func beginStart(trigger: String? = nil) -> Bool {
        guard !isTerminating, state == .idle || isFailed else { return false }
        if let dictation, dictation.isBusy {
            if trigger == nil {
                indicator.showFlash(.busyWithDictation)
                AppLog.info("meeting", "dictation busy — start ignored")
            }
            return false
        }
        guard hasMicrophoneAccess() else {
            if trigger == nil {
                permissions?.refresh()
                indicator.showFlash(.meetingMicrophoneAccessDenied)
            }
            return false
        }
        // Made here, on the main actor and before any wait, so the window
        // knows the folder from the first moment of the start.
        let directory: URL
        do {
            directory = try createSession()
        } catch {
            state = .failed(error.localizedDescription)
            if trigger != nil { watchdog?.automaticStartFailed() }
            indicator.finish(with: .meetingFailure(message: error.localizedDescription))
            AppLog.error("meeting", "start failed: no session folder: \(error.localizedDescription)")
            return true
        }
        recordingTrigger = trigger
        stopAutomaticWhenStarted = false
        state = .starting
        currentSession = Session(directory: directory, identity: FolderIdentity.of(directory), trigger: trigger)
        lastRecordingDirectory = nil
        if trigger == nil {
            // Before any await: a tick must not treat this session as the
            // automatic attempt that may have just failed.
            watchdog?.manualRecordingStarted()
            AppWindowController.enterRegular()
        }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            // Keep the app foreground while Core Audio presents its one-time
            // system-audio consent dialog.
            if trigger == nil { try? await Task.sleep(for: self.permissionPromptDelay) }
            do {
                let startedAt = try await self.capture.start(in: directory)
                if Task.isCancelled {
                    // The session did start, so its stop is the only proof
                    // that what it captured was saved.
                    await self.stopCancelledStart()
                    self.state = .idle
                    self.currentSession = nil
                    self.recordingTrigger = nil
                    self.indicator.clearBase()
                    self.watchdog?.automaticStartCancelled()
                    return
                }
                self.state = .recording
                self.currentSession?.startedAt = startedAt
                self.playBeepIfEnabled()
                self.indicator.setBase(.recordingMeeting(
                    startedAt: startedAt,
                    automatic: trigger != nil
                ))
                AppLog.info("meeting", "recording system audio + microphone")
                if self.stopAutomaticWhenStarted {
                    self.operationTask = nil
                    self.beginStop()
                    return
                }
            } catch is CancellationError {
                _ = try? await self.capture.stop()
                self.state = .idle
                self.currentSession = nil
                self.recordingTrigger = nil
                self.indicator.clearBase()
                self.watchdog?.automaticStartCancelled()
            } catch {
                let cause = error as? SystemAudioCaptureError
                self.state = .failed(error.localizedDescription, cause: cause)
                self.currentSession = nil
                self.recordingTrigger = nil
                // A stop already ordered for this call (automatic recording
                // turned off, its app excluded) outranks the retry a passing
                // failure earns: the call stays stopped.
                self.watchdog?.automaticStartFailed(
                    passing: cause == .microphoneNotReady && !self.stopAutomaticWhenStarted
                )
                self.indicator.finish(with: .meetingFailure(message: error.localizedDescription))
                AppLog.error("meeting", "start failed: \(error.localizedDescription)")
            }
            self.operationTask = nil
            if trigger == nil { AppWindowController.windowDidClose() }
        }
        return true
    }

    /// A stop at the time limit is reported like a recording saved with a
    /// warning, in memory only: `metadata.json` describes the tracks, and a
    /// limit says nothing about them.
    private func beginStop(atLimit: Bool = false) {
        guard state == .recording else { return }
        state = .stopping
        // Before the save is awaited, so a call that starts meanwhile is not
        // banned together with the one being stopped.
        watchdog?.recordingWillStop()
        indicator.setBase(.savingMeeting)
        let trigger = recordingTrigger
        let limitIssues = atLimit ? [String(
            localized: "Stopped at the 4-hour limit for automatic recordings. Start a new recording to continue."
        )] : []
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // After everything the stop publishes, the queue's job
                // included: the session's folder now speaks for itself.
                self.currentSession = nil
                self.recordingTrigger = nil
                self.watchdog?.recordingDidEnd()
                self.operationTask = nil
            }
            do {
                let tracks = try await self.capture.stop()
                self.stopEvidence = .saved
                let directory = tracks.first?.deletingLastPathComponent()
                self.lastRecordingDirectory = directory
                let metadata = directory.flatMap {
                    self.metadata(in: $0, applying: trigger)
                }
                var issues: [String] = []
                if let metadata, metadata.state != "done" {
                    issues = metadata.issues
                        ?? [String(localized: "state “\(metadata.state)” — check the recording")]
                }
                issues += limitIssues
                if let directory, !issues.isEmpty {
                    self.recordingWarning = RecordingWarning(directory: directory, issues: issues)
                }
                self.state = .idle
                if let directory { self.offerToQueue(directory) }
                self.playBeepIfEnabled()
                let terminalState: IndicatorState = metadata?.state == "suspect" || atLimit
                    ? .meetingSavedSuspect
                    : .meetingSaved
                self.indicator.finish(with: terminalState)
                AppLog.info("meeting", "stopped; tracks: \(tracks.map(\.lastPathComponent))")
            } catch is CancellationError {
                self.stopEvidence = .failed(directory: nil, reason: String(localized: "stop cancelled"))
                self.state = .idle
                self.indicator.clearBase()
            } catch {
                self.stopEvidence = .failed(
                    directory: (error as? SystemAudioCaptureError)?.savedDirectory,
                    reason: error.localizedDescription
                )
                if let captureError = error as? SystemAudioCaptureError,
                   let savedDirectory = captureError.savedDirectory {
                    self.lastRecordingDirectory = savedDirectory
                    let metadata = self.metadata(in: savedDirectory, applying: trigger)
                    self.recordingWarning = RecordingWarning(
                        directory: savedDirectory,
                        issues: (metadata?.issues ?? [error.localizedDescription]) + limitIssues
                    )
                }
                self.state = .failed(error.localizedDescription)
                let terminalState: IndicatorState = self.lastRecordingDirectory == nil
                    ? .meetingFailure(message: error.localizedDescription)
                    : .meetingSavedPartially
                self.indicator.finish(with: terminalState)
                AppLog.error("meeting", "stop failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopCancelledStart() async {
        do {
            _ = try await capture.stop()
            stopEvidence = .saved
        } catch {
            stopEvidence = .failed(
                directory: (error as? SystemAudioCaptureError)?.savedDirectory,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Quit

    /// Anything quit still has to stop, wait for or confirm.
    var hasUnfinishedWork: Bool {
        isBusy || terminationTask != nil || unconfirmedRecording != nil
    }

    /// Starts the quit-time work or joins the running one. New starts stay
    /// blocked until that work actually ends, even if this quit is abandoned.
    func beginTermination() -> Task<Bool, Never> {
        quitRequested = true
        isTerminating = true
        if let terminationTask { return terminationTask }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return true }
            let saved = await self.finishForTermination()
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

    /// Where the recording a warning is about is now.
    var warnedRecordingLocation: URL? {
        recordingWarning.map { location(of: $0.directory) }
    }

    func dismissRecordingWarning() {
        recordingWarning = nil
    }

    /// A meeting the window deleted, or the audio of it: the warning about
    /// its tracks goes, and, with the whole meeting, "Show Last Recording…".
    func forget(_ folder: URL, wholeMeeting: Bool) {
        let path = folder.standardizedFileURL.path
        if warnedRecordingLocation?.standardizedFileURL.path == path { recordingWarning = nil }
        if wholeMeeting, lastRecordingLocation?.standardizedFileURL.path == path { lastRecordingDirectory = nil }
    }

    /// The user's explicit choice to quit without proof for this recording.
    func releaseUnconfirmedRecording() {
        unconfirmedRecording = nil
    }

    /// In Finder, not the window: the folder may hold no metadata at all.
    func revealUnconfirmedRecording() {
        guard let directory = unconfirmedRecording?.directory else { return }
        fileViewer(location(of: directory))
    }

    /// True only with proof that every started session was saved: a clean stop,
    /// or a failed one whose folder holds a readable `metadata.json`.
    private func finishForTermination() async -> Bool {
        stopEvidence = nil
        switch state {
        case .recording:
            beginStop()
        case .starting:
            operationTask?.cancel()
        case .stopping, .idle, .failed:
            break
        }
        if let operationTask { await operationTask.value }
        switch stopEvidence {
        case .saved:
            unconfirmedRecording = nil
        case let .failed(directory, reason):
            if let directory, Self.hasReadableMetadata(in: directory) {
                unconfirmedRecording = nil
            } else {
                unconfirmedRecording = UnconfirmedRecording(directory: directory, reason: reason)
                AppLog.error("meeting", "quit: recording not confirmed as saved: \(reason)")
            }
        case nil:
            // No session was stopped now. A recording left unconfirmed by an
            // earlier quit is confirmed only if its proof has appeared since.
            if let directory = unconfirmedRecording?.directory,
               Self.hasReadableMetadata(in: directory) {
                unconfirmedRecording = nil
            }
        }
        return unconfirmedRecording == nil
    }

    /// Proof of a finished save: metadata written by a completed `stop`, with a
    /// terminal state and an end time, not an intermediate snapshot.
    private static func hasReadableMetadata(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(MeetingMetadata.self, from: data) else {
            return false
        }
        return ["done", "suspect", "failed"].contains(metadata.state) && !metadata.endedAt.isEmpty
    }

    /// Names who started the recording in its metadata: the automatic
    /// recording's app, or `manual`. Only there: `recordingTrigger` stays nil
    /// for a manual recording, which is how the watchdog tells the two apart.
    private func metadata(in directory: URL, applying trigger: String?) -> MeetingMetadata? {
        let url = directory.appendingPathComponent("metadata.json")
        guard var metadata = try? JSONDecoder().decode(
            MeetingMetadata.self,
            from: Data(contentsOf: url)
        ) else { return nil }
        metadata.trigger = trigger ?? MeetingMetadata.manualTrigger
        do {
            try RecordingsStore().writeMetadata(metadata, to: directory)
        } catch {
            AppLog.error("meeting", "metadata trigger was not saved: \(error.localizedDescription)")
        }
        return metadata
    }

    /// Only a clean stop reaches here; a partly saved recording is left to the
    /// menu and to the next scan. Synchronous and after `.idle`, so the stop
    /// (and the quit that may be waiting for it) never waits on the queue; a
    /// quit-time stop is not offered at all, since the process is about to
    /// end, and the launch scan compresses it. The new folder goes in before
    /// the scan, which may also find older folders left uncompressed.
    private func offerToQueue(_ directory: URL) {
        guard !isTerminating, let transcripts else { return }
        transcripts.enqueue(directory, transcribe: settings?.meetingAfterStop == .transcribe)
        transcripts.scanLocalFolders()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func playBeepIfEnabled() {
        guard settings?.soundsEnabled == true else { return }
        beepPlayer()
    }

    #if DEBUG
    func tickWatchdogForTesting(now: Date) { watchdog?.tick(now: now) }
    #endif
}
