import AppKit
import FluidAudio
import XCTest
@testable import Murmurly

/// Saves every stop as a finished folder with real tracks; `failedStop` makes
/// the next stop a partly saved one, as a capture error does.
private actor MovingMeetingCapture: MeetingCaptureBackend {
    let root: URL
    private var stops = 0
    private var failNext = false

    init(root: URL) { self.root = root }

    nonisolated static func name(_ index: Int) -> String { "2026-10-07 11-00-0\(index) Meeting" }

    func failNextStop() { failNext = true }

    func start(in _: URL) async throws -> Date { Date(timeIntervalSinceReferenceDate: 1_000) }

    func stop() async throws -> [URL] {
        stops += 1
        let samples = [MeetingAudio.noise(count: 48_000, amplitude: 0.4, seed: UInt32(stops))]
        let folder = try MeetingAudio.folder(
            Self.name(stops), in: root, microphone: samples, system: samples,
            state: failNext ? "failed" : "done"
        )
        if failNext {
            failNext = false
            throw SystemAudioCaptureError.captureFailed(message: "partial", savedAt: folder)
        }
        return ["system.caf", "microphone.caf"].map { folder.appendingPathComponent($0) }
    }
}

/// Writes the folder and its finished metadata, then holds the stop until
/// released: the recorder is still stopping then, as it is between the
/// capture's stop and its own last metadata write (the trigger).
private actor HeldStopCapture: MeetingCaptureBackend {
    let folder: URL
    private var released = false

    init(folder: URL) { self.folder = folder }

    func release() { released = true }

    func start(in _: URL) async throws -> Date { Date(timeIntervalSinceReferenceDate: 1_000) }

    func stop() async throws -> [URL] {
        let samples = [MeetingAudio.noise(count: 48_000, amplitude: 0.4, seed: 5)]
        _ = try MeetingAudio.folder(
            folder.lastPathComponent, in: folder.deletingLastPathComponent(), microphone: samples, system: samples
        )
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        return ["system.caf", "microphone.caf"].map { folder.appendingPathComponent($0) }
    }
}

private actor SpeakingEngine: WhisperEngine {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        ([WhisperSegmentDTO(text: "реплика", start: 0)], "ru")
    }
}

private struct SpeakingEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { SpeakingEngine() }
}

private actor NoMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func append<Element>(_ element: Element) where Value == [Element] { lock.withLock { value.append(element) } }
}

/// The junctions "stop → transcription → copy → compression → move", "mount →
/// scan → move" and "Show… → where the folder is now": the real recorder,
/// queue and settings store; the capture, the VAD and the engine stand in.
@MainActor
final class MeetingMoveQueueTests: XCTestCase {
    private static let suiteName = "io.github.spacevibes365.MurmurlyTests.MeetingMoveQueue"
    private var base: URL!
    private var local: URL!
    private var target: URL!
    private var notes: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-move-queue-\(UUID().uuidString)", isDirectory: true)
        local = base.appendingPathComponent("Meetings", isDirectory: true)
        target = base.appendingPathComponent("Disk/Meetings", isDirectory: true)
        notes = base.appendingPathComponent("Vault/Созвоны", isDirectory: true)
        for folder in [local!, target!, notes!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    func testStopTranscribesCopiesCompressesAndMovesAndShowLeadsThere() async throws {
        let setup = makeRecorder()
        let name = MovingMeetingCapture.name(1)

        try await record(setup.recorder)
        let moved = target.appendingPathComponent(name, isDirectory: true)
        let done = await eventually { !self.exists(self.local.appendingPathComponent(name)) && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(try names(in: moved), ["metadata.json", "microphone.m4a", "system.m4a", "transcript.md"])
        // The attempt's record went with the meeting, and the copy took only the text.
        XCTAssertEqual(try MeetingAttempt.entries(in: moved).map(\.attempt?.transcript), ["transcript.md"])
        XCTAssertEqual(try names(in: notes), ["2026-10-07 11-00-01 Meeting.md"])
        XCTAssertEqual(
            try Data(contentsOf: notes.appendingPathComponent("2026-10-07 11-00-01 Meeting.md")),
            try Data(contentsOf: moved.appendingPathComponent("transcript.md"))
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), [], "nothing left behind, not even hidden")
        XCTAssertEqual(setup.queue.issues, [:])

        // Where "Show Transcript" and "Show Last Recording…" open the window.
        XCTAssertEqual(setup.queue.lastMeeting?.path, moved.path)
        XCTAssertEqual(setup.queue.lastOutcome?.transcript?.lastPathComponent, "transcript.md")
        XCTAssertEqual(setup.recorder.lastRecordingLocation?.path, moved.path)
    }

    /// Two calls in one minute: two notes, since the name keeps the seconds.
    func testTwoMeetingsInOneMinuteGiveTwoNotes() async throws {
        let setup = makeRecorder()

        try await record(setup.recorder)
        try await record(setup.recorder)
        let done = await eventually { (try? self.names(in: self.target).count) == 2 && setup.queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(try names(in: notes), ["2026-10-07 11-00-01 Meeting.md", "2026-10-07 11-00-02 Meeting.md"])
    }

    /// The meetings folder is away: the recording is compressed and waits
    /// here with its reason; when a volume appears, it moves.
    func testUnavailableFolderWaitsAndMovesWhenAVolumeAppears() async throws {
        try FileManager.default.removeItem(at: target)
        let setup = makeRecorder()
        let name = MovingMeetingCapture.name(1)
        let folder = local.appendingPathComponent(name, isDirectory: true)

        try await record(setup.recorder)
        let waiting = await eventually {
            setup.queue.activeFolder == nil && setup.queue.issues[folder.standardizedFileURL]?.move != nil
        }

        XCTAssertTrue(waiting)
        XCTAssertEqual(setup.queue.issues[folder.standardizedFileURL]?.lines, ["move: folder not available: \(target.path)"])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a", "transcript.md"])
        XCTAssertEqual(try MeetingAttempt.entries(in: folder).count, 1)
        XCTAssertFalse(exists(target), "the meetings folder is never created")

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        let moved = await eventually { !self.exists(folder) && setup.queue.activeFolder == nil }

        XCTAssertTrue(moved)
        XCTAssertTrue(exists(target.appendingPathComponent(name).appendingPathComponent("transcript.md")))
        XCTAssertEqual(setup.queue.issues, [:])
        XCTAssertEqual(try names(in: notes), ["2026-10-07 11-00-01 Meeting.md"], "copied once, at the transcription")
    }

    /// Scans never copy: a note the user renamed (or deleted) stays so.
    func testScanAfterTheOwnerRenamedTheNoteMakesNoNewCopy() async throws {
        let setup = makeRecorder(meetingsFolder: false)
        try await record(setup.recorder)
        let copied = await eventually { (try? self.names(in: self.notes)) == ["2026-10-07 11-00-01 Meeting.md"] && setup.queue.activeFolder == nil }
        XCTAssertTrue(copied)
        try FileManager.default.moveItem(
            at: notes.appendingPathComponent("2026-10-07 11-00-01 Meeting.md"),
            to: notes.appendingPathComponent("Планёрка с подрядчиком.md")
        )
        setup.settings.meetingsFolderPath = target.path

        setup.queue.scanLocalFolders()
        let moved = await eventually { !self.exists(self.local.appendingPathComponent(MovingMeetingCapture.name(1))) && setup.queue.activeFolder == nil }

        XCTAssertTrue(moved)
        XCTAssertEqual(try names(in: notes), ["Планёрка с подрядчиком.md"])
    }

    /// Choosing the folder starts a scan: old meetings move without being
    /// transcribed, a partly saved one too, and its warning's "Show…"
    /// follows it.
    func testChosenFolderTakesOldAndPartlySavedMeetingsAndWarningsFollow() async throws {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.4, seed: 9)]
        let old = try MeetingAudio.folder("2026-08-27 10-31-15 Meeting", in: local, microphone: samples, system: samples)
        let setup = makeRecorder(meetingsFolder: false, transcripts: false)
        let compressed = await eventually { setup.queue.activeFolder == nil && !self.exists(old.appendingPathComponent("system.caf")) }
        XCTAssertTrue(compressed, "the launch scan compressed it; with no folder chosen it stays")
        await setup.capture.failNextStop()
        try await record(setup.recorder, expectingFailure: true)
        XCTAssertNotNil(setup.recorder.recordingWarning)

        setup.settings.meetingsFolderPath = target.path
        setup.queue.scanLocalFolders()
        let moved = await eventually { (try? self.names(in: self.local)) == [] && setup.queue.activeFolder == nil }

        XCTAssertTrue(moved)
        XCTAssertEqual(try names(in: target), [old.lastPathComponent, MovingMeetingCapture.name(1)])
        XCTAssertEqual(setup.transcriptions.get(), 0, "a scan never transcribes")
        XCTAssertEqual(setup.recorder.warnedRecordingLocation?.path, target.appendingPathComponent(MovingMeetingCapture.name(1)).path)
    }

    /// The panel opens in the chosen folder without checking it is there.
    func testPanelOpensInTheMeetingsFolderUnchecked() throws {
        let destinations = Box(MeetingTranscriptionQueue.Destinations())
        let queue = makeQueue(destinations: { destinations.get() }, transcriptions: Box(0))
        XCTAssertEqual(queue.panelDirectory, local)

        let away = base.appendingPathComponent("Unplugged/Meetings", isDirectory: true)
        destinations.set(.init(meetings: away, transcripts: nil))
        XCTAssertEqual(queue.panelDirectory, away)
        XCTAssertFalse(exists(away))
    }

    /// Asked for after an earlier job moved the folder: it is transcribed
    /// where it is now, and left there.
    func testFolderQueuedAfterItMovedIsTranscribedWhereItIsNow() async throws {
        let samples = [MeetingAudio.noise(count: 48_000, amplitude: 0.4, seed: 3)]
        let folder = try MeetingAudio.folder("2026-10-07 12-00-00 Meeting", in: local, microphone: samples, system: samples)
        let place = try MeetingStorage.move(folder, into: target, localRoot: local)
        let transcriptions = Box(0)
        let target = self.target!
        let queue = makeQueue(
            destinations: { .init(meetings: target, transcripts: nil) }, transcriptions: transcriptions
        )

        queue.enqueue(folder)
        let done = await eventually { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(queue.lastOutcome, .saved(place.appendingPathComponent("transcript.md")))
        XCTAssertEqual(try names(in: place), ["metadata.json", "microphone.caf", "system.caf", "transcript.md"],
                       "outside the local root nothing is compressed or moved")
        XCTAssertEqual(try MeetingAttempt.entries(in: place).map(\.attempt?.transcript), ["transcript.md"])
    }

    // MARK: - What a job must not touch

    /// A recording in progress has no metadata yet; without the recorder to
    /// say so, it is a recording cut off before its stop. Asked for by hand,
    /// it is transcribed as far as it goes; whatever the transcription ends
    /// in, here a failure, no move follows: the tracks stay where the capture
    /// wrote them, untouched, beside the attempt's record.
    func testRecordingInProgressAskedForByHandIsNeverMoved() async throws {
        let samples = [MeetingAudio.noise(count: 48_000, amplitude: 0.4, seed: 4)]
        let live = local.appendingPathComponent("2026-10-07 13-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try MeetingAudio.write(samples, to: live.appendingPathComponent("system.caf"))
        try MeetingAudio.write(samples, to: live.appendingPathComponent("microphone.caf"))
        let before = try MeetingAudio.digests(of: live)
        let target = self.target!
        let queue = makeQueue(
            destinations: { .init(meetings: target, transcripts: nil) }, transcriptions: Box(0),
            detector: { _ in throw CocoaError(.fileReadCorruptFile) }
        )

        queue.enqueue(live)
        let done = await eventually { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(done)
        guard case .failed(let folder, _)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertEqual(folder.path, live.path)
        XCTAssertEqual(try MeetingAudio.digests(of: live).filter { MeetingAttempt.number(inName: $0.key) == nil }, before)
        XCTAssertEqual(try MeetingAttempt.entries(in: live).map(\.attempt?.result), [.failed])
        XCTAssertEqual(try names(in: target), [])
        XCTAssertEqual(
            queue.issues[live.standardizedFileURL]?.lines,
            ["move: “2026-10-07 13-00-00 Meeting” — recording not finished, it stays on this Mac"]
        )
    }

    /// The junction "queue's failed move → Storage settings": a different
    /// meeting already holds the name in the meetings folder, so the move
    /// fails while the folder is there, and the waiting line points to the
    /// reasons below. The line must ask the queue whether a move failed, not
    /// look for words in the issue: those words are translated.
    func testFailedMoveSendsTheStorageLineToTheReasonsBelow() async throws {
        let setup = makeRecorder()
        let name = MovingMeetingCapture.name(1)
        let folder = local.appendingPathComponent(name, isDirectory: true)
        let other = target.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("another meeting".utf8).write(to: other.appendingPathComponent("metadata.json"))

        try await record(setup.recorder)
        let waiting = await eventually {
            setup.queue.activeFolder == nil && setup.queue.issues[folder.standardizedFileURL]?.move != nil
        }
        XCTAssertTrue(waiting)

        let snapshot = await refreshed(setup.settings)
        XCTAssertEqual(
            StorageSettingsView.waitingLine(snapshot?.meetingsFolder, busy: false, issues: setup.queue.issues),
            "1 meeting waiting to move: reasons below"
        )
    }

    // MARK: - Storage settings: what is counted, and when

    /// №12, the junction "access is back without a mount → Move Now": the
    /// folder could not be reached (no permission), so the meeting waits;
    /// permission returns without any volume event, and the button's scan and
    /// recount move it and clear the reason.
    func testMoveNowMovesOnceAccessIsBackWithoutAMount() async throws {
        let disk = target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: disk.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: disk.path) }
        let setup = makeRecorder()
        let folder = local.appendingPathComponent(MovingMeetingCapture.name(1), isDirectory: true)

        try await record(setup.recorder)
        let waiting = await eventually {
            setup.queue.activeFolder == nil && setup.queue.issues[folder.standardizedFileURL]?.move != nil
        }
        XCTAssertTrue(waiting)
        let before = await refreshed(setup.settings)
        XCTAssertEqual(before?.meetingsFolder?.available, false)
        XCTAssertEqual(
            StorageSettingsView.waitingLine(before?.meetingsFolder, busy: false, issues: setup.queue.issues),
            "1 meeting waiting to move: the folder isn’t available — check the drive or network, then Move Now"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: disk.path)
        setup.queue.scanLocalFolders()
        let moved = await eventually { !self.exists(folder) && setup.queue.activeFolder == nil }
        let after = await refreshed(setup.settings)

        XCTAssertTrue(moved)
        XCTAssertTrue(exists(target.appendingPathComponent(folder.lastPathComponent).appendingPathComponent("transcript.md")))
        XCTAssertEqual(after?.meetingsFolder?.available, true)
        XCTAssertEqual(after?.meetingsFolder?.waiting, 0)
        XCTAssertNil(StorageSettingsView.waitingLine(after?.meetingsFolder, busy: false, issues: setup.queue.issues))
        XCTAssertEqual(setup.queue.issues, [:])
    }

    /// №11: each folder has its own availability, read in the same refresh.
    func testTranscriptsFolderAvailabilityIsItsOwn() async throws {
        let missing = base.appendingPathComponent("Unplugged/Notes", isDirectory: true)

        let notesAway = await refreshed(meetingsFolder: target, transcriptsFolder: missing)
        XCTAssertEqual(notesAway?.meetingsFolder?.available, true)
        XCTAssertEqual(notesAway?.transcriptsFolderPath, missing.path)
        XCTAssertEqual(notesAway?.transcriptsFolderAvailable, false)

        let meetingsAway = await refreshed(meetingsFolder: missing, transcriptsFolder: notes)
        XCTAssertEqual(meetingsAway?.meetingsFolder?.available, false)
        XCTAssertEqual(meetingsAway?.transcriptsFolderPath, notes.path)
        XCTAssertEqual(meetingsAway?.transcriptsFolderAvailable, true)
    }

    /// №9: this Mac's figures are out before the meetings folder answers,
    /// and the folder's figures follow when it does.
    func testLocalFiguresDoNotWaitForTheMeetingsFolder() async throws {
        let gate = FolderGate()
        let published = Box<[ArchiveSnapshot]>([])
        let running = Task { await refresh(through: gate, into: published) }

        let local = await eventually { published.get().count == 1 && gate.entered.get() }
        XCTAssertTrue(local, "the local figures waited for the meetings folder")
        XCTAssertEqual(published.get().first?.dictationCount, 3)
        XCTAssertNil(published.get().first?.meetingsFolder, "no folder figures before the folder answered")

        gate.open.set(true)
        await running.value
        XCTAssertEqual(published.get().count, 2)
        XCTAssertEqual(published.get().last?.meetingsFolder?.path, target.path)
        XCTAssertEqual(published.get().last?.meetingsFolder?.available, true)
    }

    /// №9: a refresh replaced by a newer one (another folder, Try Again) never
    /// publishes its folder's late answer.
    func testCancelledRefreshDropsTheFoldersLateAnswer() async throws {
        let gate = FolderGate()
        let published = Box<[ArchiveSnapshot]>([])
        let running = Task { await refresh(through: gate, into: published) }
        let local = await eventually { published.get().count == 1 && gate.entered.get() }
        XCTAssertTrue(local)

        running.cancel()
        gate.open.set(true)
        await running.value
        XCTAssertEqual(published.get().count, 1, "the cancelled refresh published its folder's answer")
    }

    /// Between the capture's stop and the recorder's own last write the
    /// folder already looks finished. A job for it then, here asked for by
    /// hand, neither compresses nor moves it; the scan after the stop does.
    func testFolderOfAStopInProgressWaitsForTheStopToEnd() async throws {
        let folder = local.appendingPathComponent("2026-10-07 14-00-00 Meeting", isDirectory: true)
        let held = HeldStopCapture(folder: folder)
        let setup = makeRecorder(transcripts: false, capture: held)
        setup.settings.meetingAfterStop = .nothing
        setup.recorder.toggle()
        let started = await eventually { setup.recorder.state == .recording }
        XCTAssertTrue(started)

        setup.recorder.toggle()
        let written = await eventually {
            self.exists(folder.appendingPathComponent("metadata.json")) && setup.recorder.state == .stopping
        }
        XCTAssertTrue(written)
        setup.queue.enqueue(folder, transcribe: false)
        let passed = await eventually { setup.queue.finishedJobs == 1 }

        XCTAssertTrue(passed)
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.caf", "system.caf"])
        XCTAssertEqual(try names(in: target), [])

        await held.release()
        let moved = await eventually {
            !self.exists(folder) && setup.recorder.state == .idle && setup.queue.activeFolder == nil
        }

        XCTAssertTrue(moved)
        XCTAssertEqual(
            try names(in: target.appendingPathComponent(folder.lastPathComponent)),
            ["metadata.json", "microphone.m4a", "system.m4a"]
        )
        XCTAssertEqual(setup.queue.issues, [:])
    }

    /// A folder chosen by hand outside the local root is where it was
    /// chosen, even with its volume gone: the main actor never asks the disk
    /// about it, so it is neither looked for in the meetings folder nor shown
    /// there.
    func testFolderChosenOutsideTheLocalRootStaysWhereItWasChosen() async throws {
        let gone = URL(
            fileURLWithPath: "/Volumes/Murmurly-test-\(UUID().uuidString)/2026-10-07 15-00-00 Meeting",
            isDirectory: true
        )
        let target = self.target!
        let queue = makeQueue(
            destinations: { .init(meetings: target, transcripts: nil) }, transcriptions: Box(0)
        )

        queue.enqueue(gone)
        let done = await eventually { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(done)
        guard case .failed(let folder, _)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertEqual(folder.path, gone.path)
        XCTAssertEqual(queue.lastMeeting?.path, gone.path, "no disk was asked where it went")
    }

    // MARK: - Choosing the meetings folder

    /// The check of folder A (a slow network volume) finishes after the user
    /// already chose B: B stays, and A is reported as superseded, so the view
    /// starts no scan for it.
    func testLaterChoiceWinsOverASlowCheckOfAnEarlierOne() async throws {
        let settings = SettingsStore(defaults: defaults)
        let slow = base.appendingPathComponent("Slow/Meetings", isDirectory: true)
        let resolve = slowResolver(for: slow)

        let first = Task { await settings.chooseMeetingsFolder(slow, localRoot: local, resolve: resolve.call) }
        let checking = await eventually { resolve.entered.get() }
        XCTAssertTrue(checking)
        let second = await settings.chooseMeetingsFolder(target, localRoot: local, resolve: resolve.call)

        XCTAssertEqual(second, .applied)
        XCTAssertEqual(settings.meetingsFolderPath, target.path)
        resolve.gate.set(true)
        let late = await first.value
        XCTAssertEqual(late, .superseded)
        XCTAssertEqual(settings.meetingsFolderPath, target.path)

        let inside = await settings.chooseMeetingsFolder(local.appendingPathComponent("Old", isDirectory: true), localRoot: local)
        XCTAssertEqual(inside, .insideLocalRoot)
        XCTAssertEqual(settings.meetingsFolderPath, target.path)
    }

    /// The meetings folder cannot be the dictation archive or a
    /// folder in it: Clear All in History would take the meetings with it.
    func testMeetingsFolderInsideTheDictationArchiveIsRefused() async throws {
        let settings = SettingsStore(defaults: defaults)
        let inside = DictationHistoryStore.defaultRoot().appendingPathComponent("Meetings", isDirectory: true)

        let choice = await settings.chooseMeetingsFolder(inside, localRoot: local)

        XCTAssertNotEqual(choice, .applied, "a folder in the dictation archive was accepted")
        XCTAssertNil(settings.meetingsFolderPath)
    }

    /// The transcripts folder cannot be in the dictation archive either; any
    /// other folder is taken.
    func testTranscriptsFolderInsideTheDictationArchiveIsRefused() async throws {
        let settings = SettingsStore(defaults: defaults)
        let inside = DictationHistoryStore.defaultRoot().appendingPathComponent("Notes", isDirectory: true)

        let refused = await settings.chooseTranscriptsFolder(inside)
        XCTAssertEqual(refused, .insideDictationArchive)
        XCTAssertNil(settings.transcriptsFolderPath)

        let taken = await settings.chooseTranscriptsFolder(target)
        XCTAssertEqual(taken, .applied)
        XCTAssertEqual(settings.transcriptsFolderPath, target.path)
        let meetings = await settings.chooseMeetingsFolder(
            DictationHistoryStore.defaultRoot(), localRoot: local
        )
        XCTAssertEqual(meetings, .insideDictationArchive)
    }

    /// The user pressed "Reset to Default" while A was being checked: the
    /// reset stays.
    func testResetWinsOverASlowCheck() async throws {
        let settings = SettingsStore(defaults: defaults)
        settings.meetingsFolderPath = target.path
        let slow = base.appendingPathComponent("Slow/Meetings", isDirectory: true)
        let resolve = slowResolver(for: slow)

        let first = Task { await settings.chooseMeetingsFolder(slow, localRoot: local, resolve: resolve.call) }
        let checking = await eventually { resolve.entered.get() }
        XCTAssertTrue(checking)
        settings.meetingsFolderPath = nil
        resolve.gate.set(true)
        let late = await first.value

        XCTAssertEqual(late, .superseded)
        XCTAssertNil(settings.meetingsFolderPath)
    }

    /// The user pressed "Don’t Copy" while a new
    /// transcripts folder was being checked: no copies stay the decision.
    func testDontCopyWinsOverASlowCheckOfTheTranscriptsFolder() async throws {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptsFolderPath = target.path
        let slow = base.appendingPathComponent("Slow/Notes", isDirectory: true)
        let resolve = slowResolver(for: slow)

        let first = Task { await settings.chooseTranscriptsFolder(slow, resolve: resolve.call) }
        let checking = await eventually { resolve.entered.get() }
        XCTAssertTrue(checking)
        settings.transcriptsFolderPath = nil
        resolve.gate.set(true)
        _ = await first.value

        XCTAssertNil(settings.transcriptsFolderPath, "a late check turned copying back on after Don’t Copy")
    }

    /// A transcripts folder chosen while an earlier
    /// choice was still being checked stays when that check finishes.
    func testLaterTranscriptsFolderWinsOverASlowCheckOfAnEarlierOne() async throws {
        let settings = SettingsStore(defaults: defaults)
        let slow = base.appendingPathComponent("Slow/Notes", isDirectory: true)
        let resolve = slowResolver(for: slow)

        let first = Task { await settings.chooseTranscriptsFolder(slow, resolve: resolve.call) }
        let checking = await eventually { resolve.entered.get() }
        XCTAssertTrue(checking)
        _ = await settings.chooseTranscriptsFolder(target, resolve: resolve.call)
        XCTAssertEqual(settings.transcriptsFolderPath, target.path)
        resolve.gate.set(true)
        _ = await first.value

        XCTAssertEqual(settings.transcriptsFolderPath, target.path, "an earlier choice replaced a later one")
    }

    /// Resolves every path as it is, but holds `slow` until the gate opens.
    private func slowResolver(
        for slow: URL
    ) -> (call: @Sendable (URL) async -> String, entered: Box<Bool>, gate: Box<Bool>) {
        let entered = Box(false)
        let gate = Box(false)
        let call: @Sendable (URL) async -> String = { url in
            if url.path == slow.path {
                entered.set(true)
                while !gate.get() { try? await Task.sleep(for: .milliseconds(10)) }
            }
            return url.path
        }
        return (call, entered, gate)
    }

    // MARK: - Helpers

    /// Holds the meetings folder's answer until opened.
    private struct FolderGate {
        let entered = Box(false)
        let open = Box(false)
    }

    private func refresh(through gate: FolderGate, into published: Box<[ArchiveSnapshot]>) async {
        await ArchiveSnapshot.refresh(
            history: (3, nil),
            meetingsFolder: target,
            transcriptsFolder: nil,
            previous: nil,
            dictationsRoot: base.appendingPathComponent("Dictations", isDirectory: true),
            meetingsRoot: local,
            loadFolder: { folder, meetingsRoot in
                gate.entered.set(true)
                while !gate.open.get() { try? await Task.sleep(for: .milliseconds(10)) }
                return ArchiveSnapshot.loadMeetingsFolder(folder, meetingsRoot: meetingsRoot)
            }
        ) { published.append($0) }
    }

    /// The last snapshot a whole refresh published, as Storage shows it.
    private func refreshed(_ settings: SettingsStore) async -> ArchiveSnapshot? {
        await refreshed(
            meetingsFolder: settings.meetingDestinations.meetings,
            transcriptsFolder: settings.meetingDestinations.transcripts
        )
    }

    private func refreshed(meetingsFolder: URL?, transcriptsFolder: URL?) async -> ArchiveSnapshot? {
        var last: ArchiveSnapshot?
        await ArchiveSnapshot.refresh(
            history: (0, nil),
            meetingsFolder: meetingsFolder,
            transcriptsFolder: transcriptsFolder,
            previous: nil,
            dictationsRoot: base.appendingPathComponent("Dictations", isDirectory: true),
            meetingsRoot: local
        ) { last = $0 }
        return last
    }

    private struct Setup {
        let recorder: MeetingRecorder
        let queue: MeetingTranscriptionQueue
        let capture: MovingMeetingCapture
        let shown: Box<[URL]>
        let transcriptions: Box<Int>
        let settings: SettingsStore
    }

    /// Both the recorder and the queue read the two folders from the settings
    /// store, as the app wires them.
    private func makeRecorder(
        meetingsFolder: Bool = true,
        transcripts: Bool = true,
        capture other: (any MeetingCaptureBackend)? = nil
    ) -> Setup {
        let settings = SettingsStore(defaults: defaults)
        settings.meetingAfterStop = .transcribe
        settings.meetingsFolderPath = meetingsFolder ? target.path : nil
        settings.transcriptsFolderPath = transcripts ? notes.path : nil
        let shown = Box<[URL]>([])
        let transcriptions = Box(0)
        let queue = makeQueue(
            destinations: { settings.meetingDestinations }, transcriptions: transcriptions
        )
        let capture = MovingMeetingCapture(root: local)
        let recorder = MeetingRecorder(
            capture: other ?? capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            fileViewer: { shown.append($0) }
        )
        recorder.transcripts = queue
        recorder.activate(
            settings: settings,
            permissions: PermissionManager(),
            dictation: DictationCoordinator(mic: NoMic(), indicator: RecordingIndicator(renderingEnabled: false))
        )
        let setup = Setup(
            recorder: recorder, queue: queue, capture: capture,
            shown: shown, transcriptions: transcriptions, settings: settings
        )
        keepAlive.append(setup)
        return setup
    }

    /// The recorder holds settings and queue weakly, as the app's state
    /// objects do; the test keeps them alive.
    private var keepAlive: [Setup] = []

    private func makeQueue(
        destinations: @escaping @MainActor () -> MeetingTranscriptionQueue.Destinations,
        transcriptions: Box<Int>,
        detector: MeetingTranscriber.SpeechDetector? = nil
    ) -> MeetingTranscriptionQueue {
        MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: SpeakingEngineFactory()),
                loadSpeechDetector: { _ in
                    transcriptions.set(transcriptions.get() + 1)
                    return detector ?? { source in source.sampleCount >= 16_000 ? [0..<16_000] : [] }
                },
                currentEngine: { _ in
                    MeetingTranscriber.Engine(
                        descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                        request: .whisper(WhisperDecodeRequest(language: "ru")),
                        label: "Whisper (whisper)"
                    )
                },
                temporaryRoot: base
            ),
            meetingsRoot: local,
            destinations: destinations
        )
    }

    private func record(_ recorder: MeetingRecorder, expectingFailure: Bool = false) async throws {
        recorder.toggle()
        let started = await eventually { recorder.state == .recording }
        XCTAssertTrue(started)
        recorder.toggle()
        let stopped = await eventually { expectingFailure ? !recorder.isBusy : recorder.state == .idle }
        XCTAssertTrue(stopped)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Attempt records are checked on their own (`MeetingAttempt.entries`).
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { MeetingAttempt.number(inName: $0) == nil }.sorted()
    }

    private func eventually(
        within limit: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
