import AppKit
import SwiftUI

/// A transcript, read-only, in an AppKit text view: selection runs across
/// any number of lines, ⌘A and ⌘C work, ⌘F searches with the find bar, and
/// a two-hour call's text scrolls without delay. The text is replaced only
/// when its identity changes, so a redraw of the window keeps the scroll
/// position and the selection; the line being played and the window
/// search's matches are drawn over it, never into it.
struct TranscriptTextView: NSViewRepresentable {
    let transcript: MeetingTranscript
    /// The meeting, version and content shown; a new one replaces the text.
    let identity: String
    /// The line being said, highlighted.
    var currentLine: Int?
    /// Timecodes are links that play from their line; nil: plain text.
    var playLine: ((Int) -> Void)?
    /// Space, while the text has the focus.
    var togglePlayer: (() -> Void)?
    /// The search of all meetings: its matches are highlighted, and ⌘G and
    /// ⇧⌘G go through them while the find bar is closed.
    var query = ""
    /// Take the focus at the first match, once; `didFocus` says it was taken.
    var focusMatch = false
    var didFocus: (() -> Void)?
    /// The text is on screen: hidden, it gives the focus up and takes none.
    var active = true
    /// A step through the matches asked for by the card's arrows: a new
    /// `id` goes once, by `direction`.
    var step = MatchStep(id: 0, direction: 1)
    /// Told which match is selected (nil: none) and how many there are.
    var onMatches: ((MatchPosition) -> Void)?
    /// Told what is selected, after the view's update, for the text it was
    /// selected in: a report from a text replaced since is never told.
    var onSelection: ((Selection) -> Void)?
    /// The context menu's "Add to Dictionary…", with the selection the text
    /// view has at that moment; nil: no such item.
    var addToDictionary: ((Selection) -> Void)?

    struct MatchStep: Equatable {
        let id: Int
        let direction: Int
    }

    struct MatchPosition: Equatable {
        var index: Int?
        var total = 0
    }

    /// What is selected, and in which text: the identity it was shown under,
    /// so a range is never read in another text of the same length.
    struct Selection: Equatable {
        let identity: String
        /// Every stretch selected, in the shown string's UTF-16.
        let ranges: [NSRange]

        var isEmpty: Bool { !ranges.contains { $0.length > 0 } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, for the temporary attributes the highlights are.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = TranscriptNSTextView(frame: .zero, textContainer: container)
        textView.coordinator = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.backgroundColor = .textBackgroundColor
        textView.linkTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor, .cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("meetingTranscriptText")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TranscriptNSTextView else { return }
        let coordinator = context.coordinator
        coordinator.playLine = playLine
        coordinator.togglePlayer = togglePlayer
        coordinator.onMatches = onMatches
        coordinator.onSelection = onSelection
        coordinator.addToDictionary = addToDictionary
        if coordinator.identity != identity {
            coordinator.replace(with: transcript, identity: identity, in: textView)
        }
        coordinator.link(playLine != nil, in: textView)
        coordinator.show(query: query, current: currentLine, in: textView)
        if coordinator.lastStep.id != step.id {
            coordinator.lastStep = step
            coordinator.step(step.direction, in: textView)
        }
        coordinator.focusWanted = focusMatch && active
        coordinator.active = active
        if !active, Self.holdsTheFocus(scrollView) {
            // Out of the layout, and only if it is still this text's or its
            // find bar's: the focus of the section shown or a sheet stays.
            DispatchQueue.main.async {
                if Self.holdsTheFocus(scrollView) { scrollView.window?.makeFirstResponder(nil) }
            }
        }
        if focusMatch, active, !coordinator.focusing {
            coordinator.focusing = true
            // Once the view is in its window, if it is still wanted then: a
            // change of section meanwhile hid the text.
            Task { @MainActor [didFocus] in
                guard coordinator.focusWanted else {
                    coordinator.focusing = false
                    return
                }
                textView.window?.makeFirstResponder(textView)
                coordinator.step(1, in: textView, fromStart: true)
                coordinator.focusing = false
                didFocus?()
            }
        }
    }

    /// The text, or its find bar's field (the window's field editor inside
    /// it while it is typed in), has the window's focus.
    static func holdsTheFocus(_ scrollView: NSScrollView) -> Bool {
        guard let responder = scrollView.window?.firstResponder as? NSView else { return false }
        return responder === scrollView.documentView || responder.isDescendant(of: scrollView)
    }

    /// Whatever room the card gives it: a long line wraps instead of
    /// widening the window past its edge.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        func room(_ offered: CGFloat?) -> CGFloat {
            guard let offered, offered.isFinite else { return 200 }
            return offered
        }
        return CGSize(width: room(proposal.width), height: room(proposal.height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var identity: String?
        var layout = MeetingTranscript.Layout(string: "", title: nil, notes: nil, lines: [], searchable: [])
        var playLine: ((Int) -> Void)?
        var togglePlayer: (() -> Void)?
        var linked = false
        var query: String?
        var current: Int?
        var matches: [NSRange] = []
        var focusing = false
        /// The view's latest word on whether the text may take the focus.
        var focusWanted = false
        /// The text is on screen: hidden, its find actions do nothing.
        var active = true
        var lastStep = MatchStep(id: 0, direction: 1)
        var onMatches: ((MatchPosition) -> Void)?
        var onSelection: ((Selection) -> Void)?
        var addToDictionary: ((Selection) -> Void)?
        private var reported: MatchPosition?
        private var reportedSelection: Selection?
        /// Counts the texts shown: a selection reported for one is dropped
        /// once another took its place.
        private(set) var generation = 0

        /// A new text: the selection, the links and the highlights start again.
        func replace(with transcript: MeetingTranscript, identity: String, in textView: NSTextView) {
            generation += 1
            self.identity = identity
            layout = transcript.layout
            linked = false
            query = nil
            current = nil
            reportedSelection = nil
            textView.textStorage?.setAttributedString(TranscriptTextView.attributed(transcript))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }

        /// After the view's update: the card's state is not changed in it.
        func report(_ textView: NSTextView) {
            let selected = textView.selectedRange()
            let position = MatchPosition(index: matches.firstIndex { NSEqualRanges($0, selected) }, total: matches.count)
            guard position != reported, let onMatches else { return }
            reported = position
            Task { @MainActor in onMatches(position) }
        }

        /// What the text view has selected now, in the text shown now.
        func selection(of textView: NSTextView) -> Selection? {
            identity.map { Selection(identity: $0, ranges: textView.selectedRanges.map(\.rangeValue)) }
        }

        /// After the view's update, and only while the same text is shown.
        func reportSelection(_ textView: NSTextView) {
            guard let onSelection, let selection = selection(of: textView), selection != reportedSelection else { return }
            reportedSelection = selection
            let generation = generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                onSelection(selection)
            }
        }

        /// The selection the view has now, if it holds words a new entry
        /// could be made from; nil without a way to take it.
        func dictionarySelection(of textView: NSTextView) -> Selection? {
            guard addToDictionary != nil, let selection = selection(of: textView), !selection.isEmpty,
                  layout.dictionarySource(for: selection.ranges) != nil else { return nil }
            return selection
        }

        /// The context menu's item: the selection the view has at the click.
        func addSelectionToDictionary(from textView: NSTextView) {
            guard let selection = dictionarySelection(of: textView) else { return }
            addToDictionary?(selection)
        }

        /// The timecodes as links, or not; the text itself stays.
        func link(_ on: Bool, in textView: NSTextView) {
            guard on != linked, let storage = textView.textStorage else { return }
            linked = on
            storage.beginEditing()
            for (index, line) in layout.lines.enumerated() {
                if on {
                    storage.addAttribute(.link, value: "murmurly-line:\(index)", range: line.timecode)
                } else {
                    storage.removeAttribute(.link, range: line.timecode)
                }
            }
            storage.endEditing()
        }

        /// Drawn again only when the line or the query changed.
        func show(query: String, current: Int?, in textView: NSTextView) {
            guard query != self.query || current != self.current, let manager = textView.layoutManager else { return }
            if query != self.query { matches = MeetingSearch.ranges(of: query, in: layout) }
            self.query = query
            self.current = current
            let whole = NSRange(location: 0, length: (layout.string as NSString).length)
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            if let current, layout.lines.indices.contains(current) {
                manager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.16),
                    forCharacterRange: layout.lines[current].whole
                )
            }
            for match in matches {
                manager.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: match)
            }
            report(textView)
        }

        /// The next or previous match from the selection, round the end.
        func step(_ direction: Int, in textView: NSTextView, fromStart: Bool = false) {
            guard !matches.isEmpty else { return }
            let at = fromStart ? -1 : textView.selectedRange().location
            let next: NSRange = direction > 0
                ? matches.first { $0.location > at } ?? matches[0]
                : matches.last { $0.location < at } ?? matches[matches.count - 1]
            textView.setSelectedRange(next)
            textView.scrollRangeToVisible(next)
            textView.showFindIndicator(for: next)
        }

        /// Any change of the selection: a step, a click, the find bar.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            report(textView)
            reportSelection(textView)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let value = link as? String, value.hasPrefix("murmurly-line:"),
                  let index = Int(value.dropFirst("murmurly-line:".count)) else { return false }
            playLine?(index)
            return true
        }
    }

    /// The transcript as shown, and, as `.string`, as "Copy Text" copies it.
    /// Colors are the system's, so both appearances read alike.
    static func attributed(_ transcript: MeetingTranscript) -> NSAttributedString {
        let size = NSFont.systemFontSize
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
        let layout = transcript.layout
        let result = NSMutableAttributedString(string: layout.string, attributes: body)
        if let title = layout.title {
            result.addAttributes([.font: NSFont.boldSystemFont(ofSize: size + 2)], range: title)
        }
        if let notes = layout.notes {
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ], range: notes)
        }
        for line in layout.lines {
            result.addAttributes([
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: line.timecode)
            result.addAttributes([.font: NSFont.boldSystemFont(ofSize: size)], range: line.speaker)
        }
        return result
    }
}

/// Space plays and pauses; ⌘G and ⇧⌘G go through the window search's
/// matches while the find bar is closed, and through the find bar's as
/// before when it is open.
final class TranscriptNSTextView: NSTextView {
    weak var coordinator: TranscriptTextView.Coordinator?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers == " ", modifiers.isEmpty, let toggle = coordinator?.togglePlayer {
            toggle()
            return
        }
        super.keyDown(with: event)
    }

    override func performFindPanelAction(_ sender: Any?) {
        guard coordinator?.active != false, !stepThroughMatches(sender) else { return }
        super.performFindPanelAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard coordinator?.active != false, !stepThroughMatches(sender) else { return }
        super.performTextFinderAction(sender)
    }

    /// "Add to Dictionary…" first, while words are selected: after the
    /// click's own change of the selection, so for what is selected then.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, coordinator?.dictionarySelection(of: self) != nil else { return menu }
        let item = NSMenuItem(
            title: String(localized: "Add to Dictionary…"), action: #selector(addSelectionToDictionary(_:)), keyEquivalent: ""
        )
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("meetingAddToDictionaryMenu")
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func addSelectionToDictionary(_ sender: Any?) {
        coordinator?.addSelectionToDictionary(from: self)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if coordinator?.active == false, Self.isFind(item) { return false }
        if searching, [NSTextFinder.Action.nextMatch.rawValue, NSTextFinder.Action.previousMatch.rawValue].contains(item.tag) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// The Find menu's items and their keys.
    private static func isFind(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(NSTextView.performTextFinderAction(_:))
            || item.action == #selector(NSTextView.performFindPanelAction(_:))
    }

    private var searching: Bool {
        guard let coordinator, !(coordinator.query ?? "").isEmpty, !coordinator.matches.isEmpty else { return false }
        return enclosingScrollView?.isFindBarVisible != true
    }

    private func stepThroughMatches(_ sender: Any?) -> Bool {
        guard searching, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag else { return false }
        switch tag {
        case NSTextFinder.Action.nextMatch.rawValue: coordinator?.step(1, in: self)
        case NSTextFinder.Action.previousMatch.rawValue: coordinator?.step(-1, in: self)
        default: return false
        }
        return true
    }
}
