import Combine
import XCTest
@testable import Murmurly

@MainActor
final class NotepadSearchTests: XCTestCase {
    private func line(start: Double, text: String = "x", name: String? = nil, isFinal: Bool = true) -> LiveLine {
        LiveLine(id: UUID(), track: .microphone, start: start, end: start + 1, rawText: text, displayText: text, name: name, isFinal: isFinal)
    }

    private func note(t: Double?, text: String) -> MeetingNote {
        MeetingNote(id: UUID(), t: t, kind: .note, text: text)
    }

    func testMatchFoldsYoAndCase() {
        let notepad = NotepadModel()
        let yolka = line(start: 0, text: "Ёлка в офисе")
        let yelka = line(start: 1, text: "ЕЛКА стоит")
        let other = line(start: 2, text: "проверка связи")
        notepad.keptLines = [yolka, yelka, other]

        notepad.searchQuery = "елка"
        notepad.refreshSearch(resetCurrent: true)
        XCTAssertEqual(notepad.matchLineIDs, [yolka.id, yelka.id])

        notepad.searchQuery = "ЁЛКА"
        notepad.refreshSearch(resetCurrent: true)
        XCTAssertEqual(notepad.matchLineIDs, [yolka.id, yelka.id])
    }

    func testMatchIsTheMeetingSearchRule() {
        let pairs: [(query: String, text: String)] = [
            ("ёлка", "елка в офисе"),
            ("елка", "ёлка в офисе"),
            ("ЁЛКА", "елка в офисе"),
            ("й", "и"),
            ("и", "й")
        ]
        for pair in pairs {
            let matched = !NotepadModel.searchMatches(pair.query, lines: [line(start: 0, text: pair.text)], notes: []).isEmpty
            XCTAssertEqual(matched, MeetingSearch.matches(pair.query, pair.text), "query \(pair.query) in \(pair.text)")
        }
    }

    func testNotesAreSearchedInFeedOrder() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "проверка связи")
        let l10 = line(start: 10, text: "проверка звука")
        let n5 = note(t: 5, text: "ёлку купить")
        notepad.keptLines = [l0, l10]
        notepad.notes = [n5]

        notepad.searchQuery = "ёлку"
        notepad.refreshSearch(resetCurrent: true)

        XCTAssertEqual(notepad.matchLineIDs, [n5.id])
    }

    func testSpeakerNameIsNotSearched() {
        let notepad = NotepadModel()
        notepad.keptLines = [line(start: 0, text: "проверка связи", name: "Ada")]

        notepad.searchQuery = "Ada"
        notepad.refreshSearch(resetCurrent: true)

        XCTAssertEqual(notepad.matchLineIDs, [])
    }

    func testBlankQueryHasNoMatches() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "проверка связи")
        notepad.keptLines = [l0]
        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)
        XCTAssertFalse(notepad.matchLineIDs.isEmpty)
        XCTAssertNotNil(notepad.currentMatch)
        XCTAssertNotNil(notepad.highlightedLineID)

        notepad.searchQuery = "   "
        notepad.refreshSearch()

        XCTAssertEqual(notepad.matchLineIDs, [])
        XCTAssertNil(notepad.currentMatch)
        XCTAssertNil(notepad.highlightedLineID)
    }

    func testNewQueryStartsAtFirstMatch() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "проверка связи")
        let l10 = line(start: 10, text: "проверка звука")
        let l20 = line(start: 20, text: "вторая проверка")
        notepad.keptLines = [l0, l10, l20]

        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)

        XCTAssertEqual(notepad.matchLineIDs, [l0.id, l10.id, l20.id])
        XCTAssertEqual(notepad.currentMatch, 0)
        XCTAssertEqual(notepad.highlightedLineID, l0.id)
        XCTAssertFalse(notepad.isFollowingBottom)
    }

    func testStepWrapsAround() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "проверка связи")
        let l10 = line(start: 10, text: "проверка звука")
        let l20 = line(start: 20, text: "вторая проверка")
        notepad.keptLines = [l0, l10, l20]
        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)

        notepad.stepSearch(by: 1)
        XCTAssertEqual(notepad.currentMatch, 1)
        notepad.stepSearch(by: 1)
        XCTAssertEqual(notepad.currentMatch, 2)
        notepad.stepSearch(by: 1)
        XCTAssertEqual(notepad.currentMatch, 0, "did not wrap forward")
        XCTAssertEqual(notepad.highlightedLineID, l0.id)
        XCTAssertFalse(notepad.isFollowingBottom)

        notepad.stepSearch(by: -1)
        XCTAssertEqual(notepad.currentMatch, 2, "did not wrap backward")
        XCTAssertEqual(notepad.highlightedLineID, l20.id)
    }

    func testNewLinesKeepTheCurrentMatch() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "проверка связи")
        let l10 = line(start: 10, text: "проверка звука")
        let l20 = line(start: 20, text: "вторая проверка")
        notepad.keptLines = [l0, l10, l20]
        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)
        notepad.stepSearch(by: 1) // second match, l10
        XCTAssertEqual(notepad.highlightedLineID, l10.id)

        // Already false (as a step sets it): a plain recompute must not turn it on.
        notepad.notes = [note(t: 5, text: "проверка раньше")]
        let l30 = line(start: 30, text: "третья проверка")
        notepad.keptLines.append(l30)
        notepad.refreshSearch()

        XCTAssertEqual(notepad.highlightedLineID, l10.id, "the current match moved away from its line")
        XCTAssertEqual(notepad.currentMatch, notepad.matchLineIDs.firstIndex(of: l10.id))
        XCTAssertFalse(notepad.isFollowingBottom, "a plain refresh turned following back on")

        // The test sets it true (as "Jump to bottom" would): a plain refresh must not turn it off.
        notepad.isFollowingBottom = true
        notepad.keptLines.append(line(start: 40, text: "четвёртая проверка"))
        notepad.refreshSearch()
        XCTAssertTrue(notepad.isFollowingBottom, "a plain refresh turned following off")
    }

    func testCurrentMatchGoneClampsIndex() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "проверка связи")
        let l10 = line(start: 10, text: "проверка звука")
        let l20 = line(start: 20, text: "вторая проверка")
        notepad.keptLines = [l0, l10, l20]
        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)
        notepad.stepSearch(by: 1) // l10, index 1

        notepad.keptLines = [l0, l20]
        notepad.refreshSearch()

        XCTAssertEqual(notepad.matchLineIDs, [l0.id, l20.id])
        XCTAssertEqual(notepad.currentMatch, 1, "did not clamp to the new last index")
        XCTAssertEqual(notepad.highlightedLineID, l20.id)

        notepad.keptLines = []
        notepad.refreshSearch()

        XCTAssertEqual(notepad.matchLineIDs, [])
        XCTAssertNil(notepad.currentMatch)
        XCTAssertNil(notepad.highlightedLineID)
    }

    func testUnchangedRefreshPublishesNothing() {
        let notepad = NotepadModel()
        notepad.keptLines = [line(start: 0, text: "проверка связи")]
        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)

        var publishCount = 0
        let cancellable = notepad.objectWillChange.sink { _ in publishCount += 1 }
        defer { cancellable.cancel() }

        notepad.refreshSearch()

        XCTAssertEqual(publishCount, 0)
    }

    /// A moment drawn on its own line (`NotepadModel.resolvedMomentLines`,
    /// via `momentLineIDs`) must never also surface as a separate match: its
    /// words are already found through the line itself.
    func testAnAnchoredMomentIsNotASeparateMatch() {
        let notepad = NotepadModel()
        let l0 = line(start: 0, text: "важная строка")
        notepad.keptLines = [l0]
        let moment = MeetingNote(id: UUID(), t: 0, kind: .moment, text: "важная строка")
        notepad.notes = [moment]
        notepad.momentLineIDs = [moment.id: l0.id]

        notepad.searchQuery = "важная"
        notepad.refreshSearch(resetCurrent: true)

        XCTAssertEqual(notepad.matchLineIDs, [l0.id])
    }

    func testLiveModelLinesAreSearched() {
        let notepad = NotepadModel()
        notepad.keptLines = [line(start: 0, text: "это не должно найтись")]
        let model = LiveTranscriptModel()
        let liveLine = line(start: 0, text: "проверка связи")
        model.publishForTesting(lines: [liveLine], state: .running)
        notepad.liveModel = model

        notepad.searchQuery = "проверка"
        notepad.refreshSearch(resetCurrent: true)

        XCTAssertEqual(notepad.matchLineIDs, [liveLine.id])
    }
}
