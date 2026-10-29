import Foundation

extension DictationHistoryStore {
    private static var historyReadBlockSize: Int { 64 * 1024 }

    func historySummary() throws -> (count: Int, oldest: Date?) {
        try scanHistory(matching: nil)
    }

    func count(matching query: String?) throws -> Int {
        try scanHistory(matching: query).count
    }

    /// Newest first. `nextCursor` is an exclusive byte offset suitable for the
    /// next call, so paging never has to rescan already returned JSONL records.
    func page(
        before cursor: UInt64? = nil,
        limit: Int = 100,
        matching query: String? = nil
    ) throws -> (entries: [DictationHistoryEntry], nextCursor: UInt64?) {
        guard limit > 0, fileManager.fileExists(atPath: historyURL.path) else {
            return ([], nil)
        }

        let handle = try FileHandle(forReadingFrom: historyURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let upperBound = min(cursor ?? fileSize, fileSize)
        guard upperBound > 0 else { return ([], nil) }

        let needle = DictationHistoryEntry.searchNeedle(query)
        return try DictationHistoryEntry.scanBackward(
            handle: handle,
            upperBound: upperBound,
            limit: limit,
            blockSize: Self.historyReadBlockSize,
            decoder: makeDecoder(),
            include: { needle == nil || $0.matches(needle: needle!) },
            onMalformed: { AppLog.error("dictation-history", "skipping malformed JSONL line") }
        )
    }

    func recent(limit: Int = 10) throws -> [DictationHistoryEntry] {
        try page(limit: limit).entries
    }

    func existingAudioIDs(for entries: [DictationHistoryEntry]) -> Set<UUID> {
        Set(entries.compactMap { entry in
            audioURL(for: entry) == nil ? nil : entry.id
        })
    }

    func audioURL(for entry: DictationHistoryEntry) -> URL? {
        guard let url = resolvedAudioURL(relativePath: entry.audioPath),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return url
    }

    func resolvedAudioURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        let supportedExtension = ["caf", "m4a"].contains(candidate.pathExtension.lowercased())
        guard candidate.path.hasPrefix(rootPrefix), supportedExtension else { return nil }
        return candidate
    }

    private func scanHistory(matching query: String?) throws -> (count: Int, oldest: Date?) {
        guard fileManager.fileExists(atPath: historyURL.path) else { return (0, nil) }

        let handle = try FileHandle(forReadingFrom: historyURL)
        defer { try? handle.close() }
        let decoder = makeDecoder()
        let needle = DictationHistoryEntry.searchNeedle(query)
        var carry = Data()
        var count = 0
        var oldest: Date?

        func consume(_ rawLine: Data) {
            guard !rawLine.isEmpty else { return }
            guard let entry = try? decoder.decode(DictationHistoryEntry.self, from: rawLine) else {
                AppLog.error("dictation-history", "skipping malformed JSONL line during scan")
                return
            }
            if let needle, !entry.matches(needle: needle) {
                return
            }
            count += 1
            if oldest.map({ entry.at < $0 }) ?? true { oldest = entry.at }
        }

        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Self.historyReadBlockSize) ?? Data()
            guard !chunk.isEmpty else { break }
            var combined = carry
            combined.append(chunk)
            var lineStart = combined.startIndex
            while let delimiter = combined[lineStart...].firstIndex(of: Self.newline) {
                consume(Data(combined[lineStart..<delimiter]))
                lineStart = combined.index(after: delimiter)
            }
            carry = Data(combined[lineStart...])
        }
        consume(carry)
        return (count, oldest)
    }
}
