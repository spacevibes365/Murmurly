import AVFoundation
import Combine
import CryptoKit
import UniformTypeIdentifiers
import XCTest
@testable import Murmurly

/// Holds a folder's reads on the library's own queue until the test lets
/// them go, and counts them: a dead network volume, a slow disk. Writes of a
/// meeting's marks have a gate and a count of their own. A folder is known by
/// its path with links resolved: one folder reached two ways is one.
private final class DiskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var reads: [String: Int] = [:]
    private var heldAnswers: Set<String> = []
    private var answers: [String: Int] = [:]
    private var heldWrites: Set<String> = []
    private var writes: [String: Int] = [:]
    /// The numbers of a folder's writes that fail.
    private var failing: [String: Set<Int>] = [:]

    private func key(_ folder: URL) -> String { folder.resolvingSymlinksInPath().standardizedFileURL.path }

    func hold(_ folder: URL) { lock.withLock { _ = held.insert(key(folder)) } }
    func release(_ folder: URL) { lock.withLock { _ = held.remove(key(folder)) } }
    func reads(of folder: URL) -> Int { lock.withLock { reads[key(folder), default: 0] } }

    /// A read of the folder done, its answer held back until released.
    func holdAnswer(_ folder: URL) { lock.withLock { _ = heldAnswers.insert(key(folder)) } }
    func releaseAnswer(_ folder: URL) { lock.withLock { _ = heldAnswers.remove(key(folder)) } }
    func answers(of folder: URL) -> Int { lock.withLock { answers[key(folder), default: 0] } }

    func holdWrites(_ folder: URL) { lock.withLock { _ = heldWrites.insert(key(folder)) } }
    func releaseWrites(_ folder: URL) { lock.withLock { _ = heldWrites.remove(key(folder)) } }
    /// Writes of the folder's marks started so far, held or not.
    func writes(of folder: URL) -> Int { lock.withLock { writes[key(folder), default: 0] } }
    /// The `number`-th write of the folder's marks fails.
    func failWrite(_ folder: URL, number: Int) { lock.withLock { _ = failing[key(folder), default: []].insert(number) } }
    /// The next write of this folder's marks fails, once.
    func failNextWrite(_ folder: URL) { failWrite(folder, number: writes(of: folder) + 1) }

    func pass(_ folder: URL) {
        let path = key(folder)
        lock.withLock { reads[path, default: 0] += 1 }
        while lock.withLock({ held.contains(path) }) { Thread.sleep(forTimeInterval: 0.005) }
    }

    private func answer(_ folder: URL) {
        let path = key(folder)
        lock.withLock { answers[path, default: 0] += 1 }
        while lock.withLock({ heldAnswers.contains(path) }) { Thread.sleep(forTimeInterval: 0.005) }
    }

    /// Throws when this write is one that fails.
    func passWrite(_ folder: URL) throws {
        let path = key(folder)
        let number = lock.withLock { () -> Int in
            writes[path, default: 0] += 1
            return writes[path]!
        }
        while lock.withLock({ heldWrites.contains(path) }) { Thread.sleep(forTimeInterval: 0.005) }
        if lock.withLock({ failing[path]?.remove(number) != nil }) { throw CocoaError(.fileWriteVolumeReadOnly) }
    }

    /// The disk as the app reads it, each read passing this gate first: a
    /// root's list by the root, a text by its meeting's folder; a meeting's
    /// marks are written past the write gate of the meeting's folder.
    var reader: MeetingLibrary.Reader {
        MeetingLibrary.Reader(
            root: { folder, place in
                self.pass(folder)
                let result = MeetingLibrary.readRoot(folder, place: place)
                self.answer(folder)
                return result
            },
            meeting: { folder in
                self.pass(folder)
                let result = MeetingLibrary.readOutside(folder)
                self.answer(folder)
                return result
            },
            text: { self.pass($0.deletingLastPathComponent()); return try String(contentsOf: $0, encoding: .utf8) },
            writeMarks: { change, folder, identity in
                try self.passWrite(folder)
                return try MeetingMarks.write(change, in: folder, expecting: identity)
            }
        )
    }
}

/// Records into the folder the recorder made: tracks from the start,
/// metadata at the stop, as the real backend.
private actor LibraryCapture: MeetingCaptureBackend {
    private var directory: URL?
    /// The stop writes no metadata and says the recording was saved only in
    /// part, as a stop whose metadata could not be written does.
    private let failsStop: Bool

    init(failsStop: Bool = false) { self.failsStop = failsStop }

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
        if failsStop { throw SystemAudioCaptureError.captureFailed(message: "metadata not written", savedAt: directory) }
        let metadata = MeetingMetadata(
            startedAt: "2026-10-15T10:00:00Z", endedAt: "2026-10-15T10:01:30Z",
            sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

/// A latch for the queue's mover, which runs on a thread of its own.
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

/// Counts calls made on any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@MainActor
private final class UpdateWatch {
    var value = false
}

private actor SilentLibraryMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// Answers each chunk by the track it came from, told by its level: the
/// microphone's tracks in these tests are quiet, the system's loud. Two
/// different replies at one time, so neither passes for the other's echo.
private struct TrackEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { TrackEngine() }
}

private struct TrackEngine: WhisperEngine {
    static let microphoneWords = "говорю в микрофон"
    static let systemWords = "слышно из колонок"

    func transcribe(audioPath: String, request: WhisperDecodeRequest) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let loud = (samples.map { abs($0) }.max() ?? 0) > 0.3
        return ([WhisperSegmentDTO(text: loud ? Self.systemWords : Self.microphoneWords, start: 0)], "ru")
    }

    /// Three seconds of one level, as a stop writes a track.
    static func writeTrack(level: Float, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        for index in 0..<144_000 { buffer.floatChannelData![0][index] = level }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// The save panel and the write of a transcript saved as a file, as a test
/// holds them. The panel answers with `answer` (a file in the test's own
/// folder), or nothing when cancelled, once it is let go; the write runs
/// where the library runs it, past a gate, and says whether that was the
/// main thread.
private final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var panelHeld = false
    private var writeHeld = false
    private var panelsAsked: [String] = []
    private var ownersAsked: [ObjectIdentifier?] = []
    private var writesDone: [(url: URL, main: Bool)] = []
    private var failing = false
    private var cancelling = false
    private var answer: URL?

    var panels: [String] { lock.withLock { panelsAsked } }
    /// The window each panel was asked for on.
    var owners: [ObjectIdentifier?] { lock.withLock { ownersAsked } }
    var writes: [(url: URL, main: Bool)] { lock.withLock { writesDone } }
    func holdPanel(_ held: Bool) { lock.withLock { panelHeld = held } }
    func holdWrite(_ held: Bool) { lock.withLock { writeHeld = held } }
    func failWrites(_ fail: Bool) { lock.withLock { failing = fail } }
    func cancelPanels(_ cancel: Bool) { lock.withLock { cancelling = cancel } }
    func answer(_ url: URL) { lock.withLock { answer = url } }

    var saving: MeetingLibrary.Saving {
        MeetingLibrary.Saving(
            destination: { name, _, owner in
                let asked = owner.map(ObjectIdentifier.init)
                self.lock.withLock {
                    self.panelsAsked.append(name)
                    self.ownersAsked.append(asked)
                }
                while self.lock.withLock({ self.panelHeld }) { try? await Task.sleep(for: .milliseconds(5)) }
                return self.lock.withLock { self.cancelling ? nil : self.answer }
            },
            write: { data, url in
                self.lock.withLock { self.writesDone.append((url, Thread.isMainThread)) }
                while self.lock.withLock({ self.writeHeld }) { Thread.sleep(forTimeInterval: 0.005) }
                if self.lock.withLock({ self.failing }) { throw CocoaError(.fileWriteVolumeReadOnly) }
                try data.write(to: url, options: .atomic)
            }
        )
    }
}

/// A door the test opens; a job waits at it before its speech detection.
private final class Door: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func unlock() { lock.withLock { open = true } }
    func pass() async throws {
        while !lock.withLock({ open }) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// The window's model at its seams: the disk under both roots, the
/// recorder's session and the queue's jobs, records and moves.
@MainActor
final class MeetingLibraryTests: XCTestCase {
    private var root: URL!
    private var local: URL!
    private var disk: URL!
    private var settings: SettingsStore!
    private var keepAlive: [AnyObject] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-library-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - What is a meeting, and where

    func testWindowAndStorageCountTheSameMeetings() async throws {
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try seed("2026-07-14 09-00-00 Meeting", in: local, metadata: ["startedAt": "2026-07-14T09:00:00Z", "state": "done"])
        try seed("2026-10-07 11-00-00 Meeting", in: local, metadata: nil, tracks: ["system.caf"])
        try seed("Notes", in: local, metadata: done)
        try seed("2026-10-08 10-00-00 Meeting", in: local, metadata: nil, tracks: [])
        try seed(".2026-10-05 10-00-00 Meeting.removing", in: local, metadata: done)
        let library = makeLibrary()

        library.windowOpened()
        try await until { library.local.fresh }

        let storage = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil,
            dictationsRoot: root.appendingPathComponent("Dictations", isDirectory: true), meetingsRoot: local
        )
        XCTAssertEqual(library.meetings.count, 3)
        XCTAssertEqual(library.meetings.count, storage.meetingCount)
    }

    func testSameNameInBothRootsStaysTwoRows() async throws {
        let name = "2026-10-06 10-00-00 Meeting"
        try seed(name, in: local, metadata: done)
        try seed(name, in: disk, metadata: done)
        settings.meetingsFolderPath = disk.path
        let library = makeLibrary()

        library.windowOpened()
        try await until { library.local.fresh && library.chosen?.fresh == true }

        let rows = library.meetings.filter { $0.name == name }
        XCTAssertEqual(Set(rows.map(\.directory.path)), [local.appendingPathComponent(name).path, disk.appendingPathComponent(name).path])
        XCTAssertEqual(Set(rows.map(\.place)), [.local, .chosen])
        XCTAssertTrue(rows.allSatisfy(library.isInBothPlaces))
    }

    /// The July recordings have no `endedAt`: their length comes from the
    /// frames. A folder with tracks and no metadata broke off before its stop.
    func testDurationsAndRecordingsThatBrokeOff() async throws {
        try seed("2026-07-14 09-00-00 Meeting", in: local, metadata: [
            "startedAt": "2026-07-14T09:00:00Z", "state": "done", "sampleRate": 48_000,
            "segments": [["system": "system.caf", "mic": "microphone.caf", "frames": 4_800_000]],
        ])
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try seed("2026-10-07 11-00-00 Meeting", in: local, metadata: nil, tracks: ["system.caf"])
        let library = makeLibrary()

        library.windowOpened()
        try await until { library.local.fresh }

        let july = try XCTUnwrap(library.meetings.first { $0.name.hasPrefix("2026-07-14") })
        XCTAssertEqual(july.duration ?? 0, 100, accuracy: 0.001)
        let october = try XCTUnwrap(library.meetings.first { $0.name.hasPrefix("2026-10-06") })
        XCTAssertEqual(october.duration ?? 0, 75 * 60, accuracy: 0.001)
        XCTAssertFalse(library.status(of: october).brokenOff)
        let broken = try XCTUnwrap(library.meetings.first { $0.name.hasPrefix("2026-10-07") })
        XCTAssertNil(broken.duration)
        XCTAssertTrue(library.status(of: broken).brokenOff)
        XCTAssertTrue(broken.isShort == false)
    }

    /// A size is a fact about one meeting: unknown when part of it cannot be
    /// read, never what happened to be counted.
    func testSizeIsUnknownWhenPartOfTheFolderCannotBeRead() async throws {
        let whole = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let part = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, files: ["notes/tasks.md": "дела"])
        let locked = part.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let library = makeLibrary()

        library.windowOpened()
        try await until { library.local.fresh }

        XCTAssertEqual(library.meeting(at: whole)?.bytes, MeetingStorage.folderSize(of: whole).bytes)
        XCTAssertNotNil(library.meeting(at: whole)?.bytes)
        XCTAssertNil(library.meeting(at: part)?.bytes)
        XCTAssertEqual(library.meeting(at: part)?.otherFiles, ["notes"])
    }

    /// A meeting that can no longer be read keeps its row and says so,
    /// rather than vanishing from a list that otherwise reads fine.
    func testMeetingThatCannotBeReadKeepsItsRowAndSaysSo() async throws {
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let locked = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh && library.meetings.count == 2 }

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        library.refresh()
        try await until { library.local.fresh }

        let row = try XCTUnwrap(library.meeting(at: locked), "the meeting vanished")
        XCTAssertFalse(row.readable)
        let status = library.status(of: row)
        XCTAssertFalse(status.brokenOff, "a folder that can't be read is not a recording that broke off")
        XCTAssertEqual(MeetingText.status(status).0, "Folder can’t be read")
        XCTAssertEqual(library.transcriptionRefusal(for: locked), "The meeting folder can’t be read.")
    }

    // MARK: - Reading off the main thread

    func testHangingMeetingsFolderDoesNotHoldTheLocalList() async throws {
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try seed("2026-10-06 11-00-00 Meeting", in: disk, metadata: done)
        settings.meetingsFolderPath = disk.path
        let gate = DiskGate()
        gate.hold(disk)
        let library = makeLibrary(reader: gate.reader)
        var seen: [MeetingLibrary.Listing] = []
        let watch = library.$chosen.sink { $0.map { seen.append($0) } }
        defer { watch.cancel() }

        library.windowOpened()
        try await until { library.local.fresh }

        XCTAssertEqual(library.meetings.map(\.place), [.local])
        XCTAssertEqual(library.chosen?.reading, true)
        XCTAssertEqual(library.chosen?.fresh, false)
        try await until { library.chosen?.notResponding == true }
        library.refresh()
        library.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gate.reads(of: disk), 1, "a second read of a folder that does not answer")

        gate.release(disk)
        try await until { library.chosen?.fresh == true }
        XCTAssertEqual(gate.reads(of: disk), 2, "the requests made meanwhile were not read once more")
        XCTAssertTrue(
            seen.contains { $0.state == .read && !$0.reading && !$0.fresh },
            "the read the later requests did not wait for passed for fresh: \(seen.map(\.fresh))"
        )
        XCTAssertEqual(library.chosen?.notResponding, false)
        XCTAssertEqual(Set(library.meetings.map(\.place)), [.local, .chosen])
    }

    func testLateAnswerFromAnEarlierMeetingsFolderIsDropped() async throws {
        let other = root.appendingPathComponent("Other/Meetings", isDirectory: true)
        try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        try seed("2026-10-07 10-00-00 Meeting", in: other, metadata: done)
        settings.meetingsFolderPath = disk.path
        let gate = DiskGate()
        gate.hold(disk)
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { gate.reads(of: disk) == 1 }

        settings.meetingsFolderPath = other.path
        try await until { library.chosen?.fresh == true }
        gate.release(disk)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(library.chosen?.folder.path, other.path)
        XCTAssertEqual(library.meetings.map(\.name), ["2026-10-07 10-00-00 Meeting"])
    }

    /// An answer started before the window was closed and opened again shows
    /// what it read, but is not taken for the fresh one.
    func testReadFromAnEarlierOpeningIsNotFresh() async throws {
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let gate = DiskGate()
        gate.hold(local)
        let library = makeLibrary(reader: gate.reader)
        var seen: [MeetingLibrary.Listing] = []
        let watch = library.$local.sink { seen.append($0) }
        defer { watch.cancel() }

        library.windowOpened()
        try await until { gate.reads(of: self.local) == 1 }
        library.windowClosed()
        library.windowOpened()
        gate.release(local)
        try await until { library.local.fresh }

        XCTAssertEqual(gate.reads(of: local), 2)
        XCTAssertTrue(
            seen.contains { $0.state == .read && !$0.reading && !$0.fresh },
            "the earlier opening's read passed for fresh: \(seen.map(\.fresh))"
        )
    }

    /// A new request makes the snapshot shown not fresh until a read made
    /// for it answers: what was read before may already be out of date.
    func testANewRequestMakesTheSnapshotNotFreshUntilItIsRead() async throws {
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh }
        gate.hold(local)

        library.refresh()

        XCTAssertFalse(library.local.fresh, "the snapshot read before the request passes for fresh")
        gate.release(local)
        try await until { library.local.fresh }
    }

    /// Reads happen only while the window is open: a read under way ends,
    /// but what was asked for meanwhile waits for the window to open again.
    func testNothingIsReadAfterTheWindowCloses() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("первая")])
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh }
        library.select(meeting)
        try await until { self.shownLines(library) == ["первая"] }
        gate.hold(local)
        library.refresh()
        try await until { gate.reads(of: self.local) == 2 }
        library.refresh()

        library.windowClosed()
        let (lists, texts) = (gate.reads(of: local), gate.reads(of: meeting))
        gate.release(local)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(gate.reads(of: local), lists, "a read started after the window closed")
        XCTAssertEqual(gate.reads(of: meeting), texts, "a text was read after the window closed")
        library.windowOpened()
        try await until { library.local.fresh }
        XCTAssertGreaterThan(gate.reads(of: local), lists)
    }

    /// A transcription that ends while the folder is being read asks for
    /// one more read: the one under way may have missed its transcript.
    func testQueueResultDuringARunningReadAsksForAnother() async throws {
        try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let documents = root.appendingPathComponent("Документы", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let gate = DiskGate()
        gate.hold(local)
        let queue = makeQueue()
        let library = makeLibrary(queue: queue, reader: gate.reader)
        var seen: [MeetingLibrary.Listing] = []
        let watch = library.$local.sink { seen.append($0) }
        defer { watch.cancel() }
        library.windowOpened()
        try await until { gate.reads(of: self.local) == 1 }

        queue.enqueue(documents)
        try await until { queue.lastOutcome != nil }
        try await Task.sleep(for: .milliseconds(50))
        gate.release(local)

        try await until { library.local.fresh }
        XCTAssertEqual(gate.reads(of: local), 2)
        XCTAssertTrue(
            seen.contains { $0.state == .read && !$0.reading && !$0.fresh },
            "the read started before the transcript passed for fresh: \(seen.map(\.fresh))"
        )
    }

    /// A text reaches the screen only for the meeting and version it was
    /// read for: one chosen and left while its read was held never shows.
    func testTextOnlyForTheMeetingItWasReadFor() async throws {
        let first = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("первая")])
        let second = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("вторая")])
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        var shown: [MeetingLibrary.Text] = []
        let watch = library.$text.sink { shown.append($0) }
        defer { watch.cancel() }
        library.windowOpened()
        try await until { library.local.fresh }

        gate.hold(first)
        library.select(first)
        try await until { gate.reads(of: first) == 1 }
        library.select(second)
        gate.release(first)
        try await until { if case .loaded = library.text { true } else { false } }
        try await Task.sleep(for: .milliseconds(50))

        guard case .loaded(let text) = library.text else { return XCTFail("\(library.text)") }
        XCTAssertEqual(text.lines?.map(\.text), ["вторая"])
        XCTAssertFalse(shown.contains { if case .loaded(let text) = $0 { text.raw.contains("первая") } else { false } })
    }

    /// "Refresh" reads the shown transcript again, keeping its version: a
    /// change made outside shows, and a read that failed is tried again.
    func testRefreshReadsTheShownTranscriptAgainAndRetriesAFailedOne() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("первая")])
        let file = meeting.appendingPathComponent("transcript.md")
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh }
        library.select(meeting)
        try await until { self.shownLines(library) == ["первая"] }

        try Data(transcript("исправленная").utf8).write(to: file)
        library.refresh()
        try await until { self.shownLines(library) == ["исправленная"] }

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        library.refresh()
        try await until { if case .failed = library.text { true } else { false } }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        library.refresh()
        try await until { self.shownLines(library) == ["исправленная"] }
        XCTAssertEqual(library.version, "transcript.md")
    }

    private func shownLines(_ library: MeetingLibrary) -> [String]? {
        guard case .loaded(let text) = library.text else { return nil }
        return text.lines?.map(\.text)
    }

    // MARK: - The recorder

    /// From the live row to an ordinary one: at no moment, not even before
    /// the folder is read again, does the meeting pass for one that broke off.
    func testStoppedRecordingBecomesAnOrdinaryRowWithoutPassingForBroken() async throws {
        let recorder = makeRecorder()
        let gate = DiskGate()
        let library = makeLibrary(recorder: recorder, reader: gate.reader)
        library.windowOpened()
        recorder.toggle()
        try await until { recorder.state == .recording }
        let live = MeetingLibrary.canonical(try XCTUnwrap(recorder.currentSession?.directory))
        library.refresh()
        try await until { library.local.fresh && library.meeting(at: live) != nil }
        XCTAssertFalse(library.meetings.contains { $0.directory == live }, "the recording under way is not a list row")
        let during = library.status(of: try XCTUnwrap(library.meeting(at: live)))
        guard case .recording? = during.operation else { return XCTFail("\(during)") }
        XCTAssertFalse(during.brokenOff)

        // A read that passed the gate already ends now, before the stop:
        // every later one waits, so the snapshot stays the recording's.
        gate.hold(local)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(library.meeting(at: live)?.state, "the recording's snapshot has metadata before its stop")
        recorder.toggle()
        try await until { recorder.state == .idle && recorder.currentSession == nil }
        let stale = try XCTUnwrap(library.meeting(at: live))
        XCTAssertNil(stale.state, "the check proves nothing: the snapshot already has the metadata")
        XCTAssertEqual(library.status(of: stale).operation, .saving)
        XCTAssertFalse(library.status(of: stale).brokenOff)

        gate.release(local)
        try await until { library.local.fresh && library.meeting(at: live)?.state == "done" }
        let saved = try XCTUnwrap(library.meetings.first { $0.directory == live })
        XCTAssertEqual(library.status(of: saved).operation, nil)
        XCTAssertFalse(library.status(of: saved).brokenOff)
        XCTAssertEqual(library.sourceName(of: saved.trigger), "Manual")
        XCTAssertNil(library.transcriptionRefusal(for: live))
    }

    /// A stop whose metadata could not be written: once the folder is read
    /// after it, the recording is one that broke off, with its actions, not
    /// "saving" for ever.
    func testStopWithoutMetadataIsNotSavingForEver() async throws {
        let recorder = makeRecorder(failsStop: true)
        let library = makeLibrary(recorder: recorder)
        library.windowOpened()
        recorder.toggle()
        try await until { recorder.state == .recording }
        let live = MeetingLibrary.canonical(try XCTUnwrap(recorder.currentSession?.directory))
        recorder.toggle()
        try await until { recorder.currentSession == nil }
        guard case .failed = recorder.state else { return XCTFail("\(recorder.state)") }

        library.refresh()
        try await until { library.local.fresh && library.meeting(at: live) != nil }

        let row = try XCTUnwrap(library.meeting(at: live))
        XCTAssertNil(row.state)
        XCTAssertNil(library.status(of: row).operation, "a stop that ended passes for saving")
        XCTAssertTrue(library.status(of: row).brokenOff)
        XCTAssertNil(library.transcriptionRefusal(for: live))
    }

    func testRecordingUnderWayCannotBeTranscribed() async throws {
        let recorder = makeRecorder()
        let queue = makeQueue()
        recorder.transcripts = queue
        let library = makeLibrary(recorder: recorder, queue: queue)
        library.windowOpened()
        recorder.toggle()
        try await until { recorder.state == .recording }
        let live = try XCTUnwrap(recorder.currentSession?.directory)

        XCTAssertNotNil(library.transcriptionRefusal(for: live))
        XCTAssertFalse(library.transcribe(live))
        XCTAssertTrue(queue.pending.isEmpty && queue.activeJob == nil)
        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    // MARK: - The queue

    /// What the queue is doing to each folder: the job under way in the
    /// menu's words, a transcription waiting, and a waiting scan that is no
    /// transcription at all.
    func testRowsShowTheQueuesWorkInTheMenusWords() async throws {
        let active = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let waiting = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let scanned = try seed("2026-10-06 12-00-00 Meeting", in: local, metadata: done)
        let door = Door()
        let queue = makeQueue(door: door)
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }

        queue.enqueue(active)
        queue.enqueue(waiting)
        queue.enqueue(scanned, transcribe: false)
        try await until { queue.isTranscribing }

        func operation(_ folder: URL) throws -> MeetingLibrary.Status.Operation? {
            library.status(of: try XCTUnwrap(library.meeting(at: folder))).operation
        }
        XCTAssertEqual(try operation(active), .working(try XCTUnwrap(queue.stepLabel)))
        XCTAssertEqual(try operation(waiting), .queued)
        XCTAssertNil(try operation(scanned), "a scan is not a transcription")
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// The last attempt by number, as its record says; a record that cannot
    /// be read outranks an earlier complete one, which proves nothing then.
    func testOutcomesComeFromTheLastRecord() async throws {
        func folder(_ hour: Int, records: [MeetingAttempt?], transcript: Bool = true) throws -> URL {
            let folder = try seed(
                "2026-10-06 \(hour)-00-00 Meeting", in: local, metadata: done,
                files: transcript ? ["transcript.md": self.transcript("текст")] : [:]
            )
            for (index, record) in records.enumerated() {
                let url = folder.appendingPathComponent(MeetingAttempt.fileName(number: index + 1))
                if let record {
                    var numbered = record
                    numbered.number = index + 1
                    try numbered.write(to: url)
                } else {
                    try Data("{".utf8).write(to: url)
                }
            }
            return folder
        }
        func attempt(_ result: MeetingAttempt.Result, _ change: (inout MeetingAttempt) -> Void = { _ in }) -> MeetingAttempt {
            var attempt = MeetingAttempt(number: 1, startedAt: Date(timeIntervalSince1970: 1_760_000_000))
            attempt.result = result
            attempt.transcript = result == .complete || result == .incomplete ? "transcript.md" : nil
            change(&attempt)
            return attempt
        }
        let complete = try folder(10, records: [attempt(.complete)])
        let gaps = try folder(11, records: [attempt(.incomplete) { $0.failedChunks = 2 }])
        let cut = try folder(12, records: [attempt(.incomplete) { $0.cutShort = true }])
        let silent = try folder(13, records: [attempt(.noSpeech)], transcript: false)
        let failed = try folder(14, records: [attempt(.complete), attempt(.failed) { $0.reason = "нет модели" }])
        let interrupted = try folder(15, records: [attempt(.inProgress)])
        let unknown = try folder(16, records: [attempt(.complete), nil])
        let old = try folder(17, records: [])
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh }

        func status(_ folder: URL) throws -> MeetingLibrary.Status {
            library.status(of: try XCTUnwrap(library.meeting(at: folder)))
        }
        XCTAssertEqual(try status(complete).outcome, .complete)
        XCTAssertEqual(try status(gaps).outcome, .incomplete(cutShort: false, failedChunks: 2, missingTracks: []))
        XCTAssertEqual(try status(cut).outcome, .incomplete(cutShort: true, failedChunks: 0, missingTracks: []))
        XCTAssertEqual(try status(silent).outcome, .noSpeech)
        XCTAssertEqual(try status(failed).outcome, .failed("нет модели"))
        XCTAssertTrue(try status(failed).hasTranscript, "the earlier good text stays")
        XCTAssertEqual(try status(interrupted).outcome, .interrupted)
        XCTAssertEqual(try status(unknown).outcome, .unknown)
        XCTAssertNil(try status(old).outcome)
        XCTAssertTrue(try status(old).hasTranscript)
    }

    /// Through the real queue: the record the job leaves is what the row says.
    func testTranscriptionThroughTheQueueShowsItsResult() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: doneCAF, tracks: [])
        for name in ["system.caf", "microphone.caf"] {
            try SavingMeetingCapture.writeSilence(to: meeting.appendingPathComponent(name))
        }
        let queue = makeQueue(speaks: true)
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }

        XCTAssertTrue(library.transcribe(meeting))
        try await until { queue.lastOutcome != nil && queue.activeJob == nil }
        try await until { library.meeting(at: meeting)?.versions.count == 1 }

        let row = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertEqual(library.status(of: row).outcome, .complete)
        XCTAssertTrue(MeetingLibrary.label(of: try XCTUnwrap(row.versions.first)).hasPrefix("Whisper · "))
    }

    /// The queue moves a meeting to the meetings folder: the selection, its
    /// refusal kept in memory and its queue issues follow it there.
    func testMovedMeetingKeepsItsSelectionAndWhatTheQueueKnows() async throws {
        settings.meetingsFolderPath = disk.path
        let recorder = makeRecorder()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        recorder.transcripts = queue
        let library = makeLibrary(recorder: recorder, queue: queue)
        library.windowOpened()
        recorder.toggle()
        try await until { recorder.state == .recording }
        let live = MeetingLibrary.canonical(try XCTUnwrap(recorder.currentSession?.directory))
        queue.enqueue(live)
        try await until { queue.unrecordedOutcomes[live.path] != nil && queue.activeJob == nil }
        library.select(live)

        recorder.toggle()
        let moved = MeetingLibrary.canonical(disk.appendingPathComponent(live.lastPathComponent, isDirectory: true))
        try await until {
            library.meeting(at: moved) != nil && library.meeting(at: live) == nil
                && library.local.fresh && library.chosen?.fresh == true && queue.activeJob == nil
        }

        XCTAssertEqual(library.selection, moved)
        XCTAssertEqual(library.address(of: live), moved)
        let row = try XCTUnwrap(library.meeting(at: moved))
        guard case .failed? = library.status(of: row).outcome else { return XCTFail("\(library.status(of: row))") }
        XCTAssertNil(library.meeting(at: live))
    }

    /// A meeting the queue moved while the window was closed: opened again,
    /// the window shows it where it went, with its text.
    func testSelectionFollowsAMoveMadeWhileTheWindowWasClosed() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("первая")])
        let moved = MeetingLibrary.canonical(disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true))
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        library.select(meeting)
        try await until { self.shownLines(library) == ["первая"] }
        library.windowClosed()

        queue.enqueue(meeting, transcribe: false)
        try await until { FileManager.default.fileExists(atPath: moved.path) && queue.activeJob == nil }
        library.windowOpened()
        try await until { library.chosen?.fresh == true && library.local.fresh }

        XCTAssertEqual(library.selection, moved, "the window shows a folder that is gone")
        try await until { self.shownLines(library) == ["первая"] }
    }

    /// The queue moves the shown meeting while its text is being read: the
    /// answer for the old address is dropped, and the text is read again
    /// where the meeting went, never left loading.
    func testTextFollowsAMoveThatEndsWhileItIsRead() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("первая")])
        let moved = MeetingLibrary.canonical(disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true))
        let gate = DiskGate()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let library = makeLibrary(queue: queue, reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh }
        gate.hold(meeting)
        library.select(meeting)
        try await until { gate.reads(of: meeting) == 1 }

        queue.enqueue(meeting, transcribe: false)
        try await until { FileManager.default.fileExists(atPath: moved.path) && queue.activeJob == nil }
        try await until { library.selection == moved }
        gate.release(meeting)

        try await until { self.shownLines(library) == ["первая"] }
    }

    /// After the queue moved A to the meetings folder, a copy of A put back
    /// at its old place is a meeting of its own: its row's actions go to it,
    /// not to the one that moved.
    func testFolderPutBackWhereAMeetingMovedFromIsItsOwnMeeting() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let moved = MeetingLibrary.canonical(disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true))
        let door = Door()
        let queue = makeQueue(door: door, destinations: { [settings] in settings!.meetingDestinations })
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        queue.enqueue(meeting, transcribe: false)
        try await until { FileManager.default.fileExists(atPath: moved.path) && queue.activeJob == nil }
        try FileManager.default.copyItem(at: moved, to: meeting)
        library.refresh()
        try await until { library.meeting(at: meeting) != nil && library.meeting(at: moved) != nil }

        XCTAssertEqual(library.address(of: meeting), MeetingLibrary.canonical(meeting))
        XCTAssertTrue(library.transcribe(meeting))
        try await until { queue.activeJob != nil }
        XCTAssertEqual(queue.activeJob?.folder.path, meeting.path, "the copy put back was not the one transcribed")
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    // MARK: - Transcribing from the window

    /// A sheet opened for A and confirmed after the menu showed B still
    /// transcribes A; one confirmed after the queue moved A goes to A's new
    /// address.
    func testTranscriptionGoesToTheMeetingItWasAskedFor() async throws {
        let first = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let second = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let door = Door()
        let queue = makeQueue(door: door)
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        library.select(first)

        library.open(second)
        XCTAssertTrue(library.transcribe(first, choice: .init(engine: .parakeet, language: "en")))

        try await until { queue.activeJob != nil }
        XCTAssertEqual(queue.activeJob?.folder.path, first.path)
        XCTAssertEqual(queue.activeJob?.choice, .init(engine: .parakeet, language: "en"))
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    func testSheetConfirmedAfterTheQueueMovedItsMeetingGoesToTheNewAddress() async throws {
        settings.meetingsFolderPath = disk.path
        let recorder = makeRecorder()
        let door = Door()
        door.unlock()
        let queue = makeQueue(door: door, destinations: { [settings] in settings!.meetingDestinations })
        recorder.transcripts = queue
        let library = makeLibrary(recorder: recorder, queue: queue)
        library.windowOpened()
        recorder.toggle()
        try await until { recorder.state == .recording }
        let asked = MeetingLibrary.canonical(try XCTUnwrap(recorder.currentSession?.directory))
        recorder.toggle()
        let moved = MeetingLibrary.canonical(disk.appendingPathComponent(asked.lastPathComponent, isDirectory: true))
        try await until { FileManager.default.fileExists(atPath: moved.path) && queue.activeJob == nil }
        try await until { library.meeting(at: moved) != nil }

        // The sheet was opened for the meeting's old address.
        XCTAssertTrue(library.transcribe(asked))

        try await until { queue.lastOutcome != nil && queue.activeJob == nil }
        guard case .noSpeech(let folder)? = queue.lastOutcome else {
            return XCTFail("\(String(describing: queue.lastOutcome))")
        }
        XCTAssertEqual(folder.path, moved.path)
    }

    /// Closing the window stops nothing: a transcription asked for from it
    /// goes on, and the window shows its result when it opens again.
    func testTranscriptionGoesOnWithTheWindowClosed() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: doneCAF, tracks: [])
        for name in ["system.caf", "microphone.caf"] {
            try SavingMeetingCapture.writeSilence(to: meeting.appendingPathComponent(name))
        }
        let door = Door()
        let queue = makeQueue(door: door, speaks: true)
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }

        XCTAssertTrue(library.transcribe(meeting))
        try await until { queue.isTranscribing }
        library.windowClosed()
        door.unlock()
        try await until { queue.lastOutcome != nil && queue.activeJob == nil }
        XCTAssertNil(library.meeting(at: meeting)?.versions.first, "the closed window read the disk")

        library.windowOpened()
        try await until { library.local.fresh && library.meeting(at: meeting)?.versions.count == 1 }
        XCTAssertEqual(library.status(of: try XCTUnwrap(library.meeting(at: meeting))).outcome, .complete)
    }

    // MARK: - The menu

    func testOpenRequestSelectsTheMeetingAndKeepsItsVersion() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: [
            "transcript.md": transcript("первая"),
            "transcript 3.md": transcript("третья"),
            "transcript 10.md": transcript("десятая"),
        ])
        let library = makeLibrary()

        library.open(meeting, transcript: "transcript 3.md")
        library.windowOpened()
        try await until { if case .loaded = library.text { true } else { false } }

        XCTAssertEqual(library.selection, MeetingLibrary.canonical(meeting))
        XCTAssertEqual(library.meeting(at: meeting)?.versions.map(\.number), [1, 3, 10])
        XCTAssertEqual(library.version, "transcript 3.md")
        guard case .loaded(let text) = library.text else { return XCTFail() }
        XCTAssertEqual(text.lines?.map(\.text), ["третья"])

        library.refresh()
        try await until { library.local.fresh }
        XCTAssertEqual(library.version, "transcript 3.md", "a version picked from the menu was switched away")

        library.select(nil)
        library.select(meeting)
        XCTAssertEqual(library.version, "transcript 10.md", "a meeting chosen in the list shows its newest version")
    }

    /// A meeting outside both roots is read on its own and listed until the
    /// window closes; one that is not there says so.
    func testMeetingOutsideTheRootsIsReadOnItsOwn() async throws {
        let elsewhere = root.appendingPathComponent("Old/Meetings", isDirectory: true)
        let meeting = try seed("2026-09-01 10-00-00 Meeting", in: elsewhere, metadata: done, files: ["transcript.md": transcript("старая")])
        let gone = root.appendingPathComponent("Unplugged/2026-09-02 10-00-00 Meeting", isDirectory: true)
        let library = makeLibrary()
        library.windowOpened()

        library.open(gone)
        library.open(meeting)
        try await until { if case .loaded = library.text { true } else { false } }

        XCTAssertEqual(library.outsideMeetings.map(\.directory), [MeetingLibrary.canonical(meeting)])
        XCTAssertEqual(library.outsideMeetings.first?.place, .outside)
        XCTAssertEqual(library.outside.first { $0.folder.path == gone.path }?.state, .unavailable)
        library.windowClosed()
        XCTAssertEqual(library.outside, [])
        XCTAssertNil(library.selection)
    }

    // MARK: - What the window says

    /// The row promises completeness only where the record proves it: a
    /// transcript without a record, or with one that cannot be read, gets no
    /// check mark, and one with gaps is a warning. Three looks, told apart
    /// by their words and their symbols.
    func testOnlyAProvenCompleteTranscriptGetsTheCheckMark() {
        func look(_ outcome: MeetingLibrary.Status.Outcome?) -> (text: String, symbol: String) {
            let shown = MeetingText.status(.init(operation: nil, outcome: outcome, hasTranscript: true, brokenOff: false))
            return (shown.0, shown.1)
        }
        let complete = look(.complete)
        let old = look(nil)
        let unreadable = look(.unknown)
        let gaps = look(.incomplete(cutShort: false, failedChunks: 1, missingTracks: []))

        XCTAssertTrue(complete.symbol.hasPrefix("checkmark"), complete.symbol)
        for unproven in [old, unreadable, gaps] {
            XCTAssertFalse(unproven.symbol.hasPrefix("checkmark"), "\(unproven) promises a whole transcript")
        }
        XCTAssertEqual(old.text, unreadable.text)
        XCTAssertEqual(Set([complete.text, old.text, gaps.text]).count, 3, "\([complete, old, gaps])")
        XCTAssertEqual(complete.text, "Fully transcribed")
        XCTAssertEqual(old.text, "Transcribed, completeness unknown")
        XCTAssertEqual(gaps.symbol, "exclamationmark.triangle.fill")
    }

    /// The list says what each folder it reads is doing, a meeting read on
    /// its own outside both roots included, with its path; and "No meetings
    /// yet" waits until every folder it needs was read, not merely tried.
    func testEveryFolderReadIsShownAndEmptyWaitsForEveryRoot() {
        typealias Listing = MeetingLibrary.Listing
        let read = Listing(folder: local, state: .read, fresh: true)
        XCTAssertTrue(MeetingText.isSettled(local: read, chosen: nil, outside: []))
        for state in [Listing.State.unavailable, .failed("Operation not permitted"), .notRead] {
            XCTAssertFalse(
                MeetingText.isSettled(local: read, chosen: Listing(folder: disk, state: state), outside: []),
                "an empty list passes for no meetings while the meetings folder is \(state)"
            )
        }
        XCTAssertTrue(MeetingText.isSettled(local: read, chosen: Listing(folder: disk, state: .read, fresh: true), outside: []))
        // A meeting asked for outside both roots that is away, failed or
        // still being read: the list is not proven empty either.
        let asked = URL(fileURLWithPath: "/Volumes/Old/2026-09-01 10-00-00 Meeting", isDirectory: true)
        let outsideStates = [
            Listing(folder: asked, state: .unavailable), Listing(folder: asked, state: .failed("Input/output error")),
            Listing(folder: asked), Listing(folder: asked, state: .read, reading: true),
        ]
        for listing in outsideStates {
            XCTAssertFalse(
                MeetingText.isSettled(local: read, chosen: nil, outside: [listing]),
                "“No meetings yet” over a meeting outside that is \(listing.state), reading \(listing.reading)"
            )
        }
        XCTAssertTrue(MeetingText.isSettled(local: read, chosen: nil, outside: [Listing(folder: asked, state: .read, fresh: true)]))

        let gone = Listing(folder: URL(fileURLWithPath: "/Volumes/Old/2026-09-02 10-00-00 Meeting", isDirectory: true), state: .unavailable)
        let hanging = Listing(
            folder: URL(fileURLWithPath: "/Volumes/NAS/2026-09-03 10-00-00 Meeting", isDirectory: true),
            reading: true, notResponding: true
        )
        let lines = MeetingText.folderLines(local: read, chosen: nil, outside: [gone, hanging])
        for listing in [gone, hanging] {
            XCTAssertTrue(
                lines.contains { $0.warning && $0.text.contains(listing.folder.path) },
                "nothing says \(listing.folder.path) is \(listing.state): \(lines)"
            )
        }
        XCTAssertTrue(MeetingText.missingMeeting(gone).warning)
        XCTAssertTrue(MeetingText.missingMeeting(gone).text.contains(gone.folder.path))
        XCTAssertFalse(MeetingText.missingMeeting(Listing(folder: gone.folder, reading: true)).warning)
    }

    // MARK: - Marks

    /// While the queue moves a meeting, held between the copy and the local
    /// folder's removal, the moment a change written into the local folder
    /// would be lost with it, its name and star are refused: the controls say
    /// why, nothing is written anywhere, nothing counts as unsaved. Once the
    /// meeting is in its new place, the star goes there.
    func testMarksAreRefusedWhileTheQueueMovesTheFolder() async throws {
        let (meeting, moved, queue, latch, library) = try await meetingBeingMoved()
        let row = try XCTUnwrap(library.meeting(at: meeting))

        XCTAssertNotNil(library.markRefusal(for: row), "the controls are on while the folder is being moved")
        library.toggleStar(row)
        library.rename(row, to: "Планёрка")

        XCTAssertTrue(library.pendingMarks.isEmpty)
        XCTAssertEqual(library.quitLosses, [])
        latch.release()
        try await until { queue.activeJob == nil }
        for folder in [meeting, moved] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path),
                           "a change was written during the move: \(folder.path)")
        }
        library.refresh()
        try await until { library.chosen?.fresh == true && library.meeting(at: moved) != nil }
        let there = try XCTUnwrap(library.meeting(at: moved))
        XCTAssertNil(library.markRefusal(for: there))
        library.toggleStar(there)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: moved), .read(MeetingMarks(starred: true)))
    }

    /// A local meeting reached through a link in a parent path is written
    /// off the main actor, as any folder not spelled in the local root; the
    /// queue's move of that folder waits for the write, so the copy takes it.
    func testAMoveWaitsForAWriteOfTheFoldersMarks() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let moved = disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let gate = DiskGate()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let reached = Latch()
        reached.release()
        queue.mover = { folder, target, localRoot in
            reached.wait()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        let library = makeLibrary(queue: queue, reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh }
        library.open(spelled)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(spelled) } }
        gate.holdWrites(meeting)

        library.toggleStar(try XCTUnwrap(library.meeting(at: spelled)))
        try await until { gate.writes(of: meeting) == 1 }
        queue.enqueue(meeting, transcribe: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(reached.wasReached, "the move began while the folder's marks were being written")

        gate.releaseWrites(meeting)
        try await until { queue.activeJob == nil && library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: moved), .read(MeetingMarks(starred: true)), "the move left the star behind")
    }

    /// The move waited for a write of the folder's marks; meanwhile another
    /// folder was put at the address. The move does not take it: the folder
    /// is read again once the wait is over, and one that is not the folder
    /// waited for is left for the next scan.
    func testAMoveDoesNotTakeAFolderPutInPlaceOfTheOneItWaitedFor() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let moved = disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let gate = DiskGate()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let reached = Latch()
        reached.release()
        queue.mover = { folder, target, localRoot in
            reached.wait()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        let library = makeLibrary(queue: queue, reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh }
        library.open(spelled)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(spelled) } }
        gate.holdWrites(meeting)
        library.toggleStar(try XCTUnwrap(library.meeting(at: spelled)))
        try await until { gate.writes(of: meeting) == 1 }
        queue.enqueue(meeting, transcribe: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(reached.wasReached)

        let old = root.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.moveItem(at: meeting, to: old)
        try seed(meeting.lastPathComponent, in: local, metadata: done)
        gate.releaseWrites(meeting)
        try await until { queue.activeJob == nil && library.pendingMarks.isEmpty }

        XCTAssertFalse(reached.wasReached, "the move took the folder put in place of the one it waited for")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("metadata.json").path))
        for folder in [meeting, old] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path), folder.path)
        }
    }

    /// A link where the local meeting folder was is no folder of its own:
    /// the queue does not move it, nor whatever it points to.
    func testAMoveDoesNotTakeALinkInPlaceOfAFolder() async throws {
        settings.meetingsFolderPath = disk.path
        let elsewhere = try seed("2026-10-06 10-00-00 Meeting", in: root.appendingPathComponent("Elsewhere", isDirectory: true), metadata: done)
        let meeting = local.appendingPathComponent(elsewhere.lastPathComponent, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: meeting, withDestinationURL: elsewhere)
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let reached = Latch()
        reached.release()
        queue.mover = { folder, target, localRoot in
            reached.wait()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }

        queue.enqueue(meeting, transcribe: false)
        try await until { queue.activeJob == nil && queue.pending.isEmpty }

        XCTAssertFalse(reached.wasReached, "the queue moved a link")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("metadata.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.appendingPathComponent(meeting.lastPathComponent).path))
    }

    /// The move has ended and the list has not been read again yet, so the
    /// meeting's old row is still there: a name saved for it is refused, and
    /// the refusal comes back to whoever saved it, as that row is about to go.
    func testANameSavedAfterAMoveBeforeTheListIsReadAgainIsRefusedVisibly() async throws {
        let gate = DiskGate()
        let (meeting, moved, queue, latch, library) = try await meetingBeingMoved(reader: gate.reader)
        let row = try XCTUnwrap(library.meeting(at: meeting))
        gate.hold(local)
        defer { gate.release(local) }
        latch.release()
        try await until { queue.activeJob == nil && queue.operations.isEmpty }
        XCTAssertNotNil(library.meeting(at: meeting), "the list was read again: the old row is gone")

        let refusal = library.rename(typedOn: row.identity, at: row.directory.path, to: "Планёрка")

        XCTAssertNotNil(refusal, "the name was dropped without a word")
        for folder in [meeting, moved] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path), folder.path)
        }
        XCTAssertTrue(library.pendingMarks.isEmpty)
    }

    /// A name written off the main actor (a local meeting reached through a
    /// link in a parent path) that fails after another meeting was chosen
    /// has no card to say so: the window says it above the list until it is
    /// dismissed. With the meeting still on the card, its card says it.
    func testALateFailureOfAMeetingNoLongerShownIsTheWindowsNotice() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh }
        library.open(spelled)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(spelled) } }
        let row = try XCTUnwrap(library.meeting(at: spelled))
        gate.holdWrites(meeting)
        gate.failWrite(meeting, number: 1)
        gate.failWrite(meeting, number: 2)

        XCTAssertNil(library.rename(typedOn: row.identity, at: row.directory.path, to: "Планёрка"), "written off the main actor")
        try await until { gate.writes(of: meeting) == 1 }
        library.select(other)
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        XCTAssertEqual(library.markNotice?.title, "Планёрка", "the failure was lost with the card")
        library.dismissMarkNotice()
        XCTAssertNil(library.markNotice)

        library.open(spelled)
        gate.holdWrites(meeting)
        library.toggleStar(try XCTUnwrap(library.meeting(at: spelled)))
        try await until { gate.writes(of: meeting) == 2 }
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertNil(library.markNotice, "the card shows it; the window need not")
        XCTAssertNotNil(library.markFailure(of: try XCTUnwrap(library.meeting(at: spelled))))
    }

    /// Whether a folder is written at once is the queue's own rule for what
    /// it may move: with the local root given through a link, a local
    /// meeting reached by its real path is written at once, on disk before
    /// the call returns, as the queue counts it in the local root.
    func testALocalFolderIsWrittenAtOnceHoweverItsRootIsSpelled() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let rootLink = root.appendingPathComponent("Local link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: local)
        let queue = makeQueue(localRoot: rootLink)
        let library = makeLibrary(queue: queue, localRoot: rootLink)
        library.windowOpened()
        try await until { library.local.fresh }
        library.open(meeting)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(meeting) } }

        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))

        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(starred: true)), "a local folder was written later, off the main actor")
        XCTAssertTrue(library.pendingMarks.isEmpty)
    }

    /// A write goes only to the folder it was meant for: another folder put
    /// at the address while the write waited takes nothing, and the
    /// refusal shows.
    func testAWriteGoesOnlyToTheFolderItWasMeantFor() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        gate.holdWrites(meeting)
        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))
        try await until { gate.writes(of: meeting) == 1 }

        try FileManager.default.moveItem(at: meeting, to: disk.appendingPathComponent("Old", isDirectory: true))
        try seed(meeting.lastPathComponent, in: disk, metadata: done)
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent(MeetingMarks.fileName).path),
                       "the star went into another folder at the same address")
        XCTAssertFalse(library.markFailures.isEmpty, "the refusal does not show")
    }

    /// A name typed on a meeting goes, when the typing ends, to the meeting
    /// it was typed on, whatever is selected; while the queue moves it, or
    /// once it has moved, it is refused with the reason, never dropped
    /// unsaid.
    func testANameTypedOnAMeetingIsTakenOrRefusedWithAReason() async throws {
        let (meeting, moved, queue, latch, library) = try await meetingBeingMoved()
        let row = try XCTUnwrap(library.meeting(at: meeting))

        XCTAssertNotNil(library.rename(typedOn: row.identity, at: row.directory.path, to: "Планёрка"), "taken during the move")
        latch.release()
        try await until { queue.activeJob == nil }
        library.refresh()
        try await until { library.local.fresh && library.chosen?.fresh == true && library.meeting(at: meeting) == nil }
        XCTAssertNotNil(library.rename(typedOn: row.identity, at: row.directory.path, to: "Планёрка"), "dropped unsaid after the move")

        let there = try XCTUnwrap(library.meeting(at: moved))
        library.select(nil)
        XCTAssertNil(library.rename(typedOn: there.identity, at: there.directory.path, to: "Планёрка"))
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: moved), .read(MeetingMarks(title: "Планёрка")))
    }

    /// Any other step of the queue is no reason to wait: the star is on disk
    /// at once.
    func testStarDuringATranscriptionIsWrittenAtOnce() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let door = Door()
        let queue = makeQueue(door: door)
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        queue.enqueue(meeting)
        try await until { queue.isTranscribing }

        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))

        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(starred: true)))
        XCTAssertTrue(library.pendingMarks.isEmpty)
        door.unlock()
        try await until { queue.activeJob == nil }
    }

    /// A folder the star cannot be written to says so on the card; the star
    /// shown stays what is on disk.
    func testStarOnAReadOnlyFolderFailsVisiblyAndKeepsTheValue() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: meeting.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path) }
        let row = try XCTUnwrap(library.meeting(at: meeting))

        library.toggleStar(row)

        XCTAssertNotNil(failure(of: meeting, in: library))
        XCTAssertEqual(library.marks(of: try XCTUnwrap(library.meeting(at: meeting)))?.starred, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.appendingPathComponent(MeetingMarks.fileName).path))
        XCTAssertTrue(library.pendingMarks.isEmpty)
    }

    /// A murmurly.json this app cannot read, or one of a later version, takes
    /// no change: the controls say why, and the file is left byte for byte.
    func testUnreadableOrNewerMarksTakeNoChange() async throws {
        let bodies = ["{broken", #"{"version":0,"starred":true}"#, #"{"version":2,"starred":true}"#]
        var folders: [URL] = []
        for (index, body) in bodies.enumerated() {
            folders.append(try seed("2026-10-06 1\(index)-00-00 Meeting", in: local, metadata: done, files: [MeetingMarks.fileName: body]))
        }
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh }

        for (folder, body) in zip(folders, bodies) {
            let row = try XCTUnwrap(library.meeting(at: folder))
            XCTAssertNotNil(library.markRefusal(for: row), body)
            library.toggleStar(row)
            library.rename(row, to: "Новое имя")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName)), Data(body.utf8), body)
            XCTAssertNil(library.marks(of: row), body)
        }
    }

    /// A folder of the same name on this Mac and in the meetings folder:
    /// neither takes marks while both are there.
    func testFoldersOfOneNameInBothPlacesTakeNoMarks() async throws {
        let name = "2026-10-06 10-00-00 Meeting"
        let here = try seed(name, in: local, metadata: done)
        let there = try seed(name, in: disk, metadata: done)
        settings.meetingsFolderPath = disk.path
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh && library.chosen?.fresh == true }

        for folder in [here, there] {
            let row = try XCTUnwrap(library.meeting(at: folder))
            XCTAssertNotNil(library.markRefusal(for: row))
            library.toggleStar(row)
        }
        try await Task.sleep(for: .milliseconds(100))
        for folder in [here, there] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingMarks.fileName).path))
        }
    }

    /// The name changes the title alone, never the folder; an empty one
    /// gives the date back. Starred lists the starred.
    func testRenameChangesOnlyTheTitleAndStarredListsTheStarred() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let library = makeLibrary()
        library.windowOpened()
        try await until { library.local.fresh }
        let dated = MeetingText.title(try XCTUnwrap(library.meeting(at: meeting)), marks: nil)

        library.rename(try XCTUnwrap(library.meeting(at: meeting)), to: "  Планёрка с подрядчиком ")
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: "Планёрка с подрядчиком")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.path), "the folder was renamed")
        let named = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertEqual(MeetingText.title(named, marks: library.marks(of: named)), "Планёрка с подрядчиком")

        library.toggleStar(named)
        XCTAssertEqual(library.starredMeetings.map(\.directory), [MeetingLibrary.canonical(meeting)])
        library.rename(try XCTUnwrap(library.meeting(at: meeting)), to: "")
        let back = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: nil, starred: true)))
        XCTAssertEqual(MeetingText.title(back, marks: library.marks(of: back)), dated)
    }

    /// A meeting in the meetings folder is written on that folder's queue:
    /// until it is on disk the change shows as saving, a person's quit warns
    /// once and a repeat goes ahead, a system quit goes ahead, and Sparkle
    /// waits.
    func testStarElsewhereHoldsQuitAndUpdatesUntilItIsWritten() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let recorder = makeRecorder()
        let queue = makeQueue()
        let library = makeLibrary(recorder: recorder, queue: queue, reader: gate.reader)
        let busy = UpdateWatch()
        let watch = AppUpdater.busy(
            meeting: recorder, dictation: DictationCoordinator(mic: SilentLibraryMic(), indicator: RecordingIndicator(renderingEnabled: false)),
            transcripts: queue, files: FilesModel(transcription: { _ in { _, _ in [] } }), library: library
        ).sink { busy.value = $0 }
        defer { watch.cancel() }
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        gate.holdWrites(meeting)

        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))
        try await until { gate.writes(of: meeting) == 1 }

        XCTAssertFalse(library.pendingMarks.isEmpty)
        XCTAssertEqual(library.marks(of: try XCTUnwrap(library.meeting(at: meeting)))?.starred, true)
        XCTAssertTrue(busy.value, "Sparkle would relaunch over an unsaved star")
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish") }
        delegate.meetingLosses = { library.quitLosses }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "a person's quit loses the star unwarned")
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow, "the repeat is held")
        let system = AppDelegate()
        system.meetingLosses = { library.quitLosses }
        system.quitReason = { OSType(kAELogOut) }
        XCTAssertEqual(system.applicationShouldTerminate(NSApp), .terminateNow)

        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(starred: true)))
        XCTAssertFalse(busy.value)
        XCTAssertEqual(library.quitLosses, [])
    }

    /// Changes made while a write is under way gather, field by field, on
    /// what the user asked for: a star and two names in a row, the first
    /// write failing, end as the star and the last name, and the change
    /// counts as unsaved the whole time, between the writes too.
    func testChangesGatherAndAFailedFirstWriteLosesNone() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        var saved: [Bool] = []
        let watch = library.$pendingMarks.dropFirst().sink { saved.append($0.isEmpty) }
        defer { watch.cancel() }
        gate.holdWrites(meeting)
        gate.failNextWrite(meeting)

        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))
        try await until { gate.writes(of: meeting) == 1 }
        library.rename(try XCTUnwrap(library.meeting(at: meeting)), to: "Планёрка")
        library.rename(try XCTUnwrap(library.meeting(at: meeting)), to: "Планёрка с подрядчиком")
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: "Планёрка с подрядчиком", starred: true)))
        XCTAssertNil(failure(of: meeting, in: library), "a failure the next write made good shows")
        XCTAssertEqual(saved.last, true)
        XCTAssertEqual(saved.dropLast().filter { $0 }, [], "the change passed for saved between the writes: \(saved)")
    }

    /// A read that found the old marks but answered after a name was
    /// written does not take the name back: the window keeps showing it,
    /// and the next star leaves it on disk.
    func testAReadAnsweredLateDoesNotUndoAWrittenName() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh && !library.local.reading }
        let answered = gate.answers(of: local)
        gate.holdAnswer(local)
        library.refresh()
        try await until { gate.answers(of: self.local) == answered + 1 }

        library.rename(try XCTUnwrap(library.meeting(at: meeting)), to: "Планёрка")
        // No later read may put the name back before the checks.
        gate.hold(local)
        defer { gate.release(local) }
        gate.releaseAnswer(local)
        try await until { library.local.fresh }

        let row = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertEqual(library.marks(of: row)?.title, "Планёрка", "the late read took the written name back")
        library.toggleStar(row)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: "Планёрка", starred: true)))
    }

    /// One folder reached two ways, through the meetings folder and through
    /// a link in a parent path, has one writer: a second change waits for
    /// the write under way, and the two land in order.
    func testAFolderReachedThroughALinkHasOneWriter() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: disk)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        try await oneWriter(for: meeting, secondChangeThrough: spelled) { _ in }
    }

    /// A meeting of the meetings folder, opened from outside both roots once
    /// the setting changed, is the same folder: one writer.
    func testAMeetingOpenedOutsideTheRootsAfterTheSettingChangedHasOneWriter() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await oneWriter(for: meeting, secondChangeThrough: meeting) { [settings] library in
            settings!.meetingsFolderPath = other.path
            library.refresh()
        }
    }

    /// The star goes through the meetings folder's row and is held at the
    /// disk; then `between` runs, the meeting is opened at `address` and
    /// renamed there. The second write waits for the first, the change
    /// stays unsaved throughout, and both land.
    private func oneWriter(
        for meeting: URL,
        secondChangeThrough address: URL,
        between: (MeetingLibrary) -> Void
    ) async throws {
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true && library.meeting(at: meeting) != nil }
        var saved: [Bool] = []
        let watch = library.$pendingMarks.dropFirst().sink { saved.append($0.isEmpty) }
        defer { watch.cancel() }
        gate.holdWrites(meeting)
        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))
        try await until { gate.writes(of: meeting) == 1 }

        between(library)
        library.open(address)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(address) } }
        library.rename(try XCTUnwrap(library.meeting(at: address)), to: "Планёрка")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(gate.writes(of: meeting), 1, "a second write of one folder started while the first was under way")
        XCTAssertFalse(library.pendingMarks.isEmpty)

        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: "Планёрка", starred: true)))
        XCTAssertEqual(saved.dropLast().filter { $0 }, [], "the change passed for saved between the writes: \(saved)")
    }

    /// The first of two writes succeeds and the last fails: the window keeps
    /// what the first put on disk, and the next change keeps it there.
    func testAWriteThatSucceededStaysWhenTheNextFails() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        gate.holdWrites(meeting)
        library.rename(try XCTUnwrap(library.meeting(at: meeting)), to: "Планёрка")
        try await until { gate.writes(of: meeting) == 1 }
        library.toggleStar(try XCTUnwrap(library.meeting(at: meeting)))
        gate.failWrite(meeting, number: 2)
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        XCTAssertEqual(gate.writes(of: meeting), 2)
        let row = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertEqual(library.marks(of: row), MeetingMarks(title: "Планёрка"), "the window forgot the name on disk")
        XCTAssertNotNil(failure(of: meeting, in: library))
        library.toggleStar(row)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: "Планёрка", starred: true)))
    }

    /// A local meeting the queue is moving to the meetings folder, the move
    /// held between its copy and the local folder's removal.
    private func meetingBeingMoved(
        reader: MeetingLibrary.Reader = .disk
    ) async throws -> (URL, URL, MeetingTranscriptionQueue, Latch, MeetingLibrary) {
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
        let library = makeLibrary(queue: queue, reader: reader)
        library.windowOpened()
        try await until { library.local.fresh }
        queue.enqueue(meeting, transcribe: false)
        try await until { latch.wasReached }
        XCTAssertEqual(queue.step, .moving)
        return (meeting, moved, queue, latch, library)
    }

    /// Why the last write of the folder's marks failed, as its card says.
    private func failure(of folder: URL, in library: MeetingLibrary) -> String? {
        library.meeting(at: folder).flatMap(library.markFailure(of:))?.reason
    }

    // MARK: - Speakers' names

    /// A transcript as the queue writes it, and the record of its attempt:
    /// each line's track, the labels written and the file's fingerprint.
    /// `lines`: each line's track, label and words, in the file's order.
    private func recorded(
        _ lines: [(MeetingAttempt.Source, String, String)], number: Int = 1, transcript: String = "transcript.md",
        header: String = """
            # Meeting 6 October 2026

            Automatic transcript. Engine: Whisper (whisper). Language: auto.
            “Me” is the microphone, “Others” is the system audio; the other voices are not told apart. Echo lines removed from the microphone: 0.
            """
    ) -> (markdown: String, attempt: MeetingAttempt) {
        let rows = lines.enumerated().map { "[0:0\($0.offset * 2 + 1)] **\($0.element.1):** \($0.element.2)" }
        let markdown = ([header, "---"] + rows).joined(separator: "\n\n") + "\n"
        var attempt = MeetingAttempt(number: number, startedAt: Date(timeIntervalSince1970: 1_760_000_000))
        attempt.result = .complete
        attempt.endedAt = Date(timeIntervalSince1970: 1_760_000_100)
        attempt.transcript = transcript
        attempt.engines = ["whisper"]
        attempt.languages = ["auto"]
        attempt.speakers = MeetingAttempt.Speakers(microphone: "Me", system: "Others")
        attempt.lines = lines.enumerated().map {
            MeetingAttempt.Line(start: Double($0.offset * 2 + 1), end: Double($0.offset * 2) + 1.75, source: $0.element.0)
        }
        let bytes = Data(markdown.utf8)
        attempt.fingerprint = MeetingAttempt.Fingerprint(
            bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        return (markdown, attempt)
    }

    /// The transcript and its record into the folder; `markdown`: the file
    /// as it is there, changed after the record was written.
    private func write(_ recorded: (markdown: String, attempt: MeetingAttempt), into folder: URL, markdown: String? = nil) throws {
        try Data((markdown ?? recorded.markdown).utf8).write(to: folder.appendingPathComponent(try XCTUnwrap(recorded.attempt.transcript)))
        try recorded.attempt.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: recorded.attempt.number)))
    }

    /// The meeting on the card with its text read.
    @discardableResult
    private func showText(of folder: URL, in library: MeetingLibrary) async throws -> MeetingLibrary.Meeting {
        library.select(folder)
        try await until { if case .loaded = library.text { true } else { false } }
        return try XCTUnwrap(library.meeting(at: folder))
    }

    private func setNames(_ library: MeetingLibrary, _ meeting: MeetingLibrary.Meeting, _ microphone: String, _ system: String) -> String? {
        library.setNames(typedOn: meeting.identity, at: meeting.directory.path, microphone: microphone, system: system)
    }

    /// Every file at the top of the folder by name, byte for byte, but the marks.
    private func contents(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name != MeetingMarks.fileName {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            files[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }

    /// The queue transcribes a meeting with a voice on each track; names
    /// set on its card take the place of each line's label by the track the
    /// record says the line came from, on the card, in Copy Text and on the
    /// player's track buttons. The transcript, its record and its copy in
    /// the transcripts folder stay byte for byte; the names live in
    /// murmurly.json alone, one line each.
    func testNamesFollowTheTrackTheRecordSays() async throws {
        let copies = root.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        settings.transcriptsFolderPath = copies.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: doneCAF, tracks: [])
        try TrackEngine.writeTrack(level: 0.1, to: meeting.appendingPathComponent("microphone.caf"))
        try TrackEngine.writeTrack(level: 0.5, to: meeting.appendingPathComponent("system.caf"))
        let queue = makeQueue(speaks: true, engine: TrackEngineFactory(), destinations: { [settings] in settings!.meetingDestinations })
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        XCTAssertTrue(library.transcribe(meeting))
        try await until(within: .seconds(30)) { queue.lastOutcome != nil && queue.activeJob == nil && queue.pending.isEmpty }
        try await until { library.meeting(at: meeting)?.versions.count == 1 }
        let row = try await showText(of: meeting, in: library)
        XCTAssertNil(library.recordRefusal(for: row))
        let disk = try contents(of: meeting)
        let copy = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: copies.path).first)
        let copied = try Data(contentsOf: copies.appendingPathComponent(copy))

        XCTAssertNil(setNames(library, row, " Денис\n", "Ком\tанда "))

        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(speakers: [.microphone: "Денис", .system: "Ком анда"])))
        let shown = try XCTUnwrap(library.shownTranscript(of: row))
        guard case .exact(let spans) = shown.timing else { return XCTFail("the queue's own transcript has no exact times") }
        XCTAssertEqual(Set(spans.map(\.source)), [.microphone, .system], "a track is missing from the text")
        XCTAssertEqual(shown.lines?.map(\.speaker), spans.map { $0.source == .microphone ? "Денис" : "Ком анда" })
        XCTAssertEqual(
            shown.lines?.map(\.text), spans.map { $0.source == .microphone ? TrackEngine.microphoneWords : TrackEngine.systemWords },
            "a name went to the other track's words"
        )
        let text = TranscriptTextView.attributed(shown).string
        XCTAssertTrue(text.contains("Денис: \(TrackEngine.microphoneWords)"), text)
        XCTAssertTrue(text.contains("Ком анда: \(TrackEngine.systemWords)"), text)
        XCTAssertFalse(text.contains("Me:"), text)
        XCTAssertTrue(text.contains(try XCTUnwrap(shown.namesNote)), "Copy Text does not say who is who")
        XCTAssertEqual(library.trackLabels(of: row), [.microphone: "Денис", .system: "Ком анда"])
        XCTAssertEqual(try contents(of: meeting), disk, "a file of the meeting changed")
        XCTAssertEqual(try Data(contentsOf: copies.appendingPathComponent(copy)), copied, "the transcripts folder's copy changed")

        // An empty name gives the label back, on the text and the player.
        XCTAssertNil(setNames(library, row, "", "Ком анда"))
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(speakers: [.system: "Ком анда"])))
        XCTAssertEqual(library.shownTranscript(of: row)?.lines?.map(\.speaker), spans.map { $0.source == .microphone ? "Me" : "Ком анда" })
        XCTAssertEqual(library.trackLabels(of: row), [.microphone: "Me", .system: "Ком анда"])
        XCTAssertNotNil(setNames(library, row, "Де*нис", ""), "a name that would end the label early was taken")
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(speakers: [.system: "Ком анда"])))
    }

    /// Names go by the track each line came from, as the record says, never
    /// by the text of its label: a transcript written under the Russian
    /// interface, and one whose two tracks share a label, are named alike.
    func testNamesGoByTrackNotByLabel() async throws {
        let russian = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let russianText = recorded([(.microphone, "Я", "раз"), (.system, "Собеседники", "два"), (.microphone, "Я", "три")])
        try write(russianText, into: russian)
        let same = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        try write(recorded([(.system, "Me", "раз"), (.microphone, "Me", "два")]), into: same)
        let library = try await openLibrary()

        let first = try await showText(of: russian, in: library)
        XCTAssertEqual(library.shownTranscript(of: first)?.lines?.map(\.speaker), ["Я", "Собеседники", "Я"], "named with no names")
        XCTAssertNil(setNames(library, first, "Денис", "Команда"))
        XCTAssertEqual(library.shownTranscript(of: first)?.lines?.map(\.speaker), ["Денис", "Команда", "Денис"])
        XCTAssertEqual(library.shownTranscript(of: first)?.raw, russianText.markdown, "the text read changed")

        let second = try await showText(of: same, in: library)
        XCTAssertNil(setNames(library, second, "Денис", "Команда"))
        XCTAssertEqual(library.shownTranscript(of: second)?.lines?.map(\.speaker), ["Команда", "Денис"])
        XCTAssertEqual(
            library.shownTranscript(of: second)?.namesNote,
            String(localized: "Names: “Денис” is the microphone, “Команда” is the system audio.")
        )
    }

    /// The names are the meeting's, not a transcript's: a transcription
    /// asked for again, in an engine and language of its own, writes a new
    /// version named as the first, and the queue leaves murmurly.json alone.
    func testTranscribingAgainKeepsTheNames() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: doneCAF, tracks: [])
        try TrackEngine.writeTrack(level: 0.1, to: meeting.appendingPathComponent("microphone.caf"))
        try TrackEngine.writeTrack(level: 0.5, to: meeting.appendingPathComponent("system.caf"))
        let queue = makeQueue(speaks: true, engine: TrackEngineFactory())
        let library = makeLibrary(queue: queue)
        library.windowOpened()
        try await until { library.local.fresh }
        XCTAssertTrue(library.transcribe(meeting))
        try await until(within: .seconds(30)) { library.meeting(at: meeting)?.versions.count == 1 && queue.activeJob == nil }
        let first = try await showText(of: meeting, in: library)
        XCTAssertNil(setNames(library, first, "Денис", "Команда"))
        let marks = try Data(contentsOf: meeting.appendingPathComponent(MeetingMarks.fileName))

        XCTAssertTrue(library.transcribe(meeting, choice: SettingsSnapshot.Choice(engine: .whisper, language: "ru")))
        try await until(within: .seconds(30)) { library.meeting(at: meeting)?.versions.count == 2 && queue.activeJob == nil }
        try await until { library.version == "transcript 2.md" && { if case .loaded = library.text { true } else { false } }() }

        let row = try XCTUnwrap(library.meeting(at: meeting))
        let shown = try XCTUnwrap(library.shownTranscript(of: row))
        guard case .exact(let spans) = shown.timing else { return XCTFail("the new version has no exact times") }
        XCTAssertEqual(shown.lines?.map(\.speaker), spans.map { $0.source == .microphone ? "Денис" : "Команда" })
        XCTAssertEqual(try Data(contentsOf: meeting.appendingPathComponent(MeetingMarks.fileName)), marks, "the queue wrote murmurly.json")
    }

    /// Only a transcript its record still matches takes the names; any other
    /// is shown with its own labels, and says why, as proven: older than
    /// records only when the meeting has none, changed only when the
    /// record's fingerprint differs, otherwise no matching record. The
    /// player still names the tracks: they are known without the lines.
    func testNamesNeedAnUnchangedRecordedTranscript() async throws {
        let names = #"{"version":1,"speakers":{"microphone":"Денис","system":"Команда"}}"#
        let plain = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n\n[0:07] **Others:** два\n"
        let older = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done,
                             files: ["transcript.md": plain, MeetingMarks.fileName: names])
        let byHand = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done,
                              files: ["transcript.md": "Созвон\n\nИван: начнём\n", MeetingMarks.fileName: names])
        let changed = try seed("2026-10-06 12-00-00 Meeting", in: local, metadata: done, files: [MeetingMarks.fileName: names])
        let changedText = recorded([(.microphone, "Me", "раз"), (.system, "Others", "два")])
        // A word corrected by hand: as many lines as the record has.
        try write(changedText, into: changed, markdown: changedText.markdown.replacingOccurrences(of: "два", with: "три"))
        let noFingerprint = try seed("2026-10-06 13-00-00 Meeting", in: local, metadata: done, files: [MeetingMarks.fileName: names])
        var unprinted = recorded([(.microphone, "Me", "раз")])
        unprinted.attempt.fingerprint = nil
        try write(unprinted, into: noFingerprint)
        let otherCount = try seed("2026-10-06 14-00-00 Meeting", in: local, metadata: done, files: [MeetingMarks.fileName: names])
        var miscounted = recorded([(.microphone, "Me", "раз"), (.system, "Others", "два")])
        miscounted.attempt.lines.removeLast()
        try write(miscounted, into: otherCount)
        let unreadable = try seed("2026-10-06 15-00-00 Meeting", in: local, metadata: done,
                                  files: ["transcript.md": plain, MeetingMarks.fileName: names,
                                          MeetingAttempt.fileName(number: 1): "{broken"])
        let library = try await openLibrary()

        let neutral = String(localized: "No record of a transcription matches this transcript.")
        let cases: [(URL, String)] = [
            (older, String(localized: "There are no records of this meeting’s transcriptions: which track each line came from isn’t known.")),
            (byHand, String(localized: "There are no records of this meeting’s transcriptions: which track each line came from isn’t known.")),
            (changed, String(localized: "The transcript file was changed after it was written: its record no longer matches it.")),
            (noFingerprint, neutral), (otherCount, neutral), (unreadable, neutral),
        ]
        for (folder, reason) in cases {
            let row = try await showText(of: folder, in: library)
            XCTAssertEqual(library.recordRefusal(for: row), reason, folder.lastPathComponent)
            let shown = try XCTUnwrap(library.shownTranscript(of: row))
            XCTAssertNil(shown.namesNote, folder.lastPathComponent)
            XCTAssertFalse(TranscriptTextView.attributed(shown).string.contains("Денис:"), "\(folder.lastPathComponent) took names by its labels")
            XCTAssertEqual(library.trackLabels(of: row), [.microphone: "Денис", .system: "Команда"], folder.lastPathComponent)
        }
        let row = try await showText(of: older, in: library)
        XCTAssertEqual(library.shownTranscript(of: row)?.lines?.map(\.speaker), ["Me", "Others"])
        XCTAssertNil(setNames(library, row, "", ""))
        XCTAssertEqual(library.trackLabels(of: row), [.microphone: "Me", .system: "Others"], "an empty name kept the player's name")
    }

    /// The names sheet is opened before the queue moves the meeting: while
    /// the move goes, and once it is done, it is refused with the reason
    /// and nothing is written into either folder; a sheet opened on the
    /// meeting where it is now writes there. A deletion reserved, a meeting
    /// deleted or another folder put at the address take no names either.
    func testNamesAreRefusedWhileTheQueueWorksOnTheFolder() async throws {
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
        library.windowOpened()
        try await until { library.local.fresh }
        let opened = try XCTUnwrap(library.meeting(at: meeting))

        queue.enqueue(meeting, transcribe: false)
        try await until { latch.wasReached }
        XCTAssertEqual(setNames(library, opened, "Денис", "Команда"), MeetingTranscriptionQueue.describe(.moving))
        latch.release()
        try await until { queue.activeJob == nil }
        library.refresh()
        try await until { library.local.fresh && library.chosen?.fresh == true && library.meeting(at: meeting) == nil }
        XCTAssertEqual(setNames(library, opened, "Денис", "Команда"), String(localized: "The meeting moved while the names were typed."))
        for folder in [meeting, moved] {
            XCTAssertFalse(exists(folder.appendingPathComponent(MeetingMarks.fileName)), "names were written into \(folder.path)")
        }
        let there = try XCTUnwrap(library.meeting(at: moved))
        XCTAssertNil(setNames(library, there, "Денис", "Команда"))
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(MeetingMarks.read(in: moved), .read(MeetingMarks(speakers: [.microphone: "Денис", .system: "Команда"])))

        // A deletion: reserved, then done.
        let doomed = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let replaced = try seed("2026-10-06 12-00-00 Meeting", in: local, metadata: done)
        let held = Latch()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        removal.beforeCheck = { _ in held.wait() }
        let deleting = makeLibrary(queue: makeQueue(removal: removal))
        deleting.windowOpened()
        try await until { deleting.local.fresh }
        let sheet = try XCTUnwrap(deleting.meeting(at: doomed))
        deleting.remove(deleting.removalPlan(for: [doomed], kind: .meeting))
        try await until { held.wasReached }
        XCTAssertNotNil(setNames(deleting, sheet, "Денис", ""), "names taken during the deletion")
        XCTAssertFalse(exists(doomed.appendingPathComponent(MeetingMarks.fileName)))
        held.release()
        try await until { !deleting.removalReport.isEmpty }
        XCTAssertNotNil(setNames(deleting, sheet, "Денис", ""), "names taken for a meeting deleted")
        XCTAssertFalse(exists(doomed))

        // Another folder at the address: not the meeting the sheet was opened on.
        let before = try XCTUnwrap(deleting.meeting(at: replaced))
        try FileManager.default.moveItem(at: replaced, to: root.appendingPathComponent("Old", isDirectory: true))
        try seed(replaced.lastPathComponent, in: local, metadata: done)
        deleting.refresh()
        try await until { deleting.local.fresh && deleting.meeting(at: replaced)?.identity != before.identity }
        XCTAssertEqual(setNames(deleting, before, "Денис", ""), String(localized: "The meeting moved while the names were typed."))
        XCTAssertFalse(exists(replaced.appendingPathComponent(MeetingMarks.fileName)), "names went into the folder put in its place")
    }

    /// Names written to a folder not on this Mac count as unsaved until
    /// they are on disk: the card says so, quit warns and updates wait. A
    /// star, a title and the names set during the write all land, and a
    /// name taken out during the write of the other goes too. (That a move
    /// waits for a write of marks, names included, is
    /// `testAMoveWaitsForAWriteOfTheFoldersMarks`: one barrier for all.)
    func testNamesElsewhereHoldQuitAndUpdatesUntilWritten() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done,
                               files: [MeetingMarks.fileName: #"{"version":1,"speakers":{"system":"Команда"}}"#])
        let gate = DiskGate()
        let recorder = makeRecorder()
        let queue = makeQueue()
        let library = makeLibrary(recorder: recorder, queue: queue, reader: gate.reader)
        let busy = UpdateWatch()
        let watch = AppUpdater.busy(
            meeting: recorder, dictation: DictationCoordinator(mic: SilentLibraryMic(), indicator: RecordingIndicator(renderingEnabled: false)),
            transcripts: queue, files: FilesModel(transcription: { _ in { _, _ in [] } }), library: library
        ).sink { busy.value = $0 }
        defer { watch.cancel() }
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        gate.holdWrites(meeting)

        XCTAssertNil(setNames(library, try XCTUnwrap(library.meeting(at: meeting)), "Денис", "Команда"))
        try await until { gate.writes(of: meeting) == 1 }
        let row = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertTrue(library.isSavingMarks(row))
        XCTAssertEqual(library.quitLosses, [.unsavedMeetingMark])
        XCTAssertTrue(busy.value, "Sparkle would relaunch over unsaved names")
        XCTAssertEqual(library.trackLabels(of: row)[.microphone], "Денис", "the names typed are not shown while they are saved")
        library.toggleStar(row)
        library.rename(row, to: "Планёрка")
        XCTAssertNil(setNames(library, row, "Денис", ""), "a name taken out during the write of the other")
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(title: "Планёрка", starred: true, speakers: [.microphone: "Денис"])))
        XCTAssertFalse(busy.value)
        XCTAssertEqual(library.quitLosses, [])
    }

    /// A write of names to a folder elsewhere refused late, after its
    /// meeting left the card (another folder was put at its address
    /// meanwhile): nothing in either folder, and the window says what was
    /// not saved and of which meeting.
    func testALateRefusalOfNamesIsTheWindowsNotice() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        library.select(meeting)
        let row = try XCTUnwrap(library.meeting(at: meeting))
        gate.holdWrites(meeting)
        XCTAssertNil(setNames(library, row, "Денис", "Команда"))
        try await until { gate.writes(of: meeting) == 1 }

        library.select(other)
        let old = disk.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.moveItem(at: meeting, to: old)
        try seed(meeting.lastPathComponent, in: disk, metadata: done)
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        for folder in [meeting, old] {
            XCTAssertFalse(exists(folder.appendingPathComponent(MeetingMarks.fileName)), "names went into \(folder.path)")
        }
        let notice = try XCTUnwrap(library.markNotice, "the refusal was lost with the card")
        XCTAssertNil(notice.title)
        XCTAssertEqual(notice.meeting, MeetingText.title(row, marks: nil))
        XCTAssertEqual(MeetingText.markNotice(notice),
                       String(localized: "The names “Денис” and “Команда” weren’t saved: \(notice.reason)"),
                       "the names typed are not in the notice")
    }

    /// A write of marks to a folder elsewhere that fails while the window
    /// shows another section is the window's notice, the meeting still
    /// selected: its card is out of sight. Quit waits for the write
    /// meanwhile, whatever the section.
    func testALateFailureOutOfSightIsTheWindowsNotice() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        library.select(meeting)
        let row = try XCTUnwrap(library.meeting(at: meeting))
        gate.holdWrites(meeting)
        gate.failWrite(meeting, number: 1)
        XCTAssertNil(setNames(library, row, "Денис", "Команда"))
        try await until { gate.writes(of: meeting) == 1 }

        library.section = .files
        XCTAssertEqual(library.quitLosses, [.unsavedMeetingMark], "quit would not wait for the write")
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }
        XCTAssertEqual(library.selection, MeetingLibrary.canonical(meeting))
        XCTAssertNotNil(library.markNotice, "the failure was said only on a card out of sight")
    }

    /// The meetings' Show… commands open the meeting on Meetings, whatever
    /// the window showed: another section, Starred without that meeting, a
    /// search that leaves it out. Given with the window closed, the command
    /// is there when it opens. The section outlives the window.
    func testOpenShowsTheMeetingsSectionAndTheMeeting() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("раз")])
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("два")])
        let library = makeLibrary()
        library.section = .files
        library.open(meeting)
        XCTAssertEqual(library.section, .meetings, "a command given with the window closed kept another section")
        library.windowOpened()
        try await until { library.local.fresh }
        XCTAssertEqual(library.section, .meetings)
        XCTAssertEqual(library.selection, MeetingLibrary.canonical(meeting))

        library.section = .starred
        library.searchQuery = "4815"
        library.open(other, transcript: "transcript.md")
        XCTAssertEqual(library.section, .meetings, "the meeting was opened under Starred, without its star")
        XCTAssertEqual(library.searchQuery, "", "the meeting was opened under a search that leaves it out")
        XCTAssertEqual(library.selection, MeetingLibrary.canonical(other))
        XCTAssertEqual(library.version, "transcript.md")

        library.section = .dictionary
        library.windowClosed()
        library.windowOpened()
        XCTAssertEqual(library.section, .dictionary, "the window opened anew lost its section")
    }

    /// The names sheet closes only once its names are on disk: while the
    /// write to a folder elsewhere goes it waits, a refusal that comes late,
    /// after another meeting came onto the card, is said in the sheet with
    /// the names typed, and nothing is written. A sheet closed before the
    /// answer leaves the names to the card's line, which names them too.
    func testALateRefusalOfNamesIsSaidWhereTheyWereTyped() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk, metadata: done)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: disk, metadata: done)
        let gate = DiskGate()
        let library = makeLibrary(reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }
        library.select(meeting)
        let row = try XCTUnwrap(library.meeting(at: meeting))
        gate.holdWrites(meeting)
        gate.failWrite(meeting, number: 1)

        // The sheet's own path: Save waits on it.
        var answered = false
        var answer: String?
        let sheet = Task {
            answer = await library.saveNames(typedOn: row.identity, at: row.directory.path, microphone: "Денис", system: "Команда")
            answered = true
        }
        try await until { gate.writes(of: meeting) == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(answered, "the sheet closed before its names were on disk")
        library.select(other)
        gate.releaseWrites(meeting)
        await sheet.value

        let refusal = try XCTUnwrap(answer, "a late refusal was taken for saved names")
        XCTAssertTrue(refusal.contains("“Денис”") && refusal.contains("“Команда”"), "the sheet does not name what was not saved: \(refusal)")
        XCTAssertFalse(exists(meeting.appendingPathComponent(MeetingMarks.fileName)))
        XCTAssertNotNil(library.markNotice, "the window lost the refusal with the card")

        // Saved: the sheet's answer comes only once the write is done.
        library.dismissMarkNotice()
        library.select(meeting)
        gate.holdWrites(meeting)
        answered = false
        let again = Task {
            answer = await library.saveNames(typedOn: row.identity, at: row.directory.path, microphone: "Денис", system: "Команда")
            answered = true
        }
        try await until { gate.writes(of: meeting) == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(answered)
        gate.releaseWrites(meeting)
        await again.value
        XCTAssertNil(answer)
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(speakers: [.microphone: "Денис", .system: "Команда"])))

        // The sheet closed before the answer: the card names what was lost.
        gate.holdWrites(meeting)
        gate.failWrite(meeting, number: 3)
        let closed = Task { _ = await library.saveNames(typedOn: row.identity, at: row.directory.path, microphone: "Аня", system: "Команда") }
        try await until { gate.writes(of: meeting) == 3 }
        closed.cancel()
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }
        let failure = try XCTUnwrap(library.markFailure(of: try XCTUnwrap(library.meeting(at: meeting))))
        XCTAssertEqual(MeetingText.marksNotSaved(failure.lost, reason: failure.reason, meeting: nil),
                       String(localized: "The speaker’s name “Аня” wasn’t saved: \(failure.reason)"))
        XCTAssertEqual(MeetingMarks.read(in: meeting), .read(MeetingMarks(speakers: [.microphone: "Денис", .system: "Команда"])))
    }

    // MARK: - Saving as a file

    /// The header's bytes as the file has them, down to its `---`.
    private func headerBytes(of markdown: String) throws -> String {
        String(markdown[..<(try XCTUnwrap(markdown.range(of: "\n---\n"))).lowerBound]) + "\n"
    }

    /// Markdown is the file itself, byte for byte, until names take the
    /// labels' place: then the header's own bytes, a line saying who is
    /// who, and only the labels changed, so the file reads back as the same
    /// lines with the names, whatever the names hold but a `*`. A text the
    /// record no longer matches is saved as it is, labels and all. Plain
    /// text is what Copy Text copies.
    func testMarkdownIsTheFileItselfUnlessNamesChangeIt() throws {
        // A header as a person may have left it: spaces at a line's end, a
        // blank line more; what the window shows of it is trimmed.
        let text = recorded(
            [(.microphone, "Me", "раз: два **жирно**"), (.system, "Others", "три"), (.microphone, "Me", "четыре")],
            header: "  # Meeting 6 October 2026  \n\nAutomatic transcript.\t\n\n"
        )
        let transcript = MeetingTranscript.parse(text.markdown).timed(by: text.attempt)
        guard case .exact = transcript.timing else { return XCTFail("the record does not match its own file") }
        XCTAssertEqual(transcript.exported(as: .markdown), text.markdown)
        XCTAssertEqual(transcript.named([:]).exported(as: .markdown), text.markdown)
        let header = try headerBytes(of: text.markdown)

        for (microphone, system) in [("Денис: главный", #"Ко\манда"#), ("🙂 Аня:", "Q&A [x] (ё)"), ("Денис", nil)] {
            var names: [MeetingAttempt.Source: String] = [.microphone: microphone]
            if let system { names[.system] = system }
            let named = transcript.named(names)
            let file = try XCTUnwrap(named.exported(as: .markdown))
            XCTAssertTrue(file.hasPrefix(header), "the header's bytes changed: \(file)")
            XCTAssertTrue(file.dropFirst(header.count).hasPrefix(try XCTUnwrap(named.namesNote) + "\n\n---\n"), file)
            let back = MeetingTranscript.parse(file)
            XCTAssertEqual(back.lines?.map(\.speaker), [microphone, system ?? "Others", microphone], file)
            XCTAssertEqual(back.lines?.map(\.text), transcript.lines?.map(\.text), "a line's words changed")
            XCTAssertEqual(back.lines?.map(\.timecode), transcript.lines?.map(\.timecode))
            XCTAssertEqual(
                file.replacingOccurrences(of: try XCTUnwrap(named.namesNote) + "\n\n", with: "")
                    .replacingOccurrences(of: "**\(microphone):**", with: "**Me:**")
                    .replacingOccurrences(of: "**\(system ?? "Others"):**", with: "**Others:**"),
                text.markdown, "more than the labels changed"
            )
            let plain = try XCTUnwrap(named.exported(as: .text))
            XCTAssertEqual(plain, TranscriptTextView.attributed(named).string.trimmingCharacters(in: .newlines) + "\n")
            XCTAssertTrue(plain.contains("\(microphone): раз: два **жирно**"), plain)
        }
        XCTAssertNotNil(MeetingLibrary.speakerNameRefusal("А:** Б"), "a name that ends the label early is taken")
        XCTAssertNil(MeetingLibrary.speakerNameRefusal(#"Аня: \ ё"#))

        for changed in [
            text.markdown + "\n[0:09] **Me:** дописано руками\n",
            text.markdown.replacingOccurrences(of: "четыре", with: "пять"),
        ] {
            let unmatched = MeetingTranscript.parse(changed).timed(by: text.attempt).named([.microphone: "Денис"])
            XCTAssertEqual(unmatched.exported(as: .markdown), changed, "a text the record does not match was not saved as it is")
            XCTAssertFalse(try XCTUnwrap(unmatched.exported(as: .text)).contains("Денис:"), "a text the record does not match took names")
        }
    }

    /// Subtitles come only from the record's exact spans, so only for the
    /// file it wrote: each line's start and end to the millisecond, its
    /// name or label and its words. An older, changed or hand-written text
    /// has none.
    func testSubtitlesOnlyFromAnUnchangedRecord() throws {
        var text = recorded([(.microphone, "Me", "раз"), (.system, "Others", "два")])
        text.attempt.lines = [
            MeetingAttempt.Line(start: 3723.25, end: 3725.5, source: .microphone),
            MeetingAttempt.Line(start: 3726, end: 3725, source: .system),
        ]
        let transcript = MeetingTranscript.parse(text.markdown).timed(by: text.attempt)
        XCTAssertEqual(transcript.named([.system: "Команда"]).exported(as: .subtitles), """
            1
            01:02:03,250 --> 01:02:05,500
            Me: раз

            2
            01:02:06,000 --> 01:02:06,000
            Команда: два

            """)
        for other in [
            MeetingTranscript.parse(text.markdown),
            MeetingTranscript.parse(text.markdown + "\n[0:09] **Me:** ещё\n").timed(by: text.attempt),
            MeetingTranscript.parse(text.markdown.replacingOccurrences(of: "раз", with: "три")).timed(by: text.attempt),
            MeetingTranscript.parse("Созвон\n\nИван: начнём\n").timed(by: text.attempt),
        ] {
            XCTAssertNil(other.exported(as: .subtitles), other.raw)
        }
        XCTAssertEqual(MeetingTranscript.exportName(folder: "2026-10-15 10-31-12 Meeting", version: "transcript.md", format: .markdown),
                       "2026-10-15 10-31 Meeting.md")
        XCTAssertEqual(MeetingTranscript.exportName(folder: "2026-10-15 10-31-12 Meeting-2", version: "transcript 3.md", format: .subtitles),
                       "2026-10-15 10-31 Meeting 3.srt")
    }

    /// A record whose line times no subtitle can hold, as one edited by
    /// hand may say (here read from the disk): the file still matches it,
    /// so the names apply, but subtitles are refused with the reason and no
    /// panel is asked; the app does not stop.
    func testSubtitlesRefuseTimesNoSubtitleHolds() async throws {
        var cases: [(String, [MeetingAttempt.Line])] = []
        for (index, bad) in [1e20, -1, 360_000, 3_600_000].enumerated() {
            cases.append(("2026-10-06 1\(index)-00-00 Meeting", [
                MeetingAttempt.Line(start: bad, end: 2, source: .microphone),
                MeetingAttempt.Line(start: 3, end: 4, source: .system),
            ]))
        }
        cases.append(("2026-10-06 18-00-00 Meeting", [
            MeetingAttempt.Line(start: 1, end: 2, source: .microphone),
            MeetingAttempt.Line(start: 3, end: 1e20, source: .system),
        ]))
        for (name, lines) in cases {
            let folder = try seed(name, in: local, metadata: done, files: [MeetingMarks.fileName: #"{"version":1,"speakers":{"microphone":"Денис"}}"#])
            var text = recorded([(.microphone, "Me", "раз"), (.system, "Others", "два")])
            text.attempt.lines = lines
            try write(text, into: folder)
        }
        let gate = SaveGate()
        let library = makeLibrary(saving: gate.saving)
        library.windowOpened()
        try await until { library.local.fresh }
        let reason = String(localized: "The record’s line times can’t be used for subtitles.")
        for (name, _) in cases {
            let row = try await showText(of: local.appendingPathComponent(name, isDirectory: true), in: library)
            XCTAssertNil(library.recordRefusal(for: row), "\(name): the record does not match its own file")
            XCTAssertEqual(library.shownTranscript(of: row)?.lines?.first?.speaker, "Денис", name)
            XCTAssertNil(library.shownTranscript(of: row)?.exported(as: .subtitles), name)
            XCTAssertEqual(library.subtitlesRefusal(for: row), reason, name)
            XCTAssertEqual(library.export(row, as: .subtitles, from: nil), reason, name)
            XCTAssertNil(library.exporting, name)
            XCTAssertNotNil(library.shownTranscript(of: row)?.exported(as: .markdown), name)
        }
        XCTAssertEqual(gate.panels, [], "subtitles a record cannot give asked for a panel")
    }

    /// The text on the card goes where the panel says, written on the
    /// library's own queue, never the main thread, and named after the
    /// meeting and its version; while it is written, quit warns, updates
    /// wait and no second save starts. A save the panel cancelled writes
    /// nothing; subtitles of a text without a record ask for no panel.
    func testExportGoesWhereTheDestinationSaysAndOffTheMainThread() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try write(recorded([(.microphone, "Me", "старое")]), into: meeting)
        let text = recorded([(.microphone, "Me", "раз"), (.system, "Others", "два")], number: 2, transcript: "transcript 2.md")
        try write(text, into: meeting)
        let saved = root.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let gate = SaveGate()
        gate.answer(saved.appendingPathComponent("chosen.md"))
        let recorder = makeRecorder()
        let queue = makeQueue()
        let library = makeLibrary(recorder: recorder, queue: queue, saving: gate.saving)
        let busy = UpdateWatch()
        let watch = AppUpdater.busy(
            meeting: recorder, dictation: DictationCoordinator(mic: SilentLibraryMic(), indicator: RecordingIndicator(renderingEnabled: false)),
            transcripts: queue, files: FilesModel(transcription: { _ in { _, _ in [] } }), library: library
        ).sink { busy.value = $0 }
        defer { watch.cancel() }
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try await showText(of: meeting, in: library)
        XCTAssertEqual(library.version, "transcript 2.md")
        XCTAssertNil(setNames(library, row, "Денис", "Команда"))
        let shown = try XCTUnwrap(library.shownTranscript(of: row))
        // The window the save was asked from goes with it to the panel.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Not held first: a write on the main thread would hold the test too.
        XCTAssertNil(library.export(row, as: .markdown, from: window))
        try await until { library.exporting == nil }
        XCTAssertEqual(gate.owners, [ObjectIdentifier(window)], "the panel was not asked for on the window the save came from")
        guard gate.writes.first?.main == false else { return XCTFail("the file was written on the main thread") }
        gate.holdWrite(true)

        XCTAssertNil(library.export(row, as: .markdown, from: nil))
        try await until { gate.writes.count == 2 }
        XCTAssertEqual(gate.panels, ["2026-10-06 10-00 Meeting 2.md", "2026-10-06 10-00 Meeting 2.md"])
        XCTAssertEqual(gate.writes.last?.main, false, "the file was written on the main thread")
        XCTAssertEqual(library.exporting?.writing, true)
        XCTAssertEqual(library.exporting?.file, "chosen.md")
        XCTAssertEqual(library.quitLosses, [.transcriptFile])
        XCTAssertTrue(busy.value, "Sparkle would relaunch over a file being written")
        XCTAssertNotNil(library.export(row, as: .text, from: nil), "a second save started")
        XCTAssertEqual(gate.panels.count, 2)
        // The main actor is free meanwhile: the names change, the card follows.
        XCTAssertNil(setNames(library, row, "Аня", "Команда"))
        gate.holdWrite(false)
        try await until { library.exporting == nil }

        XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("chosen.md"), encoding: .utf8),
                       shown.exported(as: .markdown), "the file is not the text as it was shown when Save was chosen")
        XCTAssertEqual(library.exportOutcome, MeetingLibrary.ExportOutcome(
            meeting: row.directory, identity: row.identity, version: "transcript 2.md", file: "chosen.md", failure: nil
        ))
        XCTAssertNil(library.exportNotice)
        XCTAssertEqual(library.quitLosses, [])
        XCTAssertFalse(busy.value)

        gate.cancelPanels(true)
        XCTAssertNil(library.export(row, as: .text, from: nil))
        try await until { library.exporting == nil }
        XCTAssertEqual(gate.panels.count, 3)
        XCTAssertEqual(gate.writes.count, 2, "a cancelled panel wrote")
        XCTAssertNil(library.exportOutcome)

        let older = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("без записи")])
        library.refresh()
        try await until { library.local.fresh && library.meeting(at: older) != nil }
        let old = try await showText(of: older, in: library)
        XCTAssertEqual(library.export(old, as: .subtitles, from: nil), library.recordRefusal(for: old))
        XCTAssertEqual(gate.panels.count, 3, "subtitles without a record asked for a panel")
        XCTAssertNil(library.exporting)
    }

    /// The panel is part of the save: while it is up nothing is written,
    /// so quit and updates do not wait, but no second save starts.
    func testAHeldPanelTakesNoSecondSave() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try write(recorded([(.microphone, "Me", "раз")]), into: meeting)
        let gate = SaveGate()
        gate.answer(root.appendingPathComponent("chosen.txt"))
        gate.holdPanel(true)
        let library = makeLibrary(saving: gate.saving)
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try await showText(of: meeting, in: library)

        XCTAssertNil(library.export(row, as: .text, from: nil))
        try await until { gate.panels.count == 1 }
        XCTAssertNotNil(library.export(row, as: .markdown, from: nil), "a second save started under the panel")
        XCTAssertEqual(gate.panels.count, 1)
        XCTAssertEqual(library.exporting?.writing, false)
        XCTAssertEqual(library.quitLosses, [], "quit waits for a panel")
        gate.holdPanel(false)
        try await until { library.exporting == nil }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("chosen.txt"), encoding: .utf8),
                       library.shownTranscript(of: row)?.exported(as: .text))
    }

    /// A save belongs to the meeting and version it was asked for: one that
    /// ends after another meeting or version came onto the card, or after
    /// the window closed, tells nothing to that card; its outcome, saved or
    /// not, is the window's notice until dismissed. Trying again writes the
    /// file and clears the notice.
    func testASaveThatEndsElsewhereIsNotTheCardsOutcome() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        try write(recorded([(.microphone, "Me", "старое")]), into: meeting)
        try write(recorded([(.microphone, "Me", "раз")], number: 2, transcript: "transcript 2.md"), into: meeting)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("другое")])
        let gate = SaveGate()
        let file = root.appendingPathComponent("chosen.md")
        gate.answer(file)
        let library = makeLibrary(saving: gate.saving)
        library.windowOpened()
        try await until { library.local.fresh }

        let moves: [(String, @MainActor () -> Void)] = [
            ("another meeting", { library.select(other) }),
            ("another version", { library.pick(version: "transcript.md") }),
            ("the window closed", { library.windowClosed() }),
            ("another section", { library.section = .files }),
        ]
        for (name, move) in moves {
            library.section = .meetings
            if !library.isWindowOpen {
                library.windowOpened()
                try await until { library.local.fresh }
            }
            let row = try await showText(of: meeting, in: library)
            if library.version != "transcript 2.md" {
                library.pick(version: "transcript 2.md")
                try await until { if case .loaded = library.text { true } else { false } }
            }
            gate.holdWrite(true)
            gate.failWrites(true)
            XCTAssertNil(library.export(row, as: .markdown, from: nil), name)
            try await until { library.exporting?.writing == true }
            move()
            gate.holdWrite(false)
            try await until { library.exporting == nil }
            XCTAssertNil(library.exportOutcome, "\(name): the card shows another save's outcome")
            let notice = try XCTUnwrap(library.exportNotice, "\(name): the failure was lost")
            XCTAssertEqual(notice.meeting, row.directory)
            XCTAssertEqual(notice.version, "transcript 2.md")
            XCTAssertNotNil(notice.failure)
            XCTAssertFalse(exists(file))
        }

        // Trying again on its card: written, the notice goes.
        library.section = .meetings
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try await showText(of: meeting, in: library)
        gate.failWrites(false)
        XCTAssertNil(library.export(row, as: .markdown, from: nil))
        try await until { library.exporting == nil }
        XCTAssertNil(library.exportNotice)
        XCTAssertNil(library.exportOutcome?.failure)
        XCTAssertNotNil(library.exportOutcome)
        XCTAssertTrue(exists(file))

        // A success elsewhere is said above the list, not on the other card.
        try FileManager.default.removeItem(at: file)
        gate.holdWrite(true)
        XCTAssertNil(library.export(row, as: .markdown, from: nil))
        try await until { library.exporting?.writing == true }
        library.select(other)
        gate.holdWrite(false)
        try await until { library.exporting == nil }
        let saved = try XCTUnwrap(library.exportNotice, "a save that ended elsewhere told no one")
        XCTAssertNil(saved.failure)
        XCTAssertEqual(saved.meeting, row.directory)
        XCTAssertEqual(MeetingText.exportOutcome(saved), String(localized: "Saved “\(saved.file)”."))
        XCTAssertNil(library.exportOutcome)
        XCTAssertTrue(exists(file))
        library.dismissExportNotice()
        XCTAssertNil(library.exportNotice)
    }

    /// A file saved into a meeting's own folder, by any address of it, or
    /// into another meeting's, is refused before anything is written: the
    /// transcripts, the marks and the audio there are never written over.
    /// A copy in the transcripts folder is the user's file: the panel asked,
    /// and it is replaced.
    func testASaveIntoAMeetingFolderIsRefused() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let text = recorded([(.microphone, "Me", "раз")])
        try write(text, into: meeting)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, files: ["transcript.md": transcript("другое")])
        let notes = meeting.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: meeting)
        let copies = root.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let copy = copies.appendingPathComponent("2026-10-06 10-00-00 Meeting.md")
        try Data("копия".utf8).write(to: copy)
        let gate = SaveGate()
        let library = makeLibrary(saving: gate.saving)
        library.windowOpened()
        try await until { library.local.fresh }
        let row = try await showText(of: meeting, in: library)
        let before = try contents(of: meeting)
        let otherBefore = try contents(of: other)

        let refusal = String(localized: "Choose a folder outside the meetings’ own folders: the files in them are the app’s.")
        for target in [
            meeting.appendingPathComponent("transcript.md"), link.appendingPathComponent("transcript.md"),
            meeting.appendingPathComponent(MeetingMarks.fileName), notes.appendingPathComponent("saved.md"),
            other.appendingPathComponent("transcript.md"),
        ] {
            gate.answer(target)
            XCTAssertNil(library.export(row, as: .markdown, from: nil))
            try await until { library.exporting == nil }
            XCTAssertEqual(library.exportOutcome?.failure, refusal, target.path)
        }
        XCTAssertEqual(gate.writes.count, 0, "a refused file was written")
        XCTAssertEqual(try contents(of: meeting), before)
        XCTAssertFalse(exists(meeting.appendingPathComponent(MeetingMarks.fileName)))
        XCTAssertFalse(exists(notes.appendingPathComponent("saved.md")))
        XCTAssertEqual(try contents(of: other), otherBefore)

        gate.answer(copy)
        XCTAssertNil(library.export(row, as: .markdown, from: nil))
        try await until { library.exporting == nil }
        XCTAssertNil(library.exportOutcome?.failure)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), text.markdown)
    }

    /// No test process opens a panel of the app's windows, whatever it was
    /// told: XCTest, the stage gate's opt-out and a UI test get the probe's
    /// answer in a temporary root, or none, for every kind of panel; only a
    /// shipped app asks AppKit, on the window given. The probe writes
    /// nothing, not even the suggested name, into a root that is not
    /// temporary. The folder panel (Transcribe Meeting…, Storage) keeps the
    /// same rule.
    func testATestProcessOpensNoPanel() async throws {
        let sheets = Counter()
        let sheet: FilesModel.PanelSheet = { _, _ in
            _ = sheets.next()
            return nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let probe = root.appendingPathComponent("Probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let all: [FilesModel.PanelPurpose] = [.fileToTranscribe, .filesTranscript, .dictionaryImport, .dictionaryExport, .meetingTranscript]
        let launches: [([String], [String: String])] = [
            ([], ["XCTestConfigurationFilePath": "/x"]),
            ([], ["XCTestConfigurationFilePath": "/x", "MURMURLY_PRODUCTION_SERVICES": "1"]),
            (["-UITesting"], [:]),
            // Once the switch for real panels in tests; it opens none now.
            (["-UITestSettingsStore", "-FileProbeRealPanels"], [:]),
        ]
        let folders = Counter()
        let begin: AppWindowController.FolderPanel = { _, _ in _ = folders.next() }
        for (arguments, environment) in launches {
            let process = TestIsolation.classify(arguments: arguments, environment: environment)
            XCTAssertTrue(process.testProcess, "\(arguments) \(environment)")
            let backend = FilesModel.panelBackend(arguments: arguments, testProcess: process.testProcess, sheet: sheet)
            for purpose in all {
                let answer = await backend(NSSavePanel(), window, purpose)
                XCTAssertNil(answer, "\(arguments) \(environment) \(purpose)")
            }
            AppWindowController.folderPanels(testProcess: process.testProcess, begin: begin)(NSOpenPanel()) { _ in }
        }
        XCTAssertEqual(folders.value, 0, "a test process would open a folder panel")
        // The probe answers in its root; a save of a file's transcript waits
        // for its gate there, so it is not asked here.
        let probed = FilesModel.panelBackend(arguments: ["-UITestSettingsStore", "-FileProbeRoot", probe.path], testProcess: true, sheet: sheet)
        let meetingPanel = NSSavePanel()
        meetingPanel.nameFieldStringValue = "2026-10-06 10-00 Meeting.md"
        let meetingAnswered = await probed(meetingPanel, window, .meetingTranscript)
        let meetingAnswer = try XCTUnwrap(meetingAnswered)
        XCTAssertEqual(meetingAnswer.deletingLastPathComponent().standardizedFileURL, probe.standardizedFileURL)
        XCTAssertEqual(meetingAnswer.pathExtension, "md")
        let suggested = try String(contentsOf: meetingAnswer.deletingPathExtension().appendingPathExtension("name"), encoding: .utf8)
        XCTAssertEqual(suggested, "2026-10-06 10-00 Meeting.md")
        let exported = await probed(NSSavePanel(), window, .dictionaryExport)
        let export = try XCTUnwrap(exported)
        XCTAssertEqual(export.deletingLastPathComponent().standardizedFileURL, probe.standardizedFileURL)
        let imported = await probed(NSOpenPanel(), window, .dictionaryImport)
        XCTAssertNil(imported, "an import with no file in the root answered")
        XCTAssertEqual(sheets.value, 0, "a test process asked AppKit for a panel")

        // A root that is not temporary leaves the probe off: no panel of any
        // kind is answered, and not one file written, its markers included.
        // The probe's writes are counted here, never made.
        let elsewhere = URL(fileURLWithPath: "/Murmurly-probe-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(FileProbe.root(in: ["-UITesting", "-FileProbeRoot", elsewhere.path]))
        XCTAssertEqual(FileProbe.root(in: ["-FileProbeRoot", probe.path])?.standardizedFileURL, probe.standardizedFileURL)
        let written = Counter()
        FileProbe.writer.standIn { _, _ in _ = written.next() }
        defer { FileProbe.writer.restore() }
        let refused = FilesModel.panelBackend(arguments: ["-UITesting", "-FileProbeRoot", elsewhere.path], testProcess: true, sheet: sheet)
        for purpose in all {
            let answer = await refused(meetingPanel, window, purpose)
            XCTAssertNil(answer, "\(purpose) was answered from a root that is not temporary")
        }
        XCTAssertEqual(written.value, 0, "the probe wrote outside a temporary folder")
        FileProbe.writer.restore()
        XCTAssertFalse(exists(elsewhere))
        // The UI test runner is sandboxed: its roots are in its container's tmp.
        let containers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        XCTAssertTrue(FileProbe.isTemporary(containers.appendingPathComponent("runner/Data/tmp/root")))
        XCTAssertFalse(FileProbe.isTemporary(containers.appendingPathComponent("runner/Data/Documents/root")))
        XCTAssertFalse(FileProbe.isTemporary(containers.appendingPathComponent("runner/Data/tmp")))
        XCTAssertFalse(FileProbe.isTemporary(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/root")))
        XCTAssertTrue(FileProbe.isTemporary(probe))

        // This very process, as every caller asks: the rule is chosen inside
        // `present`, on a window that is on screen, and only AppKit's last
        // call stands in, counting. A wiring that took this for a shipped
        // app reddens the count and reaches no AppKit panel.
        XCTAssertTrue(TestIsolation.isTestProcess)
        for purpose in all {
            let answer = await FilesModel.present(NSSavePanel(), on: window, as: purpose, sheet: sheet)
            XCTAssertNil(answer, "\(purpose)")
        }
        XCTAssertEqual(sheets.value, 0, "this test process asked AppKit for a panel")
        let given = ObjectIdentifier(window)
        let shipped = FilesModel.panelBackend(arguments: [], testProcess: false) { _, owner in
            XCTAssertEqual(ObjectIdentifier(owner), given, "the shipped app's panel went on another window")
            _ = sheets.next()
            return nil
        }
        _ = await shipped(NSSavePanel(), window, .filesTranscript)
        XCTAssertEqual(sheets.value, 1, "the shipped app does not ask AppKit for the panel")

        // The folder panel, as the menu's Transcribe Meeting… and Storage
        // open it, its rule chosen inside: never in this process; the
        // shipped app's opens.
        let gone = expectation(description: "the folder panel was asked for")
        AppWindowController.chooseFolder(message: "m", prompt: "p", directory: nil, begin: begin) { _ in
            XCTFail("a folder came from no panel")
        }
        DispatchQueue.main.async { gone.fulfill() }
        await fulfillment(of: [gone], timeout: 5)
        XCTAssertEqual(folders.value, 0, "this test process opened a folder panel")
        AppWindowController.folderPanels(testProcess: false, begin: begin)(NSOpenPanel()) { _ in }
        XCTAssertEqual(folders.value, 1, "the shipped app does not open the folder panel")
    }

    // MARK: - Deletion

    /// The tests' own Trash.
    private var trashFolder: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    /// Names of everything put in the tests' Trash.
    private func inTrash() -> Set<String> {
        let places = (try? FileManager.default.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil)) ?? []
        return Set(places.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A library over the local root with its window open, read.
    private func openLibrary(
        queue: MeetingTranscriptionQueue? = nil, recorder: MeetingRecorder? = nil, reader: MeetingLibrary.Reader = .disk
    ) async throws -> MeetingLibrary {
        let library = makeLibrary(recorder: recorder, queue: queue, reader: reader)
        library.windowOpened()
        try await until { library.local.fresh && !library.local.reading }
        return library
    }

    private func deleted(_ library: MeetingLibrary, _ folders: [URL], _ kind: MeetingLibrary.RemovalKind) async throws
        -> [MeetingLibrary.RemovalLine] {
        let plan = library.removalPlan(for: folders, kind: kind)
        let before = library.removalReport.count
        library.remove(plan)
        try await until { library.removalReport.count == before + plan.items.count || library.removalRecheck != nil }
        return Array(library.removalReport.dropFirst(before))
    }

    /// "Delete Audio" puts the tracks the metadata names, their CAF/m4a pairs
    /// and a killed compression's leftover in the Trash, and nothing else:
    /// the transcript, the marks and a note of the same type stay.
    func testDeletingAudioTrashesOnlyTheTracks() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: [
            "transcript.md": transcript("текст"), "notes.m4a": "мой звук", "system.caf": "leftover",
            ".system.partial.m4a": "partial", MeetingMarks.fileName: #"{"version":1,"starred":true}"#,
        ])
        let library = try await openLibrary()
        let plan = library.removalPlan(for: [meeting], kind: .audio)
        XCTAssertEqual(plan.refused, [])
        XCTAssertEqual(plan.items.count, 1)

        let lines = try await deleted(library, [meeting], .audio)

        XCTAssertEqual(lines.map(\.outcome), [.trashed])
        XCTAssertEqual(inTrash(), ["system.m4a", "system.caf", ".system.partial.m4a", "microphone.m4a"])
        for name in ["transcript.md", "notes.m4a", MeetingMarks.fileName, "metadata.json"] {
            XCTAssertTrue(exists(meeting.appendingPathComponent(name)), name)
        }
        try await until { library.meeting(at: meeting)?.audio == .known(files: [], missing: ["system.m4a", "microphone.m4a"]) }
    }

    /// Only plain names directly in the folder count as tracks, and nothing
    /// is followed through a link: a track named by a path, a track that is a
    /// link, a folder reached by a link — none is deleted, each says why.
    func testDeletionReadsTheFolderStrictly() async throws {
        let outsider = root.appendingPathComponent("outside.m4a")
        try Data("чужой".utf8).write(to: outsider)
        var named = done
        named["segments"] = [["index": 0, "system": "../../notes.caf", "mic": "microphone.m4a"]]
        let byPath = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: named, files: ["notes.caf": "local"])
        let linked = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done, tracks: ["microphone.m4a"])
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("system.m4a"), withDestinationURL: outsider)
        let nested = try seed("2026-10-06 12-00-00 Meeting", in: local, metadata: done, files: ["notes/tasks.md": "дела"])
        let library = try await openLibrary()

        for folder in [byPath, linked] {
            let plan = library.removalPlan(for: [folder], kind: .audio)
            XCTAssertEqual(plan.items, [], folder.lastPathComponent)
            XCTAssertEqual(plan.refused.count, 1, folder.lastPathComponent)
        }
        let whole = library.removalPlan(for: [nested, linked], kind: .meeting)
        XCTAssertEqual(whole.items, [])
        XCTAssertTrue(whole.refused.allSatisfy { $0.reason.contains("Finder") }, "\(whole.refused.map(\.reason))")
        XCTAssertTrue(exists(byPath.appendingPathComponent("notes.caf")))
        XCTAssertTrue(exists(outsider))
        XCTAssertTrue(exists(nested.appendingPathComponent("notes/tasks.md")))
        XCTAssertEqual(inTrash(), [])
    }

    /// "Delete Meeting" puts the whole folder in the Trash, the files not
    /// the app's own named first; a copy of its transcript in the
    /// transcripts folder stays, and the menu no longer points to it.
    func testDeletingAMeetingTrashesItsFolderAndForgetsIt() async throws {
        let copies = root.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        try Data("копия".utf8).write(to: copies.appendingPathComponent("2026-10-06 10-00-00 Meeting.md"))
        settings.transcriptsFolderPath = copies.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: ["tasks.md": "дела"])
        let library = try await openLibrary()
        library.select(meeting)

        let plan = library.removalPlan(for: [meeting], kind: .meeting)
        XCTAssertEqual(plan.items.first?.others, ["tasks.md"])
        let lines = try await deleted(library, [meeting], .meeting)

        XCTAssertEqual(lines.map(\.outcome), [.trashed])
        XCTAssertFalse(exists(meeting))
        XCTAssertEqual(inTrash(), [meeting.lastPathComponent])
        XCTAssertTrue(exists(copies.appendingPathComponent("2026-10-06 10-00-00 Meeting.md")), "the transcript's copy went too")
        XCTAssertNil(library.selection)
        try await until { library.meeting(at: meeting) == nil }
    }

    /// The menu's "Show Last Recording…" and the warning about a recording's
    /// tracks go with the meeting they point to.
    func testDeletionForgetsWhatTheMenuShowsOfTheMeeting() async throws {
        let recorder = makeRecorder()
        recorder.toggle()
        try await until { recorder.state == .recording }
        recorder.toggle()
        try await until { recorder.state == .idle && recorder.lastRecordingDirectory != nil }
        let meeting = try XCTUnwrap(recorder.lastRecordingDirectory)
        let library = try await openLibrary(recorder: recorder)
        try await until { library.meeting(at: meeting)?.state != nil }

        _ = try await deleted(library, [meeting], .meeting)

        XCTAssertNil(recorder.lastRecordingLocation, "the menu still shows the deleted meeting")
    }

    /// Deleted through another address (a link in a parent path), the
    /// meeting is still forgotten by the menu: matched by the folder itself.
    func testTheMenuForgetsAMeetingDeletedThroughAnotherAddress() async throws {
        let recorder = makeRecorder()
        recorder.toggle()
        try await until { recorder.state == .recording }
        recorder.toggle()
        try await until { recorder.state == .idle && recorder.lastRecordingDirectory != nil }
        let meeting = try XCTUnwrap(recorder.lastRecordingDirectory)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let library = try await openLibrary(recorder: recorder)
        library.open(spelled)
        try await until { library.meeting(at: spelled)?.state != nil }

        _ = try await deleted(library, [spelled], .meeting)

        XCTAssertFalse(exists(meeting))
        XCTAssertNil(recorder.lastRecordingLocation, "the menu still shows the meeting deleted through a link")
    }

    /// What was confirmed is what goes: a file of the same name put in place
    /// of another, a file grown, a file added, a folder added — the meeting
    /// is asked about again (or refused, for a folder inside) and nothing
    /// unconfirmed is deleted. Finder's own `.DS_Store` may change.
    func testOnlyWhatWasConfirmedIsDeleted() async throws {
        let changes: [(String, (URL) throws -> Void)] = [
            ("replaced", { folder in
                try FileManager.default.removeItem(at: folder.appendingPathComponent("tasks.md"))
                try Data("дела".utf8).write(to: folder.appendingPathComponent("tasks.md"))
            }),
            ("grown", { folder in
                let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("tasks.md"))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" и ещё".utf8))
                try handle.close()
            }),
            ("added", { folder in try Data("новое".utf8).write(to: folder.appendingPathComponent("new.md")) }),
            ("nested", { folder in
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
            }),
        ]
        var folders: [URL] = []
        for (index, _) in changes.enumerated() {
            folders.append(try seed("2026-10-06 1\(index)-00-00 Meeting", in: local, metadata: done, files: ["tasks.md": "дела"]))
        }
        let finder = try seed("2026-10-06 18-00-00 Meeting", in: local, metadata: done, files: [".DS_Store": "a"])
        let library = try await openLibrary()

        for ((name, change), folder) in zip(changes, folders) {
            let plan = library.removalPlan(for: [folder], kind: .meeting)
            XCTAssertEqual(plan.items.count, 1, name)
            try change(folder)
            library.dismissRemovalRecheck()
            library.dismissRemovalReport()
            library.remove(plan)
            try await until { library.removalRecheck != nil || !library.removalReport.isEmpty }
            XCTAssertTrue(exists(folder), "\(name): deleted though it changed")
            if name == "nested" {
                XCTAssertEqual(library.removalReport.map(\.outcome.isRefused), [true], name)
            } else {
                XCTAssertEqual(library.removalRecheck?.items.map(\.id), [MeetingLibrary.canonical(folder)], "\(name): not asked again")
            }
        }
        let plan = library.removalPlan(for: [finder], kind: .meeting)
        try Data("Finder wrote this".utf8).write(to: finder.appendingPathComponent(".DS_Store"))
        library.dismissRemovalReport()
        library.remove(plan)
        try await until { !library.removalReport.isEmpty }
        XCTAssertEqual(library.removalReport.map(\.outcome), [.trashed], "a rewritten .DS_Store held the deletion")
    }

    /// Each file is checked right before it goes: a track put in place of the
    /// second after the first went to the Trash stays, and the result says
    /// what went and what is left.
    func testEachFileIsCheckedRightBeforeItGoes() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let calls = Counter()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        removal.beforeCheck = { folder in
            guard calls.next() == 2 else { return }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("microphone.m4a"))
            try? Data("другой".utf8).write(to: folder.appendingPathComponent("microphone.m4a"))
        }
        let library = try await openLibrary(queue: makeQueue(removal: removal))

        let lines = try await deleted(library, [meeting], .audio)

        guard case .stopped(_, let trashed, let left, _)? = lines.first?.outcome else {
            return XCTFail("\(lines)")
        }
        XCTAssertEqual(trashed, ["system.m4a"])
        XCTAssertEqual(left, ["microphone.m4a"])
        XCTAssertTrue(exists(meeting.appendingPathComponent("microphone.m4a")), "a file put in place went to the Trash")
    }

    /// A disk with no Trash: nothing is deleted for good, the folder is shown
    /// in Finder, and the result says so.
    func testADiskWithoutATrashDeletesNothingAndShowsTheFolder() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let removed = Counter()
        let removal = MeetingStorage.Removal(
            trash: { _ in throw CocoaError(.featureUnsupported) },
            remove: { _ in _ = removed.next() }
        )
        let library = try await openLibrary(queue: makeQueue(removal: removal))
        var shown: [URL] = []
        library.reveal = { shown.append($0) }

        for kind in [MeetingLibrary.RemovalKind.audio, .meeting] {
            let lines = try await deleted(library, [meeting], kind)
            XCTAssertEqual(lines.map(\.outcome), [.noTrash], "\(kind)")
        }
        XCTAssertEqual(shown, [MeetingLibrary.canonical(meeting), MeetingLibrary.canonical(meeting)])
        XCTAssertEqual(removed.value, 0, "deleted for good without a Trash")
        XCTAssertTrue(exists(meeting.appendingPathComponent("system.m4a")))
    }

    /// No Trash found after the first file went: the folder is shown in
    /// Finder all the same, for the rest.
    func testNoTrashAfterThePartThatWentShowsTheFolder() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let calls = Counter()
        let confined = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        let removal = MeetingStorage.Removal(
            trash: { url in
                guard calls.next() == 1 else { throw CocoaError(.featureUnsupported) }
                try confined.trash(url)
            },
            remove: { _ in XCTFail("deleted for good") }
        )
        let library = try await openLibrary(queue: makeQueue(removal: removal))
        var shown: [URL] = []
        library.reveal = { shown.append($0) }

        _ = try await deleted(library, [meeting], .audio)

        XCTAssertEqual(shown, [MeetingLibrary.canonical(meeting)], "the folder was not shown for the rest")
        XCTAssertTrue(exists(meeting.appendingPathComponent("microphone.m4a")))
    }

    /// In a test process the disk's own deletion is never called without a
    /// test's own Trash, and a test's Trash touches nothing outside its roots.
    func testATestProcessDeletesNothingWithoutItsOwnTrash() throws {
        let folder = root.appendingPathComponent("2026-10-06 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("system.m4a"))
        guard case .file(let fact) = MeetingStorage.entry("system.m4a", in: folder),
              let identity = FolderIdentity.of(folder) else { return XCTFail("seed") }
        for forGood in [false, true] {
            if case .success = MeetingStorage.Removal.live.perform(.file(fact), in: folder, folderIdentity: identity, forGood: forGood) {
                XCTFail("the disk's own deletion ran in a test process")
            }
        }
        let elsewhere = MeetingStorage.Removal.confined(to: [root.appendingPathComponent("Other")], trash: trashFolder)
        if case .success = elsewhere.perform(.file(fact), in: folder, folderIdentity: identity, forGood: true) {
            XCTFail("a test's Trash deleted outside its roots")
        }
        XCTAssertTrue(exists(folder.appendingPathComponent("system.m4a")))
    }

    /// The recording under way is known by its folder, not its path: moved
    /// in Finder and opened at its new address, it is not deleted.
    func testTheRecordingUnderWayIsNotDeletedAtAnotherAddress() async throws {
        let recorder = makeRecorder()
        let queue = makeQueue()
        recorder.transcripts = queue
        let library = try await openLibrary(queue: queue, recorder: recorder)
        recorder.toggle()
        try await until { recorder.state == .recording }
        let live = try XCTUnwrap(recorder.currentSession?.directory)
        let moved = local.appendingPathComponent("2026-10-06 23-59-59 Meeting", isDirectory: true)
        try FileManager.default.moveItem(at: live, to: moved)
        library.refresh()
        library.open(moved)
        try await until { library.meeting(at: moved) != nil }

        let plan = library.removalPlan(for: [moved], kind: .meeting)
        XCTAssertEqual(plan.items, [], "the recording under way could be deleted at its new address")
        if case .success = queue.reserve(try XCTUnwrap(MeetingStorage.address(of: moved)), folder: moved) {
            XCTFail("the queue took the recording under way for deletion")
        }
        try FileManager.default.moveItem(at: moved, to: live)
        recorder.toggle()
        try await until { recorder.state == .idle }
    }

    /// The UI tests' probe Trash works only inside the root those tests
    /// seeded, named by its own argument: without it, nothing is deleted,
    /// least of all from the app's own meetings folder. That folder is
    /// stood in for by a temporary one of the test's own: no test writes to
    /// or cleans a path the app computes for itself.
    func testTheProbeTrashNeedsItsOwnSeededRoot() throws {
        let appRoot = root.appendingPathComponent("App meetings", isDirectory: true)
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: appRoot, metadata: done)
        guard case .file(let fact) = MeetingStorage.entry("system.m4a", in: meeting), let identity = FolderIdentity.of(meeting) else {
            return XCTFail("seed")
        }
        let probe = ["-RemovalProbeTrash", trashFolder.path]
        for (testProcess, arguments) in [(true, probe), (false, probe), (true, probe + ["-MeetingsProbeRoot", appRoot.path])] {
            let removal = MeetingStorage.Removal.backend(arguments: arguments, testProcess: testProcess, appMeetingsRoot: appRoot)
            if case .success = removal.perform(.file(fact), in: meeting, folderIdentity: identity, forGood: false) {
                XCTFail("the probe Trash took a file from the app's own meetings: \(arguments)")
            }
        }
        XCTAssertTrue(exists(meeting.appendingPathComponent("system.m4a")))

        // A seeded root around the owner's meetings, or inside them, is as
        // bad as one on them.
        let innerRoot = appRoot.appendingPathComponent("Inner", isDirectory: true)
        let inner = try seed("2026-10-06 12-00-00 Meeting", in: innerRoot, metadata: done)
        guard case .file(let innerFact) = MeetingStorage.entry("system.m4a", in: inner),
              let innerIdentity = FolderIdentity.of(inner) else {
            return XCTFail("seed")
        }
        for (seededRoot, folder, file, folderIdentity) in [(root!, meeting, fact, identity), (innerRoot, inner, innerFact, innerIdentity)] {
            let removal = MeetingStorage.Removal.backend(
                arguments: probe + ["-MeetingsProbeRoot", seededRoot.path], testProcess: true, appMeetingsRoot: appRoot
            )
            if case .success = removal.perform(.file(file), in: folder, folderIdentity: folderIdentity, forGood: false) {
                XCTFail("the probe Trash reached the owner's meetings from \(seededRoot.lastPathComponent)")
            }
        }
        XCTAssertTrue(exists(inner.appendingPathComponent("system.m4a")))
        // What the app's own probe compares with is the owner's folder, not
        // the root a test moved the app to.
        XCTAssertNotEqual(RecordingsStore.ownersMeetingsRoot(), RecordingsStore.meetingsRoot())
        XCTAssertTrue(RecordingsStore.ownersMeetingsRoot().path.hasSuffix("/Application Support/Murmurly/Meetings"))

        let seeded = MeetingStorage.Removal.backend(
            arguments: probe + ["-MeetingsProbeRoot", local.path], testProcess: true, appMeetingsRoot: appRoot
        )
        if case .success = seeded.perform(.file(fact), in: meeting, folderIdentity: identity, forGood: false) {
            XCTFail("the probe Trash reached outside its seeded root")
        }
        let inside = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        guard case .file(let own) = MeetingStorage.entry("system.m4a", in: inside), let ownIdentity = FolderIdentity.of(inside) else {
            return XCTFail("seed")
        }
        if case .failure(let failure) = seeded.perform(.file(own), in: inside, folderIdentity: ownIdentity, forGood: false) {
            XCTFail("the probe Trash refused its own seeded root: \(failure)")
        }
    }

    /// The destination is checked again by its whole address before the
    /// move uses it: the meetings folder reached through a link that points
    /// elsewhere after the move took its place is not moved into, even with
    /// no folder there either way.
    func testAMoveChecksItsDestinationsWholeAddressAfterWaiting() async throws {
        let diskLink = root.appendingPathComponent("Disk link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: diskLink, withDestinationURL: disk)
        let other = root.appendingPathComponent("Other/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        settings.meetingsFolderPath = diskLink.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let gate = DiskGate()
        let moves = Counter()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        queue.mover = { folder, target, localRoot in
            _ = moves.next()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        let library = makeLibrary(queue: queue, reader: gate.reader)
        // The move asks about the marks once it has read its destination.
        let asked = Counter()
        let marks = queue.marksBeingWritten
        queue.marksBeingWritten = { identity in
            _ = asked.next()
            return marks(identity)
        }
        library.windowOpened()
        try await until { library.local.fresh }
        library.open(spelled)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(spelled) } }
        gate.holdWrites(meeting)
        library.toggleStar(try XCTUnwrap(library.meeting(at: spelled)))
        try await until { gate.writes(of: meeting) == 1 }
        queue.enqueue(meeting, transcribe: false)
        try await until { asked.value > 0 }

        try FileManager.default.removeItem(at: diskLink)
        try FileManager.default.createSymbolicLink(at: diskLink, withDestinationURL: other)
        gate.releaseWrites(meeting)
        try await until { queue.activeJob == nil && queue.pending.isEmpty && library.pendingMarks.isEmpty }

        XCTAssertEqual(moves.value, 0, "moved into a place other than the one it took")
        XCTAssertTrue(exists(meeting))
        XCTAssertFalse(exists(other.appendingPathComponent(meeting.lastPathComponent)))
    }

    /// A transcription waiting in the queue keeps the folder it was asked
    /// for: queued plainly (as the menu does) behind another job, it still
    /// refuses a deletion of that folder through another address, and only
    /// of that folder: another meeting can be deleted meanwhile.
    func testAWaitingTranscriptionRefusesADeletionThroughAnotherAddress() async throws {
        let first = try seed("2026-10-06 09-00-00 Meeting", in: local, metadata: done)
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let door = Door()
        let queue = makeQueue(door: door)
        let library = try await openLibrary(queue: queue)
        library.open(spelled)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(spelled) } }
        queue.enqueue(first)
        try await until { queue.isTranscribing }
        queue.enqueue(meeting)

        let plan = library.removalPlan(for: [spelled], kind: .meeting)
        XCTAssertEqual(plan.items, [], "deletable through a link while it waits to be transcribed")
        if case .success = queue.reserve(try XCTUnwrap(MeetingStorage.address(of: spelled)), folder: spelled) {
            XCTFail("taken for deletion while it waits to be transcribed")
        }
        switch queue.reserve(try XCTUnwrap(MeetingStorage.address(of: other)), folder: other) {
        case .success(let taken): queue.endOperations([taken])
        case .failure(let refusal): XCTFail("another meeting refused while one waits: \(refusal.reason)")
        }
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// After the queue's own move, a transcription waiting for the moved
    /// meeting knows the folder at its new place: a deletion of that folder
    /// through another address is refused.
    func testAWaitingJobKnowsTheFolderItsMeetingWasMovedTo() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let busy = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let diskLink = root.appendingPathComponent("Disk link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: diskLink, withDestinationURL: disk)
        let moved = disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let spelled = diskLink.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let door = Door()
        let latch = Latch()
        let queue = makeQueue(door: door, destinations: { [settings] in settings!.meetingDestinations })
        queue.mover = { folder, target, localRoot in
            latch.wait()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        queue.enqueue(meeting, transcribe: false)
        try await until { latch.wasReached }
        queue.enqueue(busy)
        queue.enqueue(meeting)
        latch.release()
        try await until { self.exists(moved) && queue.isTranscribing }

        let waiting = try XCTUnwrap(queue.pending.first { $0.transcribe })
        XCTAssertEqual(waiting.folder.path, moved.path)
        XCTAssertEqual(waiting.identity, FolderIdentity.of(moved), "the waiting job kept the identity of the folder that went")
        if case .success = queue.reserve(try XCTUnwrap(MeetingStorage.address(of: spelled)), folder: spelled) {
            XCTFail("the moved meeting was taken for deletion while it waits to be transcribed")
        }
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// A transcription waiting for a folder that cannot be read is no
    /// folder known: it might be any meeting, so every deletion waits until
    /// the job has run and dropped itself.
    func testAnUnknownWaitingTranscriptionHoldsEveryDeletionBack() async throws {
        let first = try seed("2026-10-06 09-00-00 Meeting", in: local, metadata: done)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        let away = try seed("2026-10-06 12-00-00 Meeting", in: locked, metadata: done)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let door = Door()
        let queue = makeQueue(door: door)
        let library = try await openLibrary(queue: queue)
        queue.enqueue(first)
        try await until { queue.isTranscribing }
        queue.enqueue(away)

        let address = try XCTUnwrap(MeetingStorage.address(of: other))
        guard case .failure(let refusal) = queue.reserve(address, folder: other) else {
            return XCTFail("deleted while a transcription waits for a folder nobody knows")
        }
        XCTAssertEqual(refusal.reason, queue.untoldTranscription)
        XCTAssertEqual(library.removalRefusal(for: try XCTUnwrap(library.meeting(at: other)), kind: .meeting),
                       queue.untoldTranscription)
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        switch queue.reserve(address, folder: other) {
        case .success(let taken): queue.endOperations([taken])
        case .failure(let refusal): XCTFail("still refused once the job dropped itself: \(refusal.reason)")
        }
    }

    /// A transcription asked for a meeting outside the local root learns its
    /// folder off the main actor right after it is queued: from then on it
    /// refuses only that folder, through any address.
    func testAWaitingTranscriptionElsewhereLearnsItsFolder() async throws {
        let first = try seed("2026-10-06 09-00-00 Meeting", in: local, metadata: done)
        let other = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let away = try seed("2026-10-06 12-00-00 Meeting", in: disk, metadata: done)
        let diskLink = root.appendingPathComponent("Disk link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: diskLink, withDestinationURL: disk)
        let spelled = diskLink.appendingPathComponent(away.lastPathComponent, isDirectory: true)
        let door = Door()
        let queue = makeQueue(door: door)
        queue.enqueue(first)
        try await until { queue.isTranscribing }
        queue.enqueue(away)

        try await until { queue.pending.first?.identity != nil }
        XCTAssertEqual(queue.pending.first?.identity, FolderIdentity.of(away))
        XCTAssertNil(queue.untoldTranscription)
        if case .success = queue.reserve(try XCTUnwrap(MeetingStorage.address(of: spelled)), folder: spelled) {
            XCTFail("taken for deletion through a link while it waits to be transcribed")
        }
        switch queue.reserve(try XCTUnwrap(MeetingStorage.address(of: other)), folder: other) {
        case .success(let taken): queue.endOperations([taken])
        case .failure(let refusal): XCTFail("another meeting refused while one waits: \(refusal.reason)")
        }
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// A job whose folder cannot be told (its parent cannot be resolved)
    /// does not start: unknown is no reason to go past a deletion. The
    /// transcription asked for says why it did not happen.
    func testAJobWhoseFolderCannotBeToldDoesNotStart() async throws {
        let queue = makeQueue(speaks: true)
        let nowhere = root.appendingPathComponent("Gone/2026-10-06 10-00-00 Meeting", isDirectory: true)
        var transcribing: [Bool] = []
        let watch = queue.$isTranscribing.sink { transcribing.append($0) }
        defer { watch.cancel() }
        queue.enqueue(nowhere)
        try await until { queue.activeJob == nil && queue.pending.isEmpty && queue.lastOutcome != nil }
        XCTAssertFalse(transcribing.contains(true), "a job worked on a folder it could not tell")
        guard case .failed? = queue.lastOutcome else { return XCTFail("\(String(describing: queue.lastOutcome))") }
    }

    /// A folder that is not a meeting's, opened from outside both roots,
    /// loses nothing to a deletion, whatever metadata and audio it holds.
    func testNothingIsDeletedFromAFolderThatIsNotAMeetings() async throws {
        let documents = try seed("Documents", in: root, metadata: done, files: ["notes.md": "мои заметки"])
        let library = try await openLibrary()
        library.open(documents)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(documents) } }

        for kind in [MeetingLibrary.RemovalKind.audio, .meeting] {
            let plan = library.removalPlan(for: [documents], kind: kind)
            XCTAssertEqual(plan.items, [], "\(kind) offered for a folder that is not a meeting's")
            library.remove(MeetingLibrary.RemovalPlan(
                kind: kind,
                items: try XCTUnwrap(library.meeting(at: documents)).identity.map { identity in
                    [MeetingLibrary.RemovalItem(
                        meeting: try XCTUnwrap(library.meeting(at: documents)),
                        identity: identity,
                        target: kind == .audio
                            ? .audio(try XCTUnwrap(library.meeting(at: documents)?.audio.files))
                            : { guard case .read(let manifest)? = library.meeting(at: documents)?.manifest else { return .audio([]) }; return .meeting(manifest) }()
                    )]
                } ?? [],
                refused: []
            ))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(inTrash(), [], "a deletion carried out for a folder that is not a meeting's")
        XCTAssertTrue(exists(documents.appendingPathComponent("system.m4a")))
    }

    /// Deleting audio needs the metadata read in full: tracks of another
    /// shape than the app writes are not taken for the default ones, and a
    /// metadata.json gone after the sheet stops the deletion.
    func testDeletingAudioNeedsTheMetadataReadInFull() async throws {
        var malformed = done
        malformed["segments"] = "system.m4a, microphone.m4a"
        let odd = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: malformed)
        let meeting = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let library = try await openLibrary()

        XCTAssertEqual(library.removalPlan(for: [odd], kind: .audio).items, [], "a malformed metadata.json passed for the default tracks")
        let plan = library.removalPlan(for: [meeting], kind: .audio)
        XCTAssertEqual(plan.items.count, 1)
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("metadata.json"))
        library.remove(plan)
        try await until { !library.removalReport.isEmpty || library.removalRecheck != nil }
        XCTAssertEqual(inTrash(), [], "audio deleted though its metadata went after the sheet")
        XCTAssertTrue(exists(odd.appendingPathComponent("system.m4a")))
    }

    /// A meeting's folder that is itself the transcripts folder (reached
    /// through a link) is not deleted whole: the sheet promises the copies
    /// stay.
    func testTheTranscriptsFolderIsNotDeletedAsAMeeting() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: [
            "2026-10-05 10-00-00 Meeting.md": "копия",
        ])
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: copies, withDestinationURL: meeting)
        settings.transcriptsFolderPath = copies.path
        let library = try await openLibrary()

        let lines = try await deleted(library, [meeting], .meeting)

        XCTAssertEqual(lines.map(\.outcome.isRefused), [true], "\(lines)")
        XCTAssertTrue(exists(meeting.appendingPathComponent("2026-10-05 10-00-00 Meeting.md")), "the transcripts' copies went to the Trash")
    }

    /// The transcripts folder is read again right before the Trash: set to
    /// the meeting's own folder (through a link) while the deletion waits,
    /// it refuses the deletion.
    func testATranscriptsFolderChosenDuringADeletionRefusesIt() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: [
            "2026-10-05 10-00-00 Meeting.md": "копия",
        ])
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: copies, withDestinationURL: meeting)
        let latch = Latch()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        removal.beforeCheck = { _ in latch.wait() }
        let library = try await openLibrary(queue: makeQueue(removal: removal))
        let plan = library.removalPlan(for: [meeting], kind: .meeting)
        XCTAssertEqual(plan.items.count, 1)

        library.remove(plan)
        try await until { latch.wasReached }
        settings.transcriptsFolderPath = copies.path
        latch.release()
        try await until { !library.removalReport.isEmpty }

        XCTAssertEqual(library.removalReport.map(\.outcome.isRefused), [true], "\(library.removalReport)")
        XCTAssertTrue(exists(meeting.appendingPathComponent("2026-10-05 10-00-00 Meeting.md")), "the transcripts' copies went to the Trash")
        XCTAssertEqual(inTrash(), [])
    }

    /// The transcripts folder is read again after the folder it named was
    /// resolved, which on a network volume may take long: chosen meanwhile
    /// through a link to the very meeting being deleted, it refuses. A
    /// folder that cannot be told refuses too.
    func testTheTranscriptsFolderIsReadAgainAfterItIsResolved() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done, files: [
            "2026-10-05 10-00-00 Meeting.md": "копия",
        ])
        let before = root.appendingPathComponent("Other copies", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: meeting)
        settings.transcriptsFolderPath = before.path
        let latch = Latch()
        var reader = MeetingLibrary.Reader.disk
        reader.copiesFolder = { folder in
            if folder.standardizedFileURL.path == before.standardizedFileURL.path { latch.wait() }
            return FolderIdentity.reach(folder)
        }
        let removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        let library = try await openLibrary(queue: makeQueue(removal: removal), reader: reader)
        let plan = library.removalPlan(for: [meeting], kind: .meeting)
        XCTAssertEqual(plan.items.count, 1)

        library.remove(plan)
        try await until { latch.wasReached }
        settings.transcriptsFolderPath = alias.path
        latch.release()
        try await until { !library.removalReport.isEmpty }
        XCTAssertEqual(library.removalReport.map(\.outcome.isRefused), [true], "\(library.removalReport)")
        XCTAssertTrue(exists(meeting.appendingPathComponent("2026-10-05 10-00-00 Meeting.md")), "the transcripts' copies went to the Trash")
        XCTAssertEqual(inTrash(), [])

        var untold = MeetingLibrary.Reader.disk
        untold.copiesFolder = { _ in .unknown("the volume does not answer") }
        settings.transcriptsFolderPath = before.path
        let other = try await openLibrary(queue: makeQueue(removal: removal), reader: untold)
        other.remove(other.removalPlan(for: [meeting], kind: .meeting))
        try await until { !other.removalReport.isEmpty }
        XCTAssertEqual(other.removalReport.map(\.outcome.isRefused), [true], "a transcripts folder that can't be told let the meeting go")
        XCTAssertEqual(inTrash(), [])
    }

    /// The transcripts folder is resolved before the meeting is checked for
    /// the last time: held there, the meeting replaced at its address, or
    /// given a file nobody confirmed, nothing goes to the Trash.
    func testTheTranscriptsFolderIsResolvedBeforeTheLastCheckOfTheMeeting() async throws {
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        settings.transcriptsFolderPath = copies.path
        let trashed = Counter()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        let trash = removal.trash
        removal.trash = { url in
            _ = trashed.next()
            try trash(url)
        }
        for change in ["replaced", "a new file"] {
            let name = change == "replaced" ? "2026-10-06 10-00-00 Meeting" : "2026-10-06 11-00-00 Meeting"
            let meeting = try seed(name, in: local, metadata: done)
            let latch = Latch()
            var reader = MeetingLibrary.Reader.disk
            reader.copiesFolder = { folder in
                latch.wait()
                return FolderIdentity.reach(folder)
            }
            let library = try await openLibrary(queue: makeQueue(removal: removal), reader: reader)
            library.remove(library.removalPlan(for: [meeting], kind: .meeting))
            try await until { latch.wasReached }
            if change == "replaced" {
                try FileManager.default.moveItem(at: meeting, to: root.appendingPathComponent("Aside \(name)", isDirectory: true))
                try seed(name, in: local, metadata: done)
            } else {
                try Data("дела".utf8).write(to: meeting.appendingPathComponent("tasks.md"))
            }
            latch.release()
            try await until { !library.removalReport.isEmpty }
            XCTAssertEqual(trashed.value, 0, "\(change): the Trash took what was not confirmed")
            XCTAssertTrue(exists(meeting.appendingPathComponent("metadata.json")), "\(change): the folder at the address went")
            XCTAssertNotEqual(library.removalReport.first?.outcome, .trashed)
        }
    }

    /// One folder, two addresses: busy through one (its marks being
    /// written through a link in a parent path, a job transcribing it), it
    /// cannot be deleted through the other.
    func testAFolderBusyThroughOneAddressIsNotDeletedThroughAnother() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let spelled = link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        let gate = DiskGate()
        let door = Door()
        let queue = makeQueue(door: door)
        let library = try await openLibrary(queue: queue, reader: gate.reader)
        library.open(spelled)
        try await until { library.outsideMeetings.contains { $0.directory == MeetingLibrary.canonical(spelled) } }

        gate.holdWrites(meeting)
        library.toggleStar(try XCTUnwrap(library.meeting(at: spelled)))
        try await until { gate.writes(of: meeting) == 1 }
        XCTAssertNotNil(library.removalRefusal(for: try XCTUnwrap(library.meeting(at: meeting)), kind: .meeting),
                        "deletable while its marks are written through another address")
        gate.releaseWrites(meeting)
        try await until { library.pendingMarks.isEmpty }

        queue.enqueue(meeting)
        try await until { queue.activeAddress != nil }
        XCTAssertNotNil(library.removalRefusal(for: try XCTUnwrap(library.meeting(at: spelled)), kind: .meeting),
                        "deletable through a link while a job transcribes it")
        door.unlock()
        try await until { queue.activeJob == nil }
    }

    /// A folder taken for deletion takes no new job, whatever asks: the
    /// window, the menu, a scan, or a job for another spelling of it, which
    /// finds out as it starts and leaves the folder alone.
    func testAFolderTakenForDeletionTakesNoJob() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: doneCAF, tracks: ["system.caf", "microphone.caf"])
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let queue = makeQueue(speaks: true)
        let address = try XCTUnwrap(MeetingStorage.address(of: meeting))
        let taken = try queue.reserve(address, folder: meeting).get()
        var queued: [String] = []
        let watch = queue.$pending.sink { queued += $0.map(\.folder.path) }
        defer { watch.cancel() }

        queue.enqueue(meeting)
        queue.enqueue(meeting, transcribe: false)
        queue.scanLocalFolders()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(queued, [], "a folder taken for deletion was queued")

        queue.enqueue(link.appendingPathComponent(meeting.lastPathComponent, isDirectory: true))
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        let names = try FileManager.default.contentsOfDirectory(atPath: meeting.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("transcript") || $0.hasPrefix(MeetingAttempt.namePrefix) }, "\(names)")
        XCTAssertTrue(names.contains("system.caf"), "compressed while taken")
        queue.endOperations([taken])
    }

    /// A move takes its source and its destination before it touches either:
    /// held with a copy already at the destination, that copy cannot be
    /// deleted; the other way round, a destination being deleted is not
    /// moved into; and a destination not made yet is known by its path.
    func testAMoveAndADeletionOfItsDestinationExcludeEachOther() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let copy = disk.appendingPathComponent(meeting.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: meeting, to: copy)
        let latch = Latch()
        let moves = Counter()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        queue.mover = { folder, target, localRoot in
            _ = moves.next()
            latch.wait()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        let copyAddress = try XCTUnwrap(MeetingStorage.address(of: copy))

        // (a) The move holds the existing copy first.
        queue.enqueue(meeting, transcribe: false)
        try await until { latch.wasReached }
        if case .success = queue.reserve(copyAddress, folder: copy) { XCTFail("the move's destination was taken for deletion") }
        latch.release()
        try await until { queue.activeJob == nil }
        XCTAssertTrue(exists(copy))

        // (b) A deletion holds the copy first: the next move does not start.
        let again = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let againCopy = disk.appendingPathComponent(again.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: again, to: againCopy)
        let taken = try queue.reserve(try XCTUnwrap(MeetingStorage.address(of: againCopy)), folder: againCopy).get()
        let before = moves.value
        queue.enqueue(again, transcribe: false)
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(moves.value, before, "moved into a folder being deleted")
        XCTAssertTrue(exists(again))
        queue.endOperations([taken])

        // (c) No destination yet: its path is taken all the same.
        let fresh = try seed("2026-10-06 12-00-00 Meeting", in: local, metadata: done)
        let freshCopy = disk.appendingPathComponent(fresh.lastPathComponent, isDirectory: true)
        let held = Latch()
        queue.mover = { folder, target, _ in
            let place = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: folder, to: place)
            held.wait()
            try FileManager.default.removeItem(at: folder)
            return place
        }
        queue.enqueue(fresh, transcribe: false)
        try await until { held.wasReached }
        if case .success = queue.reserve(try XCTUnwrap(MeetingStorage.address(of: freshCopy)), folder: freshCopy) {
            XCTFail("a destination made by the move was taken for deletion")
        }
        held.release()
        try await until { queue.activeJob == nil }
    }

    /// A scan that found a folder before it was deleted drops what it found
    /// and looks again: no job for a folder that is gone.
    func testAScanFromBeforeADeletionIsDropped() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: doneCAF, tracks: ["system.caf", "microphone.caf"])
        let queue = makeQueue()
        let latch = Latch()
        let scans = Counter()
        queue.folderScan = { root, moving in
            let found = MeetingStorage.foldersNeedingWork(in: root, moving: moving)
            if scans.next() == 1 { latch.wait() }
            return found
        }
        var jobs: [String] = []
        let watch = queue.$activeJob.compactMap { $0?.folder.lastPathComponent }.sink { jobs.append($0) }
        defer { watch.cancel() }

        queue.scanLocalFolders()
        try await until { latch.wasReached }
        let taken = try queue.reserve(try XCTUnwrap(MeetingStorage.address(of: meeting)), folder: meeting).get()
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: meeting, to: trashFolder.appendingPathComponent(meeting.lastPathComponent))
        queue.endOperations([taken])
        latch.release()
        try await Task.sleep(for: .milliseconds(300))
        try await until { queue.activeJob == nil && queue.pending.isEmpty }

        XCTAssertEqual(jobs, [], "a job for a deleted folder from a scan that began before")
        XCTAssertGreaterThanOrEqual(scans.value, 2, "the scan did not look again")
    }

    /// The check is made again when the deletion is carried out: a job asked
    /// for after the sheet opened refuses it; waiting upkeep is dropped for
    /// it, a waiting transcription refuses it.
    func testADeletionIsCheckedAgainWhenItIsCarriedOut() async throws {
        let first = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let second = try seed("2026-10-06 11-00-00 Meeting", in: local, metadata: done)
        let third = try seed("2026-10-06 12-00-00 Meeting", in: local, metadata: done)
        let door = Door()
        let queue = makeQueue(door: door)
        let library = try await openLibrary(queue: queue)

        let plan = library.removalPlan(for: [first], kind: .meeting)
        XCTAssertEqual(plan.items.count, 1)
        queue.enqueue(first)
        try await until { queue.activeJob != nil }
        library.remove(plan)
        try await until { !library.removalReport.isEmpty }
        XCTAssertEqual(library.removalReport.map(\.outcome.isRefused), [true])
        XCTAssertTrue(exists(first))

        queue.enqueue(second, transcribe: false)
        queue.enqueue(third)
        library.dismissRemovalReport()
        library.remove(library.removalPlan(for: [second], kind: .meeting))
        try await until { !library.removalReport.isEmpty }
        XCTAssertEqual(library.removalReport.map(\.outcome), [.trashed])
        XCTAssertFalse(queue.pending.contains { $0.folder.lastPathComponent == second.lastPathComponent })
        let waiting = library.removalPlan(for: [third], kind: .meeting)
        XCTAssertEqual(waiting.refused.map(\.reason), [String(localized: "The meeting is waiting to be transcribed.")])
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// While a meeting is being deleted its marks are refused; while its
    /// marks are being written it is not deleted.
    func testMarksAndDeletionExcludeEachOther() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: local, metadata: done)
        let there = try seed("2026-10-06 11-00-00 Meeting", in: disk, metadata: done)
        let latch = Latch()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        removal.beforeCheck = { _ in latch.wait() }
        let gate = DiskGate()
        let library = makeLibrary(queue: makeQueue(removal: removal), reader: gate.reader)
        library.windowOpened()
        try await until { library.local.fresh && library.chosen?.fresh == true }

        library.remove(library.removalPlan(for: [meeting], kind: .meeting))
        try await until { latch.wasReached }
        let row = try XCTUnwrap(library.meeting(at: meeting))
        XCTAssertNotNil(library.markRefusal(for: row))
        library.toggleStar(row)
        XCTAssertFalse(exists(meeting.appendingPathComponent(MeetingMarks.fileName)), "a star was written into a folder being deleted")
        latch.release()
        try await until { !library.removalReport.isEmpty }

        gate.holdWrites(there)
        library.toggleStar(try XCTUnwrap(library.meeting(at: there)))
        try await until { gate.writes(of: there) == 1 }
        XCTAssertNotNil(library.removalRefusal(for: try XCTUnwrap(library.meeting(at: there)), kind: .meeting))
        gate.releaseWrites(there)
        try await until { library.pendingMarks.isEmpty }
    }

    // MARK: - Old audio

    /// The audio rule a queue reads, as a test sets it.
    @MainActor
    private final class Rule {
        var days = 0
        var generation = 0
        func set(_ days: Int) {
            self.days = days
            generation += 1
        }
    }

    private func ruledQueue(
        _ rule: Rule,
        removal: MeetingStorage.Removal? = nil,
        door: Door? = nil,
        speaks: Bool = false,
        localRoot: URL? = nil,
        destinations: @escaping @MainActor () -> MeetingTranscriptionQueue.Destinations = { .init() }
    ) -> MeetingTranscriptionQueue {
        let queue = makeQueue(door: door, speaks: speaks, localRoot: localRoot, removal: removal, destinations: destinations)
        queue.audioRetention = { (rule.days, rule.generation) }
        queue.writeAudioRetention = { rule.set($0) }
        return queue
    }

    private var longAgo: Date { Date().addingTimeInterval(-40 * 86_400) }

    private func tracks(of folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".m4a") })
    }

    /// Choosing a rule asks first, always: what goes now (even nothing), or
    /// that a folder could not be counted; the rule changes only on yes, and
    /// a count answered after a cancel changes nothing.
    func testTheAudioRuleChangesOnlyOnceTheQuestionIsAnswered() async throws {
        let rule = Rule()
        let due = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let queue = ruledQueue(rule)

        queue.askAudioRetention(days: 30)
        try await until { queue.audioQuestion != nil }
        let question = try XCTUnwrap(queue.audioQuestion)
        XCTAssertEqual(question.candidates.map(\.folder.lastPathComponent), [due.lastPathComponent])
        XCTAssertTrue(question.complete)
        XCTAssertEqual(rule.days, 0, "the rule changed before the answer")
        queue.answerAudioQuestion(question, accepted: false)
        XCTAssertEqual(rule.days, 0)

        queue.askAudioRetention(days: 30)
        queue.cancelAudioQuestion()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(queue.audioQuestion, "a count answered after the cancel asked again")
        XCTAssertEqual(rule.days, 0)

        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let nothing = ruledQueue(Rule(), localRoot: empty)
        nothing.askAudioRetention(days: 30)
        try await until { nothing.audioQuestion != nil }
        XCTAssertEqual(nothing.audioQuestion?.candidates, [], "no question when nothing goes now")
        XCTAssertEqual(nothing.audioQuestion?.complete, true)

        let away = ruledQueue(Rule(), localRoot: empty, destinations: { [root] in
            .init(meetings: root!.appendingPathComponent("Away", isDirectory: true))
        })
        away.askAudioRetention(days: 30)
        try await until { away.audioQuestion != nil }
        XCTAssertEqual(away.audioQuestion?.complete, false, "a folder not counted passed for counted")

        XCTAssertEqual(tracks(of: due), ["system.m4a", "microphone.m4a"])
        queue.askAudioRetention(days: 30)
        try await until { queue.audioQuestion != nil }
        queue.answerAudioQuestion(try XCTUnwrap(queue.audioQuestion), accepted: true)
        XCTAssertEqual(rule.days, 30)
        try await until { self.tracks(of: due).isEmpty }
        XCTAssertTrue(exists(due.appendingPathComponent("transcript.md")))
    }

    /// The first pass after a yes takes only what the question showed: a
    /// meeting that became due meanwhile waits for a later pass.
    func testTheFirstPassTakesOnlyWhatTheQuestionShowed() async throws {
        let rule = Rule()
        let shown = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let later = try RetentionFixture.meeting("2026-09-02 10-00-00 Meeting", in: local, ended: longAgo)
        try MeetingMarks.write(.init(starred: true), in: later, expecting: FolderIdentity.of(later))
        let queue = ruledQueue(rule)

        queue.askAudioRetention(days: 30)
        try await until { queue.audioQuestion != nil }
        let question = try XCTUnwrap(queue.audioQuestion)
        try MeetingMarks.write(.init(starred: false), in: later, expecting: FolderIdentity.of(later))
        queue.answerAudioQuestion(question, accepted: true)
        try await until { self.tracks(of: shown).isEmpty }
        try await until { queue.activeJob == nil && queue.pending.isEmpty }

        XCTAssertEqual(tracks(of: later), ["system.m4a", "microphone.m4a"], "the first pass took more than the question showed")
    }

    /// The rule's generation is checked inside the last call, after its last
    /// read of the disk: held right at that read, the rule set to keep, to
    /// 90 days, or the meetings folder changed — nothing is deleted. Between
    /// two files, the second stays. A pass that began under another rule
    /// queues nothing.
    func testAChangedRuleStopsTheDeletionAtItsLastCheck() async throws {
        let changes: [(String, (Rule) -> Void)] = [
            ("keep", { $0.set(0) }), ("90 days", { $0.set(90) }), ("another meetings folder", { $0.generation += 1 }),
        ]
        for (index, (name, change)) in changes.enumerated() {
            for heldAt in [1, 2] {
                let rule = Rule()
                rule.set(30)
                let own = root.appendingPathComponent("Local \(index) \(heldAt)", isDirectory: true)
                let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: own, ended: longAgo)
                let latch = Latch()
                let checks = Counter()
                let removed = Counter()
                var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
                let remove = removal.remove
                removal.remove = { url in
                    _ = removed.next()
                    try remove(url)
                }
                removal.beforeCheck = { _ in if checks.next() == heldAt { latch.wait() } }
                let queue = ruledQueue(rule, removal: removal, localRoot: own)

                queue.pruneAudio()
                try await until { latch.wasReached }
                change(rule)
                latch.release()
                try await until { queue.activeJob == nil && queue.pending.isEmpty }

                XCTAssertEqual(removed.value, heldAt - 1, "\(name), held at file \(heldAt): deleted under a rule no longer wanted")
                XCTAssertEqual(tracks(of: meeting).count, 3 - heldAt, "\(name), held at file \(heldAt)")
            }
        }

        let rule = Rule()
        rule.set(30)
        let late = try RetentionFixture.meeting("2026-09-09 10-00-00 Meeting", in: local, ended: longAgo)
        let queue = ruledQueue(rule)
        var jobs = 0
        let watch = queue.$activeJob.compactMap { $0 }.sink { _ in jobs += 1 }
        defer { watch.cancel() }
        queue.pruneAudio()
        rule.set(30)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(jobs, 0, "a pass that began under another generation queued a job")
        XCTAssertEqual(tracks(of: late).count, 2)
    }

    /// Every file is admitted again, from the disk, right before it goes:
    /// with the first file's deletion held, a transcript edited, the
    /// recording marked with a warning, or the second file replaced — the
    /// second stays.
    func testEveryFileIsAdmittedAgainRightBeforeItGoes() async throws {
        let changes: [(String, (URL) throws -> Void)] = [
            ("transcript edited", { try Data("другой текст".utf8).write(to: $0.appendingPathComponent("transcript.md")) }),
            ("recording with a warning", { try RetentionFixture.metadata(state: "suspect").write(to: $0.appendingPathComponent("metadata.json")) }),
            ("second file replaced", { folder in
                try FileManager.default.removeItem(at: folder.appendingPathComponent("microphone.m4a"))
                try Data(repeating: 2, count: 1_000).write(to: folder.appendingPathComponent("microphone.m4a"))
            }),
        ]
        for (index, (name, change)) in changes.enumerated() {
            let rule = Rule()
            rule.set(30)
            let own = root.appendingPathComponent("Local \(index)", isDirectory: true)
            let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: own, ended: longAgo)
            let latch = Latch()
            let removed = Counter()
            let removal = MeetingStorage.Removal(
                trash: { _ in XCTFail("the rule put audio in the Trash") },
                remove: { url in
                    if removed.next() == 1 { latch.wait() }
                    try FileManager.default.removeItem(at: url)
                }
            )
            let queue = ruledQueue(rule, removal: removal, localRoot: own)

            queue.pruneAudio()
            try await until { latch.wasReached }
            try change(meeting)
            latch.release()
            try await until { queue.activeJob == nil && queue.pending.isEmpty }

            XCTAssertEqual(removed.value, 1, "\(name): the second file went")
            XCTAssertTrue(exists(meeting.appendingPathComponent("microphone.m4a")), name)
            for kept in ["transcript.md", "metadata.json"] + ((try? FileManager.default.contentsOfDirectory(atPath: meeting.path)) ?? [])
                .filter({ $0.hasPrefix(MeetingAttempt.namePrefix) }) {
                XCTAssertTrue(exists(meeting.appendingPathComponent(kept)), "\(name): \(kept)")
            }
        }
    }

    /// The last check is the call's own: held right at its read of the
    /// second file, that file replaced by another of the same name — the
    /// other file stays.
    func testTheLastCallChecksItsOwnFile() async throws {
        let rule = Rule()
        rule.set(30)
        let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let latch = Latch()
        let checks = Counter()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        removal.beforeCheck = { _ in if checks.next() == 2 { latch.wait() } }
        let queue = ruledQueue(rule, removal: removal)

        queue.pruneAudio()
        try await until { latch.wasReached }
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("microphone.m4a"))
        try Data(repeating: 2, count: 1_000).write(to: meeting.appendingPathComponent("microphone.m4a"))
        latch.release()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }

        XCTAssertEqual(tracks(of: meeting), ["microphone.m4a"], "the file put in place went")
    }

    /// While a star is being written, the rule leaves the meeting this time;
    /// while the rule deletes, the star is refused.
    func testOldAudioAndMarksExcludeEachOther() async throws {
        settings.meetingsFolderPath = disk.path
        let rule = Rule()
        rule.set(30)
        let there = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: disk, ended: longAgo)
        let latch = Latch()
        var removal = MeetingStorage.Removal.confined(to: [root], trash: trashFolder)
        removal.beforeCheck = { _ in latch.wait() }
        let gate = DiskGate()
        let queue = ruledQueue(rule, removal: removal, destinations: { [settings] in settings!.meetingDestinations })
        let library = makeLibrary(queue: queue, reader: gate.reader)
        library.windowOpened()
        try await until { library.chosen?.fresh == true }

        gate.holdWrites(there)
        library.rename(try XCTUnwrap(library.meeting(at: there)), to: "Планёрка")
        try await until { gate.writes(of: there) == 1 }
        latch.release()
        queue.pruneAudio()
        try await Task.sleep(for: .milliseconds(300))
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(tracks(of: there).count, 2, "deleted while its name was being written")
        gate.releaseWrites(there)
        try await until { library.pendingMarks.isEmpty }

        let held = Latch()
        removal.beforeCheck = { _ in held.wait() }
        let next = ruledQueue(rule, removal: removal, destinations: { [settings] in settings!.meetingDestinations })
        let other = makeLibrary(queue: next)
        other.windowOpened()
        try await until { other.chosen?.fresh == true }
        next.pruneAudio()
        try await until { held.wasReached }
        XCTAssertNotNil(other.markRefusal(for: try XCTUnwrap(other.meeting(at: there))), "a star allowed while its audio goes")
        held.release()
        try await until { next.activeJob == nil && next.pending.isEmpty }
    }

    /// The rule is a step of the queue's job, after the job's own
    /// transcription, and looks again then: queued as due, the meeting is
    /// transcribed anew first, finds no speech, and its last attempt is no
    /// longer complete — the audio stays.
    func testOldAudioWaitsForATranscriptionAndLooksAgain() async throws {
        let rule = Rule()
        rule.set(30)
        let busy = try seed("2026-09-01 09-00-00 Meeting", in: local, metadata: done)
        let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let door = Door()
        let queue = ruledQueue(rule, door: door)
        queue.enqueue(busy)
        try await until { queue.isTranscribing }
        queue.pruneAudio()
        try await until { queue.pending.contains { $0.removesAudio != nil } }
        queue.enqueue(meeting)
        XCTAssertEqual(queue.pending.filter { $0.folder.lastPathComponent == meeting.lastPathComponent }.count, 1)
        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(tracks(of: meeting).count, 2, "deleted after a transcription that was not complete")
    }

    /// A meeting fully transcribed long ago, with audio a transcription can
    /// read again.
    private func speakingRetentionMeeting(_ name: String) throws -> URL {
        let folder = try seed(name, in: local, metadata: doneCAF, tracks: [])
        for track in ["system.caf", "microphone.caf"] {
            try SavingMeetingCapture.writeSilence(to: folder.appendingPathComponent(track))
        }
        try Data(RetentionFixture.text.utf8).write(to: folder.appendingPathComponent("transcript.md"))
        try RetentionFixture.write(RetentionFixture.complete(number: 1, ended: longAgo), in: folder)
        return folder
    }

    private func audioFiles(of folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
            $0.hasSuffix(".m4a") || $0.hasSuffix(".caf")
        })
    }

    /// Two transcriptions of one meeting asked for with two choices, the
    /// rule's pass queued before both or between them: each transcription
    /// finds the audio, and the audio goes only after the last.
    func testOldAudioWaitsForEveryTranscriptionAskedForTheMeeting() async throws {
        for passBetween in [false, true] {
            let rule = Rule()
            rule.set(30)
            let day = passBetween ? "02" : "01"
            let busy = try seed("2026-09-\(day) 09-00-00 Meeting", in: local, metadata: done)
            let meeting = try speakingRetentionMeeting("2026-09-\(day) 10-00-00 Meeting")
            let door = Door()
            let queue = ruledQueue(rule, door: door, speaks: true)
            queue.enqueue(busy)
            try await until { queue.isTranscribing }
            queue.enqueue(meeting, choice: SettingsSnapshot.Choice(engine: .whisper, language: "ru"))
            if passBetween {
                queue.pruneAudio()
                try await until { queue.pending.contains { $0.removesAudio != nil } }
            }
            queue.enqueue(meeting, choice: SettingsSnapshot.Choice(engine: .whisper, language: "en"))
            if !passBetween {
                queue.pruneAudio()
                try await until { queue.pending.contains { $0.removesAudio != nil } }
            }
            XCTAssertEqual(queue.pending.filter { $0.transcribe && $0.folder.lastPathComponent == meeting.lastPathComponent }.count, 2)

            door.unlock()
            try await until(within: .seconds(30)) { queue.activeJob == nil && queue.pending.isEmpty }
            let results = try MeetingAttempt.entries(in: meeting).compactMap(\.attempt).map(\.result)
            XCTAssertEqual(results, [.complete, .complete, .complete],
                           "pass \(passBetween ? "between" : "after"): a transcription asked for found the audio gone")
            XCTAssertEqual(audioFiles(of: meeting), [], "the audio stayed after the last transcription")
        }
    }

    /// A transcription waiting for a folder not told yet may be this very
    /// meeting: the step goes after it, and, as that folder is another,
    /// the audio is kept this time.
    func testOldAudioIsKeptWhileATranscriptionWaitsForAFolderNotToldYet() async throws {
        let rule = Rule()
        rule.set(30)
        let busy = try seed("2026-09-01 09-00-00 Meeting", in: local, metadata: done)
        let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let door = Door()
        let queue = ruledQueue(rule, door: door)
        queue.enqueue(busy)
        try await until { queue.isTranscribing }
        queue.pruneAudio()
        try await until { queue.pending.contains { $0.removesAudio != nil } }
        // Nothing there, so it is never told.
        queue.enqueue(root.appendingPathComponent("Elsewhere/2026-09-03 10-00-00 Meeting", isDirectory: true))
        XCTAssertNotNil(queue.untoldTranscription)

        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(tracks(of: meeting).count, 2, "deleted while a transcription waited for a folder not told yet")
    }

    /// A yes takes the meetings the question counted, wherever they are by
    /// then, and not another folder put at one's address meanwhile.
    func testTheFirstPassTakesTheMeetingsAgreedToNotAFolderPutInTheirPlace() async throws {
        let rule = Rule()
        let address = "2026-09-01 10-00-00 Meeting"
        let agreed = try RetentionFixture.meeting(address, in: local, ended: longAgo)
        let queue = ruledQueue(rule)
        queue.askAudioRetention(days: 30)
        try await until { queue.audioQuestion != nil }
        let question = try XCTUnwrap(queue.audioQuestion)

        let moved = local.appendingPathComponent("2026-09-05 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.moveItem(at: agreed, to: moved)
        let other = try RetentionFixture.meeting(address, in: local, ended: longAgo)
        queue.answerAudioQuestion(question, accepted: true)
        try await until { self.tracks(of: moved).isEmpty }
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(tracks(of: other), ["system.m4a", "microphone.m4a"], "the first pass took a folder put in the agreed one's place")
    }

    /// Queued for the meeting it counted, the step leaves alone another
    /// folder put at the meeting's address before the job runs.
    func testAFolderPutInAMeetingsPlaceAfterThePassKeepsItsAudio() async throws {
        let rule = Rule()
        rule.set(30)
        let address = "2026-09-01 10-00-00 Meeting"
        let busy = try seed("2026-09-01 09-00-00 Meeting", in: local, metadata: done)
        let counted = try RetentionFixture.meeting(address, in: local, ended: longAgo)
        let door = Door()
        let queue = ruledQueue(rule, door: door)
        queue.enqueue(busy)
        try await until { queue.isTranscribing }
        queue.pruneAudio()
        try await until { queue.pending.contains { $0.removesAudio != nil } }
        try FileManager.default.moveItem(at: counted, to: root.appendingPathComponent("Aside", isDirectory: true))
        let other = try RetentionFixture.meeting(address, in: local, ended: longAgo)

        door.unlock()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(tracks(of: other), ["system.m4a", "microphone.m4a"], "the step took a folder put in the counted one's place")
    }

    /// A count that does not answer at once, for a test to change things under it.
    private final class CountGate: @unchecked Sendable {
        private let lock = NSLock()
        private let held = DispatchSemaphore(value: 0)
        private var count = 0
        var calls: Int { lock.withLock { count } }
        /// The first call waits for `release`.
        func enter() {
            let first = lock.withLock { count += 1; return count == 1 }
            if first { held.wait() }
        }
        func release() { held.signal() }
    }

    /// A count made while the meetings folder changed is not asked about: it
    /// is counted again. A yes after such a change sets nothing and asks again.
    func testACountUnderAnotherMeetingsFolderIsCountedAgain() async throws {
        let rule = Rule()
        let due = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let queue = ruledQueue(rule)
        let gate = CountGate()
        queue.countAudio = { root, local, days, now in
            gate.enter()
            return MeetingTranscriptionQueue.due(in: root, local: local, days: days, now: now)
        }
        queue.askAudioRetention(days: 30)
        try await until { gate.calls == 1 }
        rule.generation += 1
        gate.release()
        try await until { queue.audioQuestion != nil }
        XCTAssertEqual(gate.calls, 2, "a count made under another meetings folder was asked about")
        let question = try XCTUnwrap(queue.audioQuestion)
        XCTAssertEqual(question.generation, rule.generation)
        XCTAssertEqual(question.candidates.map(\.folder.lastPathComponent), [due.lastPathComponent])

        rule.generation += 1
        queue.answerAudioQuestion(question, accepted: true)
        XCTAssertEqual(rule.days, 0, "the rule was set from a count under another meetings folder")
        try await until { queue.audioQuestion != nil }
        XCTAssertEqual(gate.calls, 3)
        XCTAssertEqual(tracks(of: due).count, 2)
    }

    /// Only a count that read everything can say nothing goes: a root that
    /// can't be listed, a meeting that can't be read, a root that does not
    /// answer in time each leave it incomplete.
    func testACountThatCouldNotReadEverythingIsNotANothing() async throws {
        let closed = root.appendingPathComponent("Closed", isDirectory: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        let mixed = root.appendingPathComponent("Mixed", isDirectory: true)
        let kept = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: mixed, ended: Date())
        let unreadable = try RetentionFixture.meeting("2026-09-01 11-00-00 Meeting", in: mixed, ended: longAgo)
        for folder in [closed, unreadable] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        }
        defer {
            for folder in [closed, unreadable] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
        }
        if case .unknown = MeetingStorage.audioRetention(of: unreadable) {} else {
            XCTFail("a meeting that can't be read passed for one that keeps its audio: \(MeetingStorage.audioRetention(of: unreadable))")
        }
        XCTAssertNil(MeetingStorage.audioRetention(of: kept).due(days: 30, now: Date()))

        let slow = root.appendingPathComponent("Slow", isDirectory: true)
        try FileManager.default.createDirectory(at: slow, withIntermediateDirectories: true)
        let late = ruledQueue(Rule(), localRoot: slow)
        late.countAudio = { root, local, days, now in
            Thread.sleep(forTimeInterval: 4)
            return MeetingTranscriptionQueue.due(in: root, local: local, days: days, now: now)
        }
        for (name, queue) in [("closed root", ruledQueue(Rule(), localRoot: closed)),
                              ("unreadable meeting", ruledQueue(Rule(), localRoot: mixed)),
                              ("no answer in time", late)] {
            queue.askAudioRetention(days: 30)
            try await until { queue.audioQuestion != nil }
            XCTAssertEqual(queue.audioQuestion?.candidates, [], name)
            XCTAssertEqual(queue.audioQuestion?.complete, false, "\(name): an incomplete count passed for nothing to delete")
        }
    }

    /// A local root whose parent can't be passed is not a root that isn't
    /// there: its count is incomplete, and the window and Storage say it
    /// can't be read.
    func testARootBehindAClosedParentIsNotAnEmptyOne() async throws {
        let parent = root.appendingPathComponent("ClosedParent", isDirectory: true)
        let meetings = parent.appendingPathComponent("Meetings", isDirectory: true)
        try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: meetings, ended: longAgo)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        XCTAssertThrowsError(try MeetingStorage.meetingFolders(in: meetings), "a root behind a closed parent passed for none")
        XCTAssertEqual(try MeetingStorage.meetingFolders(in: root.appendingPathComponent("Nowhere/Meetings")), [])
        let queue = ruledQueue(Rule(), localRoot: meetings)
        queue.askAudioRetention(days: 30)
        try await until { queue.audioQuestion != nil }
        XCTAssertEqual(queue.audioQuestion?.complete, false, "a root behind a closed parent was counted as nothing to delete")
    }

    /// As the app starts, the rule's pass runs, when there is a rule.
    func testTheStartPassTakesDueAudioOnlyUnderARule() async throws {
        let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: longAgo)
        let keeping = ruledQueue(Rule())
        keeping.activate()
        try await Task.sleep(for: .milliseconds(300))
        try await until { keeping.activeJob == nil && keeping.pending.isEmpty }
        XCTAssertEqual(tracks(of: meeting).count, 2)

        let rule = Rule()
        rule.set(30)
        ruledQueue(rule).activate()
        try await until { self.tracks(of: meeting).isEmpty }
    }

    /// The window and Storage tell the audio apart alike: all there, part
    /// gone, none left, cannot be told.
    func testTheWindowAndStorageTellTheAudioAlike() async throws {
        let full = try seed("2026-09-01 10-00-00 Meeting", in: local, metadata: done)
        let part = try seed("2026-09-01 11-00-00 Meeting", in: local, metadata: done, tracks: ["system.m4a"])
        let none = try seed("2026-09-01 12-00-00 Meeting", in: local, metadata: done, tracks: [])
        let unknown = try seed("2026-09-01 13-00-00 Meeting", in: local, metadata: done, tracks: ["microphone.m4a"])
        try FileManager.default.createSymbolicLink(
            at: unknown.appendingPathComponent("system.m4a"), withDestinationURL: full.appendingPathComponent("system.m4a")
        )
        let library = try await openLibrary()
        let snapshot = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil, dictationsRoot: root.appendingPathComponent("Dictations"), meetingsRoot: local
        )

        let rows = [full, part, none, unknown].compactMap { library.meeting(at: $0) }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(snapshot.meetingAudio.bytes, rows.compactMap(\.audio.bytes).reduce(0, +))
        XCTAssertEqual(snapshot.meetingAudio.bytes, 64 * 3)
        XCTAssertEqual(snapshot.meetingAudio.without, rows.filter { $0.audio.files?.isEmpty == true }.count)
        XCTAssertEqual(snapshot.meetingAudio.without, 1)
        XCTAssertEqual(snapshot.meetingAudio.unknown, rows.filter { $0.audio.files == nil }.count)
        XCTAssertEqual(snapshot.meetingAudio.unknown, 1)
        XCTAssertEqual(MeetingText.audioTag(try XCTUnwrap(library.meeting(at: part))), String(localized: "Audio incomplete"))
        XCTAssertEqual(MeetingText.audioTag(try XCTUnwrap(library.meeting(at: none))), String(localized: "No audio"))
    }

    // MARK: - Labels

    func testVersionLabels() {
        var attempt = MeetingAttempt(number: 1, startedAt: Date(timeIntervalSince1970: 1_760_000_000))
        attempt.engines = ["parakeet"]
        attempt.languages = ["auto"]
        attempt.endedAt = Date(timeIntervalSince1970: 1_760_000_100)
        let recorded = MeetingLibrary.Version(name: "transcript 2.md", number: 2, modified: nil, attempt: attempt)
        let old = MeetingLibrary.Version(name: "transcript 2.md", number: 2, modified: Date(timeIntervalSince1970: 1_760_000_000), attempt: nil)

        XCTAssertTrue(MeetingLibrary.label(of: recorded).hasPrefix("Parakeet · Auto · "), MeetingLibrary.label(of: recorded))
        XCTAssertTrue(MeetingLibrary.label(of: old).hasPrefix("Transcript 2 · "), MeetingLibrary.label(of: old))
    }

    func testSourceNames() {
        var asked: [String] = []
        let library = makeLibrary(applicationName: { asked.append($0); return "Arc" })

        XCTAssertNil(library.sourceName(of: nil))
        XCTAssertEqual(library.sourceName(of: "manual"), "Manual")
        XCTAssertEqual(library.sourceName(of: "pid:42"), "Unknown process")
        XCTAssertEqual(library.sourceName(of: "company.thebrowser.browser.helper"), "Arc")
        XCTAssertEqual(library.sourceName(of: "company.thebrowser.browser.helper"), "Arc")
        XCTAssertEqual(asked, ["company.thebrowser.browser.helper"], "the name is looked up once")
        XCTAssertEqual(
            MeetingsSettingsView.outermostApplication(URL(fileURLWithPath:
                "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper.app")).path,
            "/Applications/Arc.app"
        )
    }

    func testGroupsAreTodayYesterdayThisWeekThenMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z"))  // a Thursday
        func meeting(_ date: String) throws -> MeetingLibrary.Meeting {
            let started = try XCTUnwrap(ISO8601DateFormatter().date(from: date))
            return MeetingLibrary.Meeting(
                directory: URL(fileURLWithPath: "/m/\(date)"), place: .local, startedAt: started, duration: nil,
                state: "done", issues: [], trigger: nil, bytes: nil, versions: [], lastAttempt: .none,
                otherFiles: [], hasTracks: true, readable: true
            )
        }
        let meetings = try [
            "2026-10-15T09:00:00Z", "2026-10-14T18:00:00Z", "2026-10-13T09:00:00Z",
            "2026-10-11T09:00:00Z", "2026-10-02T09:00:00Z", "2026-09-30T09:00:00Z",
        ].map(meeting)

        let groups = MeetingLibrary.groups(meetings, now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "This Week", "October 2026", "September 2026"])
        XCTAssertEqual(groups.map(\.meetings.count), [1, 1, 1, 2, 1])
    }

    // MARK: - Reading a transcript

    func testTranscriptKeepsItsHeaderAndReadsHourTimecodes() {
        let raw = """
        # Meeting 15 October 2026 at 11:48

        Automatic transcript. Engine: Parakeet (parakeet). Language: auto.
        Pieces not recognized: 2.
        ⚠︎ Transcription broke off: others, 0:07, piece 2 of 3.

        ---

        [0:05] **Я:** Начнём.

        [59:59] **Others:** Ок.

        [1:02:03] **Собеседники:** Спустя час.

        """

        let transcript = MeetingTranscript.parse(raw)

        XCTAssertEqual(transcript.lines?.map(\.timecode), ["0:05", "59:59", "1:02:03"])
        XCTAssertEqual(transcript.lines?.map(\.speaker), ["Я", "Others", "Собеседники"])
        XCTAssertEqual(transcript.lines?.last?.text, "Спустя час.")
        XCTAssertTrue(transcript.header?.contains("Pieces not recognized: 2.") == true)
        XCTAssertTrue(transcript.header?.contains("broke off") == true)
    }

    func testTextNotInTheAppsFormIsShownAsItIs() {
        let manual = "Созвон с подрядчиком\n\nДенис: начнём\nИван: да\n"
        let mixed = "# Meeting\n\n---\n\n[0:05] **Me:** да\n\nдописано руками\n"

        for raw in [manual, mixed] {
            let transcript = MeetingTranscript.parse(raw)
            XCTAssertNil(transcript.lines)
            XCTAssertNil(transcript.header)
            XCTAssertEqual(transcript.raw, raw)
        }
    }

    // MARK: - Fixtures

    private var done: [String: Any] {
        [
            "startedAt": "2026-10-06T10:00:00Z", "endedAt": "2026-10-06T11:15:00Z", "sampleRate": 48_000,
            "state": "done", "trigger": "manual",
            "segments": [["index": 0, "system": "system.m4a", "mic": "microphone.m4a"]],
        ]
    }

    /// As a stop writes it, before compression: the tracks are CAF.
    private var doneCAF: [String: Any] {
        var metadata = done
        metadata["segments"] = [["index": 0, "system": "system.caf", "mic": "microphone.caf"]]
        return metadata
    }

    private func transcript(_ line: String) -> String {
        "# Meeting\n\nAutomatic transcript.\n\n---\n\n[0:05] **Me:** \(line)\n"
    }

    /// A meeting folder with its m4a tracks (no compression waits for them).
    @discardableResult
    private func seed(
        _ name: String,
        in root: URL,
        metadata: [String: Any]?,
        tracks: [String] = ["system.m4a", "microphone.m4a"],
        files: [String: String] = [:]
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

    private func makeRecorder(failsStop: Bool = false) -> MeetingRecorder {
        let recorder = MeetingRecorder(
            capture: LibraryCapture(failsStop: failsStop),
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

    /// A queue for the local root. `door`: the job waits at it before its
    /// speech detection. `speaks`: every track has one second of speech and
    /// the engine hears it; otherwise there is none.
    private func makeQueue(
        door: Door? = nil,
        speaks: Bool = false,
        engine: any WhisperEngineFactory = ConstantEngineFactory(),
        localRoot: URL? = nil,
        removal: MeetingStorage.Removal? = nil,
        destinations: @escaping @MainActor () -> MeetingTranscriptionQueue.Destinations = { .init() }
    ) -> MeetingTranscriptionQueue {
        let queue = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: engine),
                loadSpeechDetector: { _ in
                    try await door?.pass()
                    return { _ in speaks ? [0..<16_000] : [] }
                },
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
            removal: removal ?? .confined(to: [root], trash: trashFolder),
            destinations: destinations
        )
        keepAlive.append(queue)
        return queue
    }

    private func makeLibrary(
        recorder: MeetingRecorder? = nil,
        queue: MeetingTranscriptionQueue? = nil,
        reader: MeetingLibrary.Reader = .disk,
        localRoot: URL? = nil,
        applicationName: @escaping @MainActor (String) -> String = { $0 },
        saving: MeetingLibrary.Saving? = nil
    ) -> MeetingLibrary {
        let library = MeetingLibrary(
            recorder: recorder ?? makeRecorder(),
            queue: queue ?? makeQueue(),
            settings: settings,
            localRoot: localRoot ?? local,
            reader: reader,
            notRespondingAfter: .milliseconds(100),
            applicationName: applicationName,
            saving: saving ?? MeetingLibrary.Saving(destination: { _, _, _ in
                XCTFail("a save panel was asked for")
                return nil
            })
        )
        keepAlive.append(library)
        return library
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

private extension MeetingLibrary.RemovalLine.Outcome {
    var isRefused: Bool {
        if case .refused = self { true } else { false }
    }
}
