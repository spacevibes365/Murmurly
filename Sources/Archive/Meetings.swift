import Foundation

extension Archive {
    /// One spelling per folder, so a meeting from the list, the menu and the
    /// queue is the same value: standardized, with its trailing slash.
    /// `MeetingLibrary.canonical` (`MeetingLibrary.swift`) calls this.
    static func canonical(_ folder: URL) -> URL {
        URL(fileURLWithPath: folder.standardizedFileURL.path, isDirectory: true)
    }

    /// One transcript file of a meeting.
    struct TranscriptVersion: Sendable, Equatable, Identifiable {
        let name: String
        /// 1 for `transcript.md`; numbers may have gaps.
        let number: Int
        let modified: Date?
        /// The latest readable record of an attempt that wrote this file.
        let attempt: MeetingAttempt?
        var id: String { name }
    }

    /// What the last attempt by number left: none (no records, as with
    /// transcripts from before records existed), its record, or a record
    /// that cannot be read, which proves nothing about the transcripts.
    enum LastAttempt: Sendable, Equatable {
        case none
        case recorded(MeetingAttempt)
        case unreadable
    }

    /// One meeting folder's facts as the files hold them: everything a row
    /// and a card show except the folder's byte count, its audio, what the
    /// Trash and the audio rule would do with it and what the player would
    /// play — those need `AVFoundation` or cost a full read of the folder,
    /// and stay the window's own concern (`MeetingLibrary.readMeeting`).
    struct MeetingFolder: Sendable, Equatable {
        /// Whether this folder's attempt records were read with their
        /// `lines` (`.full`, the window's own default) or without
        /// (`.summary`, the helper's listing): `Archive.transcript(of:)`
        /// reads the record again, fully, for a `.summary` folder, so timing
        /// and names are never missing — only the listing itself is lighter.
        enum Records: Sendable, Equatable { case full, summary }

        let records: Records
        let directory: URL
        /// Nil when the folder itself could not be listed.
        let names: [String]?
        let startedAt: Date?
        let duration: TimeInterval?
        /// `metadata.json`'s state; nil without it: the recording under way,
        /// or one cut off before its stop.
        let state: String?
        /// Why `metadata.json` could not be read, when it is there but is not
        /// a plain, readable JSON object: `"link"` for a symbolic link (never
        /// opened in `refuse`), `"readError"` for anything else unreadable.
        /// Nil both when the file is absent (legitimately: the recording is
        /// under way, or was cut off) and when it was read: never guessed
        /// from `try?` alone, which would call a link "no metadata".
        let metadataError: String?
        let issues: [String]
        let trigger: String?
        /// The tracks `metadata.json` names, by their last path component.
        let tracks: [String]
        let versions: [TranscriptVersion]
        let lastAttempt: LastAttempt
        /// The user's name and star, from `murmurly.json`.
        let marks: MeetingMarks.State
        /// The folder itself, whatever path reached it; nil when it could
        /// not be read.
        let identity: FolderIdentity?

        /// Reads `metadata.json` loosely and without filtering its state:
        /// July recordings have no `endedAt`, and a folder without it is
        /// still a meeting. `links: .refuse` never opens a file in the
        /// folder through a link.
        static func read(_ folder: URL, links: Links, records: Records = .full) -> MeetingFolder {
            let directory = Archive.canonical(folder)
            let fileManager = FileManager.default
            let metadataURL = directory.appendingPathComponent("metadata.json")
            var metadata: [String: Any]?
            var metadataError: String?
            switch links {
            case .follow:
                // `Data(contentsOf:)` does not tell a missing file apart from
                // any other failure, so a legitimate absence (no recording
                // stopped yet) is checked for first, as the window always did.
                if fileManager.fileExists(atPath: metadataURL.path) {
                    do {
                        let data = try Archive.read(metadataURL, links: .follow)
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            metadata = object
                        } else {
                            metadataError = "readError"
                        }
                    } catch {
                        metadataError = "readError"
                    }
                }
            case .refuse:
                do {
                    let data = try Archive.read(metadataURL, links: .refuse)
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        metadata = object
                    } else {
                        metadataError = "readError"
                    }
                } catch Archive.ReadError.missing(_) {
                    // No file at all: legitimately no metadata yet (recording
                    // under way, or cut off before its stop).
                } catch Archive.ReadError.link(_) {
                    metadataError = "link"
                } catch {
                    metadataError = "readError"
                }
            }
            let names = try? fileManager.contentsOfDirectory(atPath: directory.path)

            let dates = ISO8601DateFormatter()
            let started = (metadata?["startedAt"] as? String).flatMap(dates.date(from:))
            let ended = (metadata?["endedAt"] as? String).flatMap(dates.date(from:))
            let segment = (metadata?["segments"] as? [[String: Any]])?.first
            let frames = (segment?["frames"] as? NSNumber)?.doubleValue
            let rate = (metadata?["sampleRate"] as? NSNumber)?.doubleValue
            let duration: TimeInterval? = if let started, let ended {
                ended.timeIntervalSince(started)
            } else if let frames, let rate, rate > 0 {
                frames / rate
            } else {
                nil
            }
            let tracks = ["system", "mic"].compactMap { segment?[$0] as? String }.map { URL(fileURLWithPath: $0).lastPathComponent }

            let entries = (try? MeetingAttempt.entries(in: directory, names: names, links: links, withLines: records == .full)) ?? []
            let lastAttempt: LastAttempt = if names == nil {
                .unreadable
            } else if let last = entries.last {
                last.attempt.map(LastAttempt.recorded) ?? .unreadable
            } else {
                .none
            }
            let versions = (names ?? []).compactMap { name -> TranscriptVersion? in
                guard let number = MeetingStorage.transcriptNumber(name) else { return nil }
                let modified = (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date
                let attempt = MeetingAttempt.latest(writing: name, in: entries)
                return TranscriptVersion(name: name, number: number, modified: modified, attempt: attempt)
            }.sorted { $0.number < $1.number }

            return MeetingFolder(
                records: records,
                directory: directory,
                names: names,
                startedAt: started ?? MeetingStorage.date(fromFolderName: directory.lastPathComponent),
                duration: duration,
                state: metadata?["state"] as? String,
                metadataError: metadataError,
                issues: metadata?["issues"] as? [String] ?? [],
                trigger: metadata?["trigger"] as? String,
                tracks: tracks,
                versions: versions,
                lastAttempt: lastAttempt,
                marks: names == nil ? .none : MeetingMarks.read(in: directory, links: links),
                identity: FolderIdentity.of(directory)
            )
        }
    }

    /// Which of the two roots a meeting for the helper was found in: no
    /// address of its own, as the window's rows have (two folders of one
    /// name in both roots are two meetings there); for the helper, one
    /// folder reached through both roots is one meeting (`Listing.meetings`
    /// below), and this says which root answered for it.
    enum Root: Sendable, Equatable {
        case local, chosen
    }

    /// One meeting as the helper reads it: its facts, and which root found
    /// it first.
    struct Meeting: Sendable, Equatable, Identifiable {
        let folder: MeetingFolder
        let root: Root

        var id: String { folder.directory.path }
        /// Nothing from a file this app cannot read.
        var title: String? { folder.marks.marks?.title }
        var starred: Bool { folder.marks.marks?.starred ?? false }
        /// Only the names the user set in `murmurly.json`; empty when none.
        var speakers: [MeetingAttempt.Source: String] { folder.marks.marks?.speakers ?? [:] }
        /// By number: `folder.versions` is sorted by it already.
        var latest: TranscriptVersion? { folder.versions.last }
        var completeness: LastAttempt { folder.lastAttempt }
        var readable: Bool { folder.names != nil }
    }

    /// A meeting-named entry left out because it is itself a link, in
    /// `refuse`, with why.
    struct SkippedFolder: Sendable, Equatable {
        let url: URL
        let reason: String
    }

    enum RootState: Sendable, Equatable {
        case read
        /// A chosen folder that is not there: its meetings are not shown.
        case unavailable
        /// Could not be listed.
        case failed(String)
    }

    /// The meetings of both roots, for the helper: no byte counts, no sound,
    /// no deletions, nothing of the Trash or the audio rule — only what
    /// `MeetingFolder` reads.
    struct Listing: Sendable, Equatable {
        /// No duplicates: the same folder reached through both roots (the
        /// chosen one a link to the local one, say) is one meeting, the
        /// local root's reading of it; a folder without an identity is never
        /// merged. Newest first by when it started, then by folder name.
        let meetings: [Meeting]
        let local: RootState
        let chosen: RootState?
        let skipped: [SkippedFolder]
    }

    /// One root's own meetings, read on their own — never bundled with the
    /// other root's read, so a caller (the helper's `listMeetings`) can give
    /// each root its own time budget. `as place:` tags every meeting found,
    /// same as `meetings(local:chosen:links:records:)` below, which is built
    /// out of this and `combine(local:chosen:)`.
    struct RootRead: Sendable {
        let found: [(identity: FolderIdentity?, meeting: Meeting)]
        let state: RootState
        let skipped: [SkippedFolder]
    }

    static func readRoot(_ root: URL, as place: Root, links: Links, records: MeetingFolder.Records = .summary) -> RootRead {
        let folders: [URL]
        var skipped: [SkippedFolder] = []
        do {
            let result = try MeetingStorage.meetingFolders(in: root, links: links)
            folders = result.folders
            skipped = result.skipped.map { SkippedFolder(url: $0.0, reason: $0.1) }
        } catch {
            return RootRead(found: [], state: .failed(error.localizedDescription), skipped: [])
        }
        var found: [(identity: FolderIdentity?, meeting: Meeting)] = []
        for folder in folders {
            autoreleasepool {
                let info = MeetingFolder.read(folder, links: links, records: records)
                found.append((info.identity, Meeting(folder: info, root: place)))
            }
        }
        return RootRead(found: found, state: .read, skipped: skipped)
    }

    /// `local`'s own read, and `chosen`'s when given: the same folder
    /// reached through both (the chosen one a link to the local one, say) is
    /// one meeting, the local root's reading of it — the rule
    /// `meetings(local:chosen:links:records:)` below has always had, now
    /// shared with a caller that read each root separately.
    static func combine(local: RootRead, chosen: RootRead?) -> Listing {
        var found = local.found
        var skipped = local.skipped
        if let chosen {
            found += chosen.found
            skipped += chosen.skipped
        }
        var seen: Set<FolderIdentity> = []
        var meetings: [Meeting] = []
        for (identity, meeting) in found {
            if let identity {
                guard !seen.contains(identity) else { continue }
                seen.insert(identity)
            }
            meetings.append(meeting)
        }
        meetings.sort { lhs, rhs in
            let left = lhs.folder.startedAt ?? .distantPast
            let right = rhs.folder.startedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.folder.directory.lastPathComponent > rhs.folder.directory.lastPathComponent
        }
        return Listing(meetings: meetings, local: local.state, chosen: chosen?.state, skipped: skipped)
    }

    /// `local` and, when given, `chosen`. A root that cannot be listed is
    /// `.failed`, never an empty list: only a root proven absent (no folder
    /// there yet) reads as no meetings. The copies-of-transcripts folder is
    /// never read here and never given as either root. `records` is
    /// `.summary` by default: this function is the helper's own, and the
    /// window never calls it.
    static func meetings(local: URL, chosen: URL?, links: Links, records: MeetingFolder.Records = .summary) -> Listing {
        let localRead = readRoot(local, as: .local, links: links, records: records)
        var chosenRead: RootRead?
        if let chosen {
            chosenRead = MeetingStorage.isAvailable(chosen)
                ? readRoot(chosen, as: .chosen, links: links, records: records)
                : RootRead(found: [], state: .unavailable, skipped: [])
        }
        return combine(local: localRead, chosen: chosenRead)
    }

    /// One meeting by its root and folder name, without listing every
    /// meeting: `transcript <id>` needs this one folder, never the whole
    /// listing. Always `links: .refuse`: a meeting folder, or a file inside
    /// it, that is itself a link is never opened by the helper. `nil` for
    /// anything that is not exactly this meeting — a name the listing would
    /// also reject (case, hidden), a root proven absent, or — for `.chosen`
    /// — the same folder the local root already answers for. Throws
    /// `ReadError.link` for a folder that is itself a link — never silently
    /// `nil`, so a caller that must tell the two apart (`runTranscript`) can.
    /// Throws (an `NSError`) when the root exists but cannot be listed (a
    /// permission error, say): the same rule as
    /// `MeetingStorage.meetingFolders(in:)`, so "not found" and "could not
    /// be read" are never folded into one `nil`.
    static func meeting(root: Root, folderName: String, local: URL, chosen: URL?, records: MeetingFolder.Records = .full) throws -> Meeting? {
        let base: URL
        switch root {
        case .local:
            base = local
        case .chosen:
            guard let chosen, MeetingStorage.isAvailable(chosen) else { return nil }
            base = chosen
        }
        var info = stat()
        if stat(base.path, &info) != 0 {
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: base.path])
            }
            return nil
        }
        // APFS is case-insensitive by default: `lstat` alone would find
        // "… meeting" for an id spelled "… Meeting", which the listing never
        // shows. The folder's exact, byte-for-byte name must be in the
        // directory's own listing first.
        let names = try MeetingStorage.rootChildNames(of: base)
        guard names.contains(folderName) else { return nil }

        let folderURL = base.appendingPathComponent(folderName, isDirectory: true)
        switch MeetingStorage.classify(folderURL) {
        case .meeting: break
        case .link: throw Archive.ReadError.link(folderURL.path)
        case .other: return nil
        }

        if root == .chosen, let localIdentity = FolderIdentity.of(local.appendingPathComponent(folderName, isDirectory: true)),
           let chosenIdentity = FolderIdentity.of(folderURL), localIdentity == chosenIdentity {
            return nil
        }

        let folder = MeetingFolder.read(folderURL, links: .refuse, records: records)
        return Meeting(folder: folder, root: root)
    }

    /// The newest transcript of `meeting`, timed by its record and with the
    /// user's names in place of the labels where it matches exactly — the
    /// same rule the window's card shows. Nil when the meeting has no
    /// transcript, or when `query` is given and a cheap check of the raw
    /// text (`MeetingSearch.matches`, the window's own fold rule) rules out
    /// a match before any parsing — never when that check cannot be trusted
    /// (`Archive.quickCheckApplies`). A file that cannot be read, or is not
    /// valid UTF-8, throws: never silently shown as fewer lines than it has.
    static func transcript(of meeting: Meeting, links: Links, containing query: String? = nil) throws -> MeetingTranscript? {
        guard let latest = meeting.latest else { return nil }
        let url = meeting.folder.directory.appendingPathComponent(latest.name)
        let data = try Archive.read(url, links: links)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReadError.unreadable(url.path, "not valid UTF-8")
        }
        if let query, quickCheckApplies(to: query), !MeetingSearch.matches(query, text) {
            return nil
        }
        let attempt: MeetingAttempt?
        if meeting.folder.records == .summary {
            // The listing's own record has no `lines`: read this one
            // meeting's records again, in full, for exact timing and names.
            let entries = (try? MeetingAttempt.entries(in: meeting.folder.directory, links: links)) ?? []
            attempt = MeetingAttempt.latest(writing: latest.name, in: entries)
        } else {
            attempt = latest.attempt
        }
        return MeetingTranscript.parse(text).timed(by: attempt).named(meeting.speakers)
    }

    /// Whether `query` is found in each meeting's newest transcript, by the
    /// window's own rule (`MeetingSearch`, the lines' own words only): a
    /// meeting without a transcript never matches; one whose transcript
    /// cannot be read is an error, not "no match".
    static func search(_ query: String, in meetings: [Meeting], links: Links) -> [(meeting: Meeting, matched: Swift.Result<Bool, Error>)] {
        meetings.map { meeting in
            do {
                guard let transcript = try transcript(of: meeting, links: links, containing: query) else {
                    return (meeting, .success(false))
                }
                return (meeting, .success(MeetingSearch.matches(query, in: transcript.layout)))
            } catch {
                return (meeting, .failure(error))
            }
        }
    }
}
