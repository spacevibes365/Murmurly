import Foundation
import os
import AppKit

/// App-wide logging: unified `os.Logger` (visible in Console.app / `log stream`)
/// PLUS an appended file at ~/Library/Logs/Murmurly/murmurly.log so the
/// whole session — actions, phases, subprocess lifecycle, errors — is captured
/// for debugging without attaching a debugger.
enum AppLog {
    enum Level: String { case debug = "DEBUG", info = "INFO", error = "ERROR" }

    // Follows the bundle so forks with their own identifier log under their own name.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Murmurly"
    private static let osLog = Logger(subsystem: subsystem, category: "app")
    private static let queue = DispatchQueue(label: subsystem + ".filelog", qos: .utility)

    static let fileURL: URL = {
        let base = TestIsolation.isEnabled
            ? TestIsolation.root
            : (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library"))
                .appendingPathComponent("Logs/Murmurly", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("murmurly.log")
    }()

    /// Rotate once at launch if the log got large (keeps one .old generation).
    static func rotateIfNeeded(maxBytes: Int = 5 * 1024 * 1024) {
        queue.async {
            let fm = FileManager.default
            guard let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int,
                  size > maxBytes else { return }
            let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
    }

    static func log(_ level: Level, _ category: String, _ message: String) {
        switch level {
        case .error: osLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info:  osLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .debug: osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        let stamp = timestamp()
        queue.async {
            let line = "\(stamp) [\(level.rawValue)] \(category): \(message)\n"
            append(line)
        }
    }

    static func info(_ category: String, _ message: String)  { log(.info, category, message) }
    static func error(_ category: String, _ message: String) { log(.error, category, message) }
    static func debug(_ category: String, _ message: String) { log(.debug, category, message) }

    /// Open the log directory in Finder with the log selected.
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - private

    private static func append(_ line: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
