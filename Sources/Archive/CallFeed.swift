import Foundation

/// The watcher of a call page (a separate card) writes one line of JSON per
/// change into `.call.murmurly.jsonl`, in the meeting's own folder, as the
/// call goes: who is on screen, who is the user's own tile, and who is
/// highlighted (speaking) right now. This type is the one format both the
/// writer and this card's picking function agree on; it is in `Sources/Archive`
/// so it builds into the app and into the read-only helper alike.
enum CallFeed {
    /// The feed file's name inside a meeting's folder.
    static let fileName = ".call.murmurly.jsonl"

    /// The feed's current format version. A line of any other version is
    /// skipped, not refused: an older or newer Murmurly's lines stay in the
    /// file, untouched, next to this version's.
    static let formatVersion = 1

    /// One change the watcher saw.
    struct Event: Sendable, Equatable {
        /// Seconds of audio already written to the tracks when this
        /// happened — the same scale as `MeetingAttempt.Line.start`/`end`.
        var t: TimeInterval
        var service: String
        /// Whether any tile at all was found on the page.
        var visible: Bool
        /// The name on the user's own tile; nil when there is none.
        var ownName: String?
        var selfSpeaking: Bool
        /// Other people's tiles, by name, without repeats: the same name
        /// twice is one person, never two.
        var people: [String]
        /// Of `people`, those highlighted (speaking) right now.
        var speaking: [String]
        /// Whether the user's own tile was visible on screen when this was
        /// read; `nil` for a line written before this field existed (an old
        /// feed, or an event built without naming it), which keeps the
        /// previous, looser single-other rule rather than being read as
        /// "known absent". Set only by a reader that actually looks for its
        /// own tile; a page that reads by caption only (web Zoom) never sets
        /// it, so it never satisfies the single-other rule below on its own.
        var selfVisible: Bool?
        /// Whether the page was read through a window on another desktop,
        /// or through a listed window that is not currently on screen
        /// (`MeetingPageReader`, another card). `false` for a line written
        /// before this field existed: an old feed is read as "on screen",
        /// the previous (and only) behaviour.
        var offscreen: Bool

        /// One line, no `*`: the same cleaning `MeetingLibrary.speakerName`
        /// gives a typed name, applied here to the own tile and to every
        /// other name alike, so none of them can break a transcript line's
        /// `**label:**` later.
        static func cleanedName(_ name: String) -> String? {
            let cleaned = name.components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }

        /// Names cleaned the same way, without repeats, in their first order.
        private static func cleanedNames(_ names: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for name in names {
                guard let cleaned = cleanedName(name), !seen.contains(cleaned) else { continue }
                seen.insert(cleaned)
                result.append(cleaned)
            }
            return result
        }

        /// `speaking` keeps every cleaned name of its own, even one `people`
        /// does not list: the dominant-speaker count credits those too
        /// (K1) rather than silently drop a highlight the writer and this
        /// reader disagree about.
        fileprivate init(line: Line) {
            t = line.t
            service = line.service
            visible = line.visible
            ownName = line.selfName.flatMap(Event.cleanedName)
            selfSpeaking = line.selfSpeaking
            people = Event.cleanedNames(line.people)
            speaking = Event.cleanedNames(line.speaking)
            selfVisible = line.selfVisible
            offscreen = line.offscreen ?? false
        }

        init(
            t: TimeInterval, service: String, visible: Bool, ownName: String?, selfSpeaking: Bool,
            people: [String], speaking: [String], selfVisible: Bool? = nil, offscreen: Bool = false
        ) {
            self.t = t
            self.service = service
            self.visible = visible
            self.ownName = ownName.flatMap(Event.cleanedName)
            self.selfSpeaking = selfSpeaking
            self.people = Event.cleanedNames(people)
            self.speaking = Event.cleanedNames(speaking)
            self.selfVisible = selfVisible
            self.offscreen = offscreen
        }

        /// The JSON line the watcher writes, ending with a newline, with a
        /// written `"self": null` (never an omitted key) and keys in a
        /// fixed order, so a byte-for-byte round trip is simple to test.
        func encodedLine() -> String {
            let line = Line(
                v: CallFeed.formatVersion, t: t, service: service, visible: visible, selfName: ownName,
                selfSpeaking: selfSpeaking, people: people, speaking: speaking, selfVisible: selfVisible,
                // The key is written only when true: an on-screen line stays
                // byte for byte what it was before this field existed.
                offscreen: offscreen ? true : nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(line), let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text + "\n"
        }
    }

    /// The JSON shape on disk; `self` cannot be a usable Swift property name
    /// (`.self` is already the built-in identity accessor), so it is only a
    /// coding key here.
    fileprivate struct Line: Codable {
        var v: Int
        var t: TimeInterval
        var service: String
        var visible: Bool
        var selfName: String?
        var selfSpeaking: Bool
        var people: [String]
        var speaking: [String]
        var selfVisible: Bool?
        var offscreen: Bool?

        enum CodingKeys: String, CodingKey {
            case v, t, service, visible
            case selfName = "self"
            case selfSpeaking, people, speaking, selfVisible, offscreen
        }

        /// Written by hand so a nil `selfName` encodes as `"self": null`:
        /// the synthesized conformance would use `encodeIfPresent` and drop
        /// the key instead, which this format's readers (this one and the
        /// watcher's own) must not have to tell apart from "never read".
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(v, forKey: .v)
            try container.encode(t, forKey: .t)
            try container.encode(service, forKey: .service)
            try container.encode(visible, forKey: .visible)
            if let selfName {
                try container.encode(selfName, forKey: .selfName)
            } else {
                try container.encodeNil(forKey: .selfName)
            }
            try container.encode(selfSpeaking, forKey: .selfSpeaking)
            try container.encode(people, forKey: .people)
            try container.encode(speaking, forKey: .speaking)
            try container.encodeIfPresent(selfVisible, forKey: .selfVisible)
            try container.encodeIfPresent(offscreen, forKey: .offscreen)
        }
    }

    /// The feed read from a meeting's folder: nil when the file itself is
    /// absent (missing is not an error, "no feed" either way the links
    /// policy reads it), else its parsed events; any other read failure
    /// (an unreadable file, a link `.refuse` won't follow) throws, since an
    /// unreadable feed must not be mistaken for an absent one.
    static func read(in folder: URL, links: Archive.Links = .follow) throws -> [Event]? {
        let url = folder.appendingPathComponent(fileName)
        let data: Data
        do {
            data = try Archive.read(url, links: links)
        } catch Archive.ReadError.missing {
            return nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return parse(data)
    }

    /// The feed's events, in order. A line that cannot be read (a damaged
    /// last line from a killed process, a foreign version, a non-numeric,
    /// negative or decreasing `t`) is skipped; the rest still counts. An
    /// empty file parses to an empty array; whether there is a file at all
    /// is `read(in:links:)`'s own concern, not this function's.
    static func parse(_ raw: String) -> [Event] {
        parse(Data(raw.utf8))
    }

    /// Splits on the raw bytes first and decodes each line's own bytes
    /// strictly (`String(data:encoding:)`, not the lossy, replacement-
    /// character `String(decoding:as:)`): a line damaged by a crash mid-write
    /// can contain invalid UTF-8 partway through, and that must drop only
    /// that one line, never turn it into a readable line with `\u{FFFD}` in
    /// a name, nor (by one `String(decoding:)` over the whole file) corrupt
    /// every line after it.
    static func parse(_ data: Data) -> [Event] {
        var events: [Event] = []
        var lastT = -TimeInterval.infinity
        let newline = UInt8(ascii: "\n")
        for row in data.split(separator: newline, omittingEmptySubsequences: true) {
            guard let text = String(data: row, encoding: .utf8),
                  let jsonData = text.data(using: .utf8),
                  let line = try? JSONDecoder().decode(Line.self, from: jsonData),
                  line.v == formatVersion,
                  line.t.isFinite, line.t >= 0, line.t >= lastT
            else { continue }
            lastT = line.t
            events.append(Event(line: line))
        }
        return events
    }

    /// What one meeting's feed says, summed up for the text and the Names
    /// sheet: a name per transcript line (`pickedNames`, unchanged), every
    /// person the feed ever showed a tile for, and whether a tile was found
    /// at all. Built once per read, off the window's `body`: a feed can run
    /// into the tens of thousands of events, and naming each line only
    /// walks `picked`, never the feed itself again.
    struct Summary: Sendable, Equatable {
        /// One name per line of the attempt's record, in the same order,
        /// exactly `pickedNames(for:feed:)`'s own answer.
        var picked: [String?]
        /// Every name the feed's `people` or `speaking` ever held, without
        /// repeats, in the order each first appeared; the user's own tile
        /// (`ownName`) is never in it — the Microphone field speaks for it.
        var people: [String]
        /// Whether any event at all had `visible` true: a tile was found at
        /// least once. False means the feed never showed anything to pick
        /// a system name from, which the Names sheet and the card say in
        /// their own words — `picked` and `people` are not forced empty for
        /// it, as the microphone's own-tile name does not depend on `visible`.
        var tilesFound: Bool
    }

    /// Builds a `Summary` from the feed and the attempt's lines in one pass.
    static func summary(
        for lines: [MeetingAttempt.Line], feed: [Event], leads: [String: TimeInterval] = CallFeed.highlightLeads
    ) -> Summary {
        var seen = Set<String>()
        var people: [String] = []
        for event in feed {
            for name in event.people + event.speaking where !seen.contains(name) {
                seen.insert(name)
                people.append(name)
            }
        }
        return Summary(
            picked: pickedNames(for: lines, feed: feed, leads: leads), people: people,
            tilesFound: feed.contains { $0.visible }
        )
    }

    /// How much earlier than the feed's own highlight event the credit for
    /// a newly-highlighted name may start, by `service`; an unmeasured or
    /// unknown service is 0 — no shift at all. A live stand measures each
    /// service's own delay between speech starting and its highlight
    /// lighting up (about 1.2 s for Zoom, by published research). Jitsi's
    /// own `dominant-speaker` class was measured lighting up 0.42–0.74 s
    /// after speech started (a public `meet.ffmuc.net` stand, 2026-10-30);
    /// 0.5 s stays short of that measured maximum, so the credit never
    /// reaches back before the previous speaker's own event. Zoom's own
    /// "active speaker" marker was measured lighting up about 1.2 s after
    /// speech started (Nook's `ZoomRosterReader.swift`, read vs. live Zoom).
    /// Telemost has no lead in this table.
    static let highlightLeads: [String: TimeInterval] = ["jitsi": 0.5, "zoom": 1.2]

    /// How long a highlight read off screen (`Event.offscreen`) keeps being
    /// credited after the `speaking` set last changed. A page on another
    /// desktop may be frozen by the browser, and a frozen highlight would
    /// otherwise give the last speaker every line for as long as nobody
    /// returns to that desktop; a live call changes `speaking` constantly
    /// (pauses alone give an empty set), so this limit never trims a call
    /// that is actually still being read.
    static let offscreenHighlightLimit: TimeInterval = 10

    /// A clear majority of a system line's length: short of it, the line is
    /// a mix and keeps the track's own label rather than guess.
    static let dominantShare = 0.6
    /// How far ahead of the next-most-credited person the winner must be:
    /// guards a close call between two people from picking either by chance.
    static let dominantMargin = 2.0
    /// The least a line's remainder after its first sighting of the call
    /// (`knownFrom`) may be, as a share of the line's own length, for the
    /// 60 % share and the ×2 margin to be measured against that remainder
    /// instead of the whole line.
    static let dominantRemainderShare = 0.4
    /// The least a line's remainder after `knownFrom` may be, in seconds,
    /// for the same shift.
    static let dominantRemainderMinimum: TimeInterval = 2.0

    /// One name per line of an attempt's record, in the same order, picked
    /// from the feed; nil where the feed does not say, or says too little
    /// to be sure. A line with a non-finite or non-positive span (`end <=
    /// start`, or either not finite) always gets nil: there is no span to
    /// look at.
    ///
    /// Everything that looks at the whole feed — sorting it, folding the
    /// own tile's last known name, and building the per-interval highlight
    /// state — happens exactly once, before the lines are walked; each line
    /// then only binary-searches into that one pass and walks the handful
    /// of intervals its own span touches. A meeting's feed can run into the
    /// tens of thousands of events and a transcript into thousands of
    /// lines, and the earlier version rebuilt a sorted boundary set and the
    /// whole onset calculation again for every single line, which made
    /// picking quadratic in the feed's length.
    static func pickedNames(
        for lines: [MeetingAttempt.Line], feed: [Event], leads: [String: TimeInterval] = CallFeed.highlightLeads
    ) -> [String?] {
        // A stable sort on `t`: two events of the same `t` keep the feed's
        // own order (the later one in the file is the current state), which
        // a plain `sorted` does not promise for equal elements (K4).
        let events = feed.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map(\.element)

        var ownNameAsOf: [String?] = []
        ownNameAsOf.reserveCapacity(events.count)
        var lastOwnName: String?
        for event in events {
            if let name = event.ownName { lastOwnName = name }
            ownNameAsOf.append(lastOwnName)
        }
        let intervals = buildIntervals(events, leads: leads)
        // Every other name the whole feed ever showed on a visible tile, in
        // `people` or `speaking` alike: the single-other shortcut below may
        // only fire when this set holds exactly one name, so a third person
        // seen anywhere else in the call (a scrolled-off tile, a later or
        // earlier moment) rules it out, never only this one line's own span.
        let allOtherNames = Set(events.filter(\.visible).flatMap { $0.people + $0.speaking })
        // The first moment the feed actually saw the call with people on
        // screen (`visible` and a non-empty `people`), or nil when it never
        // did. Seconds before this point are "not yet known", never "hidden"
        // (the round-3 rule for a tab closed mid-call, which keeps measuring
        // the full line, is unaffected: it only applies once this point is
        // behind the line's own start).
        let knownFrom = events.first { $0.visible && !$0.people.isEmpty }?.t

        return lines.map { line in
            guard line.start.isFinite, line.end.isFinite, line.end > line.start else { return nil }
            switch line.source {
            case .microphone:
                // An event exactly at `end` belongs to the next line, not
                // this one, the same half-open rule the system track uses.
                let index = lastIndex(in: events, strictlyBefore: line.end)
                return index >= 0 ? ownNameAsOf[index] : nil
            case .system:
                return systemName(
                    start: line.start, end: line.end, intervals: intervals, allOtherNames: allOtherNames,
                    knownFrom: knownFrom
                )
            }
        }
    }

    /// The largest index whose `t` is strictly less than `target`, or -1
    /// when none is (including an empty feed). `events` must already be
    /// sorted by `t`.
    private static func lastIndex(in events: [Event], strictlyBefore target: TimeInterval) -> Int {
        var low = 0
        var high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].t < target { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    /// One state change per feed event, in file order: who was on screen,
    /// whether the tab was visible at all, and who is currently credited
    /// with the ongoing highlight (the onset rule, K1/K6, below). Lasts
    /// until the next interval's `start`, or forever for the last one —
    /// never clipped to any one line's own span, so a highlight's onset
    /// carries correctly into a line that starts mid-highlight.
    private struct Interval {
        let start: TimeInterval
        let visible: Bool
        let people: Set<String>
        let credited: Set<String>
        /// Whether the event this interval comes from can tell "I am the
        /// only other tile" apart from "my own tile just wasn't read" — true
        /// when the own tile was seen (`ownName` or `selfVisible == true`),
        /// or when the reader never looks for one at all (`selfVisible ==
        /// nil`, an old feed or a caption-only reader): either way a single
        /// other tile really is the whole call. `false` only when the
        /// reader looked for its own tile and did not see it (`selfVisible
        /// == false`) — the single remaining tile could then be anyone, not
        /// necessarily the other half of a pair with the user.
        let pairConfirmed: Bool
    }

    private static func pairConfirmed(_ event: Event) -> Bool {
        event.selfVisible == nil || event.selfVisible == true || event.ownName != nil
    }

    /// The onset rule (K1): a highlighted name is credited for as long as
    /// it stays among the most recently highlighted. Two overlapping
    /// highlights (an interruption) hand the credit to whichever lit up
    /// last; when that later one goes dark and an earlier one is still lit,
    /// the credit goes back to the earlier one, not to nobody. Two names
    /// lighting up in the very same event tie on onset (K6): crediting only
    /// one of them, picked by dictionary order, let either cross both
    /// thresholds off a coin flip that could change between runs, so a tie
    /// credits all of them in full for that stretch instead — then neither
    /// clears the ×2 margin over the other, and the line keeps its mixed
    /// label rather than naming either one. An empty highlight, or an
    /// invisible tab, credits nobody. `speaking` counts here even for a
    /// name `people` does not also list: the writer and this reader must
    /// not quietly disagree about who that is.
    ///
    /// `leads`, by `service`, lets a name that just lit up for the first
    /// time (a fresh onset, never a continuing one) be credited starting
    /// earlier than the event that reported it: the service's own gap
    /// between speech starting and its highlight catching up. That earlier
    /// start never reaches before the previous event's own time — there is
    /// no highlight yet to read before it — nor before the previous event
    /// at all when that one was invisible (no seconds a hidden tab ever
    /// showed are credited to anyone), nor before the feed's very first
    /// event. The onset map itself still keeps the event's own `t`, never
    /// the shifted start: only the interval boundary moves. The extra
    /// interval, when there is one, is appended before the event's own, so
    /// `Interval.start` keeps rising, which `lastIndex(in:atMost:)`'s binary
    /// search depends on.
    private static func buildIntervals(_ events: [Event], leads: [String: TimeInterval]) -> [Interval] {
        var onset: [String: TimeInterval] = [:]
        var intervals: [Interval] = []
        intervals.reserveCapacity(events.count)

        // The off-screen freeze (K1–K3): `lastChangeTime` is the `t` of the
        // last event whose raw `speaking` set differed from the one before
        // it (the very first event always counts as a change). An
        // off-screen event past `lastChangeTime + offscreenHighlightLimit`
        // is credited nothing of its own; one still within the limit keeps
        // its normal credit but registers `pendingCut`, the moment that
        // credit must stop if nothing changes before then. `pendingCut` is
        // resolved — inserted as an empty-credit tail of the event that set
        // it, or dropped — right before the next event's own interval (and
        // its lead interval, if any) is appended, so it never lands after
        // an interval already in the array: an on-screen event, or any
        // change of the `speaking` set, quenches it outright instead.
        var lastSpeakingSet: Set<String>?
        var lastChangeTime: TimeInterval = 0
        var pendingCut: (time: TimeInterval, event: Event)?

        for (index, event) in events.enumerated() {
            let rawSpeaking = Set(event.speaking)
            let speakingChanged = lastSpeakingSet.map { $0 != rawSpeaking } ?? true
            let previousPendingCut = pendingCut
            pendingCut = nil
            if speakingChanged {
                lastChangeTime = event.t
                lastSpeakingSet = rawSpeaking
            }

            var newNames: Set<String> = []
            if event.visible {
                for name in onset.keys where !rawSpeaking.contains(name) { onset.removeValue(forKey: name) }
                for name in rawSpeaking where onset[name] == nil {
                    onset[name] = event.t
                    newNames.insert(name)
                }
            } else {
                onset.removeAll()
            }
            var credited: Set<String> = []
            if event.visible, let maxOnset = onset.values.max() {
                credited = Set(onset.filter { $0.value == maxOnset }.keys)
            }

            var effectiveCredited = credited
            if event.offscreen {
                if event.t >= lastChangeTime + offscreenHighlightLimit {
                    effectiveCredited = []
                } else if !credited.isEmpty {
                    pendingCut = (lastChangeTime + offscreenHighlightLimit, event)
                }
            }

            var leadInterval: Interval?
            if index > 0, !newNames.isEmpty, events[index - 1].visible {
                let previous = events[index - 1]
                let lead = leads[event.service] ?? 0
                let start = Swift.max(event.t - lead, previous.t)
                if start < event.t {
                    leadInterval = Interval(
                        start: start, visible: previous.visible, people: Set(previous.people), credited: newNames,
                        pairConfirmed: pairConfirmed(previous)
                    )
                }
            }
            let nextStart = leadInterval?.start ?? event.t

            // A cut strictly between the last interval already added and
            // where this event's own interval (or its lead) is about to
            // start: the freeze really did last into this event, so its
            // tail is credited to nobody. Anything else (quenched by a
            // `speaking` change above, or this event arriving before the
            // cut would have struck) is simply dropped — Zoom's and
            // Jitsi's own lead can start earlier than a cut that never gets
            // to fire, and appending it anyway would break the rising
            // `start` order `lastIndex(in:atMost:)` depends on.
            if let cut = previousPendingCut, let last = intervals.last, cut.time > last.start, cut.time < nextStart {
                intervals.append(Interval(
                    start: cut.time, visible: cut.event.visible, people: Set(cut.event.people), credited: [],
                    pairConfirmed: pairConfirmed(cut.event)
                ))
            }

            if let leadInterval { intervals.append(leadInterval) }
            intervals.append(Interval(
                start: event.t, visible: event.visible, people: Set(event.people), credited: effectiveCredited,
                pairConfirmed: pairConfirmed(event)
            ))
        }

        // K3: a feed that ends on a still-credited off-screen event (the
        // recording broke off before a closing `visible: false` line could
        // apply the cut above) never gets another event to resolve
        // `pendingCut` against — apply it here instead, so a name still
        // never carries more than `offscreenHighlightLimit` seconds past the
        // last change of `speaking`.
        if let cut = pendingCut, let last = intervals.last, cut.time > last.start {
            intervals.append(Interval(
                start: cut.time, visible: cut.event.visible, people: Set(cut.event.people), credited: [],
                pairConfirmed: pairConfirmed(cut.event)
            ))
        }
        return intervals
    }

    /// The largest index whose `start` is at most `target`, or -1 when
    /// every interval starts after it (including an empty feed).
    private static func lastIndex(in intervals: [Interval], atMost target: TimeInterval) -> Int {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].start <= target { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    /// Walks only the intervals `[start, end)` actually overlaps (found by
    /// one binary search, then forward from there), checking the "exactly
    /// one other person, the whole time" case and tallying highlighted
    /// seconds in the same pass. `visible == false`, and any stretch before
    /// the feed's first event, count toward neither person and also fail
    /// the single-other case — but the 60 % share is still measured against
    /// the line's full length (the orchestrator's call, round 3 item 2): a
    /// line half-hidden by a closed tab is not thereby easier to name from
    /// the half that is left. The single-other case only wins when
    /// `allOtherNames` (every other name the whole feed ever showed on a
    /// visible tile) is exactly that one name: a third person seen anywhere
    /// else in the call — a pinned video, a screen share, a gallery not
    /// fully shown — means the single tile visible for this one line could
    /// still be either of several people, so the line falls through to the
    /// dominant-speaker count instead of guessing. This only ever removes a
    /// name the line would otherwise have gotten; it never adds one.
    ///
    /// `knownFrom` is the feed's first sighting of the call with people on
    /// screen (nil when it never had one). When this line starts before
    /// that point, the stretch from `start` up to `knownFrom` is "not yet
    /// known", not "hidden" like the round-3 rule above: if what remains
    /// after it is at least 2 s and at least 40 % of the line, the 60 %
    /// share and the ×2 margin are measured against that remainder alone,
    /// counting only seconds credited at or after `knownFrom` — so the
    /// share this check reports never exceeds 100 %. Short of either bound,
    /// or with no `knownFrom` at all, the check keeps measuring the full
    /// line as before.
    private static func systemName(
        start: TimeInterval, end: TimeInterval, intervals: [Interval], allOtherNames: Set<String>,
        knownFrom: TimeInterval?
    ) -> String? {
        let total = end - start
        guard total > 0 else { return nil }
        let epsilon = 1e-9

        var seconds: [String: TimeInterval] = [:]
        var secondsFromKnown: [String: TimeInterval] = [:]
        var singleOtherValid = true
        var singleOtherName: String?

        var index = lastIndex(in: intervals, atMost: start)
        var cursor = start
        if index < 0 {
            let firstStart = intervals.first?.start ?? end
            let gapEnd = Swift.min(firstStart, end)
            if gapEnd > cursor {
                singleOtherValid = false
                cursor = gapEnd
            }
            index = 0
        }

        while cursor < end, index < intervals.count {
            let interval = intervals[index]
            let intervalEnd = index + 1 < intervals.count ? intervals[index + 1].start : TimeInterval.infinity
            let segmentEnd = Swift.min(intervalEnd, end)
            guard segmentEnd > cursor else { index += 1; continue }

            if interval.visible, interval.pairConfirmed, interval.people.count == 1, let onlyName = interval.people.first {
                if let existing = singleOtherName {
                    if existing != onlyName { singleOtherValid = false }
                } else {
                    singleOtherName = onlyName
                }
            } else {
                singleOtherValid = false
            }

            if !interval.credited.isEmpty {
                let duration = segmentEnd - cursor
                for name in interval.credited { seconds[name, default: 0] += duration }
                if let knownFrom {
                    let knownStart = Swift.max(cursor, knownFrom)
                    if segmentEnd > knownStart {
                        let knownDuration = segmentEnd - knownStart
                        for name in interval.credited { secondsFromKnown[name, default: 0] += knownDuration }
                    }
                }
            }

            cursor = segmentEnd
            index += 1
        }

        if singleOtherValid, let name = singleOtherName, allOtherNames == Set([name]) { return name }

        let remainder = knownFrom.map { end - Swift.max($0, start) }
        let usesRemainder = knownFrom.map { $0 - start > epsilon } ?? false
            && (remainder ?? 0) >= dominantRemainderMinimum - epsilon
            && (remainder ?? 0) >= dominantRemainderShare * total - epsilon
        let denominator = usesRemainder ? remainder! : total
        let tally = usesRemainder ? secondsFromKnown : seconds

        let ranked = tally.sorted { $0.value > $1.value }
        guard let winner = ranked.first else { return nil }
        let second = ranked.count > 1 ? ranked[1].value : 0
        guard winner.value >= dominantShare * denominator - epsilon, winner.value >= dominantMargin * second - epsilon
        else { return nil }
        return winner.key
    }
}
