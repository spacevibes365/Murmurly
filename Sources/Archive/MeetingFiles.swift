import Foundation

/// Reading a meeting's folder: which folders are meetings, their attempt
/// records and the user's marks. The sound, compression, moving and removal
/// code stay in the app's own `MeetingStorage.swift`, as `extension
/// MeetingStorage`; this file holds only what the helper needs too.
enum MeetingStorage {}

extension MeetingStorage {
    /// `yyyy-MM-dd HH-mm-ss Meeting`, with `-N` when two start in one second:
    /// the only names `RecordingsStore.createSession` gives.
    static func isMeetingFolderName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}-[0-9]{2}-[0-9]{2} Meeting(-[0-9]+)?/#) != nil
    }

    /// The track names a stop writes; a folder without `metadata.json` (a
    /// recording cut off by a crash) is known by them.
    static let defaultTrackNames: Set<String> = ["system.caf", "microphone.caf", "system.m4a", "microphone.m4a"]

    /// The meetings directly in `root`, for Storage and the window alike, so
    /// both count the same: a folder named as `RecordingsStore.createSession`
    /// names it, with `metadata.json` or a track in it. A recording cut off
    /// before its stop has no metadata and is still a meeting; nothing here
    /// says whether it is finished. No root yet is no meetings; a root that
    /// cannot be reached or listed throws, as that is not the same as empty. A folder of
    /// a meeting's name that cannot be read is kept: it may be one, and
    /// leaving it out would pass for its loss.
    static func meetingFolders(in root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        // Read strictly: only a root proven absent is none; one behind a
        // parent that can't be passed is unknown, not empty.
        var info = stat()
        if stat(root.path, &info) != 0 {
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: root.path])
            }
            return []
        }
        // `rootChildNames(of:)` resolves only `root`'s own last link (as the
        // `.refuse` branch below already does): `contentsOfDirectory(at:
        // root)` instead throws Cocoa 256 when `root` itself is a symbolic
        // link, even though the folder behind it reads fine — which is
        // exactly what a chosen meetings folder set to a link is. Children's
        // paths are still built from `root`'s own original spelling, so a
        // link inside `root` is still followed below, same as before.
        let names = try rootChildNames(of: root)
        return names.compactMap { name -> URL? in
            guard isMeetingFolderName(name) else { return nil }
            let child = root.appendingPathComponent(name, isDirectory: true)
            guard let isDirectory = try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else { return child }
            guard isDirectory else { return nil }
            guard let childNames = try? fileManager.contentsOfDirectory(atPath: child.path) else { return child }
            return (childNames.contains("metadata.json") || !Set(childNames).isDisjoint(with: defaultTrackNames)) ? child : nil
        }
    }

    /// What one child of a meetings root is, for the helper's `refuse` read:
    /// a meeting folder, a link (never opened), or neither. A failed `lstat`
    /// is silently `.other`, same as before — never reported as a link.
    enum Child: Sendable, Equatable {
        case meeting
        case link
        case other
    }

    static func classify(_ child: URL) -> Child {
        var entry = stat()
        guard lstat(child.path, &entry) == 0 else { return .other }
        if entry.st_mode & S_IFMT == S_IFLNK { return .link }
        guard entry.st_mode & S_IFMT == S_IFDIR else { return .other }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: child.path) else { return .meeting }
        return (names.contains("metadata.json") || !Set(names).isDisjoint(with: defaultTrackNames)) ? .meeting : .other
    }

    /// The names of `root`'s own direct children, for a `refuse` read of
    /// `root` itself: `contentsOfDirectory(at:)` throws Cocoa 256 when its
    /// own URL is itself a symbolic link (a chosen folder that is a link to
    /// the local one, say) even though the folder behind it is perfectly
    /// readable, so the listing call resolves `root`'s own last link first —
    /// for this one call only, never for a child's path, which must keep
    /// `root`'s original spelling so a later `lstat`/`classify` of that path
    /// still sees a link in the child's own name, not one hidden by
    /// resolving the root out from under it. Shared by this file's `.refuse`
    /// branch below and by `Archive.meeting` (`Meetings.swift`), so a root
    /// that is a link is read the same way by both.
    static func rootChildNames(of root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [], options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent)
    }

    /// For the helper, which never opens a meeting folder that is itself a
    /// link: every such name is left out of the folders returned and named
    /// instead in `skipped`, with why. `follow` is `meetingFolders(in:)`
    /// above, unchanged.
    static func meetingFolders(in root: URL, links: Archive.Links) throws -> (folders: [URL], skipped: [(URL, String)]) {
        switch links {
        case .follow:
            return (try meetingFolders(in: root), [])
        case .refuse:
            var info = stat()
            if stat(root.path, &info) != 0 {
                let code = errno
                guard code == ENOENT || code == ENOTDIR else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: root.path])
                }
                return ([], [])
            }
            let names = try rootChildNames(of: root)
            var folders: [URL] = []
            var skipped: [(URL, String)] = []
            for name in names where isMeetingFolderName(name) {
                let child = root.appendingPathComponent(name, isDirectory: true)
                switch classify(child) {
                case .meeting: folders.append(child)
                case .link: skipped.append((child, "is a link"))
                case .other: continue
                }
            }
            return (folders, skipped)
        }
    }

    /// `transcript.md` is 1, `transcript N.md` is N; nil for any other name.
    static func transcriptNumber(_ name: String) -> Int? {
        if name == "transcript.md" { return 1 }
        guard name.hasPrefix("transcript "), name.hasSuffix(".md"),
              let number = Int(name.dropFirst("transcript ".count).dropLast(".md".count)), number > 1 else { return nil }
        return number
    }

    /// A chosen folder counts only if it exists as a folder, and one under
    /// `/Volumes` on the same volume as `/Volumes` itself does not: that is a
    /// mount point left (or made) while its disk was away, and anything put
    /// there would stay on this Mac. The startup volume `/` is no reference:
    /// on APFS it is the sealed system volume, while `/Volumes` lives on the
    /// data volume. Nothing is ever created here, the folder nor its parents.
    static func isAvailable(_ folder: URL, mounts: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let resolved = folder.resolvingSymlinksInPath()
        let mountsPath = mounts.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(mountsPath + "/") else { return true }
        func volume(_ url: URL) -> (any NSObjectProtocol)? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        }
        guard let own = volume(resolved), let parent = volume(mounts) else { return false }
        return !own.isEqual(parent)
    }

    /// `yyyy-MM-dd HH-mm-ss Meeting`, as `RecordingsStore.createSession`
    /// names folders.
    static func date(fromFolderName name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.date(from: String(name.prefix(19)))
    }
}

// MARK: - A folder's identity

/// A folder as the disk knows it: its volume and its file number, whatever
/// path reaches it. Two spellings of one folder (a link in a parent path, a
/// meetings folder that has since become a folder outside both roots) are one
/// folder; a copy of it is another. Read with the folder, off the main actor
/// for anything that may be on a network volume. Nil when it cannot be read,
/// or when the path ends in a link rather than the folder itself: nothing is
/// written or removed through one.
struct FolderIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64

    static func of(_ folder: URL) -> FolderIdentity? {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FolderIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// What a setting's path leads to, its own last link followed: for
    /// telling whether a folder is that one, never for writing or deleting.
    enum Reach: Equatable, Sendable {
        case folder(FolderIdentity)
        /// Nothing there, or something that is not a folder.
        case none
        /// It could not be told: never taken for "none".
        case unknown(String)
    }

    static func reach(_ folder: URL) -> Reach {
        var info = stat()
        guard stat(folder.path, &info) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .none : .unknown(String(cString: strerror(code)))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .none }
        return .folder(FolderIdentity(device: info.st_dev, inode: info.st_ino))
    }
}

// MARK: - Attempt records

/// What became of one transcription attempt of a meeting, kept in the
/// meeting's folder so it outlives the run: whether the transcript it wrote
/// covers the whole meeting, and with which engine, languages and lines.
/// Written by the queue alone, in its job, only to a folder `Folder.inspect`
/// accepted: in progress before the work starts, its result after. A record
/// still in progress is an attempt that never ended (the app was killed, or
/// the result could not be written); no record at all is an attempt from
/// before records existed. Neither proves anything.
///
/// The order of attempts is their number, in the file's name, so even a
/// record that cannot be read keeps its place; never the clock, which two
/// attempts in one second share.
struct MeetingAttempt: Codable, Sendable, Equatable {
    static let formatVersion = 1
    static let namePrefix = ".attempt "
    static let nameSuffix = ".murmurly.json"

    enum Result: String, Codable, Sendable {
        case inProgress, complete, incomplete, noSpeech, failed
    }

    /// Which track a line came from: what the transcript's labels mean.
    enum Source: String, Codable, Sendable {
        case microphone, system
    }

    /// One transcript line's exact span; the n-th line of the record is the
    /// n-th line of its transcript while the fingerprint matches.
    struct Line: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var source: Source
    }

    struct Fingerprint: Codable, Sendable, Equatable {
        var bytes: Int
        var sha256: String
    }

    /// The labels written for each track, in the interface language of that run.
    struct Speakers: Codable, Sendable, Equatable {
        var microphone: String
        var system: String
    }

    var version = MeetingAttempt.formatVersion
    var number: Int
    var result = Result.inProgress
    var startedAt: Date
    var endedAt: Date?
    /// The transcript's file name in the folder.
    var transcript: String?
    /// `DictationEngine` raw values.
    var engines: [String] = []
    var languages: [String] = []
    var failedChunks = 0
    var cutShort = false
    var missingTracks: [Source] = []
    /// Why it failed, as shown; nothing decides by it.
    var reason: String?
    var speakers: Speakers?
    var lines: [Line] = []
    var fingerprint: Fingerprint?

    /// One record file as found: its number from the name, and what it holds
    /// unless it cannot be read or is of a version this app does not know.
    struct Entry: Sendable, Equatable {
        let name: String
        let number: Int
        let attempt: MeetingAttempt?
    }

    /// `.attempt <number> <UUID>.murmurly.json`; nil for any other name.
    static func number(inName name: String) -> Int? {
        guard name.hasPrefix(namePrefix), name.hasSuffix(nameSuffix) else { return nil }
        let middle = name.dropFirst(namePrefix.count).dropLast(nameSuffix.count).split(separator: " ")
        guard middle.count == 2, let number = Int(middle[0]), number > 0,
              UUID(uuidString: String(middle[1])) != nil else { return nil }
        return number
    }

    /// Every record in the folder, oldest first by number. `links: .refuse`
    /// never opens a record that is itself a link; it reads as unreadable.
    /// `names`, when given, is a listing of the folder already read by the
    /// caller — one less listing of a folder read for both its names and its
    /// records. `withLines: false` reads each record without its `lines`
    /// array (`Head` below): for a listing of many meetings, where nothing
    /// looks at a line's own span or source.
    static func entries(in folder: URL, names: [String]? = nil, links: Archive.Links = .follow, withLines: Bool = true) throws -> [Entry] {
        let fileNames = try names ?? FileManager.default.contentsOfDirectory(atPath: folder.path)
        return fileNames.compactMap { name in
            guard let number = number(inName: name) else { return nil }
            return Entry(name: name, number: number, attempt: read(folder.appendingPathComponent(name), links: links, withLines: withLines))
        }.sorted { $0.number < $1.number }
    }

    /// Which record (among those already read) wrote the transcript file
    /// named `name`: the latest one that names it, as both the listing's own
    /// completeness and a transcript's exact timing and names agree on.
    static func latest(writing name: String, in entries: [Entry]) -> MeetingAttempt? {
        entries.reversed().lazy.compactMap(\.attempt).first { $0.transcript == name }
    }

    private static func read(_ url: URL, links: Archive.Links, withLines: Bool) -> MeetingAttempt? {
        guard let data = try? Archive.read(url, links: links) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard withLines else {
            guard let head = try? decoder.decode(Head.self, from: data), head.version == formatVersion else { return nil }
            return head.asAttempt
        }
        guard let attempt = try? decoder.decode(MeetingAttempt.self, from: data), attempt.version == formatVersion else {
            return nil
        }
        return attempt
    }

    /// A placeholder for `lines`'s own JSON value, read only enough to check
    /// it is an array: its elements are never walked or stored, so a
    /// meeting listing's memory never holds the lines of records it does not
    /// need, and a record whose line elements are themselves malformed still
    /// reads as a record here (a known, deliberate difference from the full
    /// decode — see `testSummaryRecordReadsAsFullRecordWithoutLines`).
    private struct LinesShape: Decodable {
        init(from decoder: Decoder) throws {
            _ = try decoder.unkeyedContainer()
        }
    }

    /// Every field of `MeetingAttempt` except `lines`, for a lighter read of
    /// a folder's attempt records (`entries(in:names:links:withLines:)`
    /// above) that still answers every question the listing and
    /// `completeness` ask. Kept in exact lock-step with `MeetingAttempt`'s
    /// own fields: a field added there without one here would make this
    /// struct quietly stop seeing it.
    private struct Head: Decodable {
        var version: Int
        var number: Int
        var result: Result
        var startedAt: Date
        var endedAt: Date?
        var transcript: String?
        var engines: [String] = []
        var languages: [String] = []
        var failedChunks = 0
        var cutShort = false
        var missingTracks: [Source] = []
        var reason: String?
        var speakers: Speakers?
        var lines: LinesShape
        var fingerprint: Fingerprint?

        var asAttempt: MeetingAttempt {
            var attempt = MeetingAttempt(number: number, startedAt: startedAt)
            attempt.version = version
            attempt.result = result
            attempt.endedAt = endedAt
            attempt.transcript = transcript
            attempt.engines = engines
            attempt.languages = languages
            attempt.failedChunks = failedChunks
            attempt.cutShort = cutShort
            attempt.missingTracks = missingTracks
            attempt.reason = reason
            attempt.speakers = speakers
            attempt.lines = []
            attempt.fingerprint = fingerprint
            return attempt
        }
    }
}

// MARK: - The user's marks

/// The user's own name for a meeting, its star and the names of its
/// speakers, in the meeting's folder as `murmurly.json` (never translated),
/// so they go wherever the meeting goes.
/// Written by the window alone (`MeetingStorage.write`, in `MeetingStorage.swift`).
/// Read loosely and written over the file as it is then, so every other key,
/// a later version's or anyone's, survives; a file this app cannot read, or
/// one of a later version, is never written over: its marks cannot be
/// changed until it can be read.
struct MeetingMarks: Sendable, Equatable {
    static let fileName = "murmurly.json"
    static let formatVersion = 1

    var title: String?
    var starred = false
    /// Who speaks on each track, shown instead of the transcript's labels:
    /// the file's lines say which track each one came from. In `speakers`,
    /// `{"microphone": …, "system": …}`; the transcripts are never changed.
    var speakers: [MeetingAttempt.Source: String] = [:]

    /// What a meeting's folder holds.
    enum State: Sendable, Equatable {
        case none
        case read(MeetingMarks)
        case unreadable(String)
        /// Written by a later Murmurly: never written over.
        case newer(version: Int)

        var marks: MeetingMarks? {
            switch self {
            case .none: MeetingMarks()
            case .read(let marks): marks
            case .unreadable, .newer: nil
            }
        }
    }

    enum Refusal: LocalizedError, Equatable {
        case unreadable(String)
        case newer(version: Int)
        /// The folder at the address is not the one the change was made for.
        case replaced

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                String(localized: "murmurly.json in the meeting’s folder can’t be read (\(reason)); it is left as it is")
            case .newer:
                String(localized: "murmurly.json in the meeting’s folder was written by a newer Murmurly; it is left as it is")
            case .replaced:
                String(localized: "The meeting’s folder at this address is gone or is another one now; nothing was written.")
            }
        }
    }

    /// `follow` is the window's own read, unchanged: no file is `.none`. For
    /// the helper (`refuse`), the file is never opened through a link —
    /// including a dangling one — which reads as `.unreadable`, not `.none`:
    /// `fileExists`, which follows links, is never asked first.
    static func read(in folder: URL, links: Archive.Links = .follow) -> State {
        let url = folder.appendingPathComponent(fileName)
        let data: Data
        switch links {
        case .follow:
            guard FileManager.default.fileExists(atPath: url.path) else { return .none }
            do {
                data = try Data(contentsOf: url)
            } catch {
                return .unreadable(error.localizedDescription)
            }
        case .refuse:
            do {
                data = try Archive.read(url, links: .refuse)
            } catch Archive.ReadError.missing {
                return .none
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable(String(localized: "not a JSON object"))
        }
        switch parse(dictionary) {
        case .success(let marks): return .read(marks)
        case .failure(.newer(let version)): return .newer(version: version)
        case .failure(.unreadable(let reason)): return .unreadable(reason)
        case .failure(let refusal): return .unreadable(refusal.localizedDescription)
        }
    }

    /// This version's keys from the file's object; the rest is kept on write.
    /// Internal, not private: `MeetingStorage.write` (`MeetingStorage.swift`)
    /// calls it too, to check the file it is about to write over.
    static func parse(_ object: [String: Any]) -> Result<MeetingMarks, Refusal> {
        guard let version = object["version"] as? Int else { return .failure(.unreadable(String(localized: "no version"))) }
        guard version <= formatVersion else { return .failure(.newer(version: version)) }
        guard version == formatVersion else { return .failure(.unreadable(String(localized: "version \(version)"))) }
        let title = object["title"]
        let starred = object["starred"]
        guard title == nil || title is String, starred == nil || starred is Bool else {
            return .failure(.unreadable(String(localized: "a mark of another kind")))
        }
        // Only this version's names are read; any other key in it is kept.
        var speakers: [MeetingAttempt.Source: String] = [:]
        if let names = object["speakers"] {
            guard let names = names as? [String: Any] else { return .failure(.unreadable(String(localized: "a mark of another kind"))) }
            for source in [MeetingAttempt.Source.microphone, .system] {
                guard let name = names[source.rawValue] else { continue }
                guard let name = name as? String else { return .failure(.unreadable(String(localized: "a mark of another kind"))) }
                speakers[source] = name
            }
        }
        return .success(MeetingMarks(title: title as? String, starred: starred as? Bool ?? false, speakers: speakers))
    }
}
