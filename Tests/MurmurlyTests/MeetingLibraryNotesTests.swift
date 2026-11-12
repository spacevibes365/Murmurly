import AVFoundation
import Combine
import XCTest
@testable import Murmurly

/// Records into the folder the recorder made, as the real backend; a copy of
/// `LibraryCapture` (`MeetingLibraryTests.swift`), kept private to this file.
private actor LibraryCapture: MeetingCaptureBackend {
    private var directory: URL?

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
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:30Z",
            sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

/// A start held until the test releases it: the session folder exists (the
/// recorder makes it before calling `start`), but the recorder stays
/// `.starting` until `unlock()`.
private actor HeldCapture: MeetingCaptureBackend {
    private var directory: URL?
    private var open = false

    func unlock() { open = true }

    func start(in directory: URL) async throws -> Date {
        self.directory = directory
        while !open { try await Task.sleep(for: .milliseconds(5)) }
        for name in ["system.caf", "microphone.caf"] {
            try MeetingAudio.write([[Float](repeating: 0, count: 4_800)], to: directory.appendingPathComponent(name))
        }
        return Date()
    }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        self.directory = nil
        let metadata = MeetingMetadata(
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:30Z",
            sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

/// A latch for the queue's mover, which runs on a thread of its own: a copy
/// of `Latch` (`MeetingLibraryTests.swift`).
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var reached = false
    var wasReached: Bool { lock.withLock { reached } }
    func release() { lock.withLock { open = true } }
    func wait() {
        lock.withLock { reached = true }
        while !lock.withLock({ open }) { Thread.sleep(forTimeInterval: 0.005) }
    }
}

@MainActor
private final class UpdateWatch {
    var value = false
}

private actor SilentLibraryMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// A reader whose `writeMarks` is a test's own closure, the rest the real disk.
private func reader(writeMarks: @escaping MeetingLibrary.Reader.MarksWrite) -> MeetingLibrary.Reader {
    MeetingLibrary.Reader(
        root: { MeetingLibrary.readRoot($0, place: $1) },
        meeting: { MeetingLibrary.readOutside($0) },
        text: { try String(contentsOf: $0, encoding: .utf8) },
        writeMarks: writeMarks
    )
}

/// Notes go through the same writer as the star and the names
/// (`MeetingLibrary.changeNotes`), entered by `identity` and address alone:
/// without a row the window read, during the recording under way, during the
/// queue's own move of the folder, and after it was replaced or removed.
@MainActor
final class MeetingLibraryNotesTests: XCTestCase {
    private var root: URL!
    private var local: URL!
    private var disk: URL!
    private var settings: SettingsStore!
    private var keepAlive: [AnyObject] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-library-notes-\(UUID().uuidString)", isDirectory: true)
        local = root.appendingPathComponent("Meetings", isDirectory: true)
        disk = root.appendingPathComponent("Disk/Meetings", isDirectory: true)
        for folder in [local!, disk!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
        settings.meetingAfterStop = .nothing
    }

    override func tearDown() async throws {
        keepAlive = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The recording under way

    /// A note made during the recording, with the main window never opened,
    /// is written into the recording's own folder at once.
    func testANoteDuringRecordingIsWrittenWithoutTheWindow() async throws {
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder)
        recorder.toggle()
        try await until { recorder.state == .recording }
        let session = try XCTUnwrap(recorder.currentSession)
        let note = MeetingNote(id: UUID(), t: 12, kind: .moment, text: "Обсудили сроки релиза")

        let failure = library.addNote(note, identity: session.identity, folder: session.directory)

        XCTAssertNil(failure)
        XCTAssertTrue(library.pendingMarks.isEmpty)
        guard case .read(let marks) = MeetingMarks.read(in: session.directory) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [note])

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A note made while the start is still under way (the folder exists, but
    /// recording has not begun) is refused with its text kept, by note id.
    func testANoteWhileTheRecordingStartsIsRefusedWithItsText() async throws {
        let capture = HeldCapture()
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        recorder.toggle()
        try await until { recorder.state == .starting && recorder.currentSession != nil }
        let session = try XCTUnwrap(recorder.currentSession)
        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Вернуться к бюджету")

        let failure = library.addNote(note, identity: session.identity, folder: session.directory)

        XCTAssertEqual(failure, "The meeting is being recorded.")
        XCTAssertEqual(library.noteFailures[note.id]?.lost, MeetingMarks.Change(notes: [.add(note)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent(MeetingMarks.fileName).path))

        await capture.unlock()
        try await until { recorder.state == .recording }
        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    // MARK: - The queue's own move

    /// A local meeting the queue is moving to the meetings folder, the move
    /// held between its copy and the local folder's removal: a copy of
    /// `meetingBeingMoved` (`MeetingLibraryTests.swift`), without opening the
    /// window.
    private func meetingBeingMoved() async throws -> (meeting: URL, moved: URL, queue: MeetingTranscriptionQueue, latch: Latch, library: MeetingLibrary) {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let moved = disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let latch = Latch()
        queue.mover = { folder, target, _ in
            let place = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: folder, to: place)
            latch.wait()
            try FileManager.default.removeItem(at: folder)
            return place
        }
        let library = makeLibrary(queue: queue)
        queue.enqueue(meeting, transcribe: false)
        try await until { latch.wasReached }
        XCTAssertEqual(queue.step, .moving)
        return (meeting, moved, queue, latch, library)
    }

    /// A note made while the move is under way waits (`pendingMarks`,
    /// `pendingNotes` are not empty, and nothing is written at either
    /// address); notes made after the move lands at the new address too, in
    /// the order they were made.
    func testNotesDuringAndAfterAMoveLandAtTheNewAddress() async throws {
        let (meeting, moved, queue, latch, library) = try await meetingBeingMoved()
        let noteA = MeetingNote(id: UUID(), t: 1, kind: .note, text: "Планёрка")

        let failureA = library.addNote(noteA, identity: nil, folder: meeting)
        XCTAssertNil(failureA)
        XCTAssertFalse(library.pendingMarks.isEmpty)
        XCTAssertTrue(library.pendingNotes.contains(noteA.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent(MeetingMarks.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(MeetingMarks.fileName).path))

        latch.release()
        try await until { queue.operations.isEmpty && library.pendingMarks.isEmpty }

        let noteB = MeetingNote(id: UUID(), t: 2, kind: .note, text: "Вернуться к бюджету")
        let noteC = MeetingNote(id: UUID(), t: 3, kind: .note, text: "Спросить про дизайн")
        XCTAssertNil(library.addNote(noteB, identity: nil, folder: meeting))
        XCTAssertNil(library.addNote(noteC, identity: nil, folder: meeting))
        try await until { library.pendingMarks.isEmpty }

        guard case .read(let marks) = MeetingMarks.read(in: moved) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [noteA, noteB, noteC])
        XCTAssertTrue(library.noteFailures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.path))
    }

    /// A note made after the move finished, for a library that was never
    /// told about this particular note before (the first one for this
    /// meeting after the move, so there is no state under the old identity
    /// yet), still finds the new address through the move's own recorded
    /// source — proving the gap where the writer only re-keyed an existing
    /// state is closed.
    func testANoteAfterAMoveTheLibraryHasNotFollowedFindsTheNewAddress() async throws {
        let (meeting, moved, queue, latch, library) = try await meetingBeingMoved()
        latch.release()
        try await until { queue.operations.isEmpty && !FileManager.default.fileExists(atPath: meeting.path) }
        let noteB = MeetingNote(id: UUID(), t: 2, kind: .note, text: "Вернуться к бюджету")
        let noteC = MeetingNote(id: UUID(), t: 3, kind: .note, text: "Спросить про дизайн")

        XCTAssertNil(library.addNote(noteB, identity: nil, folder: meeting))
        XCTAssertNil(library.addNote(noteC, identity: nil, folder: meeting))
        try await until { library.pendingMarks.isEmpty }

        guard case .read(let marks) = MeetingMarks.read(in: moved) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [noteB, noteC])
    }

    /// An unsaved note (parked while the queue moves its folder) holds quit
    /// and Sparkle, as an unsaved star does; both see it only through
    /// `pendingMarks`.
    func testAParkedNoteHoldsQuitAndUpdates() async throws {
        let (meeting, moved, queue, latch, library) = try await meetingBeingMoved()
        let note = MeetingNote(id: UUID(), t: 1, kind: .note, text: "Планёрка")
        let busy = UpdateWatch()
        let watch = AppUpdater.busy(
            meeting: makeRecorder(), dictation: DictationCoordinator(mic: SilentLibraryMic(), indicator: RecordingIndicator(renderingEnabled: false)),
            transcripts: queue, files: FilesModel(transcription: { _ in { _, _ in [] } }), library: library
        ).sink { busy.value = $0 }
        defer { watch.cancel() }

        XCTAssertNil(library.addNote(note, identity: nil, folder: meeting))
        try await until { !library.pendingMarks.isEmpty }
        XCTAssertTrue(busy.value, "Sparkle would relaunch over an unsaved note")
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish") }
        delegate.meetingLosses = { library.quitLosses }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "a person's quit loses the note unwarned")

        latch.release()
        try await until { library.pendingMarks.isEmpty }
        XCTAssertFalse(busy.value)
        XCTAssertEqual(library.quitLosses, [])
        guard case .read(let marks) = MeetingMarks.read(in: moved) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [note])
    }

    // MARK: - Failures

    /// The folder at the address was replaced (deleted and recreated, same
    /// name) with no queue operation and no move to explain it: the change
    /// fails with the text, rather than park forever.
    func testAReplacedFolderKeepsTheNoteText() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        let library = makeLibrary()
        try FileManager.default.removeItem(at: meeting)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Планёрка")

        let failure = library.addNote(note, identity: identity, folder: meeting)

        XCTAssertEqual(failure, MeetingMarks.Refusal.replaced.localizedDescription)
        XCTAssertEqual(library.noteFailures[note.id]?.lost, MeetingMarks.Change(notes: [.add(note)]))
        XCTAssertTrue(library.pendingMarks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent(MeetingMarks.fileName).path))
    }

    /// A write that fails for an ordinary reason (not a replaced folder) is
    /// reported by the note's own id, never through `markFailures`/`markNotice`.
    func testAFailedNoteWriteIsReportedByNoteID() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        let library = makeLibrary(reader: reader(writeMarks: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }))
        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Планёрка")

        let failure = library.addNote(note, identity: identity, folder: meeting)

        XCTAssertNotNil(failure)
        XCTAssertEqual(library.noteFailures[note.id]?.reason, failure)
        XCTAssertTrue(library.markFailures.isEmpty)
        XCTAssertNil(library.markNotice)
        XCTAssertTrue(library.pendingMarks.isEmpty)
    }

    /// A star change and a notes change parked on the same operation land in
    /// one state; the write goes in two parts, so a crooked `notes` field
    /// never takes the star down with it.
    func testCrookedNotesDoNotTakeTheStarDown() async throws {
        let meeting = try seed(
            "2026-10-06 10-00-00 Meeting", in: local, metadata: done,
            files: [MeetingMarks.fileName: #"{"version":1,"notes":"x"}"#]
        )
        let queue = makeQueue()
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try XCTUnwrap(library.meeting(at: meeting))
        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let ids = try XCTUnwrap(queue.beginOperations(.removingAudio, on: [address]))
        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Планёрка")

        XCTAssertNil(library.addNote(note, identity: row.identity, folder: meeting))
        XCTAssertFalse(library.pendingMarks.isEmpty)

        queue.endOperations(ids)
        library.toggleStar(row)
        try await until { library.pendingMarks.isEmpty }

        let data = try Data(contentsOf: meeting.appendingPathComponent(MeetingMarks.fileName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["starred"] as? Bool, true)
        XCTAssertEqual(object["notes"] as? String, "x")
        XCTAssertNotNil(library.noteFailures[note.id])
        XCTAssertTrue(library.markFailures.isEmpty)
    }

    /// A note made while the queue holds the folder for "Delete Audio…"
    /// waits, and is written once the operation ends.
    func testANoteDuringAudioRemovalIsWrittenAfterIt() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let queue = makeQueue()
        let library = makeLibrary(queue: queue)
        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let ids = try XCTUnwrap(queue.beginOperations(.removingAudio, on: [address]))
        let identity = try XCTUnwrap(address.identity)
        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Планёрка")

        XCTAssertNil(library.addNote(note, identity: identity, folder: meeting))
        XCTAssertFalse(library.pendingMarks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent(MeetingMarks.fileName).path))

        queue.endOperations(ids)
        try await until { library.pendingMarks.isEmpty }

        guard case .read(let marks) = MeetingMarks.read(in: meeting) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [note])
    }

    // MARK: - As before

    /// Stopping a recording with a note in it, queuing it (without
    /// transcribing), and deleting it whole still work: the note is on disk
    /// after the stop, survives the scan, and goes to the Trash with the rest
    /// of the folder.
    func testStopQueueAndDeletionWorkWithANoteInTheRecordingFolder() async throws {
        let recorder = makeRecorder()
        let queue = makeQueue()
        recorder.transcripts = queue
        let library = makeLibrary(recorder: recorder, queue: queue)
        recorder.toggle()
        try await until { recorder.state == .recording }
        let session = try XCTUnwrap(recorder.currentSession)
        let note = MeetingNote(id: UUID(), t: 5, kind: .moment, text: "Планёрка")
        XCTAssertNil(library.addNote(note, identity: session.identity, folder: session.directory))
        let folder = session.directory

        recorder.toggle()
        try await until { recorder.state == .idle }
        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [note])

        queue.enqueue(folder, transcribe: false)
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        guard case .read(let afterScan) = MeetingMarks.read(in: folder) else { return XCTFail("the marks did not read after the scan") }
        XCTAssertEqual(afterScan.notes, [note])

        library.windowOpened()
        try await until { library.local.fresh && !library.local.reading }
        let lines = try await deleted(library, [folder], .meeting)
        XCTAssertEqual(lines.map(\.outcome), [.trashed])
        let places = try FileManager.default.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil)
        let trashed = try XCTUnwrap(places.first).appendingPathComponent(folder.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.appendingPathComponent(MeetingMarks.fileName).path))
    }

    /// The star, the name and the speakers' names are still refused for the
    /// recording under way, as before notes went their own way.
    func testStarNameAndNamesStayRefusedForTheRecording() async throws {
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder)
        library.windowOpened()
        recorder.toggle()
        try await until { recorder.state == .recording }
        let session = try XCTUnwrap(recorder.currentSession)
        let live = session.directory
        try await until { library.local.fresh }

        let renameFailure = library.rename(typedOn: session.identity, at: live.path, to: "Планёрка")
        XCTAssertNotNil(renameFailure)
        let namesFailure = library.setNames(typedOn: session.identity, at: live.path, microphone: "Аня", system: "Борис")
        XCTAssertNotNil(namesFailure)
        if let row = library.meeting(at: live) {
            XCTAssertEqual(library.markRefusal(for: row), "The meeting is being recorded.")
        }

        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Планёрка")
        XCTAssertNil(library.addNote(note, identity: session.identity, folder: live))

        guard case .read(let marks) = MeetingMarks.read(in: live) else { return XCTFail("the marks did not read") }
        XCTAssertNil(marks.title)
        XCTAssertFalse(marks.starred)
        XCTAssertEqual(marks.notes, [note])

        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// A meeting the window has read (in the chosen meetings folder, with
    /// the same name also present locally) takes its row as before: the
    /// write goes through the folder's own channel, and the "both roots"
    /// refusal still applies.
    func testANoteForAMeetingTheWindowShowsTakesItsRow() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Планёрка")

        XCTAssertNil(library.addNote(note, identity: nil, folder: meeting))
        try await until { library.pendingMarks.isEmpty }
        guard case .read(let marks) = MeetingMarks.read(in: meeting) else { return XCTFail("the marks did not read") }
        XCTAssertEqual(marks.notes, [note])

        _ = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        library.refresh()
        try await until { library.local.fresh && !library.local.reading }
        let noteWhileBoth = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Спросить про дизайн")
        let failure = library.addNote(noteWhileBoth, identity: nil, folder: meeting)
        XCTAssertEqual(failure, library.noteFailures[noteWhileBoth.id]?.reason)
        XCTAssertNotNil(failure)
    }

    // MARK: - The notepad, stopped, after the queue moves its folder

    /// A note typed in the notepad of a meeting that has stopped, after the
    /// queue has already moved its folder into the chosen meetings folder
    /// (the notepad never re-reads that move — it keeps the meeting's own,
    /// pre-move address and identity), still lands: the marks writer follows
    /// the move itself. The main window is never opened.
    func testANoteFromTheNotepadOfAStoppedMeetingLandsAfterTheQueueMovesIt() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let moved = disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        queue.mover = { folder, target, _ in
            let place = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: folder, to: place)
            try FileManager.default.removeItem(at: folder)
            return place
        }
        let recorder = makeRecorder()
        let library = makeLibrary(recorder: recorder, queue: queue)

        let panel = LiveTranscriptPanel(settings: settings, meeting: recorder, renderingEnabled: false)
        let notes = NotepadNotes.attach(notepad: panel.notepad, recorder: recorder, library: library)
        keepAlive += [panel, notes]

        recorder.publishLiveTranscriptForTesting(state: .recording, model: LiveTranscriptModel(), directory: meeting)
        recorder.stopLiveTranscriptForTesting()
        XCTAssertEqual(panel.notepad.meeting?.isRecording, false)
        XCTAssertEqual(panel.notepad.meeting?.folder.standardizedFileURL.path, meeting.standardizedFileURL.path)

        queue.enqueue(meeting, transcribe: false)
        try await until {
            queue.operations.isEmpty
                && !FileManager.default.fileExists(atPath: meeting.path)
                && FileManager.default.fileExists(atPath: moved.path)
        }

        // The user closes the panel and reopens it, as "Show Live
        // Transcript" does: `render()` must not mistake the move for a new
        // meeting, nor forget the address it should keep.
        panel.close()
        panel.show()

        let id = try XCTUnwrap(panel.notepad.submitNote(text: "Вернуться к бюджету", t: nil))
        try await until { library.pendingNotes.isEmpty }
        try await until { !panel.notepad.pendingNoteIDs.contains(id) }

        XCTAssertTrue(library.noteFailures.isEmpty)
        XCTAssertNil(panel.notepad.noteFailures[id])
        guard case .read(let marks) = MeetingMarks.read(in: moved) else { return XCTFail("the marks did not read") }
        XCTAssertTrue(marks.notes.contains { $0.text == "Вернуться к бюджету" })
    }

    // MARK: - Fixtures and helpers

    private var done: [String: Any] {
        [
            "startedAt": "2026-10-06T10:00:00Z", "endedAt": "2026-10-06T11:15:00Z", "sampleRate": 48_000,
            "state": "done", "trigger": "manual",
            "segments": [["index": 0, "system": "system.m4a", "mic": "microphone.m4a"]],
        ]
    }

    @discardableResult
    private func seed(
        _ name: String, in root: URL, metadata: [String: Any]?,
        tracks: [String] = ["system.m4a", "microphone.m4a"], files: [String: String] = [:]
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let metadata {
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
        }
        for track in tracks { try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent(track)) }
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    private func makeRecorder(capture: (any MeetingCaptureBackend)? = nil) -> MeetingRecorder {
        let recorder = MeetingRecorder(
            capture: capture ?? LibraryCapture(),
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

    private func makeQueue(
        localRoot: URL? = nil,
        destinations: @escaping @MainActor () -> MeetingTranscriptionQueue.Destinations = { .init() }
    ) -> MeetingTranscriptionQueue {
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
            meetingsRoot: localRoot ?? local,
            removal: .confined(to: [root], trash: trashFolder),
            destinations: destinations
        )
        keepAlive.append(queue)
        return queue
    }

    private func makeLibrary(
        recorder: MeetingRecorder? = nil,
        queue: MeetingTranscriptionQueue? = nil,
        reader: MeetingLibrary.Reader = .disk,
        localRoot: URL? = nil
    ) -> MeetingLibrary {
        let library = MeetingLibrary(
            recorder: recorder ?? makeRecorder(),
            queue: queue ?? makeQueue(),
            settings: settings,
            localRoot: localRoot ?? local,
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

    private var trashFolder: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    private func deleted(_ library: MeetingLibrary, _ folders: [URL], _ kind: MeetingLibrary.RemovalKind) async throws
        -> [MeetingLibrary.RemovalLine] {
        let plan = library.removalPlan(for: folders, kind: kind)
        let before = library.removalReport.count
        library.remove(plan)
        try await until { library.removalReport.count == before + plan.items.count || library.removalRecheck != nil }
        return Array(library.removalReport.dropFirst(before))
    }

    /// Polls with a deadline, so a wedged read fails instead of hanging the run.
    private func until(
        within limit: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
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
