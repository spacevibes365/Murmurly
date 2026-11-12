import AppKit
import XCTest
@testable import Murmurly

@MainActor
final class LiveLinesViewTests: XCTestCase {
    private func line(
        id: UUID = UUID(), start: Double, track: LiveTranscript.Track = .system, name: String? = nil, text: String = "текст",
        isFinal: Bool = true
    ) -> LiveLine {
        LiveLine(id: id, track: track, start: start, end: start + 1, rawText: text, displayText: text, name: name, isFinal: isFinal)
    }

    private func note(t: Double? = nil, text: String = "заметка") -> MeetingNote {
        MeetingNote(id: UUID(), t: t, kind: .note, text: text)
    }

    // MARK: - `CopyLiveTextButton.copyText`

    func testCopyTextFormatsEachLineWithTimeSpeakerAndText() {
        let short = line(start: 65, track: .system, name: "Ада", text: "первая фраза")
        let long = line(start: 3_725, track: .microphone, name: nil, text: "вторая фраза")

        let text = CopyLiveTextButton.copyText(for: [short, long])

        XCTAssertEqual(
            text,
            "[1:05] Ада: первая фраза\n[1:02:05] \(MeetingTranscript.microphoneLabel): вторая фраза"
        )
    }

    func testCopyTextFallsBackToTheTrackLabelWhenTheLineHasNoName() {
        let systemLine = line(start: 0, track: .system, name: nil, text: "фраза")
        let micLine = line(start: 1, track: .microphone, name: nil, text: "фраза")

        let text = CopyLiveTextButton.copyText(for: [systemLine, micLine])

        XCTAssertTrue(text.contains("\(MeetingTranscript.systemLabel): фраза"))
        XCTAssertTrue(text.contains("\(MeetingTranscript.microphoneLabel): фраза"))
    }

    func testCopyTextOfNoLinesIsEmpty() {
        XCTAssertEqual(CopyLiveTextButton.copyText(for: []), "")
    }

    // MARK: - `LiveLinesView.lines(for:)`

    func testLinesForNotepadFallsBackToKeptLinesOnceTheLiveModelIsGone() {
        let notepad = NotepadModel()
        let model = LiveTranscriptModel()
        let liveLine = line(start: 0, text: "живая строка")
        model.publishForTesting(lines: [liveLine], state: .running)
        notepad.liveModel = model

        XCTAssertEqual(LiveLinesView.lines(for: notepad), [liveLine])

        // The recording stops: the panel sets `liveModel` back to nil and
        // copies its lines into `keptLines` first.
        let keptLine = line(start: 10, text: "сохранённая строка")
        notepad.keptLines = [keptLine]
        notepad.liveModel = nil

        XCTAssertEqual(LiveLinesView.lines(for: notepad), [keptLine])
    }

    // MARK: - `ScrollFollowReducer.reduce`

    /// Calls `reduce` with no live generation, no gesture phase, a container
    /// of 400 and a given offset/content height — convenience for the
    /// resize/gesture cases (D, E, F, G, H, I, J), which never carry a
    /// generation.
    private func reduceNoGeneration(
        wasFollowing: Bool,
        offsetDelta: CGFloat,
        contentDelta: CGFloat = 0,
        containerDelta: CGFloat = 0,
        newOffset: CGFloat,
        newContentHeight: CGFloat = 1_000,
        newContainerHeight: CGFloat = 400,
        isGesturePhase: Bool = false
    ) -> ScrollFollowReducer.Result {
        ScrollFollowReducer.reduce(
            wasFollowing: wasFollowing,
            generation: nil,
            now: .now,
            offsetDelta: offsetDelta,
            contentDelta: contentDelta,
            containerDelta: containerDelta,
            newOffset: newOffset,
            newContentHeight: newContentHeight,
            newContainerHeight: newContainerHeight,
            bottomInset: 0,
            isGesturePhase: isGesturePhase,
            tolerance: 24
        )
    }

    /// A — the frame that lands a scroll to a search highlight near the
    /// bottom: a generation with intention `false` is still open (one
    /// settling frame in), so the result stays `false` even though the
    /// frame itself sits at the bottom. The old code decided this from
    /// `atBottom` alone, with no regard for whether this view's own
    /// `scrollTo` caused it, so this exact case came out `true`.
    func testGenerationSettlingAtBottomKeepsIntendedFalse() {
        let generation = ScrollFollowGeneration(intendedFollowing: false, startTime: .now, stableFrames: 1)
        let result = ScrollFollowReducer.reduce(
            wasFollowing: false, generation: generation, now: .now,
            offsetDelta: 2, contentDelta: 0, containerDelta: 0,
            newOffset: 976, newContentHeight: 1_000, newContainerHeight: 400,
            bottomInset: 0, isGesturePhase: false, tolerance: 24
        )
        XCTAssertFalse(result.isFollowingBottom)
    }

    /// B — "Jump to bottom"'s own scroll, mid-animation, well above the
    /// bottom: the generation's intention (`true`) must be reported, and it
    /// must stay open (a large per-frame delta is not "settled").
    func testGenerationMidAnimationAboveBottomReportsIntentionAndStaysOpen() {
        let generation = ScrollFollowGeneration(intendedFollowing: true, startTime: .now)
        let result = ScrollFollowReducer.reduce(
            wasFollowing: true, generation: generation, now: .now,
            offsetDelta: 120, contentDelta: 0, containerDelta: 0,
            newOffset: 500, newContentHeight: 1_000, newContainerHeight: 400,
            bottomInset: 0, isGesturePhase: false, tolerance: 24
        )
        XCTAssertTrue(result.isFollowingBottom)
        XCTAssertNotNil(result.generation, "a frame well above the target has not settled yet")
    }

    /// C — the container shrinking (the search bar opening) pushes the
    /// offset down to a new bottom on its own; with no generation open and
    /// following already off, that must not read as a gesture that turns it
    /// on.
    func testContainerShrinkingToTheBottomLeavesFollowingOff() {
        let result = reduceNoGeneration(
            wasFollowing: false, offsetDelta: 24, containerDelta: -24, newOffset: 624, newContentHeight: 1_000, newContainerHeight: 376
        )
        XCTAssertFalse(result.isFollowingBottom)
    }

    /// D (finding 3) — content growing while already at the bottom, with
    /// following off, used to read as "sitting at the bottom" and turn
    /// following back on; `atBottom` must not be checked before the resize
    /// explanation.
    func testContentGrowingAtTheBottomLeavesFollowingOffWhenItWasOff() {
        let result = reduceNoGeneration(
            wasFollowing: false, offsetDelta: 40, contentDelta: 40, newOffset: 640, newContentHeight: 1_040
        )
        XCTAssertFalse(result.isFollowingBottom)
    }

    /// E — the container growing (the window getting shorter — i.e. a
    /// smaller container height here is the "window below" case; this is
    /// the complementary growth) while following was on must preserve it.
    func testContainerGrowingPreservesFollowingWhenItWasOn() {
        let result = reduceNoGeneration(
            wasFollowing: true, offsetDelta: -40, containerDelta: 40, newOffset: 560, newContentHeight: 1_000, newContainerHeight: 440
        )
        XCTAssertTrue(result.isFollowingBottom)
    }

    /// F (finding 4) — the container growing enough that the existing
    /// content now fits without scrolling (so the geometry would read as
    /// "at the bottom") must not turn following on when it was off and the
    /// change is fully explained by the resize.
    func testContainerGrowingToFitLeavesFollowingOffWhenItWasOff() {
        let result = reduceNoGeneration(
            wasFollowing: false, offsetDelta: -400, containerDelta: 400, newOffset: 200, newContentHeight: 1_000, newContainerHeight: 800
        )
        XCTAssertFalse(result.isFollowingBottom)
    }

    /// G (finding 5) — a real gesture away from the bottom arriving in the
    /// same frame as new content growing must be read as a gesture (via
    /// `ScrollPhase`), not swallowed by the resize explanation.
    func testGestureAwayWithNewContentInTheSameFrameTurnsFollowingOff() {
        let result = reduceNoGeneration(
            wasFollowing: true, offsetDelta: 10, contentDelta: 40, newOffset: 600, newContentHeight: 1_040,
            isGesturePhase: true
        )
        XCTAssertFalse(result.isFollowingBottom)
    }

    /// H — content growing with no gesture, following already on, must
    /// preserve it.
    func testContentGrowingWithoutGesturePreservesFollowingWhenItWasOn() {
        let result = reduceNoGeneration(
            wasFollowing: true, offsetDelta: 40, contentDelta: 40, newOffset: 640, newContentHeight: 1_040
        )
        XCTAssertTrue(result.isFollowingBottom)
    }

    /// I — a real scroll away from the bottom, unexplained by any resize,
    /// turns following off outright.
    func testUnexplainedScrollAwayFromTheBottomTurnsFollowingOff() {
        let result = reduceNoGeneration(wasFollowing: true, offsetDelta: -200, newOffset: 400)
        XCTAssertFalse(result.isFollowingBottom)
    }

    /// J — the user scrolling down to the bottom themselves, with following
    /// off beforehand, turns it on.
    func testUserScrollingDownToTheBottomTurnsFollowingOn() {
        let result = reduceNoGeneration(wasFollowing: false, offsetDelta: 200, newOffset: 600)
        XCTAssertTrue(result.isFollowingBottom)
    }

    /// K (finding 6) — a generation that never settles (the frame's own
    /// offset keeps moving) times out after 0.5 s and reports its intention
    /// on that very frame, rather than staying stuck forever.
    func testGenerationTimesOutAndReportsItsIntention() {
        let generation = ScrollFollowGeneration(intendedFollowing: false, startTime: .now.addingTimeInterval(-0.6))
        let result = ScrollFollowReducer.reduce(
            wasFollowing: false, generation: generation, now: .now,
            offsetDelta: 0, contentDelta: 0, containerDelta: 0,
            newOffset: 600, newContentHeight: 1_000, newContainerHeight: 400,
            bottomInset: 0, isGesturePhase: false, tolerance: 24
        )
        XCTAssertFalse(result.isFollowingBottom)
        XCTAssertNil(result.generation, "an expired generation must not linger")
    }

    /// L (finding 6) — once a generation has timed out, a real gesture on
    /// the very next frame must be judged fresh, not suppressed by the
    /// stale intention.
    func testGestureAfterGenerationTimeoutIsJudgedFresh() {
        let generation = ScrollFollowGeneration(intendedFollowing: true, startTime: .now.addingTimeInterval(-0.6))
        let result = ScrollFollowReducer.reduce(
            wasFollowing: true, generation: generation, now: .now,
            offsetDelta: -200, contentDelta: 0, containerDelta: 0,
            newOffset: 400, newContentHeight: 1_000, newContainerHeight: 400,
            bottomInset: 0, isGesturePhase: true, tolerance: 24
        )
        XCTAssertFalse(result.isFollowingBottom)
        XCTAssertNil(result.generation)
    }

    /// Finding 2 — the bottom formula must account for the scroll view's
    /// own bottom inset: a frame that is at the true bottom once the inset
    /// is added back must read as "at the bottom".
    func testBottomFormulaAccountsForBottomInset() {
        // Without the inset, the true bottom is at offset 1,000 - 400 = 600;
        // with a 20 pt bottom inset the scrollable range extends further, so
        // the true bottom only arrives at offset 620. 600 must not count as
        // "at the bottom" once the inset is accounted for.
        let notAtTrueBottom = ScrollFollowReducer.reduce(
            wasFollowing: false, generation: nil, now: .now,
            offsetDelta: 200, contentDelta: 0, containerDelta: 0,
            newOffset: 600, newContentHeight: 1_000, newContainerHeight: 400,
            bottomInset: 20, isGesturePhase: false, tolerance: 0
        )
        XCTAssertFalse(notAtTrueBottom.isFollowingBottom)

        let atTrueBottom = ScrollFollowReducer.reduce(
            wasFollowing: false, generation: nil, now: .now,
            offsetDelta: 220, contentDelta: 0, containerDelta: 0,
            newOffset: 620, newContentHeight: 1_000, newContainerHeight: 400,
            bottomInset: 20, isGesturePhase: false, tolerance: 0
        )
        XCTAssertTrue(atTrueBottom.isFollowingBottom)
    }

    // MARK: - `LiveLineText.attributedString` draws the moment's highlight itself

    /// A plain-text `NSTextView` ignores per-range attributes
    /// (one font, one color for the whole view). The view's own `isRichText`
    /// must be on, or neither the moment's highlight nor the speaker's bold
    /// name would actually draw — reading `textStorage` back from the real
    /// view (not just the detached `NSAttributedString`) is the only thing
    /// that proves it.
    func testLineTextHighlightsTheMomentsWordsAfterTheSpeaker() {
        let speaker = "Ада"
        let text = "обсудим бюджет на квартал"
        let momentText = "бюджет на квартал"
        let moment = MeetingNote(id: UUID(), t: 0, kind: .moment, text: momentText)
        let notepad = NotepadModel()

        let representable = LiveLineText(
            line: line(start: 0, name: speaker, text: text), speaker: speaker, moments: [moment],
            selection: nil, notepad: notepad
        )
        let coordinator = representable.makeCoordinator()
        let view = LiveLineText.makeTextView(coordinator: coordinator)
        coordinator.update(from: representable, in: view)

        let prefixLength = LiveLineText.speakerPrefixLength(for: speaker)
        let wordsLocation = prefixLength + (text as NSString).range(of: momentText).location
        let wordsRange = NSRange(location: wordsLocation, length: (momentText as NSString).length)

        var highlighted = NSRange()
        let background = view.textStorage?.attribute(.backgroundColor, at: wordsRange.location, effectiveRange: &highlighted) as? NSColor
        XCTAssertNotNil(background, "the moment's words must be highlighted in the view's own textStorage")
        XCTAssertEqual(highlighted, wordsRange)

        var speakerRange = NSRange()
        let speakerFont = view.textStorage?.attribute(.font, at: 0, effectiveRange: &speakerRange) as? NSFont
        XCTAssertEqual(speakerFont?.fontDescriptor.symbolicTraits.contains(.bold), true, "the speaker's name must be drawn bold by the view itself")
    }

    /// An interim line's text can change under a moment that is still
    /// anchored to it (`NotepadModel.momentLineIDs`): once its words are no
    /// longer in the text, the line draws no highlight at all — the ★ stays
    /// up to the row, not `attributedString`.
    func testLineTextWithoutTheMomentsWordsHasNoHighlight() {
        let moment = MeetingNote(id: UUID(), t: 0, kind: .moment, text: "слов здесь уже нет")
        let attributed = LiveLineText.attributedString(speaker: "Ада", text: "текст сменился", isFinal: false, moments: [moment])

        var found = false
        attributed.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { found = true }
        }
        XCTAssertFalse(found)
    }

    // MARK: - `LiveLineText.selectedText` clamps to the line's own text and trims it

    /// A raw selection reaching into the speaker's name and
    /// past the end of the text clamps to the line's own bounds; the
    /// returned words are trimmed of their leading and trailing spaces.
    func testSelectionIsClampedToTheLinesOwnTextAndTrimmed() {
        let speaker = "Ада"
        let displayText = " бюджет на квартал "
        let speakerLength = LiveLineText.speakerPrefixLength(for: speaker)

        let raw = NSRange(location: 1, length: speakerLength + (displayText as NSString).length + 50)

        let (clamped, text) = LiveLineText.selectedText(range: raw, in: displayText, speakerLength: speakerLength)

        XCTAssertEqual(
            clamped, NSRange(location: 0, length: (displayText as NSString).length),
            "a selection reaching into the name or past the text clamps to the line's own bounds"
        )
        XCTAssertEqual(text, "бюджет на квартал")
    }

    // MARK: - `LiveLineTextView` accepts the first click

    func testLineTextViewAcceptsTheFirstClick() {
        let view = LiveLineTextView(usingTextLayoutManager: false)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    // MARK: - `LiveLineText.Coordinator` does nothing for unchanged values

    private func makeCoordinatorAndView(
        notepad: NotepadModel, line: LiveLine, speaker: String = "Ада", moments: [MeetingNote] = [],
        selection: NotepadLineSelection? = nil
    ) -> (LiveLineText, LiveLineText.Coordinator, LiveLineTextView) {
        let representable = LiveLineText(line: line, speaker: speaker, moments: moments, selection: selection, notepad: notepad)
        let coordinator = representable.makeCoordinator()
        let view = LiveLineText.makeTextView(coordinator: coordinator)
        return (representable, coordinator, view)
    }

    func testLineTextDoesNothingForUnchangedValues() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет на квартал")
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine)

        coordinator.update(from: representable, in: view)
        XCTAssertEqual(coordinator.textRebuildCountForTesting, 1)
        XCTAssertEqual(coordinator.selectionApplyCountForTesting, 1)

        coordinator.update(from: representable, in: view)
        XCTAssertEqual(coordinator.textRebuildCountForTesting, 1, "an unchanged value must never rebuild the text")
        XCTAssertEqual(coordinator.selectionApplyCountForTesting, 1, "an unchanged selection must never be reapplied")
    }

    func testLineTextRedrawsOnlyWhatChanged() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет на квартал")
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine)
        coordinator.update(from: representable, in: view)

        // Only the selection changes: the text must not rebuild.
        let selected = NotepadLineSelection(lineID: aLine.id, start: aLine.start, range: NSRange(location: 0, length: 8), text: "обсудим")
        let withSelection = LiveLineText(line: aLine, speaker: "Ада", moments: [], selection: selected, notepad: notepad)
        coordinator.update(from: withSelection, in: view)
        XCTAssertEqual(coordinator.textRebuildCountForTesting, 1, "a selection change alone must not rebuild the text")
        XCTAssertEqual(coordinator.selectionApplyCountForTesting, 2)

        // A moment's own text changes: the line must rebuild.
        let moment = MeetingNote(id: UUID(), t: aLine.start, kind: .moment, text: "бюджет")
        let withMoment = LiveLineText(line: aLine, speaker: "Ада", moments: [moment], selection: selected, notepad: notepad)
        coordinator.update(from: withMoment, in: view)
        XCTAssertEqual(coordinator.textRebuildCountForTesting, 2, "a changed moment must rebuild the text")
    }

    // MARK: - A selection written by the user reaches `notepad.lineSelection`

    /// A real selection made in the view (`setSelectedRange`, which sends the
    /// same delegate notification a mouse click would) must be written to
    /// the model, clamped to `displayText`'s own coordinates.
    func testSelectingWordsInALineWritesTheModelsSelection() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет на квартал")
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine)
        coordinator.update(from: representable, in: view)

        let prefixLength = LiveLineText.speakerPrefixLength(for: "Ада")
        let wordsLocation = prefixLength + ("обсудим бюджет на квартал" as NSString).range(of: "бюджет").location
        view.setSelectedRange(NSRange(location: wordsLocation, length: ("бюджет" as NSString).length))

        XCTAssertEqual(notepad.lineSelection?.lineID, aLine.id)
        XCTAssertEqual(notepad.lineSelection?.start, aLine.start)
        XCTAssertEqual(notepad.lineSelection?.text, "бюджет")
    }

    /// `update` restoring or clearing a selection programmatically
    /// (`isApplyingUpdate`) must never itself publish over
    /// `notepad.lineSelection` — only the user's own selection may.
    func testAProgrammaticClearNeverPublishesOverTheModel() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет на квартал")
        let selection = NotepadLineSelection(lineID: aLine.id, start: aLine.start, range: NSRange(location: 0, length: 7), text: "обсудим")
        notepad.lineSelection = selection
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine, selection: selection)
        coordinator.update(from: representable, in: view)
        XCTAssertGreaterThan(view.selectedRange().length, 0)

        let cleared = LiveLineText(line: aLine, speaker: "Ада", moments: [], selection: nil, notepad: notepad)
        coordinator.update(from: cleared, in: view)

        XCTAssertEqual(view.selectedRange().length, 0, "the view's own selection must be cleared")
        XCTAssertEqual(notepad.lineSelection, selection, "clearing the view must not touch the model's own selection")
    }

    /// A selection made in line A, then one made in line B (sharing the same
    /// `notepad`): once B's `update` runs, A must have its own selection
    /// cleared, and the model must still name B.
    func testANewSelectionInOneLineClearsTheOther() {
        let notepad = NotepadModel()
        let lineA = line(start: 3, text: "строка А")
        let lineB = line(start: 9, text: "строка Б")
        let (representableA, coordinatorA, viewA) = makeCoordinatorAndView(notepad: notepad, line: lineA)
        coordinatorA.update(from: representableA, in: viewA)
        let prefixLength = LiveLineText.speakerPrefixLength(for: "Ада")
        viewA.setSelectedRange(NSRange(location: prefixLength, length: 6))
        XCTAssertEqual(notepad.lineSelection?.lineID, lineA.id)

        let (representableB, coordinatorB, viewB) = makeCoordinatorAndView(notepad: notepad, line: lineB)
        coordinatorB.update(from: representableB, in: viewB)
        viewB.setSelectedRange(NSRange(location: prefixLength, length: 6))
        XCTAssertEqual(notepad.lineSelection?.lineID, lineB.id)

        // A's next update must see the selection now belongs to B and clear its own.
        let clearedA = LiveLineText(line: lineA, speaker: "Ада", moments: [], selection: nil, notepad: notepad)
        coordinatorA.update(from: clearedA, in: viewA)
        XCTAssertEqual(viewA.selectedRange().length, 0)
        XCTAssertEqual(notepad.lineSelection?.lineID, lineB.id, "B's own selection must survive A's update")
    }

    /// The line's text grows but the selected range still fits inside it:
    /// the selection is restored. Once the text shrinks past the selected
    /// range, it is cleared instead.
    func testSelectionIsRestoredAfterTheTextChangesWhenItStillFits() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет")
        let selection = NotepadLineSelection(lineID: aLine.id, start: aLine.start, range: NSRange(location: 0, length: 7), text: "обсудим")
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine, selection: selection)
        coordinator.update(from: representable, in: view)
        XCTAssertEqual(view.selectedRange().length, 7)

        let grown = line(id: aLine.id, start: aLine.start, text: "обсудим бюджет на квартал")
        let withGrown = LiveLineText(line: grown, speaker: "Ада", moments: [], selection: selection, notepad: notepad)
        coordinator.update(from: withGrown, in: view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: LiveLineText.speakerPrefixLength(for: "Ада"), length: 7))
    }

    func testSelectionIsClearedWhenItNoLongerFits() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет на квартал")
        let selection = NotepadLineSelection(lineID: aLine.id, start: aLine.start, range: NSRange(location: 0, length: 25), text: "обсудим бюджет на квартал")
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine, selection: selection)
        coordinator.update(from: representable, in: view)
        XCTAssertEqual(view.selectedRange().length, 25)

        let shrunk = line(id: aLine.id, start: aLine.start, text: "короче")
        let withShrunk = LiveLineText(line: shrunk, speaker: "Ада", moments: [], selection: selection, notepad: notepad)
        coordinator.update(from: withShrunk, in: view)
        XCTAssertEqual(view.selectedRange().length, 0, "a selection past the new, shorter text must be cleared")
    }

    // MARK: - A selection being dragged with the mouse holds the text and selection

    /// While `isSelectingWithMouse` is set (a drag in progress), `update`
    /// must not touch the view's text or selection; once the drag ends
    /// (`endMouseSelectionForTesting`), the deferred update applies, with
    /// the selection the drag itself made.
    func testLineTextHoldsItsTextAndSelectionWhileTheMouseSelects() {
        let notepad = NotepadModel()
        let aLine = line(start: 3, text: "обсудим бюджет на квартал")
        let (representable, coordinator, view) = makeCoordinatorAndView(notepad: notepad, line: aLine)
        coordinator.update(from: representable, in: view)

        view.beginMouseSelectionForTesting()
        let prefixLength = LiveLineText.speakerPrefixLength(for: "Ада")
        let wordsLocation = prefixLength + ("обсудим бюджет на квартал" as NSString).range(of: "бюджет").location
        let wordsRange = NSRange(location: wordsLocation, length: ("бюджет" as NSString).length)
        view.setSelectedRange(wordsRange) // as the real drag's own notification would send

        let grown = line(id: aLine.id, start: aLine.start, text: "обсудим бюджет на квартал и сроки")
        let withGrown = LiveLineText(line: grown, speaker: "Ада", moments: [], selection: nil, notepad: notepad)
        coordinator.update(from: withGrown, in: view)
        XCTAssertEqual(view.string, "Ада обсудим бюджет на квартал", "an update mid-drag must not change the text")
        XCTAssertEqual(view.selectedRange(), wordsRange, "an update mid-drag must not change the selection")

        view.endMouseSelectionForTesting()
        XCTAssertEqual(view.string, "Ада обсудим бюджет на квартал и сроки", "the deferred update must apply once the drag ends")
        XCTAssertEqual(
            view.selectedRange(), wordsRange,
            "the drag's own selection, written to the model by its selection-changed notification, must be restored"
        )
    }

    // MARK: - A moment drawn on its own line never also appears as a feed item

    func testFeedPutsTheMomentOnItsLine() {
        let notepad = NotepadModel()
        let model = LiveTranscriptModel()
        let aLine = line(start: 2, text: "важная строка")
        model.publishForTesting(lines: [aLine], state: .running)
        notepad.liveModel = model
        let moment = MeetingNote(id: UUID(), t: 2, kind: .moment, text: "важная строка")
        notepad.notes = [moment]
        notepad.momentLineIDs = [moment.id: aLine.id]

        XCTAssertEqual(LiveLinesView.feed(for: notepad), [.line(aLine)])
        XCTAssertEqual(LiveLinesView.moments(for: notepad)[aLine.id]?.map(\.id), [moment.id])
    }

    // MARK: - `LiveLinesView.feedItemID(in:matching:)`

    func testFeedItemIDMatchesHighlightedLineOrNoteAndIsNilOtherwise() {
        let aLine = line(start: 0)
        let aNote = note(t: 5)
        let feed = NotepadFeedItem.merge(lines: [aLine], notes: [aNote])

        XCTAssertEqual(LiveLinesView.feedItemID(in: feed, matching: aLine.id), .line(aLine.id))
        XCTAssertEqual(LiveLinesView.feedItemID(in: feed, matching: aNote.id), .note(aNote.id))
        XCTAssertNil(LiveLinesView.feedItemID(in: feed, matching: nil))
        XCTAssertNil(LiveLinesView.feedItemID(in: feed, matching: UUID()), "an id that is in neither lines nor notes")
    }
}
