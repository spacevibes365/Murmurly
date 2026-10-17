import Foundation

/// On-disk metadata for one meeting session (written alongside the CAF tracks).
struct MeetingMetadata: Codable, Sendable, Equatable {
    struct SegmentMeta: Codable, Sendable, Equatable {
        var index: Int
        var system: String
        var mic: String
        /// Frames the closed system track really holds; absent when it could
        /// not be read. Older files stored the write-queue count here.
        var frames: Int64?
        /// Frames the closed microphone track really holds; absent when unread.
        var micFrames: Int64? = nil
        /// Frames the capture handed to the write queue: diagnostics only.
        var enqueuedFrames: Int64? = nil
        /// Channels the microphone delivered; absent in older files.
        var micInputChannels: Int? = nil
        /// The one channel (counted from 1) written when the microphone had
        /// three or more; absent when every channel was written.
        var micRecordedChannel: Int? = nil
        /// Set when the track was compressed scaled down to fit 24-bit ALAC:
        /// the original sample is the stored one divided by it.
        var systemGain: Double? = nil
        var micGain: Double? = nil
    }
    var startedAt: String          // ISO8601
    var endedAt: String            // ISO8601
    var sampleRate: Double
    var state: String              // recording / processing / done / suspect / interrupted / failed
    var segments: [SegmentMeta]
    /// Who started the recording: the app an automatic recording was started
    /// for (its bundle ID, or `pid:<n>` without one), or `manual`. Absent in
    /// recordings made before it was written.
    var trigger: String? = nil
    /// Why the state is `suspect` or `failed`, naming the track.
    var issues: [String]? = nil

    /// `trigger` of a recording started by hand. Never translated.
    static let manualTrigger = "manual"
}

/// Owns the meeting recordings directory: creates per-session folders and reads/writes
/// `metadata.json`.
@MainActor
final class RecordingsStore: ObservableObject {
    /// `~/Library/Application Support/Murmurly/Meetings`.
    /// `nonisolated` — pure path computation, usable as a default-arg / off the main actor.
    nonisolated static func meetingsRoot() -> URL {
        meetingsRoot(
            arguments: ProcessInfo.processInfo.arguments, isolated: TestIsolation.isEnabled,
            isolatedRoot: TestIsolation.root, owners: ownersMeetingsRoot()
        )
    }

    /// `owners` only for a launch that is not isolated and was not given a
    /// seeded root.
    nonisolated static func meetingsRoot(arguments: [String], isolated: Bool, isolatedRoot: URL, owners: URL) -> URL {
        #if DEBUG
        // UI-test harness only: `-MeetingsProbeRoot <dir>` puts the meetings
        // where the test seeded them before launch.
        if let index = arguments.firstIndex(of: "-MeetingsProbeRoot"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        if isolated {
            return isolatedRoot.appendingPathComponent("Meetings", isDirectory: true)
        }
        return owners
    }

    /// The meetings of the person using this Mac, whatever a test process
    /// was told: what a test must never reach.
    nonisolated static func ownersMeetingsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmurly/Meetings", isDirectory: true)
    }

    /// Create a fresh session folder named `yyyy-MM-dd HH-mm-ss Meeting`; returns its URL.
    /// `root` defaults to the real recordings dir; tests pass a temp dir for isolation.
    func createSession(date: Date = Date(), root: URL = RecordingsStore.meetingsRoot()) throws -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = "\(fmt.string(from: date)) Meeting"
        let fm = FileManager.default
        // Guarantee a unique folder: two sessions within the same second must NOT
        // reuse a dir (the writer would overwrite the prior recording's CAFs).
        var dir = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where a meeting folder is now: its local path while it is there,
    /// otherwise the same name in the meetings folder it moved to. Only the
    /// local path is checked: this runs on the main actor, and a dead network
    /// volume would hang it. Hence only for a folder in the local root: the
    /// recorder's own, or one the queue matched to that root by path.
    nonisolated static func currentLocation(of folder: URL, meetingsFolder: URL?) -> URL {
        guard let meetingsFolder, !FileManager.default.fileExists(atPath: folder.path) else { return folder }
        return meetingsFolder.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
    }

    func writeMetadata(_ meta: MeetingMetadata, to sessionDir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(
            to: sessionDir.appendingPathComponent("metadata.json"),
            options: .atomic
        )
    }

    /// Bytes free on the volume holding the recordings root (for pre-flight disk checks).
    /// Anchors on the always-present Application Support dir — the Murmurly/Meetings
    /// subfolders may not exist before the first session (capacity is per-volume anyway).
    func freeDiskBytes() -> Int64? {
        let anchor = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? anchor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
