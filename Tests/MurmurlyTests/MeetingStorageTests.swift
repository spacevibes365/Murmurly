import AVFoundation
import CryptoKit
import XCTest
@testable import Murmurly

/// Tracks and metadata as `SystemAudioCapture` leaves them, and the in-between
/// states a killed run leaves behind. Everything is read back from disk.
final class MeetingStorageTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Compression

    func testBothTracksBecomeCheckedALACAndTheGainIsRecorded() async throws {
        var microphone = MeetingAudio.noise(count: 48_000, amplitude: 0.5, seed: 1)
        microphone[1_000] = 1.6
        microphone[30_000] = -1.2
        let system = MeetingAudio.noise(count: 48_000, amplitude: 0.9, seed: 2)
        let folder = try MeetingAudio.folder("2026-10-06 10-00-00 Meeting", in: root, microphone: [microphone], system: [system])

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.compressed, ["microphone.caf", "system.caf"])
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a"])
        let metadata = try JSONDecoder().decode(
            MeetingMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(metadata.segments.first?.mic, "microphone.m4a")
        XCTAssertEqual(metadata.segments.first?.system, "system.m4a")
        XCTAssertNil(metadata.segments.first?.systemGain, "a track already in range is not scaled")
        let gain = try XCTUnwrap(metadata.segments.first?.micGain.map { Float($0) })
        XCTAssertLessThanOrEqual(1.6 * gain, 1)
        XCTAssertEqual(gain, 1 / 1.6, accuracy: 1e-6)
        // Everything else the stop wrote is still there.
        XCTAssertEqual(metadata.state, "done")
        XCTAssertEqual(metadata.endedAt, "2026-10-06T10:01:00Z")
        XCTAssertEqual(metadata.trigger, "us.zoom.xos")
        XCTAssertEqual(metadata.segments.first?.frames, 48_000)

        let format = try MeetingAudio.dataFormat(of: folder.appendingPathComponent("microphone.m4a"))
        XCTAssertEqual(format.mFormatID, kAudioFormatAppleLossless)
        XCTAssertEqual(format.mFormatFlags, kAppleLosslessFormatFlag_24BitSourceData)
        XCTAssertEqual(format.mSampleRate, 48_000)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: gain)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("system.m4a"), equals: [system], gain: 1)

        let inspected = try MeetingTranscriber.Folder.inspect(folder)
        XCTAssertEqual(inspected.microphone?.lastPathComponent, "microphone.m4a")
        XCTAssertEqual(inspected.microphoneGain, gain)
        XCTAssertEqual(inspected.systemGain, 1)
    }

    /// July recordings: no `endedAt` (so `MeetingMetadata` cannot read them),
    /// `frames` from the old write-queue count and a microphone of another
    /// length, no `micFrames`.
    func testJulyMetadataWithoutEndedAtIsCompressedWithEveryKeyKept() async throws {
        let folder = root.appendingPathComponent("2026-07-14 19-40-35 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let microphone = MeetingAudio.noise(count: 47_000, amplitude: 0.3, seed: 3)
        let system = MeetingAudio.noise(count: 48_000, amplitude: 0.3, seed: 4)
        try MeetingAudio.write([microphone], to: folder.appendingPathComponent("microphone.caf"))
        try MeetingAudio.write([system], to: folder.appendingPathComponent("system.caf"))
        let july = """
        {"sampleRate":48000,"segments":[{"frames":48000,"index":0,"mic":"microphone.caf","system":"system.caf"}],\
        "startedAt":"2026-07-14T16:40:37Z","state":"done"}
        """
        try Data(july.utf8).write(to: folder.appendingPathComponent("metadata.json"))

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        ) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sampleRate", "segments", "startedAt", "state"])
        XCTAssertEqual(object["startedAt"] as? String, "2026-07-14T16:40:37Z")
        XCTAssertEqual(object["sampleRate"] as? Int, 48_000)
        let segment = try XCTUnwrap((object["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(segment.keys), ["frames", "index", "mic", "system"])
        XCTAssertEqual(segment["frames"] as? Int, 48_000)
        XCTAssertEqual(segment["mic"] as? String, "microphone.m4a")
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: 1)
        // M1 still reads it.
        let inspected = try MeetingTranscriber.Folder.inspect(folder)
        XCTAssertEqual(inspected.system?.lastPathComponent, "system.m4a")
    }

    /// The gain is plain 1/peak: rounded to nearest, peak × (1/peak) never
    /// exceeds 1 for a normal float, so no scaled sample passes full scale.
    /// The sweep pins that property; the folder shows the top of the range.
    func testPeaksUpToSixteenFitAfterScalingAndAboveAreKept() async throws {
        var state: UInt32 = 1
        for index in 0..<1_000_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let peak = index < 16 ? Float(index + 1) : 1 + 15 * Float(state >> 8 | 1) / Float(1 << 24)
            XCTAssertLessThanOrEqual(peak * (1 / peak), 1, "peak \(peak)")
        }
        var top = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 5)
        top[12_000] = MeetingStorage.maximumPeak
        var over = top
        over[12_000] = MeetingStorage.maximumPeak.nextUp
        let folder = try MeetingAudio.folder("2026-10-06 11-00-00 Meeting", in: root, microphone: [top], system: [over])

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.compressed, ["microphone.caf"])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].hasPrefix("others: peak ×16"), result.issues[0])
        XCTAssertEqual(try MeetingTranscriber.Folder.inspect(folder).microphoneGain, 1 / 16)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [top], gain: 1 / 16)
    }

    func testGlitchPeakAndNonFiniteSamplesKeepTheCAF() async throws {
        var glitch = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 6)
        glitch[100] = 20
        var broken = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 7)
        broken[23_999] = .nan
        let folder = try MeetingAudio.folder("2026-10-06 12-00-00 Meeting", in: root, microphone: [glitch], system: [broken])
        let before = try Data(contentsOf: folder.appendingPathComponent("microphone.caf"))

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.compressed, [])
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(result.issues[0].hasPrefix("microphone: peak ×20"), result.issues[0])
        XCTAssertTrue(result.issues[0].contains("audio glitch"), result.issues[0])
        XCTAssertTrue(result.issues[1].hasPrefix("others: samples that are not numbers"), result.issues[1])
        XCTAssertTrue(result.issues.allSatisfy { $0.hasSuffix("kept as CAF") })
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.caf", "system.caf"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("microphone.caf")), before)
        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: root, moving: false).map(\.lastPathComponent),
            [folder.lastPathComponent],
            "tried again by the next scan"
        )
    }

    func testStereoMicrophoneKeepsBothChannels() async throws {
        let left = MeetingAudio.noise(count: 30_000, amplitude: 0.5, seed: 8)
        var right = MeetingAudio.noise(count: 30_000, amplitude: 0.2, seed: 9)
        right[7] = 1.3
        let system = MeetingAudio.noise(count: 30_000, amplitude: 0.5, seed: 10)
        let folder = try MeetingAudio.folder("2026-10-06 13-00-00 Meeting", in: root, microphone: [left, right], system: [system])

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.issues, [])
        let microphone = folder.appendingPathComponent("microphone.m4a")
        XCTAssertEqual(try MeetingAudio.dataFormat(of: microphone).mChannelsPerFrame, 2)
        let gain = try XCTUnwrap(MeetingTranscriber.Folder.inspect(folder).microphoneGain)
        XCTAssertLessThan(gain, 1)
        try MeetingAudio.assertDecoded(microphone, equals: [left, right], gain: gain)
    }

    /// The check is what lets the CAF go, so it is tested on its own: one
    /// 24-bit step passes (a full-scale +1.0 is stored as 8388607), two steps
    /// or a missing frame do not.
    func testCheckAcceptsOneStepAndRejectsTwoStepsOrAShorterFile() throws {
        var samples = MeetingAudio.noise(count: 20_000, amplitude: 0.5, seed: 11)
        samples[500] = 1
        samples[501] = -1
        let source = root.appendingPathComponent("source.caf")
        try MeetingAudio.write([samples], to: source)
        let m4a = root.appendingPathComponent("copy.m4a")
        try DictationHistoryStore.encodeAppleLossless(from: source, to: m4a)

        XCTAssertNoThrow(try MeetingStorage.verify(m4a, against: source, gain: 1))

        var changed = samples
        changed[9_000] += 2 * MeetingStorage.tolerance
        let other = root.appendingPathComponent("changed.caf")
        try MeetingAudio.write([changed], to: other)
        XCTAssertThrowsError(try MeetingStorage.verify(m4a, against: other, gain: 1)) {
            XCTAssertEqual($0 as? MeetingStorage.Rejection, .mismatch("frame 9,000, channel 1"))
        }

        let shorter = root.appendingPathComponent("shorter.caf")
        try MeetingAudio.write([Array(samples.dropLast(10))], to: shorter)
        XCTAssertThrowsError(try MeetingStorage.verify(m4a, against: shorter, gain: 1)) {
            XCTAssertEqual($0 as? MeetingStorage.Rejection, .mismatch("20,000 frames instead of 19,990"))
        }
    }

    // MARK: - Recovery from the files alone

    func testKilledRunsAreFinishedFromTheFilesAlone() async throws {
        let microphone = MeetingAudio.noise(count: 24_000, amplitude: 0.5, seed: 12)
        let system = MeetingAudio.noise(count: 24_000, amplitude: 0.5, seed: 13)

        // Killed while writing: a hidden partial.
        let writing = try MeetingAudio.folder("2026-10-06 14-00-01 Meeting", in: root, microphone: [microphone], system: [system])
        try Data("half".utf8).write(to: writing.appendingPathComponent(".microphone.partial.m4a"))
        // Killed after the rename, before the commit: an m4a the metadata does not name.
        let renamed = try MeetingAudio.folder("2026-10-06 14-00-02 Meeting", in: root, microphone: [microphone], system: [system])
        try Data("not audio".utf8).write(to: renamed.appendingPathComponent("microphone.m4a"))
        // Killed after the commit, before the CAF was removed.
        let committed = try MeetingAudio.folder("2026-10-06 14-00-03 Meeting", in: root, microphone: [microphone], system: [system])
        _ = await MeetingStorage.compress(committed)
        try MeetingAudio.write([microphone], to: committed.appendingPathComponent("microphone.caf"))
        let committedM4A = try Data(contentsOf: committed.appendingPathComponent("microphone.m4a"))
        // Someone else's files are not ours to remove.
        for name in ["notes.m4a", ".other.m4a", "talk.partial.m4a"] {
            try Data(name.utf8).write(to: renamed.appendingPathComponent(name))
        }

        for folder in [writing, renamed, committed] {
            let result = await MeetingStorage.compress(folder)
            XCTAssertEqual(result.issues, [], folder.lastPathComponent)
        }

        XCTAssertEqual(try names(in: writing), ["metadata.json", "microphone.m4a", "system.m4a"])
        XCTAssertEqual(
            try names(in: renamed),
            [".other.m4a", "metadata.json", "microphone.m4a", "notes.m4a", "system.m4a", "talk.partial.m4a"]
        )
        XCTAssertEqual(try names(in: committed), ["metadata.json", "microphone.m4a", "system.m4a"])
        XCTAssertEqual(try Data(contentsOf: committed.appendingPathComponent("microphone.m4a")), committedM4A)
        for folder in [writing, renamed, committed] {
            try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: 1)
        }
        XCTAssertEqual(MeetingStorage.foldersNeedingWork(in: root, moving: false), [])
    }

    /// The CAF goes only after the metadata names the m4a: when the commit
    /// fails (here metadata.json cannot be replaced), the CAF is still there
    /// and the metadata still names it; the next run finishes the job.
    func testFailedCommitKeepsTheCAF() async throws {
        let microphone = MeetingAudio.noise(count: 24_000, amplitude: 0.5, seed: 15)
        let folder = try MeetingAudio.folder("2026-10-06 14-30-00 Meeting", in: root, microphone: [microphone], system: [microphone])
        let metadata = folder.appendingPathComponent("metadata.json")
        let original = try Data(contentsOf: metadata)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: metadata.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadata.path) }

        let failed = await MeetingStorage.compress(folder)

        XCTAssertEqual(failed.compressed, [])
        XCTAssertEqual(failed.issues.count, 2)
        XCTAssertTrue(failed.issues.allSatisfy { $0.contains("couldn’t compress") }, "\(failed.issues)")
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("microphone.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadata.path)
        let finished = await MeetingStorage.compress(folder)

        XCTAssertEqual(finished.issues, [])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a"])
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: 1)
    }

    // MARK: - Which folders

    /// `metadata.json` is written only by a finished stop, so a folder without
    /// it is a recording in progress (or cut off by a crash) and stays as is.
    func testOnlyFinishedFoldersWithACAFTrackAreFound() async throws {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 14)]
        let recording = root.appendingPathComponent("2026-10-06 15-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try MeetingAudio.write(samples, to: recording.appendingPathComponent("system.caf"))
        try MeetingAudio.write(samples, to: recording.appendingPathComponent("microphone.caf"))
        let unknownState = try MeetingAudio.folder("2026-10-06 15-00-01 Meeting", in: root, microphone: samples, system: samples, state: "recording")
        let suspect = try MeetingAudio.folder("2026-10-06 15-00-02 Meeting", in: root, microphone: samples, system: samples, state: "suspect")
        let failed = try MeetingAudio.folder("2026-10-06 15-00-03 Meeting", in: root, microphone: samples, system: samples, state: "failed")
        let done = try MeetingAudio.folder("2026-10-06 15-00-04 Meeting", in: root, microphone: samples, system: samples)
        let compressed = try MeetingAudio.folder("2026-10-06 15-00-05 Meeting", in: root, microphone: samples, system: samples)
        _ = await MeetingStorage.compress(compressed)
        _ = try MeetingAudio.folder(".hidden", in: root, microphone: samples, system: samples)
        let before = try MeetingAudio.digests(of: recording)

        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: root, moving: false).map(\.lastPathComponent),
            [suspect, failed, done].map(\.lastPathComponent)
        )
        XCTAssertEqual(MeetingStorage.foldersNeedingWork(in: root.appendingPathComponent("absent"), moving: false), [])

        for folder in [recording, unknownState] {
            let result = await MeetingStorage.compress(folder)
            XCTAssertEqual(result, MeetingStorage.Result())
        }
        XCTAssertEqual(try MeetingAudio.digests(of: recording), before)
        XCTAssertEqual(try names(in: unknownState), ["metadata.json", "microphone.caf", "system.caf"])
    }

    /// A meeting is a folder named as recordings are named, with metadata or
    /// a track in it: a recording cut off before its stop counts, a folder of
    /// notes with someone's `metadata.json` does not.
    func testMeetingFoldersAreNamedOnesWithMetadataOrATrack() throws {
        let expected = try seedMixedMeetingsRoot()

        XCTAssertEqual(try MeetingStorage.meetingFolders(in: root).map(\.lastPathComponent).sorted(), expected)
        XCTAssertEqual(try MeetingStorage.meetingFolders(in: root.appendingPathComponent("absent")), [])
    }

    /// A meeting whose folder cannot be listed inside a root that can is
    /// still a meeting: it does not vanish from the list and the count.
    func testMeetingWhoseFolderCannotBeReadIsStillListed() throws {
        let readable = try MeetingAudio.folder("2026-10-06 10-00-00 Meeting", in: root, microphone: [[0, 0]], system: [[0, 0]])
        let locked = try MeetingAudio.folder("2026-10-06 11-00-00 Meeting", in: root, microphone: [[0, 0]], system: [[0, 0]])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertEqual(
            try MeetingStorage.meetingFolders(in: root).map(\.lastPathComponent).sorted(),
            [readable.lastPathComponent, locked.lastPathComponent]
        )
    }

    /// A root that cannot be listed is not an empty one.
    func testUnreadableRootThrowsInsteadOfPassingForEmpty() throws {
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try MeetingStorage.meetingFolders(in: locked))
    }

    /// Storage counts the meetings the window lists: it used to count any
    /// folder with a `metadata.json` and miss recordings cut off before
    /// their stop.
    func testStorageCountsTheMeetingsTheWindowLists() throws {
        let expected = try seedMixedMeetingsRoot()

        let snapshot = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil,
            dictationsRoot: root.appendingPathComponent("absent-dictations", isDirectory: true),
            meetingsRoot: root
        )

        XCTAssertEqual(snapshot.meetingCount, expected.count)
        XCTAssertEqual(snapshot.meetingOldest, MeetingTranscriber.Folder.date(fromFolderName: "2026-07-14 09-00-00 Meeting"))
    }

    /// The app's own files in a meeting's folder, and what it only shows:
    /// the user's notes, and nothing of Finder's bookkeeping.
    func testOwnFilesOfAMeetingAndEveryoneElses() {
        let tracks = ["mic-1.caf", "system.m4a"]
        let own = [
            "metadata.json", "murmurly.json", "system.caf", "microphone.m4a", "mic-1.caf", "mic-1.m4a",
            "transcript.md", "transcript 12.md", MeetingAttempt.fileName(number: 3),
            ".transcript-\(UUID().uuidString).tmp", ".system.partial.m4a",
        ]
        let theirs = ["tasks.md", "transcript 1.md", "transcript-notes.md", ".attempt notes", "photo.png"]

        for name in own { XCTAssertTrue(MeetingStorage.isOwnFile(name, tracks: tracks), name) }
        for name in theirs { XCTAssertFalse(MeetingStorage.isOwnFile(name, tracks: tracks), name) }
        XCTAssertTrue(MeetingStorage.isSystemFile(".DS_Store"))
        XCTAssertTrue(MeetingStorage.isSystemFile("._system.m4a"))
        XCTAssertFalse(MeetingStorage.isSystemFile("tasks.md"))
        XCTAssertEqual(["transcript.md", "transcript 2.md", "transcript 10.md", "transcript 1.md"].map(MeetingStorage.transcriptNumber), [1, 2, 10, nil])
    }

    /// murmurly.json is written only over a file proven to be this version:
    /// every other key survives, a title set to none is taken out, and any
    /// other file (no version, version 0, another type, a later version,
    /// not JSON) is left byte for byte.
    func testMarksAreWrittenOnlyOverAProvenVersionAndKeepEveryOtherKey() throws {
        let folder = root.appendingPathComponent("2026-10-15 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(MeetingMarks.fileName)
        XCTAssertEqual(MeetingMarks.read(in: folder), .none)

        try MeetingMarks.write(MeetingMarks.Change(title: .some("Планёрка"), starred: true), in: folder, expecting: FolderIdentity.of(folder))
        XCTAssertEqual(MeetingMarks.read(in: folder), .read(MeetingMarks(title: "Планёрка", starred: true)))

        try Data(#"{"version":1,"title":"Старое","starred":false,"speakers":{"microphone":"Денис"},"later":[1,2]}"#.utf8).write(to: file)
        try MeetingMarks.write(MeetingMarks.Change(title: .some(nil), starred: true), in: folder, expecting: FolderIdentity.of(folder))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["speakers"] as? [String: String], ["microphone": "Денис"])
        XCTAssertEqual(object["later"] as? [Int], [1, 2])
        XCTAssertNil(object["title"], "an empty name stays in the file")
        XCTAssertEqual(object["starred"] as? Bool, true)

        let refused: [(String, Bool)] = [
            (#"{"title":"x"}"#, false), (#"{"version":0}"#, false), (#"{"version":"1"}"#, false),
            (#"{"version":1,"starred":"yes"}"#, false), ("[1]", false), ("{broken", false),
            (#"{"version":2,"title":"из будущего"}"#, true),
        ]
        for (body, newer) in refused {
            try Data(body.utf8).write(to: file)
            switch MeetingMarks.read(in: folder) {
            case .newer: XCTAssertTrue(newer, body)
            case .unreadable: XCTAssertFalse(newer, body)
            default: XCTFail("\(body) read as \(MeetingMarks.read(in: folder))")
            }
            XCTAssertThrowsError(try MeetingMarks.write(MeetingMarks.Change(title: .some("новое"), starred: true), in: folder, expecting: FolderIdentity.of(folder)), body)
            XCTAssertEqual(try Data(contentsOf: file), Data(body.utf8), "\(body) was written over")
        }
    }

    /// The file is read once: what is checked is what is changed. A second
    /// read that failed or found another file would otherwise stand in for
    /// it, losing every other key or writing version 1 over a later one.
    /// A read that fails writes nothing; only a file that is not there is new.
    func testMarksAreReadOnceAndThatObjectIsChanged() throws {
        let folder = root.appendingPathComponent("2026-10-15 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(MeetingMarks.fileName)
        let first = #"{"version":1,"title":"Старое","speakers":{"microphone":"Денис"}}"#
        for later in ["{broken", #"{"version":2,"title":"из будущего","later":true}"#] {
            var reads = 0
            let written = try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: FolderIdentity.of(folder)) { _ in
                reads += 1
                return Data((reads == 1 ? first : later).utf8)
            }
            XCTAssertEqual(reads, 1, "the file was read again after it was checked")
            XCTAssertEqual(written, MeetingMarks(title: "Старое", starred: true, speakers: [.microphone: "Денис"]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(object["speakers"] as? [String: String], ["microphone": "Денис"], later)
            XCTAssertEqual(object["version"] as? Int, 1, later)
            XCTAssertNil(object["later"], "a file read later was written as version 1")
        }

        try Data(first.utf8).write(to: file)
        XCTAssertThrowsError(try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: FolderIdentity.of(folder)) { _ in
            throw CocoaError(.fileReadUnknown)
        })
        XCTAssertEqual(try Data(contentsOf: file), Data(first.utf8), "a failed read passed for no file")

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: FolderIdentity.of(folder)), MeetingMarks(starred: true))
    }

    /// The speakers' names live in `speakers`, changed in place: every other
    /// key, at the top and inside it, survives, whatever its type; an empty
    /// name takes its own key out, and `speakers` goes only once nothing is
    /// left in it. A `speakers` that is not an object, or a name of this
    /// version that is not a string, makes the file unreadable: nothing is
    /// written over it, the star included.
    func testSpeakerNamesKeepEveryOtherKey() throws {
        let folder = root.appendingPathComponent("2026-10-15 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(MeetingMarks.fileName)
        func object() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        }
        func names(_ change: [MeetingAttempt.Source: String?]) -> MeetingMarks.Change {
            var names = MeetingMarks.Change()
            for (source, name) in change { names.speakers.updateValue(name, forKey: source) }
            return names
        }

        try Data(#"{"version":1,"title":"Планёрка","later":{"a":1},"speakers":{"room":{"seats":[1,2]},"guest":7}}"#.utf8).write(to: file)
        let written = try MeetingMarks.write(names([.microphone: "Денис", .system: "Команда"]), in: folder, expecting: FolderIdentity.of(folder))
        XCTAssertEqual(written, MeetingMarks(title: "Планёрка", speakers: [.microphone: "Денис", .system: "Команда"]))
        XCTAssertEqual(MeetingMarks.read(in: folder), .read(written))
        var speakers = try XCTUnwrap(try object()["speakers"] as? [String: Any])
        XCTAssertEqual(speakers["microphone"] as? String, "Денис")
        XCTAssertEqual(speakers["system"] as? String, "Команда")
        XCTAssertEqual((speakers["room"] as? [String: Any])?["seats"] as? [Int], [1, 2], "a key of a later version inside speakers was lost")
        XCTAssertEqual(speakers["guest"] as? Int, 7)
        XCTAssertEqual((try object()["later"] as? [String: Any])?["a"] as? Int, 1)

        // One name out, the other changed, in one change.
        try MeetingMarks.write(names([.microphone: nil, .system: "Подрядчик"]), in: folder, expecting: FolderIdentity.of(folder))
        speakers = try XCTUnwrap(try object()["speakers"] as? [String: Any])
        XCTAssertNil(speakers["microphone"], "an empty name stays in the file")
        XCTAssertEqual(speakers["system"] as? String, "Подрядчик")
        // Both out: what is not ours stays in speakers.
        try MeetingMarks.write(names([.system: nil]), in: folder, expecting: FolderIdentity.of(folder))
        speakers = try XCTUnwrap(try object()["speakers"] as? [String: Any])
        XCTAssertEqual(Set(speakers.keys), ["room", "guest"])
        XCTAssertEqual(MeetingMarks.read(in: folder), .read(MeetingMarks(title: "Планёрка")))
        // Nothing left in speakers: the key goes.
        try Data(#"{"version":1,"speakers":{"microphone":"Денис"}}"#.utf8).write(to: file)
        try MeetingMarks.write(names([.microphone: nil]), in: folder, expecting: FolderIdentity.of(folder))
        XCTAssertNil(try object()["speakers"])
        // A change of the star leaves the names alone.
        try Data(#"{"version":1,"speakers":{"microphone":"Денис"}}"#.utf8).write(to: file)
        try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: FolderIdentity.of(folder))
        XCTAssertEqual(MeetingMarks.read(in: folder), .read(MeetingMarks(starred: true, speakers: [.microphone: "Денис"])))

        for body in [
            #"{"version":1,"speakers":["Денис"]}"#, #"{"version":1,"speakers":"Денис"}"#,
            #"{"version":1,"speakers":{"microphone":7}}"#, #"{"version":1,"speakers":{"system":{"name":"x"}}}"#,
        ] {
            try Data(body.utf8).write(to: file)
            guard case .unreadable = MeetingMarks.read(in: folder) else {
                XCTFail("\(body) read as \(MeetingMarks.read(in: folder))")
                continue
            }
            for change in [names([.microphone: "Денис"]), MeetingMarks.Change(starred: true)] {
                XCTAssertThrowsError(try MeetingMarks.write(change, in: folder, expecting: FolderIdentity.of(folder)), body)
            }
            XCTAssertEqual(try Data(contentsOf: file), Data(body.utf8), "\(body) was written over")
        }
    }

    /// A folder's identity is the folder itself, whatever path reaches it; a
    /// link at its address is not it. Marks are written only into the folder
    /// they were meant for: another folder at that address, or a link, takes
    /// nothing.
    func testMarksGoOnlyIntoTheFolderTheyWereMeantFor() throws {
        let folder = root.appendingPathComponent("2026-10-15 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(FolderIdentity.of(folder))
        let parentLink = root.appendingPathComponent("Parent link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        XCTAssertEqual(FolderIdentity.of(parentLink.appendingPathComponent(folder.lastPathComponent)), identity)
        let folderLink = root.appendingPathComponent("2026-10-15 11-00-00 Meeting", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        XCTAssertNil(FolderIdentity.of(folderLink), "a link passed for the folder it points to")

        XCTAssertThrowsError(try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folderLink, expecting: identity))
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Old", isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path))
        XCTAssertNoThrow(try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: FolderIdentity.of(folder)))
    }

    // MARK: - The audio rule

    /// Anything not proven keeps the audio: each case starts from a meeting
    /// the rule takes and changes one thing.
    func testTheAudioRuleKeepsAudioUnlessEverythingIsProven() throws {
        let ended = Date().addingTimeInterval(-40 * 86_400)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func record(_ change: @escaping (inout MeetingAttempt) -> Void) -> (URL) throws -> Void {
            { folder in
                var attempt = RetentionFixture.complete(number: 2, ended: ended)
                change(&attempt)
                try RetentionFixture.write(attempt, in: folder)
            }
        }
        let cases: [(String, (URL) throws -> Void)] = [
            ("starred", { try MeetingMarks.write(.init(starred: true), in: $0, expecting: FolderIdentity.of($0)) }),
            ("marks damaged", { try Data("{broken".utf8).write(to: $0.appendingPathComponent(MeetingMarks.fileName)) }),
            ("marks of a later version", {
                try Data(#"{"version":2}"#.utf8).write(to: $0.appendingPathComponent(MeetingMarks.fileName))
            }),
            ("marks a link", { folder in
                let file = outside.appendingPathComponent(UUID().uuidString)
                try Data(#"{"version":1,"starred":false}"#.utf8).write(to: file)
                try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(MeetingMarks.fileName), withDestinationURL: file)
            }),
            ("marks unreadable", { folder in
                let file = folder.appendingPathComponent(MeetingMarks.fileName)
                try Data(#"{"version":1,"starred":false}"#.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            }),
            ("no records", { folder in
                for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(MeetingAttempt.namePrefix) {
                    try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
            }),
            ("a record unreadable", { try Data("{".utf8).write(to: $0.appendingPathComponent(MeetingAttempt.fileName(number: 2))) }),
            ("two records of one number", { try RetentionFixture.write(RetentionFixture.complete(number: 1, ended: ended), in: $0) }),
            ("the last failed", record { $0.result = .failed }),
            ("the last incomplete", record { $0.result = .incomplete }),
            ("the last found no speech", record { $0.result = .noSpeech }),
            ("the last never ended", record { $0.result = .inProgress }),
            ("the last complete with a missed piece", record { $0.failedChunks = 1 }),
            ("the last complete cut short", record { $0.cutShort = true }),
            ("the last complete without a track", record { $0.missingTracks = [.microphone] }),
            ("the last complete ending before it began", record { $0.endedAt = $0.startedAt.addingTimeInterval(-1) }),
            ("the last complete without a fingerprint", record { $0.fingerprint = nil }),
            ("the transcript deleted", { try FileManager.default.removeItem(at: $0.appendingPathComponent("transcript.md")) }),
            ("the transcript edited", { try Data((RetentionFixture.text + "!").utf8).write(to: $0.appendingPathComponent("transcript.md")) }),
            ("the transcript a link to the same text outside", { folder in
                let file = outside.appendingPathComponent(UUID().uuidString)
                try Data(RetentionFixture.text.utf8).write(to: file)
                try FileManager.default.removeItem(at: folder.appendingPathComponent("transcript.md"))
                try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("transcript.md"), withDestinationURL: file)
            }),
            ("a record a link", { folder in
                let file = outside.appendingPathComponent(UUID().uuidString)
                try RetentionFixture.complete(number: 2, ended: ended).write(to: file)
                try FileManager.default.createSymbolicLink(
                    at: folder.appendingPathComponent(MeetingAttempt.fileName(number: 2)), withDestinationURL: file
                )
            }),
            ("the last complete naming no transcript", record { $0.transcript = nil }),
            ("the last complete naming another file", record { $0.transcript = "notes.md" }),
            ("the last complete without an end", record { $0.endedAt = nil }),
            ("the transcript edited, same size", { folder in
                let edited = RetentionFixture.text.replacingOccurrences(of: "Me:", with: "Mx:")
                try Data(edited.utf8).write(to: folder.appendingPathComponent("transcript.md"))
            }),
            ("a track a link", { folder in
                let file = outside.appendingPathComponent(UUID().uuidString)
                try Data(repeating: 1, count: 1_000).write(to: file)
                try FileManager.default.removeItem(at: folder.appendingPathComponent("system.m4a"))
                try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("system.m4a"), withDestinationURL: file)
            }),
            ("saved with a warning", { try RetentionFixture.metadata(state: "suspect").write(to: $0.appendingPathComponent("metadata.json")) }),
            ("no metadata", { try FileManager.default.removeItem(at: $0.appendingPathComponent("metadata.json")) }),
        ]
        let base = try RetentionFixture.meeting("2026-09-30 09-00-00 Meeting", in: root, ended: ended)
        guard case .eligible(let since, let files) = MeetingStorage.audioRetention(of: base) else {
            return XCTFail("a meeting proven in full keeps its audio: \(MeetingStorage.audioRetention(of: base))")
        }
        XCTAssertEqual(since.timeIntervalSince1970, ended.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(Set(files.map(\.name)), ["system.m4a", "microphone.m4a"])
        for (index, (name, change)) in cases.enumerated() {
            let folder = try RetentionFixture.meeting(String(format: "2026-10-%02d 10-00-00 Meeting", index + 1), in: root, ended: ended)
            try change(folder)
            if case .eligible = MeetingStorage.audioRetention(of: folder) { XCTFail("\(name): the audio would go") }
        }
        let link = root.appendingPathComponent("2026-10-30 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        if case .eligible = MeetingStorage.audioRetention(of: link) { XCTFail("a link to a meeting passed for one") }

        // A track already gone, the proof intact: the rest goes by the same rule.
        let partial = try RetentionFixture.meeting("2026-10-31 10-00-00 Meeting", in: root, ended: ended)
        try FileManager.default.removeItem(at: partial.appendingPathComponent("microphone.m4a"))
        guard case .eligible(_, let rest) = MeetingStorage.audioRetention(of: partial) else {
            return XCTFail("the rest of the audio is kept")
        }
        XCTAssertEqual(rest.map(\.name), ["system.m4a"])
    }

    /// The count starts at the first full transcription, a later one does
    /// not move it; and that first one must hold up too.
    func testTheCountStartsAtTheFirstFullTranscriptionWhichMustHoldUp() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-40 * 86_400)
        let yesterday = now.addingTimeInterval(-86_400)
        let twice = try RetentionFixture.meeting("2026-10-01 10-00-00 Meeting", in: root, ended: longAgo, records: [
            RetentionFixture.complete(number: 1, ended: longAgo), RetentionFixture.complete(number: 2, ended: yesterday),
        ])
        XCTAssertNotNil(MeetingStorage.audioRetention(of: twice).due(days: 30, now: now), "a later transcription moved the count")
        XCTAssertNil(MeetingStorage.audioRetention(of: twice).due(days: 90, now: now))

        let flaws: [(String, (inout MeetingAttempt) -> Void)] = [
            ("a missed piece", { $0.failedChunks = 2 }), ("cut short", { $0.cutShort = true }),
            ("no fingerprint", { $0.fingerprint = nil }), ("another file", { $0.transcript = "notes.md" }),
            ("no end", { $0.endedAt = nil }), ("an end before its start", { $0.endedAt = $0.startedAt.addingTimeInterval(-1) }),
        ]
        for (index, (name, flaw)) in flaws.enumerated() {
            var flawed = RetentionFixture.complete(number: 1, ended: longAgo)
            flaw(&flawed)
            let doubtful = try RetentionFixture.meeting("2026-10-1\(index) 10-00-00 Meeting", in: root, ended: longAgo, records: [
                flawed, RetentionFixture.complete(number: 2, ended: yesterday),
            ])
            if case .eligible = MeetingStorage.audioRetention(of: doubtful) {
                XCTFail("a first full transcription with \(name) started the count")
            }
        }
    }

    /// A meeting's size counts everything in it, hidden files included, and
    /// says when a part could not be read rather than passing that part for
    /// the whole.
    func testSizeCountsHiddenFilesAndSaysWhenItIsIncomplete() throws {
        let folder = root.appendingPathComponent("2026-10-15 10-00-00 Meeting", isDirectory: true)
        let nested = folder.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 20).write(to: folder.appendingPathComponent("system.m4a"))
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent(".attempt 0001.murmurly.json"))
        try Data(repeating: 1, count: 5).write(to: nested.appendingPathComponent("tasks.md"))

        let whole = MeetingStorage.folderSize(of: folder)
        XCTAssertEqual(whole.bytes, 35)
        XCTAssertTrue(whole.complete)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path) }
        let part = MeetingStorage.folderSize(of: folder)
        XCTAssertFalse(part.complete, "a folder inside that cannot be read passed for counted")
        XCTAssertEqual(part.bytes, 30)
        XCTAssertFalse(MeetingStorage.folderSize(of: root.appendingPathComponent("absent")).complete)
    }

    /// Every kind of entry a meetings root may hold; returns the names that
    /// are meetings, sorted.
    private func seedMixedMeetingsRoot() throws -> [String] {
        let fileManager = FileManager.default
        let samples = [MeetingAudio.noise(count: 480, amplitude: 0.5, seed: 21)]
        func folder(_ name: String, files: [String: String]) throws {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            for (file, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(file)) }
        }
        _ = try MeetingAudio.folder("2026-10-06 10-00-00 Meeting", in: root, microphone: samples, system: samples)
        try folder("2026-07-14 09-00-00 Meeting", files: [
            "metadata.json": #"{"startedAt":"2026-07-14T09:00:00Z","state":"done","sampleRate":48000}"#,
        ])
        try folder("2026-10-07 11-00-00 Meeting", files: ["system.caf": "audio"])
        try folder("2026-10-07 11-00-00 Meeting-2", files: ["microphone.m4a": "audio"])
        try folder("Notes", files: ["metadata.json": "{}"])
        try folder("2026-10-08 10-00-00 Meeting", files: [:])
        try folder("2026-10-08 11-00-00 Meeting", files: ["notes.md": "мои заметки"])
        try folder(".2026-10-05 10-00-00 Meeting.removing", files: ["metadata.json": "{}"])
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("2026-10-09 10-00-00 Meeting"))
        return [
            "2026-07-14 09-00-00 Meeting", "2026-10-06 10-00-00 Meeting",
            "2026-10-07 11-00-00 Meeting", "2026-10-07 11-00-00 Meeting-2",
        ]
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

// MARK: - Fixtures shared with the queue tests

enum MeetingAudio {
    /// Deterministic noise, so a failure can be reproduced sample for sample.
    static func noise(count: Int, amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed &* 2_654_435_761 | 1
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    /// A finished meeting folder as `SystemAudioCapture.stop` writes it.
    static func folder(
        _ name: String,
        in root: URL,
        microphone: [[Float]],
        system: [[Float]],
        state: String = "done",
        rate: Double = 48_000
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(microphone, to: folder.appendingPathComponent("microphone.caf"), rate: rate)
        try write(system, to: folder.appendingPathComponent("system.caf"), rate: rate)
        let metadata = MeetingMetadata(
            startedAt: "2026-10-06T10:00:00Z",
            endedAt: "2026-10-06T10:01:00Z",
            sampleRate: rate,
            state: state,
            segments: [.init(
                index: 0,
                system: "system.caf",
                mic: "microphone.caf",
                frames: Int64(system[0].count),
                micFrames: Int64(microphone[0].count),
                enqueuedFrames: Int64(system[0].count)
            )],
            trigger: "us.zoom.xos"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
        return folder
    }

    static func write(_ channels: [[Float]], to url: URL, rate: Double = 48_000) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: AVAudioChannelCount(channels.count), interleaved: false
        ))
        let frames = channels[0].count
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames)
            }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Reads to the end in a loop: a single read may stop short.
    static func decode(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 4_096)
            guard buffer.frameLength > 0 else { break }
            for index in channels.indices {
                channels[index] += UnsafeBufferPointer(start: buffer.floatChannelData![index], count: Int(buffer.frameLength))
            }
        }
        return channels
    }

    /// Every decoded sample within one 24-bit step of the original × gain.
    static func assertDecoded(
        _ url: URL,
        equals channels: [[Float]],
        gain: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decoded = try decode(url)
        XCTAssertEqual(decoded.count, channels.count, "channels", file: file, line: line)
        for (got, expected) in zip(decoded, channels) {
            XCTAssertEqual(got.count, expected.count, "frames", file: file, line: line)
            let worst = zip(got, expected).map { abs($0 - $1 * gain) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, MeetingStorage.tolerance, "worst difference", file: file, line: line)
        }
    }

    /// The description is copied while its format is alive: it points into it.
    static func dataFormat(of url: URL) throws -> AudioStreamBasicDescription {
        let format = try AVAudioFile(forReading: url).fileFormat
        return withExtendedLifetime(format) { format.streamDescription.pointee }
    }

    static func digests(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return result
    }
}

/// A meeting the audio rule takes: saved without a warning, two m4a tracks,
/// a transcript and the complete record that proves it.
enum RetentionFixture {
    static let text = "# Meeting\n\nAutomatic transcript.\n\n---\n\n[0:05] **Me:** текст\n"

    static func metadata(state: String = "done") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "startedAt": "2026-09-01T10:00:00Z", "endedAt": "2026-09-01T10:30:00Z", "sampleRate": 48_000,
            "state": state, "segments": [["index": 0, "system": "system.m4a", "mic": "microphone.m4a"]],
        ])
    }

    static func complete(number: Int, ended: Date, transcript: String = "transcript.md") -> MeetingAttempt {
        var attempt = MeetingAttempt(number: number, startedAt: ended.addingTimeInterval(-60))
        attempt.result = .complete
        attempt.endedAt = ended
        attempt.transcript = transcript
        let bytes = Data(text.utf8)
        attempt.fingerprint = .init(bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        return attempt
    }

    static func write(_ attempt: MeetingAttempt, in folder: URL) throws {
        try attempt.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: attempt.number)))
    }

    @discardableResult
    static func meeting(_ name: String, in root: URL, ended: Date, records: [MeetingAttempt]? = nil) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try metadata().write(to: folder.appendingPathComponent("metadata.json"))
        for track in ["system.m4a", "microphone.m4a"] {
            try Data(repeating: 1, count: 1_000).write(to: folder.appendingPathComponent(track))
        }
        try Data(text.utf8).write(to: folder.appendingPathComponent("transcript.md"))
        for record in records ?? [complete(number: 1, ended: ended)] { try write(record, in: folder) }
        return folder
    }
}
