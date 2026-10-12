import Foundation
import XCTest
@testable import Murmurly

/// Moving a finished meeting folder and copying its transcript, on real files:
/// what reaches the target, what stays behind, and the states a killed move
/// leaves. `mounts` stands in for `/Volumes`, which a test cannot write to.
final class MeetingMoveTests: XCTestCase {
    private var base: URL!
    private var local: URL!
    private var target: URL!
    private var mounts: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-move-\(UUID().uuidString)", isDirectory: true)
        local = base.appendingPathComponent("Meetings", isDirectory: true)
        target = base.appendingPathComponent("Disk/Meetings", isDirectory: true)
        mounts = base.appendingPathComponent("Volumes", isDirectory: true)
        for folder in [local!, target!, mounts!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        // Recursively, folders before what is in them: a test locks some, and
        // a listing cannot see past a locked folder.
        let unlock = Process()
        unlock.executableURL = URL(fileURLWithPath: "/bin/chmod")
        unlock.arguments = ["-R", "u+rwx", base.path]
        try? unlock.run()
        unlock.waitUntilExit()
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Where the target is

    /// Missing, a file, or a folder under the mounts folder on the mounts
    /// folder's own volume (a mount point left while its disk was away): not
    /// available, and nothing is created there, the folder nor its parents.
    func testUnavailableTargetsCreateNothingAndKeepTheLocalFolder() throws {
        let folder = try meeting("2026-10-07 10-00-00 Meeting")
        let before = try MeetingAudio.digests(of: folder)
        let missing = base.appendingPathComponent("Gone/Disk/Meetings", isDirectory: true)
        let file = base.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        let stale = mounts.appendingPathComponent("T7/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        XCTAssertTrue(MeetingStorage.isAvailable(target, mounts: mounts))
        for unavailable in [missing, file, stale] {
            XCTAssertFalse(MeetingStorage.isAvailable(unavailable, mounts: mounts), unavailable.path)
            XCTAssertThrowsError(try MeetingStorage.move(folder, into: unavailable, localRoot: local, mounts: mounts)) {
                XCTAssertEqual($0 as? MeetingStorage.DeliveryFailure, .unavailable(unavailable.path))
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Gone").path))
        XCTAssertEqual(try names(in: stale), [])
        XCTAssertEqual(try MeetingAudio.digests(of: folder), before)
    }

    func testMoveCopiesChecksRenamesAndRemovesTheLocalFolder() throws {
        let folder = try meeting("2026-10-07 10-00-01 Meeting")
        try Data("finder".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        let before = try MeetingAudio.digests(of: folder)

        let place = try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts)

        XCTAssertEqual(place.lastPathComponent, folder.lastPathComponent)
        XCTAssertEqual(try MeetingAudio.digests(of: place), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try names(in: target), [folder.lastPathComponent], "no partial copy left")
        XCTAssertEqual(try names(in: local), [], "no local copy left, not even a hidden one")
        let moved = try MeetingTranscriber.Folder.inspect(place)
        XCTAssertEqual(moved.microphone?.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent)
    }

    /// A file the copy cannot read: the half copy goes, the local folder stays.
    func testFailedCopyLeavesNoPartialAndKeepsTheLocalFolder() throws {
        let folder = try meeting("2026-10-07 10-00-02 Meeting")
        let locked = folder.appendingPathComponent("transcript.md")
        try Data("# Созвон".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        XCTAssertThrowsError(try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts))

        XCTAssertEqual(try names(in: target), [])
        XCTAssertEqual(try names(in: local), [folder.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
    }

    /// Killed between the rename and the removal: the same folder is already
    /// there, with what exFAT adds, and the local one goes. Another folder of
    /// that name is never replaced, nor is a second copy made beside it.
    func testNameTakenBySameFolderRemovesTheLocalOneAndByAnotherKeepsBoth() throws {
        let same = try meeting("2026-10-07 10-00-03 Meeting")
        try FileManager.default.copyItem(at: same, to: target.appendingPathComponent(same.lastPathComponent))
        try Data("apple double".utf8).write(to: target.appendingPathComponent(same.lastPathComponent).appendingPathComponent("._metadata.json"))

        let place = try MeetingStorage.move(same, into: target, localRoot: local, mounts: mounts)

        XCTAssertFalse(FileManager.default.fileExists(atPath: same.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: place.appendingPathComponent("system.caf").path))

        let other = try meeting("2026-10-07 10-00-04 Meeting")
        let theirs = target.appendingPathComponent(other.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("another recording".utf8).write(to: theirs.appendingPathComponent("system.caf"))
        let ours = try MeetingAudio.digests(of: other)
        let before = try MeetingAudio.digests(of: theirs)

        XCTAssertThrowsError(try MeetingStorage.move(other, into: target, localRoot: local, mounts: mounts)) {
            XCTAssertEqual($0 as? MeetingStorage.DeliveryFailure, .conflict(other.lastPathComponent))
            XCTAssertEqual($0.localizedDescription, "the meetings folder already has a different “\(other.lastPathComponent)”")
        }
        XCTAssertEqual(try MeetingAudio.digests(of: other), ours)
        XCTAssertEqual(try MeetingAudio.digests(of: theirs), before)
        XCTAssertEqual(try names(in: target), [same.lastPathComponent, other.lastPathComponent].sorted())
    }

    /// Killed between the rename and the removal, and the user then edited
    /// the local transcript: same length, other bytes. The local folder holds
    /// the only copy of that edit and stays, and so does the earlier copy.
    func testNameTakenByAnEarlierCopyOfAnEditedFolderKeepsBoth() throws {
        let folder = try meeting("2026-10-07 10-00-09 Meeting")
        let transcript = folder.appendingPathComponent("transcript.md")
        try Data("# Созвон\n\nверсия 1".utf8).write(to: transcript)
        let earlier = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: earlier)
        try Data("# Созвон\n\nверсия 2".utf8).write(to: transcript)
        let ours = try MeetingAudio.digests(of: folder)
        let theirs = try MeetingAudio.digests(of: earlier)

        XCTAssertThrowsError(try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts)) {
            XCTAssertEqual($0 as? MeetingStorage.DeliveryFailure, .conflict(folder.lastPathComponent))
        }

        XCTAssertEqual(try MeetingAudio.digests(of: folder), ours)
        XCTAssertEqual(try MeetingAudio.digests(of: earlier), theirs)
        XCTAssertEqual(try names(in: local), [folder.lastPathComponent])
    }

    /// A local folder that cannot be read in full is never taken for the copy
    /// already in the meetings folder: a subfolder that cannot be listed, or
    /// whose files cannot be looked at, is a difference, not a pass.
    func testLocalFolderThatCannotBeReadInFullIsNeverTakenForItsCopy() throws {
        for (index, mode) in [0o000, 0o444].enumerated() {
            let folder = try meeting("2026-10-07 10-00-1\(index) Meeting")
            let notes = folder.appendingPathComponent("notes", isDirectory: true)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            try Data("заметка".utf8).write(to: notes.appendingPathComponent("a.md"))
            try FileManager.default.copyItem(at: folder, to: target.appendingPathComponent(folder.lastPathComponent))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: notes.path)

            XCTAssertThrowsError(
                try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts), "mode \(mode)"
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "mode \(mode)")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
            XCTAssertEqual(try? names(in: notes), ["a.md"], "mode \(mode)")
        }
        XCTAssertEqual(try names(in: local), ["2026-10-07 10-00-10 Meeting", "2026-10-07 10-00-11 Meeting"])
    }

    func testCheckIgnoresWhatTheTargetAddsButNotWhatItLacks() throws {
        let folder = try meeting("2026-10-07 10-00-05 Meeting")
        let copy = base.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: copy)
        try Data("x".utf8).write(to: copy.appendingPathComponent("._system.caf"))
        try Data("x".utf8).write(to: copy.appendingPathComponent(".DS_Store"))

        XCTAssertNil(MeetingStorage.difference(of: folder, in: copy))

        let metadata = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        try Data("short".utf8).write(to: copy.appendingPathComponent("metadata.json"))
        XCTAssertEqual(
            MeetingStorage.difference(of: folder, in: copy),
            "“metadata.json”: 5 bytes instead of \(metadata.count)"
        )
        try metadata.write(to: copy.appendingPathComponent("metadata.json"))
        try FileManager.default.removeItem(at: copy.appendingPathComponent("system.caf"))
        XCTAssertEqual(MeetingStorage.difference(of: folder, in: copy), "“system.caf” is missing")
    }

    /// What a killed move leaves: a hidden partial copy at the target and a
    /// hidden local folder on its way out. Both are removed; nothing else is.
    func testLeftoversOfKilledMovesAreRemovedAndNothingElse() throws {
        let partial = target.appendingPathComponent(".2026-10-07 09-00-00 Meeting.partial-\(UUID().uuidString)", isDirectory: true)
        let removing = local.appendingPathComponent(".2026-10-07 09-00-01 Meeting.removing", isDirectory: true)
        let foreignTarget = target.appendingPathComponent(".hidden-notes", isDirectory: true)
        let foreignLocal = local.appendingPathComponent(".hidden-notes", isDirectory: true)
        for folder in [partial, removing, foreignTarget, foreignLocal] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("system.caf"))
        }
        let folder = try meeting("2026-10-07 10-00-06 Meeting")

        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: local, moving: true).map(\.lastPathComponent),
            [folder.lastPathComponent]
        )
        XCTAssertEqual(try names(in: local), [".hidden-notes", folder.lastPathComponent], "the scan removed its own leftover")
        _ = try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts)

        XCTAssertEqual(try names(in: local), [".hidden-notes"])
        XCTAssertEqual(try names(in: target), [".hidden-notes", folder.lastPathComponent])
    }

    /// Only the exact hidden names this code gives are removed:
    /// `.<meeting>.partial-<UUID>` in the meetings folder, which may be
    /// shared with other programs and people, and `.<meeting>.removing` here.
    /// Anything else, however alike, stays.
    func testOnlyOwnLeftoverNamesAreRemovedAndAlikeOnesStay() throws {
        let own = [
            target.appendingPathComponent(".2026-10-07 09-00-00 Meeting.partial-\(UUID().uuidString)"),
            target.appendingPathComponent(".2026-10-07 09-00-00 Meeting-2.partial-\(UUID().uuidString)"),
            local.appendingPathComponent(".2026-10-07 09-00-01 Meeting.removing"),
        ]
        let foreignTarget = [
            ".backup.partial-2026-10-07",
            ".x.partial-abc",
            ".notes.partial-\(UUID().uuidString)",
            ".2026-10-07 09-00-00 Meeting.partial-latest",
            ".2026-10-07 09-00-00 Meeting copy.partial-\(UUID().uuidString)",
        ]
        let foreignLocal = [".notes.removing", ".Meeting.removing", ".2026-10-07 09-00-01 Meeting old.removing"]
        let all = own + foreignTarget.map { target.appendingPathComponent($0) }
            + foreignLocal.map { local.appendingPathComponent($0) }
        for folder in all {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("system.caf"))
        }
        let folder = try meeting("2026-10-07 10-00-12 Meeting")

        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: local, moving: true).map(\.lastPathComponent),
            [folder.lastPathComponent]
        )
        _ = try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts)

        XCTAssertEqual(try names(in: local), foreignLocal.sorted())
        XCTAssertEqual(try names(in: target), (foreignTarget + [folder.lastPathComponent]).sorted())
    }

    /// Names that start with the marker or the suffix itself belong to
    /// someone else: they stay, and neither the scan nor the move trips over
    /// them. A range built backwards there once stopped the app on every move
    /// into such a folder.
    func testNamesThatStartWithTheMarkerStayAndTheMoveGoesOn() throws {
        let foreignTarget = [".partial-", ".partial-backup", ".partial-\(UUID().uuidString)", "..partial-\(UUID().uuidString)"]
        let foreignLocal = [".removing", "..removing", ". Meeting.removing"]
        let all = foreignTarget.map { target.appendingPathComponent($0) }
            + foreignLocal.map { local.appendingPathComponent($0) }
        for folder in all {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("system.caf"))
        }
        let folder = try meeting("2026-10-07 10-00-13 Meeting")

        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: local, moving: true).map(\.lastPathComponent),
            [folder.lastPathComponent]
        )
        _ = try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts)

        XCTAssertEqual(try names(in: local), foreignLocal.sorted())
        XCTAssertEqual(try names(in: target), (foreignTarget + [folder.lastPathComponent]).sorted())
        for name in foreignTarget { XCTAssertFalse(MeetingStorage.isOwnPartialCopyName(name), name) }
        for name in foreignLocal { XCTAssertFalse(MeetingStorage.isOwnRemovingName(name), name) }
        XCTAssertTrue(MeetingStorage.isOwnPartialCopyName(".2026-10-07 09-00-00 Meeting-2.partial-\(UUID().uuidString)"))
        XCTAssertTrue(MeetingStorage.isOwnRemovingName(".2026-10-07 09-00-01 Meeting.removing"))
    }

    /// The byte check reads 1 MB blocks: a copy equal to the end passes, and
    /// one byte changed past the first block boundary, or the very last one,
    /// is found, where sizes alone see nothing.
    func testByteCheckFindsADifferencePastTheFirstBlock() throws {
        let size = 3 * (1 << 20) + 123
        var state: UInt32 = 7
        let bytes = (0..<size).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        let original = base.appendingPathComponent("original", isDirectory: true)
        let copy = base.appendingPathComponent("copy", isDirectory: true)
        for folder in [original, copy] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(bytes).write(to: folder.appendingPathComponent("system.caf"))
        }

        XCTAssertNil(MeetingStorage.difference(of: original, in: copy, comparingBytes: true))
        for offset in [(1 << 20) + 17, size - 1] {
            var changed = bytes
            changed[offset] ^= 0xFF
            try Data(changed).write(to: copy.appendingPathComponent("system.caf"))
            XCTAssertEqual(
                MeetingStorage.difference(of: original, in: copy, comparingBytes: true),
                "“system.caf”: different contents", "offset \(offset)"
            )
            XCTAssertNil(MeetingStorage.difference(of: original, in: copy), "offset \(offset): sizes match")
        }
    }

    // MARK: - Transcript copy

    func testCopyNamesKeepSecondsAndTheTranscriptNumber() {
        XCTAssertEqual(
            MeetingStorage.transcriptCopyName(folder: "2026-10-02 12-09-22 Meeting", transcript: "transcript.md"),
            "2026-10-02 12-09-22 Meeting.md"
        )
        XCTAssertEqual(
            MeetingStorage.transcriptCopyName(folder: "2026-10-02 12-09-50 Meeting", transcript: "transcript 2.md"),
            "2026-10-02 12-09-50 Meeting 2.md"
        )
        XCTAssertEqual(
            MeetingStorage.transcriptCopyName(folder: "2026-10-02 12-09-50 Meeting-2", transcript: "transcript.md"),
            "2026-10-02 12-09-50 Meeting-2.md"
        )
        XCTAssertEqual(
            MeetingStorage.transcriptCopyName(folder: "Планёрка", transcript: "transcript.md"),
            "Планёрка Meeting.md"
        )
    }

    /// The junction "string catalog → copy name": the copy's name is a file
    /// name, the same in every interface language. The app's Russian
    /// localization must carry no word for it; when it did, the name followed
    /// the language. Tests run in English, so the Russian side is read from
    /// the app's own ru.lproj.
    func testCopyNameIsTheSameInEveryInterfaceLanguage() throws {
        XCTAssertEqual(
            MeetingStorage.transcriptCopyName(folder: "2026-10-02 12-09-22 Meeting", transcript: "transcript.md"),
            "2026-10-02 12-09-22 Meeting.md"
        )
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ru", ofType: "lproj"), "no Russian in the app")
        let russian = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(
            russian.localizedString(forKey: "Meeting", value: nil, table: nil), "Meeting",
            "the copy-name word is translated, so the file name would change with the language"
        )
    }

    /// An existing note is never replaced: the user may have edited it.
    func testTranscriptCopyNeverOverwritesAndNeedsAnAvailableFolder() throws {
        let notes = base.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let folder = try meeting("2026-10-07 10-00-07 Meeting")
        let transcript = folder.appendingPathComponent("transcript.md")
        try Data("# Созвон\n\nтекст".utf8).write(to: transcript)

        let copy = try MeetingStorage.copyTranscript(transcript, of: folder, into: notes, mounts: mounts)
        XCTAssertEqual(copy.lastPathComponent, "2026-10-07 10-00-07 Meeting.md")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: transcript))

        try Data("правка пользователя".utf8).write(to: copy)
        XCTAssertThrowsError(try MeetingStorage.copyTranscript(transcript, of: folder, into: notes, mounts: mounts)) {
            XCTAssertEqual($0 as? MeetingStorage.DeliveryFailure, .alreadyThere("2026-10-07 10-00-07 Meeting.md"))
        }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "правка пользователя")
        XCTAssertEqual(try names(in: notes), ["2026-10-07 10-00-07 Meeting.md"], "no temporary file left")

        let gone = base.appendingPathComponent("Vault/Meetings", isDirectory: true)
        XCTAssertThrowsError(try MeetingStorage.copyTranscript(transcript, of: folder, into: gone, mounts: mounts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Vault").path))
    }

    // MARK: - Where a folder is now

    func testCurrentLocationIsLocalWhileThereAndThenInTheMeetingsFolder() throws {
        let folder = try meeting("2026-10-07 10-00-08 Meeting")
        XCTAssertEqual(RecordingsStore.currentLocation(of: folder, meetingsFolder: target), folder)
        XCTAssertEqual(RecordingsStore.currentLocation(of: folder, meetingsFolder: nil), folder)

        _ = try MeetingStorage.move(folder, into: target, localRoot: local, mounts: mounts)

        XCTAssertEqual(
            RecordingsStore.currentLocation(of: folder, meetingsFolder: target).path,
            target.appendingPathComponent(folder.lastPathComponent).path
        )
        XCTAssertEqual(RecordingsStore.currentLocation(of: folder, meetingsFolder: nil), folder)
    }

    // MARK: - Helpers

    private func meeting(_ name: String) throws -> URL {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.3, seed: 1)]
        return try MeetingAudio.folder(name, in: local, microphone: samples, system: samples)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

}
