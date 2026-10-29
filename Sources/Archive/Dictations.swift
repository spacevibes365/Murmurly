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
    /// The recognized text before the personal dictionary changed it; set
    /// only when it did, so a wrong entry never costs the original words and
    /// a line without replacements stays byte for byte what it was.
    let rawText: String?
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
        rawText: String? = nil,
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
        self.rawText = rawText
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
        case rawText = "raw_text"
        case interrupted
        case recognitionFailed = "recognition_failed"
        case recognitionSkipped = "recognition_skipped"
    }
}

extension DictationHistoryEntry {
    static let historyFileName = "history.jsonl"
    static let newline: UInt8 = 0x0A

    /// Fractional-second, UTC ISO 8601: `DictationHistoryStore.makeEncoder`/
    /// `makeDecoder` (`DictationHistoryStore.swift`) use this one formatter,
    /// so a line is always read back the way it was written.
    static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestampFormatter().string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
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

    /// The window's search rule, prepared once: trimmed of spaces and line
    /// breaks, nil when that leaves nothing (no filter). Case is folded;
    /// ё/е are NOT folded, unlike a meeting's search.
    static func searchNeedle(_ query: String?) -> String? {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The one rule for a match, shared with the quick, pre-decode check on
    /// a raw JSONL line (`Archive.mayMatch`): case folded, ё/е kept apart.
    static func contains(_ haystack: String, needle: String) -> Bool {
        haystack.localizedCaseInsensitiveContains(needle)
    }

    func matches(needle: String) -> Bool {
        Self.contains(text, needle: needle)
    }
}

/// Reads JSONL lines backward from `upperBound`, one block at a time.
struct ReverseJSONLReader {
    private let handle: FileHandle
    private let blockSize: UInt64
    private var unreadUpperBound: UInt64
    private var buffer = Data()
    private var bufferStart: UInt64
    private var shouldConsumeTrailingDelimiter = true

    init(handle: FileHandle, upperBound: UInt64, blockSize: Int) {
        self.handle = handle
        self.blockSize = UInt64(blockSize)
        self.unreadUpperBound = upperBound
        self.bufferStart = upperBound
    }

    mutating func next() throws -> (data: Data, startOffset: UInt64)? {
        while true {
            if shouldConsumeTrailingDelimiter, !buffer.isEmpty {
                shouldConsumeTrailingDelimiter = false
                if buffer.last == DictationHistoryEntry.newline {
                    buffer.removeLast()
                }
            }

            if let delimiter = buffer.lastIndex(of: DictationHistoryEntry.newline) {
                let lineStart = buffer.index(after: delimiter)
                let line = Data(buffer[lineStart...])
                let absoluteStart = bufferStart + UInt64(lineStart)
                buffer.removeSubrange(delimiter..<buffer.endIndex)
                return (line, absoluteStart)
            }

            if unreadUpperBound == 0 {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return (line, 0)
            }

            let count = min(blockSize, unreadUpperBound)
            let start = unreadUpperBound - count
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(count)) ?? Data()
            var combined = chunk
            combined.append(buffer)
            buffer = combined
            bufferStart = start
            unreadUpperBound = start
        }
    }
}

extension DictationHistoryEntry {
    /// Reads JSONL lines backward from `upperBound`, decoding each with
    /// `decoder`: lines `include` rejects are skipped, not counted; a line
    /// that cannot be decoded calls `onMalformed` and is skipped too. Stops
    /// once `limit` matching entries are collected or the start of the file
    /// is reached — whichever comes first — so `DictationHistoryStore.page`
    /// and the helper's period filter share one scan.
    static func scanBackward(
        handle: FileHandle,
        upperBound: UInt64,
        limit: Int,
        blockSize: Int = 64 * 1024,
        decoder: JSONDecoder,
        prefilter: ((Data) -> Bool)? = nil,
        include: (DictationHistoryEntry) -> Bool,
        onMalformed: () -> Void
    ) throws -> (entries: [DictationHistoryEntry], nextCursor: UInt64?) {
        var reader = ReverseJSONLReader(handle: handle, upperBound: upperBound, blockSize: blockSize)
        var entries: [DictationHistoryEntry] = []
        while let rawLine = try reader.next() {
            try Task.checkCancellation()
            guard !rawLine.data.isEmpty else { continue }
            // A line the quick check rules out is skipped before decoding,
            // without counting towards `onMalformed`: it was never a
            // candidate to begin with.
            if let prefilter, !prefilter(rawLine.data) { continue }
            let entry: DictationHistoryEntry
            do {
                entry = try decoder.decode(DictationHistoryEntry.self, from: rawLine.data)
            } catch {
                onMalformed()
                continue
            }
            guard include(entry) else { continue }
            entries.append(entry)
            if entries.count == limit {
                let nextCursor = rawLine.startOffset > 0 ? rawLine.startOffset : nil
                return (entries, nextCursor)
            }
        }
        return (entries, nil)
    }
}

extension Archive {
    /// `needle` contains a character JSON's own escaping (of `"`, `\`, `/`
    /// and control characters below U+0020) could turn into something else
    /// on the way from the decoded text to the raw line's own bytes, or vice
    /// versa: the quick check is unsafe for it and must be skipped entirely.
    private static func rawCompareIsUnsafe(for needle: String) -> Bool {
        needle.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0 == "/" || $0.value < 0x20 }
    }

    /// Whether a raw JSONL line's own bytes could hold a match for `needle`
    /// once decoded, without decoding it: `true` whenever it is unsure (not
    /// valid UTF-8, or carrying a `\u` escape, which could encode a
    /// character this literal compare would otherwise miss), so a line that
    /// might actually match is never skipped.
    static func mayMatch(rawLine: Data, needle: String) -> Bool {
        guard let text = String(data: rawLine, encoding: .utf8) else { return true }
        guard !text.contains("\\u") else { return true }
        return DictationHistoryEntry.contains(text, needle: needle)
    }

    /// Whether the quick, pre-decode check is safe to use at all for
    /// `needle`: both `Archive.quickCheckApplies` (the shared cluster-edge
    /// rule) and the dictation-specific escaping rule above must allow it.
    static func dictationQuickCheckApplies(to needle: String) -> Bool {
        quickCheckApplies(to: needle) && !rawCompareIsUnsafe(for: needle)
    }
}

extension Archive {
    /// `dictationsRead(...)`'s result: the matching entries, and how many
    /// lines among those read were malformed JSON and skipped — never
    /// silently dropped (the helper's `skippedLines`), but never their
    /// content either.
    struct DictationsRead: Sendable, Equatable {
        let entries: [DictationHistoryEntry]
        let malformedLines: Int
    }

    /// Dictations from `root`'s `history.jsonl`, newest first: the window's
    /// search rule, and, when given, a period on `at` — `from` inclusive,
    /// `to` exclusive. The period is a filter, exactly like the search, never
    /// a cut of the page: an entry outside it is skipped, not a stopping
    /// point, as a line's own `at` is not guaranteed to be in the file's
    /// order (Recognize Again rewrites a line in place with its old `at`; so
    /// does a clock turned back). No file is `[]`; a file that cannot be
    /// read, or is a link in `refuse`, throws — the helper turns that into
    /// its `readError` code, never an empty list standing in for a refusal.
    static func dictationsRead(
        root: URL,
        limit: Int,
        matching query: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        links: Links
    ) throws -> DictationsRead {
        guard limit > 0 else { return DictationsRead(entries: [], malformedLines: 0) }
        let url = root.appendingPathComponent(DictationHistoryEntry.historyFileName)
        let handle: FileHandle
        switch links {
        case .follow:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return DictationsRead(entries: [], malformedLines: 0)
            }
            handle = try FileHandle(forReadingFrom: url)
        case .refuse:
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR { return DictationsRead(entries: [], malformedLines: 0) }
                throw ReadError.unreadable(url.path, String(cString: strerror(code)))
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw ReadError.link(url.path) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw ReadError.notAFile(url.path) }
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw ReadError.unreadable(url.path, String(cString: strerror(errno))) }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else { return DictationsRead(entries: [], malformedLines: 0) }
        let needle = DictationHistoryEntry.searchNeedle(query)
        var malformed = 0
        var prefilter: ((Data) -> Bool)?
        if let needle, dictationQuickCheckApplies(to: needle) {
            prefilter = { data in mayMatch(rawLine: data, needle: needle) }
        }
        let (entries, _) = try DictationHistoryEntry.scanBackward(
            handle: handle,
            upperBound: fileSize,
            limit: limit,
            decoder: DictationHistoryEntry.makeDecoder(),
            prefilter: prefilter,
            include: { entry in
                if let needle, !entry.matches(needle: needle) { return false }
                if let from, entry.at < from { return false }
                if let to, entry.at >= to { return false }
                return true
            },
            onMalformed: { malformed += 1 }
        )
        return DictationsRead(entries: entries, malformedLines: malformed)
    }

    /// `dictationsRead(...).entries`, for callers that do not need the
    /// malformed-line count (the window's own readers, and the existing
    /// tests of this layer).
    static func dictations(
        root: URL,
        limit: Int,
        matching query: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        links: Links
    ) throws -> [DictationHistoryEntry] {
        try dictationsRead(root: root, limit: limit, matching: query, from: from, to: to, links: links).entries
    }
}
