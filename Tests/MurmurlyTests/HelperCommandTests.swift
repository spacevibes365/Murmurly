import CryptoKit
import XCTest
@testable import Murmurly

/// Runs the built `murmurly` helper (`Contents/Helpers/murmurly` next to the
/// app, embedded by `project.yml`) against made-up, temporary fixtures and
/// checks its stdout against `HelperContract`. Nothing here reads or could
/// read a real archive: every process launch carries all four
/// `MURMURLY_HELPER_*` overrides, and `HOME` is a temporary folder too.
final class HelperCommandTests: XCTestCase {
    private var root: URL!
    private var meetingsRoot: URL!
    private var dictationsRoot: URL!
    private var settingsURL: URL!
    private var logURL: URL!
    private var homeURL: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)", isDirectory: true)
        meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        dictationsRoot = root.appendingPathComponent("Dictations", isDirectory: true)
        settingsURL = root.appendingPathComponent("settings.plist")
        logURL = root.appendingPathComponent("Logs/agents.log")
        homeURL = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Settings fixture

    private func writeSettings(
        meetings: Bool = true, dictations: Bool = true, periodDays: Int? = nil,
        meetingsFolder: String? = nil, invalidPeriodDays: Any? = nil
    ) throws {
        var dict: [String: Any] = [
            HelperContract.SettingsKey.agentsMeetings: meetings,
            HelperContract.SettingsKey.agentsDictations: dictations,
        ]
        if let periodDays { dict[HelperContract.SettingsKey.periodDays] = periodDays }
        if let invalidPeriodDays { dict[HelperContract.SettingsKey.periodDays] = invalidPeriodDays }
        if let meetingsFolder { dict[HelperContract.SettingsKey.meetingsFolder] = meetingsFolder }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: settingsURL)
    }

    // MARK: - Meeting fixtures

    @discardableResult
    private func makeMeeting(_ name: String, in parent: URL, startedAt: Date, state: String = "done") throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let json: [String: Any] = ["state": state, "startedAt": formatter.string(from: startedAt)]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("metadata.json"))
        return folder
    }

    /// `yyyy-MM-dd HH-mm-ss Meeting`, in the same `Europe/Berlin` zone the
    /// helper process runs in (`helperEnvironment`'s `TZ`): what
    /// `MeetingStorage.date(fromFolderName:)` parses back there, so a test
    /// date and the helper's own idea of it agree regardless of this test
    /// process's own time zone.
    private func folderName(for date: Date, suffix: String = "") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(formatter.string(from: date)) Meeting\(suffix)"
    }

    private func writeMarks(title: String?, starred: Bool, in folder: URL) throws {
        var object: [String: Any] = ["version": 1, "starred": starred]
        if let title { object["title"] = title }
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

    private func makeTranscript(
        in folder: URL, name: String = "transcript.md", lines: [(timecode: String, speaker: String, text: String)]
    ) throws -> String {
        let body = lines.map { "[\($0.timecode)] **\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
        let text = "# Title\n---\n\(body)\n"
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return text
    }

    // MARK: - Dictation fixtures

    private func dictationEntry(at date: Date, text: String, interrupted: Bool? = nil, recognitionFailed: Bool? = nil) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(), at: date, duration: 1.5, selectedLanguage: "auto", actualLanguage: "en",
            targetBundleID: "com.example.notes", targetApplicationName: "Notes", audioPath: "", text: text,
            interrupted: interrupted, recognitionFailed: recognitionFailed
        )
    }

    private func writeHistory(_ entries: [DictationHistoryEntry]) throws {
        let encoder = DictationHistoryEntry.makeEncoder()
        let lines = try entries.map { try String(data: encoder.encode($0), encoding: .utf8)! }
        try (lines.joined(separator: "\n") + "\n").write(
            to: dictationsRoot.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8
        )
    }

    // MARK: - Running the helper

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// The four `MURMURLY_HELPER_*` overrides plus a temporary `HOME`, as a
    /// whole replacement environment — never the inherited one. Shared by
    /// every process this file launches (the CLI's `run` and the MCP
    /// server's `openMCPSession`): a helper missing even one of the four
    /// overrides falls back to `HelperEnvironment.standard()`, which is the
    /// owner's real archive, and no test may ever risk that.
    private func helperEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [
            "MURMURLY_HELPER_MEETINGS_ROOT": meetingsRoot.path,
            "MURMURLY_HELPER_DICTATIONS_ROOT": dictationsRoot.path,
            "MURMURLY_HELPER_SETTINGS": settingsURL.path,
            "MURMURLY_HELPER_LOG": logURL.path,
            "TZ": "Europe/Berlin",
            "HOME": homeURL.path,
        ]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    private func helperURL() throws -> URL {
        #if !DEBUG
        throw XCTSkip("the murmurly helper reads MURMURLY_HELPER_* only in DEBUG; outside it, it would read the real archive")
        #endif
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/murmurly")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("the murmurly helper is not embedded in this build")
        }
        return url
    }

    /// What `launch` hands back: the running process and everything `run`
    /// needs to wait for it, split out so a test that must act (write
    /// settings, remove a hold file) while the helper is still mid-call can
    /// launch it without blocking on its exit.
    private struct LaunchedProcess {
        let process: Process
        let expectation: XCTestExpectation
        let stdoutURL: URL
        let stderrURL: URL
    }

    private func launch(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> LaunchedProcess {
        let helperURL = try self.helperURL()
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.environment = helperEnvironment(extra: extraEnvironment)

        let stdoutURL = root.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        let stderrURL = root.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        let expectation = expectation(description: "murmurly exited")
        process.terminationHandler = { _ in expectation.fulfill() }
        try process.run()
        return LaunchedProcess(process: process, expectation: expectation, stdoutURL: stdoutURL, stderrURL: stderrURL)
    }

    private func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> RunResult {
        let launched = try launch(arguments, extraEnvironment: extraEnvironment)
        await_fulfillment(for: [launched.expectation], timeout: 30)

        let stdout = try String(contentsOf: launched.stdoutURL, encoding: .utf8)
        let stderr = try String(contentsOf: launched.stderrURL, encoding: .utf8)
        return RunResult(exitCode: launched.process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// A thin, non-deprecated spelling for `XCTWaiter`, kept local so every
    /// `run` call reads the same way.
    private func await_fulfillment(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        let waiter = XCTWaiter()
        let result = waiter.wait(for: expectations, timeout: timeout)
        XCTAssertEqual(result, .completed, "the helper did not exit within \(timeout)s")
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try HelperContract.makeDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Tests

    func testMeetingsJSONFollowsContract() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: "Plum review", starred: true, in: folder)
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Shall we start with the fence?")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let result = try run(["meetings", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.schema, 1)
        XCTAssertEqual(response.roots.local, .read)
        XCTAssertEqual(response.roots.chosen, .notSet)
        let item = try XCTUnwrap(response.meetings.first)
        XCTAssertEqual(item.id, "local:2026-10-20_10-31-05")
        XCTAssertEqual(item.root, "local")
        XCTAssertEqual(item.title, "Plum review")
        XCTAssertTrue(item.starred)
        XCTAssertEqual(item.completeness, "complete")
        XCTAssertEqual(item.lastAttempt, "complete")

        XCTAssertFalse(result.stdout.contains(root.path), "no absolute path leaks into stdout")
        XCTAssertFalse(result.stderr.contains(root.path), "no absolute path leaks into stderr either")
    }

    func testTranscriptChunksAndHasMore() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: (1...5).map { ("0:0\($0)", "Me", "Line \($0)") })
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let first = try run(["transcript", "local:2026-10-20_10-31-05", "--from", "2", "--count", "2", "--json"])
        XCTAssertEqual(first.exitCode, 0)
        let firstResponse = try decode(HelperContract.TranscriptResponse.self, from: first.stdout)
        XCTAssertEqual(firstResponse.lines.map(\.n), [2, 3])
        XCTAssertTrue(firstResponse.hasMore)
        XCTAssertEqual(firstResponse.nextFrom, 4)

        let last = try run(["transcript", "local:2026-10-20_10-31-05", "--from", "4", "--count", "2", "--json"])
        let lastResponse = try decode(HelperContract.TranscriptResponse.self, from: last.stdout)
        XCTAssertEqual(lastResponse.lines.map(\.n), [4, 5])
        XCTAssertFalse(lastResponse.hasMore)
        XCTAssertNil(lastResponse.nextFrom)

        let tooMany = try run(["transcript", "local:2026-10-20_10-31-05", "--count", "1001", "--json"])
        XCTAssertEqual(tooMany.exitCode, 2)
    }

    func testTranscriptOfPlainTextFile() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try "Just some notes, not the app's own format.\nSecond line.\n".write(
            to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8
        )

        let result = try run(["transcript", "local:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.TranscriptResponse.self, from: result.stdout)
        XCTAssertEqual(response.format, "text")
        XCTAssertEqual(response.lines.map(\.text), ["Just some notes, not the app's own format.", "Second line."])
        XCTAssertNil(response.lines.first?.timecode)
    }

    func testUnreadableHistoryIsAReadErrorNotAnEmptyList() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere-history", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "{}".write(to: elsewhere.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dictationsRoot.appendingPathComponent("history.jsonl"),
            withDestinationURL: elsewhere.appendingPathComponent("history.jsonl")
        )

        let linked = try run(["dictations", "--json"])
        XCTAssertEqual(linked.exitCode, 5)
        let linkedError = try decode(HelperContract.ErrorResponse.self, from: linked.stdout)
        XCTAssertEqual(linkedError.error.code, .readError)
        XCTAssertFalse(linked.stdout.contains(root.path))

        let linkedSearch = try run(["search", "anything", "--json"])
        XCTAssertEqual(linkedSearch.exitCode, 5, "a broken history refuses the whole search, never an empty dictations list beside real meeting hits")

        try FileManager.default.removeItem(at: dictationsRoot.appendingPathComponent("history.jsonl"))
        let historyURL = dictationsRoot.appendingPathComponent("history.jsonl")
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_000), text: "Buy milk")])
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: historyURL.path)
        let unreadable = try run(["dictations", "--json"])
        XCTAssertEqual(unreadable.exitCode, 5)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        try FileManager.default.removeItem(at: historyURL)
        let missing = try run(["dictations", "--json"])
        XCTAssertEqual(missing.exitCode, 0)
        let missingResponse = try decode(HelperContract.DictationsResponse.self, from: missing.stdout)
        XCTAssertEqual(missingResponse.dictations, [])
    }

    func testSearchReturnsSnippetLineAndMeeting() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: "Plum review", starred: false, in: folder)
        let text = try makeTranscript(in: folder, lines: [
            ("0:01", "Me", "Shall we start with the budget for the garden fence?"),
            ("0:05", "Others", "Yes, let's start there."),
        ])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy wood for the garden fence")])

        let result = try run(["search", "garden fence", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.SearchResponse.self, from: result.stdout)
        let meetingHit = try XCTUnwrap(response.meetings.first)
        XCTAssertEqual(meetingHit.meetingId, "local:2026-10-20_10-31-05")
        XCTAssertEqual(meetingHit.line, 1)
        XCTAssertTrue(meetingHit.snippet.contains("garden fence"))
        XCTAssertFalse(response.dictations.isEmpty)
        XCTAssertTrue(response.dictations[0].snippet.contains("garden fence"))

        let log = try? String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse((log ?? "").contains("garden fence"), "the search text never reaches the log, even though the answer's own snippets must show it")
    }

    func testSearchListsUnreadFolders() throws {
        try writeSettings(periodDays: 0)
        let local: URL = meetingsRoot
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())
        try writeMarks(title: "Hidden", starred: false, in: target)
        let link = local.appendingPathComponent("2026-10-20 10-31-05 Meeting", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try run(["search", "anything", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.SearchResponse.self, from: result.stdout)
        XCTAssertTrue(response.unread.contains { $0.reason == "link" })
        XCTAssertTrue(response.meetings.isEmpty)
    }

    func testDictationsHaveNoRawTextTargetOrAudio() throws {
        try writeSettings(periodDays: 0)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_000), text: "Buy milk")])

        let result = try run(["dictations", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        for forbidden in ["raw_text", "rawText", "target_bundle_id", "targetBundleID", "target_app_name", "audio_path", "audioPath", "selected_language", "actual_language"] {
            XCTAssertFalse(result.stdout.contains(forbidden), "\(forbidden) must never appear")
        }
        let response = try decode(HelperContract.DictationsResponse.self, from: result.stdout)
        XCTAssertEqual(response.dictations.first?.text, "Buy milk")
        XCTAssertEqual(response.dictations.first?.status, "ok")
    }

    func testBrokenHistoryLinesAreCounted() throws {
        try writeSettings(periodDays: 0)
        let good = dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_000), text: "Buy milk")
        let encoder = DictationHistoryEntry.makeEncoder()
        let goodLine = try String(data: encoder.encode(good), encoding: .utf8)!
        let garbage = "{ not json at all"
        try (goodLine + "\n" + garbage + "\n").write(
            to: dictationsRoot.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8
        )

        let result = try run(["dictations", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.DictationsResponse.self, from: result.stdout)
        XCTAssertEqual(response.skippedLines, 1)
        XCTAssertEqual(response.dictations.count, 1)
    }

    func testDisabledAccessIsRefused() throws {
        try writeSettings(meetings: false, dictations: false, periodDays: 0)

        let dictationsResult = try run(["dictations", "--json"])
        XCTAssertEqual(dictationsResult.exitCode, 3)
        let dictationsError = try decode(HelperContract.ErrorResponse.self, from: dictationsResult.stdout)
        XCTAssertEqual(dictationsError.error.code, .accessDenied)

        let meetingsResult = try run(["meetings", "--json"])
        XCTAssertEqual(meetingsResult.exitCode, 3)

        let searchResult = try run(["search", "anything", "--json"])
        XCTAssertEqual(searchResult.exitCode, 3)

        try writeSettings(meetings: true, dictations: false, periodDays: 0)
        let partial = try run(["search", "anything", "--json"])
        XCTAssertEqual(partial.exitCode, 0)
        let partialResponse = try decode(HelperContract.SearchResponse.self, from: partial.stdout)
        XCTAssertEqual(partialResponse.denied, ["dictations"])
    }

    func testPeriodCutsTranscriptOfOldMeeting() throws {
        try writeSettings(periodDays: 7)
        let old = try makeMeeting(
            "2026-09-01 10-00-00 Meeting", in: meetingsRoot, startedAt: Date().addingTimeInterval(-30 * 86_400)
        )
        let text = try makeTranscript(in: old, lines: [("0:01", "Me", "Old meeting")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: old)

        let listing = try run(["meetings", "--json"])
        let listingResponse = try decode(HelperContract.MeetingsResponse.self, from: listing.stdout)
        XCTAssertTrue(listingResponse.meetings.isEmpty)

        let transcript = try run(["transcript", "local:2026-09-01_10-00-00", "--json"])
        XCTAssertEqual(transcript.exitCode, 4)
    }

    func testSinceWiderThanPeriodDoesNotWiden() throws {
        try writeSettings(periodDays: 7)
        let old = try makeMeeting(
            "2026-09-01 10-00-00 Meeting", in: meetingsRoot, startedAt: Date().addingTimeInterval(-60 * 86_400)
        )
        _ = try makeTranscript(in: old, lines: [("0:01", "Me", "Old meeting")])

        let since = HelperContract.string(from: Date().addingTimeInterval(-60 * 86_400))
        let result = try run(["meetings", "--since", since, "--json"])
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertTrue(response.meetings.isEmpty, "a --since wider than the period never widens it")
        XCTAssertNotNil(response.period.from)
    }

    func testSameNameInBothRootsAreTwoMeetings() throws {
        let chosenRoot = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenRoot, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenRoot.path)

        let localFolder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let chosenFolder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let localText = try makeTranscript(in: localFolder, lines: [("0:01", "Me", "Local words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: localText), in: localFolder)
        let chosenText = try makeTranscript(in: chosenFolder, lines: [("0:01", "Me", "Chosen words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: chosenText), in: chosenFolder)

        let listing = try run(["meetings", "--json"])
        let listingResponse = try decode(HelperContract.MeetingsResponse.self, from: listing.stdout)
        XCTAssertEqual(listingResponse.meetings.count, 2)
        XCTAssertTrue(listingResponse.meetings.contains { $0.id == "local:2026-10-20_10-31-05" })
        XCTAssertTrue(listingResponse.meetings.contains { $0.id == "chosen:2026-10-20_10-31-05" })

        let local = try run(["transcript", "local:2026-10-20_10-31-05", "--json"])
        let localResponse = try decode(HelperContract.TranscriptResponse.self, from: local.stdout)
        XCTAssertEqual(localResponse.lines.first?.text, "Local words")

        let chosen = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        let chosenResponse = try decode(HelperContract.TranscriptResponse.self, from: chosen.stdout)
        XCTAssertEqual(chosenResponse.lines.first?.text, "Chosen words")
    }

    func testLinkedMeetingFolderIsNotRead() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())
        let link = meetingsRoot.appendingPathComponent("2026-10-20 10-31-05 Meeting", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try run(["meetings", "--json"])
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertTrue(response.meetings.isEmpty)
        XCTAssertTrue(response.unread.contains { $0.reason == "link" })
    }

    func testLinkedTranscriptInsideMeetingIsReadError() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "---\n[0:01] **Me:** Hello\n".write(
            to: outside.appendingPathComponent("outside-transcript.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("transcript.md"),
            withDestinationURL: outside.appendingPathComponent("outside-transcript.md")
        )

        let result = try run(["transcript", "local:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(result.exitCode, 5)
        let response = try decode(HelperContract.ErrorResponse.self, from: result.stdout)
        XCTAssertEqual(response.error.code, .readError)
        XCTAssertFalse(result.stdout.contains(root.path))
    }

    func testLinkedMetadataIsReportedNotTreatedAsMissing() throws {
        try writeSettings(periodDays: 0)
        let folder = meetingsRoot.appendingPathComponent("2026-10-20 10-31-05 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside-metadata.json")
        try JSONSerialization.data(withJSONObject: ["state": "done"]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("metadata.json"), withDestinationURL: outside)
        // A plain track file, so the folder still counts as a meeting even
        // though `metadata.json` itself cannot be opened.
        FileManager.default.createFile(atPath: folder.appendingPathComponent("system.caf").path, contents: Data())

        let result = try run(["meetings", "--json"])
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        let item = try XCTUnwrap(response.meetings.first)
        XCTAssertEqual(item.metadataError, "link")
        XCTAssertNil(item.state, "a link's state is unknown, never read through it")
    }

    func testUnreachableRoots() throws {
        try writeSettings(periodDays: 0)
        let path = meetingsRoot.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meetingsRoot.path)

        let result = try run(["meetings", "--json"])
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.roots.local, .readError)
        XCTAssertEqual(result.exitCode, 0, "a local read error is still a partial, successful answer")
    }

    func testMeetingsFolderChangeBetweenCalls() throws {
        let firstChosen = root.appendingPathComponent("Chosen1", isDirectory: true)
        let secondChosen = root.appendingPathComponent("Chosen2", isDirectory: true)
        try FileManager.default.createDirectory(at: firstChosen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondChosen, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: firstChosen.path)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: firstChosen, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "First folder")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let before = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(before.exitCode, 0)

        try writeSettings(periodDays: 0, meetingsFolder: secondChosen.path)
        let after = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(after.exitCode, 4, "the old chosen id is gone once the folder changes")
    }

    func testArbitraryPathIsNotAccepted() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("fixture-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let absolute = try run(["transcript", elsewhere.path, "--json"])
        XCTAssertEqual(absolute.exitCode, 4)

        let traversal = try run(["transcript", "local:../x", "--json"])
        XCTAssertEqual(traversal.exitCode, 4)
    }

    func testLogStaysInTempFolderWithoutText() throws {
        try writeSettings(periodDays: 0)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldLine = "\(HelperContract.string(from: Date().addingTimeInterval(-40 * 86_400))) dictations count=1\n"
        try oldLine.write(to: logURL, atomically: true, encoding: .utf8)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_000), text: "some private words")])

        let result = try run(["search", "private words", "--json"])
        XCTAssertEqual(result.exitCode, 0)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("private words"))
        XCTAssertFalse(log.contains("count=1"), "the 40-day-old line was dropped")
        XCTAssertTrue(log.contains("search"))
    }

    func testPartialOverridesAreRefused() throws {
        let process = Process()
        let helperURL = try self.helperURL()
        process.executableURL = helperURL
        process.arguments = ["dictations", "--json"]
        process.environment = [
            "MURMURLY_HELPER_MEETINGS_ROOT": meetingsRoot.path,
            // The other three overrides are deliberately missing.
            "TZ": "Europe/Berlin",
            "HOME": homeURL.path,
        ]
        let stdoutURL = root.appendingPathComponent("partial-stdout.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = FileHandle.nullDevice
        let expectation = expectation(description: "exited")
        process.terminationHandler = { _ in expectation.fulfill() }
        try process.run()
        await_fulfillment(for: [expectation], timeout: 30)
        XCTAssertEqual(process.terminationStatus, 2)
    }

    // MARK: - Response size limit

    func testManyDictationsAreTruncatedWithinByteLimit() throws {
        try writeSettings(periodDays: 0)
        var entries: [DictationHistoryEntry] = []
        for index in 0..<40 {
            entries.append(dictationEntry(
                at: Date(timeIntervalSince1970: 1_792_000_000 + Double(index)),
                text: "Dictation number \(index), with some filler text to take up a bit of space in the archive."
            ))
        }
        try writeHistory(entries)

        let result = try run(["dictations", "--last", "40", "--json"], extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "2000"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.DictationsResponse.self, from: result.stdout)
        XCTAssertTrue(response.truncated)
        XCTAssertLessThan(response.dictations.count, 40)
        let bodyBytes = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        XCTAssertLessThanOrEqual(bodyBytes, 2000)
    }

    func testManyMeetingsAreTruncatedWithinByteLimit() throws {
        try writeSettings(periodDays: 0)
        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.timeZone = TimeZone(identifier: "UTC")
        nameFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        for index in 0..<40 {
            let startedAt = Date(timeIntervalSince1970: 1_792_000_000 + Double(index) * 3_600)
            let folder = try makeMeeting("\(nameFormatter.string(from: startedAt)) Meeting", in: meetingsRoot, startedAt: startedAt)
            try writeMarks(title: "Meeting number \(index) about the quarterly roadmap and the garden committee budget", starred: false, in: folder)
        }

        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "3000"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertTrue(response.truncated)
        XCTAssertTrue(response.hasMore)
        XCTAssertLessThan(response.meetings.count, 40)
        let bodyBytes = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        XCTAssertLessThanOrEqual(bodyBytes, 3000)
    }

    // MARK: - Meetings pagination (`--limit`, `nextUntil`)

    /// `count` meetings an hour apart, newest first, starting at `base`; no
    /// marks or transcript, so every field but `id`/`startedAt` is the one
    /// `HelperContract.completeness`/`lastAttemptName` give an unread
    /// meeting. Returns the ids in the same newest-first order the helper
    /// itself sorts to (`Archive.combine`), for the tests below to compare
    /// pages against.
    @discardableResult
    private func makeHourlyMeetings(count: Int, base: Date) throws -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            let startedAt = base.addingTimeInterval(-Double(index) * 3_600)
            let name = folderName(for: startedAt)
            try makeMeeting(name, in: meetingsRoot, startedAt: startedAt)
            ids.append(try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: name)))
        }
        return ids
    }

    func testMeetingsDefaultLimitIsFiftyAndSignalsHasMore() throws {
        try writeSettings(periodDays: 0)
        let allIDs = try makeHourlyMeetings(count: 120, base: Date(timeIntervalSince1970: 1_792_000_000))

        let result = try run(["meetings", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.meetings.count, 50)
        XCTAssertEqual(response.meetings.map(\.id), Array(allIDs.prefix(50)))
        XCTAssertTrue(response.hasMore)
        XCTAssertFalse(response.truncated)
        XCTAssertNotNil(response.nextUntil)
    }

    func testMeetingsLimitFlagOutOfRangeIsUsageError() throws {
        try writeSettings(periodDays: 0)
        let zero = try run(["meetings", "--limit", "0", "--json"])
        XCTAssertEqual(zero.exitCode, 2)
        let tooMany = try run(["meetings", "--limit", "501", "--json"])
        XCTAssertEqual(tooMany.exitCode, 2)
    }

    func testMeetingsLimitFlagNarrowsThePage() throws {
        try writeSettings(periodDays: 0)
        let allIDs = try makeHourlyMeetings(count: 10, base: Date(timeIntervalSince1970: 1_792_000_000))

        let result = try run(["meetings", "--limit", "3", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.meetings.map(\.id), Array(allIDs.prefix(3)))
        XCTAssertTrue(response.hasMore)
    }

    func testMeetingsContinuationByUntilCoversAllWithoutDuplicatesOrGaps() throws {
        try writeSettings(periodDays: 0)
        let allIDs = try makeHourlyMeetings(count: 120, base: Date(timeIntervalSince1970: 1_792_000_000))

        var seenIDs: [String] = []
        var arguments = ["meetings", "--json"]
        for _ in 0..<10 {
            let result = try run(arguments)
            XCTAssertEqual(result.exitCode, 0)
            let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
            seenIDs.append(contentsOf: response.meetings.map(\.id))
            if !response.hasMore {
                XCTAssertNil(response.nextUntil)
                break
            }
            let nextUntil = try XCTUnwrap(response.nextUntil)
            arguments = ["meetings", "--until", HelperContract.string(from: nextUntil), "--json"]
        }

        XCTAssertEqual(seenIDs, allIDs, "every meeting exactly once, newest first, nothing skipped")
    }

    /// Reconstructs the exact `MeetingsResponse` bytes `runMeetings` would
    /// measure for a given prefix of made-up, markless, attempt-less
    /// meetings (`HelperContract.completeness`/`lastAttemptName`'s answer for
    /// one with neither), so a `--limit` test can pick a byte limit that
    /// lands inside — not merely near — a run of same-second meetings,
    /// without guessing or retrying.
    private func sizeOfMeetingsPrefix(_ items: [HelperContract.MeetingItem]) -> Int {
        let response = HelperContract.MeetingsResponse(
            schema: HelperContract.schemaVersion, command: "meetings",
            period: HelperContract.Period(from: nil, until: nil),
            roots: HelperContract.Roots(local: .read, chosen: .notSet),
            meetings: items, unread: [], hasMore: true, nextUntil: nil, truncated: true
        )
        return (try? HelperContract.makeEncoder().encode(response))?.count ?? Int.max
    }

    private func markerlessItem(id: String, startedAt: Date) -> HelperContract.MeetingItem {
        HelperContract.MeetingItem(
            id: id, root: "local", title: nil, startedAt: startedAt, duration: nil, state: "done",
            metadataError: nil, issues: [], starred: false, readable: true, transcripts: 0,
            latestTranscript: nil, lastAttempt: "none", completeness: "none"
        )
    }

    /// Two meetings an hour apart, then three sharing one second (`Meeting`,
    /// `Meeting-2`, `Meeting-3`: the suffix the app itself uses for a
    /// folder-name collision), then two more an hour apart below that. A
    /// byte limit sized to fit the two newest plus exactly one of the three
    /// same-second meetings must defer the whole group to the next page
    /// instead of splitting it: showing one or two of the three and silently
    /// dropping the rest — what the whole-second back-off in `runMeetings`
    /// (`Commands.swift`) exists to prevent — would make the dropped ones
    /// unreachable through any `--until` continuation, since the cursor
    /// would land inside their own second.
    func testMeetingsByteLimitDefersWholeSecondGroupRatherThanSplittingIt() throws {
        try writeSettings(periodDays: 0)
        let sharedSecond = Date(timeIntervalSince1970: 1_792_000_000)
        let newerA = sharedSecond.addingTimeInterval(7_200)
        let newerB = sharedSecond.addingTimeInterval(3_600)
        let olderA = sharedSecond.addingTimeInterval(-3_600)
        let olderB = sharedSecond.addingTimeInterval(-7_200)

        let newerAName = folderName(for: newerA)
        let newerBName = folderName(for: newerB)
        try makeMeeting(newerAName, in: meetingsRoot, startedAt: newerA)
        try makeMeeting(newerBName, in: meetingsRoot, startedAt: newerB)
        let sharedNames = ["", "-2", "-3"].map { folderName(for: sharedSecond, suffix: $0) }
        for name in sharedNames { try makeMeeting(name, in: meetingsRoot, startedAt: sharedSecond) }
        let olderAName = folderName(for: olderA)
        let olderBName = folderName(for: olderB)
        try makeMeeting(olderAName, in: meetingsRoot, startedAt: olderA)
        try makeMeeting(olderBName, in: meetingsRoot, startedAt: olderB)

        let newerAID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: newerAName))
        let newerBID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: newerBName))
        // Newest-first, tie broken by folder name descending — the same
        // order `Archive.combine` sorts to: "Meeting-3" > "Meeting-2" > "Meeting".
        let sharedIDs = try sharedNames.sorted(by: >).map { try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: $0)) }
        let olderAID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: olderAName))
        let olderBID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: olderBName))

        // A budget that fits the two newer meetings plus the first
        // (newest-named) of the three same-second ones, and nothing more —
        // landing the byte cut one meeting into the group.
        let prefixThroughOneShared = [
            markerlessItem(id: newerAID, startedAt: newerA),
            markerlessItem(id: newerBID, startedAt: newerB),
            markerlessItem(id: sharedIDs[0], startedAt: sharedSecond),
        ]
        let maxBytes = sizeOfMeetingsPrefix(prefixThroughOneShared)

        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "\(maxBytes)"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.meetings.map(\.id), [newerAID, newerBID], "the whole same-second group must be deferred, not split")
        XCTAssertTrue(response.truncated)
        XCTAssertTrue(response.hasMore)
        let nextUntil = try XCTUnwrap(response.nextUntil)
        XCTAssertEqual(nextUntil, newerB, "the cursor must sit right after the last meeting actually shown")

        let next = try run(["meetings", "--until", HelperContract.string(from: nextUntil), "--json"])
        XCTAssertEqual(next.exitCode, 0)
        let nextResponse = try decode(HelperContract.MeetingsResponse.self, from: next.stdout)
        XCTAssertEqual(nextResponse.meetings.map(\.id), sharedIDs + [olderAID, olderBID], "the deferred group arrives whole, then the rest")
    }

    /// All three same-second meetings sit at the very front, with nothing
    /// newer before them, and the byte limit is too small to hold even two
    /// of them. Backing off to a clean boundary would empty the page
    /// entirely, so `runMeetings` keeps the byte-fit page as it is — some of
    /// the group shown, the rest not — but must not hand out a `nextUntil`
    /// for it: any cursor inside that one second would drop whichever
    /// sibling landed on the far side.
    func testMeetingsByteLimitGivesNoCursorWhenOneSecondAloneExceedsIt() throws {
        try writeSettings(periodDays: 0)
        let sharedSecond = Date(timeIntervalSince1970: 1_792_000_000)
        let olderA = sharedSecond.addingTimeInterval(-3_600)
        let olderB = sharedSecond.addingTimeInterval(-7_200)

        let sharedNames = ["", "-2", "-3"].map { folderName(for: sharedSecond, suffix: $0) }
        for name in sharedNames { try makeMeeting(name, in: meetingsRoot, startedAt: sharedSecond) }
        let olderAName = folderName(for: olderA)
        let olderBName = folderName(for: olderB)
        try makeMeeting(olderAName, in: meetingsRoot, startedAt: olderA)
        try makeMeeting(olderBName, in: meetingsRoot, startedAt: olderB)

        let sharedIDs = try sharedNames.sorted(by: >).map { try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: $0)) }
        let sharedItems = sharedIDs.map { markerlessItem(id: $0, startedAt: sharedSecond) }
        let sizeOfTwo = sizeOfMeetingsPrefix(Array(sharedItems.prefix(2)))
        let sizeOfThree = sizeOfMeetingsPrefix(sharedItems)
        XCTAssertLessThan(sizeOfTwo, sizeOfThree, "the three same-second meetings must differ in size for this test to mean anything")
        // `run`'s own `--json` budget leaves room for the `notice` field
        // `WithNotice` adds on top of the plain response this helper
        // measures; add that overhead back so the override still lands
        // exactly at "room for two, not three" for `perform`'s own budget.
        let noticeOverhead = HelperContract.encodedSize(["notice": HelperContract.Tools.untrustedNotice])
        let maxBytes = sizeOfTwo + noticeOverhead

        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "\(maxBytes)"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.meetings.map(\.id), Array(sharedIDs.prefix(2)), "kept as the byte-fit page, not emptied")
        XCTAssertTrue(response.truncated)
        XCTAssertTrue(response.hasMore)
        XCTAssertNil(response.nextUntil, "no cursor would be safe: it would drop the third, undated-for-retrieval sibling")
    }

    /// `--limit 1` with two meetings sharing one second: the limit must not
    /// split that second. Both are shown, past the limit, and the
    /// continuation by `nextUntil` picks up only the earlier, third meeting —
    /// without repeating or skipping either of the first two (K2).
    func testMeetingsPageNeverSplitsOneSecond() throws {
        try writeSettings(periodDays: 0)
        let sharedSecond = Date(timeIntervalSince1970: 1_792_000_000)
        let older = sharedSecond.addingTimeInterval(-3_600)

        let sharedNames = ["", "-2"].map { folderName(for: sharedSecond, suffix: $0) }
        for name in sharedNames { try makeMeeting(name, in: meetingsRoot, startedAt: sharedSecond) }
        let olderName = folderName(for: older)
        try makeMeeting(olderName, in: meetingsRoot, startedAt: older)

        let sharedIDs = try sharedNames.sorted(by: >).map { try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: $0)) }
        let olderID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: olderName))

        let result = try run(["meetings", "--limit", "1", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.meetings.map(\.id), sharedIDs, "both meetings of the second are shown, past the limit")
        XCTAssertTrue(response.hasMore)
        XCTAssertFalse(response.truncated, "the limit, not the byte budget, caused this to extend past one meeting")
        let nextUntil = try XCTUnwrap(response.nextUntil)

        let next = try run(["meetings", "--until", HelperContract.string(from: nextUntil), "--limit", "1", "--json"])
        XCTAssertEqual(next.exitCode, 0)
        let nextResponse = try decode(HelperContract.MeetingsResponse.self, from: next.stdout)
        XCTAssertEqual(nextResponse.meetings.map(\.id), [olderID], "no repeat, no gap")
        XCTAssertFalse(nextResponse.hasMore)
    }

    /// A single meeting with a title much longer than the byte budget: the
    /// response must still measure what it actually sends (K1) — the title
    /// shrunk, the whole encoded response within the budget, and `truncated`
    /// true even though there is nothing more to fetch.
    func testMeetingsByteLimitShrinksALongTitleAndStaysWithinBudget() throws {
        try writeSettings(periodDays: 0)
        let longTitle = String(repeating: "garden fence budget ", count: 200)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: longTitle, starred: false, in: folder)

        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "700"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.meetings.count, 1)
        XCTAssertTrue(response.truncated)
        let title = try XCTUnwrap(response.meetings[0].title)
        XCTAssertLessThan(title.count, longTitle.count)
        let bodyBytes = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        XCTAssertLessThanOrEqual(bodyBytes, 700)
    }

    func testOneTranscriptLineBiggerThanLimitIsCutButKept() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let longText = String(repeating: "garden fence budget ", count: 200)
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", longText)])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let result = try run(
            ["transcript", "local:2026-10-20_10-31-05", "--json"],
            extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "600"]
        )
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.TranscriptResponse.self, from: result.stdout)
        XCTAssertTrue(response.truncated)
        XCTAssertEqual(response.lines.count, 1)
        XCTAssertLessThan(response.lines[0].text.count, longText.count)
        let bodyBytes = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        XCTAssertLessThanOrEqual(bodyBytes, 600)
    }

    func testTranscriptTruncationNextFromPointsToFirstNotGiven() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let lines = (1...20).map { ("0:0\($0 % 10)", "Me", "This is line number \($0) with a bit of filler text to add some bulk.") }
        let text = try makeTranscript(in: folder, lines: lines)
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let result = try run(
            ["transcript", "local:2026-10-20_10-31-05", "--count", "20", "--json"],
            extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "1200"]
        )
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.TranscriptResponse.self, from: result.stdout)
        XCTAssertTrue(response.truncated)
        XCTAssertTrue(response.hasMore)
        let given = try XCTUnwrap(response.lines.last)
        XCTAssertEqual(response.nextFrom, given.n + 1)
        XCTAssertLessThan(response.lines.count, 20)
    }

    func testPrintsExamples() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: "Plum review", starred: true, in: folder)
        let text = try makeTranscript(in: folder, lines: [
            ("0:01", "Me", "Shall we start with the fence?"),
            ("0:05", "Others", "Yes, the budget first."),
        ])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy wood for the fence")])

        for arguments in [["meetings", "--json"], ["transcript", "local:2026-10-20_10-31-05", "--json"], ["search", "fence", "--json"], ["dictations", "--json"]] {
            let result = try run(arguments)
            print("$ murmurly \(arguments.joined(separator: " "))\n\(result.stdout)")
        }
    }

    // MARK: - Agents tab → helper

    /// `UserDefaults` is not `Sendable`, so no helper below hands one back
    /// across an `await`: every caller threads a plain suite name instead,
    /// and `UserDefaults(suiteName:)` with the same name always reaches the
    /// same domain.
    private func agentsSuite(_ suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("couldn't create a UserDefaults suite for the Agents tab fixture")
        }
        return defaults
    }

    /// Writes `agents.meetings` / `agents.dictations` / `agents.periodDays`
    /// the way the Agents tab does — through a real `SettingsStore`, not the
    /// test fixture's own plist dictionary — then copies exactly what
    /// `UserDefaults` holds for those three keys into the helper's settings
    /// file, each value as `object(forKey:)` returns it, never rebuilt into
    /// a fresh `NSNumber`: a switch is a boolean-tagged one, a period an
    /// integer-tagged one, matching what the Settings tab itself writes.
    @MainActor
    private func writeAgentsSettingsFromStore(
        suiteName: String, meetings: Bool, dictations: Bool, periodDays: Int
    ) throws {
        let defaults = try agentsSuite(suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.agentsMeetings = meetings
        store.agentsDictations = dictations
        store.agentsPeriodDays = periodDays
        try exportAgentsSettings(from: defaults)
    }

    /// A `SettingsStore` reads the domain only in `init`: `agentsPeriodDays`
    /// has no `didSet`-triggered reread, so a store already created does not
    /// see an edit made straight to `UserDefaults` after it — only a fresh
    /// one does. `liveStore` is passed in so repeated manual edits (one per
    /// value under test) all read against the one store created before any
    /// of them. Plain values cross back, never the `@MainActor` store itself.
    @MainActor
    private func periodDaysAfterManualEdit(
        suiteName: String, writing value: Any, liveStore: SettingsStore
    ) throws -> (liveAfterEdit: Int, freshAfterEdit: Int) {
        let defaults = try agentsSuite(suiteName)
        defaults.set(value, forKey: HelperContract.SettingsKey.periodDays)
        let freshValue = SettingsStore(defaults: defaults).agentsPeriodDays
        try exportAgentsSettings(from: defaults)
        return (liveStore.agentsPeriodDays, freshValue)
    }

    private func exportAgentsSettings(from defaults: UserDefaults) throws {
        var dict: [String: Any] = [:]
        for key in [
            HelperContract.SettingsKey.agentsMeetings,
            HelperContract.SettingsKey.agentsDictations,
            HelperContract.SettingsKey.periodDays,
        ] {
            if let value = defaults.object(forKey: key) { dict[key] = value }
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: settingsURL)
    }

    /// One source on, the other off, set from the tab's own switches: the
    /// allowed source answers, the other is refused, and `search` — which
    /// touches both — reports only the one still off, never the one that is
    /// on (the same rule the other way round as `testDisabledAccessIsRefused`).
    @MainActor
    func testAgentsTabToggleGrantsOneSourceAndDeniesTheOther() throws {
        try writeAgentsSettingsFromStore(
            suiteName: "agents-tab-\(UUID().uuidString)", meetings: true, dictations: false, periodDays: 0
        )
        try writeHistory([dictationEntry(at: Date(), text: "Buy wood for the fence")])

        let meetingsResult = try run(["meetings", "--json"])
        XCTAssertEqual(meetingsResult.exitCode, 0)

        let dictationsResult = try run(["dictations", "--json"])
        XCTAssertEqual(dictationsResult.exitCode, 3)
        let dictationsError = try decode(HelperContract.ErrorResponse.self, from: dictationsResult.stdout)
        XCTAssertEqual(dictationsError.error.code, .accessDenied)

        let searchResult = try run(["search", "fence", "--json"])
        XCTAssertEqual(searchResult.exitCode, 0)
        let searchResponse = try decode(HelperContract.SearchResponse.self, from: searchResult.stdout)
        XCTAssertEqual(searchResponse.denied, ["dictations"])
    }

    /// Both switches off, as the tab has them by default: every command that
    /// touches either source is refused, `search` included.
    @MainActor
    func testAgentsTabBothTogglesOffRefusesEveryCommand() throws {
        try writeAgentsSettingsFromStore(
            suiteName: "agents-tab-\(UUID().uuidString)", meetings: false, dictations: false, periodDays: 0
        )

        for arguments in [["meetings", "--json"], ["dictations", "--json"], ["search", "anything", "--json"]] {
            let result = try run(arguments)
            XCTAssertEqual(result.exitCode, 3, "\(arguments) should be refused while both switches are off")
            let error = try decode(HelperContract.ErrorResponse.self, from: result.stdout)
            XCTAssertEqual(error.error.code, .accessDenied)
        }
    }

    /// The period the tab's picker offers (365 days here) cuts a meeting
    /// just past it while keeping one still inside it; a period the picker
    /// never offers (written straight to the domain, as a manual edit would)
    /// is refused rather than read as "no limit". A `SettingsStore` already
    /// held in memory does not reread the domain by itself — only a fresh one does.
    @MainActor
    func testAgentsTabPeriodBoundaryAndManualDomainEditAreHonored() throws {
        let suiteName = "agents-tab-\(UUID().uuidString)"
        try writeAgentsSettingsFromStore(suiteName: suiteName, meetings: true, dictations: false, periodDays: 365)
        let recent = try makeMeeting(
            "2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date().addingTimeInterval(-100 * 86_400)
        )
        let recentText = try makeTranscript(in: recent, lines: [("0:01", "Me", "Still within a year")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: recentText), in: recent)
        let old = try makeMeeting(
            "2025-10-19 10-31-05 Meeting", in: meetingsRoot, startedAt: Date().addingTimeInterval(-366 * 86_400)
        )
        let oldText = try makeTranscript(in: old, lines: [("0:01", "Me", "Just over a year")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: oldText), in: old)

        let listing = try run(["meetings", "--json"])
        XCTAssertEqual(listing.exitCode, 0)
        let listingResponse = try decode(HelperContract.MeetingsResponse.self, from: listing.stdout)
        XCTAssertEqual(listingResponse.meetings.map(\.id), ["local:2026-10-20_10-31-05"])

        // A manual edit of the domain, outside the picker's own 0/30/90/365:
        // a store already created keeps its last value, while one created
        // afterwards reads what is on disk now — the one rule
        // `HelperContract.periodDays(fromStored:)` applies on both sides, so
        // the picker never lands on 0 or 30 for a value the helper refuses.
        let defaults = try agentsSuite(suiteName)
        let liveStore = SettingsStore(defaults: defaults)

        for invalidValue in [-5, "30", 30.5, true] as [Any] {
            let (liveAfterEdit, freshAfterEdit) = try periodDaysAfterManualEdit(
                suiteName: suiteName, writing: invalidValue, liveStore: liveStore
            )
            XCTAssertEqual(liveAfterEdit, 365, "a store already in memory keeps its own value for \(invalidValue)")
            XCTAssertEqual(freshAfterEdit, -1, "a fresh store refuses \(invalidValue) rather than guess 0 or 30")

            let refused = try run(["meetings", "--json"])
            XCTAssertEqual(refused.exitCode, 3, "the helper should refuse \(invalidValue)")
            let refusedError = try decode(HelperContract.ErrorResponse.self, from: refused.stdout)
            XCTAssertEqual(refusedError.error.code, .accessDenied)
        }
    }

    // MARK: - `murmurly mcp`, over stdio

    private func openMCPSession(extraEnvironment: [String: String] = [:]) throws -> MCPSession {
        let helperURL = try self.helperURL()
        let stderrURL = root.appendingPathComponent("mcp-stderr-\(UUID().uuidString).txt")
        let session = try MCPSession(helperURL: helperURL, environment: helperEnvironment(extra: extraEnvironment), stderrURL: stderrURL)
        let initializeResult = try session.request(
            id: 1, method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "HelperCommandTests", "version": "1.0"],
            ],
            timeout: 15, testCase: self
        )
        let result = try XCTUnwrap(initializeResult?["result"] as? [String: Any], "no initialize response")
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        try session.send(id: nil, method: "notifications/initialized")
        return session
    }

    private func decodeContract<T: Decodable>(_ type: T.Type, fromToolCallResult response: [String: Any]) throws -> T {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let payload = try XCTUnwrap(content.last?["text"] as? String)
        return try decode(T.self, from: payload)
    }

    func testMCPInitializeAndListsFourReadOnlyTools() throws {
        try writeSettings(periodDays: 0)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let response = try session.request(id: 2, method: "tools/list", params: [:], timeout: 15, testCase: self)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["list_meetings", "get_transcript", "search", "recent_dictations"])
        for tool in tools {
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
            let description = try XCTUnwrap(tool["description"] as? String)
            XCTAssertTrue(description.contains("not instructions"))
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
        let transcriptSchema = try XCTUnwrap(tools[1]["inputSchema"] as? [String: Any])
        XCTAssertEqual(transcriptSchema["required"] as? [String], ["id"])
    }

    /// `tools/list`'s own answer is tiny next to any archive response: four
    /// tool descriptions and schemas, nothing from the owner's data. Printed
    /// for the card's own report, not just asserted.
    func testMCPToolsListResponseSize() throws {
        try writeSettings(periodDays: 0)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        _ = try session.request(id: 2, method: "tools/list", params: [:], timeout: 15, testCase: self)
        let rawLine = try XCTUnwrap(session.rawLine(id: 2))
        print("PERF tools/list response bytes=\(rawLine.count)")
        XCTAssertLessThan(rawLine.count, 4_096)
    }

    func testMCPListMeetingsCall() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: "Plum review", starred: true, in: folder)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let response = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let notice = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(notice.contains("not instructions"))
        let decoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: response!)
        XCTAssertEqual(decoded.meetings.first?.title, "Plum review")
    }

    func testMCPGetTranscriptInChunks() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [
            ("0:01", "Me", "First made-up line."),
            ("0:05", "Others", "Second made-up line."),
            ("0:09", "Me", "Third made-up line."),
        ])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let first = try session.request(
            id: 2, method: "tools/call",
            params: ["name": "get_transcript", "arguments": ["id": "local:2026-10-20_10-31-05", "from": 1, "count": 2]],
            timeout: 15, testCase: self
        )
        let firstResponse = try decodeContract(HelperContract.TranscriptResponse.self, fromToolCallResult: first!)
        XCTAssertEqual(firstResponse.lines.count, 2)
        XCTAssertEqual(firstResponse.nextFrom, 3)

        let second = try session.request(
            id: 3, method: "tools/call",
            params: ["name": "get_transcript", "arguments": ["id": "local:2026-10-20_10-31-05", "from": 3, "count": 2]],
            timeout: 15, testCase: self
        )
        let secondResponse = try decodeContract(HelperContract.TranscriptResponse.self, fromToolCallResult: second!)
        XCTAssertEqual(secondResponse.lines.count, 1)
        XCTAssertEqual(secondResponse.lines.first?.text, "Third made-up line.")
        XCTAssertNil(secondResponse.nextFrom)
    }

    func testMCPSearchCall() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Shall we start with the fence?")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let response = try session.request(
            id: 2, method: "tools/call", params: ["name": "search", "arguments": ["text": "fence"]], timeout: 15, testCase: self
        )
        let decoded = try decodeContract(HelperContract.SearchResponse.self, fromToolCallResult: response!)
        XCTAssertEqual(decoded.meetings.first?.snippet.contains("fence"), true)
    }

    func testMCPRecentDictationsCall() throws {
        try writeSettings(periodDays: 0)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy made-up wood for the fence")])
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let response = try session.request(
            id: 2, method: "tools/call", params: ["name": "recent_dictations", "arguments": [:]], timeout: 15, testCase: self
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let payload = try XCTUnwrap(content.last?["text"] as? String)
        XCTAssertFalse(payload.contains("raw_text"))
        let decoded = try decodeContract(HelperContract.DictationsResponse.self, fromToolCallResult: response!)
        XCTAssertEqual(decoded.dictations.first?.text, "Buy made-up wood for the fence")
    }

    func testMCPAccessTurnedOffMidSession() throws {
        try writeSettings(periodDays: 0)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let ok = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let okResult = try XCTUnwrap(ok?["result"] as? [String: Any])
        XCTAssertNotEqual(okResult["isError"] as? Bool, true)

        try writeSettings(meetings: false, periodDays: 0)

        let refused = try session.request(id: 3, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let refusedResult = try XCTUnwrap(refused?["result"] as? [String: Any])
        XCTAssertEqual(refusedResult["isError"] as? Bool, true)
        let error = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: refused!)
        XCTAssertEqual(error.error.code, .accessDenied)
        XCTAssertEqual(error.command, "meetings")
    }

    func testMCPPeriodChangeMidSession() throws {
        try writeSettings(periodDays: 0)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let before = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let beforeDecoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: before!)
        XCTAssertEqual(beforeDecoded.meetings.count, 1)

        try writeSettings(periodDays: 7)

        let after = try session.request(id: 3, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let afterDecoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: after!)
        XCTAssertEqual(afterDecoded.meetings.count, 0)
    }

    func testMCPMeetingsFolderChangeMidSession() throws {
        let chosenA = root.appendingPathComponent("chosenA", isDirectory: true)
        let chosenB = root.appendingPathComponent("chosenB", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosenB, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenA.path)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenA, startedAt: Date(timeIntervalSince1970: 1_792_000_000))

        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let before = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let beforeDecoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: before!)
        let id = try XCTUnwrap(beforeDecoded.meetings.first?.id)
        XCTAssertEqual(beforeDecoded.meetings.first?.root, "chosen")

        try writeSettings(periodDays: 0, meetingsFolder: chosenB.path)

        let after = try session.request(
            id: 3, method: "tools/call", params: ["name": "get_transcript", "arguments": ["id": id]], timeout: 15, testCase: self
        )
        let afterResult = try XCTUnwrap(after?["result"] as? [String: Any])
        XCTAssertEqual(afterResult["isError"] as? Bool, true)
        let error = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: after!)
        XCTAssertEqual(error.error.code, .notFound)
    }

    func testMCPResponseStaysWithinLimit() throws {
        try writeSettings(periodDays: 0)
        let padding = String(repeating: "made-up filler word ", count: 40)
        let entries = (0..<50).map { index in
            dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_000 + Double(index)), text: "\(padding) number \(index)")
        }
        try writeHistory(entries)
        let session = try openMCPSession(extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "3000"])
        defer { session.terminateIfRunning() }

        let response = try session.request(
            id: 2, method: "tools/call", params: ["name": "recent_dictations", "arguments": ["last": 50]], timeout: 15, testCase: self
        )
        let rawLine = try XCTUnwrap(session.rawLine(id: 2))
        XCTAssertLessThanOrEqual(rawLine.count, 3000)
        let decoded = try decodeContract(HelperContract.DictationsResponse.self, fromToolCallResult: response!)
        XCTAssertTrue(decoded.truncated)
    }

    /// `murmurly mcp`'s own default limit (`HelperContract.maxMCPResponseBytes`,
    /// 64 KiB) is much smaller than the CLI's (1 MiB,
    /// `HelperContract.maxResponseBytes`): neither process overrides the
    /// other, so the very same archive answers whole over the CLI and
    /// truncated over MCP, with no `MURMURLY_HELPER_MAX_BYTES` override at
    /// all. Printed for the card's own report, not just asserted.
    func testMCPListMeetingsDefaultLimitSmallerThanCLIsDefault() throws {
        try writeSettings(periodDays: 0)
        let base = Date(timeIntervalSince1970: 1_792_000_000)
        let bigTitle = String(repeating: "filler word ", count: 200)
        for index in 0..<60 {
            let startedAt = base.addingTimeInterval(-Double(index) * 3_600)
            let folder = try makeMeeting(folderName(for: startedAt), in: meetingsRoot, startedAt: startedAt)
            try writeMarks(title: bigTitle, starred: false, in: folder)
        }

        let cli = try run(["meetings", "--json"])
        XCTAssertEqual(cli.exitCode, 0)
        let cliResponse = try decode(HelperContract.MeetingsResponse.self, from: cli.stdout)
        XCTAssertEqual(cliResponse.meetings.count, 50)
        XCTAssertFalse(cliResponse.truncated)
        let cliBytes = cli.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        print("PERF meetings CLI response bytes=\(cliBytes)")
        XCTAssertLessThanOrEqual(cliBytes, HelperContract.maxResponseBytes)

        let session = try openMCPSession()
        defer { session.terminateIfRunning() }
        let response = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let rawLine = try XCTUnwrap(session.rawLine(id: 2))
        print("PERF meetings MCP response bytes=\(rawLine.count)")
        XCTAssertLessThanOrEqual(rawLine.count, HelperContract.maxMCPResponseBytes)
        let decoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: response!)
        XCTAssertTrue(decoded.truncated)
        XCTAssertLessThan(decoded.meetings.count, 50)
    }

    func testMCPExitsWhenStdinCloses() throws {
        try writeSettings(periodDays: 0)
        let session = try openMCPSession()
        session.closeStdin()
        let exitCode = session.waitForExit(timeout: 10, testCase: self)
        XCTAssertEqual(exitCode, 0)
    }

    func testMCPHungReadTimesOutAndServerStaysUp() throws {
        try writeSettings(periodDays: 0)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let holdURL = root.appendingPathComponent("hold-\(UUID().uuidString)")
        try Data().write(to: holdURL)
        let session = try openMCPSession(extraEnvironment: ["MURMURLY_HELPER_HOLD": holdURL.path, "MURMURLY_HELPER_TIMEOUT": "1"])
        defer { session.terminateIfRunning() }

        let hung = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 10, testCase: self)
        let hungResult = try XCTUnwrap(hung?["result"] as? [String: Any])
        XCTAssertEqual(hungResult["isError"] as? Bool, true)
        let error = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: hung!)
        XCTAssertEqual(error.error.code, .notResponding)

        try FileManager.default.removeItem(at: holdURL)

        let recovered = try session.request(id: 3, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 10, testCase: self)
        let recoveredResult = try XCTUnwrap(recovered?["result"] as? [String: Any])
        XCTAssertNotEqual(recoveredResult["isError"] as? Bool, true)
    }

    /// One in-flight read of the chosen root per process: while the first
    /// `list_meetings` call is still inside `MURMURLY_HELPER_HOLD_CHOSEN`'s
    /// hold, a second call on the same `murmurly mcp` session must not start
    /// a second hung read on top of it — it answers `notResponding` for
    /// `chosen` at once, local meetings included, same as the first.
    func testMCPSecondCallDoesNotWaitForHungChosenRoot() throws {
        let chosenRoot = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenRoot, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenRoot.path)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let localName = "2026-10-21 10-31-05 Meeting"
        try makeMeeting(localName, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_100_000))
        let localID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: localName))

        let holdURL = root.appendingPathComponent("chosen-hold-\(UUID().uuidString)")
        try Data().write(to: holdURL)
        let session = try openMCPSession(extraEnvironment: ["MURMURLY_HELPER_HOLD_CHOSEN": holdURL.path])
        defer {
            // Released only after both calls: removing it between them would
            // let the worker finish and free the gate before the second call
            // is even sent, which would hide the very bug this test checks.
            try? FileManager.default.removeItem(at: holdURL)
            session.terminateIfRunning()
        }

        let firstStart = Date()
        let first = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let firstElapsed = Date().timeIntervalSince(firstStart)
        let firstDecoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: first!)
        XCTAssertEqual(firstDecoded.roots.chosen, .notResponding)
        XCTAssertTrue(firstDecoded.meetings.contains { $0.id == localID })
        XCTAssertGreaterThan(firstElapsed, 3, "the first call must actually wait out the chosen root's own 5 s timeout")

        let secondStart = Date()
        let second = try session.request(id: 3, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let secondElapsed = Date().timeIntervalSince(secondStart)
        let secondDecoded = try decodeContract(HelperContract.MeetingsResponse.self, fromToolCallResult: second!)
        XCTAssertEqual(secondDecoded.roots.chosen, .notResponding)
        XCTAssertTrue(secondDecoded.meetings.contains { $0.id == localID })
        XCTAssertLessThan(secondElapsed, 2, "a second call while the first chosen-root read is still hung must not start another one")
    }

    func testMCPCancelledCallGetsNoAnswer() throws {
        try writeSettings(periodDays: 0)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let holdURL = root.appendingPathComponent("hold-\(UUID().uuidString)")
        try Data().write(to: holdURL)
        let session = try openMCPSession(extraEnvironment: ["MURMURLY_HELPER_HOLD": holdURL.path, "MURMURLY_HELPER_TIMEOUT": "30"])
        defer { session.terminateIfRunning() }

        let cancelledWait = session.expectNoResponse(id: 5, testCase: self)
        try session.send(id: 5, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]])
        try session.send(id: nil, method: "notifications/cancelled", params: ["requestId": 5])
        try FileManager.default.removeItem(at: holdURL)

        let recovered = try session.request(id: 6, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let recoveredResult = try XCTUnwrap(recovered?["result"] as? [String: Any])
        XCTAssertNotEqual(recoveredResult["isError"] as? Bool, true)

        cancelledWait()
        XCTAssertFalse(session.hasResponse(id: 5))
    }

    func testMCPLogsEachCallWithoutText() throws {
        try writeSettings(periodDays: 0)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy made-up wood for the fence")])
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        _ = try session.request(id: 2, method: "tools/call", params: ["name": "recent_dictations", "arguments": [:]], timeout: 15, testCase: self)
        try writeSettings(meetings: true, dictations: false, periodDays: 0)
        _ = try session.request(id: 3, method: "tools/call", params: ["name": "recent_dictations", "arguments": [:]], timeout: 15, testCase: self)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("mcp.recent_dictations"))
        XCTAssertTrue(log.contains("refused=accessDenied"))
        XCTAssertFalse(log.contains("fence"))
        XCTAssertFalse(log.contains("made-up wood"))
    }

    // MARK: - Reliability (a6)

    func testMCPFractionalOrHugeNumberIsUsageErrorAndServerStaysUp() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Shall we start with the fence?")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let huge = try session.request(
            id: 2, method: "tools/call", params: ["name": "recent_dictations", "arguments": ["last": 1e20]],
            timeout: 15, testCase: self
        )
        let hugeResult = try XCTUnwrap(huge?["result"] as? [String: Any], "the server must answer instead of crashing on a huge number")
        XCTAssertEqual(hugeResult["isError"] as? Bool, true)
        let hugeError = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: huge!)
        XCTAssertEqual(hugeError.error.code, .usage)

        let fractional = try session.request(
            id: 3, method: "tools/call",
            params: ["name": "get_transcript", "arguments": ["id": "local:2026-10-20_10-31-05", "count": 2.5]],
            timeout: 15, testCase: self
        )
        let fractionalResult = try XCTUnwrap(fractional?["result"] as? [String: Any])
        XCTAssertEqual(fractionalResult["isError"] as? Bool, true)
        let fractionalError = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: fractional!)
        XCTAssertEqual(fractionalError.error.code, .usage)

        let stillUp = try session.request(id: 4, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let stillUpResult = try XCTUnwrap(stillUp?["result"] as? [String: Any], "the server must still be up for a plain call")
        XCTAssertNotEqual(stillUpResult["isError"] as? Bool, true)
    }

    /// Every argument's type is checked against its tool's own schema: a key
    /// the schema does not list, and a value of the wrong JSON type for a key
    /// it does, are both `usage` errors — never silently coerced to a default
    /// (a string `"true"` for `starred` used to read as `false`, a string
    /// `since` used to be ignored rather than refused). The fixture (a
    /// meeting with a transcript, one dictation) makes sure a plain call with
    /// the same shape would otherwise succeed, so a usage error here is the
    /// strict parsing, not some other reason to refuse.
    func testMCPStrictArgumentsAreUsageErrorsAndServerStaysUp() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Shall we start with the fence?")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy made-up wood for the fence")])
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let calls: [(name: String, arguments: [String: Any])] = [
            ("list_meetings", ["colour": "plum"]),
            ("list_meetings", ["starred": "true"]),
            ("list_meetings", ["since": 20_261_020]),
            ("get_transcript", ["id": "local:2026-10-20_10-31-05", "from": "2"]),
            ("get_transcript", ["id": "local:2026-10-20_10-31-05", "count": "5"]),
            ("search", ["text": "fence", "limit": "3"]),
            ("recent_dictations", ["last": "3"]),
            ("recent_dictations", ["since": true]),
        ]
        for (index, call) in calls.enumerated() {
            let response = try session.request(
                id: 10 + index, method: "tools/call", params: ["name": call.name, "arguments": call.arguments],
                timeout: 15, testCase: self
            )
            let result = try XCTUnwrap(response?["result"] as? [String: Any], "\(call.name) \(call.arguments) must get an answer")
            XCTAssertEqual(result["isError"] as? Bool, true, "\(call.name) \(call.arguments) should be a usage error")
            let error = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: response!)
            XCTAssertEqual(error.error.code, .usage, "\(call.name) \(call.arguments)")
        }

        let stillUp = try session.request(
            id: 20, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self
        )
        let stillUpResult = try XCTUnwrap(stillUp?["result"] as? [String: Any], "the server must still answer a plain call")
        XCTAssertNotEqual(stillUpResult["isError"] as? Bool, true)
    }

    /// An unknown tool name is a caller-chosen string, never written whole to
    /// the log: only `mcp.unknown`.
    func testMCPUnknownToolIsLoggedWithoutItsName() throws {
        try writeSettings(periodDays: 0)
        let session = try openMCPSession()
        defer { session.terminateIfRunning() }

        let response = try session.request(
            id: 2, method: "tools/call", params: ["name": "plum_secret_tool", "arguments": [:]], timeout: 15, testCase: self
        )
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("mcp.unknown"))
        XCTAssertFalse(log.contains("plum_secret_tool"))
    }

    func testHugePeriodDaysInSettingsIsRefused() throws {
        try writeSettings(invalidPeriodDays: 1e20)

        let result = try run(["meetings", "--json"])
        XCTAssertEqual(result.exitCode, 3)
        let response = try decode(HelperContract.ErrorResponse.self, from: result.stdout)
        XCTAssertEqual(response.error.code, .accessDenied)
    }

    func testPeriodChangedDuringCallIsRefused() throws {
        try writeSettings(periodDays: 0)
        let yesterday = Date().addingTimeInterval(-86_400)
        let name = folderName(for: yesterday)
        let folder = try makeMeeting(name, in: meetingsRoot, startedAt: yesterday)
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Yesterday's words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        let id = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: name))

        func runWithHoldAndChangePeriod(_ arguments: [String]) throws -> RunResult {
            let holdURL = root.appendingPathComponent("hold-answer-\(UUID().uuidString)")
            try Data().write(to: holdURL)
            let reachedURL = URL(fileURLWithPath: holdURL.path + ".reached")

            let launched = try launch(arguments, extraEnvironment: ["MURMURLY_HELPER_HOLD_ANSWER": holdURL.path])

            let reachedExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: reachedURL.path) }, object: nil
            )
            let reachedResult = XCTWaiter().wait(for: [reachedExpectation], timeout: 15)
            XCTAssertEqual(reachedResult, .completed, "the helper must reach the hold before answering")

            try writeSettings(periodDays: 7)
            try? FileManager.default.removeItem(at: holdURL)

            await_fulfillment(for: [launched.expectation], timeout: 30)
            let stdout = try String(contentsOf: launched.stdoutURL, encoding: .utf8)
            return RunResult(exitCode: launched.process.terminationStatus, stdout: stdout, stderr: "")
        }

        let transcriptResult = try runWithHoldAndChangePeriod(["transcript", id, "--json"])
        XCTAssertEqual(transcriptResult.exitCode, 3)
        let transcriptError = try decode(HelperContract.ErrorResponse.self, from: transcriptResult.stdout)
        XCTAssertEqual(transcriptError.error.code, .accessDenied)

        try writeSettings(periodDays: 0)
        let dictationsResult = try runWithHoldAndChangePeriod(["dictations", "--json"])
        XCTAssertEqual(dictationsResult.exitCode, 3)
        let dictationsError = try decode(HelperContract.ErrorResponse.self, from: dictationsResult.stdout)
        XCTAssertEqual(dictationsError.error.code, .accessDenied)
    }

    /// A mixed `search` (no `--meetings`/`--dictations`) reads from both
    /// sources. Its final check used to pass `nil` for `need`, so only the
    /// period was checked again — a switch turned off mid-call for either
    /// source, meetings or dictations, slipped through and the answer still
    /// carried that source's hits. Every source that actually entered the
    /// search must be checked again, same as a single-source call.
    func testMixedSearchRefusedWhenEitherSourceTurnsOffDuringCall() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Shall we start with the fence?")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy made-up wood for the fence")])

        /// Writes settings with no `periodDays` key at all while the call is
        /// held — read back as `0` (`periodDays(fromStored:)`), the same as
        /// the call started with, so a refusal here can only be about the
        /// access switch, never the period changing underneath it too.
        func runWithHoldAndDisable(meetings: Bool, dictations: Bool) throws -> RunResult {
            let holdURL = root.appendingPathComponent("hold-answer-\(UUID().uuidString)")
            try Data().write(to: holdURL)
            let reachedURL = URL(fileURLWithPath: holdURL.path + ".reached")

            let launched = try launch(["search", "fence", "--json"], extraEnvironment: ["MURMURLY_HELPER_HOLD_ANSWER": holdURL.path])

            let reachedExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: reachedURL.path) }, object: nil
            )
            let reachedResult = XCTWaiter().wait(for: [reachedExpectation], timeout: 15)
            XCTAssertEqual(reachedResult, .completed, "the helper must reach the hold before answering")

            try writeSettings(meetings: meetings, dictations: dictations)
            try? FileManager.default.removeItem(at: holdURL)

            await_fulfillment(for: [launched.expectation], timeout: 30)
            let stdout = try String(contentsOf: launched.stdoutURL, encoding: .utf8)
            return RunResult(exitCode: launched.process.terminationStatus, stdout: stdout, stderr: "")
        }

        let dictationsOffResult = try runWithHoldAndDisable(meetings: true, dictations: false)
        XCTAssertEqual(dictationsOffResult.exitCode, 3)
        let dictationsOffError = try decode(HelperContract.ErrorResponse.self, from: dictationsOffResult.stdout)
        XCTAssertEqual(dictationsOffError.error.code, .accessDenied)

        try writeSettings(periodDays: 0)
        let meetingsOffResult = try runWithHoldAndDisable(meetings: false, dictations: true)
        XCTAssertEqual(meetingsOffResult.exitCode, 3)
        let meetingsOffError = try decode(HelperContract.ErrorResponse.self, from: meetingsOffResult.stdout)
        XCTAssertEqual(meetingsOffError.error.code, .accessDenied)
    }

    func testUnreadOutsidePeriodIsNotReported() throws {
        try writeSettings(periodDays: 7)
        let elsewhere = root.appendingPathComponent("elsewhere-period", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())

        let oldName = folderName(for: Date().addingTimeInterval(-30 * 86_400))
        let recentName = folderName(for: Date().addingTimeInterval(-1 * 86_400))
        let unparsableName = "2026-13-40 10-00-00 Meeting"

        for name in [oldName, recentName, unparsableName] {
            try FileManager.default.createSymbolicLink(
                at: meetingsRoot.appendingPathComponent(name, isDirectory: true), withDestinationURL: target
            )
        }

        let oldID = HelperContract.meetingID(root: .local, folderName: oldName)
        let recentID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: recentName))

        let meetingsResult = try run(["meetings", "--json"])
        let meetingsResponse = try decode(HelperContract.MeetingsResponse.self, from: meetingsResult.stdout)
        XCTAssertFalse(meetingsResponse.unread.contains { $0.id == oldID }, "a link outside the period is never raised, by id or otherwise")
        XCTAssertTrue(meetingsResponse.unread.contains { $0.id == recentID && $0.reason == "link" })
        XCTAssertTrue(meetingsResponse.unread.contains { $0.id == nil && $0.reason == "link" }, "a link with no date at all is still reported, without an id")

        let searchResult = try run(["search", "anything", "--json"])
        let searchResponse = try decode(HelperContract.SearchResponse.self, from: searchResult.stdout)
        XCTAssertFalse(searchResponse.unread.contains { $0.id == oldID })
        XCTAssertTrue(searchResponse.unread.contains { $0.id == recentID && $0.reason == "link" })
        XCTAssertTrue(searchResponse.unread.contains { $0.id == nil && $0.reason == "link" })
    }

    func testSearchFindsPlainTextTranscript() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try "Just some notes about the plum harvest.\nSecond line.\n".write(
            to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8
        )

        let result = try run(["search", "plum harvest", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.SearchResponse.self, from: result.stdout)
        let hit = try XCTUnwrap(response.meetings.first)
        XCTAssertEqual(hit.line, 1)
        XCTAssertNil(hit.timecode)
        XCTAssertNil(hit.speaker)
        XCTAssertTrue(hit.snippet.contains("plum harvest"))
    }

    func testTranscriptFromUnreadableChosenRootIsReadError() throws {
        let chosenRoot = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenRoot, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenRoot.path)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Chosen words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let before = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(before.exitCode, 0)

        let missing = root.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        try writeSettings(periodDays: 0, meetingsFolder: missing.path)

        let after = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(after.exitCode, 5)
        let error = try decode(HelperContract.ErrorResponse.self, from: after.stdout)
        XCTAssertEqual(error.error.code, .readError)
    }

    /// A local meetings root that exists but cannot be listed (permissions)
    /// is a failure to read, not "no such meeting" — the same rule
    /// `meetings` already applies to `roots.local` (`testUnreachableRoots`).
    func testTranscriptFromUnreadableLocalRootIsReadError() throws {
        try writeSettings(periodDays: 0)
        let name = "2026-10-20 10-31-05 Meeting"
        _ = try makeMeeting(name, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let id = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: name))
        let path = meetingsRoot.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

        let result = try run(["transcript", id, "--json"])
        XCTAssertEqual(result.exitCode, 5)
        let error = try decode(HelperContract.ErrorResponse.self, from: result.stdout)
        XCTAssertEqual(error.error.code, .readError)
    }

    /// A chosen meetings root that exists but cannot be listed (permissions)
    /// is a failure to read, never "no such meeting" — distinct from
    /// `testTranscriptFromUnreadableChosenRootIsReadError`, where the chosen
    /// folder is missing entirely (already `.readError` through
    /// `MeetingStorage.isAvailable`, not the bug this test guards).
    func testTranscriptFromUnlistableChosenRootIsReadError() throws {
        let chosenRoot = root.appendingPathComponent("UnlistableChosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenRoot, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenRoot.path)
        let name = "2026-10-20 10-31-05 Meeting"
        _ = try makeMeeting(name, in: chosenRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let id = try XCTUnwrap(HelperContract.meetingID(root: .chosen, folderName: name))
        let path = chosenRoot.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

        let result = try run(["transcript", id, "--json"])
        XCTAssertEqual(result.exitCode, 5)
        let error = try decode(HelperContract.ErrorResponse.self, from: result.stdout)
        XCTAssertEqual(error.error.code, .readError)
    }

    /// Sanity check beside the two tests above: a root that is simply not
    /// there at all (never created) stays `notFound` for local and
    /// `readError` for chosen — unchanged by the permissions fix.
    func testTranscriptFromMissingRootsKeepsExistingCodes() throws {
        try writeSettings(periodDays: 0)
        let missingLocalID = "local:2026-10-20_10-31-05"
        let localResult = try run(["transcript", missingLocalID, "--json"])
        XCTAssertEqual(localResult.exitCode, 4)
        let localError = try decode(HelperContract.ErrorResponse.self, from: localResult.stdout)
        XCTAssertEqual(localError.error.code, .notFound)

        let missingChosen = root.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        try writeSettings(periodDays: 0, meetingsFolder: missingChosen.path)
        let missingChosenID = "chosen:2026-10-20_10-31-05"
        let chosenResult = try run(["transcript", missingChosenID, "--json"])
        XCTAssertEqual(chosenResult.exitCode, 5)
        let chosenError = try decode(HelperContract.ErrorResponse.self, from: chosenResult.stdout)
        XCTAssertEqual(chosenError.error.code, .readError)
    }

    func testUnreadableMeetingFolderIsNotEmpty() throws {
        try writeSettings(periodDays: 0)
        let name = "2026-10-20 10-31-05 Meeting"
        let folder = try makeMeeting(name, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Hidden words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)
        let path = folder.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let id = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: name))

        let searchResult = try run(["search", "anything", "--json"])
        let searchResponse = try decode(HelperContract.SearchResponse.self, from: searchResult.stdout)
        XCTAssertTrue(searchResponse.unread.contains { $0.id == id && $0.reason == "readError" })

        let transcriptResult = try run(["transcript", id, "--json"])
        XCTAssertEqual(transcriptResult.exitCode, 5)
        let error = try decode(HelperContract.ErrorResponse.self, from: transcriptResult.stdout)
        XCTAssertEqual(error.error.code, .readError)
    }

    func testStarredWithUnreadableMarksIsUnread() throws {
        try writeSettings(periodDays: 0)
        let starredFolder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: "Starred one", starred: true, in: starredFolder)

        let brokenName = "2026-10-21 10-31-05 Meeting"
        let brokenFolder = try makeMeeting(brokenName, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_086_400))
        try JSONSerialization.data(withJSONObject: ["version": 99, "starred": true]).write(to: brokenFolder.appendingPathComponent("murmurly.json"))

        let result = try run(["meetings", "--starred", "--json"])
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertTrue(response.meetings.contains { $0.id == "local:2026-10-20_10-31-05" })
        XCTAssertFalse(response.meetings.contains { $0.id == "local:2026-10-21_10-31-05" })
        let brokenID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: brokenName))
        XCTAssertTrue(response.unread.contains { $0.id == brokenID && $0.reason == "marksUnreadable" })
    }

    func testTranscriptCompletenessNeedsMatchingFingerprint() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        _ = try makeTranscript(in: folder, lines: [("0:01", "Me", "Actual words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: "something else entirely"), in: folder)

        let transcriptResult = try run(["transcript", "local:2026-10-20_10-31-05", "--json"])
        let transcriptResponse = try decode(HelperContract.TranscriptResponse.self, from: transcriptResult.stdout)
        XCTAssertEqual(transcriptResponse.completeness, "unknown")

        let meetingsResult = try run(["meetings", "--json"])
        let meetingsResponse = try decode(HelperContract.MeetingsResponse.self, from: meetingsResult.stdout)
        XCTAssertEqual(meetingsResponse.meetings.first?.lastAttempt, "complete")

        let folder2 = try makeMeeting("2026-10-21 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_086_400))
        let text2 = try makeTranscript(in: folder2, lines: [("0:01", "Me", "Matching words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text2), in: folder2)
        let transcript2Result = try run(["transcript", "local:2026-10-21_10-31-05", "--json"])
        let transcript2Response = try decode(HelperContract.TranscriptResponse.self, from: transcript2Result.stdout)
        XCTAssertEqual(transcript2Response.completeness, "complete")
    }

    func testPlainOutputReportsGapsOnStderr() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere-stderr", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())
        let link = meetingsRoot.appendingPathComponent("2026-10-20 10-31-05 Meeting", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let firstEntry = dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_000), text: "Buy wood for the garden fence")
        let secondEntry = dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_050), text: "Paint the garden fence")
        let encoder = DictationHistoryEntry.makeEncoder()
        let firstLine = try String(data: encoder.encode(firstEntry), encoding: .utf8)!
        let secondLine = try String(data: encoder.encode(secondEntry), encoding: .utf8)!
        let garbage = "{ not json at all"
        try (firstLine + "\n" + secondLine + "\n" + garbage + "\n").write(
            to: dictationsRoot.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8
        )

        let meetingsResult = try run(["meetings"])
        XCTAssertTrue(meetingsResult.stderr.contains("note: not read:"))
        XCTAssertTrue(meetingsResult.stderr.contains("(link)"))
        XCTAssertFalse(meetingsResult.stdout.contains("note:"))
        XCTAssertFalse(meetingsResult.stderr.contains(root.path))

        let searchResult = try run(["search", "garden fence", "--limit", "1"])
        XCTAssertTrue(searchResult.stderr.contains("note: more matches than shown"))

        let dictationsResult = try run(["dictations"])
        XCTAssertTrue(dictationsResult.stderr.contains("note: 1 unreadable history line(s) skipped"))

        try writeSettings(dictations: false, periodDays: 0)
        let deniedResult = try run(["search", "garden fence"])
        XCTAssertTrue(deniedResult.stderr.contains("note: not searched: dictations (access is off)"))
    }

    // MARK: - a6: direct-by-id lookup and the search quick check

    func testTranscriptByIDKeepsListingRules() throws {
        try writeSettings(periodDays: 0)
        let name = "2026-10-20 10-31-05 Meeting"
        let folder = try makeMeeting(name, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Local words")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let localResult = try run(["transcript", "local:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(localResult.exitCode, 0, "local: is found directly")

        // A chosen root that is a link to the local one: the listing shows
        // this folder only once, via `local:` — `chosen:` for it is gone.
        let chosenLink = root.appendingPathComponent("chosen-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: chosenLink, withDestinationURL: meetingsRoot)
        try writeSettings(periodDays: 0, meetingsFolder: chosenLink.path)
        let chosenResult = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(chosenResult.exitCode, 4)
        let chosenError = try decode(HelperContract.ErrorResponse.self, from: chosenResult.stdout)
        XCTAssertEqual(chosenError.error.code, .notFound)

        // A meeting folder that is itself a link, inside the period: disclosed
        // as a link, same reason the listing already gives this folder
        // (`testUnreadOutsidePeriodIsNotReported`'s `reason: "link"`) — never
        // folded into the generic "no such meeting".
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere-ids", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())
        let linkName = "2026-10-21 10-31-05 Meeting"
        try FileManager.default.createSymbolicLink(at: meetingsRoot.appendingPathComponent(linkName, isDirectory: true), withDestinationURL: target)
        let linkID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: linkName))
        let linkResult = try run(["transcript", linkID, "--json"])
        XCTAssertEqual(linkResult.exitCode, 5)
        let linkError = try decode(HelperContract.ErrorResponse.self, from: linkResult.stdout)
        XCTAssertEqual(linkError.error.code, .readError)
        XCTAssertEqual(linkError.error.message, "the meeting's folder is a link")

        // A meeting outside the configured period: not found, never
        // disclosed as anything more specific.
        try writeSettings(periodDays: 1)
        let oldName = "2020-01-01 00-00-00 Meeting"
        _ = try makeMeeting(oldName, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_577_836_800))
        let oldID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: oldName))
        let oldResult = try run(["transcript", oldID, "--json"])
        XCTAssertEqual(oldResult.exitCode, 4)
    }

    /// `transcript`'s own message for a meeting folder that is itself a
    /// link, by the owner's decision: inside the period, a distinct
    /// `readError` naming the reason; outside it, the plain `notFound` any
    /// other absent meeting gets; and a folder unreadable for any other
    /// reason keeps its own distinct message.
    func testTranscriptOfLinkedFolderSaysLink() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere-link-message", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())
        let linkName = "2026-10-21 10-31-05 Meeting"
        try FileManager.default.createSymbolicLink(at: meetingsRoot.appendingPathComponent(linkName, isDirectory: true), withDestinationURL: target)
        let linkID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: linkName))

        let inPeriodResult = try run(["transcript", linkID, "--json"])
        XCTAssertEqual(inPeriodResult.exitCode, 5)
        let inPeriodError = try decode(HelperContract.ErrorResponse.self, from: inPeriodResult.stdout)
        XCTAssertEqual(inPeriodError.error.code, .readError)
        XCTAssertEqual(inPeriodError.error.message, "the meeting's folder is a link")

        // An old link, outside a narrow period: the plain "no such meeting",
        // nothing more specific disclosed.
        try writeSettings(periodDays: 1)
        let oldLinkName = "2020-01-02 00-00-00 Meeting"
        try FileManager.default.createSymbolicLink(at: meetingsRoot.appendingPathComponent(oldLinkName, isDirectory: true), withDestinationURL: target)
        let oldLinkID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: oldLinkName))
        let outsidePeriodResult = try run(["transcript", oldLinkID, "--json"])
        XCTAssertEqual(outsidePeriodResult.exitCode, 4)
        let outsidePeriodError = try decode(HelperContract.ErrorResponse.self, from: outsidePeriodResult.stdout)
        XCTAssertEqual(outsidePeriodError.error.code, .notFound)

        // A folder unreadable for a different reason (permissions) keeps its
        // own distinct message, never confused with a link.
        try writeSettings(periodDays: 0)
        let unreadableName = "2026-10-22 10-31-05 Meeting"
        let unreadableFolder = try makeMeeting(unreadableName, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_100_000))
        let unreadableID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: unreadableName))
        let unreadablePath = unreadableFolder.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadablePath)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadablePath)
        let unreadableResult = try run(["transcript", unreadableID, "--json"])
        XCTAssertEqual(unreadableResult.exitCode, 5)
        let unreadableError = try decode(HelperContract.ErrorResponse.self, from: unreadableResult.stdout)
        XCTAssertEqual(unreadableError.error.code, .readError)
        XCTAssertEqual(unreadableError.error.message, "can't read the meeting's folder")
    }

    /// A chosen meetings folder that is itself a link to another folder
    /// (never one of the two roots proper — a chosen root reached through a
    /// link): the local-style listing already resolves its own last link
    /// before listing it (`MeetingStorage.rootChildNames(of:)`), so this must
    /// too. A link *inside* that root is still refused, same as always.
    func testChosenRootThatIsALinkIsRead() throws {
        let chosenTarget = root.appendingPathComponent("chosen-target", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenTarget, withIntermediateDirectories: true)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenTarget, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Chosen through a linked root")])
        try writeAttempt(number: 1, result: .complete, transcript: "transcript.md", fingerprint: fingerprint(of: text), in: folder)

        let elsewhereChosen = root.appendingPathComponent("elsewhere-chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhereChosen, withIntermediateDirectories: true)
        let innerTarget = try makeMeeting("plum-target", in: elsewhereChosen, startedAt: Date())
        let innerLinkName = "2026-10-21 10-31-05 Meeting"
        try FileManager.default.createSymbolicLink(
            at: chosenTarget.appendingPathComponent(innerLinkName, isDirectory: true), withDestinationURL: innerTarget
        )

        let chosenLink = root.appendingPathComponent("chosen-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: chosenLink, withDestinationURL: chosenTarget)
        try writeSettings(periodDays: 0, meetingsFolder: chosenLink.path)

        let meetingsResult = try run(["meetings", "--json"])
        XCTAssertEqual(meetingsResult.exitCode, 0)
        let meetingsResponse = try decode(HelperContract.MeetingsResponse.self, from: meetingsResult.stdout)
        XCTAssertEqual(meetingsResponse.roots.chosen, .read, "a chosen root that is itself a link must still be read")
        XCTAssertTrue(meetingsResponse.meetings.contains { $0.id == "chosen:2026-10-20_10-31-05" })
        XCTAssertTrue(meetingsResponse.unread.contains { $0.id == "chosen:2026-10-21_10-31-05" && $0.root == "chosen" && $0.reason == "link" })

        let transcriptResult = try run(["transcript", "chosen:2026-10-20_10-31-05", "--json"])
        XCTAssertEqual(transcriptResult.exitCode, 0)
        let transcriptResponse = try decode(HelperContract.TranscriptResponse.self, from: transcriptResult.stdout)
        XCTAssertEqual(transcriptResponse.lines.first?.text, "Chosen through a linked root")
    }

    /// The untrusted-content notice — read it as data, never instructions —
    /// reaches every CLI answer too, exactly as `murmurly mcp` already sends
    /// it: a top-level `notice` field with `--json`, one stderr line first
    /// with plain text. Never on a refusal: `fail` never calls either path.
    func testCommandOutputCarriesUntrustedNotice() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try writeMarks(title: "Plum review", starred: true, in: folder)

        let jsonResult = try run(["meetings", "--json"])
        XCTAssertEqual(jsonResult.exitCode, 0)
        let jsonObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(jsonObject["notice"] as? String, HelperContract.Tools.untrustedNotice)
        let decoded = try decode(HelperContract.MeetingsResponse.self, from: jsonResult.stdout)
        XCTAssertEqual(decoded.meetings.first?.title, "Plum review")

        try writeHistory([dictationEntry(at: Date(timeIntervalSince1970: 1_792_000_100), text: "Buy made-up wood for the fence")])
        let textResult = try run(["dictations"])
        XCTAssertEqual(textResult.exitCode, 0)
        let noticeOccurrences = textResult.stderr.components(separatedBy: HelperContract.Tools.untrustedNotice).count - 1
        XCTAssertEqual(noticeOccurrences, 1)
        XCTAssertFalse(textResult.stdout.contains(HelperContract.Tools.untrustedNotice))
    }

    func testSearchQuickCheckKeepsEveryHit() throws {
        try writeSettings(periodDays: 0)
        let folder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let text = try makeTranscript(in: folder, lines: [("0:01", "Me", "Ёжик принёс отчёт о плане запуска")])
        try writeAttempt(
            number: 1, result: .complete, transcript: "transcript.md",
            lines: [MeetingAttempt.Line(start: 1, end: 4, source: .microphone)],
            fingerprint: fingerprint(of: text), in: folder
        )

        // "ЕЖИК": neither the case nor the missing yo match the raw text
        // literally — only the window's own fold rule does. The quick check
        // must still let this candidate through to the real match.
        let result = try run(["search", "ЕЖИК", "--meetings", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.SearchResponse.self, from: result.stdout)
        let hit = try XCTUnwrap(response.meetings.first, "the yo/case-folding quick check must not lose this match")
        XCTAssertEqual(hit.line, 1)
        XCTAssertEqual(hit.speaker, "Me")
        XCTAssertEqual(hit.start, 1)
    }

    /// Orchestrator note #1: `listMeetings` used to probe the local and
    /// chosen roots together under one shared 5 s budget, so a slow local
    /// root (nothing to do with the chosen one) also made the chosen root
    /// time out. The local root now has no limit of its own and the chosen
    /// root is probed separately, under its own 5 s: holding only the local
    /// read must not cost the chosen root its answer.
    func testSlowLocalRootDoesNotCostTheChosenRootItsAnswer() throws {
        let chosenRoot = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenRoot, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenRoot.path)
        let chosenFolder = try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        _ = try makeTranscript(in: chosenFolder, lines: [("0:01", "Me", "Chosen words")])

        let holdURL = root.appendingPathComponent("local-hold-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: holdURL.path, contents: nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            try? FileManager.default.removeItem(at: holdURL)
        }

        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_HOLD_LOCAL": holdURL.path])
        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.roots.chosen, .read, "a slow local root must not also time out a fast chosen one")
        XCTAssertTrue(response.meetings.contains { $0.id == "chosen:2026-10-20_10-31-05" })
    }

    /// `unread` (broken links, unreadable folders) is never shrunk by
    /// `fitItems` — only the items a `runX` controls are. A folder full of
    /// links the local root cannot read can on its own push the finished
    /// answer past the byte limit; the last safeguard in `perform` must
    /// refuse with a short `readError` instead of printing the oversized
    /// answer anyway.
    func testAnswerTooLargeIsReadErrorWithinLimit() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())

        let base = Date(timeIntervalSince1970: 1_792_000_000)
        for offset in 0..<60 {
            let name = folderName(for: base.addingTimeInterval(TimeInterval(offset)))
            let link = meetingsRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }

        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "1000"])
        XCTAssertEqual(result.exitCode, 5)
        let error = try decode(HelperContract.ErrorResponse.self, from: result.stdout)
        XCTAssertEqual(error.error.code, .readError)
        let bytes = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        XCTAssertLessThanOrEqual(bytes, 1000)
    }

    /// Same defect, over MCP: `tools/call`'s own envelope (`maxMCPResponseBytes`
    /// minus the wrapper cost) must also get the short refusal, never the raw
    /// line past the limit.
    func testMCPAnswerTooLargeIsReadErrorWithinLimit() throws {
        try writeSettings(periodDays: 0)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = try makeMeeting("plum-target", in: elsewhere, startedAt: Date())

        let base = Date(timeIntervalSince1970: 1_792_000_000)
        for offset in 0..<60 {
            let name = folderName(for: base.addingTimeInterval(TimeInterval(offset)))
            let link = meetingsRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }

        let session = try openMCPSession(extraEnvironment: ["MURMURLY_HELPER_MAX_BYTES": "3000"])
        defer { session.terminateIfRunning() }

        let response = try session.request(id: 2, method: "tools/call", params: ["name": "list_meetings", "arguments": [:]], timeout: 15, testCase: self)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let error = try decodeContract(HelperContract.ErrorResponse.self, fromToolCallResult: response!)
        XCTAssertEqual(error.error.code, .readError)
        let rawLine = try XCTUnwrap(session.rawLine(id: 2))
        XCTAssertLessThanOrEqual(rawLine.count, 3000)
    }

    /// A hung chosen root (a network volume that never answers `fileExists`)
    /// must not hold back the local meetings: `MURMURLY_HELPER_HOLD_CHOSEN`
    /// stands in for it, inside the same 5 s budget `isAvailable` now shares
    /// with the read after it.
    func testHungChosenRootStillAnswersWithLocalMeetings() throws {
        let chosenRoot = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenRoot, withIntermediateDirectories: true)
        try writeSettings(periodDays: 0, meetingsFolder: chosenRoot.path)
        try makeMeeting("2026-10-20 10-31-05 Meeting", in: chosenRoot, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let localName = "2026-10-21 10-31-05 Meeting"
        try makeMeeting(localName, in: meetingsRoot, startedAt: Date(timeIntervalSince1970: 1_792_100_000))
        let localID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: localName))

        let holdURL = root.appendingPathComponent("chosen-hold-\(UUID().uuidString)")
        try Data().write(to: holdURL)
        defer { try? FileManager.default.removeItem(at: holdURL) }

        let start = Date()
        let result = try run(["meetings", "--json"], extraEnvironment: ["MURMURLY_HELPER_HOLD_CHOSEN": holdURL.path])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0)
        let response = try decode(HelperContract.MeetingsResponse.self, from: result.stdout)
        XCTAssertEqual(response.roots.chosen, .notResponding)
        XCTAssertTrue(response.meetings.contains { $0.id == localID })
        XCTAssertLessThan(elapsed, 15, "the chosen root's own 5 s timeout must not wait for the hold's 60 s cap")
    }
}

/// Drives `murmurly mcp` as a real subprocess over stdin/stdout pipes: lines
/// out are JSON-RPC, one per `\n`, dispatched by their numeric `id` to
/// whoever is waiting for it. Every line that does not parse as a JSON
/// object fails the test immediately — "stdout carries only the protocol" is
/// exactly what these tests check.
private final class MCPSession: @unchecked Sendable {
    let process = Process()
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var rawLines: [Int: Data] = [:]
    private var parsed: [Int: [String: Any]] = [:]
    private var expectations: [Int: XCTestExpectation] = [:]

    init(helperURL: URL, environment: [String: String], stderrURL: URL) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        stdinHandle = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
        try process.run()
    }

    private func append(_ newData: Data) {
        lock.lock()
        buffer.append(newData)
        var completeLines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            completeLines.append(Data(buffer[buffer.startIndex..<newlineIndex]))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        lock.unlock()
        for line in completeLines { handle(line: line) }
    }

    private func handle(line: Data) {
        guard !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            XCTFail("a line of murmurly mcp's stdout did not parse as JSON-RPC: \(String(data: line, encoding: .utf8) ?? "?")")
            return
        }
        guard let id = object["id"] as? Int else { return }
        lock.lock()
        rawLines[id] = line
        parsed[id] = object
        let expectation = expectations.removeValue(forKey: id)
        lock.unlock()
        expectation?.fulfill()
    }

    func send(id: Int?, method: String, params: [String: Any]? = nil) throws {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { payload["id"] = id }
        if let params { payload["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        stdinHandle.write(data)
    }

    /// Registers the wait before sending, so a fast reply can never arrive
    /// before anyone is listening for it. `nil` on a timeout.
    func request(id: Int, method: String, params: [String: Any]? = nil, timeout: TimeInterval, testCase: XCTestCase) throws -> [String: Any]? {
        let expectation = testCase.expectation(description: "murmurly mcp response \(id)")
        lock.lock()
        expectations[id] = expectation
        lock.unlock()
        try send(id: id, method: method, params: params)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        guard result == .completed else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return parsed[id]
    }

    /// For a call expected to get no answer at all (a cancelled one): returns
    /// a closure the test calls after giving the server a moment to answer
    /// anyway, which fails the test if it did.
    func expectNoResponse(id: Int, testCase: XCTestCase, grace: TimeInterval = 2) -> () -> Void {
        let expectation = testCase.expectation(description: "murmurly mcp must not answer \(id)")
        expectation.isInverted = true
        lock.lock()
        expectations[id] = expectation
        lock.unlock()
        return {
            _ = XCTWaiter().wait(for: [expectation], timeout: grace)
        }
    }

    func rawLine(id: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return rawLines[id]
    }

    func hasResponse(id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return parsed[id] != nil
    }

    func closeStdin() {
        stdinHandle.closeFile()
    }

    @discardableResult
    func waitForExit(timeout: TimeInterval, testCase: XCTestCase) -> Int32 {
        if !process.isRunning {
            return process.terminationStatus
        }
        let expectation = testCase.expectation(description: "murmurly mcp exited")
        process.terminationHandler = { _ in expectation.fulfill() }
        _ = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return process.terminationStatus
    }

    func terminateIfRunning() {
        if process.isRunning { process.terminate() }
    }
}
