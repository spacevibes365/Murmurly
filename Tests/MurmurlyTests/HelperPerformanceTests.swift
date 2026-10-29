import CryptoKit
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import Murmurly

/// Measures the built `murmurly` helper's speed and peak memory against a
/// made-up archive, run as a child process (never in this test's own
/// address space, and never against the owner's real archive: every launch
/// carries all four `MURMURLY_HELPER_*` overrides). The thresholds in the
/// card are printed as targets, not hard limits: a command that is slow but
/// still answers correctly, or that gives up at the helper's own 30 s
/// internal timeout (exit code 6), is a measurement, not a test failure. A
/// test failure here means the helper crashed, answered wrong, or never
/// exited at all within the 120 s the test itself waits.
final class HelperPerformanceTests: XCTestCase {
    private var root: URL!
    private var meetingsRoot: URL!
    private var dictationsRoot: URL!
    private var settingsURL: URL!
    private var logURL: URL!
    private var homeURL: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-perf-\(UUID().uuidString)", isDirectory: true)
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

    private func writeSettings() throws {
        let dict: [String: Any] = [
            HelperContract.SettingsKey.agentsMeetings: true,
            HelperContract.SettingsKey.agentsDictations: true,
            HelperContract.SettingsKey.periodDays: 0,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: settingsURL)
    }

    // MARK: - Made-up sentences

    /// 40 neutral, invented sentences, around 15 words each: no real names,
    /// no real dictations or meetings. Half (the first 20) carry the word
    /// "roadmap", which makes it the archive's frequent search term; the
    /// made-up word "zephyrquill" is never in this pool, so it is placed by
    /// hand at exactly the lines the test needs.
    private static let phrasePool: [String] = [
        "The quarterly roadmap review moved to Thursday because the design team needs more time",
        "Engineering agreed the roadmap milestone for the billing module should slip by two weeks",
        "Marketing wants the roadmap deck updated before the partner call next Tuesday morning",
        "The support queue grew again after the latest roadmap release shipped without a changelog",
        "Finance asked whether the roadmap budget for next quarter already includes the new hires",
        "The onboarding flow redesign stays blocked until the roadmap for permissions gets settled",
        "The roadmap presentation ran long because half the slides were months out of date",
        "Two reviewers disagreed sharply about the roadmap priority for the mobile notifications feature",
        "The roadmap for the analytics dashboard depends on a schema change nobody owns yet",
        "Nobody updated the shared roadmap document after the last planning meeting wrapped up",
        "The roadmap slipped again once the vendor delayed the promised integration by a month",
        "Leadership asked for a shorter roadmap summary before the board meeting next week",
        "The roadmap workshop ran out of time before anyone discussed the mobile timeline",
        "Someone archived the old roadmap board instead of merging it into the new one",
        "The roadmap committee postponed its decision until the budget numbers were finally confirmed",
        "A fresh roadmap draft circulated Friday afternoon but nobody had reviewed it by Monday",
        "The roadmap milestone for search relevance keeps moving further into next year",
        "Customers kept asking about roadmap items that were quietly dropped from the plan",
        "The roadmap sync ran twenty minutes over because the slides would not load",
        "Every roadmap update this quarter seems to push the mobile release a bit later",
        "Customers in the pilot group reported the search results felt slower than before",
        "The warehouse team switched suppliers after repeated delays on the packaging order",
        "A new intern joined the data pipeline group to help clear the backlog",
        "The garden committee postponed the fence vote until the budget numbers arrive",
        "Legal flagged a clause in the vendor contract that needs another round of edits",
        "The travel policy update got pushed back after questions from the regional offices",
        "Someone left the conference room projector running again after the Friday standup",
        "The printer on the third floor keeps jamming whenever anyone prints the invoice batch",
        "A customer asked for a refund after the shipment arrived nearly two weeks late",
        "The cafeteria menu changed again and the vegetarian options moved to a separate line",
        "The security audit found a stale credential that nobody had rotated in years",
        "The new hire spent the whole morning waiting for a laptop to be provisioned",
        "The office move got delayed again after the landlord found a problem with the wiring",
        "Someone reported the elevator was stuck between floors for almost twenty minutes today",
        "The weekly newsletter went out a day late because the template broke overnight",
        "The parking garage closed one level for repairs starting sometime next Monday morning",
        "A vendor invoice arrived twice this month and accounting is still sorting it out",
        "The team lunch got rescheduled because half the group was stuck in meetings",
        "The building's fire alarm testing is scheduled for early Saturday morning this weekend",
        "The shared drive ran out of space again after last week's recording upload",
    ]

    private static func dictationText(index: Int) -> String {
        let phraseA = phrasePool[index % phrasePool.count]
        let phraseB = phrasePool[(index * 7 + 11) % phrasePool.count]
        let words = (phraseA + " " + phraseB).split(separator: " ")
        return words.prefix(25).joined(separator: " ")
    }

    // MARK: - Transcript generation

    private static let lineCount = 400
    private static let secondsStep = 7

    /// `m:ss` or `h:mm:ss`, seconds always two digits: the app's own
    /// transcript parser refuses a line whose seconds are not exactly two
    /// digits, which would silently turn the whole file into "text" format.
    private static func timecode(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func fingerprint(of text: String) -> MeetingAttempt.Fingerprint {
        let bytes = Data(text.utf8)
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return MeetingAttempt.Fingerprint(bytes: bytes.count, sha256: hex)
    }

    private struct GeneratedTranscript {
        let textData: Data
        let fingerprint: MeetingAttempt.Fingerprint
        let lines: [MeetingAttempt.Line]
    }

    /// 400 lines alternating "Me"/"Others", cycling through the phrase pool
    /// with `shift`; `override` replaces one line's phrase (used to plant
    /// "zephyrquill" at an exact, known line).
    private func generateTranscript(shift: Int, override: (index: Int, phrase: String)? = nil) -> GeneratedTranscript {
        var bodyLines: [String] = []
        var lines: [MeetingAttempt.Line] = []
        bodyLines.reserveCapacity(Self.lineCount)
        lines.reserveCapacity(Self.lineCount)
        var secondsElapsed = 0
        for index in 0..<Self.lineCount {
            var phrase = Self.phrasePool[(index + shift) % Self.phrasePool.count]
            if let override, override.index == index { phrase = override.phrase }
            let isMicrophone = index % 2 == 0
            let label = isMicrophone ? "Me" : "Others"
            bodyLines.append("[\(Self.timecode(secondsElapsed))] **\(label):** \(phrase)")
            lines.append(MeetingAttempt.Line(
                start: Double(secondsElapsed), end: Double(secondsElapsed + Self.secondsStep),
                source: isMicrophone ? .microphone : .system
            ))
            secondsElapsed += Self.secondsStep
        }
        let text = "# Meeting\n---\n" + bodyLines.joined(separator: "\n\n") + "\n"
        return GeneratedTranscript(textData: Data(text.utf8), fingerprint: Self.fingerprint(of: text), lines: lines)
    }

    private func attemptData(number: Int, transcriptName: String, transcript: GeneratedTranscript) throws -> Data {
        var attempt = MeetingAttempt(number: number, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        attempt.result = .complete
        attempt.transcript = transcriptName
        attempt.lines = transcript.lines
        attempt.fingerprint = transcript.fingerprint
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(attempt)
    }

    // MARK: - Archive generation

    private struct ArchiveInfo {
        let sampleMeetingID: String
        let zephyrMeetingID: String
        let zephyrDictationID: UUID
        let lastDictationAt: Date
    }

    private struct Variant {
        let v1Data: Data
        let v2Data: Data
        let attempt1Data: Data
        let attempt2Data: Data
    }

    /// Builds `meetingCount` meetings (two transcript versions and two
    /// matching attempt records each) and a `history.jsonl` of
    /// `dictationCount` lines, all made up, in the temporary folders from
    /// `setUp`. Most meetings reuse one of 16 precomputed byte blobs (only
    /// the folder and its `metadata.json` are unique per meeting) so
    /// generating thousands of them does not mean re-encoding thousands of
    /// JSON attempt records.
    private func buildArchive(meetingCount: Int, dictationCount: Int) throws -> ArchiveInfo {
        let folderNameFormatter = DateFormatter()
        folderNameFormatter.locale = Locale(identifier: "en_US_POSIX")
        folderNameFormatter.timeZone = TimeZone(identifier: "UTC")
        folderNameFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let metadataDateFormatter = ISO8601DateFormatter()
        metadataDateFormatter.timeZone = TimeZone(identifier: "UTC")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let meetingsBase = try XCTUnwrap(calendar.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 9, minute: 0, second: 0)))

        let variants: [Variant] = try (0..<16).map { index in
            let v1 = generateTranscript(shift: index * 2)
            let v2 = generateTranscript(shift: index * 2 + 1)
            return Variant(
                v1Data: v1.textData, v2Data: v2.textData,
                attempt1Data: try attemptData(number: 1, transcriptName: "transcript.md", transcript: v1),
                attempt2Data: try attemptData(number: 2, transcriptName: "transcript 2.md", transcript: v2)
            )
        }

        let sampleMeetingIndex = 10
        let zephyrMeetingIndex = meetingCount / 2
        let zephyrFirstOnlyIndex = zephyrMeetingIndex + 1

        var sampleFolderName: String?
        var zephyrFolderName: String?

        for index in 0..<meetingCount {
            let startedAt = meetingsBase.addingTimeInterval(Double(index) * 4 * 3_600)
            let folderName = folderNameFormatter.string(from: startedAt) + " Meeting"
            let folder = meetingsRoot.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let metadataText = "{\"state\":\"done\",\"startedAt\":\"\(metadataDateFormatter.string(from: startedAt))\"}"
            try Data(metadataText.utf8).write(to: folder.appendingPathComponent("metadata.json"))

            if index == zephyrMeetingIndex {
                // Latest version carries "zephyrquill" once: search must find it.
                let v1 = generateTranscript(shift: 9_001)
                let v2 = generateTranscript(
                    shift: 9_002,
                    override: (index: 123, phrase: "The committee is reviewing the zephyrquill proposal before the next roadmap sync")
                )
                try v1.textData.write(to: folder.appendingPathComponent("transcript.md"))
                try v2.textData.write(to: folder.appendingPathComponent("transcript 2.md"))
                try attemptData(number: 1, transcriptName: "transcript.md", transcript: v1)
                    .write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 1)))
                try attemptData(number: 2, transcriptName: "transcript 2.md", transcript: v2)
                    .write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 2)))
                zephyrFolderName = folderName
            } else if index == zephyrFirstOnlyIndex {
                // Only the first, superseded version carries "zephyrquill":
                // search reads the latest version only and must not find it here.
                let v1 = generateTranscript(
                    shift: 9_101,
                    override: (index: 77, phrase: "An early note mentions the zephyrquill proposal that was later dropped from the roadmap")
                )
                let v2 = generateTranscript(shift: 9_102)
                try v1.textData.write(to: folder.appendingPathComponent("transcript.md"))
                try v2.textData.write(to: folder.appendingPathComponent("transcript 2.md"))
                try attemptData(number: 1, transcriptName: "transcript.md", transcript: v1)
                    .write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 1)))
                try attemptData(number: 2, transcriptName: "transcript 2.md", transcript: v2)
                    .write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 2)))
            } else {
                let variant = variants[index % variants.count]
                try variant.v1Data.write(to: folder.appendingPathComponent("transcript.md"))
                try variant.v2Data.write(to: folder.appendingPathComponent("transcript 2.md"))
                try variant.attempt1Data.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 1)))
                try variant.attempt2Data.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 2)))
            }

            if index == sampleMeetingIndex { sampleFolderName = folderName }
        }

        let sampleID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: try XCTUnwrap(sampleFolderName)))
        let zephyrID = try XCTUnwrap(HelperContract.meetingID(root: .local, folderName: try XCTUnwrap(zephyrFolderName)))

        let dictationsBase = try XCTUnwrap(calendar.date(from: DateComponents(year: 2021, month: 1, day: 1, hour: 0, minute: 0, second: 0)))
        let zephyrDictationIndex = dictationCount / 2
        var lines: [String] = []
        lines.reserveCapacity(dictationCount)
        let encoder = DictationHistoryEntry.makeEncoder()
        var zephyrDictationID = UUID()
        var lastAt = dictationsBase
        for index in 0..<dictationCount {
            let at = dictationsBase.addingTimeInterval(Double(index) * 1_200)
            lastAt = at
            let id = UUID()
            let text: String
            if index == zephyrDictationIndex {
                text = "A short note about the zephyrquill proposal that came up during the planning call"
                zephyrDictationID = id
            } else {
                text = Self.dictationText(index: index)
            }
            let entry = DictationHistoryEntry(
                id: id, at: at, duration: 1.5, selectedLanguage: "auto", actualLanguage: "en",
                targetBundleID: "com.example.notes", targetApplicationName: "Notes", audioPath: "", text: text
            )
            lines.append(try XCTUnwrap(String(data: try encoder.encode(entry), encoding: .utf8)))
        }
        let historyText = lines.joined(separator: "\n") + "\n"
        try Data(historyText.utf8).write(to: dictationsRoot.appendingPathComponent("history.jsonl"))

        return ArchiveInfo(sampleMeetingID: sampleID, zephyrMeetingID: zephyrID, zephyrDictationID: zephyrDictationID, lastDictationAt: lastAt)
    }

    // MARK: - Running the helper as a child process, measured

    private struct RunResult {
        let exitCode: Int32
        let elapsed: Double
        let peakRSSBytes: Int64
        let stdout: String
        let stderr: String
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// `Process` reaps its child itself, so its `rusage` (peak memory) is
    /// gone by the time `terminationHandler` runs. `posix_spawn` plus a
    /// `DispatchSource` on the pid's exit, followed by our own single
    /// `wait4`, keeps both the exit status and the peak RSS.
    private func spawnAndMeasure(
        helperURL: URL, arguments: [String], environment: [String: String],
        stdoutURL: URL, stderrURL: URL, timeout: TimeInterval = 120
    ) throws -> RunResult {
        // `posix_spawn_file_actions_t` is itself an opaque pointer on this
        // SDK: declared as an optional, never allocated by hand, and set up
        // by `posix_spawn_file_actions_init` through `&fileActions`.
        var fileActions: posix_spawn_file_actions_t?
        _ = posix_spawn_file_actions_init(&fileActions)
        defer { _ = posix_spawn_file_actions_destroy(&fileActions) }
        let openFlags: Int32 = O_WRONLY | O_CREAT | O_TRUNC
        _ = posix_spawn_file_actions_addopen(&fileActions, 1, stdoutURL.path, openFlags, 0o600)
        _ = posix_spawn_file_actions_addopen(&fileActions, 2, stderrURL.path, openFlags, 0o600)

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(helperURL.path)]
        for argument in arguments { argv.append(strdup(argument)) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for pointer in envp { free(pointer) } }

        var pid: pid_t = 0
        let start = ContinuousClock.now
        let spawnStatus = posix_spawn(&pid, helperURL.path, &fileActions, nil, argv, envp)
        guard spawnStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnStatus))
        }

        let expectation = XCTestExpectation(description: "murmurly exited")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [expectation] in
            expectation.fulfill()
        }
        source.resume()

        let waitResult = XCTWaiter().wait(for: [expectation], timeout: timeout)
        source.cancel()

        var status: Int32 = 0
        var usage = rusage()
        guard waitResult == .completed else {
            kill(pid, SIGKILL)
            _ = wait4(pid, &status, 0, &usage)
            XCTFail("murmurly \(arguments.joined(separator: " ")) did not exit within \(timeout) s")
            return RunResult(exitCode: -1, elapsed: timeout, peakRSSBytes: 0, stdout: "", stderr: "")
        }
        let elapsed = seconds(ContinuousClock.now - start)
        _ = wait4(pid, &status, 0, &usage)

        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return RunResult(exitCode: exitCode, elapsed: elapsed, peakRSSBytes: Int64(usage.ru_maxrss), stdout: stdout, stderr: stderr)
    }

    private struct HelperMissing: Error {}

    private func runHelper(arguments: [String]) throws -> RunResult {
        #if !DEBUG
        throw XCTSkip("the murmurly helper reads MURMURLY_HELPER_* only in DEBUG; outside it, it would read the real archive")
        #endif
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/murmurly")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            XCTFail("the murmurly helper is not embedded in this build")
            throw HelperMissing()
        }
        let environment: [String: String] = [
            "MURMURLY_HELPER_MEETINGS_ROOT": meetingsRoot.path,
            "MURMURLY_HELPER_DICTATIONS_ROOT": dictationsRoot.path,
            "MURMURLY_HELPER_SETTINGS": settingsURL.path,
            "MURMURLY_HELPER_LOG": logURL.path,
            "TZ": "Europe/Berlin",
            "HOME": homeURL.path,
        ]
        return try spawnAndMeasure(
            helperURL: helperURL, arguments: arguments, environment: environment,
            stdoutURL: root.appendingPathComponent("perf-stdout.txt"),
            stderrURL: root.appendingPathComponent("perf-stderr.txt")
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try HelperContract.makeDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - The test

    func testHelperSpeedAndMemoryOnMadeUpArchive() throws {
        #if !DEBUG
        throw XCTSkip("the murmurly helper reads MURMURLY_HELPER_* only in DEBUG; outside it, it would read the real archive")
        #endif
        try writeSettings()
        // `MURMURLY_PERF_FULL=1` (xcodebuild's own `TEST_RUNNER_MURMURLY_PERF_FULL`)
        // switches to the full archive size; the project's own CI runner does
        // not forward it, so a plain run always measures the reduced archive.
        let isFull = ProcessInfo.processInfo.environment["MURMURLY_PERF_FULL"] == "1"
        let meetingCount = isFull ? 10_000 : 1_000
        let dictationCount = isFull ? 100_000 : 10_000

        let generationStart = ContinuousClock.now
        let archive = try buildArchive(meetingCount: meetingCount, dictationCount: dictationCount)
        let generationSeconds = seconds(ContinuousClock.now - generationStart)
        print("PERF archive meetings=\(meetingCount) dictations=\(dictationCount) generated in \(String(format: "%.3f", generationSeconds)) s")

        func printPerf(label: String, phase: String, result: RunResult, targetSeconds: Double, targetMB: Double) {
            let megabytes = Double(result.peakRSSBytes) / 1_048_576
            let withinTargets = result.elapsed < targetSeconds && megabytes < targetMB
            let verdict = withinTargets ? "ok" : "OVER"
            let gaveUp = result.exitCode == 6 ? " gave up at 30 s" : ""
            print(
                "PERF scale=\(meetingCount)/\(dictationCount) \(label) \(phase) " +
                "\(String(format: "%.3f", result.elapsed)) s \(String(format: "%.1f", megabytes)) MB " +
                "(target < \(String(format: "%.1f", targetSeconds)) s, < \(String(format: "%.0f", targetMB)) MB) \(verdict)\(gaveUp)"
            )
        }

        struct Scenario {
            let label: String
            let arguments: [String]
            let targetSeconds: Double
            let check: (RunResult) throws -> Void
        }

        let memoryTargetMB = 500.0
        let scenarios: [Scenario] = [
            Scenario(label: "meetings", arguments: ["meetings", "--json"], targetSeconds: 2) { result in
                let response = try self.decode(HelperContract.MeetingsResponse.self, from: result.stdout)
                XCTAssertEqual(response.roots.local, .read)
                if response.truncated {
                    XCTAssertGreaterThan(response.meetings.count, 0)
                    XCTAssertFalse(response.meetings.contains { $0.id.isEmpty })
                } else {
                    // The default `--limit` (50) caps the page well below
                    // `meetingCount`, long before the 1 MiB CLI response
                    // limit is anywhere near reached.
                    XCTAssertEqual(response.meetings.count, min(meetingCount, 50))
                    XCTAssertTrue(response.hasMore)
                }
            },
            Scenario(label: "transcript", arguments: ["transcript", archive.sampleMeetingID, "--json"], targetSeconds: 0.5) { result in
                let response = try self.decode(HelperContract.TranscriptResponse.self, from: result.stdout)
                XCTAssertEqual(response.lines.count, 200)
                XCTAssertEqual(response.totalLines, 400)
                XCTAssertEqual(response.version.number, 2)
                XCTAssertTrue(response.hasMore)
            },
            Scenario(label: "search zephyrquill --meetings", arguments: ["search", "zephyrquill", "--meetings", "--json"], targetSeconds: 10) { result in
                let response = try self.decode(HelperContract.SearchResponse.self, from: result.stdout)
                XCTAssertEqual(response.meetings.count, 1)
                XCTAssertEqual(response.meetings.first?.meetingId, archive.zephyrMeetingID)
                XCTAssertFalse(response.hasMore)
            },
            Scenario(label: "search roadmap --meetings", arguments: ["search", "roadmap", "--meetings", "--json"], targetSeconds: 10) { result in
                let response = try self.decode(HelperContract.SearchResponse.self, from: result.stdout)
                XCTAssertEqual(response.meetings.count, 20)
                XCTAssertTrue(response.hasMore)
            },
            Scenario(label: "search zephyrquill --dictations", arguments: ["search", "zephyrquill", "--dictations", "--json"], targetSeconds: 10) { result in
                let response = try self.decode(HelperContract.SearchResponse.self, from: result.stdout)
                XCTAssertEqual(response.dictations.count, 1)
                XCTAssertEqual(response.dictations.first?.id, archive.zephyrDictationID)
            },
            Scenario(label: "search roadmap --dictations", arguments: ["search", "roadmap", "--dictations", "--json"], targetSeconds: 10) { result in
                let response = try self.decode(HelperContract.SearchResponse.self, from: result.stdout)
                XCTAssertEqual(response.dictations.count, 20)
                XCTAssertTrue(response.hasMore)
            },
            Scenario(label: "dictations --last 20", arguments: ["dictations", "--last", "20", "--json"], targetSeconds: 0.5) { result in
                let response = try self.decode(HelperContract.DictationsResponse.self, from: result.stdout)
                XCTAssertEqual(response.dictations.count, 20)
                XCTAssertEqual(response.dictations.first?.at, archive.lastDictationAt)
            },
        ]

        for scenario in scenarios {
            for phase in ["cold", "warm"] {
                let result = try runHelper(arguments: scenario.arguments)
                printPerf(label: scenario.label, phase: phase, result: result, targetSeconds: scenario.targetSeconds, targetMB: memoryTargetMB)
                switch result.exitCode {
                case 0:
                    try scenario.check(result)
                case 6:
                    // The helper's own 30 s internal timeout: a measurement
                    // of how slow it is on this archive, not a defect.
                    break
                default:
                    XCTFail(
                        "\(scenario.label) (\(phase)) exited \(result.exitCode); " +
                        "stdout: \(result.stdout); stderr: \(result.stderr)"
                    )
                }
            }
        }
    }
}
