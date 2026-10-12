import Foundation
import Combine
import KeyboardShortcuts

enum DictationEngine: String, CaseIterable, Codable, Sendable {
    case whisper, parakeet
    var title: String { self == .whisper ? "Whisper" : "Parakeet" }
}

/// What happens to a meeting recording once it is saved.
enum MeetingAfterStop: String, CaseIterable, Sendable {
    case nothing, transcribe
}

/// The look of the app's windows, sheets and menus. The recording indicator
/// keeps its own dark look whatever is chosen.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}

struct EngineDescriptor: Hashable, Sendable {
    let engine: DictationEngine
    let modelPath: String
    init(engine: DictationEngine, modelPath: String) {
        self.engine = engine
        self.modelPath = modelPath.hasPrefix("/")
            ? URL(fileURLWithPath: modelPath, isDirectory: true).standardizedFileURL.path : modelPath
    }
}

/// Persisted settings for local transcription. All preferences
/// are non-secret and live in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var dictationLanguage: String { didSet { d.set(dictationLanguage, forKey: K.dictationLanguage) } }
    @Published var dictationEngine: DictationEngine {
        didSet { d.set(dictationEngine.rawValue, forKey: K.dictationEngine) }
    }
    @Published var saveDictationAudio: Bool {
        didSet { d.set(saveDictationAudio, forKey: K.saveDictationAudio) }
    }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: K.launchAtLogin) } }
    @Published var settingsTab: SettingsTab { didSet { d.set(settingsTab.rawValue, forKey: K.settingsTab) } }
    /// Applied by `AppDelegate.followAppearance(of:)`.
    @Published var appearance: AppAppearance { didSet { d.set(appearance.rawValue, forKey: K.appearance) } }
    @Published var hotkeyActivation: HotkeyActivation {
        didSet { d.set(hotkeyActivation.rawValue, forKey: K.hotkeyActivation) }
    }
    @Published var doubleTapModifier: TapModifier {
        didSet { d.set(doubleTapModifier.rawValue, forKey: K.doubleTapModifier) }
    }
    @Published var doubleTapThresholdMS: Int {
        didSet {
            let clamped = Self.clampedDoubleTapThreshold(doubleTapThresholdMS)
            guard clamped == doubleTapThresholdMS else {
                doubleTapThresholdMS = clamped
                return
            }
            d.set(doubleTapThresholdMS, forKey: K.doubleTapThresholdMS)
        }
    }
    @Published var soundOnRecordingStart: Bool {
        didSet { d.set(soundOnRecordingStart, forKey: K.soundOnRecordingStart) }
    }
    @Published var soundOnInsert: Bool { didSet { d.set(soundOnInsert, forKey: K.soundOnInsert) } }
    @Published var overlayEnabled: Bool { didSet { d.set(overlayEnabled, forKey: K.overlayEnabled) } }
    @Published var overlayPlacement: OverlayPlacement? {
        didSet { Self.store(overlayPlacement, in: d, forKey: K.overlayPlacement) }
    }
    @Published var autoRecordMeetings: Bool {
        didSet { d.set(autoRecordMeetings, forKey: K.autoRecordMeetings) }
    }
    @Published var meetingExcludedBundleIDs: Set<String> {
        didSet { d.set(meetingExcludedBundleIDs.sorted(), forKey: K.meetingExcludedBundleIDs) }
    }
    @Published var meetingAfterStop: MeetingAfterStop {
        didSet { d.set(meetingAfterStop.rawValue, forKey: K.meetingAfterStop) }
    }
    @Published var systemAudioCheck: SystemAudioCheck? {
        didSet { Self.store(systemAudioCheck, in: d, forKey: K.systemAudioCheck) }
    }
    /// Where finished meetings move; nil keeps them in the local `Meetings`.
    /// Kept as chosen even while its disk is away: the meetings wait.
    @Published var meetingsFolderPath: String? {
        didSet {
            Self.store(path: meetingsFolderPath, in: d, forKey: K.meetingsFolder)
            meetingsFolderAttempt += 1
        }
    }
    /// Bumped by every choice of the meetings folder and by every change of
    /// it, a reset included: a choice checked off the main actor is applied
    /// only while it is still the latest, so a slow check of an earlier folder
    /// never undoes a later decision.
    private var meetingsFolderAttempt = 0
    /// Where each new transcript is copied once; nil makes no copy.
    @Published var transcriptsFolderPath: String? {
        didSet {
            Self.store(path: transcriptsFolderPath, in: d, forKey: K.transcriptsFolder)
            transcriptsFolderAttempt += 1
        }
    }
    /// The same for the transcripts folder: a late check never undoes
    /// "Don’t Copy" or a later choice.
    private var transcriptsFolderAttempt = 0

    private let d: UserDefaults

    private enum K {
        static let dictationLanguage = "dictation.language"
        static let dictationEngine = "dictation.engine"
        static let saveDictationAudio = "dictation.saveAudio"
        static let launchAtLogin = "app.launchAtLogin"
        static let settingsTab = "ui.settingsTab"
        static let appearance = "ui.appearance"
        static let hotkeyActivation = "dictation.hotkey.activation"
        static let doubleTapModifier = "dictation.hotkey.doubleModifier"
        static let doubleTapThresholdMS = "dictation.hotkey.doubleThresholdMS"
        static let soundOnRecordingStart = "dictation.sound.start"
        static let soundOnInsert = "dictation.sound.inserted"
        static let overlayEnabled = "overlay.enabled"
        static let overlayPlacement = "overlay.placement"
        static let autoRecordMeetings = "meeting.autoRecord"
        static let meetingExcludedBundleIDs = "meeting.excludedBundleIDs"
        static let meetingAfterStop = "meeting.afterStop"
        static let systemAudioCheck = "permissions.systemAudioCheck"
        static let meetingsFolder = "meeting.storageFolder"
        static let transcriptsFolder = "meeting.transcriptCopyFolder"
    }

    /// Models live in one folder of the app's own, where the downloader puts
    /// them; there is nothing to choose. `nonisolated` — a constant path
    /// carries no state, and the stage gate reads it from a nonisolated context.
    nonisolated static let defaultWhisperModel = ModelDownloader.defaultRoot
        .appendingPathComponent(ModelSource.whisper.destination, isDirectory: true).path
    nonisolated static let defaultParakeetModel = ModelDownloader.defaultRoot
        .appendingPathComponent(ModelSource.parakeet.destination, isDirectory: true).path

    nonisolated static func modelPath(for engine: DictationEngine) -> String {
        engine == .whisper ? defaultWhisperModel : defaultParakeetModel
    }

    init(defaults: UserDefaults = TestIsolation.settingsDefaults()) {
        d = defaults
        // Kept as stored, whatever it is: an engine that does not know the
        // code treats it as "auto" at the moment of use.
        dictationLanguage = d.string(forKey: K.dictationLanguage) ?? "auto"
        // Parakeet for someone new: a third of Whisper's download, and
        // Whisper is needed only for languages beyond Parakeet's 25.
        dictationEngine = d.string(forKey: K.dictationEngine)
            .flatMap(DictationEngine.init(rawValue:)) ?? .parakeet
        saveDictationAudio = d.object(forKey: K.saveDictationAudio) as? Bool ?? false
        launchAtLogin = d.object(forKey: K.launchAtLogin) as? Bool ?? true
        settingsTab = d.string(forKey: K.settingsTab).flatMap(SettingsTab.init(rawValue:))
            ?? .dictation
        appearance = d.string(forKey: K.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        hotkeyActivation = d.string(forKey: K.hotkeyActivation)
            .flatMap(HotkeyActivation.init(rawValue:)) ?? .press
        doubleTapModifier = d.string(forKey: K.doubleTapModifier)
            .flatMap(TapModifier.init(rawValue:)) ?? .rightCommand
        doubleTapThresholdMS = Self.clampedDoubleTapThreshold(
            d.object(forKey: K.doubleTapThresholdMS) as? Int ?? 250
        )
        soundOnRecordingStart = d.object(forKey: K.soundOnRecordingStart) as? Bool ?? true
        soundOnInsert = d.object(forKey: K.soundOnInsert) as? Bool ?? true
        overlayEnabled = d.object(forKey: K.overlayEnabled) as? Bool ?? true
        overlayPlacement = Self.load(OverlayPlacement.self, from: d, forKey: K.overlayPlacement)
        autoRecordMeetings = d.object(forKey: K.autoRecordMeetings) as? Bool ?? true
        meetingExcludedBundleIDs = Set(d.stringArray(forKey: K.meetingExcludedBundleIDs) ?? [])
        // Transcribe by default: a call recorded on its own is easily forgotten,
        // and a transcript nobody asked for costs only a file.
        meetingAfterStop = d.string(forKey: K.meetingAfterStop)
            .flatMap(MeetingAfterStop.init(rawValue:)) ?? .transcribe
        systemAudioCheck = Self.load(SystemAudioCheck.self, from: d, forKey: K.systemAudioCheck)
        meetingsFolderPath = d.string(forKey: K.meetingsFolder)
        transcriptsFolderPath = d.string(forKey: K.transcriptsFolder)
    }

    /// What came of choosing the meetings or the transcripts folder.
    enum FolderChoice: Equatable {
        case applied
        /// The local root or a folder in it: moving meetings there would only
        /// shuffle them around this Mac, and into the root itself remove them.
        case insideLocalRoot
        /// The dictation archive or a folder in it: the archive's Clear All
        /// would then be one click from the meetings.
        case insideDictationArchive
        /// Another choice or a reset came while this one was checked.
        case superseded
    }

    /// Sets the meetings folder the user picked, unless it is the local
    /// recording root or below it. Links are resolved off the main actor: the
    /// picked folder may be on a network volume, and a dead one hangs.
    func chooseMeetingsFolder(
        _ url: URL,
        localRoot: URL = RecordingsStore.meetingsRoot(),
        dictationsRoot: URL = DictationHistoryStore.defaultRoot(),
        resolve: @escaping @Sendable (URL) async -> String = SettingsStore.resolvedPath
    ) async -> FolderChoice {
        meetingsFolderAttempt += 1
        let attempt = meetingsFolderAttempt
        let picked = await resolve(url)
        let local = await resolve(localRoot)
        let dictations = await resolve(dictationsRoot)
        guard attempt == meetingsFolderAttempt else { return .superseded }
        guard !Self.path(picked, isIn: local) else { return .insideLocalRoot }
        guard !Self.path(picked, isIn: dictations) else { return .insideDictationArchive }
        meetingsFolderPath = url.path
        return .applied
    }

    /// Sets the transcripts folder unless it is the dictation archive or in
    /// it, and unless "Don’t Copy" or another choice came while it was checked.
    func chooseTranscriptsFolder(
        _ url: URL,
        dictationsRoot: URL = DictationHistoryStore.defaultRoot(),
        resolve: @escaping @Sendable (URL) async -> String = SettingsStore.resolvedPath
    ) async -> FolderChoice {
        transcriptsFolderAttempt += 1
        let attempt = transcriptsFolderAttempt
        let picked = await resolve(url)
        let dictations = await resolve(dictationsRoot)
        guard attempt == transcriptsFolderAttempt else { return .superseded }
        guard !Self.path(picked, isIn: dictations) else { return .insideDictationArchive }
        transcriptsFolderPath = url.path
        return .applied
    }

    /// Links resolved off the main actor: a folder may be on a network volume,
    /// and a dead one hangs.
    nonisolated static func resolvedPath(_ url: URL) async -> String {
        await Task.detached(priority: .userInitiated) { url.resolvingSymlinksInPath().path }.value
    }

    private nonisolated static func path(_ path: String, isIn folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    var meetingDestinations: MeetingTranscriptionQueue.Destinations {
        .init(
            meetings: meetingsFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
            transcripts: transcriptsFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    /// The parent control stores no third preference: turning it on selects both
    /// concrete cues, while either selected cue keeps the parent visibly on.
    var soundsEnabled: Bool {
        get { soundOnRecordingStart || soundOnInsert }
        set {
            soundOnRecordingStart = newValue
            soundOnInsert = newValue
        }
    }

    /// What the language pickers show: the setting, or "auto" while the
    /// selected engine does not know it. Choosing writes the setting;
    /// switching engines never does.
    var pickedLanguage: String {
        get { dictationEngine.language(for: dictationLanguage) ?? "auto" }
        set { dictationLanguage = newValue }
    }

    var dictationShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description
    }

    var meetingShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .meeting)?.description
    }

    /// Called once during service activation, never by window rendering.
    /// Consume the missing preference before opening the first-run window.
    /// A test process writes nothing: the stage gate runs on the live domain,
    /// and the key would hide the first-run window from the installed copy.
    func prepareGettingStarted(isTestProcess: Bool = TestIsolation.isTestProcess) -> Bool {
        guard !isTestProcess, d.object(forKey: K.autoRecordMeetings) == nil else { return false }
        d.set(autoRecordMeetings, forKey: K.autoRecordMeetings)
        return true
    }

    /// Immutable copy safe to hand to background work.
    var snapshot: SettingsSnapshot {
        SettingsSnapshot(dictationLanguage: dictationLanguage,
                         dictationEngine: dictationEngine,
                         saveDictationAudio: saveDictationAudio)
    }

    private static func clampedDoubleTapThreshold(_ value: Int) -> Int {
        min(max(value, 150), 500)
    }

    private static func load<Value: Decodable>(
        _ type: Value.Type,
        from defaults: UserDefaults,
        forKey key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store(path: String?, in defaults: UserDefaults, forKey key: String) {
        if let path { defaults.set(path, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func store<Value: Encodable>(
        _ value: Value?,
        in defaults: UserDefaults,
        forKey key: String
    ) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

struct SettingsSnapshot: Sendable, Equatable {
    var dictationLanguage: String
    var dictationEngine: DictationEngine = .whisper
    var whisperModelPath: String = SettingsStore.defaultWhisperModel
    var parakeetModelPath: String = SettingsStore.defaultParakeetModel
    var saveDictationAudio: Bool = false

    var dictationDescriptor: EngineDescriptor {
        EngineDescriptor(
            engine: dictationEngine,
            modelPath: dictationEngine == .whisper ? whisperModelPath : parakeetModelPath
        )
    }
}
