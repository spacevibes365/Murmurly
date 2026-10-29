import Darwin
import Foundation

/// The helper's own log, separate from the app's `AppLog`
/// (`Sources/Logging.swift`): that one writes with a bare seek-then-write,
/// fine for one process with its own queue, unsafe for a helper that may run
/// more than once at a time. One line per call: the command and counts only
/// — never the search text, a dictation's words or a meeting's title, and
/// never a path. Lines older than 30 days are dropped at the next write.
enum AgentsLog {
    private static let retention: TimeInterval = 30 * 86_400

    /// `fields` is already reduced to counts and ids (`count=12`,
    /// `id=local:2026-03-04_10-20-30`): callers must not pass anything a
    /// person typed or anything read from a transcript or a dictation.
    static func record(at url: URL, command: String, fields: String) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let lockPath = url.path + ".lock"
        let lockDescriptor = lockPath.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard lockDescriptor >= 0 else { return }
        defer { Darwin.close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX) == 0 else { return }
        defer { flock(lockDescriptor, LOCK_UN) }

        dropOldLines(at: url)

        let stamp = HelperContract.string(from: Date())
        let line = "\(stamp) \(command) \(fields)\n"
        guard let data = line.data(using: .utf8) else { return }
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Only the file's first line's timestamp is checked: once it is within
    /// 30 days, every later line (newer, by construction) is too, so the
    /// common case costs reading the first 4096 bytes, never the whole file
    /// (which `record` would otherwise reopen and rewrite on every single
    /// call, log line or not). The full read and rewrite below still happen,
    /// unchanged, once that first line actually is old.
    private static func dropOldLines(at url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), !head.isEmpty,
              let headText = String(data: head, encoding: .utf8), !headText.isEmpty else { return }
        let firstLine = headText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        guard let firstLine, let firstDate = timestamp(in: firstLine) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        guard firstDate < cutoff else { return }

        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { line in
            guard let date = timestamp(in: String(line)) else { return true }
            return date >= cutoff
        }
        let rewritten = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".agents.log.tmp-\(UUID().uuidString)")
        do {
            try rewritten.write(to: temporary, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private static func timestamp(in line: String) -> Date? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        return HelperContract.dateFormatter().date(from: String(line[line.startIndex..<space]))
    }
}
