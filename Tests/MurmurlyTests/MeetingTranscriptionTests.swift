import AVFoundation
import CryptoKit
import FluidAudio
import SwiftUI
import XCTest
@testable import Murmurly

/// Every engine call, in order, so a test can tell what ran between two moments.
private final class EngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    func all() -> [String] { lock.withLock { entries } }
}

/// Answers by the level of the chunk it is given: each speech region in a test
/// track has its own constant amplitude, so the reply proves which part of
/// which track reached the engine. Stands in for either engine and logs which
/// one was asked, and in what language.
private actor LevelEngine: WhisperEngine, ParakeetEngine {
    let replies: [Float: String]
    /// What a chunk asked in no language is "detected" as, like Whisper does.
    let detected: [Float: String]
    let delay: Duration
    let log: EngineLog

    init(replies: [Float: String], detected: [Float: String], delay: Duration, log: EngineLog) {
        self.replies = replies
        self.detected = detected
        self.delay = delay
        self.log = log
    }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        try await recognize(audioPath, asked: request.language, by: "whisper")
    }

    func transcribe(audioPath: String, language: String?) async throws
        -> (segments: [WhisperSegmentDTO], language: String) {
        try await recognize(audioPath, asked: language, by: "parakeet")
    }

    private func recognize(
        _ audioPath: String,
        asked: String?,
        by engine: String
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        let level = try Self.level(of: URL(fileURLWithPath: audioPath))
        let reply = replies.min { abs($0.key - level) < abs($1.key - level) }?.value ?? ""
        let language = asked ?? detected.min { abs($0.key - level) < abs($1.key - level) }?.value ?? "auto"
        log.append("\(engine):\(asked ?? "auto")")
        log.append("asked:\(asked ?? "auto")")
        log.append("start:\(reply)")
        // Two replies stand for broken engines: a chunk that fails on its own,
        // and an engine that is gone (its model folder removed mid-call).
        if reply == Self.failingReply { throw CocoaError(.fileReadCorruptFile) }
        if reply == Self.lostEngineReply {
            throw TranscriptionError.engineUnavailable("Папка модели не найдена: /models/whisper")
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        log.append("end:\(reply)")
        return ([WhisperSegmentDTO(text: reply, start: 0)], language)
    }

    static let failingReply = "<сбой куска>"
    static let lostEngineReply = "<движок пропал>"

    private static func level(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return 0 }
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let sorted = samples.map { abs($0) }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private actor LevelEngineFactory: WhisperEngineFactory, ParakeetEngineFactory {
    let replies: [Float: String]
    let detected: [Float: String]
    let delay: Duration
    let log: EngineLog
    private var loads: [String: Int] = [:]

    init(
        replies: [Float: String],
        detected: [Float: String] = [:],
        delay: Duration = .zero,
        log: EngineLog = EngineLog()
    ) {
        self.replies = replies
        self.detected = detected
        self.delay = delay
        self.log = log
    }

    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        loads[modelFolder, default: 0] += 1
        return LevelEngine(replies: replies, detected: detected, delay: delay, log: log)
    }

    func make(modelFolder: String) async throws -> any ParakeetEngine {
        loads[modelFolder, default: 0] += 1
        return LevelEngine(replies: replies, detected: detected, delay: delay, log: log)
    }

    func loadCount(_ path: String) -> Int { loads[path, default: 0] }
    func totalLoads() -> Int { loads.values.reduce(0, +) }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

private struct Region {
    let start: Double
    let end: Double
    let level: Float
}

/// Gives Parakeet once, for the warm-up at activation; every later load it
/// refuses at once, or holds until the load is cancelled.
private actor RefusingParakeetFactory: ParakeetEngineFactory {
    struct Refusal: LocalizedError {
        var errorDescription: String? { "the Parakeet model would not load" }
    }

    private struct Silent: ParakeetEngine {
        func transcribe(audioPath: String, language: String?) async throws
            -> (segments: [WhisperSegmentDTO], language: String) { ([], language ?? "auto") }
    }

    let holds: Bool
    private var tries = 0
    private var holding = false
    private var cancelled = false

    init(holds: Bool) { self.holds = holds }

    func make(modelFolder: String) async throws -> any ParakeetEngine {
        tries += 1
        guard tries > 1 else { return Silent() }
        guard holds else { throw Refusal() }
        holding = true
        do {
            while true { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            cancelled = true
            throw error
        }
    }

    func attempts() -> Int { tries }
    func isHolding() -> Bool { holding }
    func wasCancelled() -> Bool { cancelled }
}

/// Hugging Face out of service: every request gets 503 at once, so a download
/// fails with the server's reason.
private final class UnavailableHub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A door the test opens. Waiting at it ends when it opens or when the waiting
/// task is cancelled, so a cancelled model load cannot hang the cache.
private final class Gate: Sendable {
    private let entered = Locked(false)
    private let opened = Locked(false)

    var wasEntered: Bool { entered.get() }
    func open() { opened.set(true) }

    func pass() async throws {
        entered.set(true)
        while !opened.get() { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Loads the model at one gate and recognizes every chunk at another.
private struct GatedEngineFactory: WhisperEngineFactory {
    let load: Gate
    let recognition: Gate

    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        try await load.pass()
        return GatedEngine(recognition: recognition)
    }
}

private struct GatedEngine: WhisperEngine {
    let recognition: Gate

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        try await recognition.pass()
        return ([WhisperSegmentDTO(text: "речь", start: 0)], request.language ?? "ru")
    }
}

@MainActor
final class MeetingTranscriptionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Files tab: one file through the same pipeline

    func testFileTranscriptionLeavesTheUsersFolderAlone() async throws {
        let folder = root.appendingPathComponent("Загрузки", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("talk.caf")
        try writeTrack(file, rate: 44_100, duration: 10, regions: [
            Region(start: 1.5, end: 3, level: 0.1),
            Region(start: 5.5, end: 7, level: 0.5),
            Region(start: 8.5, end: 8.6, level: 0.3),   // under 0.3 s: skipped, not sent
        ])
        // Names this pipeline cleans up in a meeting folder; here they are the user's.
        let lookalike = folder.appendingPathComponent(
            MeetingTranscriber.temporaryPrefix + "mine" + MeetingTranscriber.temporarySuffix
        )
        try Data("user data".utf8).write(to: lookalike)
        try Data("# my notes".utf8).write(to: folder.appendingPathComponent("transcript.md"))
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        let streamingBefore = streamingTemporaryFiles()
        let factory = LevelEngineFactory(replies: [
            0.1: "Первая фраза", 0.5: "Вторая фраза", 0.3: "не должно попасть",
        ])
        let steps = Locked<[MeetingTranscriber.Step]>([])

        let lines = try await makeTranscriber(factory: factory).transcribeFile(file) { step in
            steps.set(steps.get() + [step])
        }

        XCTAssertEqual(lines.map(\.text), ["Первая фраза", "Вторая фраза"])
        XCTAssertEqual(lines.map { Int($0.start) }, [1, 5])
        XCTAssertEqual(Set(lines.map(\.speaker)), [""])
        XCTAssertEqual(steps.get().first, .reading(track: "file"))
        XCTAssertTrue(steps.get().contains(.recognizing(track: "file", done: 0, total: 3)))
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)), before)
        XCTAssertEqual(try Data(contentsOf: lookalike), Data("user data".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Загрузки"])
        XCTAssertEqual(streamingTemporaryFiles(), streamingBefore)
    }

    func testFileTranscriptionAsksForTheSelectedEngine() async throws {
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.2)])
        let factory = LevelEngineFactory(replies: [0.2: "привет"])
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in Self.levelDetector },
            currentEngine: { _ in Self.engine("/models/selected") },
            temporaryRoot: root
        )

        let lines = try await transcriber.transcribeFile(file) { _ in }

        XCTAssertEqual(lines.map(\.text), ["привет"])
        let loads = await factory.loadCount("/models/selected")
        XCTAssertEqual(loads, 1)
    }

    func testCancelledFileTranscriptionLeavesNoWorkBehind() async throws {
        let file = root.appendingPathComponent("long.caf")
        try writeTrack(file, rate: 48_000, duration: 8, regions: [
            Region(start: 1, end: 2, level: 0.1), Region(start: 4, end: 5, level: 0.5),
        ])
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "раз", 0.5: "два"], delay: .seconds(5), log: log)
        let streamingBefore = streamingTemporaryFiles()
        let transcriber = makeTranscriber(factory: factory)
        let task = Task { try await transcriber.transcribeFile(file) { _ in } }

        let started = await eventually(within: .seconds(10)) { !log.all().isEmpty }
        XCTAssertTrue(started)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled file transcription must not return text")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["long.caf"])
        XCTAssertEqual(streamingTemporaryFiles(), streamingBefore)
    }

    func testFailedChunkAmongRecognizedOnesMakesTheFileIncomplete() async throws {
        let file = root.appendingPathComponent("lecture.caf")
        try writeTrack(file, rate: 48_000, duration: 8, regions: [
            Region(start: 1, end: 2, level: 0.1), Region(start: 4, end: 5, level: 0.5),
        ])
        let before = try Data(contentsOf: file)
        let factory = LevelEngineFactory(replies: [0.1: "Первая фраза", 0.5: LevelEngine.failingReply])

        do {
            let lines = try await makeTranscriber(factory: factory).transcribeFile(file) { _ in }
            XCTFail("a gap must not pass for a whole transcript: \(lines.map(\.text))")
        } catch let failure as MeetingTranscriber.Failure {
            guard case let .incompleteFile(lines, failed, _) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(lines.map(\.text), ["Первая фраза"], "what was recognized comes back")
            XCTAssertEqual(failed, 1)
            XCTAssertTrue(failure.localizedDescription.hasPrefix("Not everything was transcribed"))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["lecture.caf"])
    }

    /// Three failures in a row after a recognized chunk: the text so far comes
    /// back with the failure, which says where the run stopped and that the
    /// rest of the file was not transcribed.
    func testFileCutShortByRepeatedFailuresKeepsWhatWasRecognized() async throws {
        let file = root.appendingPathComponent("lecture.caf")
        try writeTrack(file, rate: 48_000, duration: 15, regions: [
            Region(start: 1.5, end: 2.5, level: 0.1),
            Region(start: 4.5, end: 5.5, level: 0.4),
            Region(start: 7.5, end: 8.5, level: 0.4),
            Region(start: 10.5, end: 11.5, level: 0.4),
            Region(start: 13.5, end: 14.5, level: 0.3),
        ])
        let factory = LevelEngineFactory(replies: [
            0.1: "Первая фраза", 0.4: LevelEngine.failingReply, 0.3: "не дошло",
        ])

        do {
            let lines = try await makeTranscriber(factory: factory).transcribeFile(file) { _ in }
            XCTFail("a run cut short must not pass for a whole transcript: \(lines.map(\.text))")
        } catch {
            XCTAssertEqual(linesCarried(by: error), ["Первая фраза"], "\(error)")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("0:10, piece 4 of 5"), message)
            XCTAssertTrue(message.contains("Three pieces in a row were not recognized"), message)
            XCTAssertTrue(message.hasSuffix("the rest of the file was not transcribed"), message)
        }
    }

    /// The engine gone mid-run (its model folder removed) after a recognized
    /// chunk: no chunk is counted as failed, yet the text so far must come back.
    func testFileCutShortByALostEngineKeepsWhatWasRecognized() async throws {
        let file = root.appendingPathComponent("lecture.caf")
        try writeTrack(file, rate: 48_000, duration: 9, regions: [
            Region(start: 1.5, end: 2.5, level: 0.1),
            Region(start: 4.5, end: 5.5, level: 0.7),
            Region(start: 7.5, end: 8.5, level: 0.5),
        ])
        let factory = LevelEngineFactory(replies: [
            0.1: "Первая фраза", 0.7: LevelEngine.lostEngineReply, 0.5: "не дошло",
        ])

        do {
            let lines = try await makeTranscriber(factory: factory).transcribeFile(file) { _ in }
            XCTFail("a run cut short must not pass for a whole transcript: \(lines.map(\.text))")
        } catch {
            XCTAssertEqual(linesCarried(by: error), ["Первая фраза"], "\(error)")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("0:04, piece 2 of 3"), message)
            XCTAssertTrue(message.contains("Папка модели не найдена"), message)
            XCTAssertTrue(message.hasSuffix("the rest of the file was not transcribed"), message)
        }
    }

    /// One chunk, the model loading behind one gate and the recognition behind
    /// another: "recognizing" may not show while the model still loads, must
    /// show while that very chunk is being recognized, and nothing may follow
    /// the result.
    func testRecognizingIsReportedOnceTheEngineIsReady() async throws {
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.2)])
        let load = Gate()
        let recognition = Gate()
        let transcriber = makeTranscriber(cache: WhisperKitCache(
            factory: GatedEngineFactory(load: load, recognition: recognition)
        ))
        let steps = Locked<[MeetingTranscriber.Step]>([])
        let job = Task { try await transcriber.transcribeFile(file) { steps.set(steps.get() + [$0]) } }
        defer { job.cancel(); load.open(); recognition.open() }
        let recognizing = MeetingTranscriber.Step.recognizing(track: "file", done: 0, total: 1)

        let loading = await eventually(within: .seconds(10)) { load.wasEntered }
        XCTAssertTrue(loading, "the model load never started")
        XCTAssertFalse(steps.get().contains(recognizing), "recognizing shown while the model loads: \(steps.get())")

        load.open()
        let shown = await eventually(within: .seconds(10)) { steps.get().contains(recognizing) }
        XCTAssertTrue(shown, "recognizing not shown while the only chunk is recognized: \(steps.get())")

        recognition.open()
        let lines = try await job.value
        XCTAssertEqual(lines.map(\.text), ["речь"])
        let reported = steps.get().count
        for _ in 0..<20 { await Task.yield() }
        await MainActor.run {}
        XCTAssertEqual(steps.get().count, reported, "a step arrived after the result: \(steps.get())")
    }

    func testStepsOfAFileComeInOrderAndAWarmModelIsNotPreparedAgain() async throws {
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 6, regions: [
            Region(start: 1, end: 2.5, level: 0.2), Region(start: 3.5, end: 5, level: 0.2),
        ])
        let load = Gate()
        let recognition = Gate()
        load.open()
        recognition.open()
        let transcriber = makeTranscriber(cache: WhisperKitCache(
            factory: GatedEngineFactory(load: load, recognition: recognition)
        ))
        let steps = Locked<[MeetingTranscriber.Step]>([])

        _ = try await transcriber.transcribeFile(file) { steps.set(steps.get() + [$0]) }

        XCTAssertEqual(steps.get(), [
            .reading(track: "file"), .detecting(track: "file"), .preparingModel,
            .recognizing(track: "file", done: 0, total: 2), .recognizing(track: "file", done: 1, total: 2),
        ])
    }

    /// Another request holds the cache while its model loads: the chunk says it
    /// waits, and says "recognizing" only once the cache is its own.
    func testBusyCacheShowsWaitingForTheEngineFirst() async throws {
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.2)])
        let load = Gate()
        let recognition = Gate()
        recognition.open()
        let cache = WhisperKitCache(factory: GatedEngineFactory(load: load, recognition: recognition))
        let other = Task { try await cache.prepare(modelFolder: "/models/whisper") }
        let held = await eventually(within: .seconds(10)) { load.wasEntered }
        XCTAssertTrue(held, "the other request never took the cache")
        let transcriber = makeTranscriber(cache: cache)
        let steps = Locked<[MeetingTranscriber.Step]>([])
        let job = Task { try await transcriber.transcribeFile(file) { steps.set(steps.get() + [$0]) } }
        defer { job.cancel(); other.cancel(); load.open() }

        let waiting = await eventually(within: .seconds(10)) { steps.get().contains(.waitingForEngine) }
        XCTAssertTrue(waiting, "\(steps.get())")
        XCTAssertFalse(steps.get().contains(.recognizing(track: "file", done: 0, total: 1)), "\(steps.get())")

        load.open()
        _ = try await job.value
        try await other.value
        XCTAssertEqual(steps.get(), [
            .reading(track: "file"), .detecting(track: "file"), .waitingForEngine,
            .recognizing(track: "file", done: 0, total: 1),
        ])
    }

    func testCancelWhileTheModelLoadsEndsTheSteps() async throws {
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.2)])
        let load = Gate()
        let recognition = Gate()
        recognition.open()
        let transcriber = makeTranscriber(cache: WhisperKitCache(
            factory: GatedEngineFactory(load: load, recognition: recognition)
        ))
        let steps = Locked<[MeetingTranscriber.Step]>([])
        let job = Task { try await transcriber.transcribeFile(file) { steps.set(steps.get() + [$0]) } }
        defer { job.cancel(); load.open() }

        let loading = await eventually(within: .seconds(10)) {
            load.wasEntered && steps.get().contains(.preparingModel)
        }
        XCTAssertTrue(loading, "\(steps.get())")
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("a cancelled run must not return text")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let reported = steps.get().count
        for _ in 0..<20 { await Task.yield() }
        await MainActor.run {}
        XCTAssertEqual(steps.get().count, reported, "a step arrived after the cancel: \(steps.get())")
        XCTAssertEqual(steps.get().last, .preparingModel)
    }

    // MARK: - Files tab: the tab's own state

    /// The pipeline's cut-short file reaches the tab as text with its note on
    /// top, and that text counts as unsaved.
    func testFileCutShortReachesTheTabWithItsNote() async throws {
        let file = root.appendingPathComponent("lecture.caf")
        try writeTrack(file, rate: 48_000, duration: 9, regions: [
            Region(start: 1.5, end: 2.5, level: 0.1),
            Region(start: 4.5, end: 5.5, level: 0.7),
            Region(start: 7.5, end: 8.5, level: 0.5),
        ])
        let transcriber = makeTranscriber(factory: LevelEngineFactory(replies: [
            0.1: "Первая фраза", 0.7: LevelEngine.lostEngineReply, 0.5: "не дошло",
        ]))
        let files = FilesModel { _ in FilesModel.transcription(transcriber, choice: nil) }

        files.select(file)
        files.start()
        let finished = await eventually(within: .seconds(10)) { !files.isTranscribing }

        XCTAssertTrue(finished)
        XCTAssertNil(files.errorText)
        XCTAssertEqual(files.segments.count, 2, "\(files.segments.map(\.text))")
        XCTAssertTrue(files.segments.first?.text.hasPrefix("⚠︎ Transcription stopped at file, 0:04") == true)
        XCTAssertEqual(files.segments.last?.text, "Первая фраза")
        XCTAssertTrue(files.status.hasPrefix("Stopped partway"), files.status)
        XCTAssertTrue(files.hasUnsavedText)
    }

    /// A save is taken with its result's revision: written after a newer
    /// result landed while the panel was up, it holds the old text and does
    /// not vouch for the new one.
    func testSaveBelongsToTheResultItWasTakenFrom() async throws {
        let target = root.appendingPathComponent("saved.md")
        let panel = Gate()
        let files = try await filesWithUnsavedResult(saveDestination: { _, _ in
            try? await panel.pass()
            return target
        })
        let save = Task { await files.saveTranscript(owner: nil) }
        let asked = await eventually(within: .seconds(10)) { panel.wasEntered }
        XCTAssertTrue(asked)

        try await landNewerResult(in: files)
        panel.open()
        let written = await save.value

        XCTAssertTrue(written)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "run 1")
        XCTAssertEqual(files.segments.map(\.text), ["run 2"])
        XCTAssertTrue(files.hasUnsavedText, "the newer result passed for saved")
        XCTAssertNil(files.savedAs)

        panel.open()
        let again = await files.saveTranscript(owner: nil)
        XCTAssertTrue(again)
        XCTAssertFalse(files.hasUnsavedText)
        XCTAssertEqual(files.savedAs, "saved.md")
    }

    /// "Save .md…" in the replace sheet: the new file is taken only once the
    /// very result the user agreed to drop is on disk. A cancelled panel, a
    /// failed write or a result that landed while the panel was up keeps the
    /// tab as it is.
    func testSaveThenReplaceGoesAheadOnlyForTheResultOnDisk() async throws {
        let b = root.appendingPathComponent("b.wav")

        let cancelled = try await filesWithUnsavedResult(saveDestination: { _, _ in nil })
        cancelled.select(b)
        await cancelled.saveThenReplace(try XCTUnwrap(cancelled.pendingReplacement), owner: nil)
        XCTAssertEqual(cancelled.fileURL?.lastPathComponent, "talk.wav", "a cancelled panel took the new file")
        XCTAssertEqual(cancelled.segments.map(\.text), ["run 1"])
        XCTAssertTrue(cancelled.hasUnsavedText)

        let unwritable = root.appendingPathComponent("no-such-folder/saved.md")
        let failed = try await filesWithUnsavedResult(saveDestination: { _, _ in unwritable })
        failed.select(b)
        await failed.saveThenReplace(try XCTUnwrap(failed.pendingReplacement), owner: nil)
        XCTAssertEqual(failed.fileURL?.lastPathComponent, "talk.wav", "a failed write took the new file")
        XCTAssertNotNil(failed.errorText)
        XCTAssertTrue(failed.hasUnsavedText)

        let target = root.appendingPathComponent("raced.md")
        let panel = Gate()
        let raced = try await filesWithUnsavedResult(saveDestination: { _, _ in
            try? await panel.pass()
            return target
        })
        raced.select(b)
        let agreed = try XCTUnwrap(raced.pendingReplacement)
        let replace = Task { await raced.saveThenReplace(agreed, owner: nil) }
        let asked = await eventually(within: .seconds(10)) { panel.wasEntered }
        XCTAssertTrue(asked)
        try await landNewerResult(in: raced)
        panel.open()
        await replace.value
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "run 1")
        XCTAssertEqual(raced.fileURL?.lastPathComponent, "talk.wav", "the newer result was dropped unasked")
        XCTAssertEqual(raced.segments.map(\.text), ["run 2"])
        XCTAssertTrue(raced.hasUnsavedText)

        let saved = root.appendingPathComponent("saved.md")
        let plain = try await filesWithUnsavedResult(saveDestination: { _, _ in saved })
        plain.select(b)
        await plain.saveThenReplace(try XCTUnwrap(plain.pendingReplacement), owner: nil)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "run 1")
        XCTAssertEqual(plain.fileURL, b)
        XCTAssertTrue(plain.segments.isEmpty)
    }

    /// A panel goes on the window it was asked from, whatever window is key
    /// when it comes; a window closed by then, or none, cancels the choice
    /// and shows nothing anywhere.
    func testAPanelGoesOnItsOwnerOrNowhere() async throws {
        let shown = Owners()
        let backend: FilesModel.PanelBackend = { _, owner, _ in
            shown.add(owner)
            return URL(fileURLWithPath: "/answered")
        }
        let owner = window(), key = window()
        owner.orderFrontRegardless()
        key.makeKeyAndOrderFront(nil)
        defer { owner.orderOut(nil); key.orderOut(nil) }

        let answer = await FilesModel.present(NSSavePanel(), on: owner, as: .filesTranscript, backend: backend)
        XCTAssertEqual(answer?.path, "/answered")
        XCTAssertEqual(shown.all, [ObjectIdentifier(owner)], "the panel went on another window than its own")

        owner.orderOut(nil)
        let closed = await FilesModel.present(NSSavePanel(), on: owner, as: .dictionaryExport, backend: backend)
        XCTAssertNil(closed, "a panel was answered for a window that is gone")
        let none = await FilesModel.present(NSOpenPanel(), on: nil, as: .fileToTranscribe, backend: backend)
        XCTAssertNil(none)
        XCTAssertEqual(shown.all.count, 1, "a panel went on a window other than its own, or on none")
    }

    /// Two panels held at once, from two windows, each answered by its own
    /// number whatever the order: the second goes on its window, the first,
    /// its window closed meanwhile, comes nowhere. The probe's root is the
    /// test's own temporary folder.
    func testTwoHeldPanelsAreToldApart() async throws {
        let probe = root.appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try Data().write(to: probe.appendingPathComponent("present.hold"))
        let shown = Owners()
        let backend: FilesModel.PanelBackend = { _, owner, _ in
            shown.add(owner)
            return URL(fileURLWithPath: "/answered")
        }
        let first = window(), second = window()
        first.identifier = NSUserInterfaceItemIdentifier("first")
        second.identifier = NSUserInterfaceItemIdentifier("second")
        first.orderFrontRegardless()
        second.orderFrontRegardless()
        defer { first.orderOut(nil); second.orderOut(nil) }
        func marker(_ name: String) -> URL { probe.appendingPathComponent(name) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: marker(name).path) }

        let one = Task { await FilesModel.present(NSSavePanel(), on: first, as: .meetingTranscript, backend: backend, probe: probe) }
        let held = await eventually(within: .seconds(5)) { exists("present-1.holding") }
        XCTAssertTrue(held)
        let two = Task { await FilesModel.present(NSSavePanel(), on: second, as: .dictionaryExport, backend: backend, probe: probe) }
        let heldToo = await eventually(within: .seconds(5)) { exists("present-2.holding") }
        XCTAssertTrue(heldToo)

        try Data().write(to: marker("present-2.release"))
        let answered = await two.value
        XCTAssertEqual(answered?.path, "/answered")
        XCTAssertEqual(try String(contentsOf: marker("present-2.owner"), encoding: .utf8), "second")
        first.orderOut(nil)
        try Data().write(to: marker("present-1.release"))
        let cancelled = await one.value
        XCTAssertNil(cancelled, "a panel came for a window that was gone")
        XCTAssertTrue(exists("present-1.cancelled"), "the first panel's end was not said for it")
        XCTAssertFalse(exists("present-1.owner"), "the first panel was said to go on a window")
        XCTAssertFalse(exists("present-2.cancelled"), "the second panel took the first one's end")
        XCTAssertEqual(shown.all, [ObjectIdentifier(second)])
    }

    /// The window a save was asked from reaches its panel by every way of
    /// Files: Save .md and "Save .md…" in the replace question.
    func testEveryPathCarriesItsOwner() async throws {
        let owner = window()
        let asked = Owners()
        let files = try await filesWithUnsavedResult(saveDestination: { _, window in
            asked.add(window)
            return nil
        })
        await files.saveTranscript(owner: owner)
        files.select(root.appendingPathComponent("b.wav"))
        await files.saveThenReplace(try XCTUnwrap(files.pendingReplacement), owner: owner)
        XCTAssertEqual(asked.all, [ObjectIdentifier(owner), ObjectIdentifier(owner)])
        XCTAssertTrue(files.hasUnsavedText, "a save nobody chose a place for passed for saved")
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A new file over unsaved text waits for the user: nothing changes until
    /// they agree, and agreeing takes the file without the old text.
    func testUnsavedTextIsReplacedOnlyAfterTheOwnerAgrees() async throws {
        let files = try await filesWithUnsavedResult(saveDestination: { _, _ in nil })
        let a = try XCTUnwrap(files.fileURL)
        let b = root.appendingPathComponent("b.wav")

        files.select(b)
        let pending = try XCTUnwrap(files.pendingReplacement)
        XCTAssertEqual(pending.action, .file(b))
        XCTAssertEqual(files.fileURL, a)
        XCTAssertEqual(files.segments.map(\.text), ["run 1"])

        files.replace(with: pending)
        XCTAssertNil(files.pendingReplacement)
        XCTAssertEqual(files.fileURL, b)
        XCTAssertTrue(files.segments.isEmpty)
        XCTAssertFalse(files.hasUnsavedText)

        files.select(a)
        XCTAssertNil(files.pendingReplacement, "no text, nothing to ask about")
        XCTAssertEqual(files.fileURL, a)
    }

    /// A run that cannot start for want of its model says so over the text
    /// and leaves the text as it was: the model is asked for before the
    /// question about the text, and again once the question is answered, as
    /// it may go while the save panel is up. Were the user asked, they agree.
    func testRunRefusedForAMissingModelLeavesTheTextShown() async throws {
        /// A tab with the unsaved result "run 1" and a switch for its model.
        func filesWithText(saveDestination: @escaping FilesModel.SaveDestination) async throws
            -> (files: FilesModel, model: Locked<Bool>, runs: Locked<Int>) {
            let model = Locked(true)
            let runs = Locked(0)
            let files = FilesModel(transcription: { _ in
                guard model.get() else { throw FilesModel.ModelMissing(engine: .whisper) }
                return { _, _ in
                    runs.set(runs.get() + 1)
                    return [TranscriptSegment(speaker: "", text: "run \(runs.get())")]
                }
            }, saveDestination: saveDestination)
            files.select(root.appendingPathComponent("talk.wav"))
            files.start()
            let shown = await eventually(within: .seconds(10)) { !files.isTranscribing && !files.segments.isEmpty }
            XCTAssertTrue(shown)
            XCTAssertTrue(files.hasUnsavedText)
            return (files, model, runs)
        }

        let gone = try await filesWithText(saveDestination: { _, _ in nil })
        gone.model.set(false)
        gone.files.start()
        if let question = gone.files.pendingReplacement { gone.files.replace(with: question) }
        let refused = await eventually(within: .seconds(10)) { !gone.files.isTranscribing }

        XCTAssertTrue(refused)
        XCTAssertEqual(gone.files.segments.map(\.text), ["run 1"], "the text went before the model was asked for")
        XCTAssertEqual(gone.files.errorText, FilesModel.ModelMissing(engine: .whisper).localizedDescription)
        XCTAssertTrue(gone.files.hasUnsavedText)
        XCTAssertEqual(gone.runs.get(), 1)

        let target = root.appendingPathComponent("saved.md")
        let panel = Gate()
        let going = try await filesWithText(saveDestination: { _, _ in
            try? await panel.pass()
            return target
        })
        going.files.start()
        let question = try XCTUnwrap(going.files.pendingReplacement)
        let replacing = Task { await going.files.saveThenReplace(question, owner: nil) }
        let asked = await eventually(within: .seconds(10)) { panel.wasEntered }
        XCTAssertTrue(asked)
        going.model.set(false)
        panel.open()
        await replacing.value
        let settled = await eventually(within: .seconds(10)) { !going.files.isTranscribing }

        XCTAssertTrue(settled)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "run 1")
        XCTAssertEqual(going.files.segments.map(\.text), ["run 1"], "the text went before the model was asked for again")
        XCTAssertEqual(going.files.savedAs, "saved.md")
        XCTAssertEqual(going.files.errorText, FilesModel.ModelMissing(engine: .whisper).localizedDescription)
        XCTAssertEqual(going.runs.get(), 1)
    }

    func testUnreadableFileNamesItself() async throws {
        let file = root.appendingPathComponent("lecture.mkv")
        try Data("not audio at all".utf8).write(to: file)
        let transcriber = makeTranscriber(factory: LevelEngineFactory(replies: [:]))

        do {
            _ = try await transcriber.transcribeFile(file) { _ in }
            XCTFail("an unreadable file must fail")
        } catch let failure as MeetingTranscriber.Failure {
            guard case let .unreadableAudio(name, _) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(name, "lecture.mkv")
            XCTAssertTrue(failure.localizedDescription.hasPrefix("Couldn’t read the audio in “lecture.mkv”"))
        }
    }

    // MARK: - Junctions with the real engine cache

    func testTranscriptInterleavesTracksDropsEchoAndKeepsShortReplies() async throws {
        try await assertInterleavesTracksDropsEchoAndKeepsShortReplies(systemRate: 24_000, microphoneRate: 48_000)
    }

    /// AirPods in headset mode: both tracks at the shared 24 kHz clock. Each
    /// track is read at its own rate and timed in seconds, so nothing moves.
    func testHeadsetRateTracksGiveTheSameTranscript() async throws {
        try await assertInterleavesTracksDropsEchoAndKeepsShortReplies(systemRate: 24_000, microphoneRate: 24_000)
    }

    private func assertInterleavesTracksDropsEchoAndKeepsShortReplies(
        systemRate: Double,
        microphoneRate: Double
    ) async throws {
        let folder = try makeFolder(
            // Starts sit mid-second: resampling rings a few samples before
            // each edge, which must not move a timecode to the previous second.
            microphone: [
                Region(start: 1.5, end: 3, level: 0.1),     // own speech
                Region(start: 4.7, end: 7, level: 0.2),     // echo of the system line
                Region(start: 9.5, end: 10.3, level: 0.3),  // short reply
            ],
            system: [
                Region(start: 4.5, end: 7.5, level: 0.5),
                Region(start: 10, end: 12.5, level: 0.6),
            ],
            systemRate: systemRate,
            microphoneRate: microphoneRate
        )
        let factory = LevelEngineFactory(replies: [
            0.1: "Всем добрый день, начнём с отчёта",
            0.2: "вы меня слышите хорошо слышно",
            0.3: "да",
            0.5: "Вы меня слышите? Хорошо слышно!",
            0.6: "Да, отлично, давайте начнём.",
        ])
        let transcriber = makeTranscriber(factory: factory)

        let report = try await transcriber.transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(report.echoRemoved, 1)
        XCTAssertEqual(report.lines.map(\.speaker), ["Me", "Others", "Me", "Others"])
        XCTAssertEqual(report.lines.map(\.text), [
            "Всем добрый день, начнём с отчёта",
            "Вы меня слышите? Хорошо слышно!",
            "да",
            "Да, отлично, давайте начнём.",
        ])
        let transcript = try XCTUnwrap(report.transcript)
        XCTAssertEqual(transcript.lastPathComponent, "transcript.md")
        let markdown = try String(contentsOf: transcript, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[0:01] **Me:** Всем добрый день"), markdown)
        XCTAssertTrue(markdown.contains("[0:04] **Others:** Вы меня слышите?"), markdown)
        XCTAssertTrue(markdown.contains("[0:09] **Me:** да"), markdown)
        XCTAssertTrue(markdown.contains("Language: \(DictationEngine.languageName("ru")).\n"), markdown)
        XCTAssertTrue(markdown.contains("Echo lines removed from the microphone: 1"), markdown)
        try assertNoTemporaryFiles(in: folder)
    }

    func testDictationWaitsForAtMostOneMeetingChunk() async throws {
        let folder = try makeFolder(
            microphone: (0..<8).map { Region(start: Double($0) * 3 + 1, end: Double($0) * 3 + 2.5, level: 0.1) },
            system: []
        )
        let dictation = root.appendingPathComponent("dictation.caf")
        try writeTrack(dictation, rate: 48_000, duration: 2, regions: [Region(start: 0.2, end: 1.8, level: 0.9)])
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок", 0.9: "диктовка"], delay: .milliseconds(250), log: log)
        let cache = WhisperKitCache(factory: factory)
        let transcriber = makeTranscriber(factory: factory, cache: cache)
        let job = Task { try await transcriber.transcribe(try .inspect(folder)) { _ in } }
        defer { job.cancel() }

        let started = await eventually(within: .seconds(10)) {
            log.all().filter { $0 == "start:кусок" }.count >= 2
        }
        XCTAssertTrue(started, "meeting chunks never reached the engine")
        log.append("dictation-queued")
        let clock = ContinuousClock()
        let queuedAt = clock.now
        let decoded = try await cache.transcribe(
            audioPath: dictation.path,
            descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
            request: .whisper(WhisperDecodeRequest(language: "ru"))
        )
        let waited = queuedAt.duration(to: clock.now)

        XCTAssertEqual(decoded.segments.map(\.text), ["диктовка"])
        let entries = log.all()
        let queued = try XCTUnwrap(entries.firstIndex(of: "dictation-queued"))
        let ownStart = try XCTUnwrap(entries.firstIndex(of: "start:диктовка"))
        let chunksStartedMeanwhile = entries[queued..<ownStart].filter { $0 == "start:кусок" }.count
        XCTAssertLessThanOrEqual(chunksStartedMeanwhile, 1, "dictation waited behind \(chunksStartedMeanwhile) chunks")
        XCTAssertLessThan(waited, .milliseconds(1_500))
        XCTAssertLessThan(entries.filter { $0 == "end:кусок" }.count, 8, "the meeting finished before the dictation")
        _ = try await job.value
    }

    func testEngineSwitchMidJobLoadsEachModelOnce() async throws {
        let folder = try makeFolder(
            microphone: (0..<6).map { Region(start: Double($0) * 3 + 1, end: Double($0) * 3 + 2.5, level: 0.1) },
            system: []
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок", 0.9: "диктовка"], delay: .milliseconds(150), log: log)
        let cache = WhisperKitCache(factory: factory)
        let first = Self.engine("/models/a")
        let second = Self.engine("/models/b")
        let selected = Locked(first)
        let transcriber = MeetingTranscriber(
            cache: cache,
            loadSpeechDetector: { _ in Self.levelDetector },
            currentEngine: { _ in selected.get() },
            temporaryRoot: root
        )
        let job = Task { try await transcriber.transcribe(try .inspect(folder)) { _ in } }
        defer { job.cancel() }

        // Switch while a chunk is being decoded: the job reads the engine again
        // only after that chunk, exactly as when the user switches mid-call.
        let switched = await eventually(within: .seconds(10)) {
            let entries = log.all()
            let starts = entries.filter { $0 == "start:кусок" }.count
            let ends = entries.filter { $0 == "end:кусок" }.count
            return ends >= 2 && starts == ends + 1
        }
        XCTAssertTrue(switched)
        // The user picks the other engine; dictation uses it at once.
        selected.set(second)
        let dictation = root.appendingPathComponent("dictation.caf")
        try writeTrack(dictation, rate: 48_000, duration: 2, regions: [Region(start: 0.2, end: 1.8, level: 0.9)])
        for _ in 0..<2 {
            _ = try await cache.transcribe(
                audioPath: dictation.path,
                descriptor: second.descriptor,
                request: second.request
            )
        }
        let report = try await job.value

        let loadsA = await factory.loadCount("/models/a")
        let loadsB = await factory.loadCount("/models/b")
        XCTAssertEqual(loadsA, 1)
        XCTAssertEqual(loadsB, 1)
        XCTAssertEqual(report.engines, [first.label, second.label])
    }

    func testThreeFailedChunksInARowKeepWhatWasRecognized() async throws {
        let folder = try makeFolder(
            microphone: [
                Region(start: 1.5, end: 3, level: 0.1),
                Region(start: 4.5, end: 6, level: 0.2),
                Region(start: 7.5, end: 9, level: 0.4),
                Region(start: 10.5, end: 12, level: 0.4),
                Region(start: 13.5, end: 15, level: 0.4),
                Region(start: 16.5, end: 18, level: 0.3),
            ],
            system: [Region(start: 20.5, end: 22, level: 0.6)]
        )
        let factory = LevelEngineFactory(replies: [
            0.1: "первая фраза с микрофона", 0.2: "вторая фраза с микрофона",
            0.3: "после сбоя", 0.4: LevelEngine.failingReply, 0.6: "собеседник",
        ])

        do {
            _ = try await makeTranscriber(factory: factory).transcribe(try .inspect(folder)) { _ in }
        } catch {
            XCTFail("the recognized part was thrown away: \(error)")
        }

        let markdown = try transcript(in: folder)
        XCTAssertTrue(markdown.contains("[0:01] **Me:** первая фраза с микрофона"), markdown)
        XCTAssertTrue(markdown.contains("вторая фраза с микрофона"), markdown)
        XCTAssertTrue(markdown.contains("Transcription broke off: microphone, 0:13, piece 5 of 6"), markdown)
        XCTAssertTrue(markdown.contains("The others were not transcribed."), markdown)
        XCTAssertFalse(markdown.contains("после сбоя"), markdown)
        XCTAssertFalse(markdown.contains("**Others:**"), markdown)
        try assertNoTemporaryFiles(in: folder)
    }

    func testEngineLostMidJobKeepsWhatWasRecognized() async throws {
        let folder = try makeFolder(
            microphone: [Region(start: 1.5, end: 3, level: 0.1)],
            system: [
                Region(start: 4.5, end: 6, level: 0.5),
                Region(start: 7.5, end: 9, level: 0.7),
                Region(start: 10.5, end: 12, level: 0.6),
            ]
        )
        let factory = LevelEngineFactory(replies: [
            0.1: "мой вопрос", 0.5: "ответ собеседника",
            0.6: "не дошло", 0.7: LevelEngine.lostEngineReply,
        ])

        do {
            _ = try await makeTranscriber(factory: factory).transcribe(try .inspect(folder)) { _ in }
        } catch {
            XCTFail("the recognized part was thrown away: \(error)")
        }

        let markdown = try transcript(in: folder)
        XCTAssertTrue(markdown.contains("**Me:** мой вопрос"), markdown)
        XCTAssertTrue(markdown.contains("**Others:** ответ собеседника"), markdown)
        XCTAssertTrue(markdown.contains("Transcription broke off: others, 0:07, piece 2 of 3"), markdown)
        XCTAssertTrue(markdown.contains("Папка модели не найдена"), markdown)
        XCTAssertTrue(markdown.contains("After this point the echo from the microphone was not removed."), markdown)
        XCTAssertFalse(markdown.contains("не дошло"), markdown)
    }

    func testChunkShorterThanMinimumIsSkippedWithoutFailingTheJob() async throws {
        let folder = try makeFolder(
            microphone: [
                Region(start: 1, end: 1.2, level: 0.1),
                Region(start: 3, end: 5, level: 0.2),
            ],
            system: []
        )
        let factory = LevelEngineFactory(replies: [0.1: "обрывок", 0.2: "целая фраза"])

        let report = try await makeTranscriber(factory: factory).transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(report.tracks.first?.chunks, 2)
        XCTAssertEqual(report.tracks.first?.skippedChunks, 1)
        XCTAssertEqual(report.lines.map(\.text), ["целая фраза"])
    }

    func testPunctuationOnlyRepliesAreDropped() async throws {
        let folder = try makeFolder(
            microphone: [Region(start: 1, end: 2, level: 0.1), Region(start: 3, end: 5, level: 0.2)],
            system: [Region(start: 6, end: 8, level: 0.5)]
        )
        let factory = LevelEngineFactory(replies: [0.1: ".", 0.2: "Начнём.", 0.5: " … "])

        let report = try await makeTranscriber(factory: factory).transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(report.lines.map(\.text), ["Начнём."])
    }

    func testExistingTranscriptIsNeverOverwrittenAndLeftoversAreRemoved() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let manual = folder.appendingPathComponent("transcript.md")
        let manualText = Data("# Ручная расшифровка\n".utf8)
        try manualText.write(to: manual)
        let leftover = folder.appendingPathComponent(".transcript-killed.tmp")
        try Data("half".utf8).write(to: leftover)
        let factory = LevelEngineFactory(replies: [0.1: "новый текст"])

        let report = try await makeTranscriber(factory: factory).transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(report.transcript?.lastPathComponent, "transcript 2.md")
        XCTAssertEqual(try Data(contentsOf: manual), manualText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        try assertNoTemporaryFiles(in: folder)
    }

    func testFolderWithoutSpeechWritesNoFile() async throws {
        let folder = try makeFolder(microphone: [], system: [])
        let factory = LevelEngineFactory(replies: [:])

        let report = try await makeTranscriber(factory: factory).transcribe(try .inspect(folder)) { _ in }

        XCTAssertNil(report.transcript)
        let loads = await factory.totalLoads()
        XCTAssertEqual(loads, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".md") }, "\(names)")
    }

    // MARK: - Attempt records

    /// A whole meeting: the record says complete and names its transcript,
    /// the engine, the language, the labels of both tracks, every line's
    /// span and source in the file's order, and the file's fingerprint.
    func testCompleteAttemptRecordsItsTranscriptLinesAndFingerprint() async throws {
        let folder = try makeFolder(
            microphone: [Region(start: 1.5, end: 3, level: 0.1)],
            system: [Region(start: 4.5, end: 6, level: 0.5), Region(start: 8.5, end: 10, level: 0.6)]
        )
        let queue = try await transcribedThroughQueue(folder, replies: [
            0.1: "мой вопрос", 0.5: "ответ собеседника", 0.6: "и ещё одна мысль, совсем отдельная",
        ])

        XCTAssertEqual(queue.lastOutcome, .saved(folder.appendingPathComponent("transcript.md").standardizedFileURL))
        let entries = try MeetingAttempt.entries(in: folder)
        XCTAssertEqual(entries.map(\.number), [1])
        let attempt = try XCTUnwrap(entries.first?.attempt)
        XCTAssertEqual(attempt.result, .complete)
        XCTAssertEqual(attempt.transcript, "transcript.md")
        XCTAssertEqual(attempt.engines, ["whisper"])
        XCTAssertEqual(attempt.languages, ["ru"])
        XCTAssertEqual(attempt.failedChunks, 0)
        XCTAssertFalse(attempt.cutShort)
        XCTAssertEqual(attempt.missingTracks, [])
        XCTAssertEqual(attempt.speakers, MeetingAttempt.Speakers(microphone: "Me", system: "Others"))
        XCTAssertNotNil(attempt.endedAt)
        let markdown = try Data(contentsOf: folder.appendingPathComponent("transcript.md"))
        XCTAssertEqual(attempt.fingerprint?.bytes, markdown.count)
        XCTAssertEqual(attempt.fingerprint?.sha256, SHA256.hash(data: markdown).map { String(format: "%02x", $0) }.joined())
        let fileLines = String(decoding: markdown, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("[") }
        XCTAssertEqual(attempt.lines.count, fileLines.count)
        XCTAssertEqual(attempt.lines.map(\.source), [.microphone, .system, .system])
        XCTAssertEqual(fileLines.map { $0.contains("**Me:**") }, [true, false, false])
        XCTAssertEqual(attempt.lines.first?.start ?? 0, 1.5, accuracy: 0.1)
        XCTAssertEqual(attempt.lines.first?.end ?? 0, 3, accuracy: 0.1)
    }

    /// One piece not recognized among many: the menu still says saved, as
    /// before, but the record does not call the transcript complete — only
    /// the audio could fill the gap.
    func testFailedChunkMakesTheAttemptIncompleteThoughTheMenuSaysSaved() async throws {
        let folder = try makeFolder(
            microphone: [Region(start: 1.5, end: 3, level: 0.1), Region(start: 4.5, end: 6, level: 0.4)],
            system: [Region(start: 7.5, end: 9, level: 0.5)]
        )
        let queue = try await transcribedThroughQueue(folder, replies: [
            0.1: "мой вопрос", 0.4: LevelEngine.failingReply, 0.5: "ответ собеседника",
        ])

        guard case .saved? = queue.lastOutcome else { return XCTFail("outcome \(String(describing: queue.lastOutcome))") }
        let attempt = try XCTUnwrap(MeetingAttempt.entries(in: folder).last?.attempt)
        XCTAssertEqual(attempt.result, .incomplete)
        XCTAssertEqual(attempt.failedChunks, 1)
        XCTAssertFalse(attempt.cutShort)
        XCTAssertEqual(attempt.transcript, "transcript.md")
    }

    /// Cut short by a lost engine, and a microphone track the metadata names
    /// but that is gone: both transcripts are incomplete, and say why.
    func testCutShortAttemptAndAMissingTrackAreIncomplete() async throws {
        let cut = try makeFolder(
            microphone: [Region(start: 1.5, end: 3, level: 0.1)],
            system: [Region(start: 4.5, end: 6, level: 0.5), Region(start: 7.5, end: 9, level: 0.7)],
            name: "cut"
        )
        _ = try await transcribedThroughQueue(cut, replies: [
            0.1: "мой вопрос", 0.5: "ответ собеседника", 0.7: LevelEngine.lostEngineReply,
        ])
        let cutShort = try XCTUnwrap(MeetingAttempt.entries(in: cut).last?.attempt)
        XCTAssertEqual(cutShort.result, .incomplete)
        XCTAssertTrue(cutShort.cutShort)

        let halved = try makeFolder(
            microphone: [Region(start: 1.5, end: 3, level: 0.1)],
            system: [Region(start: 4.5, end: 6, level: 0.5)],
            name: "halved"
        )
        try writeFinishedMetadata(in: halved)
        try FileManager.default.removeItem(at: halved.appendingPathComponent("microphone.caf"))
        let queue = try await transcribedThroughQueue(halved, replies: [0.5: "ответ собеседника"])
        guard case .saved? = queue.lastOutcome else { return XCTFail("outcome \(String(describing: queue.lastOutcome))") }
        let half = try XCTUnwrap(MeetingAttempt.entries(in: halved).last?.attempt)
        XCTAssertEqual(half.result, .incomplete)
        XCTAssertEqual(half.missingTracks, [.microphone])
        XCTAssertEqual(half.failedChunks, 0)
        XCTAssertFalse(half.cutShort)
    }

    /// A meeting with no speech and one whose model is missing get a record
    /// each; a folder that is not a meeting gets none, only the queue's
    /// memory of the refusal.
    func testAttemptsWithoutATranscriptAreRecordedButAForeignFolderGetsNone() async throws {
        let silent = try makeFolder(microphone: [], system: [], name: "silent")
        _ = try await transcribedThroughQueue(silent, replies: [:])
        let quiet = try XCTUnwrap(MeetingAttempt.entries(in: silent).last?.attempt)
        XCTAssertEqual(quiet.result, .noSpeech)
        XCTAssertNil(quiet.transcript)

        let modelless = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [], name: "modelless")
        let queue = MeetingTranscriptionQueue(transcriber: MeetingTranscriber(
            cache: WhisperKitCache(factory: LevelEngineFactory(replies: [:])),
            loadSpeechDetector: { _ in throw MeetingTranscriber.Failure.modelNotDownloaded },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        ))
        queue.enqueue(modelless)
        let failed = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeFolder == nil }
        XCTAssertTrue(failed)
        let refused = try XCTUnwrap(MeetingAttempt.entries(in: modelless).last?.attempt)
        XCTAssertEqual(refused.result, .failed)
        XCTAssertEqual(refused.reason, MeetingTranscriber.Failure.modelNotDownloaded.localizedDescription)
        XCTAssertNil(queue.unrecordedOutcomes[modelless.standardizedFileURL.path], "a recorded failure is on disk, not in memory")

        let documents = root.appendingPathComponent("Документы", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("заметки".utf8).write(to: documents.appendingPathComponent("notes.md"))
        queue.enqueue(documents)
        let answered = await eventually(within: .seconds(10)) {
            queue.lastOutcome.map { if case .failed(let folder, _) = $0 { folder.lastPathComponent == "Документы" } else { false } } ?? false
        }
        XCTAssertTrue(answered)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.path), ["notes.md"])
        XCTAssertEqual(queue.unrecordedOutcomes[documents.standardizedFileURL.path], queue.lastOutcome)
    }

    /// The user's cancel is not an attempt to remember: the record goes.
    func testCancelledAttemptLeavesNoRecord() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let load = Gate()
        load.open()
        let recognition = Gate()
        let queue = MeetingTranscriptionQueue(transcriber: MeetingTranscriber(
            cache: WhisperKitCache(factory: GatedEngineFactory(load: load, recognition: recognition)),
            loadSpeechDetector: { _ in Self.levelDetector },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        ))

        queue.enqueue(folder)
        let recognizing = await eventually(within: .seconds(10)) { recognition.wasEntered }
        XCTAssertTrue(recognizing)
        XCTAssertEqual(try MeetingAttempt.entries(in: folder).map(\.attempt?.result), [.inProgress])
        queue.cancelCurrent()
        let stopped = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(stopped)
        XCTAssertEqual(queue.lastOutcome, .cancelled(folder: folder.standardizedFileURL))
        XCTAssertEqual(try MeetingAttempt.entries(in: folder), [])
        XCTAssertNil(queue.unrecordedOutcomes[folder.standardizedFileURL.path])
    }

    /// A record that cannot be made stops the attempt before it reads
    /// anything: a later failure must not be left without a trace, or an
    /// earlier success would pass for the last word.
    func testAttemptThatCannotBeRecordedDoesNotStart() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let queue = MeetingTranscriptionQueue(transcriber: makeTranscriber(factory: factory))

        queue.enqueue(folder)
        let answered = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(answered)
        guard case let .failed(_, reason)? = queue.lastOutcome else {
            return XCTFail("outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertTrue(reason.hasPrefix("Couldn’t keep a record of this transcription in the meeting folder: "), reason)
        XCTAssertEqual(queue.unrecordedOutcomes[folder.standardizedFileURL.path], queue.lastOutcome)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["microphone.caf", "system.caf"])
        let loads = await factory.totalLoads()
        XCTAssertEqual(loads, 0, "the attempt went ahead without its record")
    }

    /// A folder reaches the queue named with or without its trailing slash
    /// (a recorder's tracks, a panel, the window's list): a new attempt
    /// clears the refusal the folder left, however it was named either time.
    func testANewAttemptClearsTheRefusalWhateverTheFolderURLLooksLike() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let queue = MeetingTranscriptionQueue(transcriber: makeTranscriber(factory: LevelEngineFactory(replies: [0.1: "текст"])))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        queue.enqueue(URL(fileURLWithPath: folder.path, isDirectory: true))
        let refused = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeFolder == nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertTrue(refused)
        XCTAssertEqual(queue.unrecordedOutcomes.count, 1, "the refusal was not kept")

        queue.enqueue(URL(fileURLWithPath: folder.path, isDirectory: false))
        let saved = await eventually(within: .seconds(10)) {
            if case .saved? = queue.lastOutcome { queue.activeFolder == nil } else { false }
        }

        XCTAssertTrue(saved, "\(String(describing: queue.lastOutcome))")
        XCTAssertTrue(queue.unrecordedOutcomes.isEmpty, "the refusal outlived the transcript: \(queue.unrecordedOutcomes)")
    }

    /// Attempts are ordered by their number, never by the clock: a failure
    /// right after a success, in the same second, is the last word, even if
    /// its time says otherwise.
    func testLaterFailureOutranksAnEarlierSuccessWhateverTheClockSays() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let calls = Locked(0)
        let queue = MeetingTranscriptionQueue(transcriber: MeetingTranscriber(
            cache: WhisperKitCache(factory: LevelEngineFactory(replies: [0.1: "текст"])),
            loadSpeechDetector: { _ in
                calls.set(calls.get() + 1)
                if calls.get() > 1 { throw MeetingTranscriber.Failure.modelNotDownloaded }
                return Self.levelDetector
            },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        ))
        for _ in 0..<2 {
            queue.enqueue(folder)
            let done = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeFolder == nil }
            XCTAssertTrue(done)
        }
        var entries = try MeetingAttempt.entries(in: folder)
        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(entries.map(\.attempt?.result), [.complete, .failed])

        // The later attempt's clock an hour behind the earlier one's.
        var later = try XCTUnwrap(entries.last?.attempt)
        later.startedAt = try XCTUnwrap(entries.first?.attempt?.startedAt).addingTimeInterval(-3_600)
        try later.write(to: folder.appendingPathComponent(try XCTUnwrap(entries.last?.name)))
        entries = try MeetingAttempt.entries(in: folder)

        XCTAssertEqual(entries.last?.number, 2)
        XCTAssertEqual(entries.last?.attempt?.result, .failed)
    }

    /// A record this app cannot read, damaged or of a newer version, keeps
    /// its place among the attempts and is never written over; the next
    /// attempt is numbered after it.
    func testUnreadableRecordKeepsItsPlaceAndIsNotOverwritten() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        var first = MeetingAttempt(number: 1, startedAt: Date(timeIntervalSince1970: 1_760_000_000))
        first.result = .complete
        try first.write(to: folder.appendingPathComponent(MeetingAttempt.fileName(number: 1)))
        let damagedName = MeetingAttempt.fileName(number: 2)
        let damaged = Data("{\"version\": 1, \"number\": ".utf8)
        try damaged.write(to: folder.appendingPathComponent(damagedName))
        // A whole record but for its version: only the version keeps it out.
        let newerName = MeetingAttempt.fileName(number: 3)
        var later = first
        later.number = 3
        later.version = 99
        try later.write(to: folder.appendingPathComponent(newerName))
        let newer = try Data(contentsOf: folder.appendingPathComponent(newerName))
        let sameName = MeetingAttempt.fileName(number: 9)
        var same = later
        same.version = MeetingAttempt.formatVersion
        try same.write(to: root.appendingPathComponent(sameName))
        XCTAssertEqual(try MeetingAttempt.entries(in: root).first?.attempt, same, "this version's record does not read")
        try FileManager.default.removeItem(at: root.appendingPathComponent(sameName))

        var entries = try MeetingAttempt.entries(in: folder)
        XCTAssertEqual(entries.map(\.number), [1, 2, 3])
        XCTAssertEqual(entries.map { $0.attempt == nil }, [false, true, true])

        _ = try await transcribedThroughQueue(folder, replies: [0.1: "текст"])
        entries = try MeetingAttempt.entries(in: folder)
        XCTAssertEqual(entries.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(entries.last?.attempt?.result, .complete)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(damagedName)), damaged)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(newerName)), newer)
    }

    /// The meeting through the queue as a job takes it, to its outcome.
    private func transcribedThroughQueue(
        _ folder: URL, replies: [Float: String]
    ) async throws -> MeetingTranscriptionQueue {
        let queue = MeetingTranscriptionQueue(transcriber: makeTranscriber(factory: LevelEngineFactory(replies: replies)))
        queue.enqueue(folder)
        let done = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeFolder == nil }
        XCTAssertTrue(done, "the job never ended")
        return queue
    }

    // MARK: - Queue

    /// Speech found and the engine failing on its only chunk, below the
    /// three-in-a-row limit: a failure that says why, never "no speech
    /// found", which would tell the user the call was silent.
    func testSpeechThatNoChunkRecognizedIsAFailureNotSilence() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.4)], system: [])
        let factory = LevelEngineFactory(replies: [0.4: LevelEngine.failingReply])
        let queue = MeetingTranscriptionQueue(transcriber: makeTranscriber(factory: factory))

        queue.enqueue(folder)
        let done = await eventually(within: .seconds(10)) {
            queue.lastOutcome != nil && queue.activeFolder == nil
        }

        XCTAssertTrue(done)
        guard case .failed(let failed, let reason)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertEqual(failed.path, folder.path)
        let prefix = "Speech was found but not recognized (errors: 1): "
        XCTAssertTrue(reason.hasPrefix(prefix) && reason.count > prefix.count, reason)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".md") }, "\(names)")
    }

    func testSameFolderIsQueuedOnce() async throws {
        let first = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [], name: "a")
        let second = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [], name: "b")
        let jobs = Locked(0)
        let factory = LevelEngineFactory(replies: [0.1: "текст"], delay: .milliseconds(100))
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in jobs.set(jobs.get() + 1); return Self.levelDetector },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        )
        let queue = MeetingTranscriptionQueue(transcriber: transcriber)

        queue.enqueue(first)
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(second)
        queue.enqueue(first.appendingPathComponent("..").appendingPathComponent("a"))
        XCTAssertEqual(queue.pending.count, 1)

        let done = await eventually(within: .seconds(10)) {
            queue.activeFolder == nil && queue.pending.isEmpty
        }
        XCTAssertTrue(done)
        XCTAssertEqual(jobs.get(), 2)
        guard case .saved(let transcript)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertEqual(transcript.path, second.appendingPathComponent("transcript.md").path)
    }

    func testCancelDuringRecognitionLeavesNoFiles() async throws {
        let folder = try makeFolder(
            microphone: (0..<6).map { Region(start: Double($0) * 3 + 1, end: Double($0) * 3 + 2.5, level: 0.1) },
            system: []
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок"], delay: .milliseconds(200), log: log)
        let streamingBefore = streamingTemporaryFiles()
        let queue = MeetingTranscriptionQueue(transcriber: makeTranscriber(factory: factory))

        queue.enqueue(folder)
        // Two chunks already recognized: a user's cancel still writes nothing.
        let recognizing = await eventually(within: .seconds(10)) {
            log.all().filter { $0 == "end:кусок" }.count >= 2
        }
        XCTAssertTrue(recognizing)
        queue.cancelCurrent()
        let finished = await eventually(within: .seconds(10)) { queue.lastOutcome != nil }

        XCTAssertTrue(finished)
        XCTAssertEqual(queue.lastOutcome, .cancelled(folder: folder.standardizedFileURL))
        try assertNoTemporaryFiles(in: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["meeting"])
        XCTAssertEqual(streamingTemporaryFiles(), streamingBefore)
    }

    func testCancelDuringSpeechDetectionLeavesNoFiles() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let entered = Locked(false)
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let streamingBefore = streamingTemporaryFiles()
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in
                { _ in
                    entered.set(true)
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        )
        let queue = MeetingTranscriptionQueue(transcriber: transcriber)

        queue.enqueue(folder)
        let detecting = await eventually(within: .seconds(10)) { entered.get() }
        XCTAssertTrue(detecting)
        queue.cancelCurrent()
        let finished = await eventually(within: .seconds(10)) { queue.lastOutcome != nil }

        XCTAssertTrue(finished)
        XCTAssertEqual(queue.lastOutcome, .cancelled(folder: folder.standardizedFileURL))
        try assertNoTemporaryFiles(in: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["meeting"])
        XCTAssertEqual(streamingTemporaryFiles(), streamingBefore)
        let loads = await factory.totalLoads()
        XCTAssertEqual(loads, 0)
    }

    /// "Stop Transcription" is the person's choice, not a failure: the log
    /// says it at INFO, so a search for errors does not turn it up.
    func testStoppedTranscriptionIsLoggedAsInfoNotError() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let entered = Locked(false)
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: LevelEngineFactory(replies: [0.1: "текст"])),
            loadSpeechDetector: { _ in
                { _ in
                    entered.set(true)
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        )
        let queue = MeetingTranscriptionQueue(transcriber: transcriber)

        queue.enqueue(folder)
        let detecting = await eventually(within: .seconds(10)) { entered.get() }
        XCTAssertTrue(detecting)
        queue.cancelCurrent()
        let finished = await eventually(within: .seconds(10)) { queue.lastOutcome != nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(queue.lastOutcome, .cancelled(folder: folder.standardizedFileURL))
        let outcome = String(describing: try XCTUnwrap(queue.lastOutcome))
        func lines() -> [Substring] {
            ((try? String(contentsOf: AppLog.fileURL, encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { $0.contains(outcome) }
        }
        // The file log is written on its own queue.
        let logged = await eventually(within: .seconds(5)) { !lines().isEmpty }

        XCTAssertTrue(logged, "the stop is not in the log")
        XCTAssertEqual(lines().count, 1)
        XCTAssertTrue(lines().allSatisfy { $0.contains("[INFO] meeting-transcript:") }, "logged as \(lines())")
    }

    func testMissingSpeechModelFailsBeforeAnyWorkAndNamesThePath() async throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 3, level: 0.1)], system: [])
        let missing = root.appendingPathComponent("no-such-vad.mlmodelc").path
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let queue = MeetingTranscriptionQueue(transcriber: MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in try await MeetingTranscriber.sileroDetector(modelPath: missing) },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        ))

        queue.enqueue(folder)
        let finished = await eventually(within: .seconds(10)) { queue.lastOutcome != nil }

        XCTAssertTrue(finished)
        guard case .failed(_, let reason)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertTrue(reason.contains(missing), reason)
        let loads = await factory.totalLoads()
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["meeting"])
    }

    // MARK: - Folder

    func testMetadataWithoutEndedAtIsReadAndRecordingIsRejected() throws {
        let folder = try makeFolder(microphone: [Region(start: 1, end: 2, level: 0.1)], system: [])
        try Data("""
        {"sampleRate":48000,"segments":[{"frames":96000,"index":0,"mic":"microphone.caf","system":"system.caf"}],
         "startedAt":"2026-07-14T16:40:37Z","state":"done"}
        """.utf8).write(to: folder.appendingPathComponent("metadata.json"))

        let inspected = try MeetingTranscriber.Folder.inspect(folder)
        XCTAssertEqual(inspected.startedAt, ISO8601DateFormatter().date(from: "2026-07-14T16:40:37Z"))
        XCTAssertEqual(inspected.microphone?.lastPathComponent, "microphone.caf")
        XCTAssertEqual(inspected.system?.lastPathComponent, "system.caf")

        try Data(#"{"state":"recording","segments":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("metadata.json"))
        XCTAssertThrowsError(try MeetingTranscriber.Folder.inspect(folder)) {
            XCTAssertEqual($0 as? MeetingTranscriber.Failure, .stillRecording("meeting"))
        }
    }

    func testFolderWithoutTracksIsRejectedAndListedNamesStayInside() throws {
        let empty = root.appendingPathComponent("2026-08-27 10-31-15 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MeetingTranscriber.Folder.inspect(empty)) {
            XCTAssertEqual($0 as? MeetingTranscriber.Failure, .notAMeetingFolder(empty.lastPathComponent))
        }

        try writeTrack(root.appendingPathComponent("outside.caf"), rate: 48_000, duration: 1, regions: [])
        try writeTrack(empty.appendingPathComponent("system.caf"), rate: 48_000, duration: 1, regions: [])
        try Data(#"{"segments":[{"mic":"../outside.caf","system":"system.caf"}]}"#.utf8)
            .write(to: empty.appendingPathComponent("metadata.json"))
        let inspected = try MeetingTranscriber.Folder.inspect(empty)
        XCTAssertNil(inspected.microphone)
        XCTAssertEqual(inspected.system?.deletingLastPathComponent().lastPathComponent, empty.lastPathComponent)
        XCTAssertEqual(inspected.startedAt, MeetingTranscriber.Folder.date(fromFolderName: empty.lastPathComponent))
        XCTAssertNotNil(inspected.startedAt)
    }

    func testMeetingTakesTheDictationEngineAndLanguage() throws {
        var snapshot = SettingsSnapshot(
            dictationLanguage: "de",
            dictationEngine: .whisper,
            whisperModelPath: "/models/whisper-model",
            parakeetModelPath: "/models/parakeet-tdt-0.6b-v3"
        )
        let whisper = try MeetingTranscriber.Engine.forMeeting(snapshot)
        XCTAssertEqual(whisper.request, .whisper(WhisperDecodeRequest(language: "de")))
        XCTAssertEqual(whisper.label, "Whisper (whisper-model)")

        snapshot.dictationEngine = .parakeet
        let parakeet = try MeetingTranscriber.Engine.forMeeting(snapshot)
        XCTAssertEqual(parakeet.request, .parakeet("de"))
        XCTAssertEqual(parakeet.descriptor.modelPath, "/models/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(parakeet.label, "Parakeet (parakeet-tdt-0.6b-v3)")
    }

    // MARK: - Language on "auto": setting → meeting engine → requests

    /// "Auto" used to force a meeting into Russian. For Whisper it now means
    /// detect: chunks go on "auto" until the first one over 5 s, and every
    /// later chunk gets that chunk's language; the short replies on either
    /// side of it are recognized, not dropped.
    func testAutoMeetingOnWhisperFixesTheLanguageOfTheFirstLongChunk() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .whisper
        let folder = try makeFolder(
            microphone: [
                Region(start: 1.5, end: 2.5, level: 0.1),    // short, before the language is known
                Region(start: 4.5, end: 11, level: 0.2),     // 6.5 s: fixes it
                Region(start: 13.5, end: 14.2, level: 0.3),  // short, after
            ],
            system: [Region(start: 16.5, end: 19, level: 0.5)]
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "Ja genau", 0.2: "Guten Morgen, fangen wir an", 0.3: "Okay", 0.5: "Hallo zusammen"],
            // A short reply can come out as any language, which is why it
            // does not fix the meeting's.
            detected: [0.1: "en", 0.2: "de", 0.3: "nn", 0.5: "de"],
            log: log
        )

        let report = try await settingsTranscriber(settings, factory: factory)
            .transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(
            log.all().filter { $0.hasPrefix("asked:") },
            ["asked:auto", "asked:auto", "asked:de", "asked:de"]
        )
        XCTAssertEqual(report.lines.map(\.text), [
            "Ja genau", "Guten Morgen, fangen wir an", "Okay", "Hallo zusammen",
        ])
        let markdown = try String(contentsOf: try XCTUnwrap(report.transcript), encoding: .utf8)
        let german = try XCTUnwrap(Locale.current.localizedString(forLanguageCode: "de"))
        XCTAssertTrue(markdown.contains(german), markdown)
    }

    /// For Parakeet "ru" is a Cyrillic-only filter: a German call forced into
    /// it comes out as noise. "Auto" must reach the engine as no filter.
    func testAutoMeetingOnParakeetHasNoScriptFilter() throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet

        XCTAssertEqual(try MeetingTranscriber.Engine.forMeeting(settings.snapshot).request, .parakeet(nil))
    }

    func testMeetingWithoutALongChunkStaysOnAuto() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .whisper
        let folder = try makeFolder(
            microphone: [Region(start: 1.5, end: 4, level: 0.1), Region(start: 6.5, end: 10, level: 0.2)],
            system: [Region(start: 12.5, end: 13, level: 0.5)]
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "Hello there", 0.2: "Wie geht es", 0.5: "Gut"],
            detected: [0.1: "en", 0.2: "de", 0.5: "de"],
            log: log
        )

        let report = try await settingsTranscriber(settings, factory: factory)
            .transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(log.all().filter { $0.hasPrefix("asked:") }, ["asked:auto", "asked:auto", "asked:auto"])
        XCTAssertEqual(report.languages, ["en", "de"])
        XCTAssertNil(report.fixedLanguage)
    }

    func testChosenLanguageReachesEveryChunkOfAMeetingAndAFile() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "uk"
        let folder = try makeFolder(
            microphone: [Region(start: 1.5, end: 9, level: 0.1)],
            system: [Region(start: 11.5, end: 12.5, level: 0.5)]
        )
        let file = root.appendingPathComponent("lecture.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2, level: 0.2)])
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "Добрий день усім", 0.2: "лекція", 0.5: "Привіт"],
            detected: [0.1: "ru", 0.2: "ru", 0.5: "ru"],
            log: log
        )
        let transcriber = settingsTranscriber(settings, factory: factory)

        let report = try await transcriber.transcribe(try .inspect(folder)) { _ in }
        _ = try await transcriber.transcribeFile(file) { _ in }

        XCTAssertEqual(log.all().filter { $0.hasPrefix("asked:") }, ["asked:uk", "asked:uk", "asked:uk"])
        XCTAssertEqual(report.languages, ["uk"])
    }

    func testFileOnAutoFixesTheLanguageLikeAMeeting() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .whisper
        let file = root.appendingPathComponent("interview.caf")
        try writeTrack(file, rate: 44_100, duration: 15, regions: [
            Region(start: 1, end: 1.8, level: 0.1),
            Region(start: 3, end: 9, level: 0.2),
            Region(start: 11, end: 12, level: 0.3),
        ])
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "Sí", 0.2: "Buenos días a todos", 0.3: "Vale"],
            detected: [0.1: "pt", 0.2: "es", 0.3: "it"],
            log: log
        )

        let lines = try await settingsTranscriber(settings, factory: factory).transcribeFile(file) { _ in }

        XCTAssertEqual(lines.map(\.text), ["Sí Buenos días a todos", "Vale"])
        XCTAssertEqual(log.all().filter { $0.hasPrefix("asked:") }, ["asked:auto", "asked:auto", "asked:es"])
    }

    func testTranscriptHeaderNamesTheLanguagesUsed() throws {
        let folder = MeetingTranscriber.Folder(
            directory: root.appendingPathComponent("meeting"), startedAt: nil, microphone: nil, system: nil
        )
        var report = MeetingTranscriber.Report()
        report.engines = ["Parakeet (parakeet-tdt-0.6b-v3)"]
        report.languages = ["auto"]
        XCTAssertTrue(MeetingTranscriber.markdown(report, folder: folder).contains(
            "Engine: Parakeet (parakeet-tdt-0.6b-v3). Language: auto.\n"
        ))
        report.languages = ["en", "de"]
        let names = ["en", "de"].map(DictationEngine.languageName).joined(separator: ", ")
        XCTAssertTrue(MeetingTranscriber.markdown(report, folder: folder).contains(". Languages: \(names).\n"))
    }

    // MARK: - Echo and merging

    func testEchoIgnoresCaseAndPunctuationButKeepsOwnSpeechAndShortReplies() {
        let system = [utterance("Собеседник", "Ну что, ЁЛКИ, начнём отчёт? Да.", 10, 14)]
        let microphone = [
            utterance("Я", "ну что елки начнем отчет", 10.2, 13.5),
            utterance("Я", "да", 12, 12.5),
            utterance("Я", "я подготовил презентацию по продажам", 11, 14),
            utterance("Я", "ну что елки начнем отчет", 30, 33),
        ]

        let result = MeetingTranscriber.removingEcho(microphone: microphone, system: system)

        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.kept.map(\.text), [
            "да",
            "я подготовил презентацию по продажам",
            "ну что елки начнем отчет",
        ])
    }

    func testMergingJoinsShortPausesButCapsBlocksAtAMinute() {
        // Remote speakers answering each other without a pause, 10 s chunks.
        let remote = (0..<12).map { utterance("Собеседник", "реплика \($0)", Double($0) * 10.5, Double($0) * 10.5 + 10) }
        let own = utterance("Я", "вопрос", 200, 203)
        let afterPause = utterance("Я", "ещё вопрос", 206, 208)

        let lines = MeetingTranscriber.merged([own] + remote.reversed() + [afterPause])

        let blocks = lines.filter { $0.speaker == "Собеседник" }
        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertTrue(blocks.allSatisfy { $0.end - $0.start <= MeetingTranscriber.maximumBlockSeconds }, "\(blocks)")
        XCTAssertEqual(blocks.first?.text, "реплика 0 реплика 1 реплика 2 реплика 3 реплика 4")
        XCTAssertEqual(lines.suffix(2).map(\.text), ["вопрос", "ещё вопрос"])
        XCTAssertEqual(lines.map(\.start), lines.map(\.start).sorted())
    }

    /// A save that failed and then worked to another place leaves
    /// no stale "Couldn't save the file" next to "Saved as".
    func testSuccessfulSaveAfterAFailedOneClearsThatFailure() async throws {
        let places = Locked([
            root.appendingPathComponent("no-such-folder/talk.md"),
            root.appendingPathComponent("talk.md"),
        ])
        let files = FilesModel(
            transcription: { _ in { _, _ in [TranscriptSegment(speaker: "", text: "words")] } },
            saveDestination: { _, _ in
                let next = places.get().first
                places.set(Array(places.get().dropFirst()))
                return next
            }
        )
        files.select(root.appendingPathComponent("talk.wav"))
        files.start()
        let finished = await eventually(within: .seconds(10)) { !files.segments.isEmpty }
        XCTAssertTrue(finished)

        let first = await files.saveTranscript(owner: nil)
        XCTAssertFalse(first)
        XCTAssertNotNil(files.errorText, "the failed save must be told")
        let second = await files.saveTranscript(owner: nil)

        XCTAssertTrue(second)
        XCTAssertEqual(files.savedAs, "talk.md")
        XCTAssertNil(files.errorText, "a save that worked still shows the earlier failure")
    }

    // MARK: - Personal dictionary: settings → transcriber

    /// The transcriber as production builds it, the dictionary included.
    private func dictionaryTranscriber(
        _ settings: SettingsStore,
        factory: LevelEngineFactory,
        engine: @escaping @Sendable () -> MeetingTranscriber.Engine = { MeetingTranscriptionTests.engine("/models/whisper") }
    ) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in Self.levelDetector },
            currentEngine: { _ in engine() },
            temporaryRoot: root,
            dictionary: MeetingTranscriber.dictionary(of: settings)
        )
    }

    /// Echo removal counts words, so it sees the tracks as recognized: a
    /// replacement 3 → 2 words would keep an echo, 2 → 3 would drop a short
    /// reply. A phrase split between two chunks of one speaker is found once
    /// they are merged. The recognized tracks stay as they were.
    func testDictionaryAppliesAfterEchoRemovalAndMerging() async throws {
        let settings = try isolatedSettings()
        try settings.saveDictionary([
            DictionaryEntry(heard: ["клод код"], written: "ClaudeCode"),
            DictionaryEntry(heard: ["гитхаб"], written: "Git Hub"),
        ])
        let folder = try makeFolder(
            microphone: [
                Region(start: 1.5, end: 3, level: 0.1),      // echo, 3 words → 2
                Region(start: 6.5, end: 7.3, level: 0.2),    // short reply, 2 words → 3
                Region(start: 10.5, end: 11.5, level: 0.3),  // "…клод"
                Region(start: 12, end: 13, level: 0.4),      // "код…"
            ],
            system: [
                Region(start: 1, end: 3.5, level: 0.5),
                Region(start: 6, end: 8, level: 0.6),
            ]
        )
        let factory = LevelEngineFactory(replies: [
            0.1: "клод код ок", 0.2: "гитхаб да", 0.3: "смотри клод", 0.4: "код готов",
            0.5: "Клод код ок, понятно.", 0.6: "Гитхаб да, конечно.",
        ])

        let report = try await dictionaryTranscriber(settings, factory: factory)
            .transcribe(try .inspect(folder)) { _ in }

        XCTAssertEqual(report.echoRemoved, 1)
        XCTAssertEqual(report.lines.map(\.speaker), ["Others", "Others", "Me", "Me"])
        XCTAssertEqual(report.lines.map(\.text), [
            "ClaudeCode ок, понятно.", "Git Hub да, конечно.", "Git Hub да", "смотри ClaudeCode готов",
        ])
        XCTAssertEqual(report.microphone.map(\.text), ["клод код ок", "гитхаб да", "смотри клод", "код готов"])
        XCTAssertEqual(report.system.map(\.text), ["Клод код ок, понятно.", "Гитхаб да, конечно."])
        let markdown = try transcript(in: folder)
        XCTAssertTrue(markdown.contains("**Me:** смотри ClaudeCode готов"), markdown)
        XCTAssertTrue(markdown.contains("Echo lines removed from the microphone: 1"), markdown)
    }

    /// The dictionary is read once, at the start: an edit during the job
    /// reaches the next one. The engine is still read before every chunk.
    func testMeetingKeepsTheDictionaryItStartedWithWhileTheEngineFollowsTheSettings() async throws {
        let settings = try isolatedSettings()
        try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        let folder = try makeFolder(
            microphone: (0..<3).map { Region(start: Double($0) * 3 + 1, end: Double($0) * 3 + 2.5, level: 0.1) },
            system: (0..<3).map { Region(start: Double($0) * 3 + 11, end: Double($0) * 3 + 12.5, level: 0.5) }
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "клод код", 0.5: "Клод код."], delay: .milliseconds(100), log: log
        )
        let first = Self.engine("/models/a")
        let second = Self.engine("/models/b")
        let selected = Locked(first)
        let transcriber = dictionaryTranscriber(settings, factory: factory) { selected.get() }
        let job = Task { try await transcriber.transcribe(try .inspect(folder)) { _ in } }
        defer { job.cancel() }

        let started = await eventually(within: .seconds(10)) { log.all().contains("end:клод код") }
        XCTAssertTrue(started)
        try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude")])
        selected.set(second)
        let report = try await job.value

        XCTAssertEqual(report.lines.map(\.text), [
            "Claude Code Claude Code Claude Code", "Claude Code. Claude Code. Claude Code.",
        ])
        XCTAssertEqual(report.engines, [first.label, second.label])
        let next = root.appendingPathComponent("next.caf")
        try writeTrack(next, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.1)])
        let lines = try await transcriber.transcribeFile(next) { _ in }
        XCTAssertEqual(lines.map(\.text), ["Claude"])
    }

    /// A job takes the dictionary as it starts, before the speech model has
    /// loaded: an edit made during the load reaches the next job, for a
    /// meeting and for a file alike.
    func testDictionaryIsTakenBeforeTheSpeechModelLoads() async throws {
        let settings = try isolatedSettings()
        let loading = Locked(Gate())
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: LevelEngineFactory(replies: [0.1: "клод код"])),
            loadSpeechDetector: { _ in
                try await loading.get().pass()
                return Self.levelDetector
            },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root,
            dictionary: MeetingTranscriber.dictionary(of: settings)
        )
        /// The job with the dictionary edited while its speech model loads, then the next one.
        func edited(_ job: @escaping @Sendable () async throws -> [String]) async throws -> (current: [String], next: [String]) {
            try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
            let gate = Gate()
            loading.set(gate)
            let current = Task { try await job() }
            let entered = await eventually(within: .seconds(10)) { gate.wasEntered }
            XCTAssertTrue(entered)
            try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude")])
            gate.open()
            return (try await current.value, try await job())
        }
        let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [])
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.1)])

        let meeting = try await edited { try await transcriber.transcribe(try .inspect(folder)) { _ in }.lines.map(\.text) }
        let files = try await edited { try await transcriber.transcribeFile(file) { _ in }.map(\.text) }

        XCTAssertEqual(meeting.current, ["Claude Code"])
        XCTAssertEqual(meeting.next, ["Claude"])
        XCTAssertEqual(files.current, ["Claude Code"])
        XCTAssertEqual(files.next, ["Claude"])
    }

    /// "Meetings" and "Files" are switches of their own.
    func testMeetingsAndFilesFollowTheirOwnSwitches() async throws {
        try MacOSRussianWordForms.require()
        let settings = try isolatedSettings()
        try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        let factory = LevelEngineFactory(replies: [0.1: "у клода кода"])
        let transcriber = dictionaryTranscriber(settings, factory: factory)
        let file = root.appendingPathComponent("memo.caf")
        try writeTrack(file, rate: 48_000, duration: 4, regions: [Region(start: 1, end: 2.5, level: 0.1)])
        func meeting(_ name: String) async throws -> [String] {
            let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: name)
            return try await transcriber.transcribe(try .inspect(folder)) { _ in }.lines.map(\.text)
        }

        settings.dictionaryInMeetings = false
        let meetingOff = try await meeting("off")
        let fileOn = try await transcriber.transcribeFile(file) { _ in }.map(\.text)
        settings.dictionaryInMeetings = true
        settings.dictionaryInFiles = false
        let meetingOn = try await meeting("on")
        let fileOff = try await transcriber.transcribeFile(file) { _ in }.map(\.text)

        XCTAssertEqual(meetingOff, ["у клода кода"])
        XCTAssertEqual(fileOn, ["у Claude Code"])
        XCTAssertEqual(meetingOn, ["у Claude Code"])
        XCTAssertEqual(fileOff, ["у клода кода"])
    }

    /// What a broken run brings back is replaced like a whole result.
    func testCutShortAndIncompleteResultsAreReplacedToo() async throws {
        let settings = try isolatedSettings()
        try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        let factory = LevelEngineFactory(replies: [
            0.1: "клод код один", 0.4: LevelEngine.failingReply, 0.3: "клод код после",
        ])
        let transcriber = dictionaryTranscriber(settings, factory: factory)

        let gap = root.appendingPathComponent("gap.caf")
        try writeTrack(gap, rate: 48_000, duration: 8, regions: [
            Region(start: 1, end: 2, level: 0.1), Region(start: 4, end: 5, level: 0.4),
        ])
        do {
            _ = try await transcriber.transcribeFile(gap) { _ in }
            XCTFail("a gap must not pass for a whole transcript")
        } catch {
            guard case .incompleteFile? = error as? MeetingTranscriber.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(linesCarried(by: error), ["Claude Code один"])
        }

        let cut = root.appendingPathComponent("cut.caf")
        try writeTrack(cut, rate: 48_000, duration: 15, regions: [
            Region(start: 1.5, end: 2.5, level: 0.1), Region(start: 4.5, end: 5.5, level: 0.4),
            Region(start: 7.5, end: 8.5, level: 0.4), Region(start: 10.5, end: 11.5, level: 0.4),
            Region(start: 13.5, end: 14.5, level: 0.3),
        ])
        do {
            _ = try await transcriber.transcribeFile(cut) { _ in }
            XCTFail("a run cut short must not pass for a whole transcript")
        } catch {
            guard case .fileCutShort? = error as? MeetingTranscriber.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(linesCarried(by: error), ["Claude Code один"])
        }

        let folder = try makeFolder(
            microphone: [
                Region(start: 1.5, end: 3, level: 0.1), Region(start: 4.5, end: 6, level: 0.4),
                Region(start: 7.5, end: 9, level: 0.4), Region(start: 10.5, end: 12, level: 0.4),
            ],
            system: [Region(start: 20.5, end: 22, level: 0.3)]
        )
        let report = try await transcriber.transcribe(try .inspect(folder)) { _ in }
        XCTAssertNotNil(report.interruption)
        XCTAssertEqual(report.lines.map(\.text), ["Claude Code один"])
        XCTAssertEqual(report.microphone.map(\.text), ["клод код один"])
    }

    // MARK: - Transcribing again: a choice over the settings → queue → engine

    /// Settings on Parakeet/Russian, a meeting asked for in Whisper/English:
    /// every chunk of both tracks goes to Whisper in English, and settings
    /// changed in the middle move nothing. The header names what was used. A
    /// job without a choice still follows the settings.
    func testChosenEngineAndLanguageReachEveryChunkThroughTheQueue() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let folder = try makeFolder(
            microphone: (0..<3).map { Region(start: Double($0) * 3 + 1, end: Double($0) * 3 + 2.5, level: 0.1) },
            system: (0..<3).map { Region(start: Double($0) * 3 + 11, end: Double($0) * 3 + 12.5, level: 0.5) }
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "кусок", 0.5: "ответ"], detected: [0.1: "ru", 0.5: "ru"], delay: .milliseconds(100), log: log
        )
        let queue = try liveQueue(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))

        queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
        let midway = await eventually(within: .seconds(10)) { log.all().contains("end:кусок") }
        XCTAssertTrue(midway)
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "de"
        let done = await eventually(within: .seconds(20)) { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(Self.engineCalls(log), Array(repeating: "whisper:en", count: 6))
        guard case .saved(let transcript)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        let model = URL(fileURLWithPath: SettingsStore.defaultWhisperModel).lastPathComponent
        let markdown = try String(contentsOf: transcript, encoding: .utf8)
        XCTAssertTrue(markdown.contains(
            "Engine: Whisper (\(model)). Language: \(DictationEngine.languageName("en")).\n"
        ), markdown)

        let next = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "next")
        queue.enqueue(next)
        let followed = await eventually(within: .seconds(10)) { queue.finishedJobs == 2 }
        XCTAssertTrue(followed)
        XCTAssertEqual(Self.engineCalls(log).last, "whisper:de")
    }

    /// A dictation in the middle of a job with another engine goes through
    /// the coordinator with its own engine and language, from the snapshot
    /// taken as it started: settings changed while it records reach neither
    /// it nor the job, whose next chunks keep the job's choice. The job waits
    /// at a gate between its two tracks, so the dictation falls between them.
    func testDictationDuringAChosenJobKeepsItsOwnEngineAndTheJobKeepsItsChoice() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let folder = try makeFolder(
            microphone: (0..<3).map { Region(start: Double($0) * 3 + 1, end: Double($0) * 3 + 2.5, level: 0.1) },
            system: (0..<3).map { Region(start: Double($0) * 3 + 11, end: Double($0) * 3 + 12.5, level: 0.5) }
        )
        let template = root.appendingPathComponent("dictation.caf")
        try writeTrack(template, rate: 48_000, duration: 2, regions: [Region(start: 0.2, end: 1.8, level: 0.9)])
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "кусок", 0.5: "ответ", 0.9: "диктовка"], detected: [0.1: "en", 0.5: "en", 0.9: "ru"], log: log
        )
        let cache = WhisperKitCache(factory: factory, parakeetFactory: factory)
        let secondTrack = Gate()
        let tracks = Locked(0)
        let queue = try liveQueue(settings, cache: cache, speechDetector: { _ in
            { source in
                tracks.set(tracks.get() + 1)
                if tracks.get() == 2 { try await secondTrack.pass() }
                return try await Self.levelDetector(source)
            }
        })
        let delivered = Locked<[String]>([])
        let dictation = DictationCoordinator(
            mic: HistoryPipelineMic(template: template),
            indicator: RecordingIndicator(renderingEnabled: false),
            startTimeout: 5,
            whisperCache: cache,
            historyStore: DictationHistoryStore(root: root.appendingPathComponent("Dictations", isDirectory: true)),
            deliveryOverride: { text, _ in delivered.set(delivered.get() + [text]) },
            frontmostApplication: { nil },
            feedbackPlayer: { _ in },
            beepPlayer: {}
        )
        dictation.configureForTesting(settings: settings)

        queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
        let between = await eventually(within: .seconds(10)) { secondTrack.wasEntered }
        XCTAssertTrue(between)
        dictation.beginCaptureForTesting()
        try await waitForDictation { dictation.state == .recording }
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "de"
        dictation.toggle()
        try await waitForDictation(timeout: .seconds(20)) { dictation.state == .idle }
        secondTrack.open()
        let done = await eventually(within: .seconds(20)) { queue.lastOutcome != nil && queue.activeFolder == nil }

        XCTAssertTrue(done)
        XCTAssertEqual(delivered.get(), ["диктовка"])
        XCTAssertEqual(
            Self.engineCalls(log),
            ["whisper:en", "whisper:en", "whisper:en", "parakeet:ru", "whisper:en", "whisper:en", "whisper:en"]
        )
        guard case .saved(let transcript)? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("**Others:** ответ"))
    }

    /// Old meetings, the ones transcribed again, are almost all compressed: a
    /// second run on m4a tracks scaled for ALAC hears them at their level,
    /// writes `transcript 2.md` and its copy, and leaves the first transcript
    /// and its copy byte for byte. A copy name already taken is refused and
    /// reported; the new transcript stays.
    func testSecondTranscriptionOfACompressedMeetingLeavesTheFirstAndItsCopy() async throws {
        let settings = try isolatedSettings()
        let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let name = "2026-10-14 10-00-00 Meeting"
        // Louder than full scale: compression scales it down and keeps the gain.
        let folder = try makeFolder(
            microphone: [Region(start: 1, end: 3, level: 1.6)],
            system: [Region(start: 4, end: 6, level: 0.5)],
            name: "Meetings/\(name)"
        ).standardizedFileURL
        try writeFinishedMetadata(in: folder)
        let factory = LevelEngineFactory(replies: [1.6: "громко", 1: "тише", 0.5: "собеседник"])
        let queue = try liveQueue(
            settings,
            cache: WhisperKitCache(factory: factory, parakeetFactory: factory),
            meetingsRoot: meetings,
            destinations: { .init(meetings: nil, transcripts: notes) }
        )

        queue.enqueue(folder)
        let first = await eventually(within: .seconds(20)) { queue.finishedJobs == 1 }
        XCTAssertTrue(first)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains("microphone.m4a") && !names.contains("microphone.caf"), "\(names)")
        let metadata = try String(contentsOf: folder.appendingPathComponent("metadata.json"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("micGain"), metadata)
        let transcript = folder.appendingPathComponent("transcript.md")
        let copy = notes.appendingPathComponent("\(name).md")
        let (firstText, firstCopy) = (try Data(contentsOf: transcript), try Data(contentsOf: copy))

        queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
        let second = await eventually(within: .seconds(20)) { queue.finishedJobs == 2 }
        XCTAssertTrue(second)
        let again = folder.appendingPathComponent("transcript 2.md")
        let againText = try String(contentsOf: again, encoding: .utf8)
        XCTAssertTrue(againText.contains("**Me:** громко"), againText)
        XCTAssertTrue(againText.contains("Engine: Whisper"), againText)
        XCTAssertEqual(try Data(contentsOf: notes.appendingPathComponent("\(name) 2.md")), try Data(contentsOf: again))
        XCTAssertEqual(try Data(contentsOf: transcript), firstText)
        XCTAssertEqual(try Data(contentsOf: copy), firstCopy)

        let taken = notes.appendingPathComponent("\(name) 3.md")
        let note = Data("моя заметка\n".utf8)
        try note.write(to: taken)
        queue.enqueue(folder, choice: .init(engine: .parakeet, language: "ru"))
        let third = await eventually(within: .seconds(20)) { queue.finishedJobs == 3 }
        XCTAssertTrue(third)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript 3.md").path))
        XCTAssertEqual(try Data(contentsOf: taken), note)
        XCTAssertNotNil(queue.issues[folder]?.transcriptCopy)
        XCTAssertEqual(queue.lastOutcome?.transcript?.lastPathComponent, "transcript 3.md")
    }

    /// The table of `enqueue`, row by row. A job leaves `pending` and becomes
    /// active at once, and its task cannot run before this test awaits, so
    /// each state is set up exactly; then the queue runs and the engine log
    /// says which job reached the engine with which choice.
    func testQueueKeepsEveryChoiceOnceAndInOrder() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let english = SettingsSnapshot.Choice(engine: .whisper, language: "en")
        let german = SettingsSnapshot.Choice(engine: .whisper, language: "de")
        let folders = try ["a", "b", "c", "d", "e"].map { name in
            try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: name)
                .standardizedFileURL
        }
        let (a, b, c, d, e) = (folders[0], folders[1], folders[2], folders[3], folders[4])
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let queue = try liveQueue(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        typealias Job = MeetingTranscriptionQueue.Job

        queue.enqueue(a, transcribe: false)
        XCTAssertEqual(queue.activeJob?.withoutIdentity, Job(folder: a, transcribe: false))
        queue.enqueue(a, choice: english)       // under way without a transcription: queued after it
        queue.enqueue(a, choice: english)       // the same choice waiting
        queue.enqueue(a)                        // a transcription is waiting
        queue.enqueue(a, transcribe: false)     // a scan never erases the choice
        queue.enqueue(a, choice: german)        // another choice: a job of its own
        queue.enqueue(a, choice: german)        // found past the first, other choice
        queue.enqueue(b, transcribe: false)
        queue.enqueue(b, choice: english)       // a waiting scan takes the choice
        queue.enqueue(c)
        queue.enqueue(c, choice: german)        // a waiting automatic one takes it: one transcription
        queue.enqueue(c)
        XCTAssertEqual(queue.pending.map(\.withoutIdentity), [
            Job(folder: a, transcribe: true, choice: english),
            Job(folder: a, transcribe: true, choice: german),
            Job(folder: b, transcribe: true, choice: english),
            Job(folder: c, transcribe: true, choice: german),
        ])
        let drained = await eventually(within: .seconds(20)) { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertTrue(drained)
        XCTAssertEqual(Self.engineCalls(log), ["whisper:en", "whisper:de", "whisper:en", "whisper:de"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("transcript 2.md").path))

        queue.enqueue(d)
        XCTAssertEqual(queue.activeJob?.withoutIdentity, Job(folder: d, transcribe: true))
        queue.enqueue(d)                        // transcribing already
        queue.enqueue(d, choice: english)       // under way as the settings say: a job of its own
        queue.enqueue(d, choice: english)
        XCTAssertEqual(queue.activeJob?.choice, nil, "the job under way was changed")
        XCTAssertEqual(queue.pending.map(\.withoutIdentity), [Job(folder: d, transcribe: true, choice: english)])
        let second = await eventually(within: .seconds(20)) { queue.activeJob == nil && queue.pending.isEmpty }
        XCTAssertTrue(second)

        queue.enqueue(e, choice: german)
        queue.enqueue(e, choice: german)        // the same choice under way
        queue.enqueue(e)
        queue.enqueue(e, transcribe: false)
        XCTAssertEqual(queue.activeJob?.withoutIdentity, Job(folder: e, transcribe: true, choice: german))
        XCTAssertEqual(queue.pending.map(\.withoutIdentity), [])
        let third = await eventually(within: .seconds(20)) { queue.activeJob == nil }
        XCTAssertTrue(third)
        XCTAssertEqual(Self.engineCalls(log).suffix(3), ["parakeet:ru", "whisper:en", "whisper:de"])
    }

    /// The choice belongs to the job, not to the path: jobs queued while an
    /// earlier one moves the meeting run where it went, each with its own
    /// choice, and name that place from the move on. A request for the new
    /// place then finds them, under way or waiting, and only another choice
    /// adds a job.
    func testChoiceGoesWithTheJobWhenTheMeetingMoves() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let name = "2026-10-14 11-00-00 Meeting"
        let folder = try makeFolder(
            microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "Meetings/\(name)"
        ).standardizedFileURL
        try writeFinishedMetadata(in: folder)
        let moved = archive.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let (english, german, french) = (
            SettingsSnapshot.Choice(engine: .whisper, language: "en"),
            SettingsSnapshot.Choice(engine: .whisper, language: "de"),
            SettingsSnapshot.Choice(engine: .whisper, language: "fr")
        )
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let second = Gate()
        let jobs = Locked(0)
        let queue = try liveQueue(
            settings,
            cache: WhisperKitCache(factory: factory, parakeetFactory: factory),
            meetingsRoot: meetings,
            destinations: { .init(meetings: archive, transcripts: nil) }
        ) { _ in
            jobs.set(jobs.get() + 1)
            if jobs.get() == 2 { try await second.pass() }
            return Self.levelDetector
        }
        typealias Job = MeetingTranscriptionQueue.Job

        queue.enqueue(folder)
        queue.enqueue(folder, choice: english)
        queue.enqueue(folder, choice: german)
        let held = await eventually(within: .seconds(20)) { second.wasEntered }
        XCTAssertTrue(held, "the first job did not finish and move the meeting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        // The jobs name the folder there by its own identity, not the one
        // the meeting had before the move.
        let there = try XCTUnwrap(MeetingStorage.address(of: moved)?.identity)
        XCTAssertEqual(queue.activeJob, Job(folder: moved, transcribe: true, choice: english, identity: there))
        XCTAssertEqual(queue.pending, [Job(folder: moved, transcribe: true, choice: german, identity: there)])
        queue.enqueue(moved, choice: english)   // under way
        queue.enqueue(moved, choice: german)    // waiting
        queue.enqueue(moved, choice: french)
        queue.enqueue(moved, choice: french)
        // Asked for outside the local root, the new job learns its folder
        // off the main actor.
        let told = await eventually(within: .seconds(5)) { queue.pending.allSatisfy { $0.identity != nil } }
        XCTAssertTrue(told, "the job queued for the archive never learned its folder")
        XCTAssertEqual(queue.pending, [
            Job(folder: moved, transcribe: true, choice: german, identity: there),
            Job(folder: moved, transcribe: true, choice: french, identity: there),
        ])
        second.open()
        let done = await eventually(within: .seconds(20)) { queue.finishedJobs == 4 }

        XCTAssertTrue(done)
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:ru", "whisper:en", "whisper:de", "whisper:fr"])
        let names = try FileManager.default.contentsOfDirectory(atPath: moved.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(names.sorted(), ["transcript 2.md", "transcript 3.md", "transcript 4.md", "transcript.md"])
        let again = try String(contentsOf: moved.appendingPathComponent("transcript 2.md"), encoding: .utf8)
        XCTAssertTrue(again.contains("Engine: Whisper"), again)
        XCTAssertEqual(queue.lastOutcome?.transcript?.deletingLastPathComponent().standardizedFileURL, moved)
    }

    /// "Transcribe Again…" opens the panel inside the last outcome's
    /// meeting, which a transcript names by its local path although the
    /// meeting has moved on since.
    func testTranscribeAgainOpensInTheMeetingWhereverItIs() async throws {
        let settings = try isolatedSettings()
        let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let name = "2026-10-14 12-00-00 Meeting"
        let folder = try makeFolder(
            microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "Meetings/\(name)"
        ).standardizedFileURL
        try writeFinishedMetadata(in: folder)
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let queue = try liveQueue(
            settings,
            cache: WhisperKitCache(factory: factory, parakeetFactory: factory),
            meetingsRoot: meetings,
            destinations: { .init(meetings: archive, transcripts: nil) }
        )
        XCTAssertNil(queue.lastMeeting)

        queue.enqueue(folder)
        let done = await eventually(within: .seconds(20)) { queue.finishedJobs == 1 }

        XCTAssertTrue(done)
        XCTAssertEqual(queue.lastOutcome, .saved(folder.appendingPathComponent("transcript.md")))
        XCTAssertEqual(queue.lastMeeting, archive.appendingPathComponent(name, isDirectory: true))
    }

    /// Whether a variant's Russian word forms match follows the job's
    /// language, not the dictation's: settings on Russian with a meeting
    /// chosen in English leave a word form alone, settings on English with a
    /// meeting on Auto replace it. An exact spelling is replaced either way,
    /// and the meetings switch still turns every replacement off.
    func testDictionaryWordFormsFollowTheJobsLanguage() async throws {
        try MacOSRussianWordForms.require()
        let settings = try isolatedSettings()
        try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        let factory = LevelEngineFactory(replies: [0.1: "у клода кода", 0.5: "клод код"])
        let queue = try liveQueue(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        func transcribe(_ name: String, settings language: String, choice: String) async throws -> [String] {
            settings.dictationEngine = .parakeet
            settings.dictationLanguage = language
            let folder = try makeFolder(
                microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [Region(start: 4, end: 5.5, level: 0.5)],
                name: name
            )
            let finished = queue.finishedJobs
            queue.enqueue(folder, choice: .init(engine: .parakeet, language: choice))
            let done = await eventually(within: .seconds(10)) { queue.finishedJobs == finished + 1 }
            XCTAssertTrue(done)
            guard case .saved(let transcript)? = queue.lastOutcome else {
                XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
                return []
            }
            return try String(contentsOf: transcript, encoding: .utf8)
                .split(separator: "\n").filter { $0.contains("**") }.map { String($0.split(separator: " ", maxSplits: 2)[2]) }
        }

        let english = try await transcribe("english", settings: "ru", choice: "en")
        let auto = try await transcribe("auto", settings: "en", choice: "auto")
        settings.dictionaryInMeetings = false
        let off = try await transcribe("off", settings: "en", choice: "auto")

        XCTAssertEqual(english, ["у клода кода", "Claude Code"])
        XCTAssertEqual(auto, ["у Claude Code", "Claude Code"])
        XCTAssertEqual(off, ["у клода кода", "клод код"])
    }

    /// The model checked is the job's engine's, with what it needs besides:
    /// the chosen engine missing refuses the job before any audio is read,
    /// the settings' engine missing does not stop a job chosen with another,
    /// and a model removed after the job was queued is found missing as it
    /// starts.
    func testModelCheckFollowsTheJobsEngine() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let detections = Locked(0)
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let whisper = SettingsSnapshot.Choice(engine: .whisper, language: "en")
        /// The folder and what came of its job.
        func run(
            _ name: String, models: [ModelSource], removing removed: ModelSource? = nil
        ) async throws -> (folder: URL, outcome: MeetingTranscriptionQueue.Outcome?) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Models"))
            let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: name)
                .standardizedFileURL
            let installed = try installedModels(models)
            let queue = MeetingTranscriptionQueue(transcriber: .live(
                settings: settings,
                models: installed,
                cache: WhisperKitCache(factory: factory, parakeetFactory: factory),
                speechDetector: { _ in detections.set(detections.get() + 1); return Self.levelDetector }
            ))
            queue.enqueue(folder, choice: whisper)
            // Queued and under way, but its task has not run yet.
            if let removed {
                try FileManager.default.removeItem(at: installed.root.appendingPathComponent(removed.destination))
            }
            let done = await eventually(within: .seconds(10)) { queue.lastOutcome != nil && queue.activeJob == nil }
            XCTAssertTrue(done)
            return (folder, queue.lastOutcome)
        }
        let refusal = MeetingTranscriber.Failure.modelNotDownloaded.localizedDescription

        for refused in [
            try await run("chosen missing", models: [.parakeet, .vad]),
            try await run("tokenizer missing", models: [.parakeet, .whisper, .vad]),
            try await run("removed", models: [.parakeet, .whisper, .whisperTokenizer, .vad], removing: .whisper),
        ] {
            XCTAssertEqual(refused.outcome, .failed(folder: refused.folder, reason: refusal), refused.folder.lastPathComponent)
        }
        XCTAssertEqual(detections.get(), 0, "audio was read for a job whose model is missing")
        XCTAssertEqual(Self.engineCalls(log), [])

        let saved = try await run("settings missing", models: [.whisper, .whisperTokenizer, .vad])
        let transcript = saved.folder.appendingPathComponent("transcript.md")
        XCTAssertEqual(saved.outcome, .saved(transcript))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertEqual(detections.get(), 1)
        XCTAssertEqual(Self.engineCalls(log), ["whisper:en"])
    }

    /// The panel's language list keeps the code as picked and shows it by
    /// the settings' rule: Auto while the engine does not know it, the code
    /// again once the engine does. The job gets what is shown.
    func testPanelShowsTheLanguageByTheSettingsRule() {
        let draft = MeetingTranscriptionQueue.ChoiceDraft(SettingsSnapshot(dictationLanguage: "kk", dictationEngine: .parakeet))
        XCTAssertEqual(draft.shownLanguage, "auto")
        XCTAssertEqual(draft.choice, SettingsSnapshot.Choice(engine: .parakeet, language: "auto"))

        draft.engine = .whisper
        XCTAssertEqual(draft.shownLanguage, "kk")
        XCTAssertEqual(draft.choice.language, "kk")
        draft.engine = .parakeet
        XCTAssertEqual(draft.language, "kk", "a change of engine lost the code")

        draft.shownLanguage = "de"
        XCTAssertEqual(draft.choice, SettingsSnapshot.Choice(engine: .parakeet, language: "de"))
        draft.shownLanguage = "auto"
        draft.engine = .whisper
        XCTAssertEqual(draft.choice, SettingsSnapshot.Choice(engine: .whisper, language: "auto"))
    }

    /// Transcribe Meeting… opens the folder panel with this transcription's
    /// engine and language below the folders, from the settings as the
    /// panel opens; Cancel queues nothing, Transcribe the folder with the
    /// choice made there, which is what the engine is asked for. The panel
    /// is the test's: a test process never opens AppKit's.
    func testTranscribeMeetingOffersTheEngineAndLanguage() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path))
        let settings = SettingsStore(defaults: defaults)
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "auto"
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let models = try installedModels()
        let queue = try liveQueue(settings, models: models, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        let opened = OpenedPanel()
        queue.chooseFolder(settings: settings.snapshot, models: models, show: { panel, completion in
            opened.panel = panel
            opened.completion = completion
        })
        let shown = await eventually(within: .seconds(5)) { opened.panel != nil }
        XCTAssertTrue(shown, "no folder panel was asked for")
        let panel = try XCTUnwrap(opened.panel)
        XCTAssertTrue(panel.canChooseDirectories && !panel.canChooseFiles)
        XCTAssertNotNil(panel.accessoryView, "the panel shows no engine and language")
        XCTAssertTrue(panel.isAccessoryViewDisclosed)
        let draft = try XCTUnwrap(panel.delegate as? MeetingTranscriptionQueue.ChoiceDraft)
        XCTAssertEqual(draft.engine, .whisper, "the panel does not show the settings' engine")
        XCTAssertEqual(draft.shownLanguage, "auto")
        // Cancel calls nothing back.
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertNil(queue.activeJob)

        // Another engine and language than the settings', picked in the panel.
        draft.engine = .parakeet
        draft.shownLanguage = "de"
        opened.completion?(try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "chosen"))
        let done = await eventually(within: .seconds(10)) { queue.finishedJobs == 1 }
        XCTAssertTrue(done)
        XCTAssertNotNil(queue.lastOutcome?.transcript, "Transcribe queued nothing")
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:de"], "the engine was not asked for the panel's choice")
        XCTAssertEqual(settings.dictationEngine, .whisper, "the panel's choice reached the settings")
        XCTAssertEqual(settings.dictationLanguage, "auto", "the panel's choice reached the settings")
    }

    /// The panel takes its accessory's size as it opens and never changes it
    /// (live pass, 2026-10-14: picking a missing engine afterwards cut the
    /// pickers off at the top and the note at the bottom). Opened with
    /// everything there, it must hold each state that can come later: the
    /// download button, the download, its failure. Each is measured on an
    /// accessory built anew in it, what that state needs.
    func testPanelHoldsWhatComesAfterItOpened() async throws {
        let installed = try installedModels([.parakeet, .vad])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnavailableHub.self]
        let models = ModelDownloader(
            root: installed.root,
            session: URLSession(configuration: configuration),
            host: try XCTUnwrap(URL(string: "https://hub.invalid"))
        )
        let draft = MeetingTranscriptionQueue.ChoiceDraft(
            SettingsSnapshot(dictationLanguage: "auto", dictationEngine: .parakeet), models: models
        )
        let opened = MeetingTranscriptionQueue.choiceAccessory(draft, models: models).frame.size
        func assertHeld(_ state: String, line: UInt = #line) {
            let needed = MeetingTranscriptionQueue.choiceAccessory(draft, models: models).fittingSize
            XCTAssertLessThanOrEqual(needed.height, opened.height, "\(state) is cut off", line: line)
            XCTAssertLessThanOrEqual(needed.width, opened.width, "\(state) is cut off", line: line)
        }

        draft.engine = .whisper
        XCTAssertFalse(models.missing(.whisper).isEmpty)
        assertHeld("the download button")

        models.start(.whisper)
        XCTAssertEqual(models.download?.engine, .whisper)
        assertHeld("the download")

        let failed = await eventually(within: .seconds(10)) { models.failure != nil }
        XCTAssertTrue(failed, "the download did not fail")
        XCTAssertEqual(models.failure?.engine, .whisper)
        XCTAssertNil(models.download)
        assertHeld("the failure under the button")

        draft.engine = .parakeet
        assertHeld("the model in place again")
    }

    // MARK: - Transcribing again: the dictation's engine comes first

    /// Neither a panel left with Cancel, nor a job with a choice, nor one
    /// that fails, touches the settings: not one publication of the engine
    /// or the language, not one write to their defaults, so not even a
    /// change undone afterwards. The watchers do see a real change.
    func testAChoiceNeverTouchesTheSettings() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path))
        let settings = SettingsStore(defaults: defaults)
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let before = settings.snapshot
        let published = Locked<[String]>([])
        let watched = [
            settings.$dictationEngine.dropFirst().sink { value in published.set(published.get() + ["\(value)"]) },
            settings.$dictationLanguage.dropFirst().sink { value in published.set(published.get() + [value]) },
        ]
        let writes = Locked(0)
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in writes.set(writes.get() + 1) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let models = try installedModels()
        let queue = try liveQueue(settings, models: models, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        let english = SettingsSnapshot.Choice(engine: .whisper, language: "en")

        let cancelled = MeetingTranscriptionQueue.ChoiceDraft(settings.snapshot)
        cancelled.engine = .whisper
        cancelled.shownLanguage = "en"
        queue.enqueue(try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "done"),
                      choice: english)
        let done = await eventually(within: .seconds(10)) { queue.finishedJobs == 1 }
        XCTAssertTrue(done)
        XCTAssertNotNil(queue.lastOutcome?.transcript)
        try FileManager.default.removeItem(at: models.root.appendingPathComponent(ModelSource.whisper.destination))
        queue.enqueue(try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "failed"),
                      choice: english)
        let failed = await eventually(within: .seconds(10)) { queue.finishedJobs == 2 }
        XCTAssertTrue(failed)
        guard case .failed? = queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: queue.lastOutcome))")
        }
        // The dictation's engine is prepared again after each: it only reads them.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(published.get(), [])
        XCTAssertEqual(writes.get(), 0)
        XCTAssertEqual(settings.snapshot, before)
        settings.dictationLanguage = "de"
        XCTAssertEqual(published.get(), ["de"], "the watcher sees nothing at all")
        let seen = await eventually(within: .seconds(2)) { writes.get() > 0 }
        XCTAssertTrue(seen, "the defaults watcher sees nothing at all")
        _ = watched
    }

    /// The dictation keeps its engine: a job in another engine leaves the
    /// cache alone while the dictation records, is recognized and for the
    /// hold after it, says it waits, and goes on after. Quit and an update
    /// see the waiting job.
    func testJobInAnotherEngineWaitsWhileTheDictationHoldsItsEngine() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок", 0.9: "диктовка"], log: log)
        let joint = try dictationJoint(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory),
                                       engineHold: .seconds(2))
        let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [])
        let busy = Locked(false)
        let library = MeetingLibrary(recorder: joint.recorder, queue: joint.queue, settings: settings)
        let updates = AppUpdater.busy(
            meeting: joint.recorder, dictation: joint.dictation, transcripts: joint.queue,
            files: FilesModel(transcription: { _ in { _, _ in [] } }), library: library
        ).sink { busy.set($0) }
        defer { updates.cancel() }
        let delegate = AppDelegate()
        delegate.attach(dictation: joint.dictation, meeting: joint.recorder, settings: settings)

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        joint.queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
        let waiting = await eventually(within: .seconds(10)) { joint.queue.step == .waitingForEngine }
        XCTAssertTrue(waiting)
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }

        // The dictation is over and holds its engine a while longer.
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:ru"])
        XCTAssertEqual(joint.queue.step, .waitingForEngine)
        XCTAssertTrue(joint.queue.isTranscribing)
        XCTAssertTrue(busy.get(), "an update would not wait for the job")
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "quit would not warn about the job")
        let done = await eventually(within: .seconds(10)) { joint.queue.lastOutcome != nil }

        XCTAssertTrue(done)
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:ru", "whisper:en"])
        XCTAssertNotNil(joint.queue.lastOutcome?.transcript)
    }

    /// A job in the dictation's own engine never waits: the cache serves
    /// them one request at a time already.
    func testJobInTheDictationsEngineNeverWaits() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок", 0.9: "диктовка"], log: log)
        let joint = try dictationJoint(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [])
        let steps = Locked<[MeetingTranscriber.Step?]>([])
        let watched = joint.queue.$step.sink { step in steps.set(steps.get() + [step]) }
        defer { watched.cancel() }

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        joint.queue.enqueue(folder, choice: .init(engine: .parakeet, language: "en"))
        let done = await eventually(within: .seconds(10)) { joint.queue.lastOutcome != nil }

        XCTAssertTrue(done)
        XCTAssertEqual(joint.dictation.state, .recording)
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:en"])
        XCTAssertFalse(steps.get().contains(.waitingForEngine), "\(steps.get())")
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }
    }

    /// Stopping the job while it waits for the dictation stops it at once,
    /// without a request to the engine.
    func testCancelWhileWaitingForTheDictationEndsTheJob() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок", 0.9: "диктовка"], log: log)
        let joint = try dictationJoint(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: []).standardizedFileURL

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        joint.queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
        let waiting = await eventually(within: .seconds(10)) { joint.queue.step == .waitingForEngine }
        XCTAssertTrue(waiting)
        let clock = ContinuousClock()
        let asked = clock.now
        joint.queue.cancelCurrent()
        let stopped = await eventually(within: .seconds(5)) { joint.queue.lastOutcome != nil }

        XCTAssertTrue(stopped)
        XCTAssertLessThan(asked.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(joint.queue.lastOutcome, .cancelled(folder: folder))
        XCTAssertEqual(Self.engineCalls(log), [])
        XCTAssertEqual(joint.dictation.state, .recording)
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }
    }

    /// The hold: nothing before the first dictation, the engine of the
    /// dictation's own snapshot while it records, and the settings' engine
    /// for 30 s after it ends, not a moment longer.
    func testDictationHoldsItsEngineForThirtySecondsAfterItEnds() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let factory = LevelEngineFactory(replies: [0.9: "диктовка"])
        let joint = try dictationJoint(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory))
        let parakeet = settings.snapshot.dictationDescriptor
        XCTAssertNil(joint.dictation.heldEngine(), "a fresh launch holds an engine")

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        settings.dictationEngine = .whisper
        XCTAssertEqual(joint.dictation.heldEngine(), parakeet, "not the engine the dictation records for")
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }

        let ended = ContinuousClock.now
        XCTAssertEqual(joint.dictation.heldEngine(at: ended + .seconds(29)), settings.snapshot.dictationDescriptor)
        XCTAssertNil(joint.dictation.heldEngine(at: ended + .seconds(30)))
    }

    /// After a job in its own engine the cache holds the dictation's again,
    /// by the dictation's own warm-up, its model being there and nothing
    /// coming after. Two such jobs in a row load each model once more: the
    /// dictation's waits for the last.
    func testDictationEngineIsBackAfterAChosenJob() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let cache = WhisperKitCache(factory: factory, parakeetFactory: factory)
        let joint = try dictationJoint(settings, cache: cache, warmsUp: true)
        try await warmedUp(cache, to: settings)
        let english = SettingsSnapshot.Choice(engine: .whisper, language: "en")

        for name in ["first", "second"] {
            joint.queue.enqueue(
                try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: name),
                choice: english
            )
        }
        let done = await eventually(within: .seconds(10)) { joint.queue.finishedJobs == 2 }
        XCTAssertTrue(done)
        try await warmedUp(cache, to: settings)

        XCTAssertEqual(Self.engineCalls(log), ["whisper:en", "whisper:en"])
        let whisper = await factory.loadCount(SettingsStore.defaultWhisperModel)
        let parakeet = await factory.loadCount(SettingsStore.defaultParakeetModel)
        XCTAssertEqual(whisper, 1, "the second job loaded Whisper again")
        XCTAssertEqual(parakeet, 2, "Parakeet came back more than once, or not at all")
    }

    /// The return waits for the end of the series, whatever its last job:
    /// a job with a choice, then one as the settings say that finds no
    /// speech and never asks for an engine, still end with the dictation's.
    func testDictationEngineGoesBackAfterASeriesWhateverItsLastJob() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let cache = WhisperKitCache(factory: factory, parakeetFactory: factory)
        let joint = try dictationJoint(
            settings, cache: cache, warmsUp: true, destinations: { .init(meetings: nil, transcripts: notes) }
        )
        try await warmedUp(cache, to: settings)
        let chosen = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "chosen")
            .standardizedFileURL
        let silent = try makeFolder(microphone: [], system: [], name: "silent").standardizedFileURL

        joint.queue.enqueue(chosen, choice: .init(engine: .whisper, language: "en"))
        joint.queue.enqueue(silent)
        let done = await eventually(within: .seconds(10)) { joint.queue.finishedJobs == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(joint.queue.lastOutcome, .noSpeech(folder: silent))
        try await warmedUp(cache, to: settings)

        let parakeet = await factory.loadCount(SettingsStore.defaultParakeetModel)
        XCTAssertEqual(parakeet, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.appendingPathComponent("transcript.md").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: notes.path), ["chosen Meeting.md"])
    }

    /// A dictation recording keeps its engine to its end: settings changed
    /// meanwhile and a job in that same engine finishing meanwhile load
    /// nothing new until the dictation has been recognized; then the new
    /// choice of the settings is warmed up.
    func testDictationEngineGoesBackOnlyOnceTheDictationEnds() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "кусок", 0.9: "диктовка"], log: log)
        let cache = WhisperKitCache(factory: factory, parakeetFactory: factory)
        let joint = try dictationJoint(settings, cache: cache, warmsUp: true)
        try await warmedUp(cache, to: settings)

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        settings.dictationEngine = .whisper
        joint.queue.enqueue(
            try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: []),
            choice: .init(engine: .parakeet, language: "en")
        )
        let done = await eventually(within: .seconds(10)) { joint.queue.finishedJobs == 1 }
        XCTAssertTrue(done)
        try await Task.sleep(for: .milliseconds(300))
        let early = await factory.loadCount(SettingsStore.defaultWhisperModel)
        XCTAssertEqual(early, 0, "Whisper was loaded while the dictation still recorded for Parakeet")
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }
        try await warmedUp(cache, to: settings)

        XCTAssertEqual(Self.engineCalls(log), ["parakeet:en", "parakeet:ru"])
        let whisper = await factory.loadCount(SettingsStore.defaultWhisperModel)
        XCTAssertEqual(whisper, 1)
    }

    /// The return is the dictation's own warm-up, under its generation: a
    /// change of the settings while it loads cancels it, and the newer
    /// choice is what the cache ends with.
    func testALaterChoiceOfTheSettingsWinsOverTheReturn() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let parakeet = RefusingParakeetFactory(holds: true)
        let cache = WhisperKitCache(factory: LevelEngineFactory(replies: [0.1: "текст"]), parakeetFactory: parakeet)
        let joint = try dictationJoint(settings, cache: cache, warmsUp: true)
        try await warmedUp(cache, to: settings)

        joint.queue.enqueue(
            try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: []),
            choice: .init(engine: .whisper, language: "en")
        )
        let returning = await eventually(within: .seconds(10)) { await parakeet.isHolding() }
        XCTAssertTrue(returning, "the dictation's engine was never asked back")
        settings.dictationEngine = .whisper
        let cancelled = await eventually(within: .seconds(5)) { await parakeet.wasCancelled() }
        XCTAssertTrue(cancelled, "the older return was not cancelled")
        try await warmedUp(cache, to: settings)
        try await Task.sleep(for: .milliseconds(300))

        let resident = await cache.residentDescriptorForTesting()
        XCTAssertEqual(resident, settings.snapshot.dictationDescriptor)
        XCTAssertNotNil(joint.queue.lastOutcome?.transcript)
    }

    /// Without the dictation's model, the meeting in another engine is
    /// transcribed and copied all the same, and nothing is loaded after it.
    func testChosenJobWithoutTheDictationsModelIsSavedAndCopied() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let cache = WhisperKitCache(factory: factory, parakeetFactory: factory)
        let joint = try dictationJoint(
            settings, cache: cache, models: try installedModels([.whisper, .whisperTokenizer, .vad]), warmsUp: true,
            destinations: { .init(meetings: nil, transcripts: notes) }
        )
        let folder = try makeFolder(microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [])

        joint.queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
        let done = await eventually(within: .seconds(10)) { joint.queue.finishedJobs == 1 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(done)
        guard case .saved? = joint.queue.lastOutcome else {
            return XCTFail("unexpected outcome \(String(describing: joint.queue.lastOutcome))")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: notes.path), ["meeting Meeting.md"])
        let loads = await factory.loadCount(SettingsStore.defaultParakeetModel)
        XCTAssertEqual(loads, 0)
        let resident = await cache.residentDescriptorForTesting()
        XCTAssertEqual(resident?.engine, .whisper)
    }

    /// The dictation's engine failing to load after the job, or its load
    /// cancelled, changes nothing of the meeting: saved, copied, no issue.
    /// The failure is the dictation's own, as any warm-up's.
    func testDictationEngineFailingAfterTheJobLeavesTheMeetingSaved() async throws {
        for cancels in [false, true] {
            let settings = try isolatedSettings()
            settings.dictationEngine = .parakeet
            let notes = root.appendingPathComponent("Notes \(cancels)", isDirectory: true)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            let parakeet = RefusingParakeetFactory(holds: cancels)
            let cache = WhisperKitCache(factory: LevelEngineFactory(replies: [0.1: "текст"]), parakeetFactory: parakeet)
            let joint = try dictationJoint(
                settings, cache: cache, warmsUp: true, destinations: { .init(meetings: nil, transcripts: notes) }
            )
            try await warmedUp(cache, to: settings)
            let folder = try makeFolder(
                microphone: [Region(start: 1, end: 2.5, level: 0.1)], system: [], name: "meeting \(cancels)"
            ).standardizedFileURL

            joint.queue.enqueue(folder, choice: .init(engine: .whisper, language: "en"))
            let tried = await eventually(within: .seconds(10)) { await parakeet.attempts() == 2 }
            XCTAssertTrue(tried, "the dictation's engine was never asked back")
            if cancels {
                let loading = await eventually(within: .seconds(5)) { await parakeet.isHolding() }
                XCTAssertTrue(loading)
                await cache.release()
                let ended = await eventually(within: .seconds(5)) { await parakeet.wasCancelled() }
                XCTAssertTrue(ended, "the load was not cancelled")
            } else {
                let failed = await eventually(within: .seconds(5)) { joint.dictation.modelFailure != nil }
                XCTAssertTrue(failed, "the warm-up's failure is not the dictation's")
            }
            let finished = await eventually(within: .seconds(10)) { joint.queue.activeJob == nil }

            XCTAssertTrue(finished)
            XCTAssertEqual(joint.queue.lastOutcome, .saved(folder.appendingPathComponent("transcript.md")))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: notes.path), ["meeting \(cancels) Meeting.md"])
            XCTAssertNil(joint.queue.issues[folder])
        }
    }

    // MARK: - Files tab: a choice of its own → FilesModel.live → engine

    /// Settings on Parakeet/Russian, the tab on Whisper/English: every chunk
    /// of the file goes to Whisper in English, and neither the settings nor
    /// the tab's menu changed in the middle move the run. As the dictation
    /// (no choice), a run follows the settings chunk by chunk.
    func testFilesChoiceReachesEveryChunkAndAsDictationFollowsTheSettings() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let log = EngineLog()
        let factory = LevelEngineFactory(
            replies: [0.1: "раз", 0.3: "два", 0.5: "три"], delay: .milliseconds(300), log: log
        )
        let files = try liveFiles(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory)).files
        files.select(try speechFile(levels: [0.1, 0.3, 0.5]))

        files.choice = .init(engine: .whisper, language: "en")
        files.start()
        let midway = await eventually(within: .seconds(10)) { log.all().contains("start:раз") }
        XCTAssertTrue(midway)
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "de"
        files.choice = .init(engine: .parakeet, language: "de")
        let chosen = await eventually(within: .seconds(20)) { !files.isTranscribing }

        XCTAssertTrue(chosen)
        XCTAssertNil(files.errorText)
        XCTAssertEqual(files.segments.map(\.text), ["раз", "два", "три"])
        XCTAssertEqual(Self.engineCalls(log), Array(repeating: "whisper:en", count: 3))

        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        files.choice = nil
        files.start()
        files.replace(with: try XCTUnwrap(files.pendingReplacement))
        let following = await eventually(within: .seconds(10)) { log.all().filter { $0 == "start:раз" }.count == 2 }
        XCTAssertTrue(following)
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "de"
        let followed = await eventually(within: .seconds(20)) { !files.isTranscribing }

        XCTAssertTrue(followed)
        XCTAssertEqual(Self.engineCalls(log).dropFirst(3), ["parakeet:ru", "whisper:de", "whisper:de"])
    }

    /// The model asked for is the run's engine's, with its tokenizer and the
    /// VAD: a run in a model that is not there is refused before the question
    /// about the text, says which model, reads no audio and leaves the text;
    /// the settings' engine missing does not stop a run chosen in another;
    /// and a model removed while the save panel is up refuses the run after
    /// the save, the text staying.
    func testFilesRunInAModelThatIsNotThereIsRefusedBeforeAnything() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let detections = Locked(0)
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let whisper = SettingsSnapshot.Choice(engine: .whisper, language: "en")
        let refusal = FilesModel.ModelMissing(engine: .whisper).localizedDescription
        let file = try speechFile(levels: [0.1])
        /// A tab whose models folder holds `models`, showing the unsaved
        /// text of a first run in `first` when one is given.
        func tab(
            _ models: [ModelSource],
            first: SettingsSnapshot.Choice?? = nil,
            saveDestination: @escaping FilesModel.SaveDestination = { _, _ in nil }
        ) async throws -> (files: FilesModel, models: ModelDownloader) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Models"))
            let installed = try installedModels(models)
            let files = try liveFiles(
                settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory), models: installed,
                saveDestination: saveDestination,
                speechDetector: { _ in detections.set(detections.get() + 1); return Self.levelDetector }
            ).files
            files.select(file)
            if let first {
                files.choice = first
                await transcribeInFiles(files)
                XCTAssertEqual(files.segments.map(\.text), ["текст"])
            }
            return (files, installed)
        }

        for models in [
            [ModelSource.parakeet, .vad],
            [.parakeet, .whisper, .vad],
        ] {
            let refused = try await tab(models, first: .some(nil))
            let (detected, calls) = (detections.get(), Self.engineCalls(log))
            refused.files.choice = whisper
            refused.files.start()

            XCTAssertNil(refused.files.pendingReplacement, "asked about the text of a run that cannot start")
            XCTAssertFalse(refused.files.isTranscribing)
            XCTAssertEqual(refused.files.errorText, refusal)
            XCTAssertEqual(refused.files.segments.map(\.text), ["текст"])
            XCTAssertTrue(refused.files.hasUnsavedText)
            XCTAssertEqual(detections.get(), detected, "audio was read for a run whose model is missing")
            XCTAssertEqual(Self.engineCalls(log), calls)
        }

        let withoutVAD = try await tab([.parakeet, .whisper, .whisperTokenizer])
        withoutVAD.files.start()
        XCTAssertEqual(withoutVAD.files.errorText, FilesModel.ModelMissing(engine: .parakeet).localizedDescription)
        withoutVAD.files.choice = whisper
        withoutVAD.files.start()
        XCTAssertEqual(withoutVAD.files.errorText, refusal)
        XCTAssertFalse(withoutVAD.files.isTranscribing)

        let settingsMissing = try await tab([.whisper, .whisperTokenizer, .vad], first: .some(whisper))
        XCTAssertNil(settingsMissing.files.errorText)
        XCTAssertEqual(Self.engineCalls(log).last, "whisper:en")

        let target = root.appendingPathComponent("saved.md")
        let panel = Gate()
        let going = try await tab([.parakeet, .whisper, .whisperTokenizer, .vad], first: .some(whisper), saveDestination: { _, _ in
            try? await panel.pass()
            return target
        })
        let calls = Self.engineCalls(log)
        going.files.start()
        let question = try XCTUnwrap(going.files.pendingReplacement)
        let replacing = Task { await going.files.saveThenReplace(question, owner: nil) }
        let asked = await eventually(within: .seconds(10)) { panel.wasEntered }
        XCTAssertTrue(asked)
        try FileManager.default.removeItem(at: going.models.root.appendingPathComponent(ModelSource.whisper.destination))
        panel.open()
        await replacing.value

        XCTAssertFalse(going.files.isTranscribing)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).hasSuffix("\n\nтекст"))
        XCTAssertEqual(going.files.segments.map(\.text), ["текст"])
        XCTAssertEqual(going.files.savedAs, "saved.md")
        XCTAssertEqual(going.files.errorText, refusal)
        XCTAssertEqual(Self.engineCalls(log), calls)
    }

    /// A run asked for over unsaved text keeps the choice it was asked in
    /// through the question: neither the menu nor the settings changed
    /// before "Replace" or while the save panel is up change it, while a run
    /// as the dictation follows the settings as they are when it starts. No
    /// run comes of a cancelled panel or a failed save, and a new file over
    /// the text only takes the file.
    func testRunAskedForOverTheTextKeepsItsChoiceThroughTheQuestion() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let save = Locked<URL?>(nil)
        let panel = Locked<Gate?>(nil)
        let files = try liveFiles(
            settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory),
            saveDestination: { _, _ in
                if let gate = panel.get() { try? await gate.pass() }
                return save.get()
            }
        ).files
        files.select(try speechFile(levels: [0.1]))
        await transcribeInFiles(files)
        /// Asks for a run over the text, lets `meanwhile` happen while the
        /// save panel is up, and saves to `target`, or cancels without one.
        func saveThenRerun(to target: URL?, meanwhile: () -> Void) async throws {
            let gate = Gate()
            panel.set(gate)
            save.set(target)
            files.start()
            let question = try XCTUnwrap(files.pendingReplacement)
            let replacing = Task { await files.saveThenReplace(question, owner: nil) }
            let asked = await eventually(within: .seconds(10)) { gate.wasEntered }
            XCTAssertTrue(asked)
            meanwhile()
            gate.open()
            await replacing.value
            let done = await eventually(within: .seconds(10)) { !files.isTranscribing }
            XCTAssertTrue(done)
        }

        files.choice = .init(engine: .whisper, language: "en")
        files.start()
        let replaced = try XCTUnwrap(files.pendingReplacement)
        XCTAssertEqual(replaced.action, .rerun(.init(engine: .whisper, language: "en")))
        files.choice = .init(engine: .parakeet, language: "de")
        settings.dictationLanguage = "uk"
        files.replace(with: replaced)
        let done = await eventually(within: .seconds(10)) { !files.isTranscribing }
        XCTAssertTrue(done)
        XCTAssertEqual(Self.engineCalls(log).last, "whisper:en")

        files.choice = .init(engine: .parakeet, language: "de")
        try await saveThenRerun(to: root.appendingPathComponent("first.md")) {
            files.choice = nil
            settings.dictationEngine = .whisper
            settings.dictationLanguage = "en"
        }
        XCTAssertEqual(Self.engineCalls(log).last, "parakeet:de")

        files.choice = nil
        try await saveThenRerun(to: root.appendingPathComponent("second.md")) {
            files.choice = .init(engine: .parakeet, language: "de")
            settings.dictationEngine = .whisper
            settings.dictationLanguage = "uk"
        }
        XCTAssertEqual(Self.engineCalls(log).last, "whisper:uk", "a run as the dictation took the settings of the question")
        XCTAssertEqual(Self.engineCalls(log).count, 4)

        try await saveThenRerun(to: nil) {}
        try await saveThenRerun(to: root.appendingPathComponent("no-such-folder/third.md")) {}
        XCTAssertEqual(Self.engineCalls(log).count, 4, "a run came of a cancelled panel or a failed save")
        XCTAssertTrue(files.hasUnsavedText)

        let other = try speechFile("other.caf", levels: [0.1])
        files.select(other)
        let picked = try XCTUnwrap(files.pendingReplacement)
        XCTAssertEqual(picked.action, .file(other))
        files.replace(with: picked)
        XCTAssertEqual(files.fileURL, other)
        XCTAssertFalse(files.isTranscribing)
        XCTAssertEqual(files.choice, .init(engine: .parakeet, language: "de"))
        XCTAssertEqual(Self.engineCalls(log).count, 4)
    }

    /// The dictionary's word forms follow the run's language, as for a
    /// meeting: a file chosen in English is not bent by the Russian tagger
    /// while the settings say Russian, one on Auto is. An exact spelling is
    /// replaced either way, and the Files switch turns it all off.
    func testFilesDictionaryWordFormsFollowTheRunsLanguage() async throws {
        try MacOSRussianWordForms.require()
        let settings = try isolatedSettings()
        try settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        let factory = LevelEngineFactory(replies: [0.1: "у клода кода", 0.5: "клод код"])
        let files = try liveFiles(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory)).files
        files.select(try speechFile(levels: [0.1, 0.5]))
        func transcribe(settings language: String, choice: String) async -> [String] {
            settings.dictationEngine = .parakeet
            settings.dictationLanguage = language
            files.choice = .init(engine: .parakeet, language: choice)
            await transcribeInFiles(files)
            return files.segments.map(\.text)
        }

        let english = await transcribe(settings: "ru", choice: "en")
        let auto = await transcribe(settings: "en", choice: "auto")
        settings.dictionaryInFiles = false
        let off = await transcribe(settings: "en", choice: "auto")

        XCTAssertEqual(english, ["у клода кода", "Claude Code"])
        XCTAssertEqual(auto, ["у Claude Code", "Claude Code"])
        XCTAssertEqual(off, ["у клода кода", "клод код"])
    }

    /// A run in another engine than the dictation's waits while the
    /// dictation records, is recognized and holds its engine, says so, and
    /// counts as running all along, for quit and updates; then it goes on.
    /// Stopped while it waits, it ends at once with no request.
    func testFilesRunInAnotherEngineWaitsForTheDictation() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст", 0.9: "диктовка"], log: log)
        let joint = try liveFiles(
            settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory), engineHold: .seconds(2)
        )
        let files = joint.files
        files.select(try speechFile(levels: [0.1]))
        files.choice = .init(engine: .whisper, language: "en")

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        files.start()
        let waiting = await eventually(within: .seconds(10)) { files.status == "Waiting for the engine…" }
        XCTAssertTrue(waiting)
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }

        XCTAssertEqual(Self.engineCalls(log), ["parakeet:ru"])
        XCTAssertEqual(files.status, "Waiting for the engine…")
        XCTAssertTrue(files.isTranscribing)
        XCTAssertEqual(files.quitLosses, [.fileTranscription])
        let done = await eventually(within: .seconds(10)) { !files.isTranscribing }
        XCTAssertTrue(done)
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:ru", "whisper:en"])
        XCTAssertEqual(files.segments.map(\.text), ["текст"])

        joint.dictation.beginCaptureForTesting()
        try await waitForDictation { joint.dictation.state == .recording }
        files.start()
        files.replace(with: try XCTUnwrap(files.pendingReplacement))
        let waitingAgain = await eventually(within: .seconds(10)) { files.status == "Waiting for the engine…" }
        XCTAssertTrue(waitingAgain)
        let clock = ContinuousClock()
        let asked = clock.now
        files.cancel()
        let stopped = await eventually(within: .seconds(5)) { !files.isTranscribing }

        XCTAssertTrue(stopped)
        XCTAssertLessThan(asked.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(files.status, "Cancelled.")
        XCTAssertEqual(Self.engineCalls(log), ["parakeet:ru", "whisper:en"])
        XCTAssertEqual(joint.dictation.state, .recording)
        joint.dictation.toggle()
        try await waitForDictation(timeout: .seconds(10)) { joint.dictation.state == .idle }
    }

    /// After a run with a choice the cache holds the dictation's engine
    /// again, by the dictation's own warm-up; a run as the dictation loads
    /// nothing more.
    func testDictationEngineIsBackAfterAChosenFilesRun() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        let log = EngineLog()
        let factory = LevelEngineFactory(replies: [0.1: "текст"], log: log)
        let cache = WhisperKitCache(factory: factory, parakeetFactory: factory)
        let files = try liveFiles(settings, cache: cache, warmsUp: true).files
        try await warmedUp(cache, to: settings)
        files.select(try speechFile(levels: [0.1]))

        files.choice = .init(engine: .whisper, language: "en")
        await transcribeInFiles(files)
        try await warmedUp(cache, to: settings)
        files.choice = nil
        await transcribeInFiles(files)

        XCTAssertEqual(Self.engineCalls(log), ["whisper:en", "parakeet:auto"])
        let whisper = await factory.loadCount(SettingsStore.defaultWhisperModel)
        let parakeet = await factory.loadCount(SettingsStore.defaultParakeetModel)
        XCTAssertEqual(whisper, 1)
        XCTAssertEqual(parakeet, 2, "Parakeet came back more than once, or not at all")
    }

    /// The dictation's engine failing to come back after the run changes
    /// nothing of the run's text, whole or cut short: the failure is the
    /// dictation's, as any warm-up's.
    func testDictationEngineFailingAfterAFilesRunLeavesItsText() async throws {
        for (replies, lines, status) in [
            ([Float(0.1): "Первая фраза", 0.5: "Вторая фраза"], ["Первая фраза", "Вторая фраза"], "Done — 2 lines."),
            ([0.1: "Первая фраза", 0.5: LevelEngine.lostEngineReply], ["Первая фраза"], "Stopped partway — 1 line."),
        ] {
            let settings = try isolatedSettings()
            settings.dictationEngine = .parakeet
            let parakeet = RefusingParakeetFactory(holds: false)
            let cache = WhisperKitCache(factory: LevelEngineFactory(replies: replies), parakeetFactory: parakeet)
            let joint = try liveFiles(settings, cache: cache, warmsUp: true)
            try await warmedUp(cache, to: settings)
            joint.files.select(try speechFile(levels: [0.1, 0.5]))

            joint.files.choice = .init(engine: .whisper, language: "en")
            await transcribeInFiles(joint.files)
            let failed = await eventually(within: .seconds(5)) { joint.dictation.modelFailure != nil }

            XCTAssertTrue(failed, "the dictation's engine was never asked back")
            let attempts = await parakeet.attempts()
            XCTAssertEqual(attempts, 2)
            XCTAssertNil(joint.files.errorText)
            XCTAssertEqual(joint.files.segments.map(\.text).filter { !$0.hasPrefix("⚠︎") }, lines)
            XCTAssertEqual(joint.files.status, status)
            XCTAssertTrue(joint.files.hasUnsavedText)
        }
    }

    /// The tab's menu as AppKit gets it: "As Dictation" with the settings'
    /// engine and language (a code the engine does not know shows Auto),
    /// checked while the tab follows them; each engine a submenu, one not
    /// downloaded marked so, with Auto and every language. An item sets
    /// engine and language together, "As Dictation" goes back to following,
    /// and the label tells following apart from the same pick by hand.
    /// The window has one width, and with the chosen engine's model missing
    /// the tab must fit in it: nothing shortened to "…" (live pass,
    /// 2026-10-14: the state beside the menu and the download button came
    /// out as "Whis…", in Russian as "…" alone). By the tab's ideal width, in
    /// English; Russian is looked at by eye. Each view is built anew in its
    /// state.
    func testFilesTabFitsTheWindowWhileTheModelIsMissing() throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .whisper
        let models = try installedModels([.parakeet, .vad])
        let files = FilesModel(transcription: { _ in { _, _ in [] } })
        let width = SettingsChrome.windowWidth - SettingsChrome.sidebarWidth - 1   // and the divider
        func assertFits(_ state: String, line: UInt = #line) {
            let tab = NSHostingView(rootView: ContentView()
                .environmentObject(settings)
                .environmentObject(models)
                .environmentObject(files))
            XCTAssertLessThanOrEqual(tab.fittingSize.width, width, "\(state) does not fit", line: line)
        }

        XCTAssertFalse(models.missing(.whisper).isEmpty)
        assertFits("As Dictation with Whisper missing")
        files.choice = .init(engine: .whisper, language: "en")
        assertFits("Whisper picked by hand and missing")
    }

    func testFilesMenuSetsTheChoiceAndTheLabelTellsAsDictationApart() async throws {
        let settings = try isolatedSettings()
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "kk"
        let models = try installedModels([.parakeet, .vad])
        let factory = LevelEngineFactory(replies: [:])
        let files = try liveFiles(settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory), models: models).files
        let menu = NSHostingMenu(rootView: FilesChoiceMenu(files: files, settings: settings, models: models))
        /// The items, separators left out, once SwiftUI has built them.
        func items(of menu: NSMenu, atLeast count: Int) async throws -> [NSMenuItem] {
            for _ in 0..<100 {
                menu.update()
                if menu.items.filter({ !$0.isSeparatorItem }).count >= count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            return menu.items.filter { !$0.isSeparatorItem }
        }
        let english = try XCTUnwrap(DictationEngine.whisper.languageChoices.first { $0.code == "en" }?.name)

        let top = try await items(of: menu, atLeast: 3)
        XCTAssertEqual(top.map(\.title), ["As Dictation (Parakeet · Auto)", "Whisper · not downloaded", "Parakeet"])
        XCTAssertEqual(top.first?.state, .on)
        let whisper = try XCTUnwrap(top.first { $0.title.hasPrefix("Whisper") }?.submenu)
        let languages = try await items(of: whisper, atLeast: DictationEngine.whisper.languages.count + 1)
        XCTAssertEqual(languages.map(\.title), ["Auto"] + DictationEngine.whisper.languageChoices.map(\.name))
        XCTAssertEqual(FilesChoiceMenu.label(of: nil, settings: settings.snapshot), "As Dictation · Parakeet · Auto")

        whisper.performActionForItem(at: try XCTUnwrap(whisper.items.firstIndex { $0.title == english }))
        let picked = await eventually(within: .seconds(2)) { files.choice == .init(engine: .whisper, language: "en") }
        XCTAssertTrue(picked, "the item set \(String(describing: files.choice))")
        XCTAssertEqual(FilesChoiceMenu.label(of: files.choice, settings: settings.snapshot), "Whisper · \(english)")
        /// "As Dictation" by its title: a menu may hold items it does not show.
        func asDictation() throws -> Int {
            menu.update()
            return try XCTUnwrap(
                menu.items.firstIndex { $0.title.hasPrefix("As Dictation") }, "no “As Dictation” in \(menu.items)"
            )
        }
        let unchecked = await eventually(within: .seconds(2)) {
            (try? asDictation()).map { menu.items[$0].state == .off } ?? false
        }
        XCTAssertTrue(unchecked, "“As Dictation” stayed checked")

        menu.performActionForItem(at: try asDictation())
        let following = await eventually(within: .seconds(2)) { files.choice == nil }
        XCTAssertTrue(following, "“As Dictation” left \(String(describing: files.choice))")
        let checked = await eventually(within: .seconds(2)) {
            (try? asDictation()).map { menu.items[$0].state == .on } ?? false
        }
        XCTAssertTrue(checked, "“As Dictation” is not checked again")
        XCTAssertEqual(
            FilesChoiceMenu.label(of: .init(engine: .parakeet, language: "auto"), settings: settings.snapshot),
            "Parakeet · Auto"
        )
        XCTAssertEqual(settings.dictationEngine, .parakeet)
        XCTAssertEqual(settings.dictationLanguage, "kk")
    }

    /// Neither a choice in the menu, nor a run in it, nor one refused, nor
    /// going back to the dictation's, touches the settings: not one
    /// publication of the engine or the language, not one write to their
    /// defaults. The watchers do see a real change.
    func testFilesChoiceNeverTouchesTheSettings() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path))
        let settings = SettingsStore(defaults: defaults)
        settings.dictationEngine = .parakeet
        settings.dictationLanguage = "ru"
        let before = settings.snapshot
        let published = Locked<[String]>([])
        let watched = [
            settings.$dictationEngine.dropFirst().sink { value in published.set(published.get() + ["\(value)"]) },
            settings.$dictationLanguage.dropFirst().sink { value in published.set(published.get() + [value]) },
        ]
        let writes = Locked(0)
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in writes.set(writes.get() + 1) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let factory = LevelEngineFactory(replies: [0.1: "текст"])
        let models = try installedModels()
        let files = try liveFiles(
            settings, cache: WhisperKitCache(factory: factory, parakeetFactory: factory), models: models, warmsUp: true
        ).files
        files.select(try speechFile(levels: [0.1]))

        files.choice = .init(engine: .whisper, language: "en")
        await transcribeInFiles(files)
        XCTAssertEqual(files.segments.map(\.text), ["текст"])
        try FileManager.default.removeItem(at: models.root.appendingPathComponent(ModelSource.whisper.destination))
        files.start()
        XCTAssertNotNil(files.errorText)
        files.choice = nil
        // The dictation's engine is prepared again after the run: it only reads them.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(published.get(), [])
        XCTAssertEqual(writes.get(), 0)
        XCTAssertEqual(settings.snapshot, before)
        settings.dictationLanguage = "de"
        XCTAssertEqual(published.get(), ["de"], "the watcher sees nothing at all")
        let seen = await eventually(within: .seconds(2)) { writes.get() > 0 }
        XCTAssertTrue(seen, "the defaults watcher sees nothing at all")
        _ = watched
    }

    // MARK: - Helpers

    /// A dictation and a meeting queue on one cache, joined as the app joins
    /// them: the dictation activated, and the recorder handing its held
    /// engine and its warm-up to the queue. The warm-up is off unless asked.
    private func dictationJoint(
        _ settings: SettingsStore,
        cache: WhisperKitCache,
        models: ModelDownloader? = nil,
        engineHold: Duration = .seconds(30),
        warmsUp: Bool = false,
        destinations: @escaping @MainActor () -> MeetingTranscriptionQueue.Destinations = { .init() }
    ) throws -> (dictation: DictationCoordinator, queue: MeetingTranscriptionQueue, recorder: MeetingRecorder) {
        let models = try models ?? installedModels()
        let dictation = try activatedDictation(settings, cache: cache, models: models, engineHold: engineHold, warmsUp: warmsUp)
        let queue = try liveQueue(settings, models: models, cache: cache, destinations: destinations)
        let recorder = MeetingRecorder(
            capture: SavingMeetingCapture(root: root.appendingPathComponent("Recordings", isDirectory: true)),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
        recorder.transcripts = queue
        recorder.activate(settings: settings, permissions: PermissionManager(runningTests: true), dictation: dictation)
        return (dictation, queue, recorder)
    }

    /// A dictation on the given cache, activated as the app activates it;
    /// what it records answers "диктовка" (level 0.9).
    private func activatedDictation(
        _ settings: SettingsStore,
        cache: WhisperKitCache,
        models: ModelDownloader,
        engineHold: Duration = .seconds(30),
        warmsUp: Bool = false
    ) throws -> DictationCoordinator {
        let template = root.appendingPathComponent("dictation.caf")
        try writeTrack(template, rate: 48_000, duration: 2, regions: [Region(start: 0.2, end: 1.8, level: 0.9)])
        let dictation = DictationCoordinator(
            mic: HistoryPipelineMic(template: template),
            indicator: RecordingIndicator(renderingEnabled: false),
            startTimeout: 5,
            engineHold: engineHold,
            hotkeyManager: HotkeyManager(installsSystemHandlers: false),
            whisperCache: cache,
            models: models,
            warmsUp: warmsUp,
            historyStore: DictationHistoryStore(root: root.appendingPathComponent("Dictations", isDirectory: true)),
            deliveryOverride: { _, _ in },
            frontmostApplication: { nil },
            feedbackPlayer: { _ in },
            beepPlayer: {}
        )
        dictation.activate(settings: settings, permissions: PermissionManager(runningTests: true))
        return dictation
    }

    /// The Files tab as the app builds it, `FilesModel.live` over
    /// `MeetingTranscriber.live`, beside an activated dictation on the same
    /// cache; only the engines, the speech detector, the models folder and
    /// the save panel are the test's own. The warm-up is off unless asked.
    private func liveFiles(
        _ settings: SettingsStore,
        cache: WhisperKitCache,
        models: ModelDownloader? = nil,
        engineHold: Duration = .seconds(30),
        warmsUp: Bool = false,
        saveDestination: @escaping FilesModel.SaveDestination = { _, _ in nil },
        speechDetector: @escaping @Sendable (String) async throws -> MeetingTranscriber.SpeechDetector = { _ in
            MeetingTranscriptionTests.levelDetector
        }
    ) throws -> (files: FilesModel, dictation: DictationCoordinator) {
        let models = try models ?? installedModels()
        let dictation = try activatedDictation(settings, cache: cache, models: models, engineHold: engineHold, warmsUp: warmsUp)
        let files = FilesModel.live(
            settings: settings,
            models: models,
            dictation: dictation,
            transcriber: .live(settings: settings, models: models, cache: cache, speechDetector: speechDetector),
            saveDestination: saveDestination
        )
        return (files, dictation)
    }

    /// A file with one speech region per level, far enough apart to stay
    /// lines of their own.
    private func speechFile(_ name: String = "talk.caf", levels: [Float]) throws -> URL {
        let file = root.appendingPathComponent(name)
        try writeTrack(file, rate: 48_000, duration: Double(levels.count) * 4 + 1, regions: levels.enumerated().map {
            Region(start: Double($0.offset) * 4 + 1, end: Double($0.offset) * 4 + 2.5, level: $0.element)
        })
        return file
    }

    /// Asks for a run and waits for its end; over unsaved text the user
    /// answers "Replace".
    private func transcribeInFiles(_ files: FilesModel) async {
        files.start()
        if let question = files.pendingReplacement { files.replace(with: question) }
        let done = await eventually(within: .seconds(20)) { !files.isTranscribing }
        XCTAssertTrue(done)
    }

    /// Waits until the cache holds the settings' dictation engine.
    private func warmedUp(_ cache: WhisperKitCache, to settings: SettingsStore) async throws {
        let warm = await eventually(within: .seconds(10)) {
            await cache.residentDescriptorForTesting() == settings.snapshot.dictationDescriptor
        }
        XCTAssertTrue(warm, "the cache never held the dictation's engine")
    }

    /// The queue as the app builds it, `MeetingTranscriber.live` included;
    /// only the engines, the speech detector and the models folder are the
    /// test's own.
    private func liveQueue(
        _ settings: SettingsStore,
        models: ModelDownloader? = nil,
        cache: WhisperKitCache,
        meetingsRoot: URL? = nil,
        destinations: @escaping @MainActor () -> MeetingTranscriptionQueue.Destinations = { .init() },
        speechDetector: @escaping @Sendable (String) async throws -> MeetingTranscriber.SpeechDetector = { _ in
            MeetingTranscriptionTests.levelDetector
        }
    ) throws -> MeetingTranscriptionQueue {
        MeetingTranscriptionQueue(
            transcriber: .live(
                settings: settings,
                models: try models ?? installedModels(),
                cache: cache,
                speechDetector: speechDetector
            ),
            meetingsRoot: meetingsRoot ?? root.appendingPathComponent("Meetings", isDirectory: true),
            destinations: destinations
        )
    }

    /// A models folder with the given models in place, by their files alone,
    /// which is all the downloader checks.
    private func installedModels(
        _ sources: [ModelSource] = [.parakeet, .whisper, .whisperTokenizer, .vad]
    ) throws -> ModelDownloader {
        let models = root.appendingPathComponent("Models", isDirectory: true)
        for source in sources {
            for path in source.required {
                let file = models.appendingPathComponent(source.destination).appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data("model".utf8).write(to: file)
            }
        }
        return ModelDownloader(root: models)
    }

    /// What a finished stop writes, enough for compression and the move.
    private func writeFinishedMetadata(in folder: URL) throws {
        try Data("""
        {"startedAt":"2026-10-14T10:00:00Z","endedAt":"2026-10-14T10:01:00Z","sampleRate":48000,\
        "state":"done","segments":[{"index":0,"mic":"microphone.caf","system":"system.caf"}]}
        """.utf8).write(to: folder.appendingPathComponent("metadata.json"))
    }

    /// Each request as "engine:language", in order.
    nonisolated private static func engineCalls(_ log: EngineLog) -> [String] { engineCalls(log.all()) }

    nonisolated private static func engineCalls(_ entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix("whisper:") || $0.hasPrefix("parakeet:") }
    }

    /// The production wiring: the engine is read from the settings before
    /// every chunk.
    private func settingsTranscriber(_ settings: SettingsStore, factory: LevelEngineFactory) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in Self.levelDetector },
            currentEngine: { _ in
                try await MainActor.run { try MeetingTranscriber.Engine.forMeeting(settings.snapshot) }
            },
            temporaryRoot: root
        )
    }

    /// A settings store of its own, language left at its default. An absolute
    /// suite path keeps its file inside `root`, which every test removes.
    private func isolatedSettings() throws -> SettingsStore {
        SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
    }

    nonisolated private static let levelDetector: MeetingTranscriber.SpeechDetector = { source in
        // Runs of non-silent samples; resampling rings briefly around each
        // edge, so nearby runs are joined and tiny blips dropped.
        var samples = [Float](repeating: 0, count: source.sampleCount)
        try samples.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 0, count: $0.count)
        }
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, sample) in samples.enumerated() {
            if abs(sample) > 0.02 {
                if start == nil { start = index }
            } else if let open = start {
                runs.append(open..<index)
                start = nil
            }
        }
        if let open = start { runs.append(open..<samples.count) }
        var joined: [Range<Int>] = []
        for run in runs {
            if let last = joined.last, run.lowerBound - last.upperBound < 800 {
                joined[joined.count - 1] = last.lowerBound..<run.upperBound
            } else {
                joined.append(run)
            }
        }
        return joined.filter { $0.count > 160 }
    }

    nonisolated private static func engine(_ path: String) -> MeetingTranscriber.Engine {
        MeetingTranscriber.Engine(
            descriptor: EngineDescriptor(engine: .whisper, modelPath: path),
            request: .whisper(WhisperDecodeRequest(language: "ru")),
            label: "Whisper (\(URL(fileURLWithPath: path).lastPathComponent))"
        )
    }

    private func makeTranscriber(
        factory: LevelEngineFactory = LevelEngineFactory(replies: [:]),
        cache: WhisperKitCache? = nil
    ) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: cache ?? WhisperKitCache(factory: factory),
            loadSpeechDetector: { _ in Self.levelDetector },
            currentEngine: { _ in Self.engine("/models/whisper") },
            temporaryRoot: root
        )
    }

    private func makeFolder(
        microphone: [Region],
        system: [Region],
        systemRate: Double = 48_000,
        microphoneRate: Double = 48_000,
        name: String = "meeting"
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let duration = ((microphone + system).map(\.end).max() ?? 0) + 1
        try writeTrack(
            folder.appendingPathComponent("microphone.caf"), rate: microphoneRate, duration: duration, regions: microphone
        )
        try writeTrack(folder.appendingPathComponent("system.caf"), rate: systemRate, duration: duration, regions: system)
        return folder
    }

    private func writeTrack(_ url: URL, rate: Double, duration: Double, regions: [Region]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        ))
        let frames = Int(duration * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frames { channel[index] = 0 }
        for region in regions {
            for index in Int(region.start * rate)..<min(frames, Int(region.end * rate)) {
                channel[index] = region.level
            }
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }

    private func utterance(_ speaker: String, _ text: String, _ start: Double, _ end: Double) -> MeetingTranscriber.Utterance {
        MeetingTranscriber.Utterance(speaker: speaker, text: text, start: start, end: end)
    }

    /// A Files tab whose stand-in run answers "run <n>", left with the
    /// unsaved result of its first run on `talk.wav`.
    private func filesWithUnsavedResult(
        saveDestination: @escaping FilesModel.SaveDestination
    ) async throws -> FilesModel {
        let runs = Locked(0)
        let files = FilesModel(transcription: { _ in { _, _ in
            runs.set(runs.get() + 1)
            return [TranscriptSegment(speaker: "", text: "run \(runs.get())")]
        } }, saveDestination: saveDestination)
        files.select(root.appendingPathComponent("talk.wav"))
        files.start()
        let finished = await eventually(within: .seconds(10)) { !files.segments.isEmpty }
        XCTAssertTrue(finished)
        XCTAssertTrue(files.hasUnsavedText)
        return files
    }

    /// The user runs the file again over its text; the run's result replaces
    /// the shown one.
    private func landNewerResult(in files: FilesModel) async throws {
        let shown = files.resultRevision
        files.start()
        files.replace(with: try XCTUnwrap(files.pendingReplacement))
        let landed = await eventually(within: .seconds(10)) {
            !files.isTranscribing && !files.segments.isEmpty && files.resultRevision != shown
        }
        XCTAssertTrue(landed)
    }

    /// The text a failure brings back, whatever its case is called: found by
    /// reflection, so the check also runs against code without such a case.
    private func linesCarried(by error: Error) -> [String] {
        func lines(in value: Any) -> [MeetingTranscriber.Utterance]? {
            if let found = value as? [MeetingTranscriber.Utterance] { return found }
            return Mirror(reflecting: value).children.lazy.compactMap { lines(in: $0.value) }.first
        }
        return lines(in: error)?.map(\.text) ?? []
    }

    /// The transcript written next to the recording, read from disk.
    private func transcript(in folder: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let name = try XCTUnwrap(names.first { $0.hasPrefix("transcript") && $0.hasSuffix(".md") }, "no transcript in \(names)")
        return try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func assertNoTemporaryFiles(in folder: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(
            names.contains { $0.hasPrefix(MeetingTranscriber.temporaryPrefix) },
            "leftover temporary transcript in \(names)", file: file, line: line
        )
    }

    /// FluidAudio's 16 kHz copies of a track, which it names itself.
    private func streamingTemporaryFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("fluidaudio-streaming-") })
    }

    /// Polls with a deadline, so a wedged queue fails instead of hanging the run.
    private func eventually(
        within limit: Duration,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

extension MeetingTranscriptionQueue.Job {
    /// The job as asked for: what the queue reads of the folder is not part
    /// of what these tests compare.
    var withoutIdentity: Self {
        var job = self
        job.identity = nil
        return job
    }
}

/// The windows panels were asked for on, in order.
@MainActor
private final class Owners {
    private(set) var all: [ObjectIdentifier?] = []
    func add(_ window: NSWindow?) { all.append(window.map(ObjectIdentifier.init)) }
}

/// The folder panel a test was handed instead of AppKit's.
@MainActor
private final class OpenedPanel {
    var panel: NSOpenPanel?
    var completion: (@MainActor (URL) -> Void)?
}
