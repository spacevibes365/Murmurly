import AVFoundation
import FluidAudio
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
/// which track reached the engine.
private actor LevelEngine: WhisperEngine {
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
        let level = try Self.level(of: URL(fileURLWithPath: audioPath))
        let reply = replies.min { abs($0.key - level) < abs($1.key - level) }?.value ?? ""
        let asked: String? = request.language
        let language = asked ?? detected.min { abs($0.key - level) < abs($1.key - level) }?.value ?? "auto"
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

private actor LevelEngineFactory: WhisperEngineFactory {
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
            loadSpeechDetector: { Self.levelDetector },
            currentEngine: { Self.engine("/models/selected") },
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
        let files = FilesModel { FilesModel.transcription(transcriber) }

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
        let files = try await filesWithUnsavedResult(saveDestination: { _ in
            try? await panel.pass()
            return target
        })
        let save = Task { await files.saveTranscript() }
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
        let again = await files.saveTranscript()
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

        let cancelled = try await filesWithUnsavedResult(saveDestination: { _ in nil })
        cancelled.select(b)
        await cancelled.saveThenReplace(try XCTUnwrap(cancelled.pendingReplacement))
        XCTAssertEqual(cancelled.fileURL?.lastPathComponent, "talk.wav", "a cancelled panel took the new file")
        XCTAssertEqual(cancelled.segments.map(\.text), ["run 1"])
        XCTAssertTrue(cancelled.hasUnsavedText)

        let unwritable = root.appendingPathComponent("no-such-folder/saved.md")
        let failed = try await filesWithUnsavedResult(saveDestination: { _ in unwritable })
        failed.select(b)
        await failed.saveThenReplace(try XCTUnwrap(failed.pendingReplacement))
        XCTAssertEqual(failed.fileURL?.lastPathComponent, "talk.wav", "a failed write took the new file")
        XCTAssertNotNil(failed.errorText)
        XCTAssertTrue(failed.hasUnsavedText)

        let target = root.appendingPathComponent("raced.md")
        let panel = Gate()
        let raced = try await filesWithUnsavedResult(saveDestination: { _ in
            try? await panel.pass()
            return target
        })
        raced.select(b)
        let agreed = try XCTUnwrap(raced.pendingReplacement)
        let replace = Task { await raced.saveThenReplace(agreed) }
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
        let plain = try await filesWithUnsavedResult(saveDestination: { _ in saved })
        plain.select(b)
        await plain.saveThenReplace(try XCTUnwrap(plain.pendingReplacement))
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "run 1")
        XCTAssertEqual(plain.fileURL, b)
        XCTAssertTrue(plain.segments.isEmpty)
    }

    /// A new file over unsaved text waits for the user: nothing changes until
    /// they agree, and agreeing takes the file without the old text.
    func testUnsavedTextIsReplacedOnlyAfterTheOwnerAgrees() async throws {
        let files = try await filesWithUnsavedResult(saveDestination: { _ in nil })
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
            loadSpeechDetector: { Self.levelDetector },
            currentEngine: { selected.get() },
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
            loadSpeechDetector: { jobs.set(jobs.get() + 1); return Self.levelDetector },
            currentEngine: { Self.engine("/models/whisper") },
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
            loadSpeechDetector: {
                { _ in
                    entered.set(true)
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            },
            currentEngine: { Self.engine("/models/whisper") },
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
            loadSpeechDetector: {
                { _ in
                    entered.set(true)
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            },
            currentEngine: { Self.engine("/models/whisper") },
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
            loadSpeechDetector: { try await MeetingTranscriber.sileroDetector(modelPath: missing) },
            currentEngine: { Self.engine("/models/whisper") },
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
            transcription: { { _, _ in [TranscriptSegment(speaker: "", text: "words")] } },
            saveDestination: { _ in
                let next = places.get().first
                places.set(Array(places.get().dropFirst()))
                return next
            }
        )
        files.select(root.appendingPathComponent("talk.wav"))
        files.start()
        let finished = await eventually(within: .seconds(10)) { !files.segments.isEmpty }
        XCTAssertTrue(finished)

        let first = await files.saveTranscript()
        XCTAssertFalse(first)
        XCTAssertNotNil(files.errorText, "the failed save must be told")
        let second = await files.saveTranscript()

        XCTAssertTrue(second)
        XCTAssertEqual(files.savedAs, "talk.md")
        XCTAssertNil(files.errorText, "a save that worked still shows the earlier failure")
    }

    // MARK: - Helpers

    /// The production wiring: the engine is read from the settings before
    /// every chunk.
    private func settingsTranscriber(_ settings: SettingsStore, factory: LevelEngineFactory) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: WhisperKitCache(factory: factory),
            loadSpeechDetector: { Self.levelDetector },
            currentEngine: {
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
            loadSpeechDetector: { Self.levelDetector },
            currentEngine: { Self.engine("/models/whisper") },
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
        let files = FilesModel(transcription: { { _, _ in
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
