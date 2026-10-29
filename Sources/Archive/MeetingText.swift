import CryptoKit
import Foundation

/// A transcript file as the window shows it. The app's own form is a header
/// down to the first `---`, then one paragraph per line,
/// `[m:ss] **label:** text` or `[h:mm:ss] …`. The header is kept whole: it
/// carries the warnings about a cut-short text and missed pieces. Labels are
/// not checked against the interface language: a file written under English
/// says "Me". Anything else, a transcript written by hand included, is shown
/// as it is.
///
/// Exporting it as a file (Markdown, plain text, subtitles) is the window's
/// own concern and stays in `Sources/MeetingRecorder/MeetingLibrary.swift`, as
/// `extension MeetingTranscript`: it needs `UTType`, which the helper cannot
/// build against.
struct MeetingTranscript: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        let timecode: String
        let speaker: String
        let text: String
    }

    /// When each line was said, for the player.
    enum Timing: Sendable, Equatable {
        /// The record of the attempt that wrote the file, which the file
        /// still matches: each line's exact span and track.
        case exact([MeetingAttempt.Line])
        /// The file's own timecodes: each line's start; it lasts until the
        /// next one starts.
        case approximate([TimeInterval])
        /// A text not in the app's form.
        case untimed

        var starts: [TimeInterval] {
            switch self {
            case .exact(let lines): lines.map(\.start)
            case .approximate(let starts): starts
            case .untimed: []
            }
        }

        /// The line being said at `position`: by the record, the latest
        /// started of those it spans, none between lines; by the timecodes,
        /// the latest started.
        func line(at position: TimeInterval) -> Int? {
            switch self {
            case .exact(let lines):
                return lines.indices.filter { lines[$0].start <= position && position < lines[$0].end }
                    .max { (lines[$0].start, $0) < (lines[$1].start, $1) }
            case .approximate(let starts):
                return starts.indices.filter { starts[$0] <= position }.max { (starts[$0], $0) < (starts[$1], $1) }
            case .untimed:
                return nil
            }
        }
    }

    let raw: String
    /// Everything above `---`; nil when the text is not in the app's form.
    let header: String?
    /// Nil when the text is not in the app's form. With the user's names
    /// in place of the labels once `named`.
    private(set) var lines: [Line]?
    var timing = Timing.untimed
    /// The labels the file wrote for each track, from the record it matches.
    private(set) var labels: MeetingAttempt.Speakers?
    /// The user's names that took the place of the labels; empty when none did.
    private(set) var names: [MeetingAttempt.Source: String] = [:]

    /// Speaker labels in the transcript, in the language of the interface;
    /// `MeetingTranscriber.microphoneSpeaker`/`systemSpeaker` return these.
    static var microphoneLabel: String { String(localized: "Me", comment: "Transcript speaker: the microphone track") }
    static var systemLabel: String {
        String(localized: "Others", comment: "Transcript speaker: everyone heard through the system audio")
    }

    /// The record's exact spans, when the file is the one it wrote: the same
    /// size and SHA-256, and one span for every line. Otherwise as parsed.
    func timed(by attempt: MeetingAttempt?) -> MeetingTranscript {
        guard let attempt, let fingerprint = attempt.fingerprint, let lines, !lines.isEmpty,
              attempt.lines.count == lines.count, matches(fingerprint) else { return self }
        var timed = self
        timed.timing = .exact(attempt.lines)
        timed.labels = attempt.speakers
        return timed
    }

    /// The file is the one the record wrote: its size and SHA-256.
    func matches(_ fingerprint: MeetingAttempt.Fingerprint) -> Bool {
        let bytes = Data(raw.utf8)
        return bytes.count == fingerprint.bytes
            && SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == fingerprint.sha256
    }

    /// Each line's label replaced by the user's name for the track the
    /// record says the line came from, never by the label's own text: a file
    /// written under another language, or with one label for both tracks,
    /// is named alike. Only with the record's exact spans, so only the file
    /// it wrote; the raw text, the times and the words stay as they are.
    func named(_ names: [MeetingAttempt.Source: String]) -> MeetingTranscript {
        guard !names.isEmpty, case .exact(let spans) = timing, let lines else { return self }
        var named = self
        named.lines = zip(lines, spans).map { line, span in
            Line(timecode: line.timecode, speaker: names[span.source] ?? line.speaker, text: line.text)
        }
        // The note says who is who for both tracks, the one not named by
        // its label from the file.
        var labels = [MeetingAttempt.Source: String]()
        for (line, span) in zip(lines, spans) where labels[span.source] == nil { labels[span.source] = line.speaker }
        if let written = self.labels {
            labels[.microphone] = labels[.microphone] ?? written.microphone
            labels[.system] = labels[.system] ?? written.system
        }
        named.names = names
        named.speakerNames = MeetingAttempt.Speakers(
            microphone: names[.microphone] ?? labels[.microphone] ?? MeetingTranscript.microphoneLabel,
            system: names[.system] ?? labels[.system] ?? MeetingTranscript.systemLabel
        )
        return named
    }

    /// Who speaks on each track once named, for the note after the header.
    private var speakerNames: MeetingAttempt.Speakers?

    /// After the header, untouched, when the user's names took the place of
    /// the labels: the header's own note is about the labels, which are gone.
    var namesNote: String? {
        speakerNames.map {
            String(localized: "Names: “\($0.microphone)” is the microphone, “\($0.system)” is the system audio.")
        }
    }

    /// The text as the window shows it and "Copy Text" copies it: the
    /// header's first `# ` line as a title, the rest of it as notes, then
    /// each line's time, label and words; a text not in the app's form as
    /// it is. With where each part is, for links, highlights and search.
    struct Layout: Sendable, Equatable {
        struct Line: Sendable, Equatable {
            let timecode: NSRange
            let speaker: NSRange
            let body: NSRange
            var whole: NSRange { NSRange(location: timecode.location, length: NSMaxRange(body) - timecode.location) }
        }

        let string: String
        let title: NSRange?
        let notes: NSRange?
        let lines: [Line]
        /// What a search looks through: the lines' own words, never their
        /// time, label or the header; a text not in the app's form whole.
        let searchable: [NSRange]

        /// What a new dictionary entry is made from a selection in this
        /// text: the words of the line it begins in, without time or label,
        /// to select in and try the entry on, or the paragraph it begins in
        /// (the header, a text not in the app's form); and everything
        /// selected, as it was, never cut down to that line: nil when
        /// several stretches are. Nil for nothing, or only spaces, selected.
        func dictionarySource(for ranges: [NSRange]) -> (text: String, selected: String?)? {
            let shown = string as NSString
            let stretches = ranges.filter { $0.length > 0 && NSMaxRange($0) <= shown.length }
            guard let first = stretches.min(by: { $0.location < $1.location }) else { return nil }
            let selected = stretches.count == 1 ? shown.substring(with: first) : nil
            if let selected, selected.allSatisfy(\.isWhitespace) { return nil }
            let text: String
            if let line = lines.first(where: { NSLocationInRange(first.location, $0.whole) }) {
                text = shown.substring(with: line.body)
            } else {
                text = shown.substring(with: shown.paragraphRange(for: NSRange(location: first.location, length: 0)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (text, selected)
        }
    }

    var layout: Layout {
        guard let lines else {
            return Layout(string: raw, title: nil, notes: nil, lines: [], searchable: [NSRange(location: 0, length: (raw as NSString).length)])
        }
        var string = ""
        func append(_ part: String) -> NSRange {
            let start = (string as NSString).length
            string += part
            return NSRange(location: start, length: (part as NSString).length)
        }
        var header = (header ?? "").components(separatedBy: "\n")
        var title: NSRange?
        if let first = header.first, first.hasPrefix("# ") {
            header.removeFirst()
            title = append(String(first.dropFirst(2)))
            _ = append("\n")
        }
        var notes: NSRange?
        let noted = ([header.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)] + [namesNote].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if !noted.isEmpty {
            notes = append(noted)
            _ = append("\n")
        }
        if !string.isEmpty { _ = append("\n") }
        var laid: [Layout.Line] = []
        for line in lines {
            let timecode = append("[\(line.timecode)]")
            _ = append("  ")
            let speaker = append(line.speaker + ":")
            _ = append(" ")
            let body = append(line.text)
            _ = append("\n\n")
            laid.append(Layout.Line(timecode: timecode, speaker: speaker, body: body))
        }
        return Layout(string: string, title: title, notes: notes, lines: laid, searchable: laid.map(\.body))
    }

    /// `m:ss` or `h:mm:ss`.
    static func seconds(_ timecode: String) -> TimeInterval {
        timecode.split(separator: ":").reduce(0) { $0 * 60 + (TimeInterval($1) ?? 0) }
    }

    static func parse(_ raw: String) -> MeetingTranscript {
        let rows = raw.components(separatedBy: "\n")
        guard let rule = rows.firstIndex(of: "---") else { return MeetingTranscript(raw: raw, header: nil, lines: nil) }
        var lines: [Line] = []
        for row in rows[(rule + 1)...] where !row.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let match = row.wholeMatch(of: /\[((?:\d+:)?\d{1,2}:\d{2})\] \*\*(.+?):\*\* (.*)/) else {
                return MeetingTranscript(raw: raw, header: nil, lines: nil)
            }
            lines.append(Line(timecode: String(match.1), speaker: String(match.2), text: String(match.3)))
        }
        let header = rows[..<rule].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingTranscript(raw: raw, header: header, lines: lines, timing: .approximate(lines.map { seconds($0.timecode) }))
    }
}

/// The one rule for a match, for the list's count and the card's
/// highlights alike: case and the Russian yo/ye never tell words apart (as
/// in the personal dictionary); other marks do ("й" is not "и").
enum MeetingSearch {
    /// `folded`: `fold` of the text searched, made once per text.
    static func ranges(of query: String, inFolded folded: NSString, within areas: [NSRange]) -> [NSRange] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        var found: [NSRange] = []
        for area in areas {
            var rest = area
            while rest.length > 0 {
                let match = folded.range(of: needle, options: .caseInsensitive, range: rest)
                guard match.location != NSNotFound else { break }
                found.append(match)
                let next = NSMaxRange(match)
                rest = NSRange(location: next, length: NSMaxRange(area) - next)
            }
        }
        return found
    }

    static func ranges(of query: String, in layout: MeetingTranscript.Layout) -> [NSRange] {
        ranges(of: query, inFolded: fold(layout.string) as NSString, within: layout.searchable)
    }

    static func matches(_ query: String, _ text: String) -> Bool {
        let folded = fold(text) as NSString
        return !ranges(of: query, inFolded: folded, within: [NSRange(location: 0, length: folded.length)]).isEmpty
    }

    /// The window's own rule for a meeting's search: whether `query` is found
    /// in the lines' own words of this transcript (never its time, label or
    /// header). A separate overload from `matches(_:_:)` above, which the
    /// window uses for the shown meeting title; both share `ranges`.
    static func matches(_ query: String, in layout: MeetingTranscript.Layout) -> Bool {
        !ranges(of: query, in: layout).isEmpty
    }

    /// Of the same length in UTF-16, so a range in it is one in the text.
    /// Only the precomposed letters change, compared literally: a plain
    /// replacement compares with canonical equivalence and also took a yo
    /// written as ye and a combining diaeresis (two units, from pasted text)
    /// for one, so the text came out shorter and a search past its end
    /// stopped the app. Such a yo is found only by a query spelled the same
    /// way, never by "е" or "ё".
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0451}", with: "\u{0435}", options: .literal)
            .replacingOccurrences(of: "\u{0401}", with: "\u{0415}", options: .literal)
    }
}
