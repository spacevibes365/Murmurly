import Combine
import Foundation

/// What is selected in one line of the feed's own `NSTextView`
/// (`LiveLineTextView`), written by the line's delegate as the selection
/// changes, so a click on ★ never loses it: `range` is in `displayText`'s
/// own coordinates (the speaker's name is never part of it), `text` is the
/// selected words, trimmed of leading and trailing spaces and line breaks.
struct NotepadLineSelection: Equatable, Sendable {
    var lineID: UUID
    var start: Double
    var range: NSRange
    var text: String
}

/// Which meeting the notepad is open on, if any; nil while idle.
struct NotepadMeeting: Equatable, Sendable {
    var identity: FolderIdentity?
    var folder: URL
    var startedAt: Date?
    var isRecording: Bool
}

/// One item of the notepad's feed: a line of the live transcript, or a note
/// the user typed. `NotepadFeedItem.merge` is the one place that interleaves
/// them by time.
enum NotepadFeedItem: Identifiable, Equatable, Sendable {
    case line(LiveLine)
    case note(MeetingNote)

    enum ID: Hashable, Sendable {
        case line(UUID)
        case note(UUID)
    }

    var id: ID {
        switch self {
        case .line(let line): .line(line.id)
        case .note(let note): .note(note.id)
        }
    }

    /// Keeps the lines in the model's own order (an interim line always
    /// after every final one, even when its `start` is earlier — a full sort
    /// by time would change today's panel) and slots notes in between lines
    /// by time: before the first line whose `start` is greater than the
    /// note's `t` (a tie goes to the line); notes without `t` come last, in
    /// their given order. With no notes this is exactly `lines`. `anchored`
    /// names moments drawn on their own line (`momentLines`), so they never
    /// also appear as a feed item of their own.
    static func merge(lines: [LiveLine], notes: [MeetingNote], anchored: Set<UUID> = []) -> [NotepadFeedItem] {
        let notes = anchored.isEmpty ? notes : notes.filter { !anchored.contains($0.id) }
        guard !notes.isEmpty else { return lines.map(NotepadFeedItem.line) }
        let timedNotes = notes.filter { $0.t != nil }.sorted { $0.t! < $1.t! }
        let untimedNotes = notes.filter { $0.t == nil }

        var result: [NotepadFeedItem] = []
        var noteIndex = 0
        for line in lines {
            while noteIndex < timedNotes.count, timedNotes[noteIndex].t! < line.start {
                result.append(.note(timedNotes[noteIndex]))
                noteIndex += 1
            }
            result.append(.line(line))
        }
        while noteIndex < timedNotes.count {
            result.append(.note(timedNotes[noteIndex]))
            noteIndex += 1
        }
        result.append(contentsOf: untimedNotes.map(NotepadFeedItem.note))
        return result
    }

    /// Resolves every moment with words (`kind == .moment`, non-empty text)
    /// to the line it is drawn on, id of note → id of line: `anchors` (made
    /// as the moment was created, in memory, `NotepadModel.momentLineIDs`)
    /// first, else a line whose `start` equals the moment's `t` — preferring
    /// one whose own words contain the moment's (`MeetingSearch`'s rule),
    /// else the first such line. A moment with no match (its line is gone)
    /// is left out, so it falls back to its own row in the feed.
    static func momentLines(lines: @autoclosure () -> [LiveLine], notes: [MeetingNote], anchors: [UUID: UUID]) -> [UUID: UUID] {
        guard notes.contains(where: { $0.kind == .moment && !$0.text.isEmpty }) else { return [:] }
        let lines = lines()
        var result: [UUID: UUID] = [:]
        let byID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for note in notes {
            guard note.kind == .moment, !note.text.isEmpty else { continue }
            if let anchoredID = anchors[note.id], byID[anchoredID] != nil {
                result[note.id] = anchoredID
                continue
            }
            let candidates = lines.filter { $0.start == note.t }
            guard !candidates.isEmpty else { continue }
            let preferred = candidates.first { MeetingSearch.matches(note.text, $0.displayText) }
            result[note.id] = (preferred ?? candidates[0]).id
        }
        return result
    }
}

/// The notepad's own state, one instance per `LiveTranscriptPanel`: set by
/// the panel and read by the view slots (`@ObservedObject`). The methods
/// that act on it live in extensions beside the views that call them, each
/// in its own file.
@MainActor
final class NotepadModel: ObservableObject {
    @Published var meeting: NotepadMeeting?
    /// The recording's own live-transcript model, handed over by the panel
    /// (`LiveTranscriptPanel.render`); nil before a recording with the
    /// setting on, and left as it is once the recording stops.
    @Published var liveModel: LiveTranscriptModel? {
        didSet {
            guard oldValue !== liveModel else { return }
            liveSubscription = liveModel?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    /// The live transcript's lines as they stood when the recording stopped,
    /// so the notepad still shows them with the recording's model gone.
    @Published var keptLines: [LiveLine] = []
    @Published var notes: [MeetingNote] = []
    /// What is selected in one line of the feed, if any — written by that
    /// line's own `NSTextView` as the selection changes, read by ★. Set to
    /// nil whenever another line gains a selection, the meeting changes, or
    /// a moment is made from it.
    @Published var lineSelection: NotepadLineSelection?
    /// A moment's id → the line it is drawn on, for a moment made from a
    /// selected line while the notepad showed the recording it belongs to.
    /// In memory only, cleared by `resetForMeeting()`.
    @Published var momentLineIDs: [UUID: UUID] = [:]
    @Published var pendingNoteIDs: Set<UUID> = []
    @Published var noteFailures: [UUID: String] = [:]
    @Published var searchQuery = ""
    @Published var matchLineIDs: [UUID] = []
    @Published var currentMatch: Int?
    @Published var highlightedLineID: UUID?
    @Published var isPinned = false
    @Published var isFollowingBottom = true
    /// Bumped by `resetForMeeting()`, for a genuinely new meeting only: the
    /// note field's own `NoteDraftController` drops its draft on a change,
    /// so a note started on the meeting just left is never delivered to the
    /// one that replaces it.
    @Published var meetingGeneration = 0
    /// Activates Murmurly and makes the panel key, for a focus move a click
    /// did not make: "Edit Note" from the context menu, where a secondary
    /// click does not activate the app. Set by
    /// `LiveTranscriptPanel.buildWindowIfNeeded`; a plain closure, not
    /// published, since no view needs to redraw on it.
    var requestKeyboard: () -> Void = {}

    /// The one place the feed and the search resolve which moments are drawn
    /// on their own line, so both always agree: `searchLines` is
    /// `NotepadSearchBar.swift`'s own (the recording's model while it
    /// exists, else `keptLines`).
    var resolvedMomentLines: [UUID: UUID] {
        NotepadFeedItem.momentLines(lines: searchLines, notes: notes, anchors: momentLineIDs)
    }

    /// Forwards the live model's own changes (new lines, a new state) to
    /// this model's observers: a slot observing `notepad` alone would not
    /// otherwise redraw when `liveModel.lines` changes, since SwiftUI only
    /// sees the `liveModel` reference change, not what is inside it. The
    /// same `sink { [weak self] … }` shape as `LiveTranscriptPanel.observe`.
    private var liveSubscription: AnyCancellable?
}
