import AppKit
import Combine
import CryptoKit
import XCTest
@testable import Murmurly

/// A clock the tracks of a test play on: frozen unless advanced by hand, so
/// a position read right after `play(from:)` is exact.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// A recording whose stop waits for the test to release it, so a card's
/// `openAndPlay` can be asked while the recorder is `.stopping`.
private actor LatchedStopCapture: MeetingCaptureBackend {
    private var directory: URL?
    private var released = false

    func release() { released = true }

    func start(in directory: URL) async throws -> Date {
        for name in ["system.caf", "microphone.caf"] {
            try MeetingAudio.write([[Float](repeating: 0, count: 4_800)], to: directory.appendingPathComponent(name))
        }
        self.directory = directory
        return Date()
    }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        self.directory = nil
        let metadata = MeetingMetadata(
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:30Z", sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

private actor PlainCapture: MeetingCaptureBackend {
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
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:30Z", sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

@MainActor
final class MeetingNotesOnCardTests: XCTestCase {
    private var root: URL!
    private var local: URL!
    private var disk: URL!
    private var settings: SettingsStore!
    private var keepAlive: [AnyObject] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-notes-card-\(UUID().uuidString)", isDirectory: true)
        local = root.appendingPathComponent("Meetings", isDirectory: true)
        disk = root.appendingPathComponent("Disk/Meetings", isDirectory: true)
        for folder in [local!, disk!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
        settings.meetingAfterStop = .nothing
    }

    override func tearDown() async throws {
        MeetingLibrary.showMainWindow = nil
        keepAlive = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 1: openAndPlay, reliably

    /// The window is closed, the queue already moved the folder: `openAndPlay`
    /// shows the main window, opens the meeting at its new address, and
    /// plays from the given time once the audio has loaded — it does not
    /// try `seek` before the load finishes, which would silently do nothing.
    func testOpenAndPlayOpensTheMovedMeetingAndPlaysOnceItsAudioIsLoaded() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local)
        let moved = MeetingLibrary.canonical(disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true))
        let clock = TestClock()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let library = makeLibrary(queue: queue, deck: MeetingPlayer.Deck { _ in SilentTrack(duration: 120, clock: { clock.now }) })
        library.windowOpened()
        try await until { library.local.fresh }
        library.windowClosed()

        queue.enqueue(meeting, transcribe: false)
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "the queue did not move the folder")

        var shown = 0
        MeetingLibrary.showMainWindow = { shown += 1; library.windowOpened() }

        XCTAssertNil(library.openAndPlay(folder: meeting, at: 42))
        try await until { library.player.state == .playing }

        XCTAssertEqual(shown, 1)
        XCTAssertEqual(library.selection, moved)
        XCTAssertEqual(library.section, .meetings)
        XCTAssertEqual(library.player.position, 42, accuracy: 0.06)
        XCTAssertEqual(library.player.folder, moved)
    }

    /// While the recorder is busy — recording, or stopping a recording —
    /// `openAndPlay` refuses at once and plays nothing; it does not show the
    /// main window either, since there is nothing to show there.
    func testOpenAndPlayWhileTheRecordingStopsGivesTheReasonAndPlaysNothing() async throws {
        let capture = LatchedStopCapture()
        let recorder = makeRecorder(capture: capture)
        let library = makeLibrary(recorder: recorder)
        library.windowOpened()
        try await until { library.local.fresh }
        var shown = 0
        MeetingLibrary.showMainWindow = { shown += 1 }

        recorder.toggle()
        try await until { recorder.state == .recording }
        let meeting = try XCTUnwrap(recorder.currentSession?.directory)
        recorder.toggle()
        try await until { recorder.state == .stopping }

        XCTAssertEqual(library.openAndPlay(folder: meeting, at: 5), MeetingLibrary.recordingRefusal)
        XCTAssertEqual(shown, 0)
        XCTAssertNotEqual(library.player.state, .playing)

        await capture.release()
        try await until { !recorder.isBusy }
    }

    /// While the queue works on a meeting's folder, `openAndPlay` gives the
    /// operation's own reason and plays nothing — the meeting is already in
    /// the window's snapshot, so the refusal comes back at once rather than
    /// only once the player tries to load and fails.
    func testOpenAndPlayDuringAQueueOperationGivesTheReasonAndPlaysNothing() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local)
        let queue = makeQueue()
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        var shown = 0
        MeetingLibrary.showMainWindow = { shown += 1 }

        // Not selected yet: `beginOperations` would otherwise wait on the
        // player's own open of the same folder.
        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let taken = try XCTUnwrap(queue.beginOperations(.moving, on: [address]))

        XCTAssertEqual(library.openAndPlay(folder: meeting, at: 5), MeetingTranscriptionQueue.describe(.moving))
        XCTAssertEqual(shown, 0)
        XCTAssertNotEqual(library.player.state, .playing)

        queue.endOperations(taken)
    }

    // MARK: - The card's notes

    /// Timed notes come first, earliest first, ties in file order; the
    /// untimed ones follow, as written.
    func testTheCardListsNotesByTimeThenTheUntimed() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local)
        let later = UUID()
        let untimed = UUID()
        let moment = UUID()
        let tied = UUID()
        let json = """
        {"version":1,"notes":[
          {"id":"\(later.uuidString)","t":65,"kind":"note","text":"Обсудить сроки"},
          {"id":"\(untimed.uuidString)","kind":"note","text":"Проверить меню"},
          {"id":"\(moment.uuidString)","t":12,"kind":"moment","text":""},
          {"id":"\(tied.uuidString)","t":12,"kind":"note","text":"Вернуться к бюджету"}
        ]}
        """
        try Data(json.utf8).write(to: meeting.appendingPathComponent(MeetingMarks.fileName))
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try XCTUnwrap(library.meeting(at: meeting))

        XCTAssertEqual(library.notepadNotes(of: row).map(\.id), [moment, tied, later, untimed])
        XCTAssertEqual(MeetingLibrary.notesInOrder([]), [])
    }

    /// A note's time plays ten seconds before it, never before the start of
    /// the recording; a note with no time does nothing.
    func testANoteTimePlaysTenSecondsEarlierButNotBeforeTheStart() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local)
        let clock = TestClock()
        let library = makeLibrary(deck: MeetingPlayer.Deck { _ in SilentTrack(duration: 120, clock: { clock.now }) })
        library.windowOpened()
        try await until { library.local.fresh }
        library.select(meeting)
        try await until { library.player.state == .ready }

        library.playNote(MeetingNote(id: UUID(), t: 65, kind: .note, text: "Обсудить сроки"))
        try await until { library.player.state == .playing }
        XCTAssertEqual(library.player.position, 55, accuracy: 0.06)
        library.player.pause()

        library.playNote(MeetingNote(id: UUID(), t: 4, kind: .note, text: "Проверить меню"))
        try await until { library.player.state == .playing }
        XCTAssertEqual(library.player.position, 0, accuracy: 0.06)
        library.player.pause()

        let before = library.player.position
        library.playNote(MeetingNote(id: UUID(), t: nil, kind: .note, text: "Вернуться к бюджету"))
        XCTAssertEqual(library.player.position, before, accuracy: 0.001)
        XCTAssertEqual(library.player.state, .ready)
    }

    // MARK: - Save As with notes

    func testSavedMarkdownEndsWithTheNotes() throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n"
        let transcript = MeetingTranscript.parse(raw)
        let notes = [
            MeetingNote(id: UUID(), t: 12, kind: .moment, text: ""),
            MeetingNote(id: UUID(), t: 12, kind: .note, text: "Вернуться к бюджету"),
            MeetingNote(id: UUID(), t: 65, kind: .note, text: "Обсудить сроки"),
            MeetingNote(id: UUID(), t: nil, kind: .note, text: "Проверить меню"),
        ]
        let expected = raw + "\n## Notes\n\n- [0:12] ★\n- [0:12] Вернуться к бюджету\n- [1:05] Обсудить сроки\n- (after the meeting) Проверить меню\n"
        XCTAssertEqual(transcript.exported(as: .markdown, notes: notes), expected)

        let withoutTrailingNewline = String(raw.dropLast())
        let expectedTwoNewlines = withoutTrailingNewline
            + "\n\n## Notes\n\n- [0:12] ★\n- [0:12] Вернуться к бюджету\n- [1:05] Обсудить сроки\n- (after the meeting) Проверить меню\n"
        XCTAssertEqual(MeetingTranscript.parse(withoutTrailingNewline).exported(as: .markdown, notes: notes), expectedTwoNewlines)

        let withLineBreak = [MeetingNote(id: UUID(), t: 1, kind: .note, text: "строка1\nстрока2")]
        XCTAssertEqual(transcript.exported(as: .markdown, notes: withLineBreak), raw + "\n## Notes\n\n- [0:01] строка1 строка2\n")
    }

    /// A moment made from a line's own selection carries its words
    /// (`MeetingNote.text`), not just a bare ★: Save As (Markdown and plain
    /// text) must show them next to the star, exactly as a moment with no
    /// text shows the star alone.
    func testSavedMarkdownAndTextShowAMomentsWords() throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n"
        let transcript = MeetingTranscript.parse(raw)
        let notes = [MeetingNote(id: UUID(), t: 12, kind: .moment, text: "бюджет на квартал")]

        XCTAssertEqual(transcript.exported(as: .markdown, notes: notes), raw + "\n## Notes\n\n- [0:12] ★ бюджет на квартал\n")

        let base = try XCTUnwrap(transcript.exported(as: .text))
        XCTAssertEqual(transcript.exported(as: .text, notes: notes), base + "\nNotes\n\n[0:12] ★ бюджет на квартал\n")
    }

    func testSavedPlainTextEndsWithTheNotesWithoutMarkup() throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n"
        let transcript = MeetingTranscript.parse(raw)
        let notes = [
            MeetingNote(id: UUID(), t: 12, kind: .moment, text: ""),
            MeetingNote(id: UUID(), t: 12, kind: .note, text: "Вернуться к бюджету"),
            MeetingNote(id: UUID(), t: 65, kind: .note, text: "Обсудить сроки"),
            MeetingNote(id: UUID(), t: nil, kind: .note, text: "Проверить меню"),
        ]
        let base = try XCTUnwrap(transcript.exported(as: .text))
        let expected = base + "\nNotes\n\n[0:12] ★\n[0:12] Вернуться к бюджету\n[1:05] Обсудить сроки\n(after the meeting) Проверить меню\n"
        XCTAssertEqual(transcript.exported(as: .text, notes: notes), expected)

        XCTAssertNil(transcript.exported(as: .subtitles))
        XCTAssertEqual(transcript.exported(as: .subtitles, notes: notes), transcript.exported(as: .subtitles))

        // A transcript with exact spans makes real SRT; notes never reach
        // it, whether or not any are given.
        var attempt = MeetingAttempt(number: 1, startedAt: Date(timeIntervalSince1970: 1_760_000_000))
        attempt.lines = [MeetingAttempt.Line(start: 5, end: 7, source: .microphone)]
        let bytes = Data(raw.utf8)
        attempt.fingerprint = MeetingAttempt.Fingerprint(
            bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        let timed = transcript.timed(by: attempt)
        guard case .exact = timed.timing else { return XCTFail("the record does not match its own file") }
        let subtitles = try XCTUnwrap(timed.exported(as: .subtitles))
        XCTAssertFalse(subtitles.isEmpty)
        XCTAssertEqual(timed.exported(as: .subtitles, notes: notes), subtitles)
    }

    func testWithoutNotesEveryFormatIsAsBefore() throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n"
        let transcript = MeetingTranscript.parse(raw)
        for format in MeetingTranscript.Format.allCases {
            XCTAssertEqual(transcript.exported(as: format, notes: []), transcript.exported(as: format))
        }
        XCTAssertEqual(transcript.exported(as: .markdown), raw)
    }

    /// The stitch from the library to the file: `export` reads the
    /// meeting's own notes from disk at the click and ends the saved
    /// Markdown with them.
    func testSaveAsTakesTheMeetingsNotes() async throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n"
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, files: ["transcript.md": raw])
        let note = MeetingNote(id: UUID(), t: 65, kind: .note, text: "Обсудить сроки")
        let json = """
        {"version":1,"notes":[{"id":"\(note.id.uuidString)","t":65,"kind":"note","text":"Обсудить сроки"}]}
        """
        try Data(json.utf8).write(to: meeting.appendingPathComponent(MeetingMarks.fileName))

        let out = root.appendingPathComponent("Saved", isDirectory: true).appendingPathComponent("out.md")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saving = MeetingLibrary.Saving(destination: { _, _, _ in out })
        let library = makeLibrary(saving: saving)
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try await showText(of: meeting, in: library)

        XCTAssertNil(library.export(row, as: .markdown, from: nil))
        try await until { library.exporting == nil }

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(written, raw + "\n## Notes\n\n- [1:05] Обсудить сроки\n")
    }

    // MARK: - Helpers

    @discardableResult
    private func seed(
        _ name: String, in root: URL, tracks: [String] = ["system.m4a", "microphone.m4a"], files: [String: String] = [:]
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "startedAt": "2026-10-06T10:00:00Z", "endedAt": "2026-10-06T10:01:30Z", "sampleRate": 48_000,
            "state": "done", "trigger": "manual", "segments": [["index": 0, "system": "system.m4a", "mic": "microphone.m4a"]],
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
        for track in tracks { try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent(track)) }
        for (path, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(path)) }
        return folder
    }

    private func makeRecorder(capture: any MeetingCaptureBackend = PlainCapture()) -> MeetingRecorder {
        let recorder = MeetingRecorder(
            capture: capture,
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
            meetingsRoot: local,
            removal: .confined(to: [root], trash: root.appendingPathComponent("Trash", isDirectory: true)),
            destinations: destinations
        )
        keepAlive.append(queue)
        return queue
    }

    private func makeLibrary(
        recorder: MeetingRecorder? = nil,
        queue: MeetingTranscriptionQueue? = nil,
        deck: MeetingPlayer.Deck = .live,
        saving: MeetingLibrary.Saving? = nil
    ) -> MeetingLibrary {
        let library = MeetingLibrary(
            recorder: recorder ?? makeRecorder(),
            queue: queue ?? makeQueue(),
            settings: settings,
            localRoot: local,
            notRespondingAfter: .milliseconds(100),
            applicationName: { $0 },
            deck: deck,
            saving: saving ?? MeetingLibrary.Saving(destination: { _, _, _ in
                XCTFail("a save panel was asked for")
                return nil
            })
        )
        keepAlive.append(library)
        return library
    }

    /// The meeting on the card with its text read.
    @discardableResult
    private func showText(of folder: URL, in library: MeetingLibrary) async throws -> MeetingLibrary.Meeting {
        library.select(folder)
        try await until { if case .loaded = library.text { true } else { false } }
        return try XCTUnwrap(library.meeting(at: folder))
    }

    /// Polls with a deadline, so a wedged read fails instead of hanging the run.
    private func until(
        within limit: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
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
