import Combine
import KeyboardShortcuts
import XCTest
@testable import Murmurly

private actor FakeNotepadCapture: MeetingCaptureBackend {
    private let secondsToReport: TimeInterval?

    init(secondsToReport: TimeInterval? = nil) {
        self.secondsToReport = secondsToReport
    }

    func start(in directory: URL) async throws -> Date { Date(timeIntervalSinceReferenceDate: 0) }
    func stop() async throws -> [URL] { [] }
    func writtenSeconds() async -> TimeInterval? { secondsToReport }
}

@MainActor
final class NotepadModelTests: XCTestCase {
    private func isolatedSettings() -> SettingsStore {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.NotepadModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return SettingsStore(defaults: defaults)
    }

    private func recorder(seconds: TimeInterval? = nil) -> MeetingRecorder {
        MeetingRecorder(
            capture: FakeNotepadCapture(secondsToReport: seconds),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
    }

    private func line(start: Double, isFinal: Bool = true) -> LiveLine {
        LiveLine(id: UUID(), track: .microphone, start: start, end: start + 1, rawText: "x", displayText: "x", name: nil, isFinal: isFinal)
    }

    private func note(t: Double?, text: String = "заметка") -> MeetingNote {
        MeetingNote(id: UUID(), t: t, kind: .note, text: text)
    }

    private func moment(id: UUID = UUID(), t: Double?, text: String) -> MeetingNote {
        MeetingNote(id: id, t: t, kind: .moment, text: text)
    }

    // MARK: - `NotepadFeedItem.merge`

    func testMergeOrdersNotesBetweenLinesByTime() {
        let l0 = line(start: 0)
        let l10 = line(start: 10)
        let l20 = line(start: 20)
        let n5 = note(t: 5, text: "в пять")
        let n15 = note(t: 15, text: "в пятнадцать")

        let feed = NotepadFeedItem.merge(lines: [l0, l10, l20], notes: [n15, n5])

        XCTAssertEqual(feed, [.line(l0), .note(n5), .line(l10), .note(n15), .line(l20)])
    }

    func testMergePutsNotesWithoutTimeLast() {
        let l0 = line(start: 0)
        let timed = note(t: 100, text: "позже всех строк")
        let untimed = note(t: nil, text: "без времени")

        let feed = NotepadFeedItem.merge(lines: [l0], notes: [untimed, timed])

        XCTAssertEqual(feed, [.line(l0), .note(timed), .note(untimed)])
    }

    func testMergeOnEqualTimePutsTheLineFirst() {
        let l10 = line(start: 10)
        let tie = note(t: 10, text: "совпадает по времени")

        let feed = NotepadFeedItem.merge(lines: [l10], notes: [tie])

        XCTAssertEqual(feed, [.line(l10), .note(tie)])
    }

    /// The model always keeps an interim line after every final one, even
    /// when its own `start` is earlier than the final line's — a full sort
    /// by time would reorder today's panel. Without notes, `merge` must not
    /// touch that order.
    func testMergeWithoutNotesKeepsTheModelsOrder() {
        let final = line(start: 10, isFinal: true)
        let interim = line(start: 5, isFinal: false)

        let feed = NotepadFeedItem.merge(lines: [final, interim], notes: [])

        XCTAssertEqual(feed, [.line(final), .line(interim)])
    }

    // MARK: - A moment drawn on its own line (`NotepadFeedItem.momentLines`/`merge(anchored:)`)

    /// A moment the feed resolves to a line (`anchored`) must not also show
    /// up as its own `.note` item — the whole point of drawing it on the
    /// line instead.
    func testAnchoredMomentIsNotASeparateFeedItem() {
        let l0 = line(start: 0)
        let m = moment(t: 0, text: "важное")

        let feed = NotepadFeedItem.merge(lines: [l0], notes: [m], anchored: [m.id])

        XCTAssertEqual(feed, [.line(l0)])
    }

    /// The anchor set when the moment was made (`momentLineIDs`) may point
    /// at an id no longer among the lines (the final line got a fresh
    /// `UUID`): the fallback is a line whose own `start` equals the
    /// moment's `t`.
    func testMomentFallsBackToTheLineWithItsStartWhenTheIdIsGone() {
        let l0 = line(start: 5)
        let m = moment(t: 5, text: "важное")

        let resolved = NotepadFeedItem.momentLines(lines: [l0], notes: [m], anchors: [m.id: UUID()])

        XCTAssertEqual(resolved[m.id], l0.id)
    }

    /// Two tracks' chunks can open at the very same quantized `start`; with
    /// no anchor at all the one whose own words contain the moment's is
    /// preferred over the first candidate.
    func testMomentWithTheSameStartOnTwoTracksPrefersTheLineWithItsWords() {
        let system = LiveLine(id: UUID(), track: .system, start: 5, end: 6, rawText: "другое", displayText: "другое", name: nil, isFinal: true)
        let mic = LiveLine(id: UUID(), track: .microphone, start: 5, end: 6, rawText: "важное слово", displayText: "важное слово", name: nil, isFinal: true)
        let m = moment(t: 5, text: "важное")

        let resolved = NotepadFeedItem.momentLines(lines: [system, mic], notes: [m], anchors: [:])

        XCTAssertEqual(resolved[m.id], mic.id)
    }

    /// A moment whose line is gone entirely (no anchor, no line at that
    /// `start`) is left out of `momentLines`, so `merge` shows it as its own
    /// row again — nothing is lost.
    func testMomentWhoseLineIsGoneIsItsOwnFeedItem() {
        let m = moment(t: 99, text: "пропавшая строка")

        let resolved = NotepadFeedItem.momentLines(lines: [], notes: [m], anchors: [:])
        XCTAssertTrue(resolved.isEmpty)

        let feed = NotepadFeedItem.merge(lines: [], notes: [m], anchored: Set(resolved.keys))
        XCTAssertEqual(feed, [.note(m)])
    }

    /// The anchor by id holds even once an interim line's text changed and
    /// no longer contains the moment's words — only the highlight is lost,
    /// never the line it is drawn on.
    func testMomentStaysOnItsLineAfterTheInterimTextChanged() {
        let l = LiveLine(id: UUID(), track: .microphone, start: 3, end: 4, rawText: "ещё не всё", displayText: "ещё не всё", name: nil, isFinal: false)
        let m = moment(t: 3, text: "важные слова")

        let resolved = NotepadFeedItem.momentLines(lines: [l], notes: [m], anchors: [m.id: l.id])

        XCTAssertEqual(resolved[m.id], l.id)
    }

    /// With no moment carrying words at all (an ordinary note, or a moment
    /// whose text is empty), `momentLines` must never force `lines()` to
    /// run — the feed's own cost with up to 5000 lines and no moments.
    func testMomentLinesWithoutMomentsNeverReadsTheLines() {
        var read = false
        func lines() -> [LiveLine] {
            read = true
            return [line(start: 0)]
        }

        let ordinary = note(t: 0, text: "обычная заметка")
        let emptyMoment = moment(t: 0, text: "")

        let resolved = NotepadFeedItem.momentLines(lines: lines(), notes: [ordinary, emptyMoment], anchors: [:])
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertFalse(read, "no moment carries words — the lines must never be read")

        let realMoment = moment(t: 0, text: "важное")
        let resolvedWithMoment = NotepadFeedItem.momentLines(lines: lines(), notes: [realMoment], anchors: [:])
        XCTAssertFalse(resolvedWithMoment.isEmpty)
        XCTAssertTrue(read, "a moment with words must read the lines")
    }

    // MARK: - `resetForMeeting` drops the selection and the anchors

    func testResetForMeetingDropsSelectionAndAnchors() {
        let notepad = NotepadModel()
        notepad.lineSelection = NotepadLineSelection(lineID: UUID(), start: 1, range: NSRange(location: 0, length: 3), text: "abc")
        notepad.momentLineIDs = [UUID(): UUID()]

        notepad.resetForMeeting()

        XCTAssertNil(notepad.lineSelection)
        XCTAssertTrue(notepad.momentLineIDs.isEmpty)
    }

    // MARK: - Forwarding the live model's changes

    func testNotepadForwardsTheLiveModelsChanges() async throws {
        let notepad = NotepadModel()
        let model = LiveTranscriptModel()
        notepad.liveModel = model
        let expectation = XCTestExpectation(description: "the notepad republished")
        let cancellable = notepad.objectWillChange.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        model.publishForTesting(lines: [line(start: 0)], state: .running)

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testPanelHandsTheRecordingsModelToItsNotepad() async throws {
        let settings = isolatedSettings()
        let recorder = recorder()
        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)
        let model = LiveTranscriptModel()

        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        XCTAssertTrue(panel.notepad.liveModel === model)
    }

    // MARK: - `MeetingRecorder.recordingSeconds()`

    func testRecordingSecondsComeFromTheCaptureOnlyWhileRecording() async throws {
        let recorder = recorder(seconds: 42.5)

        let idle = await recorder.recordingSeconds()
        XCTAssertNil(idle, "idle, before any recording")

        recorder.publishLiveTranscriptForTesting(state: .recording, model: nil)
        let recording = await recorder.recordingSeconds()
        XCTAssertEqual(recording, 42.5)
    }

    // MARK: - `KeyboardShortcuts.Name.markMoment`

    func testMarkMomentHasNoInitialShortcutInATestProcess() {
        XCTAssertNil(KeyboardShortcuts.Name.markMoment.initialShortcut)
    }

    // MARK: - `SettingsStore.liveTranscriptKeepOnTop`

    func testKeepOnTopDefaultsOffAndWritesNothing() {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.KeepOnTopDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        XCTAssertFalse(settings.liveTranscriptKeepOnTop)
        XCTAssertNil(defaults.object(forKey: "liveTranscript.keepOnTop"))
    }
}
