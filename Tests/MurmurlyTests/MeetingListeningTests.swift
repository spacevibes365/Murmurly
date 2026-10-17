import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
@testable import Murmurly

/// A clock the tracks of a test play on.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// The tracks a test deck opened: which are open now, what each was told,
/// and opens held until the test lets them go.
private final class DeckLog: @unchecked Sendable {
    private let lock = NSLock()
    private var openFiles: [String: Int] = [:]
    private var opens = 0
    private var events: [String] = []
    private var held = false
    private var tracks: [String: Weak] = [:]

    private final class Weak {
        weak var track: SilentTrack?
        init(_ track: SilentTrack) { self.track = track }
    }

    private var openedFiles: [URL] = []

    var open: Set<String> { lock.withLock { Set(openFiles.filter { $0.value > 0 }.keys) } }
    var openCount: Int { lock.withLock { opens } }
    /// How many tracks of this folder were ever opened.
    func opens(in folder: URL) -> Int {
        let path = folder.standardizedFileURL.path
        return lock.withLock { openedFiles.filter { $0.deletingLastPathComponent().standardizedFileURL.path == path }.count }
    }
    var log: [String] { lock.withLock { events } }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }
    private var heldNames: Set<String> = []
    private var waitingNames: Set<String> = []
    /// The open of this file waits, inside the deck, until released.
    func holdOpen(of name: String) { lock.withLock { _ = heldNames.insert(name) } }
    func releaseOpen(of name: String) { lock.withLock { _ = heldNames.remove(name) } }
    func isWaiting(_ name: String) -> Bool { lock.withLock { waitingNames.contains(name) } }
    func track(_ name: String) -> SilentTrack? { lock.withLock { tracks[name]?.track } }
    func add(_ event: String) { lock.withLock { events.append(event) } }
    func reset() { lock.withLock { events = [] } }

    func deck(clock: TestClock, duration: @escaping @Sendable (URL) -> TimeInterval = { _ in 120 }) -> MeetingPlayer.Deck {
        MeetingPlayer.Deck { [self] url in
            while lock.withLock({ held }) { Thread.sleep(forTimeInterval: 0.005) }
            let name = url.lastPathComponent
            lock.withLock { _ = waitingNames.insert(name) }
            while lock.withLock({ heldNames.contains(name) }) { Thread.sleep(forTimeInterval: 0.005) }
            lock.withLock { _ = waitingNames.remove(name) }
            let track = SilentTrack(
                duration: duration(url), clock: { clock.now }, log: { [self] in add("\(name) \($0)") },
                closed: { [self] in lock.withLock { openFiles[url.path, default: 1] -= 1 } }
            )
            lock.withLock {
                opens += 1
                openedFiles.append(url)
                openFiles[url.path, default: 0] += 1
                tracks[name] = Weak(track)
            }
            return track
        }
    }
}

/// Holds a meeting folder's transcript reads and counts them.
private final class TextGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var failing: Set<String> = []
    private var reads: [String] = []
    private var inFlight: [String: Int] = [:]
    private var most: [String: Int] = [:]

    private var holdingAll = false

    private func key(_ folder: URL) -> String { folder.resolvingSymlinksInPath().standardizedFileURL.path }
    func hold(_ folder: URL) { lock.withLock { _ = held.insert(key(folder)) } }
    func release(_ folder: URL) { lock.withLock { _ = held.remove(key(folder)) } }
    func holdAll() { lock.withLock { holdingAll = true } }
    private var heldLists: Set<String> = []
    private var heldWords: Set<String> = []
    /// Any transcript read with this word, held after it was read.
    func holdText(containing word: String) { lock.withLock { _ = heldWords.insert(word) } }
    func releaseText(containing word: String) { lock.withLock { _ = heldWords.remove(word) } }
    /// A folder's list read, held before it reads anything.
    func holdList(_ folder: URL) { lock.withLock { _ = heldLists.insert(key(folder)) } }
    func releaseList(_ folder: URL) { lock.withLock { _ = heldLists.remove(key(folder)) } }
    func releaseAll() { lock.withLock { holdingAll = false } }
    var textReads: Int { lock.withLock { reads.filter { !$0.hasPrefix("list ") }.count } }
    func fail(_ folder: URL) { lock.withLock { _ = failing.insert(key(folder)) } }
    func reads(of folder: URL) -> Int { lock.withLock { reads.filter { $0 == key(folder) }.count } }
    var log: [String] { lock.withLock { reads } }
    /// The most reads of one root's meetings at once.
    func mostAtOnce(in root: URL) -> Int { lock.withLock { most[key(root), default: 0] } }

    func record(_ event: String) { lock.withLock { reads.append(event) } }

    func reader(base: MeetingLibrary.Reader = .disk) -> MeetingLibrary.Reader {
        var reader = base
        let root = base.root
        reader.root = { [self] folder, place in
            record("list " + key(folder))
            while lock.withLock({ heldLists.contains(key(folder)) }) { Thread.sleep(forTimeInterval: 0.005) }
            return root(folder, place)
        }
        reader.text = { [self] file in
            let folder = key(file.deletingLastPathComponent())
            let parent = key(file.deletingLastPathComponent().deletingLastPathComponent())
            lock.withLock {
                reads.append(folder)
                inFlight[parent, default: 0] += 1
                most[parent] = max(most[parent, default: 0], inFlight[parent]!)
            }
            defer { lock.withLock { inFlight[parent, default: 1] -= 1 } }
            // Read first, then held: the answer is what the folder held then.
            let text = try String(contentsOf: file, encoding: .utf8)
            while lock.withLock({ held.contains(folder) || holdingAll || heldWords.contains(where: text.contains) }) {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if lock.withLock({ failing.contains(folder) }) { throw CocoaError(.fileReadNoPermission) }
            return text
        }
        return reader
    }
}

private actor ListeningCapture: MeetingCaptureBackend {
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

private actor QuietMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// A latch on any thread.
private final class Hold: @unchecked Sendable {
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

/// Listening to a meeting and searching all of them, at the seams: the
/// window's model, the player, the queue's operations, the recorder, the
/// dictation and the disk.
@MainActor
final class MeetingListeningTests: XCTestCase {
    private var root: URL!
    private var local: URL!
    private var disk: URL!
    private var settings: SettingsStore!
    private var keepAlive: [AnyObject] = []
    private let clock = TestClock()
    private let deckLog = DeckLog()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-listening-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - What plays

    /// The timeline is the tracks' own length by their frames, not the
    /// clock of the recording; the player opens them as AVFoundation does.
    func testTheTimelineIsTheTracksRealLength() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", tracks: [])
        try MeetingAudio.write([[Float](repeating: 0, count: 24_000)], to: meeting.appendingPathComponent("system.caf"))
        try MeetingAudio.write([[Float](repeating: 0, count: 36_000)], to: meeting.appendingPathComponent("microphone.caf"))
        try metadata(caf: true).write(to: meeting.appendingPathComponent("metadata.json"))
        let library = try await openLibrary(deck: .audioPlayers)
        library.select(meeting)
        try await until { library.player.state == .ready }
        XCTAssertEqual(library.player.duration, 0.75, accuracy: 0.01, "the timeline is not the tracks' frames")
        XCTAssertEqual(library.player.sources, [.microphone, .system])
    }

    /// Per track: the m4a a compression checked, else the CAF; never a
    /// killed compression's leftover; as `metadata.json` names them.
    func testPlaybackTakesTheCheckedM4aElseTheCAF() throws {
        let both = try seed("2026-10-06 10-00-00 Meeting", tracks: ["system.caf", "system.m4a", "microphone.caf", ".microphone.partial.m4a"])
        try metadata(caf: true).write(to: both.appendingPathComponent("metadata.json"))
        XCTAssertEqual(MeetingStorage.playback(in: both), .tracks([.system: "system.m4a", .microphone: "microphone.caf"]))
        let none = try seed("2026-10-06 11-00-00 Meeting", tracks: [])
        XCTAssertEqual(MeetingStorage.playback(in: none), .tracks([:]))
        let outside = try seed("2026-10-06 12-00-00 Meeting", tracks: [])
        try Data(#"{"state":"done","segments":[{"system":"../x.caf","mic":"microphone.m4a"}]}"#.utf8)
            .write(to: outside.appendingPathComponent("metadata.json"))
        guard case .unknown = MeetingStorage.playback(in: outside) else { return XCTFail("a track outside the folder was played") }
    }

    /// A test process plays nothing through AVFoundation, whatever its
    /// environment: a track AVFoundation opens is refused by the test guard.
    func testATestProcessPlaysNothing() throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", tracks: [])
        let track = meeting.appendingPathComponent("system.caf")
        try MeetingAudio.write([[Float](repeating: 0, count: 4_800)], to: track)
        XCTAssertNoThrow(try MeetingPlayer.Deck.audioPlayers.open(track), "the track itself can't be opened")
        XCTAssertThrowsError(try MeetingPlayer.Deck.live.open(track)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .featureUnsupported, "not the test process's refusal: \(error)")
            XCTAssertEqual(error.localizedDescription, String(localized: "Nothing is played in a test process."))
        }
    }

    /// One start for both tracks, at one moment; pause, seek, the 15
    /// seconds and the rate move both; muting turns one off and nothing is
    /// ever louder than recorded.
    func testBothTracksMoveTogether() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let library = try await openLibrary()
        library.select(meeting)
        try await until { library.player.state == .ready }
        let player = library.player
        let system = try XCTUnwrap(deckLog.track("system.m4a"))
        let microphone = try XCTUnwrap(deckLog.track("microphone.m4a"))

        player.play()
        XCTAssertEqual(player.state, .playing)
        let starts = deckLog.log.filter { $0.contains(" play ") }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(Set(starts.map { $0.components(separatedBy: " play ")[1] }).count, 1, "the tracks started at two moments: \(starts)")
        clock.advance(10)
        XCTAssertEqual(player.position, 9.95, accuracy: 0.01)

        player.skip(by: 15)
        XCTAssertEqual(system.currentTime, microphone.currentTime, accuracy: 0.001)
        XCTAssertEqual(player.position, 24.95, accuracy: 0.06)
        player.seek(to: 60)
        XCTAssertEqual(system.currentTime, 60, accuracy: 0.001)
        XCTAssertEqual(microphone.currentTime, 60, accuracy: 0.001)
        player.setRate(1.5)
        XCTAssertEqual([system.rate, microphone.rate], [1.5, 1.5])
        player.toggleMute(.microphone)
        XCTAssertEqual([system.volume, microphone.volume], [1, 0])
        player.toggleMute(.microphone)
        XCTAssertTrue([system.volume, microphone.volume].allSatisfy { $0 <= 1 })
        player.pause()
        XCTAssertFalse(system.isPlaying || microphone.isPlaying)
    }

    /// Without audio, or with audio that can't be told or opened, the
    /// player says why; with one track only, it plays that one.
    func testWithoutAudioThePlayerIsOffAndSaysWhy() async throws {
        let gone = try seed("2026-10-06 10-00-00 Meeting", tracks: [])
        let outside = try seed("2026-10-06 11-00-00 Meeting", tracks: [])
        try Data(#"{"state":"done","segments":[{"system":"../x.m4a","mic":"microphone.m4a"}]}"#.utf8)
            .write(to: outside.appendingPathComponent("metadata.json"))
        let half = try seed("2026-10-06 12-00-00 Meeting", tracks: ["system.m4a"])
        let library = try await openLibrary()

        library.select(gone)
        guard case .unavailable(let reason) = library.player.state else { return XCTFail("\(library.player.state)") }
        XCTAssertEqual(reason, String(localized: "The audio was deleted; the transcripts stay."))
        library.select(outside)
        guard case .unavailable(let told) = library.player.state else { return XCTFail("\(library.player.state)") }
        XCTAssertTrue(told.hasPrefix(String(localized: "The audio can’t be told: \("")")), told)
        library.select(half)
        try await until { library.player.state == .ready }
        XCTAssertEqual(library.player.sources, [.system])

        let refused = try await openLibrary(deck: .refusing)
        refused.select(half)
        try await until { if case .unavailable = refused.player.state { true } else { false } }
    }

    // MARK: - The recording comes first

    /// A meeting recording starting stops the sound in that very turn, and
    /// while it records or saves, a start is refused with the reason.
    func testARecordingStopsThePlayerAndKeepsItOff() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let recorder = makeRecorder()
        let library = try await openLibrary(recorder: recorder)
        library.select(meeting)
        try await until { library.player.state == .ready }
        library.player.play()

        recorder.toggle()
        XCTAssertNotEqual(recorder.state, .idle)
        XCTAssertEqual(library.player.state, .ready, "the sound went on as the recording started")
        XCTAssertFalse(deckLog.track("system.m4a")?.isPlaying ?? true)
        library.player.play()
        XCTAssertEqual(library.player.state, .ready)
        XCTAssertEqual(library.player.refusal, MeetingLibrary.recordingRefusal)

        try await until { recorder.state == .recording }
        recorder.toggle()
        try await until { !recorder.isBusy }
        library.select(meeting)
        library.player.play()
        XCTAssertEqual(library.player.state, .playing)
    }

    /// Another section of the window is no card shown: the sound stops and
    /// the meeting's files close, Play is refused, and a load on its way
    /// opens no more and plays nothing. Meetings and Starred show the same
    /// card: the sound goes on between them. Back on the meetings, the
    /// meeting is loaded again, paused.
    func testLeavingTheMeetingsStopsTheSound() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        let library = try await openLibrary()
        library.select(meeting)
        try await until { library.player.state == .ready }
        library.player.play()
        XCTAssertEqual(library.player.state, .playing)

        library.section = .starred
        XCTAssertEqual(library.player.state, .playing, "Starred stopped the sound of the same card")
        library.section = .dictations
        XCTAssertNotEqual(library.player.state, .playing, "the sound went on with the card out of sight")
        XCTAssertFalse(deckLog.open.contains { $0.hasPrefix(meeting.path) }, "the meeting's files stayed open")
        library.player.play()
        XCTAssertNotEqual(library.player.state, .playing, "Play started with the card out of sight")

        library.section = .meetings
        try await until { library.player.state == .ready }
        XCTAssertEqual(library.player.folder, MeetingLibrary.canonical(meeting))

        // A load on its way as the window leaves the meetings.
        library.select(nil as URL?)
        deckLog.holdOpen(of: "microphone.m4a")
        let opensBefore = deckLog.opens(in: meeting)
        let logBefore = deckLog.log.count
        library.select(meeting)
        try await until { self.deckLog.isWaiting("microphone.m4a") }
        library.section = .files
        deckLog.releaseOpen(of: "microphone.m4a")
        try await until { !library.player.isOpening([identity]) }
        XCTAssertEqual(deckLog.opens(in: meeting) - opensBefore, 1, "the load let go of opened its next track")
        XCTAssertFalse(deckLog.open.contains { $0.hasPrefix(meeting.path) }, "the late load kept its files open")
        XCTAssertFalse(deckLog.log.dropFirst(logBefore).contains { $0.contains(" play ") }, "the late load played")
    }

    /// A dictation starting pauses the player where it is, and holds a
    /// start while it lasts: the microphone would hear it.
    func testADictationPausesThePlayer() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let dictation = DictationCoordinator(mic: QuietMic(), indicator: RecordingIndicator(renderingEnabled: false))
        keepAlive.append(dictation)
        let library = try await openLibrary(dictation: dictation)
        library.select(meeting)
        try await until { library.player.state == .ready }
        library.player.play()
        clock.advance(5)

        dictation.beginCaptureForTesting()
        XCTAssertEqual(library.player.state, .ready, "the sound went on as the dictation started")
        XCTAssertEqual(library.player.position, 4.95, accuracy: 0.01, "the pause lost the place")
        library.player.play()
        XCTAssertEqual(library.player.state, .ready)
        XCTAssertEqual(library.player.refusal, MeetingLibrary.dictationRefusal)
    }

    // MARK: - Operations close the files first

    /// Before the queue takes a move, the player's files of both its source
    /// (opened through a link in a parent path) and its destination (a
    /// meeting of the same name in the meetings folder) are closed; the
    /// mover finds nothing open, and no file opens while the move goes.
    func testAMoveClosesTheFilesOfItsSourceAndDestinationFirst() async throws {
        settings.meetingsFolderPath = disk.path
        let name = "2026-10-06 10-00-00 Meeting"
        let meeting = try seed(name)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: local)
        let there = try seed(name, in: disk)
        let hold = Hold()
        let seen = DeckLog()
        let queue = makeQueue(destinations: { [settings] in settings!.meetingDestinations })
        let log = deckLog
        queue.mover = { folder, target, localRoot in
            seen.add("open at the move: \(log.open.count)")
            hold.wait()
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        // The source, opened through a link in a parent path: taken by its
        // own address, it is the same folder.
        let source = try await openLibrary(queue: queue)
        let throughLink = alias.appendingPathComponent(name, isDirectory: true)
        source.open(throughLink)
        try await until { source.player.state == .ready }
        XCTAssertEqual(source.meeting(at: throughLink)?.identity, FolderIdentity.of(meeting))
        let taken = queue.beginOperations(.moving, on: [try XCTUnwrap(MeetingStorage.address(of: meeting))])
        XCTAssertTrue(deckLog.open.isEmpty, "the source's files stayed open through a link in a parent path")
        XCTAssertEqual(source.player.state, .unavailable(MeetingTranscriptionQueue.describe(.moving)))
        if let taken { queue.endOperations(taken) }
        source.windowClosed()

        // The destination: a meeting of the same name in the meetings folder.
        let library = try await openLibrary(queue: queue)
        library.open(there)
        try await until { library.player.state == .ready }
        XCTAssertFalse(deckLog.open.isEmpty)
        queue.enqueue(meeting, transcribe: false)
        try await until { hold.wasReached }
        XCTAssertEqual(seen.log, ["open at the move: 0"], "the destination's files were open as the move began")
        XCTAssertEqual(library.player.state, .unavailable(MeetingTranscriptionQueue.describe(.moving)))
        library.select(nil as URL?)
        library.open(there)
        XCTAssertEqual(library.player.state, .unavailable(MeetingTranscriptionQueue.describe(.moving)))
        XCTAssertTrue(deckLog.open.isEmpty, "a file opened while the move went")
        hold.release()
        try await until { queue.activeJob == nil && queue.pending.isEmpty }
    }

    /// No operation takes a folder while its audio is being opened off the
    /// main actor, where nothing can close it: held inside the open of the
    /// second track, a move (of the meeting, or onto it), the rule's
    /// deletion of old audio and a deletion by hand all leave the folder
    /// alone; once the open is over, each finds every file closed as it
    /// reaches the disk.
    func testNoOperationTakesAFolderWhileItsAudioIsBeingOpened() async throws {
        settings.meetingsFolderPath = disk.path
        let seen = DeckLog()
        let log = deckLog
        var removal = MeetingStorage.Removal.confined(to: [root], trash: root.appendingPathComponent("Trash", isDirectory: true))
        removal.beforeCheck = { _ in seen.add("disk, open: \(log.open.count)") }
        let queue = makeQueue(removal: removal, destinations: { [settings] in settings!.meetingDestinations })
        queue.mover = { folder, target, localRoot in
            seen.add("disk, open: \(log.open.count)")
            return try MeetingStorage.move(folder, into: target, localRoot: localRoot)
        }
        queue.audioRetention = { (30, 1) }
        let library = try await openLibrary(queue: queue)

        func holdingAnOpen(of shown: URL, _ name: String, operation: () async throws -> Void) async throws {
            try await openAgain(library)
            deckLog.holdOpen(of: "system.m4a")
            library.select(nil as URL?)
            library.open(shown)
            try await until { self.deckLog.isWaiting("system.m4a") }
            XCTAssertEqual(deckLog.open.count, 1, "\(name): the first track is not open yet")
            try await operation()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(seen.log, [], "\(name): the disk was reached while a track was being opened")
            XCTAssertTrue(queue.operations.isEmpty, "\(name): an operation took the folder while its audio was opened")
            deckLog.releaseOpen(of: "system.m4a")
        }

        // A move of the meeting on the card: it waits, then goes.
        let source = try seed("2026-10-06 10-00-00 Meeting")
        try await holdingAnOpen(of: source, "the move's source") { queue.enqueue(source, transcribe: false) }
        try await until { !seen.log.isEmpty && queue.activeJob == nil }
        XCTAssertEqual(seen.log, ["disk, open: 0"], "the move's source")

        // A move onto the meeting on the card, of the same name.
        seen.reset()
        let name = "2026-10-06 11-00-00 Meeting"
        let there = try seed(name, in: disk)
        let local2 = try seed(name)
        try await holdingAnOpen(of: there, "the move's destination") { queue.enqueue(local2, transcribe: false) }
        try await until { !seen.log.isEmpty && queue.activeJob == nil }
        XCTAssertEqual(seen.log, ["disk, open: 0"], "the move's destination")

        // Old audio: kept while the open goes, deleted by the next pass.
        seen.reset()
        settings.meetingsFolderPath = nil
        let old = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: Date().addingTimeInterval(-40 * 86_400))
        try await holdingAnOpen(of: old, "old audio") {
            queue.pruneAudio()
            try await until { queue.activeJob == nil && queue.pending.isEmpty }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("system.m4a").path))
        try await until { library.player.state == .ready }
        queue.pruneAudio()
        // The whole step: each file is checked on its own, and a late check
        // would land in the next case's log.
        try await until {
            ["system.m4a", "microphone.m4a"].allSatisfy { !FileManager.default.fileExists(atPath: old.appendingPathComponent($0).path) }
                && queue.activeJob == nil && queue.pending.isEmpty
        }
        XCTAssertEqual(seen.log, ["disk, open: 0", "disk, open: 0"], "old audio")

        // A deletion by hand: refused while the open goes, then it goes.
        seen.reset()
        let deleted = try seed("2026-10-06 12-00-00 Meeting")
        try await holdingAnOpen(of: deleted, "a deletion") {
            library.remove(library.removalPlan(for: [deleted], kind: .meeting))
            try await until { !library.removalReport.isEmpty }
        }
        XCTAssertEqual(library.removalReport.last?.outcome,
                       .refused(String(localized: "The meeting’s audio is being opened: try again in a moment.")))
        try await until { library.player.state == .ready }
        library.remove(library.removalPlan(for: [deleted], kind: .meeting))
        try await until { library.removalReport.last?.outcome == .trashed }
        XCTAssertEqual(seen.log, ["disk, open: 0"], "a deletion")
    }

    private func openAgain(_ library: MeetingLibrary) async throws {
        library.refresh()
        try await until {
            library.local.fresh && !library.local.reading && (library.chosen.map { $0.fresh && !$0.reading } ?? true)
        }
    }

    /// The tracks are checked again right before they are opened: one
    /// replaced by a link after the folder was read is not followed.
    func testATrackReplacedByALinkIsNotOpened() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let outside = root.appendingPathComponent("elsewhere.m4a")
        try Data(repeating: 1, count: 64).write(to: outside)
        let player = MeetingPlayer(deck: deckLog.deck(clock: clock))
        let waiting = DispatchQueue(label: "held open")
        waiting.suspend()
        player.load(meeting, identity: try XCTUnwrap(FolderIdentity.of(meeting)), files: [.system: "system.m4a"]) {
            waiting.async(execute: $0)
        }
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("system.m4a"))
        try FileManager.default.createSymbolicLink(at: meeting.appendingPathComponent("system.m4a"), withDestinationURL: outside)
        waiting.resume()
        try await until { player.state != .loading }
        guard case .unavailable = player.state else { return XCTFail("\(player.state)") }
        XCTAssertEqual(deckLog.openCount, 0, "a link put in place of a track was opened")
    }

    /// A track that won't start, or stops by itself on an error, stops
    /// both, with the reason; it is never taken for the end.
    func testAFailingTrackStopsBothWithItsReason() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let library = try await openLibrary()
        library.select(meeting)
        try await until { library.player.state == .ready }
        let player = library.player

        try XCTUnwrap(deckLog.track("microphone.m4a")).refusesToPlay = true
        player.play()
        guard case .unavailable(let refused) = player.state else { return XCTFail("a track that didn't start: \(player.state)") }
        XCTAssertTrue(refused.contains(String(localized: "The audio didn’t start.")), refused)
        XCTAssertNil(deckLog.track("system.m4a"), "the other track kept going")

        library.select(nil as URL?)
        library.select(meeting)
        try await until { library.player.state == .ready }
        player.play()
        clock.advance(2)
        try XCTUnwrap(deckLog.track("system.m4a")).failure = "the volume went away"
        try await until { if case .unavailable = player.state { true } else { false } }
        guard case .unavailable(let reason) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertTrue(reason.contains("the volume went away"), reason)
        XCTAssertTrue(deckLog.open.isEmpty, "a track stayed open, or playing, after the other failed")
    }

    /// Play is off as soon as a dictation holds it, a load that ends during
    /// it included, with the reason.
    func testAHoldTakesPlayOffEvenForALoadThatEndsDuringIt() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let dictation = DictationCoordinator(mic: QuietMic(), indicator: RecordingIndicator(renderingEnabled: false))
        keepAlive.append(dictation)
        let library = try await openLibrary(dictation: dictation)
        deckLog.hold()
        library.select(meeting)
        dictation.beginCaptureForTesting()
        deckLog.release()
        try await until { library.player.state == .ready }
        XCTAssertEqual(library.player.held, MeetingLibrary.dictationRefusal, "Play was on during the dictation")
    }

    /// A meeting whose folder can't be read in a root that can is not "no
    /// match": the search says so, and Try Again reads it once it can.
    func testAMeetingWhoseFolderCantBeReadIsNotANoMatch() async throws {
        try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("иное")])
        let closed = try seed("2026-10-06 11-00-00 Meeting", files: ["transcript.md": transcript("искомое")])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }
        let library = try await openLibrary()
        library.searchQuery = "искомое"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(library.searchMatches.isEmpty)
        XCTAssertFalse(library.searchState.settled, "a meeting that can't be read passed for no match")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
        library.retrySearch()
        try await until { library.searchMatches[MeetingLibrary.canonical(closed)] != nil && library.searchState.settled }
    }

    /// A text read before the folder was asked for again is not shown:
    /// between the refresh and the folder's answer nothing of it appears,
    /// and the search is not settled.
    func testATextReadBeforeARefreshIsNotShown() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("слово")])
        let file = meeting.appendingPathComponent("transcript.md")
        // Whole seconds, as a share with coarse times keeps them.
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let gate = TextGate()
        gate.holdText(containing: "слово")
        let library = try await openLibrary(reader: gate.reader())
        var published: [[URL: MeetingLibrary.SearchMatch]] = []
        let watch = library.$searchMatches.sink { published.append($0) }
        defer { watch.cancel() }
        library.searchQuery = "слово"
        try await until { gate.reads(of: meeting) == 1 }

        // Changed within the same second: the date says nothing, only a
        // read after the refresh does.
        try Data(transcript("другое").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        gate.holdList(local)
        library.refresh()
        published = []
        gate.releaseText(containing: "слово")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(published.contains { $0[MeetingLibrary.canonical(meeting)] != nil },
                       "a text read before the refresh was shown before the folder answered: \(published)")
        XCTAssertFalse(library.searchState.settled, "the search was settled while the folder was read again")

        gate.releaseList(local)
        try await until { library.searchState.settled && gate.reads(of: meeting) == 2 }
        XCTAssertTrue(library.searchMatches.isEmpty)
    }

    /// A count begun before a refresh is not shown: the transcript was read
    /// and kept, then changed; a new query and a refresh in one turn, and
    /// nothing of the old text appears while the folder is read again. The
    /// two counts begun in that turn, known by their numbers, have answered
    /// before the folder is let go, the one from before the refresh
    /// dropped: no pause stands for it, and a late answer of a count from
    /// before the turn is not taken for one of them.
    func testACountBegunBeforeARefreshIsNotShown() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("слово")])
        let gate = TextGate()
        let library = try await openLibrary(reader: gate.reader())
        library.searchQuery = "нечто"
        try await until { gate.reads(of: meeting) == 1 && library.searchState.settled }

        let file = meeting.appendingPathComponent("transcript.md")
        try Data(transcript("другое").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        var published: [[URL: MeetingLibrary.SearchMatch]] = []
        let watch = library.$searchMatches.sink { published.append($0) }
        defer { watch.cancel() }
        var answers: [Int: Bool] = [:]
        library.countAnswered = { answers[$0] = $1 }
        func shown() -> Bool { published.contains { $0[MeetingLibrary.canonical(meeting)] != nil } }
        gate.holdList(local)
        // One turn of the main actor: the new query's count takes the kept
        // text, then the folder is asked for again.
        let query = library.searchCount + 1
        library.searchQuery = "слово"
        library.refresh()
        let refreshed = library.searchCount
        XCTAssertGreaterThan(refreshed, query, "the refresh began no count of its own")
        try await until { answers[query] != nil && answers[refreshed] != nil || shown() }
        XCTAssertFalse(shown(), "a count begun before the refresh showed the old text's match: \(published)")
        XCTAssertEqual(answers[query], false, "the count begun before the refresh was not dropped: \(answers)")
        XCTAssertEqual(answers[refreshed], true, "the refresh's own count was not taken: \(answers)")
        XCTAssertFalse(library.searchState.settled, "the search was settled while the folder was read again")

        gate.releaseList(local)
        try await until { library.searchState.settled && gate.reads(of: meeting) == 2 }
        XCTAssertTrue(library.searchMatches.isEmpty)
    }

    /// A new query is not settled, nor shows the last query's matches,
    /// until its own count is in.
    func testANewQueryIsNotSettledUntilItsCountIsIn() async throws {
        try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("альфа бета")])
        let library = try await openLibrary()
        library.searchQuery = "альфа"
        try await until { library.searchMatches.count == 1 && library.searchState.settled }
        library.searchQuery = "гамма"
        XCTAssertFalse(library.searchState.settled, "a new query was settled before its count")
        XCTAssertTrue(library.searchMatches.isEmpty, "the last query's matches stayed for the new one")
        try await until { library.searchState.settled }
        XCTAssertTrue(library.searchMatches.isEmpty)
    }

    /// A deletion of a meeting in the meetings folder: its files are closed
    /// before the Trash is touched, whichever address the card had.
    func testADeletionClosesTheFilesBeforeTheTrash() async throws {
        settings.meetingsFolderPath = disk.path
        let meeting = try seed("2026-10-06 10-00-00 Meeting", in: disk)
        var removal = MeetingStorage.Removal.confined(to: [root], trash: root.appendingPathComponent("Trash", isDirectory: true))
        let log = deckLog
        let seen = DeckLog()
        removal.beforeCheck = { _ in seen.add("open: \(log.open.count)") }
        let library = try await openLibrary(queue: makeQueue(removal: removal))
        library.select(meeting)
        try await until { library.player.state == .ready }

        library.remove(library.removalPlan(for: [meeting], kind: .meeting))
        try await until { !library.removalReport.isEmpty }
        XCTAssertEqual(seen.log, ["open: 0"], "the Trash was reached with the meeting's files open")
        XCTAssertEqual(library.removalReport.first?.outcome, .trashed)
    }

    /// The rule's deletion of old audio closes the files first too.
    func testOldAudioClosesThePlayersFilesFirst() async throws {
        let meeting = try RetentionFixture.meeting("2026-09-01 10-00-00 Meeting", in: local, ended: Date().addingTimeInterval(-40 * 86_400))
        var removal = MeetingStorage.Removal.confined(to: [root], trash: root.appendingPathComponent("Trash", isDirectory: true))
        let log = deckLog
        let seen = DeckLog()
        removal.beforeCheck = { _ in seen.add("open: \(log.open.count)") }
        let queue = makeQueue(removal: removal)
        queue.audioRetention = { (30, 1) }
        let library = try await openLibrary(queue: queue)
        library.select(meeting)
        try await until { library.player.state == .ready }

        queue.pruneAudio()
        try await until { !seen.log.isEmpty && queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertEqual(Set(seen.log), ["open: 0"], "old audio went while the player had it open")
    }

    // MARK: - Loads that come late

    /// A load inside its first open when another meeting is chosen or the
    /// window closes: it opens nothing more, closes what it opened, never
    /// plays, and takes nothing from the load that came after.
    func testALateLoadOnlyClosesWhatItOpened() async throws {
        let first = try seed("2026-10-06 10-00-00 Meeting")
        let second = try seed("2026-10-06 11-00-00 Meeting")
        let firstIdentity = try XCTUnwrap(FolderIdentity.of(first))
        let library = try await openLibrary()
        for change in ["another meeting", "the window closed"] {
            library.select(nil as URL?)
            deckLog.holdOpen(of: "microphone.m4a")
            let opensBefore = deckLog.opens(in: first)
            library.select(first)
            try await until { self.deckLog.isWaiting("microphone.m4a") }
            if change == "another meeting" { library.select(second) } else { library.windowClosed() }
            deckLog.releaseOpen(of: "microphone.m4a")
            try await until { !library.player.isOpening([firstIdentity]) }
            if change == "another meeting" { try await until { library.player.state == .ready } }
            XCTAssertEqual(deckLog.opens(in: first) - opensBefore, 1, "\(change): the load let go of opened its next track")
            XCTAssertFalse(deckLog.open.contains { $0.hasPrefix(first.path) }, "\(change): the late load kept its files open")
            XCTAssertFalse(deckLog.log.contains { $0.contains(" play ") }, "\(change): the late load played")
            if change == "another meeting" {
                try await until { library.player.state == .ready }
                XCTAssertEqual(library.player.folder, MeetingLibrary.canonical(second))
            } else {
                XCTAssertEqual(library.player.state, .empty)
                library.windowOpened()
                try await until { library.local.fresh }
            }
        }
    }

    /// A load let go of before its folder's queue reached it opens nothing.
    func testALoadLetGoOfBeforeItBeganOpensNothing() async throws {
        let ahead = try seed("2026-10-06 09-00-00 Meeting")
        let first = try seed("2026-10-06 10-00-00 Meeting")
        let second = try seed("2026-10-06 11-00-00 Meeting")
        let identities = try Set([ahead, first].map { try XCTUnwrap(FolderIdentity.of($0)) })
        let library = try await openLibrary()
        for change in ["another meeting", "the window closed"] {
            library.select(nil as URL?)
            // The parent folder's queue is inside another load's first open;
            // the next load waits behind it, not begun.
            deckLog.holdOpen(of: "microphone.m4a")
            let aheadBefore = deckLog.opens(in: ahead)
            library.select(ahead)
            try await until { self.deckLog.isWaiting("microphone.m4a") }
            library.select(first)
            if change == "another meeting" { library.select(second) } else { library.windowClosed() }
            deckLog.releaseOpen(of: "microphone.m4a")
            try await until { !library.player.isOpening(identities) }
            XCTAssertEqual(deckLog.opens(in: ahead) - aheadBefore, 1, "\(change): the load ahead, let go of in its first open, opened more")
            XCTAssertEqual(deckLog.opens(in: first), 0, "\(change): a load let go of before it began opened a track")
            XCTAssertFalse(deckLog.log.contains { $0.contains(" play ") }, "\(change): a load let go of played")
            if change == "another meeting" {
                try await until { library.player.state == .ready }
                XCTAssertEqual(library.player.folder, MeetingLibrary.canonical(second))
            } else {
                XCTAssertEqual(library.player.state, .empty)
                library.windowOpened()
                try await until { library.local.fresh }
            }
        }
    }

    /// The folder at a meeting's address is checked as its files are
    /// opened: another one put there meanwhile is not opened.
    func testAFolderPutAtTheAddressBeforeTheOpenIsNotOpened() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting")
        let identity = try XCTUnwrap(FolderIdentity.of(meeting))
        let player = MeetingPlayer(deck: deckLog.deck(clock: clock))
        let waiting = DispatchQueue(label: "held open")
        waiting.suspend()
        player.load(meeting, identity: identity, files: [.system: "system.m4a"]) { waiting.async(execute: $0) }
        try FileManager.default.moveItem(at: meeting, to: root.appendingPathComponent("Aside", isDirectory: true))
        try seed("2026-10-06 10-00-00 Meeting")
        waiting.resume()
        try await until { player.state != .loading }
        guard case .unavailable = player.state else { return XCTFail("\(player.state)") }
        XCTAssertEqual(deckLog.openCount, 0, "another folder's track was opened")
    }

    // MARK: - Lines and times

    /// The record's exact spans while the file is the one it wrote; the
    /// file's timecodes otherwise; a foreign text has none.
    func testLineTimesComeFromTheRecordOnlyWhileTheFileIsUnchanged() throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n\n[1:02:03] **Others:** два\n"
        var attempt = MeetingAttempt(number: 1, startedAt: Date())
        attempt.lines = [.init(start: 5.2, end: 6.8, source: .microphone), .init(start: 3_723.4, end: 3_730, source: .system)]
        let bytes = Data(raw.utf8)
        attempt.fingerprint = .init(bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())

        let exact = MeetingTranscript.parse(raw).timed(by: attempt)
        XCTAssertEqual(exact.timing, .exact(attempt.lines))
        XCTAssertEqual(exact.timing.line(at: 6), 0)
        XCTAssertNil(exact.timing.line(at: 10), "a line lit between lines")
        XCTAssertEqual(exact.timing.line(at: 3_725), 1)

        let edited = MeetingTranscript.parse(raw.replacingOccurrences(of: "раз", with: "три")).timed(by: attempt)
        XCTAssertEqual(edited.timing, .approximate([5, 3_723]))
        XCTAssertEqual(edited.timing.line(at: 100), 0)
        var short = attempt
        short.lines.removeLast()
        XCTAssertEqual(MeetingTranscript.parse(raw).timed(by: short).timing, .approximate([5, 3_723]))
        XCTAssertEqual(MeetingTranscript.parse("written by hand").timing, .untimed)
    }

    /// Through the window: the text shown takes the record's times, a
    /// timecode clicked plays from its line.
    func testATimecodeClickedPlaysFromItsLine() async throws {
        let raw = "# Meeting\n\n---\n\n[0:05] **Me:** раз\n\n[0:40] **Others:** два\n"
        var attempt = MeetingAttempt(number: 1, startedAt: Date())
        attempt.result = .complete
        attempt.transcript = "transcript.md"
        attempt.lines = [.init(start: 5.2, end: 6.8, source: .microphone), .init(start: 40.5, end: 42, source: .system)]
        let bytes = Data(raw.utf8)
        attempt.fingerprint = .init(bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let meeting = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": raw])
        try attempt.write(to: meeting.appendingPathComponent(MeetingAttempt.fileName(number: 1)))
        let library = try await openLibrary()
        library.select(meeting)
        try await until { library.player.state == .ready && library.text != .loading }
        guard case .loaded(let transcript) = library.text else { return XCTFail("\(library.text)") }
        XCTAssertEqual(transcript.timing, .exact(attempt.lines))

        var view = TranscriptTextView(transcript: transcript, identity: "x")
        view.playLine = { library.player.play(from: transcript.timing.starts[$0]) }
        let coordinator = view.makeCoordinator()
        coordinator.playLine = view.playLine
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: "murmurly-line:1", at: 0))
        XCTAssertEqual(library.player.state, .playing)
        XCTAssertEqual(library.player.position, 40.5, accuracy: 0.06)
    }

    // MARK: - Search

    /// The list keeps the meetings found, with how often; the card's
    /// highlights are the list's count for the newest version. Case and
    /// the Russian yo/ye do not tell words apart, other marks do; names are
    /// searched, timecodes, labels and the header are not.
    func testSearchNarrowsTheListAndCountsWhatTheCardHighlights() async throws {
        let tree = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("Ёлка, и ещё ёлка. Мой дом")])
        let fir = try seed("2026-10-06 11-00-00 Meeting", files: ["transcript.md": transcript("ЕЛКА")])
        let mine = try seed("2026-10-06 12-00-00 Meeting", files: ["transcript.md": transcript("мои вещи")])
        try MeetingMarks.write(.init(title: .some("Квартальный план")), in: mine, expecting: FolderIdentity.of(mine))
        let library = try await openLibrary()

        library.searchQuery = "елка"
        try await until { library.searchMatches.count == 2 && library.searchState.settled }
        XCTAssertEqual(library.searchMatches[MeetingLibrary.canonical(tree)]?.count, 2)
        XCTAssertEqual(library.searchMatches[MeetingLibrary.canonical(fir)]?.count, 1)
        let shown = MeetingTranscript.parse(try String(contentsOf: tree.appendingPathComponent("transcript.md"), encoding: .utf8))
        XCTAssertEqual(MeetingSearch.ranges(of: "елка", in: shown.layout).count, 2, "the card's highlights are not the list's count")

        library.searchQuery = "мой"
        try await until { library.searchMatches.keys.map(\.lastPathComponent) == [tree.lastPathComponent] }
        library.searchQuery = "квартальный"
        try await until { library.searchMatches[MeetingLibrary.canonical(mine)]?.inTitle == true }
        for unsearched in ["Me", "0:05", "Meeting"] {
            library.searchQuery = unsearched
            try await Task.sleep(for: .milliseconds(150))
            try await until { library.searchState.settled }
            XCTAssertEqual(library.searchMatches.values.filter { $0.count > 0 }, [], "“\(unsearched)” was found in a time, a label or the header")
        }
    }

    /// A yo written as ye and a combining diaeresis (a pasted name, a
    /// dictionary's spelling, a transcript from elsewhere) is two UTF-16
    /// units: folded into one, the text came out shorter than the card's
    /// ranges, and a match looked for at its end stopped the app.
    func testADecomposedYoKeepsTheCardsMatchesInPlace() {
        let layout = MeetingTranscript.parse(decomposedYo).layout
        XCTAssertEqual(layout.lines.count, 2)
        for text in [decomposedYo, layout.string, "ёЁ е\u{0308}Е\u{0308}"] {
            XCTAssertEqual(MeetingSearch.fold(text).utf16.count, text.utf16.count, "the fold changed the length of “\(text)”")
        }
        let shown = layout.string as NSString
        let found = MeetingSearch.ranges(of: "встречи", in: layout)
        XCTAssertEqual(found, [shown.range(of: "встречи", options: .literal)])
        XCTAssertEqual(found.map(shown.substring(with:)), ["встречи"])
    }

    /// The same text through the list's count, made off the main actor.
    func testADecomposedYoKeepsTheListsCountInPlace() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": decomposedYo])
        let library = try await openLibrary()

        library.searchQuery = "встречи"
        try await until { library.searchMatches[MeetingLibrary.canonical(meeting)]?.count == 1 && library.searchState.settled }
    }

    /// A transcript not read yet, one that can't be read, and a meetings
    /// folder never read or away are not "no match".
    func testATextNotReadIsNotANoMatch() async throws {
        let slow = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("искомое")])
        let broken = try seed("2026-10-06 11-00-00 Meeting", files: ["transcript.md": transcript("искомое")])
        let gate = TextGate()
        gate.hold(slow)
        gate.fail(broken)
        let library = try await openLibrary(reader: gate.reader())

        library.searchQuery = "искомое"
        try await until { gate.reads(of: slow) == 1 }
        XCTAssertFalse(library.searchState.settled)
        XCTAssertGreaterThan(library.searchState.waiting, 0)
        gate.release(slow)
        try await until { library.searchMatches[MeetingLibrary.canonical(slow)] != nil && library.searchState.waiting == 0 }
        XCTAssertEqual(library.searchState.failed.count, 1, "a transcript that can't be read passed for no match")
        XCTAssertFalse(library.searchState.settled)

        // A meetings folder not read yet holds an unknown number of meetings.
        gate.holdList(disk)
        settings.meetingsFolderPath = disk.path
        library.refresh()
        try await until { library.chosen?.reading == true }
        library.searchQuery = "искомое "
        try await until { library.searchState.unknownFolders.contains(self.disk.standardizedFileURL.path) }
        XCTAssertFalse(library.searchState.settled, "a meetings folder never read passed for searched")
        gate.releaseList(disk)

        settings.meetingsFolderPath = root.appendingPathComponent("Away", isDirectory: true).path
        library.refresh()
        try await until { library.chosen?.state == .unavailable }
        try await until { library.searchState.unknownFolders.contains(self.root.appendingPathComponent("Away").standardizedFileURL.path) }
    }

    /// One read of a folder's transcripts at a time; after the window
    /// closes no batch starts, and an answer for a meeting replaced at its
    /// address meanwhile is dropped.
    func testOneSearchReadPerFolderAndLateAnswersAreDropped() async throws {
        var meetings: [URL] = []
        for index in 0..<25 {
            meetings.append(try seed(String(format: "2026-10-06 10-%02d-00 Meeting", index), files: ["transcript.md": transcript("слово")]))
        }
        let gate = TextGate()
        gate.holdAll()
        let library = try await openLibrary(reader: gate.reader())
        library.searchQuery = "слово"
        try await until { gate.textReads == 1 }
        library.windowClosed()
        gate.releaseAll()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gate.textReads, 20, "a batch began after the window closed")
        XCTAssertEqual(gate.mostAtOnce(in: local), 1)
        XCTAssertTrue(library.searchMatches.isEmpty)

        library.windowOpened()
        try await until { library.local.fresh }
        let replaced = meetings[0]
        let before = gate.reads(of: replaced)
        gate.hold(replaced)
        library.searchQuery = "слово"
        try await until { gate.reads(of: replaced) == before + 1 }
        // Its text read, the meeting is replaced before the answer: the
        // list read after it finds another folder there.
        try FileManager.default.moveItem(at: replaced, to: root.appendingPathComponent("Aside", isDirectory: true))
        try seed(replaced.lastPathComponent, files: ["transcript.md": transcript("другое")])
        gate.holdText(containing: "другое")
        library.refresh()
        gate.release(replaced)
        // The new folder listed, its own text not read yet: the old one's
        // text is not its.
        try await until { library.local.fresh && gate.reads(of: replaced) == before + 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(library.searchMatches[MeetingLibrary.canonical(replaced)], "the folder put in its place took the old meeting's text")
        gate.releaseText(containing: "другое")
        try await until { library.searchState.settled && library.local.fresh }
        XCTAssertNil(library.searchMatches[MeetingLibrary.canonical(replaced)], "the replaced meeting kept the text read for the one before")
        XCTAssertEqual(gate.mostAtOnce(in: local), 1)
    }

    /// The search reads in batches: a list asked for meanwhile goes before
    /// the next batch.
    func testSearchingLetsTheListGoFirst() async throws {
        for index in 0..<25 {
            try seed(String(format: "2026-10-06 10-%02d-00 Meeting", index), files: ["transcript.md": transcript("слово")])
        }
        let gate = TextGate()
        gate.holdAll()
        let library = try await openLibrary(reader: gate.reader())
        library.searchQuery = "слово"
        try await until { gate.textReads == 1 }
        library.refresh()
        gate.releaseAll()
        try await until { library.searchState.settled && library.searchMatches.count == 25 }
        let log = gate.log
        let list = try XCTUnwrap(log.lastIndex { $0.hasPrefix("list ") })
        XCTAssertEqual(log[..<list].filter { !$0.hasPrefix("list ") }.count, 20, "the list waited for every batch: \(log)")
    }

    /// A transcript changed since it was read is read again.
    func testAChangedTranscriptIsSearchedAgain() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("альфа")])
        let library = try await openLibrary()
        library.searchQuery = "альфа"
        try await until { library.searchMatches.count == 1 }
        let file = meeting.appendingPathComponent("transcript.md")
        try Data(transcript("бета").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        library.refresh()
        try await until { library.searchMatches.isEmpty && library.searchState.settled }
        library.searchQuery = "бета"
        try await until { library.searchMatches.count == 1 }
    }

    /// ⌘G and ⇧⌘G go through the search's matches while the find bar is
    /// closed; Space plays and pauses.
    func testCommandGStepsThroughTheMatchesAndSpacePlays() throws {
        let transcript = MeetingTranscript.parse(transcript("один два один"))
        var view = TranscriptTextView(transcript: transcript, identity: "x")
        view.query = "один"
        var toggles = 0
        let coordinator = view.makeCoordinator()
        let textView = TranscriptNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.coordinator = coordinator
        coordinator.togglePlayer = { toggles += 1 }
        coordinator.layout = transcript.layout
        textView.textStorage?.setAttributedString(TranscriptTextView.attributed(transcript))
        coordinator.show(query: "один", current: nil, in: textView)
        XCTAssertEqual(coordinator.matches.count, 2)

        let next = NSMenuItem()
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        textView.performFindPanelAction(next)
        XCTAssertEqual(textView.selectedRange(), coordinator.matches[0])
        textView.performFindPanelAction(next)
        XCTAssertEqual(textView.selectedRange(), coordinator.matches[1])
        let previous = NSMenuItem()
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        textView.performFindPanelAction(previous)
        XCTAssertEqual(textView.selectedRange(), coordinator.matches[0])

        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        textView.keyDown(with: space)
        XCTAssertEqual(toggles, 1)
    }

    /// Return in the search asks the card's text to take the focus at its
    /// match once it is read; leaving the meetings first drops that wish,
    /// so a text read late takes no focus from the section now shown.
    /// Meetings and Starred show the same card: the wish stays between them.
    func testLeavingTheMeetingsDropsTheWishForFocus() async throws {
        let meeting = try seed("2026-10-06 10-00-00 Meeting", files: ["transcript.md": transcript("код 4815")])
        let library = try await openLibrary()
        library.searchQuery = "4815"
        try await until { library.searchMatches.count == 1 && library.searchState.settled }
        library.searchSubmitted()
        XCTAssertEqual(library.searchFocus, MeetingLibrary.canonical(meeting))
        library.section = .starred
        XCTAssertEqual(library.searchFocus, MeetingLibrary.canonical(meeting), "Starred dropped the wish of the same card")
        library.section = .dictations
        XCTAssertNil(library.searchFocus, "a text read later would take the focus from another section")
    }

    /// The text takes the focus at its match only while it is on screen:
    /// hidden with its section, it takes none, even when the wish came
    /// just before the section changed, and it gives up a focus it had.
    func testAHiddenTextTakesNoFocus() async throws {
        let transcript = MeetingTranscript.parse(transcript("один два один"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        func text(focus: Bool, active: Bool) -> some View {
            TranscriptTextView(transcript: transcript, identity: "x", query: "один", focusMatch: focus, active: active)
                .frame(width: 400, height: 300)
        }
        let host = NSHostingView(rootView: AnyView(text(focus: false, active: true)))
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        func find(in view: NSView) -> NSTextView? {
            if let text = view as? TranscriptNSTextView { return text }
            for child in view.subviews { if let text = find(in: child) { return text } }
            return nil
        }
        func shown() -> NSTextView? { find(in: host) }
        func firstResponderIsText() -> Bool { shown().map { window.firstResponder === $0 } ?? false }
        try await until { shown() != nil }

        // Wished for and hidden in the same turn: no focus.
        host.rootView = AnyView(text(focus: true, active: true))
        host.layoutSubtreeIfNeeded()
        host.rootView = AnyView(text(focus: true, active: false))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(firstResponderIsText(), "a hidden text took the focus")

        // On screen it takes it, and gives it up when hidden.
        host.rootView = AnyView(text(focus: true, active: true))
        host.layoutSubtreeIfNeeded()
        try await until { firstResponderIsText() }
        host.rootView = AnyView(text(focus: false, active: false))
        host.layoutSubtreeIfNeeded()
        try await until { !firstResponderIsText() }
    }

    /// The Find handlers do nothing while the text's section is hidden: ⌘G
    /// steps through no match and the Find items are off; on screen they
    /// work as before.
    func testAHiddenTextTakesNoFindAction() throws {
        let transcript = MeetingTranscript.parse(transcript("один два один"))
        let coordinator = TranscriptTextView(transcript: transcript, identity: "x").makeCoordinator()
        let textView = TranscriptNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.coordinator = coordinator
        coordinator.layout = transcript.layout
        textView.textStorage?.setAttributedString(TranscriptTextView.attributed(transcript))
        coordinator.show(query: "один", current: nil, in: textView)
        let next = NSMenuItem(title: "", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let before = textView.selectedRange()

        coordinator.active = false
        XCTAssertFalse(textView.validateUserInterfaceItem(next), "Find Next is on for a hidden text")
        textView.performFindPanelAction(next)
        textView.performTextFinderAction(next)
        XCTAssertEqual(textView.selectedRange(), before, "⌘G moved a hidden text's selection")

        coordinator.active = true
        XCTAssertTrue(textView.validateUserInterfaceItem(next))
        textView.performFindPanelAction(next)
        XCTAssertEqual(textView.selectedRange(), coordinator.matches[0], "⌘G on screen stepped through no match — the check proves nothing")
    }

    /// The card's "i of n" follows the selection whatever moved it: a step
    /// to a match, then a click in plain text.
    func testTheMatchPositionFollowsTheSelection() async throws {
        let transcript = MeetingTranscript.parse(transcript("один два один"))
        let coordinator = TranscriptTextView(transcript: transcript, identity: "x").makeCoordinator()
        let textView = TranscriptNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.coordinator = coordinator
        textView.delegate = coordinator
        var position: TranscriptTextView.MatchPosition?
        coordinator.onMatches = { position = $0 }
        coordinator.layout = transcript.layout
        textView.textStorage?.setAttributedString(TranscriptTextView.attributed(transcript))
        coordinator.show(query: "один", current: nil, in: textView)
        try await until { position == .init(index: nil, total: 2) }

        coordinator.step(1, in: textView)
        try await until { position == .init(index: 0, total: 2) }
        let plain = (transcript.layout.string as NSString).range(of: "два")
        textView.setSelectedRange(NSRange(location: plain.location + 1, length: 0))
        try await until(message: { "\(String(describing: position))" }) { position == .init(index: nil, total: 2) }
        textView.setSelectedRange(coordinator.matches[1])
        try await until { position == .init(index: 1, total: 2) }
    }

    // MARK: - A dictionary entry from the transcript

    /// The sheet gets the words of the line the selection begins in, the
    /// time and label left out, whether the selection began on the words,
    /// the label or the time; in the header, or a text not in the app's
    /// form, the paragraph. Everything selected goes with it, as selected,
    /// across two lines too; several stretches are none. Ranges are the
    /// shown string's UTF-16, an emoji before the words included.
    func testDictionarySourceIsTheLineTheSelectionStartsIn() throws {
        let raw = "# Meeting\n\nAutomatic transcript.\nPieces not recognized: 1.\n\n---\n\n[0:05] **Me:** 🙂 открываем клод код\n\n[0:07] **Others:** и смотрим\n"
        let layout = MeetingTranscript.parse(raw).layout
        let string = layout.string as NSString
        func range(_ text: String) -> NSRange { string.range(of: text) }

        let words = try XCTUnwrap(layout.dictionarySource(for: [range("клод код")]))
        XCTAssertEqual(words.text, "🙂 открываем клод код")
        XCTAssertEqual(words.selected, "клод код")
        for start in ["[0:05]", "Me:"] {
            XCTAssertEqual(layout.dictionarySource(for: [range(start)])?.text, "🙂 открываем клод код", start)
        }
        let across = try XCTUnwrap(layout.dictionarySource(for: [NSRange(location: range("код").location, length: NSMaxRange(range("и смотрим")) - range("код").location)]))
        XCTAssertEqual(across.text, "🙂 открываем клод код")
        XCTAssertTrue(across.selected?.hasSuffix("и смотрим") == true, "the selection was cut to its first line: \(across.selected ?? "nil")")
        if case .success = DictionaryEntry.variant(fromSelection: Substring(try XCTUnwrap(across.selected))) {
            XCTFail("a selection over two lines passed for one spelling")
        }
        XCTAssertNil(layout.dictionarySource(for: [range("клод"), range("смотрим")])?.selected, "several stretches passed for one")
        XCTAssertEqual(layout.dictionarySource(for: [range("клод"), range("смотрим")])?.text, "🙂 открываем клод код")
        XCTAssertEqual(layout.dictionarySource(for: [range("not recognized")])?.text, "Pieces not recognized: 1.")
        XCTAssertNil(layout.dictionarySource(for: [NSRange(location: range("клод").location, length: 0)]))
        XCTAssertNil(layout.dictionarySource(for: [NSRange(location: NSMaxRange(range("код")), length: 2)]), "only spaces were taken")

        let manual = MeetingTranscript.parse("Созвон\n\nДенис: открываем клод код\nИван: да\n").layout
        let manualRange = (manual.string as NSString).range(of: "клод")
        XCTAssertEqual(manual.dictionarySource(for: [manualRange])?.text, "Денис: открываем клод код")

        // Names change where the words are: a range is read in its own text.
        let named = recordedTranscript(raw).named([.microphone: "Денис Андреевич"])
        let namedRange = (named.layout.string as NSString).range(of: "клод код")
        XCTAssertNotEqual(namedRange, range("клод код"))
        XCTAssertEqual(named.layout.dictionarySource(for: [namedRange])?.selected, "клод код")
        XCTAssertNotEqual(named.layout.dictionarySource(for: [range("клод код")])?.selected, "клод код")
    }

    /// The text with the record of its attempt, so names apply.
    private func recordedTranscript(_ raw: String) -> MeetingTranscript {
        let transcript = MeetingTranscript.parse(raw)
        var attempt = MeetingAttempt(number: 1, startedAt: Date())
        attempt.transcript = "transcript.md"
        attempt.lines = (transcript.lines ?? []).indices.map { MeetingAttempt.Line(start: Double($0), end: Double($0) + 1, source: $0 == 0 ? .microphone : .system) }
        let bytes = Data(raw.utf8)
        attempt.fingerprint = MeetingAttempt.Fingerprint(
            bytes: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        return transcript.timed(by: attempt)
    }

    /// A selection is told only for the text it was made in: one reported
    /// just before another text took its place, with the same range, is
    /// never told; the new text's own selection is.
    func testASelectionReportedForAnotherTextIsDropped() async throws {
        let first = MeetingTranscript.parse(transcript("один два три"))
        let second = MeetingTranscript.parse(transcript("раз два три"))
        let coordinator = TranscriptTextView(transcript: first, identity: "a").makeCoordinator()
        let textView = TranscriptNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.coordinator = coordinator
        textView.delegate = coordinator
        var told: [TranscriptTextView.Selection] = []
        coordinator.onSelection = { told.append($0) }
        coordinator.replace(with: first, identity: "a", in: textView)
        try await until { told.last?.identity == "a" }
        let words = (first.layout.string as NSString).range(of: "два")

        textView.setSelectedRange(words)
        coordinator.replace(with: second, identity: "b", in: textView)
        textView.setSelectedRange(words)
        try await until { told.last == TranscriptTextView.Selection(identity: "b", ranges: [words]) }
        XCTAssertFalse(told.contains(TranscriptTextView.Selection(identity: "a", ranges: [words])),
                       "a selection in the text replaced was told: \(told)")
    }

    /// The context menu's "Add to Dictionary…" takes what the text view has
    /// selected at the click, a selection made by hand and not yet told
    /// included; a click on no words offers no such item, nor does a view
    /// with no way to take it.
    func testTheContextMenuTakesTheViewsOwnSelection() throws {
        let shown = MeetingTranscript.parse(transcript("открываем клод код"))
        let coordinator = TranscriptTextView(transcript: shown, identity: "a").makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let textView = TranscriptNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        textView.coordinator = coordinator
        textView.delegate = coordinator
        coordinator.replace(with: shown, identity: "a", in: textView)
        var added: [TranscriptTextView.Selection] = []
        coordinator.addToDictionary = { added.append($0) }
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        /// A right click at the middle of `range`'s glyphs, or below all text.
        func click(on range: NSRange?) throws -> NSEvent {
            var point = NSPoint(x: 200, y: 290)
            if let range {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                point = NSPoint(x: rect.midX + textView.textContainerOrigin.x, y: rect.midY + textView.textContainerOrigin.y)
            }
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        func item(_ event: NSEvent) -> NSMenuItem? {
            textView.menu(for: event)?.items.first { $0.identifier?.rawValue == "meetingAddToDictionaryMenu" }
        }
        XCTAssertNil(item(try click(on: nil)), "offered for a click on no words")

        let words = (shown.layout.string as NSString).range(of: "клод код")
        textView.setSelectedRange(words)
        let event = try click(on: (shown.layout.string as NSString).range(of: "клод"))
        let offered = try XCTUnwrap(item(event), "not offered for a selection")
        XCTAssertEqual(textView.menu(for: event)?.items.first?.identifier?.rawValue, "meetingAddToDictionaryMenu", "not the first item")
        let action = try XCTUnwrap(offered.action)
        _ = (offered.target as AnyObject?)?.perform(action, with: offered)
        XCTAssertEqual(added, [TranscriptTextView.Selection(identity: "a", ranges: textView.selectedRanges.map(\.rangeValue))])
        XCTAssertEqual(added.first?.ranges, [words], "the click's own selection is not the one taken")
        coordinator.addToDictionary = nil
        XCTAssertNil(item(event), "offered without a way to take it")
    }

    // MARK: - Helpers

    private func transcript(_ words: String) -> String {
        "# Meeting\n\nAutomatic transcript.\n\n---\n\n[0:05] **Me:** \(words)\n"
    }

    /// Four yos, each ye and a combining diaeresis, before the last line,
    /// which ends with the words searched for.
    private let decomposedYo = """
        # Meeting

        ---

        [0:05] **Me:** Е\u{0308}лка, е\u{0308}ж, е\u{0308}рш и е\u{0308}ще

        [0:40] **Others:** итог встречи

        """

    private func metadata(caf: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "startedAt": "2026-10-06T10:00:00Z", "endedAt": "2026-10-06T10:01:30Z", "sampleRate": 48_000, "state": "done",
            "segments": [["index": 0, "system": caf ? "system.caf" : "system.m4a", "mic": caf ? "microphone.caf" : "microphone.m4a"]],
        ])
    }

    @discardableResult
    private func seed(
        _ name: String, in root: URL? = nil, tracks: [String] = ["system.m4a", "microphone.m4a"], files: [String: String] = [:]
    ) throws -> URL {
        let folder = (root ?? local).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try metadata().write(to: folder.appendingPathComponent("metadata.json"))
        for track in tracks { try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent(track)) }
        for (file, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(file)) }
        return folder
    }

    private func makeRecorder() -> MeetingRecorder {
        let recorder = MeetingRecorder(
            capture: ListeningCapture(),
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
        removal: MeetingStorage.Removal? = nil,
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
            removal: removal ?? .confined(to: [root], trash: root.appendingPathComponent("Trash", isDirectory: true)),
            destinations: destinations
        )
        keepAlive.append(queue)
        return queue
    }

    private func openLibrary(
        recorder: MeetingRecorder? = nil,
        queue: MeetingTranscriptionQueue? = nil,
        reader: MeetingLibrary.Reader = .disk,
        dictation: DictationCoordinator? = nil,
        deck: MeetingPlayer.Deck? = nil
    ) async throws -> MeetingLibrary {
        let library = MeetingLibrary(
            recorder: recorder ?? makeRecorder(),
            queue: queue ?? makeQueue(),
            settings: settings,
            localRoot: local,
            reader: reader,
            notRespondingAfter: .milliseconds(100),
            applicationName: { $0 },
            dictation: dictation,
            deck: deck ?? deckLog.deck(clock: clock)
        )
        keepAlive.append(library)
        library.windowOpened()
        try await until { library.local.fresh && !library.local.reading }
        return library
    }

    private func until(
        within limit: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        message: @MainActor () -> String = { "" },
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out \(message())", file: file, line: line)
        throw CancellationError()
    }
}
