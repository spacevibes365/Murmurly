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

/// How long a meeting's audio is kept after its first full transcription;
/// `keep` keeps it. The days are the stored value.
enum MeetingAudioRetention: Int, CaseIterable, Sendable {
    case keep = 0, week = 7, month = 30, quarter = 90
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
            retentionGeneration += 1
        }
    }
    /// Written only once the user agreed to what it deletes now.
    @Published var meetingAudioRetention: MeetingAudioRetention {
        didSet {
            d.set(meetingAudioRetention.rawValue, forKey: K.meetingAudioRetention)
            retentionGeneration += 1
        }
    }
    /// Bumped by every change of the audio rule and of the meetings folder:
    /// a deletion of old audio asked for under another is not carried out.
    /// In memory only.
    @Published private(set) var retentionGeneration = 0
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
    /// The personal dictionary, changed only by `saveDictionary(_:)`.
    @Published private(set) var dictionary: [DictionaryEntry]
    /// The stored dictionary is there but could not be read: damaged, or
    /// written by a newer version of the app after this one was reinstalled.
    /// Its data stays untouched, jobs run without replacements, and editing
    /// waits for an explicit `clearDictionary()`.
    @Published private(set) var dictionaryUnreadable: Bool
    @Published var dictionaryInDictation: Bool {
        didSet { d.set(dictionaryInDictation, forKey: K.dictionaryInDictation) }
    }
    @Published var dictionaryInMeetings: Bool {
        didSet { d.set(dictionaryInMeetings, forKey: K.dictionaryInMeetings) }
    }
    @Published var dictionaryInFiles: Bool { didSet { d.set(dictionaryInFiles, forKey: K.dictionaryInFiles) } }

    private let d: UserDefaults
    private let encodeDictionary: ([DictionaryEntry]) throws -> Data

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
        static let meetingAudioRetention = "meeting.audioRetentionDays"
        static let transcriptsFolder = "meeting.transcriptCopyFolder"
        static let dictionary = "dictionary.entries"
        static let dictionaryInDictation = "dictionary.inDictation"
        static let dictionaryInMeetings = "dictionary.inMeetings"
        static let dictionaryInFiles = "dictionary.inFiles"
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

    init(
        defaults: UserDefaults = TestIsolation.settingsDefaults(),
        encodeDictionary: @escaping ([DictionaryEntry]) throws -> Data = SettingsStore.encodedDictionary
    ) {
        d = defaults
        self.encodeDictionary = encodeDictionary
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
        meetingAudioRetention = MeetingAudioRetention(rawValue: d.integer(forKey: K.meetingAudioRetention)) ?? .keep
        transcriptsFolderPath = d.string(forKey: K.transcriptsFolder)
        // Read only: nothing seeds a dictionary, or the stage gate and test
        // copies, which run on the live domain, would leave entries in it.
        let stored = Self.storedDictionary(in: d)
        dictionary = stored ?? []
        dictionaryUnreadable = stored == nil
        dictionaryInDictation = d.object(forKey: K.dictionaryInDictation) as? Bool ?? true
        dictionaryInMeetings = d.object(forKey: K.dictionaryInMeetings) as? Bool ?? true
        dictionaryInFiles = d.object(forKey: K.dictionaryInFiles) as? Bool ?? true
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

    /// The dictionary as the next job will use it. Entries and switches only:
    /// the variants' word forms are worked out by the job, off the main actor.
    var dictionarySnapshot: DictionarySnapshot {
        DictionarySnapshot(
            entries: dictionary,
            uses: Set([
                dictionaryInDictation ? .dictation : nil,
                dictionaryInMeetings ? .meetings : nil,
                dictionaryInFiles ? .files : nil,
            ].compactMap { $0 }),
            matchesWordForms: DictionarySnapshot.matchesWordForms(engine: dictationEngine, language: dictationLanguage)
        )
    }

    enum DictionaryFailure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            String(localized: "The saved dictionary can’t be read. Clear it to start a new one.")
        }
    }

    /// Stores the whole dictionary and publishes it only once its data is
    /// set: a failure leaves the stored data, the published entries and the
    /// next job's snapshot as they were. Not `store(_:in:forKey:)`, which
    /// removes the key when encoding fails.
    func saveDictionary(_ entries: [DictionaryEntry]) throws {
        guard !dictionaryUnreadable else { throw DictionaryFailure.unreadable }
        d.set(try encodeDictionary(entries), forKey: K.dictionary)
        dictionary = entries
    }

    /// The one way out of an unreadable dictionary; its entries are lost.
    func clearDictionary() {
        d.removeObject(forKey: K.dictionary)
        dictionary = []
        dictionaryUnreadable = false
    }

    /// Writes data to a file; a UI test stands in for it to hold the write.
    typealias FileWrite = @Sendable (Data, URL) async throws -> Void

    nonisolated static let writeWhole: FileWrite = { data, url in try data.write(to: url, options: .atomic) }

    /// Writes the dictionary to a file the user chose: the very bytes the
    /// settings hold, written whole and off the main actor, as the folder may
    /// be on a network volume. Returns the number of entries written.
    func exportDictionary(to url: URL, write: @escaping FileWrite = SettingsStore.writeWhole) async throws -> Int {
        guard !dictionaryUnreadable else { throw DictionaryFailure.unreadable }
        let entries = dictionary
        let data = try encodeDictionary(entries)
        try await Task.detached(priority: .userInitiated) { try await write(data, url) }.value
        AppLog.info("settings", "dictionary exported: entries=\(entries.count)")
        return entries.count
    }

    /// What an import did, in numbers: the log never gets the words.
    enum DictionaryImport: Equatable {
        /// `turnedOff` of the added are switched off, as one of yours has
        /// their spelling; `matched` were already there as they are; `kept`
        /// are entries of yours changed since the file was made, kept as you
        /// have them.
        case added(Int, turnedOff: Int, matched: Int, kept: Int)
        case replaced(Int)

        var summary: String {
            switch self {
            case let .added(added, turnedOff, matched, kept):
                var parts = [String(localized: "Added: \(added).")]
                if turnedOff > 0 {
                    parts.append(String(localized: "Switched off, as you already have their spelling: \(turnedOff)."))
                }
                if matched > 0 { parts.append(String(localized: "Already in your dictionary: \(matched).")) }
                if kept > 0 { parts.append(String(localized: "Kept as you changed them: \(kept).")) }
                return parts.joined(separator: " ")
            case .replaced(let count):
                return String(localized: "Dictionary replaced. Entries: \(count).")
            }
        }
    }

    /// Adds entries from `importedDictionary` to the dictionary as it is at
    /// this moment, or replaces it with them, and saves once: all or nothing.
    /// Synchronous, so no edit lands between the merge and the save.
    func importDictionary(_ entries: [DictionaryEntry], replacing: Bool) throws -> DictionaryImport {
        if replacing {
            try saveDictionary(entries)
            AppLog.info("settings", "dictionary replaced from a file: entries=\(entries.count)")
            return .replaced(entries.count)
        }
        let yours = Dictionary(dictionary.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = dictionary
        var taken = DictionaryEntry.spellings(of: merged)
        var added = 0, turnedOff = 0, matched = 0, kept = 0
        for var entry in entries {
            // The id says where an entry came from, not which copy is newer:
            // an old file never undoes a later edit or switch.
            if let mine = yours[entry.id] {
                if mine == entry { matched += 1 } else { kept += 1 }
                continue
            }
            // The file passed as a whole, so only a spelling of yours, or of
            // one switched on before it, can stand in its way.
            if entry.problem(besides: taken) != nil {
                entry.isEnabled = false
                turnedOff += 1
            }
            taken.formUnion(DictionaryEntry.spellings(of: [entry]))
            merged.append(entry)
            added += 1
        }
        try saveDictionary(merged)
        AppLog.info("settings", "dictionary imported: added=\(added) turnedOff=\(turnedOff) matched=\(matched) kept=\(kept)")
        return .added(added, turnedOff: turnedOff, matched: matched, kept: kept)
    }

    /// Why data is not a dictionary to import, entries counted from 1.
    enum DictionaryFileFailure: Error, Equatable {
        case unreadableFile(String)
        case notADictionary
        case version(Int)
        case noEntries
        case unreadableEntry(Int)
        case sameID(Int, Int)
        case entry(Int, DictionaryEntry.Problem)

        var message: String {
            switch self {
            case .unreadableFile(let reason):
                return reason
            case .notADictionary:
                return String(localized: "This file is not a Murmurly dictionary.")
            case .version(let version):
                return String(localized: "This dictionary is in a format this version of Murmurly can’t read (version \(version)).")
            case .noEntries:
                return String(localized: "The file has no entries.")
            case .unreadableEntry(let number):
                return String(localized: "Entry \(number) can’t be read.")
            case let .sameID(first, second):
                return String(localized: "Entries \(first) and \(second) have the same id.")
            case let .entry(number, problem):
                return String(localized: "Entry \(number): \(problem.message)")
            }
        }

        /// Without the words.
        fileprivate var logDescription: String {
            switch self {
            case .unreadableFile: "the file can’t be read"
            case .notADictionary: "not a dictionary"
            case .version(let version): "version \(version)"
            case .noEntries: "no entries"
            case .unreadableEntry(let number): "entry \(number) can’t be read"
            case let .sameID(first, second): "entries \(first) and \(second) share an id"
            case .entry(let number, _): "entry \(number) refused"
            }
        }
    }

    /// Reads a file; a UI test stands in for it to hold the answer.
    typealias FileRead = @Sendable (URL) async throws -> Data

    nonisolated static let readWhole: FileRead = { url in try Data(contentsOf: url) }

    /// A dictionary file as an import takes it, read off the main actor.
    nonisolated static func importedDictionary(
        at url: URL,
        read: @escaping FileRead = SettingsStore.readWhole
    ) async -> Result<[DictionaryEntry], DictionaryFileFailure> {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[DictionaryEntry], DictionaryFileFailure> in
            do {
                return SettingsStore.importedDictionary(from: try await read(url))
            } catch {
                return .failure(.unreadableFile(error.localizedDescription))
            }
        }.value
        if case .failure(let failure) = result {
            AppLog.error("settings", "dictionary import refused: \(failure.logDescription)")
        }
        return result
    }

    /// The entries, or the first reason to refuse the file whole: an import
    /// takes only a dictionary this app could have saved itself, each id once
    /// and every entry as the sheet would take it, switched-off ones included.
    nonisolated static func importedDictionary(from data: Data) -> Result<[DictionaryEntry], DictionaryFileFailure> {
        let entries: [DictionaryEntry]
        switch decodedDictionary(data) {
        case .failure(let failure): return .failure(failure)
        case .success(let decoded): entries = decoded
        }
        guard !entries.isEmpty else { return .failure(.noEntries) }
        var seen: [UUID: Int] = [:]
        var taken = Set<String>()
        for (index, entry) in entries.enumerated() {
            if let first = seen.updateValue(index, forKey: entry.id) { return .failure(.sameID(first + 1, index + 1)) }
            if let problem = entry.problem(besides: taken) { return .failure(.entry(index + 1, problem)) }
            taken.formUnion(DictionaryEntry.spellings(of: [entry]))
        }
        return .success(entries)
    }

    /// A version plus the entries, in the settings and in an exported file
    /// alike; a later version may only add optional fields.
    private struct DictionaryDocument: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var entries: [DictionaryEntry]
    }

    /// One encoding for the settings and the file: indented and with its keys
    /// in a fixed order, so the file reads and edits by hand and compares
    /// byte for byte.
    nonisolated static func encodedDictionary(_ entries: [DictionaryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(DictionaryDocument(entries: entries))
    }

    /// The entries of this version's document, or why the data is not one.
    /// The version is read first: a newer document may be built otherwise and
    /// is not damaged. A broken entry is found by its index in the path.
    private nonisolated static func decodedDictionary(_ data: Data) -> Result<[DictionaryEntry], DictionaryFileFailure> {
        struct Version: Decodable { var version: Int }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(Version.self, from: data).version else {
            return .failure(.notADictionary)
        }
        guard version == DictionaryDocument.currentVersion else { return .failure(.version(version)) }
        do {
            return .success(try decoder.decode(DictionaryDocument.self, from: data).entries)
        } catch {
            let path: [any CodingKey]
            switch error as? DecodingError {
            case let .typeMismatch(_, context), let .valueNotFound(_, context),
                 let .keyNotFound(_, context), let .dataCorrupted(context):
                path = context.codingPath
            default:
                path = []
            }
            return .failure(path.lazy.compactMap(\.intValue).first.map { .unreadableEntry($0 + 1) } ?? .notADictionary)
        }
    }

    /// Empty when there is no key; nil when there is one that does not read
    /// as this version's document, which is never mistaken for no dictionary.
    private static func storedDictionary(in defaults: UserDefaults) -> [DictionaryEntry]? {
        guard let stored = defaults.object(forKey: K.dictionary) else { return [] }
        guard let data = stored as? Data, case .success(let entries) = decodedDictionary(data) else {
            AppLog.error("settings", "the saved dictionary can’t be read; it is kept as it is")
            return nil
        }
        return entries
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

    /// An engine and a language picked for one job, over the settings and
    /// never written into them: they stay the dictation's.
    struct Choice: Sendable, Hashable {
        let engine: DictationEngine
        /// A code or "auto". A code the engine does not know is kept as
        /// "auto", so two choices that ask the engine the same are one.
        let language: String

        init(engine: DictationEngine, language: String) {
            self.engine = engine
            self.language = engine.language(for: language) ?? "auto"
        }
    }

    /// The settings as one job sees them; without a choice, as they are.
    func applying(_ choice: Choice?) -> SettingsSnapshot {
        guard let choice else { return self }
        var snapshot = self
        snapshot.dictationEngine = choice.engine
        snapshot.dictationLanguage = choice.language
        return snapshot
    }

    var dictationDescriptor: EngineDescriptor {
        EngineDescriptor(
            engine: dictationEngine,
            modelPath: dictationEngine == .whisper ? whisperModelPath : parakeetModelPath
        )
    }
}
