import AppKit
import SwiftUI

/// The notepad's feed: the live transcript's lines merged with the user's
/// notes (`NotepadFeedItem.merge`), oldest first, newest at the bottom.
/// `isFollowingBottom` decides whether a new line scrolls the feed down: on
/// while the user has not scrolled away, off the moment they do. Whether a
/// change of scroll position counts as "scrolled away" is read from the
/// geometry, through `ScrollFollowReducer.reduce`, below — a single pure
/// function so it can be tested without a live scroll view.
///
/// A plain "are we scrolling programmatically" flag cannot tell the frame
/// that *lands* a scroll this view started from a frame that merely looks
/// the same (offset moving, content size unchanged): both happen while the
/// flag is set, and both happen after it is cleared, depending only on when
/// the animation's last frame arrives relative to the flag's own clearing.
/// Instead, every scroll this view starts opens a *generation*
/// (`ScrollFollowGeneration`): a target intention and a start time. While a
/// generation is open, the geometry handler reports its intention, not
/// `atBottom` — it closes itself, from inside the reducer, once two
/// consecutive frames show the offset no longer moving (the scroll has
/// settled) or 0.5 s have passed, whichever comes first; a real gesture
/// (`ScrollPhase.interacting` / `.tracking`, when it is reported at all)
/// closes it immediately, since that is the user taking the scroll over.
/// Once no generation is open, an offset change fully explained by a change
/// of the content's or the container's own size (new lines arriving, the
/// search bar opening or closing, the window being resized) is not a
/// gesture either and leaves the flag as it was; anything else is a real
/// scroll, and only then does "sitting at the bottom" decide the flag.
struct LiveLinesView: View {
    @ObservedObject var notepad: NotepadModel

    /// How close to the very bottom still counts as "at the bottom", and how
    /// small a frame's own offset change must be to count as "settled" or
    /// "explained by a resize".
    static let tolerance: CGFloat = 24
    private static let bottomAnchorID = "notepadFeedBottomAnchor"

    @State private var hasPerformedInitialScroll = false
    @State private var scrollPhase: ScrollPhase = .idle
    /// The scroll this view itself started, if one is still settling; read
    /// and replaced wholesale by `ScrollFollowReducer.reduce` on every
    /// geometry frame, and opened fresh by `performProgrammaticScroll`.
    @State private var generation: ScrollFollowGeneration?
    /// The value this view itself last wrote to `notepad.isFollowingBottom`,
    /// kept only until the matching `onChange` fires, so that handler can
    /// tell its own write apart from one made elsewhere (the search bar
    /// turning following off without asking this view to scroll anywhere).
    @State private var pendingSelfWrite: Bool?

    var body: some View {
        let content = Self.content(for: notepad)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if notepad.liveModel?.hasEarlierLines == true {
                            Text("Earlier lines are in the transcript after the meeting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("notepadEarlierLinesMarker")
                        }
                        ForEach(content.feed) { item in
                            row(for: item, moments: content.moments)
                                .id(item.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.vertical, 2)
                }
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("notepadFeedScrollView")
                .onScrollPhaseChange { _, newPhase in
                    scrollPhase = newPhase
                }
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { oldValue, newValue in
                    // `defaultScrollAnchor(.bottom)` is only a hint, and a
                    // `LazyVStack`'s content size is not known until its
                    // first real layout pass, so it does not reliably land
                    // the feed at the bottom on first appearance; this
                    // corrects it once, on the first real (non-zero)
                    // content size the scroll view ever reports.
                    if !hasPerformedInitialScroll, newValue.contentSize.height > 0 {
                        hasPerformedInitialScroll = true
                        if notepad.isFollowingBottom {
                            performProgrammaticScroll(
                                to: Self.bottomAnchorID, anchor: .bottom, animated: false,
                                intendedFollowing: true, proxy: proxy
                            )
                        }
                    }

                    let result = ScrollFollowReducer.reduce(
                        wasFollowing: notepad.isFollowingBottom,
                        generation: generation,
                        now: .now,
                        offsetDelta: newValue.contentOffset.y - oldValue.contentOffset.y,
                        contentDelta: newValue.contentSize.height - oldValue.contentSize.height,
                        containerDelta: newValue.containerSize.height - oldValue.containerSize.height,
                        newOffset: newValue.contentOffset.y,
                        newContentHeight: newValue.contentSize.height,
                        newContainerHeight: newValue.containerSize.height,
                        bottomInset: newValue.contentInsets.bottom,
                        isGesturePhase: scrollPhase == .interacting || scrollPhase == .tracking,
                        tolerance: Self.tolerance
                    )
                    generation = result.generation
                    if result.isFollowingBottom != notepad.isFollowingBottom {
                        setFollowing(result.isFollowingBottom)
                    }
                }
                .onChange(of: content.feed.count) { _, _ in
                    guard notepad.isFollowingBottom else { return }
                    performProgrammaticScroll(
                        to: Self.bottomAnchorID, anchor: .bottom, animated: false,
                        intendedFollowing: true, proxy: proxy
                    )
                }
                .onChange(of: notepad.highlightedLineID) { _, newValue in
                    guard let id = feedItemID(matching: newValue) else { return }
                    setFollowing(false)
                    performProgrammaticScroll(to: id, anchor: .center, animated: true, intendedFollowing: false, proxy: proxy)
                }
                .onChange(of: notepad.meeting) { _, _ in
                    hasPerformedInitialScroll = false
                    generation = nil
                }
                .onChange(of: notepad.isFollowingBottom) { _, newValue in
                    // A write this view just made itself is expected here;
                    // consume it and do nothing. Anything else is the search
                    // bar (or another owner) turning following off without
                    // asking this view to scroll anywhere — open a
                    // generation of our own so the very next frame, likely
                    // reporting no real movement at all, does not read that
                    // as "sitting at the bottom" and turn it straight back on.
                    if pendingSelfWrite == newValue {
                        pendingSelfWrite = nil
                        return
                    }
                    if newValue == false {
                        generation = ScrollFollowGeneration(intendedFollowing: false, startTime: .now)
                    }
                }

                if !notepad.isFollowingBottom {
                    Button {
                        setFollowing(true)
                        performProgrammaticScroll(to: Self.bottomAnchorID, anchor: .bottom, animated: true, intendedFollowing: true, proxy: proxy)
                    } label: {
                        Text("Jump to bottom")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("notepadJumpToBottomButton")
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .clipped()
    }

    /// The one place `notepad.isFollowingBottom` is written from this view,
    /// so `onChange(of: notepad.isFollowingBottom)` can tell its own writes
    /// apart from ones made elsewhere.
    private func setFollowing(_ value: Bool) {
        pendingSelfWrite = value
        notepad.isFollowingBottom = value
    }

    /// Every scroll this view starts on its own goes through here: it opens
    /// a generation stating what it intends `isFollowingBottom` to read
    /// while the scroll is still under way, then performs the scroll.
    /// `ScrollFollowReducer` closes the generation itself, from the
    /// geometry frames that follow — there is nothing to wait for here.
    private func performProgrammaticScroll<ID: Hashable>(
        to id: ID, anchor: UnitPoint, animated: Bool, intendedFollowing: Bool, proxy: ScrollViewProxy
    ) {
        generation = ScrollFollowGeneration(intendedFollowing: intendedFollowing, startTime: .now)
        if animated {
            withAnimation(.default) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    /// `highlightedLineID` names either a line or a note by the same raw
    /// `UUID`; this looks the id up in the feed actually on screen to build
    /// the right `NotepadFeedItem.ID` for `scrollTo`.
    private func feedItemID(matching highlighted: UUID?) -> NotepadFeedItem.ID? {
        Self.feedItemID(in: Self.feed(for: notepad), matching: highlighted)
    }

    @ViewBuilder
    private func row(for item: NotepadFeedItem, moments: [UUID: [MeetingNote]]) -> some View {
        switch item {
        case .line(let line):
            LiveLineRow(
                line: line, notepad: notepad, isHighlighted: notepad.highlightedLineID == line.id,
                moments: moments[line.id] ?? []
            )
        case .note(let note):
            NoteRow(note: note, notepad: notepad)
        }
    }
}

/// A scroll `LiveLinesView` started itself, open until
/// `ScrollFollowReducer.reduce` decides it has settled (or it is interrupted
/// by a real gesture, or 0.5 s pass without settling).
struct ScrollFollowGeneration: Equatable {
    var intendedFollowing: Bool
    var startTime: Date
    /// Consecutive frames in a row whose own offset barely moved; two in a
    /// row mean the scroll this generation covers has landed.
    var stableFrames: Int = 0
}

/// The one rule for whether the feed keeps following the bottom, and for
/// when a programmatic scroll's generation is still open, read by the
/// geometry handler on every frame. See `LiveLinesView`'s own doc comment
/// for the reasoning; this type carries no view state so it can be tested on
/// its own.
enum ScrollFollowReducer {
    /// Consecutive near-zero-movement frames that count as "the scroll has
    /// settled" while a generation is open.
    static let settleStableFrames = 2
    /// A generation younger than this never settles early, whatever its
    /// frames look like: an eased animation's very first frames can move as
    /// little as a landed one does, and closing on that would hand the next,
    /// still mid-flight frame to the no-generation path as if it were a
    /// fresh gesture.
    static let minimumSettleAge: TimeInterval = 0.2
    /// How long a generation stays open without settling before the next
    /// frame is judged on its own, as if no generation had been open at all.
    static let generationTimeout: TimeInterval = 0.5

    struct Result {
        var isFollowingBottom: Bool
        var generation: ScrollFollowGeneration?
    }

    static func reduce(
        wasFollowing: Bool,
        generation: ScrollFollowGeneration?,
        now: Date,
        offsetDelta: CGFloat,
        contentDelta: CGFloat,
        containerDelta: CGFloat,
        newOffset: CGFloat,
        newContentHeight: CGFloat,
        newContainerHeight: CGFloat,
        bottomInset: CGFloat,
        isGesturePhase: Bool,
        tolerance: CGFloat
    ) -> Result {
        if let generation, now.timeIntervalSince(generation.startTime) < generationTimeout, !isGesturePhase {
            var updated = generation
            let age = now.timeIntervalSince(generation.startTime)
            if age >= minimumSettleAge, abs(offsetDelta) <= tolerance {
                updated.stableFrames += 1
            } else {
                updated.stableFrames = 0
            }
            if updated.stableFrames < settleStableFrames {
                return Result(isFollowingBottom: updated.intendedFollowing, generation: updated)
            }
            return Result(isFollowingBottom: updated.intendedFollowing, generation: nil)
        }

        // No generation is open — none ever was, a real gesture just took
        // the scroll over from one that was, or one timed out without
        // settling: either way this frame is judged fresh, on its own.
        if !isGesturePhase {
            let passiveDelta = contentDelta - containerDelta
            if abs(offsetDelta) <= tolerance || abs(offsetDelta - passiveDelta) <= tolerance {
                return Result(isFollowingBottom: wasFollowing, generation: nil)
            }
        }

        let atBottom = newOffset >= newContentHeight - newContainerHeight + bottomInset - tolerance
        return Result(isFollowingBottom: atBottom, generation: nil)
    }
}

extension LiveLinesView {
    /// The lines the feed and "Copy" both read: the recording's own live
    /// model while it exists, the snapshot kept from it once the recording
    /// (and the model) is gone — the model is what carries
    /// `hasEarlierLines`, so that marker is lost along with it, by design.
    static func lines(for notepad: NotepadModel) -> [LiveLine] {
        notepad.liveModel?.lines ?? notepad.keptLines
    }

    /// `feed(for:)` and `moments(for:)` below are thin wrappers over this:
    /// both need `resolvedMomentLines`, and computing it only once per call
    /// means a body that reads both (every call) never resolves it twice.
    static func content(for notepad: NotepadModel) -> (feed: [NotepadFeedItem], moments: [UUID: [MeetingNote]]) {
        let resolved = notepad.resolvedMomentLines
        let feed = NotepadFeedItem.merge(lines: lines(for: notepad), notes: notepad.notes, anchored: Set(resolved.keys))
        guard !resolved.isEmpty else { return (feed, [:]) }
        var moments: [UUID: [MeetingNote]] = [:]
        for note in notepad.notes {
            guard let lineID = resolved[note.id] else { continue }
            moments[lineID, default: []].append(note)
        }
        return (feed, moments)
    }

    /// A moment drawn on its own line (`NotepadModel.resolvedMomentLines`)
    /// is left out of the feed as a separate item.
    static func feed(for notepad: NotepadModel) -> [NotepadFeedItem] {
        content(for: notepad).feed
    }

    /// Every moment with words, grouped by the line it is drawn on, in
    /// `notepad.notes`' own order — read by `LiveLineRow` to show its ★s.
    static func moments(for notepad: NotepadModel) -> [UUID: [MeetingNote]] {
        content(for: notepad).moments
    }

    /// `highlighted` names either a line or a note by the same raw `UUID`;
    /// this looks it up in `feed` to build the right `NotepadFeedItem.ID`.
    static func feedItemID(in feed: [NotepadFeedItem], matching highlighted: UUID?) -> NotepadFeedItem.ID? {
        guard let highlighted else { return nil }
        if feed.contains(where: { $0.id == .line(highlighted) }) { return .line(highlighted) }
        if feed.contains(where: { $0.id == .note(highlighted) }) { return .note(highlighted) }
        return nil
    }
}

/// One line of the live transcript: its recording time (a separate, clickable
/// element — never combined into the text's own accessibility element, or a
/// UI test finding `liveTranscriptLine` would find a button instead of a
/// static text), the speaker and the text itself, selectable, and one ★ per
/// moment drawn on this line (`LiveLinesView.moments(for:)`).
struct LiveLineRow: View {
    let line: LiveLine
    @ObservedObject var notepad: NotepadModel
    let isHighlighted: Bool
    let moments: [MeetingNote]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            NotepadTimeButton(seconds: line.start, notepad: notepad)
            ForEach(moments) { moment in
                LineMomentStar(note: moment, notepad: notepad)
            }
            LiveLineText(
                line: line, speaker: speaker, moments: moments,
                selection: notepad.lineSelection?.lineID == line.id ? notepad.lineSelection : nil,
                notepad: notepad
            )
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.firstTextBaseline) { _ in Self.baselineOffset }
            ForEach(moments) { moment in
                if notepad.pendingNoteIDs.contains(moment.id) {
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notepadNoteSaving")
                }
                if let reason = notepad.noteFailures[moment.id] {
                    Text(String(format: String(localized: "Not saved: %@"), reason))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("notepadNoteFailure")
                }
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, isHighlighted ? 4 : 0)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var speaker: String {
        line.name ?? (line.track == .microphone
            ? MeetingTranscript.microphoneLabel
            : MeetingTranscript.systemLabel)
    }

    /// A static value from the line's own font: `LiveLineText` draws with
    /// `NSFont.systemFont(ofSize: NSFont.systemFontSize)`, so this lines its
    /// first baseline up with the time button and the ★s beside it.
    /// `alignmentGuide`'s closure is `@Sendable`; `nonisolated` lets it read
    /// this plain, already-`Sendable` constant without hopping actors.
    nonisolated private static let baselineOffset: CGFloat = {
        NSLayoutManager().defaultBaselineOffset(for: NSFont.systemFont(ofSize: NSFont.systemFontSize))
    }()
}

/// ★ drawn on a line of the feed, for a moment made from a selection in it:
/// the first match of its words (`MeetingSearch`'s rule) is highlighted in
/// the line itself (`LiveLineText.attributedString`), so this star carries no
/// text of its own beyond its accessibility label — the moment's words, read
/// verbatim, never translated. "Remove Mark" is the only way to undo it; the
/// star itself is read-only.
private struct LineMomentStar: View {
    let note: MeetingNote
    @ObservedObject var notepad: NotepadModel

    private var isPending: Bool { notepad.pendingNoteIDs.contains(note.id) }

    var body: some View {
        Image(systemName: "star.fill")
            .foregroundStyle(.yellow)
            .accessibilityIdentifier("notepadLineMomentStar")
            .accessibilityLabel(Text(verbatim: note.text))
            .contextMenu {
                Button("Remove Mark", role: .destructive) {
                    notepad.requestDelete(id: note.id)
                }
                .disabled(isPending)
            }
    }
}

/// A read-only, selectable `NSTextView` for one line of the feed: accepts the
/// very first click even while the panel sits behind another app's window
/// (`acceptsFirstMouse`), so selecting words also brings the notepad and
/// Murmurly forward, as any click on the panel does.
final class LiveLineTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Set from just before `super.mouseDown` is called until it returns on
    /// the mouse-up: `NSTextView`'s own tracking loop sends no
    /// selection-changed notification while the mouse drags, so the model
    /// does not yet name this line as selected, and a live update arriving
    /// mid-drag would otherwise clear or replace the text being dragged over.
    private(set) var isSelectingWithMouse = false
    /// Called right after `isSelectingWithMouse` goes back to false, once
    /// tracking actually ends — the coordinator applies whatever update it
    /// deferred.
    var mouseSelectionEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isSelectingWithMouse = true
        super.mouseDown(with: event) // returns only once the mouse-up ends tracking
        isSelectingWithMouse = false
        mouseSelectionEnded?()
    }

    #if DEBUG
    func beginMouseSelectionForTesting() { isSelectingWithMouse = true }
    func endMouseSelectionForTesting() {
        isSelectingWithMouse = false
        mouseSelectionEnded?()
    }
    #endif
}

/// One line's text: an `NSTextView` (TextKit 1, so `usedRect` is predictable
/// — see `sizeThatFits`), not a SwiftUI `Text`, because only an `NSTextView`
/// reports a reliable `selectedRange` and a selection-changed callback (see
/// `NotepadModel.lineSelection`'s own doc comment). `isRichText` so the
/// speaker's name can be drawn bold and a moment's words highlighted by the
/// view itself, not only in a detached `NSAttributedString` a test can read.
/// Reported to accessibility as the static text `liveTranscriptLine`, same
/// value as the old SwiftUI `Text` carried.
struct LiveLineText: NSViewRepresentable {
    let line: LiveLine
    let speaker: String
    let moments: [MeetingNote]
    /// `notepad.lineSelection` only when it names this very line, else nil —
    /// read by the coordinator as a value, so a selection change elsewhere
    /// (which this view does not carry) never looks like a change here.
    let selection: NotepadLineSelection?
    /// Written to (the user's own selection, read back for the mouse-drag
    /// deferral below) — never observed: `LiveLineRow` already observes it
    /// and rebuilds this value on every change that matters.
    let notepad: NotepadModel

    func makeNSView(context: Context) -> LiveLineTextView {
        Self.makeTextView(coordinator: context.coordinator)
    }

    @MainActor
    static func makeTextView(coordinator: Coordinator) -> LiveLineTextView {
        let view = LiveLineTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = coordinator
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityIdentifier("liveTranscriptLine")
        view.mouseSelectionEnded = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.mouseSelectionEnded(in: view)
        }
        return view
    }

    func updateNSView(_ nsView: LiveLineTextView, context: Context) {
        context.coordinator.update(from: self, in: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LiveLineTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        guard let container = nsView.textContainer, let layoutManager = nsView.layoutManager else {
            return CGSize(width: width, height: 0)
        }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Builds the speaker (bold) and the line's own text, with a moment's
    /// words highlighted: the first range of `moment.text` found in `text`
    /// by `MeetingSearch`'s own rule (case and ё/е folded), shifted past the
    /// speaker and the space after it. A moment whose words are no longer in
    /// the (changed) text is skipped — the ★ stays, drawn with no highlight.
    static func attributedString(speaker: String, text: String, isFinal: Bool, moments: [MeetingNote]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let color: NSColor = isFinal ? .labelColor : .secondaryLabelColor
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: speaker, attributes: [.font: boldFont, .foregroundColor: color]))
        result.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: color]))

        let prefixLength = speakerPrefixLength(for: speaker)
        let folded = MeetingSearch.fold(text) as NSString
        let whole = NSRange(location: 0, length: folded.length)
        for moment in moments where !moment.text.isEmpty {
            guard let first = MeetingSearch.ranges(of: moment.text, inFolded: folded, within: [whole]).first else { continue }
            let shifted = NSRange(location: first.location + prefixLength, length: first.length)
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: shifted)
        }
        return result
    }

    /// How many UTF-16 units of the view's full string come before
    /// `displayText` itself: the speaker's name plus the one space after it.
    static func speakerPrefixLength(for speaker: String) -> Int {
        (speaker as NSString).length + 1
    }

    /// `range` is a selection in the view's full string (speaker included);
    /// this clamps it to the part that is `displayText`'s own and returns
    /// that clamped range together with the selected words, trimmed of
    /// leading and trailing spaces and line breaks. A selection that never
    /// reaches past the speaker's name clamps to an empty range with empty
    /// text — the line is still "selected" (`markMoment` then takes its text
    /// whole), just with nothing of its own highlighted.
    static func selectedText(range: NSRange, in displayText: String, speakerLength: Int) -> (range: NSRange, text: String) {
        let ns = displayText as NSString
        let start = min(max(0, range.location - speakerLength), ns.length)
        let end = min(max(start, NSMaxRange(range) - speakerLength), ns.length)
        let clamped = NSRange(location: start, length: end - start)
        let text = ns.substring(with: clamped).trimmingCharacters(in: .whitespacesAndNewlines)
        return (clamped, text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Everything a value-equality check needs to decide "nothing to
        /// redraw". `lineID`/`start`/`speakerLength` are the line's own
        /// identity and are compared too, so a row reused for another line
        /// is redrawn; they are written whenever an update is applied (one
        /// deferred during a mouse drag at the mouse-up), so `textViewDidChangeSelection`
        /// always has the current line's own `start` to put a moment on.
        private struct Content: Equatable {
            var lineID: UUID
            var start: Double
            var speakerLength: Int
            var speaker: String
            var displayText: String
            var isFinal: Bool
            var moments: [MeetingNote]
            var selection: NotepadLineSelection?
        }

        private weak var notepad: NotepadModel?
        /// Read back in `textViewDidChangeSelection`, instead of
        /// `notification.object`: `Notification` is not `Sendable`, and
        /// capturing it inside `MainActor.assumeIsolated`'s closure — itself
        /// a cross-isolation boundary to the type checker, even though it
        /// never actually hops threads — once this `nonisolated` delegate
        /// method is called from AppKit's own (already-main-actor) thread.
        private weak var view: LiveLineTextView?
        /// The last values actually applied to the view — nil before the
        /// first `apply`, so the very first update always draws.
        private var applied: Content?
        /// Set while `view.isSelectingWithMouse`: the update that arrived
        /// mid-drag, to be applied once the drag ends
        /// (`mouseSelectionEnded`) instead of disturbing the view's own,
        /// in-progress selection and text.
        private var deferred: Content?
        /// Guards every programmatic change this coordinator itself makes
        /// (setting the text, restoring or clearing a selection) so the
        /// delegate callback they trigger never mistakes it for the user's
        /// own selection and publishes over `notepad.lineSelection`.
        private var isApplyingUpdate = false

        #if DEBUG
        private(set) var textRebuildCountForTesting = 0
        private(set) var selectionApplyCountForTesting = 0
        #endif

        func update(from text: LiveLineText, in view: LiveLineTextView) {
            notepad = text.notepad
            self.view = view

            // The width SwiftUI actually laid this view out at — `bounds`,
            // not only the proposal `sizeThatFits` saw — or a later resize
            // of the row leaves the container's wrapping stuck at a stale
            // width and the line clips.
            let width = view.bounds.width
            if width > 0, view.textContainer?.containerSize.width != width {
                view.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            }

            let content = Content(
                lineID: text.line.id, start: text.line.start,
                speakerLength: LiveLineText.speakerPrefixLength(for: text.speaker),
                speaker: text.speaker, displayText: text.line.displayText, isFinal: text.line.isFinal,
                moments: text.moments, selection: text.selection
            )

            if view.isSelectingWithMouse {
                deferred = content
                return
            }
            apply(content, in: view)
        }

        /// Called once `LiveLineTextView`'s own tracking loop returns on the
        /// mouse-up. The selection is read fresh from `notepad.lineSelection`
        /// rather than taken from whatever was deferred: by now the view's
        /// own delegate callback has already told the model what the drag
        /// selected, and a deferred value (made before the drag started,
        /// usually no selection at all) would instantly overwrite it.
        func mouseSelectionEnded(in view: LiveLineTextView) {
            guard var content = deferred else { return }
            deferred = nil
            if let selection = notepad?.lineSelection, selection.lineID == content.lineID {
                content.selection = selection
            } else {
                content.selection = nil
            }
            apply(content, in: view)
        }

        private func apply(_ content: Content, in view: LiveLineTextView) {
            guard content != applied else { return }
            let textChanged = applied == nil
                || applied?.speaker != content.speaker
                || applied?.displayText != content.displayText
                || applied?.isFinal != content.isFinal
                || applied?.moments != content.moments

            if textChanged {
                isApplyingUpdate = true
                let attributed = LiveLineText.attributedString(
                    speaker: content.speaker, text: content.displayText, isFinal: content.isFinal, moments: content.moments
                )
                view.textStorage?.setAttributedString(attributed)
                view.setAccessibilityValue("\(content.speaker) \(content.displayText)")
                view.setAccessibilityLabel("\(content.speaker): \(content.displayText)")
                isApplyingUpdate = false
                #if DEBUG
                textRebuildCountForTesting += 1
                #endif
            }

            if textChanged || applied?.selection != content.selection {
                applySelectionState(content.selection, lineID: content.lineID, speakerLength: content.speakerLength, in: view)
                #if DEBUG
                selectionApplyCountForTesting += 1
                #endif
            }

            applied = content
        }

        /// Restores this line's own selection from `selection` when it still
        /// fits the (possibly just-changed) text, and draws its highlight;
        /// clears both when there is none, or it no longer fits. `lineID`
        /// and `speakerLength` are the content *being applied*, not the
        /// previous `applied` — this runs before `applied` is updated.
        private func applySelectionState(_ selection: NotepadLineSelection?, lineID: UUID, speakerLength: Int, in view: LiveLineTextView) {
            guard let selection, selection.lineID == lineID else {
                clearSelection(in: view)
                return
            }
            let fullLength = (view.string as NSString).length
            let restoreRange = NSRange(location: selection.range.location + speakerLength, length: selection.range.length)
            guard restoreRange.location >= 0, NSMaxRange(restoreRange) <= fullLength else {
                clearSelection(in: view)
                return
            }
            isApplyingUpdate = true
            view.setSelectedRange(restoreRange)
            isApplyingUpdate = false
            applyHighlight(restoreRange, in: view)
        }

        private func clearSelection(in view: LiveLineTextView) {
            if view.selectedRange().length > 0 {
                isApplyingUpdate = true
                view.setSelectedRange(NSRange(location: 0, length: 0))
                isApplyingUpdate = false
            }
            applyHighlight(NSRange(location: 0, length: 0), in: view)
        }

        /// The notepad is often not key (the user is back in the call app
        /// after making a selection there), so AppKit's own selection color
        /// (pale, drawn only while key) would often make a selection
        /// invisible to the very person who just made it. This
        /// paints it as a temporary `NSLayoutManager` attribute instead —
        /// never part of `textStorage`, so it never collides with a moment's
        /// own highlight — in the ordinary, vivid selection color, whether
        /// the panel is key or not.
        private func applyHighlight(_ range: NSRange, in view: LiveLineTextView) {
            guard let layoutManager = view.layoutManager else { return }
            let length = (view.string as NSString).length
            if length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            }
            guard range.length > 0 else { return }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: range)
        }

        /// Already on the main actor by the time AppKit calls this — see
        /// `LiveLineTextView`'s own doc comment — but the delegate
        /// requirement itself carries no isolation, so a Swift 6 conformance
        /// from this `@MainActor` type must re-assert it explicitly.
        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard !isApplyingUpdate, let textView = view, let lineID = applied?.lineID else { return }
                let full = textView.selectedRange()
                applyHighlight(full, in: textView)
                guard full.length > 0 else {
                    // `applied?.selection` must track the view's own actual
                    // selection, not just what the last `update` carried in:
                    // without this, a later `update` whose incoming
                    // `selection` happens to equal the stale cached value
                    // (both nil, most often) would wrongly look unchanged
                    // and skip clearing/restoring the view for real.
                    applied?.selection = nil
                    if notepad?.lineSelection?.lineID == lineID { notepad?.lineSelection = nil }
                    return
                }
                let speakerLength = applied?.speakerLength ?? 0
                let (clamped, text) = LiveLineText.selectedText(range: full, in: applied?.displayText ?? "", speakerLength: speakerLength)
                let start = applied?.start ?? 0
                let selection = NotepadLineSelection(lineID: lineID, start: start, range: clamped, text: text)
                applied?.selection = selection
                notepad?.lineSelection = selection
            }
        }

        #if DEBUG
        var isApplyingUpdateForTesting: Bool { isApplyingUpdate }
        #endif
    }
}

/// "Copy" for the live text: every line as `[m:ss] Name: text`, the same
/// time format `transcript.md` uses, to the ordinary clipboard — the user's
/// own click, so no sandboxing of the clipboard applies.
struct CopyLiveTextButton: View {
    @ObservedObject var notepad: NotepadModel

    var body: some View {
        Button(action: copy) {
            Label {
                Text("Copy")
            } icon: {
                Image(systemName: "doc.on.doc")
            }
        }
        .buttonStyle(.plain)
        .disabled(lines.isEmpty)
        .help(Text("Copy the live text"))
        .accessibilityIdentifier("liveTranscriptCopyButton")
        .accessibilityLabel(Text("Copy the live text"))
    }

    private var lines: [LiveLine] {
        LiveLinesView.lines(for: notepad)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.copyText(for: lines), forType: .string)
    }
}

extension CopyLiveTextButton {
    /// Every line as `[m:ss] Name: text`, one per line, in the model's own
    /// order — the fallback track label (`MeetingTranscript.microphoneLabel`
    /// / `.systemLabel`) stands in for a line with no name from the call
    /// feed, the same rule `LiveLineRow` shows on screen.
    static func copyText(for lines: [LiveLine]) -> String {
        lines.map { line -> String in
            let speaker = line.name ?? (line.track == .microphone
                ? MeetingTranscript.microphoneLabel
                : MeetingTranscript.systemLabel)
            return "[\(TranscriptSegment.timecode(line.start))] \(speaker): \(line.displayText)"
        }.joined(separator: "\n")
    }
}
