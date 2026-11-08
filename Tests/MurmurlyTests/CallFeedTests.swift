import CryptoKit
import XCTest
@testable import Murmurly

/// `CallFeed`: the call-watcher's feed format (`Sources/Archive/CallFeed.swift`)
/// and the pure picking function it offers, tested at the seam that matters —
/// an attempt's recorded lines plus a parsed feed going in, a named transcript
/// coming out (`MeetingTranscript.named(_:feed:renames:)`). No real meeting,
/// name or audio anywhere; every person here is invented.
final class CallFeedTests: XCTestCase {
    // MARK: - Building a transcript with exact spans, as a real attempt would

    private func rawTranscript(_ rows: [(time: String, label: String, text: String)]) -> String {
        (["---"] + rows.map { "[\($0.time)] **\($0.label):** \($0.text)" }).joined(separator: "\n")
    }

    private func timedTranscript(_ rows: [(time: String, label: String, text: String)], lines: [MeetingAttempt.Line]) -> MeetingTranscript {
        let raw = rawTranscript(rows)
        let parsed = MeetingTranscript.parse(raw)
        var attempt = MeetingAttempt(number: 1, startedAt: Date())
        attempt.transcript = "transcript.md"
        attempt.lines = lines
        let bytes = Data(raw.utf8)
        attempt.fingerprint = MeetingAttempt.Fingerprint(
            bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        return parsed.timed(by: attempt)
    }

    private func event(
        t: TimeInterval, service: String = "telemost", visible: Bool = true, ownName: String? = nil,
        people: [String] = [], speaking: [String] = [], offscreen: Bool = false
    ) -> CallFeed.Event {
        CallFeed.Event(
            t: t, service: service, visible: visible, ownName: ownName, selfSpeaking: false, people: people,
            speaking: speaking, offscreen: offscreen
        )
    }

    // MARK: - Picking

    /// One other person the whole line, in `people` the whole time: no
    /// highlight is needed at all.
    func testSingleOtherPresentWholeLineNeedsNoHighlight() {
        let transcript = timedTranscript(
            [("0:00", "Others", "привет")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [event(t: 0, people: ["Гость"])]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Гость")
    }

    /// Two people, each dominant on their own line: turns, not an
    /// interruption inside one line.
    func testTwoPeopleTakeTurnsAcrossLines() {
        let transcript = timedTranscript(
            [("0:00", "Others", "да"), ("0:05", "Others", "продолжим")],
            lines: [
                MeetingAttempt.Line(start: 0, end: 5, source: .system),
                MeetingAttempt.Line(start: 5, end: 10, source: .system),
            ]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 5, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А")
        XCTAssertEqual(named.lines?[1].speaker, "Участник Б")
    }

    /// Both talk inside one line, 7 s against 3 s: the dominant one still
    /// clears 60 % of the line and is at least twice the other.
    func testInterruptionPicksTheDominantSpeaker() {
        let transcript = timedTranscript(
            [("0:00", "Others", "итак")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 7, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А")
    }

    /// The highlight fades late: a 0.5 s sliver for the other person right
    /// before the line ends must not overturn a 7.5 s majority.
    func testBriefTrailingHighlightDoesNotOverturnTheWinner() {
        let transcript = timedTranscript(
            [("0:00", "Others", "согласна")],
            lines: [MeetingAttempt.Line(start: 0, end: 8, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 7.5, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А")
    }

    /// 6 s against 4 s clears the 60 % share but not the ×2 margin: no
    /// winner, the line keeps the track's own written label.
    func testMixedLineKeepsTheTrackLabel() {
        let transcript = timedTranscript(
            [("0:00", "Собеседники", "минутку")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 4, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
            event(t: 8, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Собеседники")
    }

    /// `visible: false` on the system line gives it no name; the microphone
    /// line in the same window still takes the user's own tile name, which
    /// does not depend on whether a tab was found at all.
    func testHiddenTabKeepsOwnNameButDropsOthers() {
        let transcript = timedTranscript(
            [("0:00", "Me", "да"), ("0:00", "Others", "да")],
            lines: [
                MeetingAttempt.Line(start: 0, end: 5, source: .microphone),
                MeetingAttempt.Line(start: 0, end: 5, source: .system),
            ]
        )
        let feed = [event(t: 0, visible: false, ownName: "Ведущая")]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Ведущая")
        XCTAssertEqual(named.lines?[1].speaker, "Others")
    }

    /// The same name twice in one event's `people` is one person, not two:
    /// it dedups at the feed's own level, and still needs no highlight.
    func testDuplicateGuestNamesCountAsOnePerson() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость","Гость"],"speaking":["Гость"]}
        """
        let feed = CallFeed.parse(raw)
        XCTAssertEqual(feed.first?.people, ["Гость"])
        let picked = CallFeed.pickedNames(for: [MeetingAttempt.Line(start: 0, end: 10, source: .system)], feed: feed)
        XCTAssertEqual(picked, ["Гость"])
    }

    /// A garbage line, a foreign version, a negative `t`, a `t` that goes
    /// backwards, and a truncated last line (a killed process) are all
    /// skipped; the readable lines around them still count, in order.
    func testGarbageAndTruncatedLinesAreSkipped() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        not json at all {{{
        {"v":2,"t":1,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":-5,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":-1,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":10,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":20,"service":"telemo
        """
        let feed = CallFeed.parse(raw)
        XCTAssertEqual(feed.map(\.t), [0, 0, 10])
    }

    // MARK: - K1: the onset rule for overlapping highlights

    /// A second person's highlight joining while the first is still lit (a
    /// real interruption, not a clean handoff) hands the credit to the
    /// newcomer for the overlap itself, and back to the first once the
    /// newcomer goes quiet while the first is still lit.
    func testInterruptionHandsCreditToTheLatecomerDuringTheOverlap() {
        let transcript = timedTranscript(
            [("0:00", "Others", "итак"), ("0:06", "Others", "минутку")],
            lines: [
                MeetingAttempt.Line(start: 0, end: 10, source: .system),
                MeetingAttempt.Line(start: 6, end: 8, source: .system),
            ]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 6, people: ["Участник А", "Участник Б"], speaking: ["Участник А", "Участник Б"]),
            event(t: 9, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А") // 7 s against 3 s over [0, 10)
        XCTAssertEqual(named.lines?[1].speaker, "Участник Б") // the overlap itself, [6, 8)
    }

    /// A highlight that fades 5 s after the speech it marked must not
    /// freeze the earlier winner once a second highlight clearly took over
    /// before the line even starts.
    func testLateFadingHighlightDoesNotFreezeTheEarlierWinner() {
        let transcript = timedTranscript(
            [("0:10", "Others", "продолжаем")],
            lines: [MeetingAttempt.Line(start: 10, end: 18, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 10.5, people: ["Участник А", "Участник Б"], speaking: ["Участник А", "Участник Б"]),
            event(t: 15, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник Б") // 7.5 s against 0.5 s
    }

    /// A highlight that fades to nothing, without another's taking its
    /// place, must not keep crediting the dark stretch to whoever faded:
    /// the empty highlight's seconds go to nobody, and 5.5 s of 10 fails
    /// the 60 % share.
    func testHighlightShareBelowThresholdKeepsNoWinner() {
        let transcript = timedTranscript(
            [("0:00", "Собеседники", "ну")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 5.5, people: ["Участник А", "Участник Б"], speaking: []),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Собеседники")
    }

    /// Exactly 60 % of the line and exactly double the runner-up still
    /// wins: the comparison's tolerance must not turn a threshold met
    /// exactly into a loss from float rounding.
    func testHighlightExactlyAtBothThresholdsStillWins() {
        let transcript = timedTranscript(
            [("0:00", "Собеседники", "решили")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 6, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
            event(t: 9, people: ["Участник А", "Участник Б"], speaking: []),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А") // 6 s against 3 s
    }

    // MARK: - K6: a tied onset must not pick either name by chance

    /// Two names highlighted by the very same event tie on onset: crediting
    /// only one of them (as the pre-fix `onset.max { ... }` did, by whatever
    /// order a `Dictionary` happens to iterate in) would let that one clear
    /// both thresholds off a coin flip that could change between runs. A
    /// tie must credit both in full instead, so neither clears the ×2
    /// margin and the line keeps its mixed label.
    func testTiedOnsetWithinOneEventKeepsTheTrackLabel() {
        let transcript = timedTranscript(
            [("0:00", "Собеседники", "привет")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А", "Участник Б"])]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Собеседники")
    }

    /// The same tie, reached after a silent opening (nobody highlighted
    /// before both light up together at `t = 2`): the tie still credits
    /// both for the whole stretch they share, not one of them for all of it.
    func testTiedOnsetAfterASilentOpeningKeepsTheTrackLabel() {
        let transcript = timedTranscript(
            [("0:00", "Собеседники", "привет")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 2, people: ["Участник А", "Участник Б"], speaking: ["Участник А", "Участник Б"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Собеседники")
    }

    // MARK: - Round 3 item 2: a hidden tab or a silent opening is nobody's time, but the line's full length still sets the bar

    /// The tab closes 8 s into a 10 s line; the 8 s А was highlighted
    /// before that still clears 60 % of the line's own full length.
    func testHiddenTabPartwayThroughStillCreditsTheEarlierMajority() {
        let transcript = timedTranscript(
            [("0:00", "Others", "итак")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 8, visible: false),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А")
    }

    /// The feed's first event lands 2 s into the line: the 2 s before it is
    /// nobody's, yet the 8 s А is highlighted afterward still clears 60 %
    /// of the line's full 10 s.
    func testFeedStartingMidLineStillCreditsTheRest() {
        let transcript = timedTranscript(
            [("0:00", "Others", "продолжаем")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [event(t: 2, people: ["Участник А", "Участник Б"], speaking: ["Участник А"])]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А")
    }

    /// The tab closes at 5 s, after only a 5 s highlight: 5 s of the full
    /// 10 s line misses the 60 % bar, so the line keeps its track label.
    func testHiddenTabAfterAMinorityHighlightKeepsTheTrackLabel() {
        let transcript = timedTranscript(
            [("0:00", "Собеседники", "ну")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 5, visible: false),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Собеседники")
    }

    // MARK: - Strict per-line UTF-8 decoding

    /// A line damaged with an invalid UTF-8 byte (as a crash mid-write might
    /// leave) must be dropped whole, not kept with a `\u{FFFD}` standing in
    /// for the bad byte: the lossy, whole-file `String(decoding:as:)` the
    /// old reader used would have decoded it anyway, replacement character
    /// and all, since a JSON string tolerates any Unicode scalar inside it.
    func testCorruptUTF8LineIsDroppedWithoutTouchingItsNeighbor() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var corrupt = Data("{\"v\":1,\"t\":0,\"service\":\"telemost\",\"visible\":true,\"self\":\"A".utf8)
        corrupt.append(0xFF)
        corrupt.append(contentsOf: Data(
            "\",\"selfSpeaking\":false,\"people\":[],\"speaking\":[]}\n".utf8
        ))
        let valid = Data(event(t: 1, people: ["Гость"]).encodedLine().utf8)
        try (corrupt + valid).write(to: folder.appendingPathComponent(CallFeed.fileName))
        let feed = try CallFeed.read(in: folder)
        XCTAssertEqual(feed?.count, 1)
        XCTAssertEqual(feed?.first?.t, 1)
        XCTAssertEqual(feed?.first?.people, ["Гость"])
    }

    // MARK: - Performance: one pass over the feed, not one per line

    /// 50,000 events and 2,000 lines: the earlier version rebuilt a sorted
    /// boundary set and the whole onset calculation again for every line,
    /// making picking quadratic in the feed's size. This stays well inside
    /// a generous 2 s budget.
    func testPickingManyLinesAgainstALargeFeedStaysFast() {
        let eventCount = 50_000
        let lineCount = 2_000
        var feed: [CallFeed.Event] = []
        feed.reserveCapacity(eventCount)
        for i in 0..<eventCount {
            let speaker = i % 2 == 0 ? "Участник А" : "Участник Б"
            feed.append(event(t: TimeInterval(i) * 0.1, people: ["Участник А", "Участник Б"], speaking: [speaker]))
        }
        let totalDuration = TimeInterval(eventCount) * 0.1
        let lineLength = totalDuration / TimeInterval(lineCount)
        var lines: [MeetingAttempt.Line] = []
        lines.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            let start = TimeInterval(i) * lineLength
            lines.append(MeetingAttempt.Line(
                start: start, end: start + lineLength, source: i % 2 == 0 ? .microphone : .system
            ))
        }
        let started = Date()
        let picked = CallFeed.pickedNames(for: lines, feed: feed)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(picked.count, lineCount)
        XCTAssertLessThan(elapsed, 2.0)
    }

    // MARK: - Cheap coverage: a few more edges of the same rules

    /// A positive `t` that goes backwards is skipped too, not only a
    /// negative one.
    func testPositiveDecreasingTimestampIsSkipped() {
        let raw = """
        {"v":1,"t":5,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":3,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        {"v":1,"t":7,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":[],"speaking":[]}
        """
        let feed = CallFeed.parse(raw)
        XCTAssertEqual(feed.map(\.t), [5, 7])
    }

    /// `people` grows mid-line (a guest joins) while the first person keeps
    /// the highlight throughout: still picked by the dominant-speaker count,
    /// since the single-other case needs one person for the *whole* line.
    func testPeopleChangingMidLineStillPicksTheDominantSpeaker() {
        let transcript = timedTranscript(
            [("0:00", "Others", "привет")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [
            event(t: 0, people: ["Участник А"], speaking: ["Участник А"]),
            event(t: 5, people: ["Участник А", "Гость"], speaking: ["Участник А"]),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник А")
    }

    /// A name can be highlighted before the watcher ever lists it in
    /// `people` at all; it is still credited.
    func testSpeakingNameAheadOfPeopleStillGetsCredited() {
        let transcript = timedTranscript(
            [("0:00", "Others", "привет")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let feed = [event(t: 0, people: [], speaking: ["Гость"])]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Гость")
    }

    /// Approximate timing (a transcript parsed without an attempt's exact
    /// spans) never consults the feed: the result equals plain `named(_:)`.
    func testFeedIsIgnoredWithApproximateTiming() {
        let raw = rawTranscript([("0:00", "Others", "привет")])
        let parsed = MeetingTranscript.parse(raw)
        let feed = [event(t: 0, people: ["Гость"])]
        let named = parsed.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named, parsed.named([:]))
        XCTAssertEqual(named.lines?[0].speaker, "Others")
    }

    // MARK: - K2: reading the feed file itself

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// No file at all is "no feed", not an error — under both link
    /// policies, and distinct from a file that exists but cannot be read.
    func testMissingFeedFileReadsAsNoFeed() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(try CallFeed.read(in: folder, links: .follow))
        XCTAssertNil(try CallFeed.read(in: folder, links: .refuse))
    }

    /// An existing, empty feed file parses to an empty array, not nil:
    /// being there at all (even blank) is not the same as being absent.
    func testEmptyFeedFileReadsAsEmptyFeed() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(try CallFeed.read(in: folder, links: .follow), [])
        XCTAssertEqual(try CallFeed.read(in: folder, links: .refuse), [])
    }

    /// A link at the feed's own path is not silently followed under
    /// `.refuse`: that is a read error, never mistaken for "no feed".
    func testLinkedFeedFileUnderRefuseIsAnError() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("elsewhere.jsonl")
        try Data("{}".utf8).write(to: target)
        let link = folder.appendingPathComponent(CallFeed.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CallFeed.read(in: folder, links: .refuse))
        XCTAssertNoThrow(try CallFeed.read(in: folder, links: .follow))
    }

    // MARK: - K3: the own tile's last known name

    /// A later event that clears the own tile's name (`self: null`, often
    /// paired with a hidden tab) must not erase the last known name; and
    /// an event landing exactly on the line's own end belongs to the next
    /// line, the same half-open rule the system track already follows.
    func testOwnNameSurvivesALaterNullAndRespectsTheLineEnd() {
        let transcript = timedTranscript(
            [("0:00", "Me", "привет")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .microphone)]
        )
        let feed = [
            event(t: 0, ownName: "Ведущая"),
            event(t: 4, visible: false, ownName: nil),
            event(t: 10, ownName: "Другая"),
        ]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Ведущая")
    }

    // MARK: - K4: equal timestamps keep the file's own order

    /// Two events sharing one `t` are not reordered by value alone: the
    /// later one in the file is the current state and must win, even in a
    /// feed long enough to defeat whatever a plain, non-stable `sorted`
    /// happens to do with equal elements.
    func testEqualTimestampsKeepTheFilesOwnOrder() {
        var feed: [CallFeed.Event] = (0..<30).map { i in
            event(t: TimeInterval(i) * 0.01, people: ["Участник А", "Участник Б"], speaking: [])
        }
        feed.append(event(t: 1, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]))
        feed.append(event(t: 1, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]))

        let transcript = timedTranscript(
            [("0:00", "Собеседники", "ладно")],
            lines: [MeetingAttempt.Line(start: 0, end: 10, source: .system)]
        )
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Участник Б")
    }

    // MARK: - K5: cleaning a rename before it becomes a label

    /// The rename dictionary's value is cleaned the same way a feed name
    /// is: a stray `*` must not reach the Markdown label unescaped.
    func testRenameValueIsCleanedBeforeItBecomesTheLabel() {
        let transcript = timedTranscript(
            [("0:00", "Others", "так")],
            lines: [MeetingAttempt.Line(start: 0, end: 5, source: .system)]
        )
        let feed = [event(t: 0, people: ["Коллега"])]
        let named = transcript.named([:], feed: feed, renames: ["Коллега": "Ведущая*2"])
        XCTAssertEqual(named.lines?[0].speaker, "Ведущая2")
    }

    /// A rename that cleans to nothing (only spaces, or only `*`) keeps
    /// the feed's own found name — never an empty label.
    func testRenameThatCleansToNothingKeepsTheFoundName() {
        let transcript = timedTranscript(
            [("0:00", "Others", "так")],
            lines: [MeetingAttempt.Line(start: 0, end: 5, source: .system)]
        )
        let feed = [event(t: 0, people: ["Коллега"])]
        let blank = transcript.named([:], feed: feed, renames: ["Коллега": "   "])
        XCTAssertEqual(blank.lines?[0].speaker, "Коллега")
        let stars = transcript.named([:], feed: feed, renames: ["Коллега": "***"])
        XCTAssertEqual(stars.lines?[0].speaker, "Коллега")
    }

    // MARK: - Cheap fixes alongside the above

    /// The encoder writes `"self": null` explicitly rather than omitting
    /// the key: the synthesized `Encodable` conformance would drop it.
    func testEncoderWritesExplicitNullForTheOwnTile() {
        let line = event(t: 1, ownName: nil)
        XCTAssertTrue(line.encodedLine().contains("\"self\":null"))
    }

    /// A non-finite span (an infinite `end`, say) never gets a name, even
    /// though it is numerically greater than `start`.
    func testNonFiniteSpanAlwaysGetsNoName() {
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: .infinity, source: .system)],
            feed: [event(t: 0, people: ["Гость"])]
        )
        XCTAssertEqual(picked, [nil])
    }

    // MARK: - Applying picks to a transcript

    /// With no feed, or with one that names nothing anywhere, the result is
    /// `named(_:)`'s own, byte for byte — whether or not the Names sheet
    /// itself has anything to say.
    func testWithoutAnyPickedNameEqualsPlainNamed() {
        let rows: [(time: String, label: String, text: String)] = [("0:00", "Me", "привет"), ("0:05", "Others", "да")]
        let lines = [
            MeetingAttempt.Line(start: 0, end: 5, source: .microphone),
            MeetingAttempt.Line(start: 5, end: 10, source: .system),
        ]
        let withNames: [MeetingAttempt.Source: String] = [.microphone: "Ведущая"]

        let noFeed = timedTranscript(rows, lines: lines)
        XCTAssertEqual(noFeed.named(withNames, feed: [], renames: [:]), noFeed.named(withNames))
        XCTAssertEqual(noFeed.named([:], feed: [], renames: [:]), noFeed.named([:]))

        let unhelpfulFeed = timedTranscript(rows, lines: lines)
        let feed = [event(t: 0, visible: false)]
        XCTAssertEqual(unhelpfulFeed.named(withNames, feed: feed, renames: [:]), unhelpfulFeed.named(withNames))
    }

    /// The Names sheet outranks the feed for the microphone: the owner
    /// typed a name, and that is the one that shows, not the tile's own.
    func testNamesSheetOutranksFeedForMicrophone() {
        let transcript = timedTranscript(
            [("0:00", "Me", "продолжим")],
            lines: [MeetingAttempt.Line(start: 0, end: 5, source: .microphone)]
        )
        let feed = [event(t: 0, ownName: "Ведущая")]
        let named = transcript.named([.microphone: "Ведущая из листа"], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Ведущая из листа")
    }

    /// A system pick is looked up in `renames` (found name → shown name)
    /// before it reaches the line.
    func testRenamesApplyToTheSystemPick() {
        let transcript = timedTranscript(
            [("0:00", "Others", "итак")],
            lines: [MeetingAttempt.Line(start: 0, end: 5, source: .system)]
        )
        let feed = [event(t: 0, people: ["Коллега"])]
        let named = transcript.named([:], feed: feed, renames: ["Коллега": "Ведущая"])
        XCTAssertEqual(named.lines?[0].speaker, "Ведущая")
    }

    /// A line with `end <= start` has no span to look at: no name, on
    /// either track, whatever the feed says at that very moment — even
    /// while another line in the same transcript does get one.
    func testZeroLengthLineHasNoName() {
        let transcript = timedTranscript(
            [("0:00", "Me", "минутку"), ("0:00", "Others", "минутку"), ("0:00", "Others", "да")],
            lines: [
                MeetingAttempt.Line(start: 0, end: 0, source: .microphone),
                MeetingAttempt.Line(start: 0, end: 0, source: .system),
                MeetingAttempt.Line(start: 0, end: 10, source: .system),
            ]
        )
        let feed = [event(t: 0, ownName: "Ведущая", people: ["Гость"])]
        let named = transcript.named([:], feed: feed, renames: [:])
        XCTAssertEqual(named.lines?[0].speaker, "Me")
        XCTAssertEqual(named.lines?[1].speaker, "Others")
        XCTAssertEqual(named.lines?[2].speaker, "Гость")
    }

    // MARK: - CallFeed.Summary

    /// Every name the feed's `people` or `speaking` ever held, without
    /// repeats, in the order each first appeared; a name only `speaking`
    /// ever lists still counts, and the own tile's name is never in it.
    func testSummaryListsPeopleOnceInFirstOrderWithoutOwnName() {
        let feed = [
            event(t: 0, ownName: "Ведущая", people: ["Гость Один"]),
            event(t: 1, ownName: "Ведущая", people: ["Гость Один", "Гость Два"], speaking: ["Гость Два"]),
            event(t: 2, ownName: "Ведущая", people: [], speaking: ["Гость Три"]),
        ]
        let summary = CallFeed.summary(for: [], feed: feed)
        XCTAssertEqual(summary.people, ["Гость Один", "Гость Два", "Гость Три"])
        XCTAssertTrue(summary.tilesFound)
    }

    /// A feed that never showed a tile says so; its own pick and its list
    /// of people are not forced empty for it — the microphone's own-tile
    /// name does not depend on `visible` at all (K1,
    /// `testHiddenTabKeepsOwnNameButDropsOthers` above).
    func testSummaryOfAFeedWithoutVisibleTilesSaysNotFound() {
        let feed = [event(t: 0, visible: false, ownName: "Ведущая", people: ["Гость Один"])]
        let summary = CallFeed.summary(for: [], feed: feed)
        XCTAssertFalse(summary.tilesFound)
        XCTAssertEqual(summary.people, ["Гость Один"])
    }

    // MARK: - named(by:call:) — the one function the card and the helper share

    /// Without a call summary, or with one that names no line at all,
    /// `named(by:call:)` is `named(marks.speakers)`'s result byte for byte:
    /// a meeting without a feed reads exactly as it did before this feature.
    func testNamedByMarksWithoutCallIsPlainNamed() {
        let transcript = timedTranscript(
            [("0:00", "Me", "привет"), ("0:05", "Others", "да")],
            lines: [
                MeetingAttempt.Line(start: 0, end: 5, source: .microphone),
                MeetingAttempt.Line(start: 5, end: 10, source: .system),
            ]
        )
        let marks = MeetingMarks(speakers: [.microphone: "Ведущая"])
        XCTAssertEqual(transcript.named(by: marks, call: nil), transcript.named(marks.speakers))

        let unhelpful = CallFeed.Summary(picked: [nil, nil], people: [], tilesFound: false)
        let namedWithUnhelpfulCall = transcript.named(by: marks, call: unhelpful)
        XCTAssertEqual(namedWithUnhelpfulCall, transcript.named(marks.speakers))
        XCTAssertEqual(namedWithUnhelpfulCall.namesNote, transcript.named(marks.speakers).namesNote)
    }

    /// `namesNote` lists the call's people once a rename has taken place,
    /// in the order they first stood on a line, after `callNames`; one the
    /// feed never named at all is left out.
    func testNamesNoteListsTheCallPeopleAfterRenames() {
        let lines = [
            MeetingAttempt.Line(start: 0, end: 5, source: .system),
            MeetingAttempt.Line(start: 5, end: 10, source: .system),
        ]
        let transcript = timedTranscript([("0:00", "Others", "привет"), ("0:05", "Others", "и я")], lines: lines)
        let feed = [
            event(t: 0, people: ["Гость Один"], speaking: ["Гость Один"]),
            event(t: 5, people: ["Гость Два"], speaking: ["Гость Два"]),
        ]
        let summary = CallFeed.summary(for: lines, feed: feed)
        let marks = MeetingMarks(callNames: ["Гость Один": "Аня"])

        let named = transcript.named(by: marks, call: summary)
        XCTAssertEqual(named.lines?[0].speaker, "Аня")
        XCTAssertEqual(named.lines?[1].speaker, "Гость Два")
        let people = ["Аня", "Гость Два"].formatted(.list(type: .and))
        XCTAssertEqual(named.namesNote, "Names: “Me” is the microphone, “Others” is the system audio. From the call: \(people).")
    }

    // MARK: - The encoder the watcher writes with

    /// What the watcher's encoder writes, this picker's own decoder reads
    /// back whole.
    func testEncodedLineRoundTrips() {
        let original = event(t: 12.5, visible: true, ownName: "Ведущая", people: ["Гость", "Коллега"], speaking: ["Гость"])
        let decoded = CallFeed.parse(original.encodedLine())
        XCTAssertEqual(decoded, [original])
    }

    /// `selfVisible: true` round-trips through the encoder, and so does
    /// `false` — the key itself must be written, not merely omitted, since
    /// `encodeIfPresent` would otherwise make a known-absent own tile read
    /// back as the old, field-less shape. Only `nil` (never set) omits the
    /// key.
    func testSelfVisible_roundTrip() {
        let present = CallFeed.Event(
            t: 1, service: "telemost", visible: true, ownName: nil, selfSpeaking: false,
            people: ["Гость"], speaking: [], selfVisible: true
        )
        XCTAssertTrue(present.encodedLine().contains("\"selfVisible\":true"))
        XCTAssertEqual(CallFeed.parse(present.encodedLine()), [present])

        let absent = CallFeed.Event(
            t: 1, service: "telemost", visible: true, ownName: nil, selfSpeaking: false,
            people: ["Гость"], speaking: [], selfVisible: false
        )
        XCTAssertTrue(absent.encodedLine().contains("\"selfVisible\":false"))
        XCTAssertEqual(CallFeed.parse(absent.encodedLine()), [absent])

        let unset = event(t: 1, people: ["Гость"])
        XCTAssertFalse(unset.encodedLine().contains("selfVisible"))
    }

    // MARK: - K7: the single-other rule needs a confirmed pair (3b)

    /// Three people on the call, but only one other tile is actually
    /// visible on screen (a scrolled gallery) and the user's own tile is
    /// known absent (`selfVisible: false`, fed as raw JSON so a line this
    /// shape round-trips the way a real reader would write it, not merely
    /// as a `CallFeed.Event` built directly in code): naming the one
    /// visible tile would be a guess about who the other two are, so the
    /// line keeps the track's own label.
    func testNewFeed_oneOtherTileWithoutOwnTile_lineKeepsTrackLabel() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"selfVisible":false,"people":["Гость Два"],"speaking":[]}
        """
        let feed = CallFeed.parse(raw)
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 10, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, [nil])
    }

    /// The user's own tile is visible (`ownName` set) and exactly one other
    /// tile is on screen: a real pair, so the other person is named.
    func testNewFeed_ownTileAndOneOther_namesTheOther() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":"Анна Тестова","selfSpeaking":false,"selfVisible":true,"people":["Гость Два"],"speaking":[]}
        """
        let feed = CallFeed.parse(raw)
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 10, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, ["Гость Два"])
    }

    /// A line written before `selfVisible` existed (no key at all, and no
    /// own name either) keeps the old, looser rule: one other tile is
    /// enough, exactly as before this card.
    func testOldFeed_withoutSelfVisible_keepsTheOldRule() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость Два"],"speaking":[]}
        """
        let feed = CallFeed.parse(raw)
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 10, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, ["Гость Два"])
    }

    // MARK: - The single-other rule needs no third name anywhere in the feed

    /// A third person ("Гость Три") stood on screen before the line even
    /// starts; only afterward does the call narrow to the user and one
    /// other ("Борис Пример"). The line itself, with no highlight, must not
    /// name the one tile it can see: a third person was seen elsewhere in
    /// the very same call, so this single visible tile is not proven to be
    /// the whole pair. On the code before this card, the line's own span
    /// alone decided this and named "Борис Пример" instead — this test is
    /// red there.
    func testNewFeed_thirdNameSeenBeforeLine_lineKeepsTrackLabel() {
        let feed = [
            event(t: 0, ownName: "Анна Тестова", people: ["Гость Три"]),
            event(t: 5, ownName: "Анна Тестова", people: ["Борис Пример"]),
        ]
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 5, end: 15, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, [nil])
    }

    /// The same shape, mirrored: the line itself sees only one other tile
    /// ("Борис Пример"), but a third person ("Гость Три") shows up right
    /// after it ends. A name once given cannot depend on what the call
    /// looked like a moment later, so this must be ruled out exactly as the
    /// third-seen-before case is: the whole feed decides, never only the
    /// line's own span. Red on the code before this card, same reason.
    func testNewFeed_thirdNameSeenAfterLine_lineKeepsTrackLabel() {
        let feed = [
            event(t: 0, ownName: "Анна Тестова", people: ["Борис Пример"]),
            event(t: 10, ownName: "Анна Тестова", people: ["Гость Три"]),
        ]
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 10, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, [nil])
    }

    /// An old-format feed (no `selfVisible` at all) that only ever shows one
    /// other person, across two separate events in time, still names the
    /// line: this is the old rule's own case, now also checked across the
    /// whole feed rather than only the line's span, and it still passes
    /// because there really is only ever one other name.
    func testOldFeed_twoNamesSeenTheWholeMeeting_lineGetsName() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость Два"],"speaking":[]}
        {"v":1,"t":5,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость Два"],"speaking":[]}
        """
        let feed = CallFeed.parse(raw)
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 10, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, ["Гость Два"])
    }

    /// The same old-format feed, but a third person ("Гость Три") was seen
    /// earlier in the call: even without `selfVisible` at all, the line
    /// keeps its track label rather than name the one tile this line alone
    /// can see. The card does not require this exact case to work on old
    /// feeds, but it is correct behavior and belongs in the acceptance list.
    func testOldFeed_thirdNameSeen_lineKeepsTrackLabel() {
        let raw = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость Три"],"speaking":[]}
        {"v":1,"t":5,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость Два"],"speaking":[]}
        """
        let feed = CallFeed.parse(raw)
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 5, end: 10, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, [nil])
    }

    /// A name that only ever appeared while the tab was hidden
    /// (`visible: false`) must not count as a third person: the user never
    /// actually saw that tile, so it cannot rule out an otherwise valid
    /// single-other line once the tab becomes visible again.
    func testNameSeenOnlyWhileHiddenDoesNotBlockTheSingleOtherRule() {
        let feed = [
            event(t: 0, visible: false, people: ["Гость Три"], speaking: ["Гость Три"]),
            event(t: 5, ownName: "Анна Тестова", people: ["Борис Пример"]),
        ]
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 5, end: 15, source: .system)], feed: feed
        )
        XCTAssertEqual(picked, ["Борис Пример"])
    }

    // MARK: - Per-service highlight lead

    /// The same feed, read two ways: with no lead at all (`leads: [:]`) a
    /// line that started 0.8 s before the highlight lit up gets no name —
    /// only 0.5 s of its 1.3 s falls inside the highlight, short of the 60 %
    /// share. With the service's lead at 1 s, the credit for the newly-lit
    /// name reaches back to `max(1 − 1, 0) = 0`, covering the whole line,
    /// and it is named. `people` lists two names throughout so the
    /// single-other shortcut never fires on its own (P2).
    func testHighlightLeadCreditsALineStartedJustBeforeTheHighlight() {
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 1, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 0.2, end: 1.5, source: .system)

        let withoutLead = CallFeed.pickedNames(for: [line], feed: feed, leads: [:])
        XCTAssertNil(withoutLead[0])

        let withLead = CallFeed.pickedNames(for: [line], feed: feed, leads: ["telemost": 1])
        XCTAssertEqual(withLead[0], "Участник А")
    }

    /// A lead of 5 s cannot reach past the previous event, which is only
    /// 1 s before the highlight: the credit starts at the previous event's
    /// own time, not 5 s earlier. The 4 s between them stays uncredited, so
    /// the line's 1.5 s of credit out of 5.5 s total stays under the 60 %
    /// share.
    func testHighlightLeadNeverStartsBeforeThePreviousEvent() {
        let feed = [
            event(t: 10, people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 11, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 6, end: 11.5, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed, leads: ["telemost": 5])
        XCTAssertNil(picked[0])
    }

    /// Two services inside one feed each take their own number from the
    /// table: "svc-a"'s 0.5 s lead names the first line, "svc-b"'s 2 s lead
    /// (itself clamped to the previous event, 1 s away) names the second;
    /// with no lead at all, neither line gets a name.
    func testTwoServicesInOneFeedUseTheirOwnLead() {
        let feed = [
            event(t: 0, service: "svc-a", people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 1, service: "svc-a", people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 2, service: "svc-a", visible: false),
            event(t: 3, service: "svc-b", people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 4, service: "svc-b", people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
        ]
        let lineA = MeetingAttempt.Line(start: 0.4, end: 1.5, source: .system)
        let lineB = MeetingAttempt.Line(start: 3.3, end: 4.5, source: .system)

        let withoutLeads = CallFeed.pickedNames(for: [lineA, lineB], feed: feed, leads: [:])
        XCTAssertEqual(withoutLeads, [nil, nil])

        let withLeads = CallFeed.pickedNames(
            for: [lineA, lineB], feed: feed, leads: ["svc-a": 0.5, "svc-b": 2]
        )
        XCTAssertEqual(withLeads, ["Участник А", "Участник Б"])
    }

    /// A hidden tab right before the highlight lends no credit at all,
    /// however large the service's lead: there was nothing to read on
    /// screen during that stretch (P4). The 0.5 s of credit after the
    /// highlight, out of the line's 1 s, stays under the 60 % share.
    func testHiddenPreviousEventNeverLendsCreditEarlier() {
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 1, visible: false),
            event(t: 2, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 1.5, end: 2.5, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed, leads: ["telemost": 5])
        XCTAssertNil(picked[0])
    }

    /// A name's onset is the event's own `t`, never the shifted window
    /// start the lead opens: with the first person lit at `t=0` and the
    /// second lit at `t=5` with a 5 s lead (so the window for the second
    /// opens right at `t=0`, matching the first's onset by coincidence),
    /// the two must not tie — the second's real onset (5) still outranks
    /// the first's (0), so only the second is credited and named. Had the
    /// window's own start been recorded as the onset instead, this would
    /// tie and leave the line unnamed.
    func testOnsetKeepsTheEventsOwnTimeNotTheShiftedStart() {
        let feed = [
            event(t: 0, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
            event(t: 5, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
        ]
        let line = MeetingAttempt.Line(start: 0, end: 6, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed, leads: ["telemost": 5])
        XCTAssertEqual(picked[0], "Участник Б")
    }

    /// The lead only ever moves a system highlight's credit. The own
    /// tile's name and the summary's `tilesFound` / `people` read straight
    /// off the feed's events, with or without a lead in the table.
    func testOwnNameAndVisibilityAreNeverShiftedByLeads() {
        let feed = [
            event(t: 0, ownName: "Ведущая", people: [], speaking: []),
            event(t: 5, people: ["Гость"], speaking: ["Гость"]),
        ]
        let micLine = MeetingAttempt.Line(start: 0, end: 10, source: .microphone)
        XCTAssertEqual(CallFeed.pickedNames(for: [micLine], feed: feed, leads: [:]), ["Ведущая"])
        XCTAssertEqual(CallFeed.pickedNames(for: [micLine], feed: feed, leads: ["telemost": 5]), ["Ведущая"])

        let withoutLead = CallFeed.summary(for: [], feed: feed, leads: [:])
        let withLead = CallFeed.summary(for: [], feed: feed, leads: ["telemost": 5])
        XCTAssertEqual(withoutLead.tilesFound, withLead.tilesFound)
        XCTAssertEqual(withoutLead.people, withLead.people)
    }

    /// `pickedNames` and `summary` with no `leads` argument at all answer
    /// exactly as they do with the shared `CallFeed.highlightLeads` table
    /// passed explicitly: the four call sites that never name `leads`
    /// (the window, the helper, `MeetingText`, the transcriber) all read
    /// that one shared table, not an independent empty literal.
    func testPickedNamesDefaultsToTheSharedHighlightLeadsTable() {
        let feed = [event(t: 0, people: ["Гость"])]
        let line = MeetingAttempt.Line(start: 0, end: 10, source: .system)
        XCTAssertEqual(
            CallFeed.pickedNames(for: [line], feed: feed),
            CallFeed.pickedNames(for: [line], feed: feed, leads: CallFeed.highlightLeads)
        )
        XCTAssertEqual(
            CallFeed.summary(for: [line], feed: feed).picked,
            CallFeed.summary(for: [line], feed: feed, leads: CallFeed.highlightLeads).picked
        )
    }

    /// Jitsi's own 0.5 s lead, read from the shared `CallFeed.highlightLeads`
    /// table (no explicit `leads` argument): a line started 0.8 s before the
    /// highlight gets its 1.0 s of credit, out of 1.3 s total — above the
    /// 60 % share — and is named. With no lead at all (`leads: [:]`, same as
    /// the table before this card, and same as an unmeasured service), only
    /// 0.5 s of credit falls inside the line, short of the share, and it
    /// stays unnamed — the very numbers `testHighlightLeadCreditsALineStartedJustBeforeTheHighlight`
    /// already proves for a 1 s lead, here on Jitsi's own 0.5 s from the table.
    func testJitsiLeadFromTheSharedTableCreditsALineStartedJustBeforeTheHighlight() {
        let feed = [
            event(t: 0, service: "jitsi", people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 1, service: "jitsi", people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 0.2, end: 1.5, source: .system)

        let withoutLead = CallFeed.pickedNames(for: [line], feed: feed, leads: [:])
        XCTAssertNil(withoutLead[0])

        let withSharedTable = CallFeed.pickedNames(for: [line], feed: feed)
        XCTAssertEqual(withSharedTable[0], "Участник А")
    }

    /// Zoom's own 1.2 s lead, read from the shared `CallFeed.highlightLeads`
    /// table: a short line entirely before the highlight event (0.9–1.1 s,
    /// the highlight itself landing at 2 s) is named only once the lead
    /// reaches far enough back to cover it. A 1.0 s lead moves the credited
    /// boundary to 1.0 s, covering only 0.1 of the line's 0.2 s (50 %, short
    /// of the 60 % share) and leaves it unnamed; the table's own 1.2 s moves
    /// the boundary to 0.8 s, before the line even starts, covering it
    /// whole. Catches a transposed number (1.2 written as 2.1, or any
    /// other slip) the way a bare `XCTAssertEqual` on the constant alone
    /// would not.
    func testZoomLeadFromTheSharedTableCreditsALineEntirelyBeforeTheHighlight() {
        XCTAssertEqual(CallFeed.highlightLeads["zoom"], 1.2)

        let feed = [
            event(t: 0, service: "zoom", people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 2.0, service: "zoom", people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 0.9, end: 1.1, source: .system)

        let withOneSecondLead = CallFeed.pickedNames(for: [line], feed: feed, leads: ["zoom": 1.0])
        XCTAssertNil(withOneSecondLead[0])

        let withSharedTable = CallFeed.pickedNames(for: [line], feed: feed)
        XCTAssertEqual(withSharedTable[0], "Участник А")
    }

    // MARK: - The line before the call was ever seen with people on screen

    /// The system track's first line starts well before the feed's first
    /// sighting of the call with people on screen (`knownFrom`, here 48.87):
    /// the stretch from the line's own start (45.98) up to that point is
    /// "not yet known", not "hidden" the way an already-seen call's closed
    /// tab is. The remainder after `knownFrom` (2.43 s of the line's 5.32 s,
    /// 45.7 %) clears both the 2 s floor and the 40 % floor, so the 60 %
    /// share and the ×2 margin are judged on that remainder alone: 2.43 s
    /// credited out of 2.43 s remaining is a clean 100 %, and the line is
    /// named. On the code before this fix the share is judged on the whole
    /// 5.32 s instead (45.7 %, short of 60 %), so this assertion fails there
    /// — the test this card's fix exists to turn green.
    func testFirstLineBeforeTheCallWasEverSeenIsNamedFromTheRest() {
        let feed = [
            event(t: 1.14, people: []),
            event(t: 3.50, visible: false),
            event(t: 48.87, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 45.98, end: 51.30, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed)
        XCTAssertEqual(picked[0], "Участник А")
    }

    /// The same shape of line and feed as above, but the first sighting
    /// comes late enough that what remains of the line is short of the
    /// shift's own floors. At a remainder of 1.90 s out of 5.0 s (38 %,
    /// under both the 2 s and the 40 % floor) the shift never opens and the
    /// line keeps the whole-line share (38 %), short of 60 % — no name,
    /// same as before this fix. Move the first sighting 0.13 s earlier and
    /// the remainder is 2.03 s out of the same 5.0 s (40.6 %, just past both
    /// floors): the shift opens, the remainder is credited to the one
    /// person whole, and the line is named — a share the code before this
    /// fix never reaches (2.03 s of 5.0 s is 40.6 %, short of 60 %), so this
    /// second assertion is the one that fails there.
    func testUnseenOpeningNeedsTwoSecondsAndFortyPercentLeft() {
        let line = MeetingAttempt.Line(start: 45.0, end: 50.0, source: .system)

        let tooLate = [
            event(t: 1.14, people: []),
            event(t: 3.50, visible: false),
            event(t: 48.10, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        XCTAssertNil(CallFeed.pickedNames(for: [line], feed: tooLate)[0])

        let justInTime = [
            event(t: 1.14, people: []),
            event(t: 3.50, visible: false),
            event(t: 47.97, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        XCTAssertEqual(CallFeed.pickedNames(for: [line], feed: justInTime)[0], "Участник А")
    }

    /// The round-3 rule is untouched: when the call was already seen with
    /// people (here at 1.14, long before this line even starts) and the tab
    /// is then closed mid-call (3.50), the line's share is still judged
    /// against its whole length, never the remainder alone — `knownFrom`
    /// here (1.14) is not after the line's own start (45.98), so the shift
    /// never considers this line at all. The same 2.43 s of credit out of
    /// the line's 5.32 s (45.7 %) stays short of 60 % and the line keeps no
    /// name, exactly as before this fix.
    func testTabHiddenAfterTheCallWasAlreadySeenStillMeasuresTheFullLine() {
        let feed = [
            event(t: 1.14, people: ["Участник А", "Участник Б"], speaking: []),
            event(t: 3.50, visible: false),
            event(t: 48.87, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 45.98, end: 51.30, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed)
        XCTAssertNil(picked[0])
    }

    /// A speaker change right at the border between "not yet known" and
    /// "known": the first person is credited from the first sighting
    /// (48.87) until the second takes over, and only the second's own share
    /// of the remainder (2.43 s after 48.87) decides the name — the first
    /// person's seconds before the switch are never counted for the second,
    /// nor folded into some looser whole-line tally. A switch at 49.20
    /// gives the second person 2.10 s of the 2.43 s remainder (86.4 %,
    /// clearing both the 60 % share and the ×2 margin over the first
    /// person's 0.33 s): named. A switch at 49.90 gives the second person
    /// only 1.40 s of 2.43 s (57.6 %, short of 60 %): no name. A switch at
    /// 49.77 gives the second person 1.53 s of 2.43 s (63.0 %, past the
    /// share) but only 1.53 s against the first person's 0.90 s remaining
    /// (short of the required ×2): no name either. The code before this fix
    /// judges the second person's share against the whole 5.32 s line
    /// (39.5 % at 49.20), so the first assertion fails there.
    func testSpeakerChangeAtTheFirstSightingIsJudgedOnTheRest() {
        let line = MeetingAttempt.Line(start: 45.98, end: 51.30, source: .system)
        func feed(switchingAt switchTime: TimeInterval) -> [CallFeed.Event] {
            [
                event(t: 1.14, people: []),
                event(t: 3.50, visible: false),
                event(t: 48.87, people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
                event(t: switchTime, people: ["Участник А", "Участник Б"], speaking: ["Участник Б"]),
            ]
        }

        XCTAssertEqual(CallFeed.pickedNames(for: [line], feed: feed(switchingAt: 49.20))[0], "Участник Б")
        XCTAssertNil(CallFeed.pickedNames(for: [line], feed: feed(switchingAt: 49.90))[0])
        XCTAssertNil(CallFeed.pickedNames(for: [line], feed: feed(switchingAt: 49.77))[0])
    }

    /// A lead (here Zoom's own 1.2 s from the shared table) can open a
    /// credited interval before the feed's first sighting of the call with
    /// people — but the remainder after that sighting (4.2) is only 1.8 s
    /// of the line's 6 s, short of the shift's 2 s floor. The shift stays
    /// closed, and the whole-line share (3.0 s of lead-plus-highlight
    /// credit out of 6 s, 50 %) stays short of 60 % as before: no name.
    /// Guards against a version of the fix that opens the shift from the
    /// lead-widened credited interval's own start rather than the event
    /// `knownFrom` is defined from — that softer rule would instead measure
    /// 3.0 s against a 4.2 s-knownFrom-to-line-start... it would, in fact,
    /// widen the remainder back out past 2 s and wrongly name the line.
    func testLeadBeforeTheFirstSightingDoesNotOpenTheShortcut() {
        let feed = [
            event(t: 0, service: "zoom", people: [], speaking: []),
            event(t: 4.2, service: "zoom", people: ["Участник А", "Участник Б"], speaking: ["Участник А"]),
        ]
        let line = MeetingAttempt.Line(start: 0, end: 6, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed)
        XCTAssertNil(picked[0])
    }

    /// A highlight with nobody in `people` at all (a caption-only reader
    /// that reports `speaking` without ever filling the tile list) never
    /// counts as a sighting of the call with people on screen, so
    /// `knownFrom` stays nil and the shift never opens: the line's 2.5 s of
    /// credit out of its 5 s (50 %) is judged against the whole line, as
    /// before, and stays short of 60 % — no name.
    func testHighlightWithoutAPeopleListNeverOpensTheShortcut() {
        let feed = [event(t: 2.5, people: [], speaking: ["Гость"])]
        let line = MeetingAttempt.Line(start: 0, end: 5, source: .system)
        let picked = CallFeed.pickedNames(for: [line], feed: feed)
        XCTAssertNil(picked[0])
    }

    // MARK: - A call window on another desktop (#59 tail)

    /// `offscreen: true` round-trips through the encoder; `false` writes no
    /// key at all, byte for byte as a line written before this field
    /// existed — and a line of that old shape, with no key, reads as
    /// `offscreen == false`. A line with an unknown extra key is still read
    /// (the decoder is synthesized `Decodable`: an unrecognized key is
    /// skipped, not a decode failure), which also covers a future key a
    /// line like this might one day carry.
    func testOffscreenFlagRoundTripsAndOldLinesReadOnScreen() {
        let offscreenEvent = event(t: 1, people: ["Гость"], offscreen: true)
        XCTAssertTrue(offscreenEvent.encodedLine().contains("\"offscreen\":true"))
        XCTAssertEqual(CallFeed.parse(offscreenEvent.encodedLine()), [offscreenEvent])

        let onScreenEvent = event(t: 1, people: ["Гость"], offscreen: false)
        XCTAssertFalse(onScreenEvent.encodedLine().contains("offscreen"))
        XCTAssertEqual(CallFeed.parse(onScreenEvent.encodedLine()), [onScreenEvent])

        let oldLine = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость"],"speaking":[]}
        """
        XCTAssertEqual(CallFeed.parse(oldLine).first?.offscreen, false)

        let futureKeyLine = """
        {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Гость"],"speaking":[],"future":1}
        """
        XCTAssertEqual(CallFeed.parse(futureKeyLine).count, 1)
    }

    /// A highlight read off screen keeps its credit only for
    /// `CallFeed.offscreenHighlightLimit` (10 s) after the `speaking` set
    /// last changed — a page Chrome froze on another desktop must not give
    /// the last speaker every line for as long as nobody looks at that
    /// desktop again. [0, 12) keeps 10 of its 12 s credited (past the 60 %
    /// share): named. [0, 16) still clears the share at the 10 s boundary
    /// (62.5 %); [0, 17) falls just short (58.8 %) — the two lines next to
    /// each other pin the 10 s limit itself, not just "somewhere under
    /// 18 s". [12, 30) and [0, 30) get none of that credit at all: no name.
    /// The very same feed read on screen (no `offscreen` key at all) keeps
    /// naming every line, exactly as before this card.
    func testFrozenOffscreenHighlightCountsAtMostTenSeconds() {
        let frozen = CallFeed.parse(
            """
            {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"],"offscreen":true}
            {"v":1,"t":15,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков","Вера Сомова"],"speaking":["Арина Веткина"],"offscreen":true}
            """
        )
        XCTAssertEqual(frozen.count, 2)
        func picked(start: TimeInterval, end: TimeInterval) -> String? {
            CallFeed.pickedNames(for: [MeetingAttempt.Line(start: start, end: end, source: .system)], feed: frozen)[0]
        }
        XCTAssertEqual(picked(start: 0, end: 12), "Арина Веткина")
        XCTAssertEqual(picked(start: 0, end: 16), "Арина Веткина")
        XCTAssertNil(picked(start: 0, end: 17))
        XCTAssertNil(picked(start: 12, end: 30))
        XCTAssertNil(picked(start: 0, end: 30))

        let onScreen = CallFeed.parse(
            """
            {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"]}
            {"v":1,"t":15,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков","Вера Сомова"],"speaking":["Арина Веткина"]}
            """
        )
        func pickedOnScreen(start: TimeInterval, end: TimeInterval) -> String? {
            CallFeed.pickedNames(for: [MeetingAttempt.Line(start: start, end: end, source: .system)], feed: onScreen)[0]
        }
        XCTAssertEqual(pickedOnScreen(start: 0, end: 30), "Арина Веткина")

        // The single-other rule (unaffected by the freeze) still applies
        // off screen: one person on the whole call, their own tile
        // confirmed — named for the full 30 s even though nothing changed.
        let singleOther = CallFeed.parse(
            """
            {"v":1,"t":0,"service":"telemost","visible":true,"self":"Я Сам","selfSpeaking":false,"selfVisible":true,"people":["Борис Луков"],"speaking":["Борис Луков"],"offscreen":true}
            """
        )
        XCTAssertEqual(
            CallFeed.pickedNames(for: [MeetingAttempt.Line(start: 0, end: 30, source: .system)], feed: singleOther)[0],
            "Борис Луков"
        )
    }

    /// A page that keeps changing its highlight while off screen (pauses
    /// alone give an empty `speaking` set) never crosses the 10 s freeze at
    /// all — every change resets the clock — so the names come out exactly
    /// as they would on screen. A version of the fix that measured 10 s
    /// from the very start of being off screen, rather than from the last
    /// change, would wrongly give `nil` for [0, 25).
    func testLiveOffscreenHighlightNamesAsOnScreen() {
        let people = ["Арина Веткина", "Борис Луков"]
        let live = CallFeed.parse(
            """
            {"v":1,"t":0,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"],"offscreen":true}
            {"v":1,"t":4,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":5,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"],"offscreen":true}
            {"v":1,"t":9,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":10,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"],"offscreen":true}
            {"v":1,"t":14,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":15,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"],"offscreen":true}
            {"v":1,"t":19,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":20,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Арина Веткина"],"offscreen":true}
            {"v":1,"t":24,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":25,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Борис Луков"],"offscreen":true}
            {"v":1,"t":29,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":30,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Борис Луков"],"offscreen":true}
            {"v":1,"t":34,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            {"v":1,"t":35,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":["Борис Луков"],"offscreen":true}
            {"v":1,"t":39,"service":"telemost","visible":true,"self":null,"selfSpeaking":false,"people":["Арина Веткина","Борис Луков"],"speaking":[],"offscreen":true}
            """
        )
        XCTAssertEqual(live.count, 16)
        XCTAssertTrue(live.allSatisfy { $0.people == people })
        let picked = CallFeed.pickedNames(
            for: [
                MeetingAttempt.Line(start: 0, end: 25, source: .system),
                MeetingAttempt.Line(start: 25, end: 40, source: .system),
            ],
            feed: live
        )
        XCTAssertEqual(picked[0], "Арина Веткина")
        XCTAssertEqual(picked[1], "Борис Луков")

        let onScreenLive = live.map { event in
            CallFeed.Event(
                t: event.t, service: event.service, visible: event.visible, ownName: event.ownName,
                selfSpeaking: event.selfSpeaking, people: event.people, speaking: event.speaking,
                selfVisible: event.selfVisible, offscreen: false
            )
        }
        let pickedOnScreen = CallFeed.pickedNames(
            for: [
                MeetingAttempt.Line(start: 0, end: 25, source: .system),
                MeetingAttempt.Line(start: 25, end: 40, source: .system),
            ],
            feed: onScreenLive
        )
        XCTAssertEqual(picked, pickedOnScreen)
    }

    /// K2 of the other-desktop card: the page comes back on screen at 4 s,
    /// well inside the 10 s freeze limit, and stays on screen until a later
    /// closing event (`visible: false`, as a stop writes). The line after
    /// the return must be named exactly as it would be read on screen the
    /// whole time — the freeze must never reach past the moment the page
    /// stopped being off screen.
    func testHighlightReturningOnScreenWithinTheLimitIsNamedAsOnScreen() {
        let feed = [
            event(t: 0, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: true),
            event(t: 4, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: false),
            event(t: 20, visible: false),
        ]
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 20, source: .system)], feed: feed
        )
        XCTAssertEqual(picked[0], "Арина Веткина")
    }

    /// K2: a highlight change that happens while the page is on screen,
    /// between two off-screen reads, is measured here through the same
    /// picking function a transcript line would use — `speaking` toggling
    /// to a different name while on screen must still name that line, never
    /// be mistaken for a frozen off-screen highlight.
    func testHighlightChangeOnScreenBetweenOffscreenReadsStillNamesTheLine() {
        let feed = [
            event(t: 0, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: true),
            event(t: 2, people: ["Арина Веткина", "Борис Луков"], speaking: ["Борис Луков"], offscreen: false),
            event(t: 4, people: ["Арина Веткина", "Борис Луков"], speaking: ["Борис Луков"], offscreen: true),
        ]
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 2, end: 14, source: .system)], feed: feed
        )
        XCTAssertEqual(picked[0], "Борис Луков")
    }

    /// K2: Zoom's and Jitsi's own highlight lead (1.2 s / 0.5 s) may start
    /// earlier than a pending off-screen cut. The cut must never be
    /// inserted behind the lead's own interval — doing so would both break
    /// the rising `start` order `systemName`'s binary search depends on and
    /// wrongly cut a highlight the lead had already credited. A line that
    /// exactly spans the lead's own window must come out named in full, not
    /// split by a misplaced cut.
    func testServiceLeadBeforeAPendingCutIsNeverInsertedBehindIt() {
        let zoomFeed = [
            event(t: 0, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: true),
            event(
                t: 10.5, service: "zoom", people: ["Арина Веткина", "Борис Луков"], speaking: ["Борис Луков"],
                offscreen: false
            ),
        ]
        let zoomPicked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 9.3, end: 10.5, source: .system)], feed: zoomFeed
        )
        XCTAssertEqual(zoomPicked[0], "Борис Луков")

        let jitsiFeed = [
            event(t: 0, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: true),
            event(
                t: 10.3, service: "jitsi", people: ["Арина Веткина", "Борис Луков"], speaking: ["Борис Луков"],
                offscreen: false
            ),
        ]
        let jitsiPicked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 9.8, end: 10.3, source: .system)], feed: jitsiFeed
        )
        XCTAssertEqual(jitsiPicked[0], "Борис Луков")
    }

    /// K3: the feed breaks off mid-freeze — the recording stopped before a
    /// closing `visible: false` line could apply the 10 s cut, so the only
    /// event at all is an off-screen one whose highlight never changes
    /// again. The credit must still stop at the limit rather than naming
    /// the whole line, which only `buildIntervals` applying the pending cut
    /// after its last event (not just between two events) can do.
    func testFeedEndingMidFreezeStillAppliesTheCutoff() {
        let feed = [
            event(t: 0, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: true)
        ]
        let picked = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 30, source: .system)], feed: feed
        )
        XCTAssertNil(picked[0], "must not go on naming the frozen speaker past the 10 s limit")
    }

    /// Locks the freeze cutoff to exactly 10 s, not merely "somewhere under
    /// 30 s": at a 16 s line the named share is 10/16 ≈ 62.5 %, just past
    /// `CallFeed.dominantShare` (60 %), and at 17 s it is 10/17 ≈ 58.8 %,
    /// just short of it. A cutoff anywhere in roughly 15–18 s would still
    /// pass both assertions, so each line's own math is spelled out here.
    func testFeedEndingMidFreezeLocksTheCutoffToTenSeconds() {
        let feed = [
            event(t: 0, people: ["Арина Веткина", "Борис Луков"], speaking: ["Арина Веткина"], offscreen: true)
        ]

        let justInside = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 16, source: .system)], feed: feed
        )
        XCTAssertEqual(justInside[0], "Арина Веткина", "10/16 ≈ 62.5 % still clears the 60 % share")

        let justOutside = CallFeed.pickedNames(
            for: [MeetingAttempt.Line(start: 0, end: 17, source: .system)], feed: feed
        )
        XCTAssertNil(justOutside[0], "10/17 ≈ 58.8 % no longer clears the 60 % share")
    }
}
