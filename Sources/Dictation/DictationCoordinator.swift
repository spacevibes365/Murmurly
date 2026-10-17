import AppKit
import AVFoundation
import Combine
import Foundation

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
    static let modelMissingFlash = IndicatorState.dictationFailure(
        message: String(localized: "Download a model: “M” menu → “Download Model…”")
    )

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

    @Published private(set) var state: State = .idle
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
    private var job: DictationJob?
    private var isTerminating = false
    private var quitRequested = false
    private var terminationTask: Task<Bool, Never>?
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
            isRecording: { [weak self] in self?.state == .recording }
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

    private func startRecording() {
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
            // The watchdog, a newer attempt or quit won. Tear down this late
            // success; under quit it may already hold speech worth keeping.
            if isTerminating {
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
        state = .transcribing
        indicator.setBase(.finishingRecording)
        var record = DictationRecord(
            startedAt: recordingStartedAt ?? Date(),
            snapshot: recordingSnapshot,
            target: injectTarget
        )
        record.stoppedAtLimit = atLimit
        let mic = self.mic
        job = DictationJob(
            record: record,
            snapshot: recordingSnapshot,
            dictionary: recordingDictionary,
            target: injectTarget,
            stop: Task { await Self.stopOutcome(of: mic) }
        )
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
        await deliver(
            text,
            to: current.target,
            historySaved: saved != nil,
            stoppedAtLimit: record.stoppedAtLimit,
            entryID: entryID
        )
        guard owns(entryID) else { return }
        finishDictation()
        if saved == nil {
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
    private func deliver(
        _ text: String,
        to target: NSRunningApplication?,
        historySaved: Bool = true,
        stoppedAtLimit: Bool = false,
        entryID: UUID
    ) async {
        // Checked before every side effect that follows an await: once quit
        // accepted or took this dictation, no new paste, fallback or feedback
        // starts, even if that quit was refused meanwhile. A posted chord stays.
        func stillOwned() -> Bool { !isTerminating && owns(entryID) }
        guard stillOwned() else { return }
        var pasted = false
        if let deliveryOverride {
            // Stands in for the paste itself; the feedback below is real.
            await deliveryOverride(text, target)
            pasted = true
        } else if AccessibilityAuthorization.isTrusted,
           let target,
           target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           target.activate() {
            indicator.clearBase()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(20))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    guard stillOwned() else { return }
                    let injected = await TextInjector.inject(text)
                    // Quit took the dictation over meanwhile: the chord stays and
                    // inject restores the clipboard itself, but no late feedback.
                    guard stillOwned() else { return }
                    guard injected else {
                        indicator.showFlash(historySaved ? .injectionFailed : Self.historyNotSavedFlash)
                        return
                    }
                    pasted = true
                    break
                }
            }
        }
        guard stillOwned() else { return }
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
            return
        }
        playClipboardFallbackFeedback()
        if TextInjector.placeLocally(text) {
            indicator.showFlash(stoppedAtLimit
                ? .dictationFailure(message: String(
                    localized: "On the clipboard — press ⌘V; stopped at the 5-minute limit"
                ))
                : .clipboardFallback)
        } else {
            indicator.showFlash(historySaved ? .clipboardFailed : Self.historyNotSavedFlash)
        }
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
        guard settings?.soundOnInsert == true else { return }
        feedbackPlayer(Self.insertionSucceededSoundName)
    }

    private func playClipboardFallbackFeedback() {
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
        dictionary: DictionarySnapshot?
    ) async throws -> Recognized {
        let descriptor = snapshot.dictationDescriptor
        let progress = modelProgress(
            descriptor: descriptor,
            generation: modelGeneration,
            showOverlay: true
        )
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

    // MARK: - Quit

    /// Anything quit still has to save or wait for.
    var hasUnfinishedWork: Bool {
        state != .idle || terminationTask != nil || !pendingSaves.isEmpty
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
    private func finishForTermination() async -> Bool {
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
    var selectedDescriptorForTesting: EngineDescriptor? { selectedDescriptor }
    var hasStartInjectTargetForTesting: Bool { startInjectTarget != nil }
    func playInsertionSucceededFeedbackForTesting() { playInsertionSucceededFeedback() }
    func playClipboardFallbackFeedbackForTesting() { playClipboardFallbackFeedback() }
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
