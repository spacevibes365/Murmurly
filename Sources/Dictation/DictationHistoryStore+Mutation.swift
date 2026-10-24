import Darwin
import Foundation

private enum HistoryRewriteMode {
    case removing(Set<UUID>)
    case clearingAll
    case replacing(id: UUID, replacement: RecognitionReplacement)
}

/// A line's new recognition: only these fields change (see
/// `replaceRecognition`), the rest of the entry and every other line stay
/// byte-for-byte.
struct RecognitionReplacement: Sendable {
    let text: String
    let rawText: String?
    let actualLanguage: String
    let engine: String?

    func applied(to entry: DictationHistoryEntry) -> DictationHistoryEntry {
        DictationHistoryEntry(
            schemaVersion: entry.schemaVersion,
            id: entry.id,
            source: entry.source,
            at: entry.at,
            duration: entry.duration,
            selectedLanguage: entry.selectedLanguage,
            actualLanguage: actualLanguage,
            engine: engine,
            targetBundleID: entry.targetBundleID,
            targetApplicationName: entry.targetApplicationName,
            audioPath: entry.audioPath,
            text: text,
            rawText: rawText,
            interrupted: entry.interrupted,
            recognitionFailed: nil,
            recognitionSkipped: nil
        )
    }
}

private struct RewriteOutcome {
    var removed: [DictationHistoryEntry] = []
    var replaced = false
}

extension DictationHistoryStore {
    @discardableResult
    func delete(id: UUID) throws -> Bool {
        let outcome = try rewriteHistory(mode: .removing([id]))
        // The index has changed; announce it even if removing audio throws.
        defer { notifyChange() }
        for entry in outcome.removed {
            try removeAudio(for: entry)
        }
        return !outcome.removed.isEmpty
    }

    /// Empties the index and removes only what the archive itself made (see
    /// `ownedFiles`), then the year and month folders left empty. A meeting
    /// moved into this folder, or any other file put here, stays. A folder
    /// that can't be listed fails the clear before anything changes: it is
    /// not an empty one, and the clear can be repeated once it reads.
    func clearAll() throws {
        let owned = try Self.ownedFiles(in: root)
        _ = try rewriteHistory(mode: .clearingAll)
        // The index has changed; announce it even if removing audio throws.
        defer { notifyChange() }
        for item in owned {
            try fileManager.removeItem(at: item)
        }
        Self.removeEmptyAudioFolders(in: root)
    }

    /// Replaces one line's recognized text in place, by its id: the audio,
    /// `at`, `duration`, the target and `selected_language` stay, a failure
    /// or skip mark is lifted since this attempt succeeded, and every other
    /// line is untouched. An id no longer there (deleted, or cleared, while
    /// this was being recognized) changes nothing and answers `false`.
    @discardableResult
    func replaceRecognition(
        id: UUID,
        text: String,
        rawText: String?,
        actualLanguage: String,
        engine: String?
    ) throws -> Bool {
        let replacement = RecognitionReplacement(
            text: text, rawText: rawText, actualLanguage: actualLanguage, engine: engine
        )
        let outcome = try rewriteHistory(mode: .replacing(id: id, replacement: replacement))
        if outcome.replaced { notifyChange() }
        return outcome.replaced
    }

    /// The archive's own files: dictation audio at `<yyyy>/<MM>/<uuid>.caf|m4a`
    /// (empty or unreadable files too)
    /// and the index's temporary `.history-<UUID>.tmp` in the root. A name is
    /// an agreement, not proof, so nothing else matches; year and month
    /// folders that are links are not followed. Throws when a folder of the
    /// archive can't be read, which never passes for an empty one.
    nonisolated static func ownedFiles(in root: URL) throws -> [URL] {
        var owned: [URL] = []
        for child in try entries(of: root) {
            let name = child.lastPathComponent
            if isIndexTemporaryName(name), try isPlain(child, directory: false) {
                owned.append(child)
            }
            guard isYearName(name), try isPlain(child, directory: true) else { continue }
            for month in try entries(of: child) where isMonthName(month.lastPathComponent) {
                guard try isPlain(month, directory: true) else { continue }
                for file in try entries(of: month) where isAudioName(file.lastPathComponent) {
                    if try isPlain(file, directory: false) { owned.append(file) }
                }
            }
        }
        return owned
    }

    /// What Clear All has to clear: the index and the archive's own files,
    /// their size, and whether there is anything at all (an empty file
    /// counts). Other files in the folder count for neither. A folder that
    /// can't be read may hold some, so there is something to clear, and Clear
    /// All then says why it can't; its files are not in the size.
    nonisolated static func contentToClear(in root: URL) -> (bytes: Int64, any: Bool) {
        let index = root.appendingPathComponent(historyFileName)
        let indexBytes = fileSize(index)
        guard let owned = try? ownedFiles(in: root) else { return (indexBytes, true) }
        return (owned.reduce(indexBytes) { $0 + fileSize($1) }, indexBytes > 0 || !owned.isEmpty)
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Year and month folders the archive made, once nothing at all is left
    /// in them. `rmdir` removes only an empty folder: one with anything else
    /// inside stays, and one that can't be listed is never taken for empty.
    private nonisolated static func removeEmptyAudioFolders(in root: URL) {
        for year in (try? entries(of: root)) ?? []
        where isYearName(year.lastPathComponent) && (try? isPlain(year, directory: true)) == true {
            for month in (try? entries(of: year)) ?? []
            where isMonthName(month.lastPathComponent) && (try? isPlain(month, directory: true)) == true {
                removeIfEmpty(month)
            }
            removeIfEmpty(year)
        }
    }

    private nonisolated static func removeIfEmpty(_ folder: URL) {
        _ = folder.withUnsafeFileSystemRepresentation { path in path.map { Darwin.rmdir($0) } }
    }

    /// Hidden entries included: the index's temporary files start with a dot.
    /// A folder that is not there holds nothing; one that can't be listed
    /// throws.
    private nonisolated static func entries(of folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    /// A real folder or file, never a link to one. Asked only about names the
    /// archive writes, so one that can't be looked at throws rather than
    /// passing for someone else's.
    private nonisolated static func isPlain(_ url: URL, directory: Bool) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { return false }
        return directory ? values.isDirectory == true : values.isRegularFile == true
    }

    private nonisolated static func isYearName(_ name: String) -> Bool {
        isDigits(name, count: 4)
    }

    /// `01`…`12`; `Int` alone would also take `+1`.
    private nonisolated static func isMonthName(_ name: String) -> Bool {
        isDigits(name, count: 2) && (1...12).contains(Int(name) ?? 0)
    }

    private nonisolated static func isDigits(_ name: String, count: Int) -> Bool {
        name.count == count && name.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private nonisolated static func isAudioName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        return ["caf", "m4a"].contains(url.pathExtension) && UUID(uuidString: stem) != nil
    }

    private nonisolated static func isIndexTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(".history-"), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst(".history-".count).dropLast(".tmp".count))) != nil
    }

    private func rewriteHistory(mode: HistoryRewriteMode) throws -> RewriteOutcome {
        // Replacing a line that isn't there must leave the index byte for
        // byte, inode and mtime included: with no index at all, there is
        // nothing to create.
        if case .replacing = mode, !fileManager.fileExists(atPath: historyURL.path) {
            return RewriteOutcome()
        }
        try ensureRootDirectory()
        let temporaryURL = root.appendingPathComponent(
            ".history-\(UUID().uuidString).tmp"
        )
        let output = try openPrivateNewFile(temporaryURL)
        var committed = false
        defer {
            try? output.close()
            if !committed { try? fileManager.removeItem(at: temporaryURL) }
        }

        var outcome = RewriteOutcome()
        if fileManager.fileExists(atPath: historyURL.path) {
            switch mode {
            case let .removing(ids):
                let input = try FileHandle(forReadingFrom: historyURL)
                defer { try? input.close() }
                outcome.removed = try copyHistory(input: input, output: output, removing: ids)
            case let .replacing(id, replacement):
                let input = try FileHandle(forReadingFrom: historyURL)
                defer { try? input.close() }
                outcome.replaced = try copyHistoryReplacing(
                    input: input, output: output, id: id, replacement: replacement
                )
                // No matching id: leave the real index untouched, before
                // synchronize, the hook or the rename.
                guard outcome.replaced else { return outcome }
            case .clearingAll:
                break
            }
        }

        try output.synchronize()
        try output.close()
        try runBeforeHistoryReplace()
        try atomicallyRename(temporaryURL, to: historyURL)
        committed = true
        synchronizeRootDirectory()
        return outcome
    }

    private func copyHistory(
        input: FileHandle,
        output: FileHandle,
        removing ids: Set<UUID>
    ) throws -> [DictationHistoryEntry] {
        let decoder = makeDecoder()
        let blockSize = 64 * 1024
        var carry = Data()
        var removed: [DictationHistoryEntry] = []

        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: blockSize) ?? Data()
            guard !chunk.isEmpty else { break }
            var combined = carry
            combined.append(chunk)
            var lineStart = combined.startIndex

            while let delimiter = combined[lineStart...].firstIndex(of: Self.newline) {
                let rawLine = Data(combined[lineStart..<delimiter])
                if let entry = try? decoder.decode(DictationHistoryEntry.self, from: rawLine),
                   ids.contains(entry.id) {
                    removed.append(entry)
                } else {
                    try output.write(contentsOf: rawLine)
                    try output.write(contentsOf: Data([Self.newline]))
                }
                lineStart = combined.index(after: delimiter)
            }
            carry = Data(combined[lineStart...])
        }

        // A final line without LF can still be a complete record (the reader
        // shows it), so it is filtered like any other line. Anything else, a
        // record kept or corrupt bytes, is preserved byte-for-byte: appending
        // already isolates it, and a deletion must not destroy unrelated data.
        if !carry.isEmpty {
            if let entry = try? decoder.decode(DictationHistoryEntry.self, from: carry),
               ids.contains(entry.id) {
                removed.append(entry)
            } else {
                try output.write(contentsOf: carry)
            }
        }
        return removed
    }

    /// Copies every line through, re-encoding only the one whose id matches;
    /// a line that fails to decode is passed through byte-for-byte, as it
    /// cannot be told apart from the one being replaced. The final line's
    /// trailing newline (or its absence) is preserved exactly as in `copyHistory`.
    private func copyHistoryReplacing(
        input: FileHandle,
        output: FileHandle,
        id: UUID,
        replacement: RecognitionReplacement
    ) throws -> Bool {
        let decoder = makeDecoder()
        let encoder = makeEncoder()
        let blockSize = 64 * 1024
        var carry = Data()
        var replaced = false

        func process(_ rawLine: Data, isFinal: Bool) throws {
            guard let entry = try? decoder.decode(DictationHistoryEntry.self, from: rawLine),
                  entry.id == id else {
                try output.write(contentsOf: rawLine)
                if !isFinal { try output.write(contentsOf: Data([Self.newline])) }
                return
            }
            let line = try encoder.encode(replacement.applied(to: entry))
            try output.write(contentsOf: line)
            if !isFinal { try output.write(contentsOf: Data([Self.newline])) }
            replaced = true
        }

        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: blockSize) ?? Data()
            guard !chunk.isEmpty else { break }
            var combined = carry
            combined.append(chunk)
            var lineStart = combined.startIndex

            while let delimiter = combined[lineStart...].firstIndex(of: Self.newline) {
                try process(Data(combined[lineStart..<delimiter]), isFinal: false)
                lineStart = combined.index(after: delimiter)
            }
            carry = Data(combined[lineStart...])
        }

        if !carry.isEmpty {
            try process(carry, isFinal: true)
        }
        return replaced
    }

    private func removeAudio(for entry: DictationHistoryEntry) throws {
        guard let audioURL = resolvedAudioURL(relativePath: entry.audioPath),
              fileManager.fileExists(atPath: audioURL.path) else { return }
        try fileManager.removeItem(at: audioURL)
        try pruneEmptyAudioDirectories(startingAt: audioURL.deletingLastPathComponent())
    }

    private func pruneEmptyAudioDirectories(startingAt directory: URL) throws {
        var candidate = directory
        while candidate != root {
            guard try fileManager.contentsOfDirectory(atPath: candidate.path).isEmpty else { return }
            try fileManager.removeItem(at: candidate)
            candidate.deleteLastPathComponent()
        }
    }

    private func openPrivateNewFile(_ url: URL) throws -> FileHandle {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func atomicallyRename(_ source: URL, to destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
    }

    private func synchronizeRootDirectory() {
        let descriptor: Int32 = root.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        _ = Darwin.close(descriptor)
    }
}
