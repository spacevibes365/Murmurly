import AppKit
import AVFoundation
import Combine
import Foundation
import WebRTCAEC3

protocol MeetingCaptureBackend: Sendable {
    /// Records into `directory`, which the recorder has just made for this
    /// session. A start that fails or is cancelled removes it.
    func start(in directory: URL) async throws -> Date
    func stop() async throws -> [URL]
    /// Seconds of audio already written to the tracks, for the call feed
    /// watcher's clock; nil when the backend does not know. The default
    /// (below) answers nil, so the test doubles that stand in for this
    /// protocol elsewhere keep building without knowing about this card.
    func writtenSeconds() async -> TimeInterval?
    /// A snapshot of the live audio ring, read by the meeting's
    /// `LiveTranscript`; nil when nothing new is there or the backend does
    /// not keep one. The default (below) answers nil, so existing test
    /// doubles keep building without knowing about this card.
    func liveAudio() async -> LiveAudio?
}

extension MeetingCaptureBackend {
    func writtenSeconds() async -> TimeInterval? { nil }
    func liveAudio() async -> LiveAudio? { nil }
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

    /// What the recording's own `LiveTranscript` pipeline needs; nil leaves
    /// the feature off entirely (the quit probe's recorder, and every
    /// existing test that does not pass one).
    struct LiveTranscription {
        let models: ModelDownloader
        var cache: WhisperKitCache = .shared
        /// Loads the VAD; called off the main actor, in a detached task.
        var detector: @Sendable (_ vadModelPath: String) async throws -> LiveTranscript.Detector = {
            try LiveTranscript.Detector.silero(modelPath: $0)
        }
        var makeEchoCanceller: @Sendable () throws -> any LiveTranscript.EchoCancelling = {
            try EchoCanceller(sampleRate: MeetingTranscriber.sampleRate)
        }
        var pollInterval: Duration = .milliseconds(250)
        var temporaryRoot: URL = FileManager.default.temporaryDirectory
    }

    /// One per recording, created right after `state` becomes `.recording`
    /// when `settings.liveTranscript` is on, so the floating panel
    /// (`LiveTranscriptPanel`) reads its lines from this property; nil when the
    /// setting is off. `beginStop`
    /// drops it before `capture.stop()`, never waiting for recognition.
    @Published private(set) var liveTranscriptModel: LiveTranscriptModel?
    private let liveTranscription: LiveTranscription?
    private var liveTranscript: LiveTranscript?
    /// The live transcript's own engine, held from before its first request
    /// until the recording stops, so a meeting job, a Files run, the
    /// dictation's warm-up and Recognize Again in another engine wait for
    /// it instead of loading their model over it.
    private(set) var liveTranscriptEngine: EngineDescriptor?
    #if DEBUG
    /// Fires once, at the very end of every start task — after its
    /// (conditional) `operationTask = nil` — whatever path the task took.
    /// The only visible sign a test has that this particular line was
    /// reached, needed to place `beginTermination()` exactly on the race the
    /// K1 fix (see `beginStart`) closes.
    var startTaskFinishedForTesting: (() -> Void)?
    #endif
    private let capture: any MeetingCaptureBackend
    private let hasMicrophoneAccess: @MainActor @Sendable () -> Bool
    private let permissionPromptDelay: Duration
    private let watchdogSnapshotSource: MeetingWatchdog.SnapshotSource
    private let indicator: RecordingIndicator
    private let beepPlayer: @MainActor @Sendable () -> Void
    private let fileViewer: @MainActor @Sendable (URL) -> Void
    private let createSession: @MainActor () throws -> URL
    private let holderSource: @Sendable () -> Set<String>?
    private let pageSnapshotSource: @Sendable (_ holders: Set<String>, _ pin: MeetingPageReader.Pin?) async -> MeetingPageSnapshot
    private let callFeedInterval: Duration
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
            transcripts?.heldByLiveTranscript = { [weak self] in self?.liveTranscriptEngine }
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
    private var callFeedWatcher: CallFeedWatcher?

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
        createSession: @escaping @MainActor () throws -> URL = { try RecordingsStore().createSession() },
        holderSource: @escaping @Sendable () -> Set<String>? = { MeetingWatchdog.readHolderBundleIDs() },
        pageSnapshotSource: @escaping @Sendable (
            _ holders: Set<String>, _ pin: MeetingPageReader.Pin?
        ) async -> MeetingPageSnapshot = { holders, pin in
            await MeetingPageReader.readLive(holders: holders, pin: pin)
        },
        callFeedInterval: Duration = .milliseconds(300),
        liveTranscription: LiveTranscription? = nil
    ) {
        self.capture = capture
        self.indicator = indicator
        self.hasMicrophoneAccess = hasMicrophoneAccess
        self.permissionPromptDelay = permissionPromptDelay
        self.watchdogSnapshotSource = watchdogSnapshotSource
        self.beepPlayer = beepPlayer
        self.fileViewer = fileViewer
        self.createSession = createSession
        self.holderSource = holderSource
        self.pageSnapshotSource = pageSnapshotSource
        self.callFeedInterval = callFeedInterval
        self.liveTranscription = liveTranscription
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
                // Right after `state` becomes `.recording`: a new instance
                // per recording, so a late result from a stopped meeting's
                // pipeline can never land in the next one's lines (nothing
                // outlives the recorder's own reference to it).
                self.liveTranscriptModel = self.settings?.liveTranscript == true
                    ? LiveTranscriptModel() : nil
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
                if self.settings?.namesFromCallWindow == true {
                    let holderSource = self.holderSource
                    let pageSnapshotSource = self.pageSnapshotSource
                    let feedSource: @Sendable (MeetingPageReader.Pin?) async -> CallFeedWatcher.Read = { pin in
                        let holders = holderSource()
                        // Once pinned, the read never consults holders: an
                        // unreadable snapshot must not stop the pinned page
                        // being read.
                        if holders == nil, pin == nil { return .skipped }
                        let snapshot = await pageSnapshotSource(holders ?? [], pin)
                        return CallFeedWatcher.read(from: snapshot)
                    }
                    let capture = self.capture
                    let watcher = CallFeedWatcher(
                        directory: directory,
                        snapshotSource: feedSource,
                        writtenSeconds: { await capture.writtenSeconds() },
                        isEnabled: { [weak self] in self?.settings?.namesFromCallWindow ?? false },
                        interval: self.callFeedInterval
                    )
                    self.callFeedWatcher = watcher
                    await watcher.start()
                }
                if let model = self.liveTranscriptModel {
                    await self.startLiveTranscript(model: model, in: directory)
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
            // A cancelled task here has already been replaced by `beginStop`
            // (or quit): nilling the property would throw away that running
            // stop, and `finishForTermination`'s own local copy of it would
            // then be the only thing left waiting for the save (K1).
            if !Task.isCancelled { self.operationTask = nil }
            if trigger == nil { AppWindowController.windowDidClose() }
            #if DEBUG
            self.startTaskFinishedForTesting?()
            #endif
        }
        return true
    }

    /// A stop at the time limit is reported like a recording saved with a
    /// warning, in memory only: `metadata.json` describes the tracks, and a
    /// limit says nothing about them.
    private func beginStop(atLimit: Bool = false) {
        guard state == .recording else { return }
        state = .stopping
        liveTranscriptModel = nil
        // Synchronous, before the task: whoever reaches here owns ending the
        // pipeline, and `finish()` never waits for a request or a model load
        // — a hung engine must never hold up the stop.
        let live = takeLiveTranscript()
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
            await live?.finish()
            // Before `capture.stop()` writes `metadata.json`: a watcher
            // still appending while the folder is read or moved would make
            // the copy disagree with the original.
            if let watcher = self.callFeedWatcher {
                self.callFeedWatcher = nil
                await watcher.finish()
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
        // Required here too even though the start sequence never reaches
        // this path with a live transcript already running (it is created
        // only after a start that was not cancelled): a later change to that
        // order must not silently leave one going.
        await takeLiveTranscript()?.finish()
        // Required here too even though the start sequence never reaches
        // this path with a watcher already running (it is started only
        // after a start that was not cancelled): a later change to that
        // order must not silently reopen the feed.
        if let watcher = callFeedWatcher {
            callFeedWatcher = nil
            await watcher.finish()
        }
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

    // MARK: - Live transcript

    /// Takes the recording's `LiveTranscript`, clearing the hold in the same
    /// synchronous step: whoever calls this now owns ending it.
    private func takeLiveTranscript() -> LiveTranscript? {
        defer {
            liveTranscript = nil
            liveTranscriptEngine = nil
        }
        return liveTranscript
    }

    /// Builds the recording's `LiveTranscript` pipeline, reading
    /// `capture.liveAudio()` as its source, beside `CallFeedWatcher`. The
    /// VAD and the personal dictionary are prepared off the main actor; a
    /// stop (or a cancelled start) may finish the recording while that is
    /// still going, through `beginStop`/`stopCancelledStart` cancelling this
    /// very task via `operationTask` — checked again here, on the main
    /// actor, with no `await` in between, right before the pipeline and the
    /// engine hold are kept. A failure here never changes the recording's
    /// own state or folder, and nothing of it reaches disk: chunks are
    /// written to `temporaryRoot` and removed as they are recognized.
    private func startLiveTranscript(model: LiveTranscriptModel, in directory: URL) async {
        guard let config = liveTranscription, let settings else { return }
        let snapshot = settings.snapshot
        guard config.models.missing(snapshot.dictationEngine).isEmpty else {
            model.reportBeforeRecognition(.noModel)
            return
        }
        guard let engine = try? MeetingTranscriber.Engine.forMeeting(snapshot) else { return }
        let dictionary: DictionarySnapshot = {
            var dictionarySnapshot = settings.dictionarySnapshot
            dictionarySnapshot.matchesWordForms = DictionarySnapshot.matchesWordForms(
                engine: snapshot.dictationEngine, language: snapshot.dictationLanguage
            )
            return dictionarySnapshot
        }()
        let vadPath = config.models.root.appendingPathComponent(ModelSource.vad.destination).path
        let makeDetector = config.detector
        let prepared: Result<(LiveTranscript.Detector, DictionaryReplacer?), any Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    let detector = try await makeDetector(vadPath)
                    return .success((detector, dictionary.replacer(for: .meetings)))
                } catch {
                    return .failure(error)
                }
            }.value

        guard !Task.isCancelled, state == .recording, currentSession?.directory == directory,
              liveTranscript == nil else { return }

        switch prepared {
        case let .failure(error):
            AppLog.error("live-transcript", "not started: \(error.localizedDescription)")
            model.reportBeforeRecognition(.stopped(error.localizedDescription))
        case let .success((detector, replacer)):
            let capture = self.capture
            let watcher = callFeedWatcher
            let live = LiveTranscript(
                source: { await capture.liveAudio() },
                detector: detector,
                makeEchoCanceller: config.makeEchoCanceller,
                pollInterval: config.pollInterval,
                recognition: .init(
                    cache: config.cache,
                    engine: engine,
                    modelMissing: { false },
                    dictionaryReplacer: replacer,
                    callFeedEvents: { [weak watcher] in await watcher?.events() ?? [] },
                    model: model,
                    temporaryRoot: config.temporaryRoot
                )
            )
            liveTranscript = live
            liveTranscriptEngine = engine.descriptor
            AppLog.info("live-transcript", "started engine=\(engine.descriptor.engine.rawValue)")
            await live.start()
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

    /// `LiveTranscriptProbe` (`-UITesting -LiveTranscriptProbe`): fakes
    /// `.recording` with a model already carrying made-up lines, without a
    /// capture or an engine, so `LiveTranscriptPanelUITests` has something
    /// to show.
    func publishLiveTranscriptForTesting(state: State, model: LiveTranscriptModel?) {
        self.state = state
        self.liveTranscriptModel = model
    }
    #endif
}
