import CryptoKit
import XCTest
@testable import Murmurly

/// `Sources/Archive/`: the pure Foundation/CryptoKit layer that reads
/// meetings and dictations for the `murmurly` helper, without the app's
/// objects, the main actor or the audio frameworks. Every fixture here is
/// made up and lives in a temporary folder; nothing touches a real archive.
final class ArchiveMeetingsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-meetings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeFolder(_ name: String, in parent: URL, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let json: [String: Any] = ["state": "done", "startedAt": formatter.string(from: startedAt)]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("metadata.json"))
        return folder
    }

    private func writeMarks(title: String?, starred: Bool, speakers: [String: String] = [:], in folder: URL) throws {
        var object: [String: Any] = ["version": 1, "starred": starred]
        if let title { object["title"] = title }
        if !speakers.isEmpty { object["speakers"] = speakers }
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("murmurly.json"))
    }

    private func fingerprint(of text: String) -> MeetingAttempt.Fingerprint {
        let bytes = Data(text.utf8)
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return MeetingAttempt.Fingerprint(bytes: bytes.count, sha256: hex)
    }

    @discardableResult
    private func writeAttempt(
        number: Int, result: MeetingAttempt.Result, transcript: String? = nil,
        lines: [MeetingAttempt.Line] = [], fingerprint: MeetingAttempt.Fingerprint? = nil, in folder: URL
    ) throws -> MeetingAttempt {
        var attempt = MeetingAttempt(number: number, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        attempt.result = result
        attempt.transcript = transcript
        attempt.lines = lines
        attempt.fingerprint = fingerprint
        try attempt.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: number)))
        return attempt
    }

    // MARK: - Tests

    func testSameNameInBothRootsIsTwoMeetings() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        _ = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        _ = try makeFolder("2026-03-04 10-20-30 Meeting", in: chosen)

        let listing = Archive.meetings(local: local, chosen: chosen, links: .follow)

        XCTAssertEqual(listing.meetings.count, 2)
        XCTAssertTrue(listing.meetings.contains { $0.root == .local })
        XCTAssertTrue(listing.meetings.contains { $0.root == .chosen })
    }

    func testOneFolderThroughBothRootsIsOneMeeting() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        _ = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        let chosen = root.appendingPathComponent("chosen-is-a-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: local)

        let listing = Archive.meetings(local: local, chosen: chosen, links: .follow)

        XCTAssertEqual(listing.meetings.count, 1)
    }

    func testLatestTranscriptIsByNumber() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        try "# One\n---\n[0:01] **Me:** Hi\n".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "# Two\n---\n[0:01] **Me:** Hi again\n".write(to: folder.appendingPathComponent("transcript 2.md"), atomically: true, encoding: .utf8)
        // `transcript.md` is modified LATER, to prove the choice is by number, not by date.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: folder.appendingPathComponent("transcript.md").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: folder.appendingPathComponent("transcript 2.md").path
        )

        let info = Archive.MeetingFolder.read(folder, links: .follow)

        XCTAssertEqual(info.versions.last?.number, 2)
        let meeting = Archive.Meeting(folder: info, root: .local)
        XCTAssertEqual(meeting.latest?.number, 2)
    }

    func testNamesWhenRecordMatches() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        let text = "# Plum review\n---\n[0:01] **Me:** Hello there\n[0:05] **Others:** Hi back\n"
        try text.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try writeAttempt(
            number: 1, result: .complete, transcript: "transcript.md",
            lines: [
                MeetingAttempt.Line(start: 1, end: 4, source: .microphone),
                MeetingAttempt.Line(start: 5, end: 9, source: .system),
            ],
            fingerprint: fingerprint(of: text), in: folder
        )
        try writeMarks(
            title: "Plum review", starred: true,
            speakers: ["microphone": "Speaker Alpha", "system": "Speaker Beta"], in: folder
        )

        let info = Archive.MeetingFolder.read(folder, links: .follow)
        let meeting = Archive.Meeting(folder: info, root: .local)
        XCTAssertEqual(meeting.title, "Plum review")
        XCTAssertTrue(meeting.starred)

        let transcript = try XCTUnwrap(Archive.transcript(of: meeting, links: .follow))
        let lines = try XCTUnwrap(transcript.lines)
        XCTAssertEqual(lines.map(\.speaker), ["Speaker Alpha", "Speaker Beta"])
        guard case .exact = transcript.timing else { return XCTFail("expected the record's exact spans") }
    }

    func testNoNamesWhenRecordDoesNotMatch() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        let text = "# Plum review\n---\n[0:01] **Me:** Hello there\n[0:05] **Others:** Hi back\n"
        try text.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try writeAttempt(
            number: 1, result: .complete, transcript: "transcript.md",
            lines: [
                MeetingAttempt.Line(start: 1, end: 4, source: .microphone),
                MeetingAttempt.Line(start: 5, end: 9, source: .system),
            ],
            fingerprint: fingerprint(of: text), in: folder
        )
        try writeMarks(
            title: "Plum review", starred: true,
            speakers: ["microphone": "Speaker Alpha", "system": "Speaker Beta"], in: folder
        )
        // Changed by one byte after the record was written: the fingerprint no longer matches.
        try (text + "\n").write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        let info = Archive.MeetingFolder.read(folder, links: .follow)
        let meeting = Archive.Meeting(folder: info, root: .local)
        let transcript = try XCTUnwrap(Archive.transcript(of: meeting, links: .follow))
        let lines = try XCTUnwrap(transcript.lines)
        XCTAssertEqual(lines.map(\.speaker), ["Me", "Others"], "the file's own labels, not the user's names")
        guard case .approximate = transcript.timing else { return XCTFail("a changed file is never the record's exact spans") }
    }

    func testCompletenessIsLastRecordedResult() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        try writeAttempt(number: 1, result: .complete, in: folder)
        try writeAttempt(number: 2, result: .incomplete, in: folder)

        let info = Archive.MeetingFolder.read(folder, links: .follow)
        switch info.lastAttempt {
        case .recorded(let attempt): XCTAssertEqual(attempt.result, .incomplete)
        default: XCTFail("expected the last record, number 2")
        }

        let folderWithoutRecords = try makeFolder("2026-03-04 11-00-00 Meeting", in: local)
        let infoWithoutRecords = Archive.MeetingFolder.read(folderWithoutRecords, links: .follow)
        XCTAssertEqual(infoWithoutRecords.lastAttempt, .none)
    }

    func testMeetingSearchFoldsYoAndCase() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        try "---\n[0:01] **Я:** Сегодня клёпсик опять на месте\n"
            .write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let info = Archive.MeetingFolder.read(folder, links: .follow)
        let meeting = Archive.Meeting(folder: info, root: .local)

        func matched(_ query: String) throws -> Bool {
            let results = Archive.search(query, in: [meeting], links: .follow)
            guard case .success(let found) = results[0].matched else { throw XCTSkip("unexpected read failure") }
            return found
        }

        XCTAssertTrue(try matched("клепсик"))
        XCTAssertTrue(try matched("КЛЁПСИК"))
        XCTAssertFalse(try matched("клипсик"))
        // "Я" alone is also a substring of "опять", so the label's text is
        // checked with its colon, which the body text never has.
        XCTAssertFalse(try matched("Я:"), "the speaker label is not searched, only the lines' words")
    }

    func testLinkedMeetingFolderIsNotReadForHelper() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeFolder("plum-target", in: elsewhere)
        try writeMarks(title: "Plum review", starred: false, in: target)
        let link = local.appendingPathComponent("2026-03-04 10-20-30 Meeting", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let listing = Archive.meetings(local: local, chosen: nil, links: .refuse)

        XCTAssertTrue(listing.meetings.isEmpty)
        XCTAssertFalse(listing.meetings.contains { $0.title == "Plum review" })
        XCTAssertEqual(listing.skipped.map(\.url.lastPathComponent), ["2026-03-04 10-20-30 Meeting"])
    }

    func testLinkedFilesInsideMeetingAreNotOpenedForHelper() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeMarks(title: "Plum review", starred: true, in: outside)
        try FileManager.default.moveItem(
            at: outside.appendingPathComponent("murmurly.json"), to: outside.appendingPathComponent("outside-marks.json")
        )
        try "---\n[0:01] **Me:** Hello\n".write(
            to: outside.appendingPathComponent("outside-transcript.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("murmurly.json"),
            withDestinationURL: outside.appendingPathComponent("outside-marks.json")
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("transcript.md"),
            withDestinationURL: outside.appendingPathComponent("outside-transcript.md")
        )

        XCTAssertEqual(MeetingMarks.read(in: folder, links: .refuse), .unreadable("\(folder.appendingPathComponent("murmurly.json").path) is a link"))
        let refused = Archive.Meeting(folder: Archive.MeetingFolder.read(folder, links: .refuse), root: .local)
        XCTAssertThrowsError(try Archive.transcript(of: refused, links: .refuse))

        guard case .read(let marks) = MeetingMarks.read(in: folder, links: .follow) else {
            return XCTFail("the window still follows the link")
        }
        XCTAssertEqual(marks.title, "Plum review")
        let followed = Archive.Meeting(folder: Archive.MeetingFolder.read(folder, links: .follow), root: .local)
        XCTAssertNoThrow(try Archive.transcript(of: followed, links: .follow))
    }

    func testUnreadableRootIsAnErrorNotEmpty() throws {
        let local = root.appendingPathComponent("local-unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: local.path)
        let chosen = root.appendingPathComponent("chosen-missing", isDirectory: true)

        let listing = Archive.meetings(local: local, chosen: chosen, links: .follow)

        guard case .failed = listing.local else { return XCTFail("an unreadable root is an error, not empty") }
        XCTAssertEqual(listing.chosen, .unavailable)
    }
}

final class ArchiveDictationsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-dictations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(at date: Date, text: String) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(), at: date, duration: 1, selectedLanguage: "auto", actualLanguage: "en",
            targetBundleID: nil, targetApplicationName: nil, audioPath: "", text: text
        )
    }

    func testNewestFirstUpToLimit() async throws {
        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        let store = DictationHistoryStore(root: dictationsRoot)
        var entries: [DictationHistoryEntry] = []
        for day in 0..<5 {
            let one = entry(at: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400), text: "Entry \(day)")
            try await store.append(one)
            entries.append(one)
        }

        let found = try Archive.dictations(root: dictationsRoot, limit: 2, links: .follow)

        XCTAssertEqual(found.map(\.id), [entries[4].id, entries[3].id])
    }

    func testPeriodIsAFilterNotAPage() async throws {
        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        let store = DictationHistoryStore(root: dictationsRoot)
        func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }
        var byDay: [DictationHistoryEntry] = []
        for n in 1...5 {
            let one = entry(at: day(n), text: "Day \(n)")
            try await store.append(one)
            byDay.append(one)
        }
        // Appended last (so it is newest in the file), but its own `at` is old:
        // a line's position in the file never implies where its `at` falls.
        let oldButLast = entry(at: day(1), text: "Old but last")
        try await store.append(oldButLast)

        // The naive "last two file entries, then filter" would see the two
        // newest-appended lines (`oldButLast`, day 5) — only one of them in
        // the period — and miss day 2 entirely.
        let found = try Archive.dictations(root: dictationsRoot, limit: 2, from: day(1), to: day(3), links: .follow)

        XCTAssertEqual(found.map(\.id), [oldButLast.id, byDay[1].id], "day 2, kept even though two out-of-period lines sit between them in the file")
    }

    func testSearchIsTheWindowsRule() async throws {
        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        let store = DictationHistoryStore(root: dictationsRoot)
        let yo = entry(at: Date(timeIntervalSince1970: 1_700_000_000), text: "Сегодня клёпсик опять на месте")
        let zembra = entry(at: Date(timeIntervalSince1970: 1_700_000_100), text: "Зембра шуршит")
        let latin = entry(at: Date(timeIntervalSince1970: 1_700_000_200), text: "Zorbel quindle")
        for one in [yo, zembra, latin] { try await store.append(one) }

        func ids(matching query: String?) throws -> [UUID] {
            try Archive.dictations(root: dictationsRoot, limit: 10, matching: query, links: .follow).map(\.id)
        }
        func windowIDs(matching query: String?) async throws -> [UUID] {
            try await store.page(matching: query).entries.map(\.id)
        }

        for query in ["клёпсик", "КЛЁПСИК", "клепсик", "зЕМБРА", "  ZORBEL  ", nil] {
            let layer = try ids(matching: query)
            let window = try await windowIDs(matching: query)
            XCTAssertEqual(layer, window, "query \(String(describing: query))")
        }

        // Unlike a meeting's search, a dictation's does not fold ё/е: a query
        // without the yo never finds a line that has it.
        XCTAssertEqual(try ids(matching: "клепсик"), [])
        XCTAssertEqual(try ids(matching: "КЛЁПСИК"), [yo.id])
        XCTAssertEqual(try ids(matching: "ZORBEL"), [latin.id])
    }

    func testLinkedHistoryIsNotReadForHelper() async throws {
        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        let store = DictationHistoryStore(root: dictationsRoot)
        let one = entry(at: Date(timeIntervalSince1970: 1_700_000_000), text: "Zorbel quindle")
        try await store.append(one)

        let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot.appendingPathComponent("history.jsonl"),
            withDestinationURL: dictationsRoot.appendingPathComponent("history.jsonl")
        )

        XCTAssertThrowsError(try Archive.dictations(root: linkedRoot, limit: 10, links: .refuse))
        let followed = try Archive.dictations(root: linkedRoot, limit: 10, links: .follow)
        XCTAssertEqual(followed.map(\.id), [one.id])
    }

    func testUnreadableHistoryIsAnErrorMissingIsEmpty() async throws {
        let missingRoot = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertEqual(try Archive.dictations(root: missingRoot, limit: 10, links: .follow), [])

        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        let store = DictationHistoryStore(root: dictationsRoot)
        try await store.append(entry(at: Date(timeIntervalSince1970: 1_700_000_000), text: "Zorbel quindle"))
        let historyURL = dictationsRoot.appendingPathComponent("history.jsonl")
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: historyURL.path)

        XCTAssertThrowsError(try Archive.dictations(root: dictationsRoot, limit: 10, links: .follow))
    }
}

/// a6: the lighter listing read (no `lines` in an attempt record), the
/// direct-by-id meeting lookup, and the raw-text quick checks before a
/// meeting's or a dictation's full parse/decode. Every "old path" compared
/// against here is built from the functions that remain unchanged
/// (`MeetingFolder.read(_, links: .refuse)` with its original default,
/// `MeetingSearch.ranges`, `scanBackward` without a `prefilter`), never a
/// second copy of the new code.
final class ArchiveFastPathTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-fastpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeFolder(_ name: String, in parent: URL, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let json: [String: Any] = ["state": "done", "startedAt": formatter.string(from: startedAt)]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("metadata.json"))
        return folder
    }

    private func fingerprint(of text: String) -> MeetingAttempt.Fingerprint {
        let bytes = Data(text.utf8)
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return MeetingAttempt.Fingerprint(bytes: bytes.count, sha256: hex)
    }

    @discardableResult
    private func writeAttempt(
        number: Int, result: MeetingAttempt.Result, transcript: String? = nil,
        lines: [MeetingAttempt.Line] = [], speakers: MeetingAttempt.Speakers? = nil,
        fingerprint: MeetingAttempt.Fingerprint? = nil, endedAt: Date? = nil, in folder: URL
    ) throws -> MeetingAttempt {
        var attempt = MeetingAttempt(number: number, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        attempt.result = result
        attempt.transcript = transcript
        attempt.lines = lines
        attempt.speakers = speakers
        attempt.fingerprint = fingerprint
        attempt.endedAt = endedAt
        try attempt.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: number)))
        return attempt
    }

    private func write(_ object: [String: Any], to folder: URL, named name: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent(name))
    }

    // MARK: - (1) The lighter listing read

    func testSummaryRecordReadsAsFullRecordWithoutLines() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        try writeAttempt(
            number: 1, result: .complete, transcript: "transcript.md",
            lines: [MeetingAttempt.Line(start: 1, end: 4, source: .microphone)],
            speakers: MeetingAttempt.Speakers(microphone: "A", system: "B"),
            fingerprint: fingerprint(of: "x"), endedAt: Date(timeIntervalSince1970: 1_700_000_010), in: folder
        )

        let full = try MeetingAttempt.entries(in: folder, links: .follow, withLines: true)
        let summary = try MeetingAttempt.entries(in: folder, links: .follow, withLines: false)
        XCTAssertEqual(full.count, 1)
        XCTAssertEqual(summary.count, 1)
        var expectedWithoutLines = try XCTUnwrap(full.first?.attempt)
        expectedWithoutLines.lines = []
        XCTAssertEqual(summary.first?.attempt, expectedWithoutLines, "every field but lines reads the same")

        // Malformed records: both paths must agree they are unreadable.
        func bothRefuse(_ object: [String: Any], _ name: String) throws {
            try write(object, to: folder, named: name)
            let withLinesEntry = try MeetingAttempt.entries(in: folder, links: .follow, withLines: true).first { $0.name == name }
            let withoutLinesEntry = try MeetingAttempt.entries(in: folder, links: .follow, withLines: false).first { $0.name == name }
            XCTAssertNil(withLinesEntry?.attempt, name)
            XCTAssertNil(withoutLinesEntry?.attempt, name)
        }
        let base: [String: Any] = [
            "version": 1, "number": 2, "result": "complete",
            "startedAt": "2026-01-01T00:00:00Z",
            "engines": [], "languages": [], "failedChunks": 0, "cutShort": false, "missingTracks": [],
            "lines": [],
        ]
        try bothRefuse(base.merging(["version": 2], uniquingKeysWith: { _, new in new }), MeetingAttempt.fileName(number: 2))
        try bothRefuse(base.merging([:], uniquingKeysWith: { _, new in new }).filter { $0.key != "result" }, MeetingAttempt.fileName(number: 3))
        try bothRefuse(base.merging(["result": "x"], uniquingKeysWith: { _, new in new }), MeetingAttempt.fileName(number: 4))
        try bothRefuse(base.filter { $0.key != "lines" }, MeetingAttempt.fileName(number: 5))
        try bothRefuse(base.merging(["lines": 5], uniquingKeysWith: { _, new in new }), MeetingAttempt.fileName(number: 6))

        // A record whose line elements are themselves malformed: the light
        // read still accepts it (it never looks past "is this an array"),
        // the full read does not — a deliberate, tested difference.
        try write(base.merging(["lines": [["source": "x"]]], uniquingKeysWith: { _, new in new }), to: folder, named: MeetingAttempt.fileName(number: 7))
        let fullSeven = try MeetingAttempt.entries(in: folder, links: .follow, withLines: true).first { $0.name.contains("0007") }
        let summarySeven = try MeetingAttempt.entries(in: folder, links: .follow, withLines: false).first { $0.name.contains("0007") }
        XCTAssertNil(fullSeven?.attempt, "a malformed line element refuses the full decode")
        XCTAssertNotNil(summarySeven?.attempt, "the light read never looks at a line's own content")

        // A record that is itself a link is unreadable to both, in `refuse`.
        let realName = MeetingAttempt.fileName(number: 8)
        try writeAttempt(number: 8, result: .complete, in: folder)
        let linkName = MeetingAttempt.fileName(number: 9)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent(linkName), withDestinationURL: folder.appendingPathComponent(realName)
        )
        let fullLink = try MeetingAttempt.entries(in: folder, links: .refuse, withLines: true).first { $0.name == linkName }
        let summaryLink = try MeetingAttempt.entries(in: folder, links: .refuse, withLines: false).first { $0.name == linkName }
        XCTAssertNil(fullLink?.attempt)
        XCTAssertNil(summaryLink?.attempt)
    }

    func testSummaryListingAnswersAsFullListing() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        let noRecords = try makeFolder("2026-01-01 00-00-00 Meeting", in: local)
        _ = try "# T\n---\n[0:01] **Me:** hi\n".write(to: noRecords.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        let complete = try makeFolder("2026-01-02 00-00-00 Meeting", in: local)
        let completeText = "# T\n---\n[0:01] **Me:** hi\n"
        try completeText.write(to: complete.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: completeText), in: complete)

        let incomplete = try makeFolder("2026-01-03 00-00-00 Meeting", in: local)
        try writeAttempt(number: 1, result: .incomplete, in: incomplete)

        let twoVersions = try makeFolder("2026-01-04 00-00-00 Meeting", in: local)
        try "v1\n---\n".write(to: twoVersions.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "v2\n---\n".write(to: twoVersions.appendingPathComponent("transcript 2.md"), atomically: true, encoding: .utf8)
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", in: twoVersions)
        try writeAttempt(number: 2, result: .incomplete, transcript: "transcript 2.md", in: twoVersions)

        let unreadableLast = try makeFolder("2026-01-05 00-00-00 Meeting", in: local)
        try writeAttempt(number: 1, result: .complete, in: unreadableLast)
        try write(["version": 2], to: unreadableLast, named: MeetingAttempt.fileName(number: 2))

        let noMetadataWithTrack = local.appendingPathComponent("2026-01-06 00-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: noMetadataWithTrack, withIntermediateDirectories: true)
        try Data().write(to: noMetadataWithTrack.appendingPathComponent("system.caf"))

        func summarize(_ listing: Archive.Listing) -> [[String: String]] {
            listing.meetings.map { meeting in
                [
                    "id": meeting.id,
                    "root": HelperContract.rootName(meeting.root),
                    "readable": String(meeting.readable),
                    "lastAttempt": HelperContract.lastAttemptName(meeting.completeness),
                    "completeness": HelperContract.completeness(meeting),
                    "versions": String(meeting.folder.versions.count),
                ]
            }
        }

        let fullListing = Archive.meetings(local: local, chosen: nil, links: .follow, records: .full)
        let summaryListing = Archive.meetings(local: local, chosen: nil, links: .follow, records: .summary)
        XCTAssertEqual(summarize(fullListing), summarize(summaryListing))
        XCTAssertEqual(fullListing.local, summaryListing.local)
        XCTAssertEqual(fullListing.skipped, summaryListing.skipped)
    }

    func testTranscriptReadsFullRecordAfterSummaryListing() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try makeFolder("2026-03-04 10-20-30 Meeting", in: local)
        let text = "# T\n---\n[0:01] **Me:** Hello there\n[0:05] **Others:** Hi back\n"
        try text.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try writeAttempt(
            number: 1, result: .complete, transcript: "transcript.md",
            lines: [
                MeetingAttempt.Line(start: 1, end: 4, source: .microphone),
                MeetingAttempt.Line(start: 5, end: 9, source: .system),
            ],
            speakers: MeetingAttempt.Speakers(microphone: "Alpha", system: "Beta"),
            fingerprint: fingerprint(of: text), in: folder
        )
        try write(["version": 1, "starred": false, "speakers": ["microphone": "Alpha", "system": "Beta"]], to: folder, named: "murmurly.json")

        let fullInfo = Archive.MeetingFolder.read(folder, links: .follow, records: .full)
        let summaryInfo = Archive.MeetingFolder.read(folder, links: .follow, records: .summary)
        let fullMeeting = Archive.Meeting(folder: fullInfo, root: .local)
        let summaryMeeting = Archive.Meeting(folder: summaryInfo, root: .local)

        let fromFull = try XCTUnwrap(Archive.transcript(of: fullMeeting, links: .follow))
        let fromSummary = try XCTUnwrap(Archive.transcript(of: summaryMeeting, links: .follow))
        XCTAssertEqual(fromFull.lines?.map(\.speaker), ["Alpha", "Beta"])
        XCTAssertEqual(fromSummary.lines?.map(\.speaker), ["Alpha", "Beta"])
        guard case .exact = fromSummary.timing else { return XCTFail("exact timing even after a summary listing") }
    }

    // MARK: - (2) Direct-by-id lookup

    func testLookupByIDFindsWhatListingFinds() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let ordinaryName = "2026-01-01 00-00-00 Meeting"
        _ = try makeFolder(ordinaryName, in: local)

        // A chosen root that is a link to the local one: the same folder
        // reached twice is one meeting, the local root's.
        try FileManager.default.removeItem(at: chosen)
        try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: local)

        let listing = Archive.meetings(local: local, chosen: chosen, links: .refuse, records: .full)
        XCTAssertEqual(listing.meetings.count, 1)

        let ordinaryID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: ordinaryName))
        let foundLocal = try XCTUnwrap(try Archive.meeting(root: .local, folderName: ordinaryName, local: local, chosen: chosen))
        XCTAssertEqual(foundLocal.id, listing.meetings.first?.id)
        XCTAssertEqual(HelperContract.meetingID(root: foundLocal.root, folderName: foundLocal.folder.directory.lastPathComponent), ordinaryID)

        // The chosen root resolves to the same folder as local: not found
        // through `.chosen` — the listing only ever shows it once, via local.
        XCTAssertNil(try Archive.meeting(root: .chosen, folderName: ordinaryName, local: local, chosen: chosen))

        // A meeting folder that is itself a link is skipped by the listing,
        // and the direct lookup throws rather than silently answering nil:
        // a caller (`runTranscript`) must be able to tell a link apart from
        // a meeting that is simply not there.
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeFolder("target", in: elsewhere)
        let linkName = "2026-01-02 00-00-00 Meeting"
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent(linkName), withDestinationURL: target)
        XCTAssertThrowsError(try Archive.meeting(root: .local, folderName: linkName, local: local, chosen: nil)) { error in
            guard case Archive.ReadError.link = error else {
                return XCTFail("expected .link, got \(error)")
            }
        }

        // A folder without metadata or a track is not a meeting.
        let notAMeetingName = "2026-01-03 00-00-00 Meeting"
        try FileManager.default.createDirectory(at: local.appendingPathComponent(notAMeetingName, isDirectory: true), withIntermediateDirectories: true)
        XCTAssertNil(try Archive.meeting(root: .local, folderName: notAMeetingName, local: local, chosen: nil))

        // A hidden meeting folder is not in the listing either.
        let hiddenName = "2026-01-04 00-00-00 Meeting"
        var hiddenFolder = try makeFolder(hiddenName, in: local)
        var flags = URLResourceValues()
        flags.isHidden = true
        try hiddenFolder.setResourceValues(flags)
        XCTAssertNil(try Archive.meeting(root: .local, folderName: hiddenName, local: local, chosen: nil))

        // No root at all: proven absent, not found rather than a failure.
        let noRoot = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(try Archive.meeting(root: .local, folderName: ordinaryName, local: noRoot, chosen: nil))

        // An unavailable chosen root.
        let missingChosen = root.appendingPathComponent("missing-chosen", isDirectory: true)
        XCTAssertNil(try Archive.meeting(root: .chosen, folderName: ordinaryName, local: local, chosen: missingChosen))
    }

    /// A root that exists but cannot be listed (permissions) is a failure
    /// to read, never folded into the same `nil` as "no such meeting" —
    /// the same rule `MeetingStorage.meetingFolders(in:)` already applies.
    func testLookupByIDThrowsWhenRootExistsButCannotBeListed() throws {
        let local = root.appendingPathComponent("unreadable-local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let name = "2026-01-05 00-00-00 Meeting"
        _ = try makeFolder(name, in: local)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: local.path)

        XCTAssertThrowsError(try Archive.meeting(root: .local, folderName: name, local: local, chosen: nil))
    }

    // MARK: - (3) Meeting search quick check

    func testMeetingQuickCheckLosesNoMatch() throws {
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        let ordinary = try makeFolder("2026-01-01 00-00-00 Meeting", in: local)
        try "---\n[0:01] **Me:** Ёжик обсудил план запуска\n[0:05] **Others:** Ежик принёс отчёт\n"
            .write(to: ordinary.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", speakers: MeetingAttempt.Speakers(microphone: "Mira", system: "Others"), in: ordinary)

        let notAppForm = try makeFolder("2026-01-02 00-00-00 Meeting", in: local)
        try "Just some free text, not a parsed transcript at all.\n"
            .write(to: notAppForm.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        func meeting(_ folder: URL, records: Archive.MeetingFolder.Records) -> Archive.Meeting {
            Archive.Meeting(folder: Archive.MeetingFolder.read(folder, links: .follow, records: records), root: .local)
        }
        let folders = [ordinary, notAppForm]

        // "Old": what the matcher found before the raw-text quick check
        // existed — always the full parse, never short-circuited.
        func oldMatches(_ query: String) throws -> Set<String> {
            var found: Set<String> = []
            for folder in folders {
                let m = meeting(folder, records: .full)
                guard let transcript = try Archive.transcript(of: m, links: .follow) else { continue }
                if MeetingSearch.matches(query, in: transcript.layout) { found.insert(m.id) }
            }
            return found
        }
        // "New": the quick check may skip the parse outright, via
        // `containing:`, same as `runSearch`/`Archive.search` now do.
        func newMatches(_ query: String) throws -> Set<String> {
            var found: Set<String> = []
            for folder in folders {
                let m = meeting(folder, records: .summary)
                guard let transcript = try Archive.transcript(of: m, links: .follow, containing: query) else { continue }
                if MeetingSearch.matches(query, in: transcript.layout) { found.insert(m.id) }
            }
            return found
        }

        for query in ["ёжик", "ЕЖИК", "Ежик", "план", "Me", "0:07", "\u{0301}"] {
            XCTAssertEqual(try newMatches(query), try oldMatches(query), "query \(query)")
        }
    }

    // MARK: - (4) Dictation search quick check

    func testDictationQuickCheckLosesNoMatch() async throws {
        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationsRoot, withIntermediateDirectories: true)
        let store = DictationHistoryStore(root: dictationsRoot)

        func entry(text: String, rawText: String? = nil, at offset: Double) -> DictationHistoryEntry {
            DictationHistoryEntry(
                id: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000 + offset), duration: 1, selectedLanguage: "auto",
                actualLanguage: "en", targetBundleID: nil, targetApplicationName: nil, audioPath: "a/b", text: text, rawText: rawText
            )
        }
        let yo = entry(text: "Ёлка у входа в офис", at: 0)
        let ye = entry(text: "Елка у окна", at: 1)
        let viaRaw = entry(text: "дерево у двери", rawText: "ёлка у двери", at: 2)
        for one in [yo, ye, viaRaw] { try await store.append(one) }

        let brokenWithNeedle = Data("{\"text\":\"содержит ёлка внутри\", not json".utf8)
        let brokenWithoutNeedle = Data("{\"text\":\"совсем другое\", not json".utf8)
        let historyURL = dictationsRoot.appendingPathComponent("history.jsonl")
        var existing = try Data(contentsOf: historyURL)
        existing.append(brokenWithNeedle)
        existing.append(0x0A)
        existing.append(brokenWithoutNeedle)
        existing.append(0x0A)
        try existing.write(to: historyURL)

        func oldRead(_ query: String?) throws -> Archive.DictationsRead {
            let handle = try FileHandle(forReadingFrom: historyURL)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            let needle = DictationHistoryEntry.searchNeedle(query)
            var malformed = 0
            let (entries, _) = try DictationHistoryEntry.scanBackward(
                handle: handle, upperBound: fileSize, limit: 100, decoder: DictationHistoryEntry.makeDecoder(),
                include: { e in needle.map { e.matches(needle: $0) } ?? true }, onMalformed: { malformed += 1 }
            )
            return Archive.DictationsRead(entries: entries, malformedLines: malformed)
        }

        for query: String? in ["ёлка", "ЁЛКА", "елка", "a/b", "\"", "у", nil] {
            let old = try oldRead(query)
            let new = try Archive.dictationsRead(root: dictationsRoot, limit: 100, matching: query, links: .follow)
            XCTAssertEqual(new.entries, old.entries, "entries for query \(String(describing: query))")

            // The quick check is a superset filter: it may let through a
            // broken line the full decode later drops, but it must never
            // rule out a broken line that is itself a candidate (contains
            // the needle in its own raw bytes), or one where the check does
            // not apply at all.
            if query == nil || !Archive.dictationQuickCheckApplies(to: DictationHistoryEntry.searchNeedle(query) ?? "") {
                XCTAssertEqual(new.malformedLines, old.malformedLines, "query \(String(describing: query))")
            } else {
                XCTAssertLessThanOrEqual(new.malformedLines, old.malformedLines, "query \(String(describing: query))")
            }
        }
        // The broken line containing the needle is always counted when the
        // query is a candidate for it.
        let withNeedle = try Archive.dictationsRead(root: dictationsRoot, limit: 100, matching: "ёлка", links: .follow)
        XCTAssertGreaterThanOrEqual(withNeedle.malformedLines, 1)
    }

    func testDictationSearchCountsOnlyBrokenLinesThatCouldMatch() async throws {
        let dictationsRoot = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationsRoot, withIntermediateDirectories: true)
        let store = DictationHistoryStore(root: dictationsRoot)
        try await store.append(DictationHistoryEntry(
            id: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000), duration: 1, selectedLanguage: "auto",
            actualLanguage: "en", targetBundleID: nil, targetApplicationName: nil, audioPath: "", text: "something ordinary"
        ))
        let historyURL = dictationsRoot.appendingPathComponent("history.jsonl")
        var existing = try Data(contentsOf: historyURL)
        existing.append(Data("{ not json at all, nothing relevant here\n".utf8))
        try existing.write(to: historyURL)

        let withQuery = try Archive.dictationsRead(root: dictationsRoot, limit: 10, matching: "zephyrquill", links: .follow)
        XCTAssertEqual(withQuery.malformedLines, 0, "a broken line that cannot hold the query is not counted during a search")

        let withoutQuery = try Archive.dictationsRead(root: dictationsRoot, limit: 10, links: .follow)
        XCTAssertEqual(withoutQuery.malformedLines, 1, "without a query every broken line is still counted, as before")
    }
}
