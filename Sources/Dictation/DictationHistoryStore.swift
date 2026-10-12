import Darwin
import Foundation

struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let source: String
    let at: Date
    let duration: TimeInterval
    let selectedLanguage: String
    let actualLanguage: String
    let engine: String?
    let targetBundleID: String?
    let targetApplicationName: String?
    let audioPath: String
    let text: String
    /// Set only for a dictation cut short by a capture failure; absent keys
    /// keep every ordinary line byte-identical within schema version 1.
    let interrupted: Bool?
    /// Set only when such a fragment could not be recognized, so an engine
    /// error is never shown as silence.
    let recognitionFailed: Bool?
    /// Set only when quit saved the audio without waiting for recognition.
    let recognitionSkipped: Bool?

    init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID,
        source: String = "dictation",
        at: Date,
        duration: TimeInterval,
        selectedLanguage: String,
        actualLanguage: String,
        engine: String? = nil,
        targetBundleID: String?,
        targetApplicationName: String?,
        audioPath: String,
        text: String,
        interrupted: Bool? = nil,
        recognitionFailed: Bool? = nil,
        recognitionSkipped: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.source = source
        self.at = at
        self.duration = duration
        self.selectedLanguage = selectedLanguage
        self.actualLanguage = actualLanguage
        self.engine = engine
        self.targetBundleID = targetBundleID
        self.targetApplicationName = targetApplicationName
        self.audioPath = audioPath
        self.text = text
        self.interrupted = interrupted
        self.recognitionFailed = recognitionFailed
        self.recognitionSkipped = recognitionSkipped
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case source
        case at
        case duration = "duration_seconds"
        case selectedLanguage = "selected_language"
        case actualLanguage = "actual_language"
        case engine
        case targetBundleID = "target_bundle_id"
        case targetApplicationName = "target_app_name"
        case audioPath = "audio_path"
        case text
        case interrupted
        case recognitionFailed = "recognition_failed"
        case recognitionSkipped = "recognition_skipped"
    }
}

extension Notification.Name {
    /// Posted by a `DictationHistoryStore`, as the object, after its index
    /// changed: a line appended, an entry deleted or the history cleared.
    static let dictationHistoryDidChange = Notification.Name("DictationHistoryDidChange")
}

actor DictationHistoryStore {
    static let shared = DictationHistoryStore()
    static let historyFileName = "history.jsonl"

    let root: URL
    let fileManager = FileManager()
    private let beforeHistoryReplace: @Sendable () throws -> Void

    init(
        root: URL = DictationHistoryStore.defaultRoot(),
        beforeHistoryReplace: @escaping @Sendable () throws -> Void = {}
    ) {
        self.root = root.standardizedFileURL
        self.beforeHistoryReplace = beforeHistoryReplace
    }

    nonisolated static func defaultRoot() -> URL {
        #if DEBUG
        // UI-test harness only: `-HistoryProbeRoot <dir>` moves the shared
        // archive into a temporary folder.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-HistoryProbeRoot"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        if TestIsolation.isEnabled {
            return TestIsolation.root.appendingPathComponent("Dictations", isDirectory: true)
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("Murmurly", isDirectory: true)
            .appendingPathComponent("Dictations", isDirectory: true)
    }

    func append(_ entry: DictationHistoryEntry) throws {
        try ensureRootDirectory()
        let handle = try openPrivateFileForAppend(historyURL)
        defer { try? handle.close() }

        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.seek(toOffset: endOffset - 1)
            let finalByte = try handle.read(upToCount: 1)?.first
            if finalByte != Self.newline {
                AppLog.error("dictation-history", "isolating incomplete JSONL tail before append")
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([Self.newline]))
            }
        }

        var line = try makeEncoder().encode(entry)
        line.append(Self.newline)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        notifyChange()
    }

    /// Announces a completed index change of this store. Synchronous, so a
    /// save adds no suspension between its audio and its line.
    func notifyChange() {
        NotificationCenter.default.post(name: .dictationHistoryDidChange, object: self)
    }

    func ensurePrivateAudioDirectory(for date: Date) throws -> (directory: URL, relativePath: String) {
        try ensureRootDirectory()
        let components = Self.utcYearMonth(from: date)
        let yearDirectory = root.appendingPathComponent(components.year, isDirectory: true)
        try ensurePrivateDirectory(yearDirectory)
        let monthDirectory = yearDirectory.appendingPathComponent(components.month, isDirectory: true)
        try ensurePrivateDirectory(monthDirectory)
        return (monthDirectory, "\(components.year)/\(components.month)")
    }

    func createPrivateEmptyFile(at url: URL) throws {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard Darwin.close(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    var historyURL: URL {
        root.appendingPathComponent(Self.historyFileName)
    }

    func ensureRootDirectory() throws {
        if fileManager.fileExists(atPath: root.path) {
            try requireDirectory(root)
            return
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try requireDirectory(directory)
            return
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private func openPrivateFileForAppend(_ url: URL) throws -> FileHandle {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDWR | O_APPEND | O_CREAT,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestampFormatter().string(from: date))
        }
        return encoder
    }

    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = Self.timestampFormatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected fractional UTC ISO8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }

    private nonisolated static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private nonisolated static func utcYearMonth(from date: Date) -> (year: String, month: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        return (
            String(format: "%04d", components.year ?? 0),
            String(format: "%02d", components.month ?? 0)
        )
    }

    func runBeforeHistoryReplace() throws {
        try beforeHistoryReplace()
    }

    nonisolated static let newline: UInt8 = 0x0A
}
