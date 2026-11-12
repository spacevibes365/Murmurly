import Combine
import KeyboardShortcuts
import XCTest
@testable import Murmurly

/// Records into the folder the recorder made; a copy of `LibraryCapture`
/// (`MeetingLibraryNotesTests.swift`), kept private to this file.
private actor NotesInputCapture: MeetingCaptureBackend {
    private var directory: URL?
    private var secondsToReport: Double?

    func setSeconds(_ seconds: Double?) { secondsToReport = seconds }

    func start(in directory: URL) async throws -> Date {
        for name in ["system.caf", "microphone.caf"] {
            try MeetingAudio.write([[Float](repeating: 0, count: 4_800)], to: directory.appendingPathComponent(name))
        }
        self.directory = directory
        return Date()
    }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        self.directory = nil
        let metadata = MeetingMetadata(
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:30Z", sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }

    func writtenSeconds() async -> TimeInterval? { secondsToReport }
}

/// A reader whose `writeMarks` is a test's own closure, the rest the real
/// disk; a copy of the same-named helper in `MeetingLibraryNotesTests.swift`,
/// kept private to this file.
private func reader(writeMarks: @escaping MeetingLibrary.Reader.MarksWrite) -> MeetingLibrary.Reader {
    MeetingLibrary.Reader(
        root: { MeetingLibrary.readRoot($0, place: $1) },
        meeting: { MeetingLibrary.readOutside($0) },
        text: { try String(contentsOf: $0, encoding: .utf8) },
        writeMarks: writeMarks
    )
}

/// Writes the first note for real (the add that must land), then refuses
/// the second and third each with their own wording, so a test can tell an
/// edit's refusal and a delete's refusal apart.
private final class NotesFailureScript: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func writeMarks(_ change: MeetingMarks.Change, _ folder: URL, _ identity: FolderIdentity) throws -> MeetingMarks {
        let call: Int = lock.withLock {
            calls += 1
            return calls
        }
        guard call > 1 else {
            return try MeetingMarks.write(change, in: folder, expecting: identity)
        }
        throw Failure(message: call == 2 ? "edit refused for the test" : "delete refused for the test")
    }
}

/// Refuses exactly the 2nd write and lets every other one land for real:
/// the add lands first, then the next operation (an edit or a delete) is
/// refused, then a further one of the same kind must still land — this is
/// what tells an operation refused right after a landed add apart from one
/// refused while the add itself never landed.
private final class FailSecondWriteThenSucceed: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    private struct Failure: LocalizedError {
        var errorDescription: String? { "refused for the test" }
    }

    func writeMarks(_ change: MeetingMarks.Change, _ folder: URL, _ identity: FolderIdentity) throws -> MeetingMarks {
        let call: Int = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 2 else {
            return try MeetingMarks.write(change, in: folder, expecting: identity)
        }
        throw Failure()
    }
}

/// Refuses the first write (the add) and lets every later one land for
/// real, so a test can tell an add that never reached disk from a retry
/// that does.
private final class FailFirstWriteThenSucceed: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    private struct Failure: LocalizedError {
        var errorDescription: String? { "add refused for the test" }
    }

    func writeMarks(_ change: MeetingMarks.Change, _ folder: URL, _ identity: FolderIdentity) throws -> MeetingMarks {
        let call: Int = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 1 else {
            return try MeetingMarks.write(change, in: folder, expecting: identity)
        }
        throw Failure()
    }
}

/// The notepad's typing, ★/⌥⇧M, editing, deleting and their test isolation.
@MainActor
final class NotesInputViewTests: XCTestCase {
    private var root: URL!
    private var local: URL!
    private var settings: SettingsStore!
    private var keepAlive: [AnyObject] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-input-\(UUID().uuidString)", isDirectory: true)
        local = root.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
        settings.meetingAfterStop = .nothing
    }

    override func tearDown() async throws {
        keepAlive = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Time captured on the first character, not on Return

    /// `stamp()` is asked while the recording's clock still reads 12; its
    /// `value` is awaited right there, forcing the one read to actually run
    /// before the clock moves to 30 — the sequence the round-trip
    /// requires, or a wrong implementation that reads the clock again at
    /// Enter would also pass by accident.
    func testNoteTimeIsCapturedOnFirstCharacterNotOnReturn() async throws {
        var clock = 12.0
        let stamp = NoteDraftStamp(recordingSeconds: { clock })

        stamp.stamp()
        let capturedWhileStillTwelve = await stamp.value
        XCTAssertEqual(capturedWhileStillTwelve, 12)

        clock = 30
        let atSubmit = await stamp.value
        XCTAssertEqual(atSubmit, 12, "the time must stay what it was on the first character, not move to Enter's clock")
    }

    /// A later character does nothing: the stream was already started.
    func testStampIgnoresACallAfterTheFirst() async throws {
        var clock = 5.0
        let stamp = NoteDraftStamp(recordingSeconds: { clock })
        stamp.stamp()
        _ = await stamp.value
        clock = 99
        stamp.stamp()
        let value = await stamp.value
        XCTAssertEqual(value, 5)
    }

    /// The field's own rule (`NoteDraftController`), not the bare stamp:
    /// clearing the field back to empty drops the stamp, and the next first
    /// character starts a new one at the clock's new reading.
    func testControllerDropsTheStampWhenTheFieldGoesEmptyThenStampsAgain() async throws {
        var clock = 10.0
        let notepad = NotepadModel()
        notepad.noteServices = NotepadNoteServices(
            recordingSeconds: { clock }, addNote: { _ in nil }, editNote: { _, _ in nil }, deleteNote: { _ in nil },
            addHasNotLanded: { _ in false }
        )
        // The draft takes the recording's own clock only while the notepad
        // is on the recording itself.
        notepad.meeting = NotepadMeeting(identity: nil, folder: URL(fileURLWithPath: "/tmp/Meeting"), startedAt: nil, isRecording: true)
        let controller = NoteDraftController(notepad: notepad)

        controller.text = "О"
        controller.textDidChange()
        try await until { controller.hasStampForTesting }

        controller.text = ""
        controller.textDidChange()
        XCTAssertFalse(controller.hasStampForTesting, "an emptied field must drop the stamp")

        clock = 77
        controller.text = "П"
        controller.textDidChange()
        try await until { controller.hasStampForTesting }

        controller.text = "Проверить меню"
        controller.textDidChange()
        controller.submit()
        try await until { notepad.notes.contains { $0.text == "Проверить меню" } }
        XCTAssertEqual(notepad.notes.first { $0.text == "Проверить меню" }?.t, 77, "the new first character must stamp the clock's new reading, not the first one")
    }

    /// A genuinely new meeting drops a draft left in the field: Return on
    /// the field afterward must not deliver A's unfinished text to B.
    func testANewMeetingClearsTheNoteDraft() async throws {
        let notepad = NotepadModel()
        let controller = NoteDraftController(notepad: notepad)

        controller.text = "про первую встречу"
        controller.textDidChange()
        try await until { controller.hasStampForTesting }

        notepad.resetForMeeting()

        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.hasStampForTesting)
    }

    // MARK: - ★ and ⌥⇧M write into the recording under way, never the
    // meeting the notepad happens to show

    /// ★, through `notepad.markMoment()`, with the notepad on the very
    /// recording under way: the moment lands in the feed and on disk.
    func testMarkMomentAddsATimedMomentWithNoText() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(42)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)
        let folder = try XCTUnwrap(recorder.currentSession).directory

        notepad.markMoment()
        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 42 && $0.text == "" } }

        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertTrue(marks.notes.contains { $0.kind == .moment && $0.t == 42 })

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The race the press and the `Task` run into: the recording ends
    /// between the ★/⌥⇧M press and the clock actually being read, so
    /// `recordingSeconds()` answers nil (the real recorder's own rule).
    /// Nothing must be added — never a moment with no time.
    func testMarkMomentAddsNothingWhenTheClockAnswersNilByTheTimeItIsRead() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(nil)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)
        let folder = try XCTUnwrap(recorder.currentSession).directory

        notepad.markMoment()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(notepad.notes.isEmpty, "nothing must be added when the clock has nothing to report")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path))

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The notepad is left on a stopped meeting A (live text off, say) while
    /// a different meeting B is being recorded: ★/⌥⇧M must still write into
    /// B, the recording under way, never into A.
    func testMarkMomentShortcutWritesIntoTheRecordingNotTheNotepadsStoppedMeeting() async throws {
        let a = try seed("2026-10-06 10-00-00 Meeting")
        let notepad = NotepadModel()
        notepad.meeting = NotepadMeeting(identity: FolderIdentity.of(a), folder: a, startedAt: nil, isRecording: false)
        let capture = NotesInputCapture()
        await capture.setSeconds(7)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        let manager = HotkeyManager()
        let hotkey = MarkMomentHotkey(manager: manager, recorder: recorder)
        hotkey.onMarkMoment = { [weak notepad] in notepad?.markMoment() }
        withExtendedLifetime((notes, hotkey)) {}

        let shortcut = KeyboardShortcuts.Shortcut(.m, modifiers: [.option, .shift])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(shortcut), encoding: .utf8))
        try await withMarkMomentShortcut(stored) {
            recorder.toggle()
            try await until { recorder.state == .recording }
            XCTAssertTrue(manager.pressMarkMomentForTesting())
            let b = try XCTUnwrap(recorder.currentSession).directory
            try await until { notesWritten(in: b).contains { $0.kind == .moment && $0.t == 7 } }

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: a.appendingPathComponent(MeetingMarks.fileName).path),
                "the meeting shown in the notepad must not get the moment"
            )
            XCTAssertTrue(notepad.notes.isEmpty, "the notepad, still on A, never shows B's moment")

            recorder.toggle()
            try await until { recorder.state == .idle }
        }
    }

    /// Same as above, with no meeting at all open in the notepad: the
    /// moment still lands in the recording under way.
    func testMarkMomentShortcutWithNoNotepadMeetingStillLandsInTheRecording() async throws {
        let notepad = NotepadModel()
        notepad.meeting = nil
        let capture = NotesInputCapture()
        await capture.setSeconds(9)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        let manager = HotkeyManager()
        let hotkey = MarkMomentHotkey(manager: manager, recorder: recorder)
        hotkey.onMarkMoment = { [weak notepad] in notepad?.markMoment() }
        withExtendedLifetime((notes, hotkey)) {}

        let shortcut = KeyboardShortcuts.Shortcut(.m, modifiers: [.option, .shift])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(shortcut), encoding: .utf8))
        try await withMarkMomentShortcut(stored) {
            recorder.toggle()
            try await until { recorder.state == .recording }
            XCTAssertTrue(manager.pressMarkMomentForTesting())
            let b = try XCTUnwrap(recorder.currentSession).directory
            try await until { notesWritten(in: b).contains { $0.kind == .moment && $0.t == 9 } }

            recorder.toggle()
            try await until { recorder.state == .idle }
        }
    }

    // MARK: - ★ with a line selected marks that line, not the clock

    /// ★ with words selected in a line of the feed: the moment's `t` is the
    /// line's own `start`, never the clock, and its text is the selected
    /// words — trimmed, even though `lineSelection.text` here carries its
    /// raw, untrimmed spaces (as a real selection reaching past the words
    /// would). The selection is consumed: `lineSelection` goes back to nil
    /// and the line is remembered as the moment's own (`momentLineIDs`).
    func testMarkMomentWithASelectionTakesTheLinesStartAndTheSelectedWords() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(999) // must never be read: this path never asks the clock
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)
        let folder = try XCTUnwrap(recorder.currentSession).directory

        let l1 = LiveLine(
            id: UUID(), track: .microphone, start: 3, end: 4,
            rawText: "Обсудим бюджет на квартал", displayText: "Обсудим бюджет на квартал", name: nil, isFinal: true
        )
        let l2 = LiveLine(
            id: UUID(), track: .microphone, start: 9, end: 10,
            rawText: "Сроки сдвигаем на пятницу", displayText: "Сроки сдвигаем на пятницу", name: nil, isFinal: true
        )
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1, l2], state: .running)
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        notepad.lineSelection = NotepadLineSelection(
            lineID: l1.id, start: l1.start, range: NSRange(location: 0, length: 0), text: "  бюджет на квартал "
        )

        notepad.markMoment()

        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 3 && $0.text == "бюджет на квартал" } }
        let added = try XCTUnwrap(notepad.notes.first { $0.kind == .moment && $0.t == 3 })
        XCTAssertEqual(notepad.momentLineIDs[added.id], l1.id)
        XCTAssertNil(notepad.lineSelection)

        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertTrue(marks.notes.contains { $0.kind == .moment && $0.t == 3 && $0.text == "бюджет на квартал" })

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// ★ with nothing selected takes the newest (bottommost) non-empty line
    /// of the recording's own live model, a fresh one, not the clock.
    func testMarkMomentWithoutASelectionTakesTheNewestLineWhole() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(12)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        let l1 = LiveLine(id: UUID(), track: .microphone, start: 3, end: 4, rawText: "первая строка", displayText: "первая строка", name: nil, isFinal: true)
        let l2 = LiveLine(id: UUID(), track: .microphone, start: 9, end: 10, rawText: "Сроки сдвигаем на пятницу", displayText: "Сроки сдвигаем на пятницу", name: nil, isFinal: true)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1, l2], state: .running)
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        notepad.markMoment()

        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 9 && $0.text == "Сроки сдвигаем на пятницу" } }

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// ⌥⇧M (`usingSelection: false`) always takes the newest line, even with
    /// a selection left in the feed: it is pressed from the call, where a
    /// selection in the feed may be stale.
    func testMarkMomentShortcutIgnoresTheSelectionAndTakesTheNewestLine() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(12)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        let l1 = LiveLine(id: UUID(), track: .microphone, start: 3, end: 4, rawText: "старое выделение", displayText: "старое выделение", name: nil, isFinal: true)
        let l2 = LiveLine(id: UUID(), track: .microphone, start: 9, end: 10, rawText: "самая свежая строка", displayText: "самая свежая строка", name: nil, isFinal: true)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1, l2], state: .running)
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)
        notepad.lineSelection = NotepadLineSelection(lineID: l1.id, start: l1.start, range: NSRange(location: 0, length: 0), text: "старое выделение")

        notepad.markMoment(usingSelection: false)

        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 9 && $0.text == "самая свежая строка" } }
        XCTAssertFalse(notepad.notes.contains { $0.text == "старое выделение" })

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The notepad shows a *stopped* meeting A, with a selection left in one
    /// of its own (now frozen) lines, while a different recording B runs:
    /// ★ must still take B's newest line whole — never A's selection, which
    /// does not even belong to the recording under way.
    func testMarkMomentWithASelectionWhileTheNotepadShowsAnotherMeetingTakesTheNewestLineOfTheRecording() async throws {
        let a = try seed("2026-10-06 10-00-00 Meeting")
        let notepad = NotepadModel()
        notepad.meeting = NotepadMeeting(identity: FolderIdentity.of(a), folder: a, startedAt: nil, isRecording: false)
        let capture = NotesInputCapture()
        await capture.setSeconds(12)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        let b = try XCTUnwrap(recorder.currentSession).directory

        let l1 = LiveLine(id: UUID(), track: .microphone, start: 3, end: 4, rawText: "строка А", displayText: "строка А", name: nil, isFinal: true)
        let l2 = LiveLine(id: UUID(), track: .microphone, start: 9, end: 10, rawText: "строка Б свежая", displayText: "строка Б свежая", name: nil, isFinal: true)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1, l2], state: .running)
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        notepad.lineSelection = NotepadLineSelection(lineID: l1.id, start: l1.start, range: NSRange(location: 0, length: 0), text: "строка А")

        notepad.markMoment()

        try await until { notesWritten(in: b).contains { $0.kind == .moment && $0.t == 9 && $0.text == "строка Б свежая" } }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: a.appendingPathComponent(MeetingMarks.fileName).path),
            "the meeting shown in the notepad must not get the moment"
        )
        XCTAssertTrue(notepad.notes.isEmpty, "the notepad, still on A, never shows B's moment")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    // MARK: - ★ without a selection: only a fresh line, else the clock

    /// The newest line ended 51 s before the clock — far past
    /// `NotepadNotes.momentLineFreshness` (10 s) — so the moment takes the
    /// clock, with no text, exactly as it would with no lines at all.
    func testMarkMomentWithoutASelectionTakesTheClockWhenTheNewestLineIsStale() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(60)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        let l1 = LiveLine(id: UUID(), track: .microphone, start: 3, end: 4, rawText: "давняя строка до паузы", displayText: "давняя строка до паузы", name: nil, isFinal: true)
        let l2 = LiveLine(id: UUID(), track: .microphone, start: 9, end: 10, rawText: "старая строка", displayText: "старая строка", name: nil, isFinal: true)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1, l2], state: .running)
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        notepad.markMoment()

        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 60 && $0.text.isEmpty } }
        XCTAssertFalse(notepad.notes.contains { $0.t == 9 })

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The live text has `.stopped` (three failed chunks in a row): even
    /// though the newest line is well within the freshness window, nothing
    /// more will be recognized, so the moment takes the clock, with no text.
    func testMarkMomentShortcutTakesTheClockWhenTheLiveTextHasStopped() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(12)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        let l1 = LiveLine(id: UUID(), track: .microphone, start: 9, end: 10, rawText: "строка до сбоя", displayText: "строка до сбоя", name: nil, isFinal: true)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1], state: .stopped("recognition failed"))
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        notepad.markMoment(usingSelection: false)

        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 12 && $0.text.isEmpty } }
        XCTAssertFalse(notepad.notes.contains { $0.t == 9 })

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The newest line ends exactly 10 s before the clock — the freshness
    /// window's own boundary, included: the moment is the line, whole.
    func testMarkMomentWithoutASelectionTakesAFreshLineWhole() async throws {
        let capture = NotesInputCapture()
        await capture.setSeconds(20)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        let l1 = LiveLine(id: UUID(), track: .microphone, start: 9, end: 10, rawText: "свежая строка", displayText: "свежая строка", name: nil, isFinal: true)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: [l1], state: .running)
        recorder.publishLiveTranscriptForTesting(state: .recording, model: model)

        notepad.markMoment()

        try await until { notepad.notes.contains { $0.kind == .moment && $0.t == 9 && $0.text == "свежая строка" } }

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A note's draft started on a stopped meeting A must not take the time
    /// of a different recording B under way at the same moment.
    func testANoteDraftOnAStoppedMeetingTakesNoTimeFromAnotherRecording() async throws {
        let a = try seed("2026-10-06 10-00-00 Meeting")
        let notepad = NotepadModel()
        notepad.meeting = NotepadMeeting(identity: FolderIdentity.of(a), folder: a, startedAt: nil, isRecording: false)
        let capture = NotesInputCapture()
        await capture.setSeconds(33)
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}
        recorder.toggle()
        try await until { recorder.state == .recording }

        let controller = NoteDraftController(notepad: notepad)
        controller.text = "про первую встречу"
        controller.textDidChange()
        controller.submit()
        try await until { notepad.notes.contains { $0.text == "про первую встречу" } }

        XCTAssertNil(notepad.notes.first { $0.text == "про первую встречу" }?.t, "a draft on a stopped meeting takes no time from another recording")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The seam: a concrete shortcut, never a real hotkey, delivered through
    /// `pressMarkMomentForTesting()`. Waited for, not read right after the
    /// press: the task iterating the stand-in stream only runs once this
    /// method itself yields (the stream's `Task` is spawned, not awaited).
    func testMarkMomentHotkeySeamFiresOnlyWhileOpen() async throws {
        let manager = HotkeyManager()
        var calls = 0
        let shortcut = KeyboardShortcuts.Shortcut(.m, modifiers: [.option, .shift])

        XCTAssertFalse(manager.pressMarkMomentForTesting(), "nothing is open yet")

        manager.listenForMarkMoment(shortcut) { calls += 1 }
        XCTAssertTrue(manager.isMarkMomentListenerOpenForTesting)
        XCTAssertTrue(manager.pressMarkMomentForTesting())
        try await until { calls == 1 }

        manager.listenForMarkMoment(nil) {}
        XCTAssertFalse(manager.isMarkMomentListenerOpenForTesting)
        XCTAssertFalse(manager.pressMarkMomentForTesting(), "closed, so the seam has nothing to deliver to")
    }

    /// `MarkMomentHotkey` opens the listener only while the recorder is
    /// `.recording`, and closes it the moment it is not — the same
    /// open/closed life as the dictation's Esc listener.
    func testMarkMomentHotkeyOpensOnlyWhileRecording() throws {
        let recorder = makeRecorder()
        let manager = HotkeyManager()
        let hotkey = MarkMomentHotkey(manager: manager, recorder: recorder)
        withExtendedLifetime(hotkey) {}

        XCTAssertFalse(manager.isMarkMomentListenerOpenForTesting, "idle: not registered")

        let shortcut = KeyboardShortcuts.Shortcut(.m, modifiers: [.option, .shift])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(shortcut), encoding: .utf8))
        withMarkMomentShortcut(stored) {
            recorder.publishLiveTranscriptForTesting(state: .recording, model: nil)
            XCTAssertTrue(manager.isMarkMomentListenerOpenForTesting, "recording: registered")

            recorder.publishLiveTranscriptForTesting(state: .idle, model: nil)
            XCTAssertFalse(manager.isMarkMomentListenerOpenForTesting, "stopped: unregistered again")
        }
    }

    /// `KeyboardShortcuts` reads only `UserDefaults.standard`; the unit-test
    /// host's own live domain, so a test overrides the shortcut only in the
    /// process's volatile argument domain — never written to disk — the same
    /// pattern as `IndicatorTests.withMeetingShortcut`.
    private func withMarkMomentShortcut(_ value: Any, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overridden = original
        overridden["KeyboardShortcuts_markMoment"] = value
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        try body()
    }

    /// An async counterpart: the shortcut must be in place for the whole
    /// span of a body that itself awaits the recorder reaching `.recording`.
    private func withMarkMomentShortcut(_ value: Any, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overridden = original
        overridden["KeyboardShortcuts_markMoment"] = value
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        try await body()
    }

    /// The marks' notes array, or empty when the file does not read: lets an
    /// `until` condition poll a folder's `murmurly.json` without throwing.
    private func notesWritten(in folder: URL) -> [MeetingNote] {
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return [] }
        return marks.notes
    }

    // MARK: - Edit and delete through the library; a refusal keeps the text

    /// A note added, edited and deleted through a real `MeetingLibrary`
    /// lands, changes and leaves the feed, via `NotepadNotes.attach`'s own
    /// reconcile — never a local shortcut around it.
    func testEditAndDeleteGoThroughTheLibraryAndUpdateTheFeed() async throws {
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 5))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка")

        notepad.editNote(id: id, text: "Планёрка перенесена")
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка перенесена")

        notepad.requestDelete(id: id)
        try await until { !notepad.notes.contains { $0.id == id } }

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A refused add (the recording never started: `noteServices` reads
    /// `notepad.meeting` as nil) keeps the typed text in the feed with the
    /// reason — nothing is lost silently.
    func testARefusedAddKeepsTheTextAndTheReason() throws {
        let notepad = NotepadModel()
        XCTAssertNil(notepad.noteServices)

        let id = try XCTUnwrap(notepad.submitNote(text: "Без блокнота", t: nil))

        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Без блокнота")
        XCTAssertEqual(notepad.noteFailures[id], "The meeting folder isn’t available.")
    }

    /// A note already on disk, a failed edit that leaves its own reason,
    /// then a delete refused with a different one: the row must keep its
    /// text and show the delete's reason — the id must never be dropped
    /// from the feed before the reconcile that reads the library's real
    /// `pendingNotes`/`noteFailures` says it settled clean.
    func testAFailedDeleteAfterAFailedEditKeepsTheRowWithTheNewReason() async throws {
        let recorder = makeRecorder()
        let script = NotesFailureScript()
        let library = makeLibrary(recorder: recorder, reader: reader(writeMarks: script.writeMarks))
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)
        // The add is the script's 1st call: written for real.
        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 1))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        // The edit is the script's 2nd call: refused with its own wording.
        notepad.editNote(id: id, text: "Правка после отказа")
        try await until { notepad.noteFailures[id] == "edit refused for the test" }

        // The delete is the script's 3rd call: a different refusal. If the
        // library's own `dismissNoteFailure` (synchronous, at the top of
        // `changeNotes`) were reconciled on its own, the row would vanish
        // between the two refusals instead of ending up
        // here with the new reason.
        notepad.requestDelete(id: id)
        try await until { notepad.noteFailures[id] == "delete refused for the test" }

        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "the row must still be there to show the new reason")
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Правка после отказа")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// While an add has not yet landed on disk (it was refused), an edit of
    /// that same note must resend as another add with the new text — not
    /// as an edit, which the writer has nothing written to apply to yet.
    /// Once the writer is alive again, the new text must actually reach the
    /// disk and the failure must lift.
    func testEditResendsAsAddWhileTheOriginalAddHasNotLanded() async throws {
        let recorder = makeRecorder()
        let script = FailFirstWriteThenSucceed()
        let library = makeLibrary(recorder: recorder, reader: reader(writeMarks: script.writeMarks))
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        // The add is the script's 1st call: refused.
        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 1))
        try await until { notepad.noteFailures[id] == "add refused for the test" }

        // The edit resends as an add — the script's 2nd call — which lands.
        notepad.editNote(id: id, text: "Планёрка перенесена")
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка перенесена")

        let folder = try XCTUnwrap(notepad.meeting?.folder)
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes.first { $0.id == id }?.text, "Планёрка перенесена", "the retried add must actually be the text on disk")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A note already on disk (its add landed), then an edit refused, then
    /// a second edit once the writer is alive again: the second edit must
    /// go as an ordinary edit (the add already landed) and must actually
    /// reach the disk with the new text, lifting the refusal. Before the
    /// fix, `editNote` took "the id has any past failure" as "the add has
    /// not landed", so this second edit was wrongly resent as another add —
    /// which a landed id's own writer silently skips, leaving the old text
    /// on disk under a note that looked saved.
    func testEditAfterARefusedEditWritesTheNewTextOnceTheWriterIsAlive() async throws {
        let recorder = makeRecorder()
        let script = FailSecondWriteThenSucceed()
        let library = makeLibrary(recorder: recorder, reader: reader(writeMarks: script.writeMarks))
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        // The add is the script's 1st call: written for real.
        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 1))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        // The edit is the script's 2nd call: refused.
        notepad.editNote(id: id, text: "Правка отказана")
        try await until { notepad.noteFailures[id] == "refused for the test" }

        // The 2nd edit is the script's 3rd call: lands, as a plain edit —
        // the add already landed, so this must not resend as an add.
        notepad.editNote(id: id, text: "Правка прошла")
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Правка прошла")

        let folder = try XCTUnwrap(notepad.meeting?.folder)
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes.first { $0.id == id }?.text, "Правка прошла", "the second edit must actually reach disk")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A note already on disk, a delete refused, then an edit: the row must
    /// stay in the feed (a refused delete must never queue the row for
    /// removal on some later, unrelated clean outcome) and the edit must
    /// actually reach disk with the new text.
    func testEditAfterARefusedDeleteKeepsTheRowAndWritesTheNewText() async throws {
        let recorder = makeRecorder()
        let script = FailSecondWriteThenSucceed()
        let library = makeLibrary(recorder: recorder, reader: reader(writeMarks: script.writeMarks))
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        // The add is the script's 1st call: written for real.
        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 1))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        // The delete is the script's 2nd call: refused.
        notepad.requestDelete(id: id)
        try await until { notepad.noteFailures[id] == "refused for the test" }
        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "a refused delete must keep the row")

        // The edit is the script's 3rd call: lands.
        notepad.editNote(id: id, text: "Правка после отказа удаления")
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "the row must still be there after the edit lands")
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Правка после отказа удаления")

        let folder = try XCTUnwrap(notepad.meeting?.folder)
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(
            marks.notes.first { $0.id == id }?.text, "Правка после отказа удаления",
            "the edit must actually reach disk, not be mistaken for a landed delete"
        )

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A note already on disk, a delete refused, then a second delete once
    /// the writer is alive again: the row must leave the feed and the note
    /// must actually be gone from disk. Before the fix, `deletingNoteIDs`
    /// was marked on the first (refused) delete already, so an unrelated
    /// later clean outcome for this id could remove the row while the note
    /// was still on disk.
    func testDeleteAfterARefusedDeleteRemovesTheRowAndTheNoteOnDisk() async throws {
        let recorder = makeRecorder()
        let script = FailSecondWriteThenSucceed()
        let library = makeLibrary(recorder: recorder, reader: reader(writeMarks: script.writeMarks))
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)

        // The add is the script's 1st call: written for real.
        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 1))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        // The delete is the script's 2nd call: refused.
        notepad.requestDelete(id: id)
        try await until { notepad.noteFailures[id] == "refused for the test" }

        // The second delete is the script's 3rd call: lands for real.
        notepad.requestDelete(id: id)
        try await until { !notepad.notes.contains { $0.id == id } }

        let folder = try XCTUnwrap(notepad.meeting?.folder)
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertFalse(marks.notes.contains { $0.id == id }, "the note must actually be gone from disk")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// Delete while an operation on the queue holds the folder: the write
    /// never starts (`writeMarks`'s own gate), so the id stays in the
    /// library's `pendingNotes` the whole time. The row, its text and the
    /// id must stay until the queue lets the write happen and the library
    /// really settles the delete, clean — never the instant there happens
    /// to be no failure for it, while it is still only pending.
    func testDeleteWhileTheQueueGatesTheWriteKeepsTheRowPending() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let queue = makeQueue()
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder, queue: queue)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        notepad.meeting = NotepadMeeting(identity: identity, folder: meeting, startedAt: nil, isRecording: false)

        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: nil))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let gateIDs = try XCTUnwrap(queue.beginOperations(.removingAudio, on: [address]))

        notepad.requestDelete(id: id)
        try await until { notepad.pendingNoteIDs.contains(id) }
        // A couple of runloop ticks while still gated: before the fix, the
        // row was removed here, as soon as the library had no failure for
        // the id — even though it was still pending, the write never begun.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "the row must stay while the delete is only pending, not yet settled")
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка")
        XCTAssertTrue(notepad.pendingNoteIDs.contains(id))

        queue.endOperations(gateIDs)
        try await until { !notepad.notes.contains { $0.id == id } }
    }

    /// While an add is still pending behind the queue's own gate, `editNote`
    /// and `requestDelete` refuse outright — without ever calling the
    /// library — so a double-click, a context-menu item or Enter in an open
    /// edit field can never tangle with the write already in flight for the
    /// same id. The moment the gate lifts and the add actually lands, a
    /// real edit goes through as an ordinary edit and reaches disk.
    func testEditAndDeleteAreUnavailableWhileAnAddIsPendingOnTheQueuesGate() async throws {
        let meeting = try seed("2026-10-07 10-00-00 Meeting")
        let queue = makeQueue()
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder, queue: queue)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        notepad.meeting = NotepadMeeting(identity: identity, folder: meeting, startedAt: nil, isRecording: false)

        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let gateIDs = try XCTUnwrap(queue.beginOperations(.removingAudio, on: [address]))

        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: nil))
        try await until { notepad.pendingNoteIDs.contains(id) }

        XCTAssertFalse(notepad.editNote(id: id, text: "Подменили текст"), "an edit must refuse outright while the add is still pending")
        XCTAssertFalse(notepad.requestDelete(id: id), "a delete must refuse outright while the add is still pending")
        // A couple of runloop ticks while still gated: neither refusal must
        // have touched the row, its text, or sent anything to the library.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "the row must stay while the add is only pending")
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка", "a refused edit must never change the shown text")
        XCTAssertTrue(notepad.pendingNoteIDs.contains(id))
        XCTAssertNil(notepad.noteFailures[id])

        queue.endOperations(gateIDs)
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        XCTAssertTrue(notepad.editNote(id: id, text: "Планёрка перенесена"), "once the add has landed, an edit must go through")
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка перенесена")

        let folder = try XCTUnwrap(notepad.meeting?.folder)
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes.first { $0.id == id }?.text, "Планёрка перенесена", "the edit must actually reach disk")
    }

    /// A delete accepted while the queue gates the folder (parked, not yet
    /// written) that then actually fails once the gate lifts: the row must
    /// keep its text with the failure's reason, the delete flag must lift
    /// (never leaving the row armed for removal on some later, unrelated
    /// clean outcome), and an edit right after must go through as an
    /// ordinary edit and reach disk.
    func testADeleteAcceptedDuringTheGateThatThenFailsKeepsTheRowAndAllowsTheEdit() async throws {
        let meeting = try seed("2026-10-08 10-00-00 Meeting")
        let queue = makeQueue()
        let recorder = makeRecorder()
        let script = FailSecondWriteThenSucceed()
        let library = makeLibrary(recorder: recorder, queue: queue, reader: reader(writeMarks: script.writeMarks))
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        notepad.meeting = NotepadMeeting(identity: identity, folder: meeting, startedAt: nil, isRecording: false)

        // The add is the script's 1st call: written for real.
        let id = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: nil))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }

        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let gateIDs = try XCTUnwrap(queue.beginOperations(.removingAudio, on: [address]))

        XCTAssertTrue(notepad.requestDelete(id: id), "the library accepts the delete; the write itself is only parked")
        try await until { notepad.pendingNoteIDs.contains(id) }
        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "the row must stay while the delete is only pending")

        // Lifting the gate lets the parked write actually run — the
        // script's 2nd call, which fails.
        queue.endOperations(gateIDs)
        try await until { notepad.noteFailures[id] == "refused for the test" }
        XCTAssertTrue(notepad.notes.contains { $0.id == id }, "a delete that failed to land must keep the row, with the reason")
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Планёрка")
        XCTAssertFalse(notepad.pendingNoteIDs.contains(id), "the failure must lift the pending flag, not just the delete's own one")

        // The edit is the script's 3rd call: must be allowed (the delete flag
        // lifted on the failure) and must actually reach disk.
        XCTAssertTrue(notepad.editNote(id: id, text: "Правка после отказа удаления"))
        try await until { !notepad.pendingNoteIDs.contains(id) && notepad.noteFailures[id] == nil }
        XCTAssertTrue(notepad.notes.contains { $0.id == id })
        XCTAssertEqual(notepad.notes.first { $0.id == id }?.text, "Правка после отказа удаления")

        let folder = try XCTUnwrap(notepad.meeting?.folder)
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(
            marks.notes.first { $0.id == id }?.text, "Правка после отказа удаления",
            "the edit must actually reach disk, not be mistaken for a landed delete"
        )
    }

    /// A note whose add never reached the library at all (no meeting set at
    /// the time) keeps its own failure through a reconcile an unrelated
    /// note's real activity on the same library triggers: before the fix,
    /// reconcile cleared `noteFailures` for every row the moment the
    /// library's own sets changed, even for an id the library never saw.
    func testALocalRefusalSurvivesAnUnrelatedLibraryReconcile() async throws {
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        // No meeting yet: the add never reaches the library.
        let localID = try XCTUnwrap(notepad.submitNote(text: "Без встречи", t: nil))
        XCTAssertEqual(notepad.noteFailures[localID], "The meeting folder isn’t available.")

        // A real note on a real meeting, through the library, so its own
        // pendingNotes/noteFailures actually change.
        recorder.toggle()
        try await until { recorder.state == .recording }
        try setMeeting(notepad, to: recorder)
        let otherID = try XCTUnwrap(notepad.submitNote(text: "Планёрка", t: 1))
        try await until { !notepad.pendingNoteIDs.contains(otherID) && notepad.noteFailures[otherID] == nil }

        XCTAssertEqual(
            notepad.noteFailures[localID], "The meeting folder isn’t available.",
            "an unrelated library settle must never clear a failure the library never made"
        )
        XCTAssertTrue(notepad.notes.contains { $0.id == localID }, "the row must still be there")

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    // MARK: - A note that failed to write holds quit, until deleted

    /// A note whose folder was replaced out from under it never writes;
    /// the failure counts for a person's quit (`quitLosses`) until the row
    /// is deleted, which removes it from the feed and the library without
    /// trying to write anything (there is nothing on disk to delete).
    func testAFailedNoteHoldsQuitUntilTheUserDeletesIt() async throws {
        let folder = try seed("2026-10-06 10-00-00 Meeting")
        let identity = try XCTUnwrap(FolderIdentity.of(folder))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder)
        let notepad = NotepadModel()
        notepad.meeting = NotepadMeeting(identity: identity, folder: folder, startedAt: nil, isRecording: false)
        let notes = NotepadNotes.attach(notepad: notepad, recorder: recorder, library: library)
        withExtendedLifetime(notes) {}

        let id = try XCTUnwrap(notepad.submitNote(text: "Проверить повестку", t: nil))

        XCTAssertNotNil(library.noteFailures[id])
        XCTAssertEqual(library.quitLosses, [.unsavedMeetingMark])

        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish") }
        delegate.meetingLosses = { library.quitLosses }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "a person's quit loses the note unwarned")

        XCTAssertTrue(notepad.requestDelete(id: id))
        try await until { !notepad.notes.contains { $0.id == id } }

        XCTAssertTrue(library.noteFailures.isEmpty)
        XCTAssertEqual(library.quitLosses, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path))
    }

    // MARK: - Fixtures and helpers

    /// `NotepadWindow` is the only code that sets `notepad.meeting` in the
    /// app; a test without one stands in for it, from the recorder's own
    /// session, once recording has actually started.
    private func setMeeting(_ notepad: NotepadModel, to recorder: MeetingRecorder) throws {
        let session = try XCTUnwrap(recorder.currentSession)
        notepad.meeting = NotepadMeeting(
            identity: session.identity, folder: session.directory, startedAt: session.startedAt, isRecording: true
        )
    }

    private func seed(_ name: String) throws -> URL {
        let folder = local.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "startedAt": "2026-10-06T10:00:00Z", "endedAt": "2026-10-06T11:15:00Z", "sampleRate": 48_000,
            "state": "done", "trigger": "manual",
            "segments": [["index": 0, "system": "system.m4a", "mic": "microphone.m4a"]],
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
        for track in ["system.m4a", "microphone.m4a"] {
            try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent(track))
        }
        return folder
    }

    private func makeRecorder(capture: (any MeetingCaptureBackend)? = nil) -> MeetingRecorder {
        let recorder = MeetingRecorder(
            capture: capture ?? NotesInputCapture(),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { [local] in try RecordingsStore().createSession(root: local!) }
        )
        keepAlive.append(recorder)
        return recorder
    }

    private func makeQueue() -> MeetingTranscriptionQueue {
        let queue = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: ConstantEngineFactory()),
                loadSpeechDetector: { _ in { _ in [] } },
                currentEngine: { _ in
                    MeetingTranscriber.Engine(
                        descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                        request: .whisper(WhisperDecodeRequest(language: "ru")),
                        label: "Whisper (whisper)"
                    )
                },
                temporaryRoot: root
            ),
            meetingsRoot: local,
            removal: .confined(to: [root], trash: root.appendingPathComponent("Trash", isDirectory: true)),
            destinations: { .init() }
        )
        keepAlive.append(queue)
        return queue
    }

    private func makeLibrary(
        recorder: MeetingRecorder, queue: MeetingTranscriptionQueue? = nil, reader: MeetingLibrary.Reader = .disk
    ) -> MeetingLibrary {
        let library = MeetingLibrary(
            recorder: recorder,
            queue: queue ?? makeQueue(),
            settings: settings,
            localRoot: local,
            reader: reader,
            notRespondingAfter: .milliseconds(100),
            saving: MeetingLibrary.Saving(destination: { _, _, _ in
                XCTFail("a save panel was asked for")
                return nil
            })
        )
        keepAlive.append(library)
        return library
    }

    /// Polls with a deadline, so a wedged read fails instead of hanging the run.
    private func until(
        within limit: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
        throw CancellationError()
    }
}
