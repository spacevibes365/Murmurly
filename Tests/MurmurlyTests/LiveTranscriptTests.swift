import AVFoundation
import Combine
import FluidAudio
import Foundation
import XCTest
@testable import Murmurly

/// Deterministic generator (SplitMix64), separate from the one in
/// `MeetingEchoCancellationTests.swift` (private there).
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func rms(_ block: [Float]) -> Float {
    guard !block.isEmpty else { return 0 }
    let sum = block.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(block.count)).squareRoot()
}

/// Classifies a block as speech by its own loudness, ignoring the carried
/// state entirely — deterministic, and independent of a real Silero model.
private func levelDetector(threshold: Float = 0.05) -> LiveTranscript.Detector {
    LiveTranscript.Detector { block, state in
        (rms(block) > threshold ? Float(1.0) : Float(0.0), state)
    }
}

/// Always reports speech, whatever the block holds.
private func alwaysSpeechDetector() -> LiveTranscript.Detector {
    LiveTranscript.Detector { _, state in (Float(1.0), state) }
}

/// Replays a fixed probability for each non-silent block it sees, in order —
/// deterministic hysteresis testing without a real Silero model. An
/// all-zero block (the muted track in these tests) is always reported
/// silent, so one script serves the one track that carries content whatever
/// order the two tracks happen to be classified in.
/// `@unchecked Sendable`: `Cursor` is only ever touched serially, from
/// inside `LiveTranscript`'s own actor.
private func scriptedDetector(_ probabilities: [Float]) -> LiveTranscript.Detector {
    final class Cursor: @unchecked Sendable { var index = 0 }
    let cursor = Cursor()
    return LiveTranscript.Detector { block, state in
        guard !block.allSatisfy({ $0 == 0 }) else { return (0, state) }
        let index = min(cursor.index, probabilities.count - 1)
        cursor.index += 1
        return (probabilities[index], state)
    }
}

private final class PassthroughCanceller: LiveTranscript.EchoCancelling {
    func process(microphone: [Float], reference: [Float]) throws -> [Float] { microphone }
    func finish() throws -> [Float] { [] }
}

/// Multiplies by 0.5 until the call numbered `failOnCall`, then throws on
/// every call from then on (the canceller is never asked again once
/// `LiveTranscript` turns it off for the meeting, but a test double that kept
/// throwing would show the same behaviour).
/// `@unchecked Sendable`: its mutable state is only ever touched from inside
/// `LiveTranscript`'s own actor, which serializes every call into it.
private final class FailingCanceller: LiveTranscript.EchoCancelling, @unchecked Sendable {
    private var calls = 0
    private let failOnCall: Int
    /// Input lengths of the calls that succeeded, in order — so a test can
    /// compute exactly where the scaling stops without guessing how the
    /// streaming converter split the signal into calls.
    private(set) var successfulLengths: [Int] = []
    init(failOnCall: Int) { self.failOnCall = failOnCall }
    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        calls += 1
        if calls >= failOnCall {
            throw NSError(domain: "fake-aec", code: 1)
        }
        successfulLengths.append(microphone.count)
        return microphone.map { $0 * 0.5 }
    }
    func finish() throws -> [Float] { [] }
}

/// Scales by 0.7 while under its sample budget, then throws forever — a
/// stand-in for a canceller whose own internal state is never reset by
/// `LiveTranscript`. Used across a break: if `LiveTranscript` hands the
/// *same* instance to both sides instead of a fresh one (its own memory of
/// calls carried across the break, not lane state), its budget is tipped
/// over by the second batch alone and that chunk is wrongly produced from
/// the raw microphone instead of the cancelled one.
/// `@unchecked Sendable`: its mutable state is only ever touched from inside
/// `LiveTranscript`'s own actor, which serializes every call into it.
private final class CountingThenFailingCanceller: LiveTranscript.EchoCancelling, @unchecked Sendable {
    private var totalProcessed = 0
    private let failAfterTotalSamples: Int
    init(failAfterTotalSamples: Int) { self.failAfterTotalSamples = failAfterTotalSamples }
    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        totalProcessed += microphone.count
        if totalProcessed > failAfterTotalSamples {
            throw NSError(domain: "fake-aec-memory", code: 1)
        }
        return microphone.map { $0 * 0.7 }
    }
    func finish() throws -> [Float] { [] }
}

private struct AlwaysFailingFactory: Sendable {
    struct Failure: Error {}
    func make() throws -> any LiveTranscript.EchoCancelling { throw Failure() }
}

private actor QueueSource {
    private var queue: [LiveTranscript.Audio]
    private(set) var calls = 0
    init(_ items: [LiveTranscript.Audio] = []) { queue = items }
    func push(_ item: LiveTranscript.Audio) { queue.append(item) }
    func pop() -> LiveTranscript.Audio? {
        calls += 1
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}

/// `XCTAssertEqual(_:_:accuracy:)` only takes `FloatingPoint`; sample counts
/// are `Int`.
private func assertClose(
    _ a: Int, _ b: Int, tolerance: Int, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(abs(a - b) <= tolerance, "\(a) is not within \(tolerance) of \(b). \(message)", file: file, line: line)
}

// MARK: - Recognition pipeline fixtures

/// Answers by the median amplitude of the chunk file it is asked to
/// transcribe — the same trick `MeetingTranscriptionTests`' `LevelEngine`
/// uses, so chunks built at different amplitudes get distinguishable replies
/// without any other bookkeeping.
private actor LiveLevelEngine: WhisperEngine {
    let replies: [Float: String]
    let delay: Duration
    private(set) var callCount = 0

    init(replies: [Float: String], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        callCount += 1
        let level = try Self.level(of: URL(fileURLWithPath: audioPath))
        let reply = replies.min { abs($0.key - level) < abs($1.key - level) }?.value ?? ""
        if delay > .zero { try await Task.sleep(for: delay) }
        return ([WhisperSegmentDTO(text: reply, start: 0)], request.language ?? "en")
    }

    static func level(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return 0 }
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let sorted = samples.map { abs($0) }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private actor LiveLevelEngineFactory: WhisperEngineFactory {
    let replies: [Float: String]
    let delay: Duration
    private(set) var loadCount = 0

    init(replies: [Float: String], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        loadCount += 1
        return LiveLevelEngine(replies: replies, delay: delay)
    }
}

/// A door the test opens by hand; a request stuck on it never comes back on
/// its own, the same way a wedged engine would.
private actor LiveGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasEntered = false
    /// Set right before `pass()` returns — the same moment the gated
    /// request is about to hand its result back — so a test can wait for
    /// that instead of guessing how long "after `open()`" needs to be.
    private(set) var didComplete = false

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func pass() async {
        wasEntered = true
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        didComplete = true
    }
}

private struct LiveGatedEngine: WhisperEngine {
    let gate: LiveGate
    let text: String
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        await gate.pass()
        return ([WhisperSegmentDTO(text: text, start: 0)], request.language ?? "en")
    }
}

private struct LiveGatedEngineFactory: WhisperEngineFactory {
    let gate: LiveGate
    let text: String
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        LiveGatedEngine(gate: gate, text: text)
    }
}

/// Replies in a fixed script, one entry per call, and records the language
/// each request actually asked for — so a test can tell whether a chunk with
/// no recognizable words fixed Whisper's "auto" language (it must not).
private actor LiveScriptedLanguageEngine: WhisperEngine {
    struct Reply { let text: String; let language: String }
    private let replies: [Reply]
    private var index = 0
    private(set) var seenLanguages: [String?] = []

    init(replies: [Reply]) { self.replies = replies }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        seenLanguages.append(request.language)
        let reply = replies[min(index, replies.count - 1)]
        index += 1
        return ([WhisperSegmentDTO(text: reply.text, start: 0)], reply.language)
    }
}

private actor LiveScriptedLanguageFactory: WhisperEngineFactory {
    let engine: LiveScriptedLanguageEngine
    init(engine: LiveScriptedLanguageEngine) { self.engine = engine }
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { engine }
}

/// Answers every request, interim or final, with "речь N" — N the chunk
/// file's own length rounded to the nearest second — and keeps a log of
/// every call's length and level, so a test can tell an interim request
/// (shorter than the final one that eventually replaces it) from a final one
/// without reading any text. `trackLevel` is off for the hour-long load test:
/// `LiveLevelEngine.level(of:)` sorts the whole chunk (up to 15 s of audio),
/// and that test only needs the length bound, not the level.
private actor LiveLengthEngine: WhisperEngine {
    struct Call: Sendable { let samples: Int; let level: Float }
    private(set) var calls: [Call] = []
    let gate: LiveGate?
    let trackLevel: Bool

    init(gate: LiveGate? = nil, trackLevel: Bool = true) {
        self.gate = gate
        self.trackLevel = trackLevel
    }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        if let gate { await gate.pass() }
        let url = URL(fileURLWithPath: audioPath)
        let file = try AVAudioFile(forReading: url)
        let samples = Int(file.length)
        let level = trackLevel ? ((try? Self.levelOfFile(file)) ?? 0) : 0
        calls.append(Call(samples: samples, level: level))
        let seconds = Int((Double(samples) / 16_000).rounded())
        return ([WhisperSegmentDTO(text: "речь \(seconds)", start: 0)], request.language ?? "en")
    }

    private static func levelOfFile(_ file: AVAudioFile) throws -> Float {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return 0 }
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let sorted = samples.map { abs($0) }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private actor LiveLengthEngineFactory: WhisperEngineFactory {
    let engine: LiveLengthEngine
    init(engine: LiveLengthEngine) { self.engine = engine }
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { engine }
}

/// Every publication `LiveTranscriptModel.lines` ever makes, in order — a
/// plain poll of the current value can miss an interim line a final result
/// replaced before the test next looked.
@MainActor
private final class LinesObserver {
    private(set) var snapshots: [[LiveLine]] = []
    private var cancellable: AnyCancellable?

    init(_ model: LiveTranscriptModel) {
        cancellable = model.$lines.sink { [weak self] lines in
            self?.snapshots.append(lines)
        }
    }
}

/// Always throws the same, fixed error — never recognized text — so a test
/// can check that error's own `localizedDescription` reaches `.stopped`
/// unchanged, after three requests in a row fail.
private struct LiveChunkFailure: LocalizedError {
    var errorDescription: String? { "live chunk request failed on purpose" }
}

private struct AlwaysFailingWhisperEngine: WhisperEngine {
    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        throw LiveChunkFailure()
    }
}

private struct AlwaysFailingWhisperEngineFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { AlwaysFailingWhisperEngine() }
}

/// Gates the engine's *load* (`make`), not a request — a stand-in for a model
/// still being prepared, so `finish()` can be tested while the cache's own
/// progress loop is still reporting `.preparingModel`.
private struct LiveGatedLoadFactory: WhisperEngineFactory {
    let gate: LiveGate
    let replies: [Float: String]
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        await gate.pass()
        return LiveLevelEngine(replies: replies)
    }
}

/// A feed a test can grow mid-call, from outside the actor isolation the real
/// `callFeedEvents` closure runs under — `@unchecked Sendable` because its own
/// lock, not the language, is what makes it safe.
private final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CallFeed.Event]
    init(_ events: [CallFeed.Event] = []) { self.events = events }
    func append(_ event: CallFeed.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    func snapshot() -> [CallFeed.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class LiveTranscriptTests: XCTestCase {
    private static let rate16 = 16_000.0
    private static let block16 = 4096

    private func blockFrames(rate: Double) -> Int {
        Int((Double(Self.block16) * rate / Self.rate16).rounded())
    }

    /// Builds a mono signal from a block-aligned pattern: loud noise (RMS
    /// well above the fake detector's threshold) for a speech block, silence
    /// for the rest.
    private func segmentSignal(
        pattern: [(speech: Bool, blocks: Int)], rate: Double, seed: UInt64
    ) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        let frames = blockFrames(rate: rate)
        var samples: [Float] = []
        for segment in pattern {
            let amplitude: Float = segment.speech ? 0.3 : 0
            for _ in 0..<(segment.blocks * frames) {
                samples.append(amplitude == 0 ? 0 : amplitude * Float.random(in: -1...1, using: &generator))
            }
        }
        return samples
    }

    /// A signal with a speech span at an arbitrary (not block-aligned) offset.
    private func buildSignal(
        rate: Double, silenceBefore: Double, speechSeconds: Double, silenceAfter: Double, seed: UInt64
    ) -> (samples: [Float], speechStart: Int, speechLength: Int) {
        var generator = SeededGenerator(seed: seed)
        let before = Int((silenceBefore * rate).rounded())
        let speech = Int((speechSeconds * rate).rounded())
        let after = Int((silenceAfter * rate).rounded())
        var samples = [Float](repeating: 0, count: before)
        for _ in 0..<speech { samples.append(0.3 * Float.random(in: -1...1, using: &generator)) }
        samples.append(contentsOf: [Float](repeating: 0, count: after))
        return (samples, before, speech)
    }

    /// `count` full VAD blocks of non-zero noise at 16 kHz, one per entry a
    /// `scriptedDetector` script will classify — content is never read for
    /// its probability, only for not being the all-zero muted track.
    private func scriptedTrackSignal(blocks: Int, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<(blocks * Self.block16)).map { _ in 0.3 * Float.random(in: -1...1, using: &generator) }
    }

    private func makeSnapshots(
        system: [Float], microphone: [Float], channels: Int, rate: Double, firstFrame: Int64, sizes: [Int]
    ) -> [LiveTranscript.Audio] {
        var result: [LiveTranscript.Audio] = []
        var offset = 0
        var frame = firstFrame
        var sizeIndex = 0
        while offset < system.count {
            let size = sizes.isEmpty ? system.count : sizes[sizeIndex % sizes.count]
            let count = max(1, min(size, system.count - offset))
            let sys = Array(system[offset..<(offset + count)])
            let mic = Array(microphone[(offset * channels)..<((offset + count) * channels)])
            result.append(LiveTranscript.Audio(
                sampleRate: rate, microphoneChannels: channels, firstFrame: frame,
                system: sys, microphone: mic, dropped: 0
            ))
            offset += count
            frame += Int64(count)
            sizeIndex += 1
        }
        return result
    }

    private func run(
        _ snapshots: [LiveTranscript.Audio],
        detector: LiveTranscript.Detector,
        makeEchoCanceller: @escaping @Sendable () throws -> any LiveTranscript.EchoCancelling = { PassthroughCanceller() }
    ) async -> (chunks: [LiveTranscript.Chunk], skipped: Int) {
        let source = QueueSource(snapshots)
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: detector, makeEchoCanceller: makeEchoCanceller
        )
        await transcript.drain()
        await transcript.finish()
        let chunks = await transcript.takeChunks()
        let skipped = await transcript.skippedChunks
        return (chunks, skipped)
    }

    // MARK: - 1. Snapshot sizes do not change the cut

    func testSnapshotSizesDoNotChangeChunks() async throws {
        let rate = 48_000.0
        let pattern: [(Bool, Int)] = [(true, 6), (false, 1), (true, 6), (false, 3), (true, 6), (false, 1), (true, 6)]
        let system = segmentSignal(pattern: pattern, rate: rate, seed: 1)
        let microphone = segmentSignal(pattern: pattern, rate: rate, seed: 2)

        func chunks(sizes: [Int]) async -> [LiveTranscript.Chunk] {
            let snapshots = makeSnapshots(
                system: system, microphone: microphone, channels: 1, rate: rate, firstFrame: 1000, sizes: sizes
            )
            return await run(snapshots, detector: levelDetector()).chunks
        }

        let whole = await chunks(sizes: [system.count])
        let sliced = await chunks(sizes: [1, 100, Int(3 * rate)])

        XCTAssertEqual(whole.count, sliced.count)
        XCTAssertFalse(whole.isEmpty)
        for (a, b) in zip(whole, sliced) {
            XCTAssertEqual(a.track, b.track)
            XCTAssertEqual(a.start, b.start, accuracy: 1e-3)
            XCTAssertEqual(a.end, b.end, accuracy: 1e-3)
            assertClose(a.samples.count, b.samples.count, tolerance: 4)
            // Not just the same length: the same audio, sample for sample —
            // a slicing that shifted the cut by a block would still pass a
            // length-only check.
            let compareCount = min(a.samples.count, b.samples.count)
            for i in 0..<compareCount {
                XCTAssertEqual(a.samples[i], b.samples[i], accuracy: 1e-4, "sample \(i) of \(a.track)")
            }
        }
    }

    // MARK: - 2. Cutting on silence, the minimum length, the 15 s hard cut

    func testTwoSilentBlocksCutOneDoesNotAndPauseIsScissors() async throws {
        let pattern: [(Bool, Int)] = [(true, 4), (false, 1), (true, 4), (false, 2), (true, 4), (false, 2)]
        let system = segmentSignal(pattern: pattern, rate: Self.rate16, seed: 10)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let (chunks, skipped) = await run([snapshot], detector: levelDetector())

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(skipped, 0)
        guard chunks.count == 2 else { return }
        // 9 blocks of real speech (4 + 1 silent + 4) plus up to 0.1 s of the
        // closing pause, never the whole pause.
        assertClose(chunks[0].samples.count, 9 * Self.block16 + 1600, tolerance: 8)
        // 4 blocks of speech plus the same pad.
        assertClose(chunks[1].samples.count, 4 * Self.block16 + 1600, tolerance: 8)
    }

    func testChunkShorterThanMinimumIsDropped() async throws {
        let pattern: [(Bool, Int)] = [(true, 1), (false, 2)]
        let system = segmentSignal(pattern: pattern, rate: Self.rate16, seed: 11)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let (chunks, skipped) = await run([snapshot], detector: levelDetector())

        XCTAssertEqual(chunks.count, 0)
        XCTAssertEqual(skipped, 0)
    }

    func testContinuousSpeechIsCutAt15Seconds() async throws {
        let seconds = 40.0
        var generator = SeededGenerator(seed: 12)
        let count = Int(seconds * Self.rate16)
        let system = (0..<count).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let microphone = [Float](repeating: 0, count: count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let (chunks, skipped) = await run([snapshot], detector: levelDetector())

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(skipped, 0)
        guard chunks.count == 3 else { return }
        let hardCut = 58 * Self.block16
        assertClose(chunks[0].samples.count, hardCut, tolerance: 4)
        assertClose(chunks[1].samples.count, hardCut, tolerance: 4)
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        assertClose(total, count, tolerance: 16)
    }

    /// FluidAudio's own hysteresis: while a chunk is open, a block in the
    /// band between the two thresholds (here 0.75, between the 0.70 exit and
    /// the 0.85 entry) is still speech — it extends the accepted end of
    /// speech and clears the silent run.
    func testHysteresisBandStaysSpeechUntilBelowExit() async throws {
        let probabilities: [Float] = [1, 1, 0.75, 0, 0]
        let system = scriptedTrackSignal(blocks: probabilities.count, seed: 100)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let (chunks, skipped) = await run([snapshot], detector: scriptedDetector(probabilities))
        let systemChunks = chunks.filter { $0.track == .system }

        XCTAssertEqual(systemChunks.count, 1)
        XCTAssertEqual(skipped, 0)
        guard let chunk = systemChunks.first else { return }
        // Blocks 1-3 count as speech (the 0.75 block moves the accepted end
        // of speech to itself); blocks 4-5 are two silent blocks in a row,
        // closing the chunk with up to 0.1 s of pad — never
        // `2 * block + pad`, which is what a band that does not extend
        // speech would produce.
        assertClose(chunk.samples.count, 3 * Self.block16 + 1600, tolerance: 8)
    }

    /// The same band, but the silent run it resets never reaches 2: the
    /// chunk must still be open — nothing closes it — without `finish()`.
    func testHysteresisBandResetsSilentRunWithoutClosing() async throws {
        let probabilities: [Float] = [1, 1, 0, 0.75, 0]
        let system = scriptedTrackSignal(blocks: probabilities.count, seed: 101)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let source = QueueSource([snapshot])
        let transcript = LiveTranscript(source: { await source.pop() }, detector: scriptedDetector(probabilities))
        await transcript.drain()
        let chunks = await transcript.takeChunks()

        XCTAssertTrue(
            chunks.filter { $0.track == .system }.isEmpty,
            "the 0.75 block must reset the silent run to 0, so the single silent block after it never closes the chunk"
        )
    }

    /// The hard cut at 15 s follows the same end-of-speech rule as an
    /// ordinary close, and a quiet block that triggers it is never folded in
    /// as speech on either side of the cut.
    func testHardCutDoesNotTreatQuietBoundaryBlockAsSpeech() async throws {
        let pattern: [(Bool, Int)] = [(true, 58), (false, 3), (true, 10)]
        let system = segmentSignal(pattern: pattern, rate: Self.rate16, seed: 110)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let (chunks, skipped) = await run([snapshot], detector: levelDetector())
        let systemChunks = chunks.filter { $0.track == .system }

        XCTAssertEqual(systemChunks.count, 2)
        XCTAssertEqual(skipped, 0)
        guard systemChunks.count == 2 else { return }
        // The cut closes right at the end of the 58 accepted speech blocks —
        // the quiet 59th block that triggered it contributes no padding on
        // this side, unlike an ordinary two-silent-blocks close.
        assertClose(systemChunks[0].samples.count, 58 * Self.block16, tolerance: 4)
        // The next chunk opens at block 62 (after the whole 3-block gap),
        // with at most 0.1 s of pad from the gap — not the gap itself
        // mistaken for speech.
        let expectedStart = (Double(61 * Self.block16) - 1600.0) / Self.rate16
        XCTAssertEqual(systemChunks[1].start, expectedStart, accuracy: 0.01)
    }

    // MARK: - 3. Time is the source frame over the clock rate

    func testChunkTimeIsSourceFrameOverClockRate() async throws {
        for rate in [48_000.0, 24_000.0] {
            let firstFrame: Int64 = 1_000_000
            let (samples, speechStart, speechLength) = buildSignal(
                rate: rate, silenceBefore: 3.3, speechSeconds: 1.0, silenceAfter: 2.0, seed: 20
            )
            let microphone = [Float](repeating: 0, count: samples.count)
            let snapshot = LiveTranscript.Audio(
                sampleRate: rate, microphoneChannels: 1, firstFrame: firstFrame,
                system: samples, microphone: microphone, dropped: 0
            )
            let (chunks, _) = await run([snapshot], detector: levelDetector())

            XCTAssertEqual(chunks.count, 1, "rate \(rate)")
            guard let chunk = chunks.first else { continue }
            let expectedStart = Double(firstFrame) / rate + Double(speechStart) / rate
            let expectedEnd = expectedStart + Double(speechLength) / rate
            let blockSeconds = Double(blockFrames(rate: rate)) / rate
            XCTAssertEqual(chunk.start, expectedStart, accuracy: blockSeconds, "rate \(rate)")
            XCTAssertEqual(chunk.end, expectedEnd, accuracy: blockSeconds, "rate \(rate)")
        }
    }

    // MARK: - 4. Breaks

    func testFrameJumpDropsOpenChunkAndRestartsAtNewFrame() async throws {
        let rate = Self.rate16
        let openPattern: [(Bool, Int)] = [(true, 8)]
        let firstBatch = segmentSignal(pattern: openPattern, rate: rate, seed: 30)
        let firstMicrophone = [Float](repeating: 0, count: firstBatch.count)
        let firstSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: 0, system: firstBatch, microphone: firstMicrophone, dropped: 0
        )

        let newOrigin: Int64 = 10 * Int64(rate)
        let (secondBatch, speechStart, _) = buildSignal(
            rate: rate, silenceBefore: 2.0, speechSeconds: 1.0, silenceAfter: 1.0, seed: 31
        )
        let secondMicrophone = [Float](repeating: 0, count: secondBatch.count)
        let secondSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: newOrigin,
            system: secondBatch, microphone: secondMicrophone, dropped: 0
        )

        let (chunks, _) = await run([firstSnapshot, secondSnapshot], detector: levelDetector())

        XCTAssertEqual(chunks.count, 1)
        guard let chunk = chunks.first else { return }
        let padSeconds = 1600.0 / rate
        let expectedStart = Double(newOrigin) / rate + Double(speechStart) / rate - padSeconds
        // A VAD block straddling the silence/speech boundary can open the
        // chunk up to one block early; a block is 0.256 s.
        XCTAssertEqual(chunk.start, expectedStart, accuracy: 0.26)
    }

    func testDroppedFramesAreABreak() async throws {
        let rate = Self.rate16
        let openPattern: [(Bool, Int)] = [(true, 8)]
        let firstBatch = segmentSignal(pattern: openPattern, rate: rate, seed: 32)
        let firstMicrophone = [Float](repeating: 0, count: firstBatch.count)
        let firstSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: 0, system: firstBatch, microphone: firstMicrophone, dropped: 0
        )

        let contiguousFrame = Int64(firstBatch.count)
        let secondPattern: [(Bool, Int)] = [(true, 4), (false, 2)]
        let secondBatch = segmentSignal(pattern: secondPattern, rate: rate, seed: 33)
        let secondMicrophone = [Float](repeating: 0, count: secondBatch.count)
        let secondSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: contiguousFrame,
            system: secondBatch, microphone: secondMicrophone, dropped: 480
        )

        let (chunks, _) = await run([firstSnapshot, secondSnapshot], detector: levelDetector())

        // The first (open, never closed) chunk is discarded by the break;
        // only the second batch's closed chunk remains.
        XCTAssertEqual(chunks.count, 1)
        guard let chunk = chunks.first else { return }
        assertClose(chunk.samples.count, 4 * Self.block16 + 1600, tolerance: 8)
    }

    /// A curved snapshot (a channel count outside 1-2, or a microphone
    /// length that does not match the system length) must be treated as a
    /// break, not quietly dropped: the open chunk from before it is
    /// discarded, exactly as a frame jump would discard it, rather than
    /// surviving to be corrupted by whatever comes next.
    func testMalformedSnapshotIsTreatedAsABreak() async throws {
        let rate = Self.rate16
        let openPattern: [(Bool, Int)] = [(true, 8)]
        let firstBatch = segmentSignal(pattern: openPattern, rate: rate, seed: 140)
        let firstMicrophone = [Float](repeating: 0, count: firstBatch.count)
        let firstSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: 0, system: firstBatch, microphone: firstMicrophone, dropped: 0
        )

        // Same channel count and a frame number that lines up exactly with
        // where the first batch left off — nothing here would trip a plain
        // continuity check (rate, channels, frame number) on its own; only
        // the mismatched microphone length (51 samples for 50 system ones,
        // at 1 channel) makes this snapshot curved.
        let malformedSystemCount = 50
        let malformedSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: Int64(firstBatch.count),
            system: [Float](repeating: 0.3, count: malformedSystemCount),
            microphone: [Float](repeating: 0, count: malformedSystemCount + 1), dropped: 0
        )

        // The next, valid snapshot picks up exactly where the malformed
        // one claimed to leave off: a reader that only re-synced on frame
        // number, rate or channel mismatches would see no break at all here
        // and would keep feeding this snapshot into the chunk still open
        // from the first batch.
        let secondFirstFrame = Int64(firstBatch.count) + Int64(malformedSystemCount)
        let (secondBatch, speechStart, _) = buildSignal(
            rate: rate, silenceBefore: 2.0, speechSeconds: 1.0, silenceAfter: 1.0, seed: 141
        )
        let secondMicrophone = [Float](repeating: 0, count: secondBatch.count)
        let secondSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: secondFirstFrame,
            system: secondBatch, microphone: secondMicrophone, dropped: 0
        )

        let (chunks, _) = await run([firstSnapshot, malformedSnapshot, secondSnapshot], detector: levelDetector())

        XCTAssertEqual(chunks.count, 1)
        guard let chunk = chunks.first else { return }
        let padSeconds = 1600.0 / rate
        let expectedStart = Double(secondFirstFrame) / rate + Double(speechStart) / rate - padSeconds
        XCTAssertEqual(chunk.start, expectedStart, accuracy: 0.26)
    }

    /// A break must hand the next segment a *fresh* echo-canceller instance,
    /// not the same one carried over: a canceller whose own call-memory
    /// survives the break would be tipped over by the second batch alone and
    /// fall back to the raw microphone, corrupting that chunk. Counting the
    /// factory's own calls would test the mechanism, not this: instead the
    /// fake canceller's budget is set so only *shared* memory across the
    /// break trips it, and the assertion is on the chunk's actual samples.
    func testFrameJumpGivesTheNextSegmentAFreshEchoCanceller() async throws {
        let rate = Self.rate16
        var generator = SeededGenerator(seed: 120)
        let firstCount = 8_000
        let firstSpeech = (0..<firstCount).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let firstSystem = [Float](repeating: 0, count: firstCount)
        let firstSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: 0, system: firstSystem, microphone: firstSpeech, dropped: 0
        )

        let newOrigin: Int64 = 10 * Int64(rate)
        let secondCount = 8_000
        let secondSpeech = (0..<secondCount).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let secondSystem = [Float](repeating: 0, count: secondCount)
        let secondSnapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: newOrigin,
            system: secondSystem, microphone: secondSpeech, dropped: 0
        )

        let raw = await run([firstSnapshot, secondSnapshot], detector: alwaysSpeechDetector())
            .chunks.filter { $0.track == .microphone }

        // A real factory makes a fresh instance every time it is asked for
        // one, with its own counter starting at zero; this one does the
        // same. Just above the first batch alone: only a canceller instance
        // *carried over* the break (never asked for again) accumulates past
        // it; a fresh one per break stays well under it.
        let withMemoryCanceller = await run(
            [firstSnapshot, secondSnapshot], detector: alwaysSpeechDetector(),
            makeEchoCanceller: { CountingThenFailingCanceller(failAfterTotalSamples: firstCount + 10) }
        ).chunks.filter { $0.track == .microphone }

        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(withMemoryCanceller.count, 1)
        guard let rawChunk = raw.first, let chunk = withMemoryCanceller.first else { return }
        let compareCount = min(rawChunk.samples.count, chunk.samples.count)
        XCTAssertGreaterThan(compareCount, 0)
        for i in 0..<compareCount {
            XCTAssertEqual(chunk.samples[i], rawChunk.samples[i] * 0.7, accuracy: 1e-5)
        }
    }

    func testPollWithoutDataIsNotABreak() async throws {
        let rate = Self.rate16
        let halfSecond = Int(rate)
        var generator = SeededGenerator(seed: 40)
        let firstHalf = (0..<halfSecond).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let secondHalf = (0..<halfSecond).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }

        let source = QueueSource([
            LiveTranscript.Audio(
                sampleRate: rate, microphoneChannels: 1, firstFrame: 0,
                system: firstHalf, microphone: [Float](repeating: 0, count: firstHalf.count), dropped: 0
            ),
        ])
        let transcript = LiveTranscript(source: { await source.pop() }, detector: levelDetector())
        await transcript.drain()
        // An empty poll in between: the source has nothing right now.
        await transcript.drain()
        await source.push(LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: Int64(halfSecond),
            system: secondHalf, microphone: [Float](repeating: 0, count: secondHalf.count), dropped: 0
        ))
        await transcript.drain()
        await transcript.finish()
        let chunks = await transcript.takeChunks()

        XCTAssertEqual(chunks.count, 1)
        guard let chunk = chunks.first else { return }
        XCTAssertEqual(chunk.end - chunk.start, 2.0, accuracy: 0.05)
    }

    // MARK: - 5. Stereo mixed like the batch path

    func testStereoMicrophoneIsMixedLikeBatchPath() async throws {
        let rate = 48_000.0
        let seconds = 3.0
        let frames = Int(seconds * rate)
        var leftGenerator = SeededGenerator(seed: 50)
        var rightGenerator = SeededGenerator(seed: 51)
        let left = (0..<frames).map { _ in Float(0.3) * Float.random(in: -1...1, using: &leftGenerator) }
        let right = (0..<frames).map { _ in Float(0.3) * Float.random(in: -1...1, using: &rightGenerator) }
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcript-stereo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("stereo.caf")
        let fileFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false
        ))
        let fileBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(frames)))
        fileBuffer.frameLength = AVAudioFrameCount(frames)
        let leftChannel = try XCTUnwrap(fileBuffer.floatChannelData?[0])
        let rightChannel = try XCTUnwrap(fileBuffer.floatChannelData?[1])
        for i in 0..<frames {
            leftChannel[i] = left[i]
            rightChannel[i] = right[i]
        }
        let file = try AVAudioFile(
            forWriting: fileURL, settings: fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: fileBuffer)

        let (reference, _) = try AudioSourceFactory().makeDiskBackedSource(from: fileURL, targetSampleRate: 16_000)
        defer { reference.cleanup() }
        var referenceSamples = [Float](repeating: 0, count: reference.sampleCount)
        try referenceSamples.withUnsafeMutableBufferPointer {
            try reference.copySamples(into: $0.baseAddress!, offset: 0, count: reference.sampleCount)
        }

        let system = [Float](repeating: 0, count: frames)
        let snapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 2, firstFrame: 0, system: system, microphone: interleaved, dropped: 0
        )
        let (chunks, _) = await run([snapshot], detector: alwaysSpeechDetector())

        let microphoneChunks = chunks.filter { $0.track == .microphone }
        XCTAssertEqual(microphoneChunks.count, 1)
        guard let chunk = microphoneChunks.first else { return }

        let compareCount = min(chunk.samples.count, referenceSamples.count)
        XCTAssertGreaterThan(compareCount, 1000)
        var maxDiff: Float = 0
        for i in 0..<compareCount {
            maxDiff = max(maxDiff, abs(chunk.samples[i] - referenceSamples[i]))
        }
        print("live-transcript stereo mix: max |diff| vs makeDiskBackedSource = \(maxDiff) over \(compareCount) samples")
        XCTAssertLessThan(maxDiff, 1e-3)
    }

    // MARK: - 6. Echo cancellation falls back to the raw microphone

    func testEchoCancellerFailureFallsBackToRawMicrophone() async throws {
        let rate = Self.rate16
        let sliceFrames = 8000
        var generator = SeededGenerator(seed: 60)
        let speech = (0..<(sliceFrames * 5)).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let system = [Float](repeating: 0, count: speech.count)
        let snapshots = (0..<5).map { index -> LiveTranscript.Audio in
            let range = (index * sliceFrames)..<((index + 1) * sliceFrames)
            return LiveTranscript.Audio(
                sampleRate: rate, microphoneChannels: 1, firstFrame: Int64(index * sliceFrames),
                system: Array(system[range]), microphone: Array(speech[range]), dropped: 0
            )
        }

        let raw = await run(snapshots, detector: alwaysSpeechDetector()).chunks.filter { $0.track == .microphone }
        let canceller = FailingCanceller(failOnCall: 3)
        let failing = await run(
            snapshots, detector: alwaysSpeechDetector(), makeEchoCanceller: { canceller }
        ).chunks.filter { $0.track == .microphone }

        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(failing.count, 1)
        guard let rawChunk = raw.first, let failingChunk = failing.first else { return }
        // Exactly where the scaling stops depends on how the streaming
        // converter happened to split the signal into calls; read it from
        // the fake canceller itself rather than assuming `sliceFrames` lines
        // up with a call.
        let boundary = canceller.successfulLengths.reduce(0, +)
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertLessThan(boundary, failingChunk.samples.count)
        assertClose(failingChunk.samples.count, rawChunk.samples.count, tolerance: 4)
        let compareCount = min(failingChunk.samples.count, rawChunk.samples.count, boundary)
        for i in 0..<compareCount {
            XCTAssertEqual(failingChunk.samples[i], rawChunk.samples[i] * 0.5, accuracy: 1e-5)
        }
        let tailStart = boundary
        let tailEnd = min(failingChunk.samples.count, rawChunk.samples.count)
        for i in tailStart..<tailEnd {
            XCTAssertEqual(failingChunk.samples[i], rawChunk.samples[i], accuracy: 1e-5)
        }
    }

    func testEchoCancellerCreationFailureUsesRawMicrophone() async throws {
        let rate = Self.rate16
        var generator = SeededGenerator(seed: 61)
        let speech = (0..<16000).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let system = [Float](repeating: 0, count: speech.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: rate, microphoneChannels: 1, firstFrame: 0, system: system, microphone: speech, dropped: 0
        )

        let raw = await run([snapshot], detector: alwaysSpeechDetector()).chunks.filter { $0.track == .microphone }
        let factory = AlwaysFailingFactory()
        let withFailingFactory = await run(
            [snapshot], detector: alwaysSpeechDetector(), makeEchoCanceller: { try factory.make() }
        ).chunks.filter { $0.track == .microphone }

        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(withFailingFactory.count, 1)
        guard let rawChunk = raw.first, let failedChunk = withFailingFactory.first else { return }
        let compareCount = min(rawChunk.samples.count, failedChunk.samples.count)
        for i in 0..<compareCount {
            XCTAssertEqual(failedChunk.samples[i], rawChunk.samples[i], accuracy: 1e-5)
        }
    }

    // MARK: - 7. The bounded queue

    func testQueueKeepsEightNewestAndCountsSkipped() async throws {
        let onePattern: [(Bool, Int)] = [(true, 3), (false, 2)]
        var pattern: [(Bool, Int)] = []
        for _ in 0..<10 { pattern.append(contentsOf: onePattern) }
        let system = segmentSignal(pattern: pattern, rate: Self.rate16, seed: 70)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )

        let source = QueueSource([snapshot])
        let transcript = LiveTranscript(source: { await source.pop() }, detector: levelDetector())
        await transcript.drain()
        let chunks = await transcript.takeChunks()
        let skipped = await transcript.skippedChunks

        XCTAssertEqual(chunks.count, 8)
        XCTAssertEqual(skipped, 2)
        guard chunks.count == 8 else { return }
        // Not just eight chunks and a count of two dropped: the two oldest
        // (segments 1 and 2) are the ones gone — what is kept is segments
        // 3…10, identified by their own start time, in order.
        let segmentBlocks = onePattern.reduce(0) { $0 + $1.1 }
        for (offset, chunk) in chunks.enumerated() {
            let segmentIndex = offset + 2
            // The gap between segments is exactly the 2 silent blocks that
            // close the previous chunk — entirely spent closing it, leaving
            // nothing over for this chunk's own pre-roll.
            let expectedStart = Double(segmentIndex * segmentBlocks * Self.block16) / Self.rate16
            XCTAssertEqual(chunk.start, expectedStart, accuracy: 1e-3, "segment \(segmentIndex + 1)")
        }
    }

    // MARK: - 8. `finish()` flushes the tail and stops accepting

    func testFinishFlushesTailAndStopsAccepting() async throws {
        var generator = SeededGenerator(seed: 80)
        let oneSecond = Int(Self.rate16)
        let speech = (0..<oneSecond).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let system = [Float](repeating: 0, count: speech.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: speech, dropped: 0
        )

        let source = QueueSource([snapshot])
        let transcript = LiveTranscript(source: { await source.pop() }, detector: alwaysSpeechDetector())
        await transcript.drain()
        let beforeFinish = await transcript.takeChunks()
        XCTAssertTrue(beforeFinish.isEmpty)

        await transcript.finish()
        let flushed = (await transcript.takeChunks()).filter { $0.track == .microphone }
        XCTAssertEqual(flushed.count, 1)
        guard let chunk = flushed.first else { return }
        // The whole second of speech, give or take a handful of samples from
        // the streaming converter — not a `pending` tail silently dropped at
        // `finish()`, which would be short by up to a whole VAD block.
        assertClose(chunk.samples.count, oneSecond, tolerance: 8)

        let callsBefore = await source.calls
        await source.push(snapshot)
        await transcript.drain()
        let callsAfter = await source.calls
        XCTAssertEqual(callsBefore, callsAfter)
        let afterReplay = await transcript.takeChunks()
        XCTAssertTrue(afterReplay.isEmpty)
    }

    func testFinishDropsATailShorterThanMinimum() async throws {
        var generator = SeededGenerator(seed: 81)
        let shortCount = Int(0.2 * Self.rate16)
        let speech = (0..<shortCount).map { _ in Float(0.3) * Float.random(in: -1...1, using: &generator) }
        let system = [Float](repeating: 0, count: speech.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: speech, dropped: 0
        )
        let chunks = await run([snapshot], detector: alwaysSpeechDetector()).chunks.filter { $0.track == .microphone }
        XCTAssertEqual(chunks.count, 0)
    }

    // MARK: - 9. The periodic task drains the source by itself

    func testPeriodicTaskDrainsSource() async throws {
        let pattern: [(Bool, Int)] = [(true, 4), (false, 2)]
        let system = segmentSignal(pattern: pattern, rate: Self.rate16, seed: 90)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshot = LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0, system: system, microphone: microphone, dropped: 0
        )
        let source = QueueSource([snapshot])
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(), pollInterval: .milliseconds(10)
        )
        await transcript.start()

        let expectation = XCTestExpectation(description: "a chunk appears on its own")
        let watcher = Task {
            while !Task.isCancelled {
                if !(await transcript.takeChunks().isEmpty) {
                    expectation.fulfill()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await fulfillment(of: [expectation], timeout: 5)
        watcher.cancel()
        await transcript.finish()
    }

    // MARK: - Recognition pipeline

    /// A signal with an explicit amplitude per segment, instead of
    /// `segmentSignal`'s fixed 0.3: `LiveLevelEngine` keys its reply on the
    /// chunk's amplitude, so distinguishable segments need distinguishable
    /// levels.
    private func amplitudeSignal(pattern: [(speech: Bool, blocks: Int, amplitude: Float)], seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        let frames = blockFrames(rate: Self.rate16)
        var samples: [Float] = []
        for segment in pattern {
            for _ in 0..<(segment.blocks * frames) {
                samples.append(segment.speech ? segment.amplitude * Float.random(in: -1...1, using: &generator) : 0)
            }
        }
        return samples
    }

    private func padded(_ a: [Float], _ b: [Float]) -> (a: [Float], b: [Float]) {
        let length = max(a.count, b.count)
        return (a + [Float](repeating: 0, count: length - a.count), b + [Float](repeating: 0, count: length - b.count))
    }

    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func makeRecognition(
        factory: any WhisperEngineFactory,
        modelMissing: @escaping @Sendable () async -> Bool = { false },
        dictionaryReplacer: DictionaryReplacer? = nil,
        feed: @escaping @Sendable () async -> [CallFeed.Event] = { [] },
        language: String? = "en",
        windowSeconds: Double = 120,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        interimSeconds: Double? = nil,
        lineLimit: Int = LiveTranscriptModel.maximumLines
    ) async -> (recognition: LiveTranscript.Recognition, model: LiveTranscriptModel) {
        let model = await MainActor.run { LiveTranscriptModel() }
        let cache = WhisperKitCache(factory: factory)
        let engine = MeetingTranscriber.Engine(
            descriptor: EngineDescriptor(engine: .whisper, modelPath: "/tmp/live-model-\(UUID().uuidString)"),
            request: .whisper(WhisperDecodeRequest(language: language)),
            label: "Whisper (test model)"
        )
        let recognition = LiveTranscript.Recognition(
            cache: cache, engine: engine, modelMissing: modelMissing,
            dictionaryReplacer: dictionaryReplacer, callFeedEvents: feed, model: model,
            temporaryRoot: temporaryRoot, windowSeconds: windowSeconds, interimSeconds: interimSeconds,
            lineLimit: lineLimit
        )
        return (recognition, model)
    }

    // MARK: - 10. Lines for both tracks, in order, labelled without a feed

    func testRecognitionProducesLinesInOrderWithTrackLabels() async throws {
        // `LiveLevelEngine` keys on the chunk file's own median absolute
        // sample, which for `amplitude * uniform(-1, 1)` noise comes out at
        // about `amplitude / 2`, not `amplitude` itself — the reply keys
        // below match that, not the generator's own parameter.
        let (mic, system) = padded(
            amplitudeSignal(pattern: [(false, 3, 0), (true, 6, 0.3), (false, 2, 0)], seed: 101),
            amplitudeSignal(pattern: [(true, 6, 0.9), (false, 2, 0), (false, 9, 0)], seed: 102)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.15: "второе предложение", 0.45: "первое предложение"])
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotBoth = await eventually { await model.lines.count >= 2 }
        XCTAssertTrue(gotBoth)
        await transcript.finish()

        let lines = await model.lines
        XCTAssertEqual(lines.map(\.track), [.system, .microphone])
        XCTAssertEqual(lines.map(\.displayText), ["первое предложение", "второе предложение"])
        XCTAssertTrue(lines.allSatisfy { $0.name == nil })
        XCTAssertTrue(lines.allSatisfy(\.isFinal))
    }

    // MARK: - 11. A microphone line hides once its echo partner arrives

    func testEchoedMicrophoneLineHidesAfterMatchingSystemLineArrives() async throws {
        // The microphone's speech closes well before the system's own
        // (fewer blocks, same start): its chunk is enqueued — and
        // recognized — first, so the test can see it shown before the
        // overlapping system line arrives and hides it.
        let (mic, system) = padded(
            amplitudeSignal(pattern: [(true, 8, 0.4), (false, 4, 0)], seed: 111),
            amplitudeSignal(pattern: [(true, 12, 0.4), (false, 2, 0)], seed: 999)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        // A small delay on every request, so the microphone's own line has
        // a real window on screen before the system line (recognized right
        // after it, one request at a time) arrives and hides it — without
        // one, both can finish within a single poll of `model.lines`.
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.4: "привет как твои дела"], delay: .milliseconds(80))
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let micShown = await eventually { await model.lines.contains { $0.track == .microphone } }
        XCTAssertTrue(micShown, "the microphone line must appear before its echo partner is recognized")

        let micHidden = await eventually(timeout: .seconds(8)) {
            let lines = await model.lines
            return lines.count == 1 && lines.first?.track == .system
        }
        XCTAssertTrue(micHidden, "the microphone line must disappear once the matching system line arrives")
        await transcript.finish()
    }

    // MARK: - 12. The personal dictionary changes the shown text, not the raw one

    func testPersonalDictionaryAppliesToDisplayTextOnly() async throws {
        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.6), (false, 2, 0)], seed: 121)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let replacer = DictionarySnapshot(
            entries: [DictionaryEntry(heard: ["фу"], written: "здравствуйте")]
        ).replacer(for: .meetings)
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.6: "фу привет миру"]),
            dictionaryReplacer: replacer
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotLine = await eventually { await !model.lines.isEmpty }
        XCTAssertTrue(gotLine)
        await transcript.finish()

        let finalLines = await model.lines
        let line = try XCTUnwrap(finalLines.first)
        XCTAssertEqual(line.rawText, "фу привет миру")
        XCTAssertEqual(line.displayText, "здравствуйте привет миру")
    }

    // MARK: - 13. Names from the call feed

    func testCallFeedNamesMicrophoneAndSystemLines() async throws {
        let (mic, system) = padded(
            amplitudeSignal(pattern: [(false, 10, 0), (true, 6, 0.3), (false, 2, 0)], seed: 131),
            amplitudeSignal(pattern: [(true, 6, 0.9), (false, 12, 0)], seed: 132)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let feedEvents: [CallFeed.Event] = [
            CallFeed.Event(
                t: 0, service: "test", visible: true, ownName: "Я", selfSpeaking: true,
                people: ["Аня"], speaking: ["Аня"], selfVisible: true
            ),
        ]
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.45: "системная фраза", 0.15: "фраза микрофона"]),
            feed: { feedEvents }
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotBoth = await eventually { await model.lines.count >= 2 }
        XCTAssertTrue(gotBoth)
        await transcript.finish()

        let lines = await model.lines
        let systemLine = try XCTUnwrap(lines.first { $0.track == .system })
        let micLine = try XCTUnwrap(lines.first { $0.track == .microphone })
        XCTAssertEqual(systemLine.name, "Аня")
        XCTAssertEqual(micLine.name, "Я")
    }

    // MARK: - 14. A hung engine never holds up finish(), and never poisons the cache

    func testHungEngineFinishesPromptlyAndCacheRecognizesNextTranscript() async throws {
        let gate = LiveGate()
        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.5), (false, 2, 0)], seed: 141)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let factory = LiveGatedEngineFactory(gate: gate, text: "застрявший кусок")
        let model = await MainActor.run { LiveTranscriptModel() }
        let cache = WhisperKitCache(factory: factory)
        let engine = MeetingTranscriber.Engine(
            descriptor: EngineDescriptor(engine: .whisper, modelPath: "/tmp/live-model-hung"),
            request: .whisper(WhisperDecodeRequest(language: "en")), label: "Whisper (test model)"
        )
        let recognition = LiveTranscript.Recognition(
            cache: cache, engine: engine, modelMissing: { false }, dictionaryReplacer: nil,
            callFeedEvents: { [] }, model: model
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let entered = await eventually { await gate.wasEntered }
        XCTAssertTrue(entered, "the engine must have been asked before finish() is called")

        let started = ContinuousClock.now
        await transcript.finish()
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2), "finish() must not wait for a hung request")

        await gate.open()
        let completed = await eventually(timeout: .seconds(5)) { await gate.didComplete }
        XCTAssertTrue(completed, "the gated request must actually complete once opened")
        // The request has now handed its result back inside the cache; give
        // the recognition task a few scheduling turns to try (and fail) to
        // publish it, instead of guessing a single fixed delay.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            let lines = await model.lines
            XCTAssertTrue(lines.isEmpty, "a result arriving after finish() must never be published")
        }

        // The cache is free again once the gated request actually completes:
        // a second, independent live transcript on it recognizes normally.
        let (mic2, system2) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.9), (false, 2, 0)], seed: 142)
        )
        let snapshots2 = makeSnapshots(
            system: system2, microphone: mic2, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source2 = QueueSource(snapshots2)
        let model2 = await MainActor.run { LiveTranscriptModel() }
        let recognition2 = LiveTranscript.Recognition(
            cache: cache, engine: engine, modelMissing: { false }, dictionaryReplacer: nil,
            callFeedEvents: { [] }, model: model2
        )
        let transcript2 = LiveTranscript(
            source: { await source2.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition2
        )
        await transcript2.start()
        let recognizedAgain = await eventually { await !model2.lines.isEmpty }
        XCTAssertTrue(recognizedAgain, "the cache must not stay stuck busy after a hung request finally completes")
        await transcript2.finish()
    }

    // MARK: - 15. The model is not downloaded

    func testMissingModelNeverCallsEngineAndReportsNoModel() async throws {
        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.5), (false, 2, 0)], seed: 151)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let factory = LiveLevelEngineFactory(replies: [0.5: "не должно распознаться"])
        let (recognition, model) = await makeRecognition(factory: factory, modelMissing: { true })
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotNoModel = await eventually { await model.state == .noModel }
        XCTAssertTrue(gotNoModel)
        try await Task.sleep(for: .milliseconds(200))
        await transcript.finish()

        let finalLines = await model.lines
        XCTAssertTrue(finalLines.isEmpty)
        let calls = await factory.loadCount
        XCTAssertEqual(calls, 0, "a missing model must never reach the engine")
    }

    // MARK: - 16. A slow engine lags; dropped chunks show as skipped

    func testSlowEngineLagsThenAudioSkipsShowAsSkipped() async throws {
        let factory = LiveLevelEngineFactory(replies: [0.3: "кусок"], delay: .milliseconds(300))
        let (recognition, model) = await makeRecognition(factory: factory)
        let source = QueueSource()
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        // Fed gradually, in real time, rather than all at once: each push is
        // its own complete speech-then-silence cycle (one chunk), slower
        // than the audio side's own poll but faster than the 300 ms engine
        // can keep up with, so the queue first lags (≥ 3 pending) and only
        // later, once it is full, starts dropping the oldest chunk.
        let pattern: [(Bool, Int)] = [(true, 3), (false, 2)]
        // Precomputed outside the task: a `Task` body must be `@Sendable`,
        // and this test's own instance methods are not.
        let pushes: [LiveTranscript.Audio] = (0..<20).map { i in
            let samples = segmentSignal(pattern: pattern, rate: Self.rate16, seed: UInt64(1610 + i))
            return LiveTranscript.Audio(
                sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
                system: samples, microphone: [Float](repeating: 0, count: samples.count), dropped: 0
            )
        }
        let feeder = Task {
            for snapshot in pushes {
                guard !Task.isCancelled else { return }
                await source.push(snapshot)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }

        let lagged = await eventually(timeout: .seconds(8)) { await model.state == .lagging }
        XCTAssertTrue(lagged, "a queue of three or more chunks must show as lagging")

        let skipped = await eventually(timeout: .seconds(8)) {
            if case .skipped = await model.state { return true }
            return false
        }
        XCTAssertTrue(skipped, "chunks dropped on the audio side must show as skipped")
        let skippedCount = await transcript.skippedChunks
        let finalState = await model.state
        if case .skipped(let shown) = finalState {
            XCTAssertEqual(shown, skippedCount)
        } else {
            XCTFail("expected .skipped, got \(finalState)")
        }
        feeder.cancel()
        await transcript.finish()
    }

    // MARK: - A hidden echo line stays hidden after it leaves the window

    func testHiddenEchoLineStaysHiddenAfterItLeavesTheWindow() async throws {
        let (mic, system) = padded(
            amplitudeSignal(pattern: [(false, 2, 0), (true, 10, 0.4), (false, 2, 0)], seed: 171),
            amplitudeSignal(pattern: [(true, 12, 0.4), (false, 2, 0)], seed: 998)
        )
        var combinedSystem = system
        var combinedMic = mic
        // Three unrelated, later chunks (system track) push the window far
        // past both the echoed microphone line and its system partner.
        for seed in [172, 173, 174] as [UInt64] {
            combinedSystem.append(contentsOf: amplitudeSignal(pattern: [(true, 6, 0.9), (false, 4, 0)], seed: seed))
            combinedMic.append(contentsOf: [Float](repeating: 0, count: combinedSystem.count - combinedMic.count))
        }
        let (paddedMic, paddedSystem) = padded(combinedMic, combinedSystem)
        let snapshots = makeSnapshots(
            system: paddedSystem, microphone: paddedMic, channels: 1, rate: Self.rate16, firstFrame: 0,
            sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        // Keys at half the generator's own amplitude, as `LiveLevelEngine`
        // keys on the chunk file's median absolute sample, not the
        // generator's parameter.
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.2: "привет как твои дела", 0.45: "совсем другая фраза"]),
            windowSeconds: 2.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotFillers = await eventually(timeout: .seconds(8)) {
            await model.lines.filter { $0.displayText == "совсем другая фраза" }.count >= 3
        }
        XCTAssertTrue(gotFillers, "the later unrelated lines must still show up")
        await transcript.finish()

        let finalLines = await model.lines
        XCTAssertFalse(
            finalLines.contains { $0.track == .microphone },
            "the echoed microphone line must never reappear once its system partner has left the window"
        )
    }

    // MARK: - Whisper's auto language is not fixed by an empty chunk

    func testWhisperAutoLanguageIsNotFixedByEmptyChunk() async throws {
        var pattern: [(speech: Bool, blocks: Int, amplitude: Float)] = []
        for _ in 0..<3 { pattern.append(contentsOf: [(true, 28, 0.6), (false, 2, 0)] as [(Bool, Int, Float)]) }
        let system = amplitudeSignal(pattern: pattern, seed: 181)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshots = makeSnapshots(
            system: system, microphone: microphone, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let engine = LiveScriptedLanguageEngine(replies: [
            .init(text: ".", language: "fr"),
            .init(text: "привет мир друг", language: "de"),
            .init(text: "ещё текст подряд", language: "de"),
        ])
        let (recognition, model) = await makeRecognition(
            factory: LiveScriptedLanguageFactory(engine: engine), language: nil
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotTwoLines = await eventually(timeout: .seconds(8)) { await model.lines.count >= 2 }
        XCTAssertTrue(gotTwoLines)
        await transcript.finish()

        let seen = await engine.seenLanguages
        XCTAssertEqual(seen.count, 3)
        XCTAssertNil(seen[0], "the first request must still ask for auto")
        XCTAssertNil(seen[1], "a chunk with no recognizable words must not fix the language")
        XCTAssertEqual(seen[2], "de", "the first chunk that actually produced a line must fix it")
    }

    // MARK: - Three failures in a row stop with the last error's own text

    func testThreeFailuresInARowStopWithTheLastErrorsOwnText() async throws {
        var pattern: [(speech: Bool, blocks: Int, amplitude: Float)] = []
        for _ in 0..<4 { pattern.append(contentsOf: [(true, 6, 0.5), (false, 2, 0)] as [(Bool, Int, Float)]) }
        let system = amplitudeSignal(pattern: pattern, seed: 251)
        let microphone = [Float](repeating: 0, count: system.count)
        let snapshots = makeSnapshots(
            system: system, microphone: microphone, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, model) = await makeRecognition(factory: AlwaysFailingWhisperEngineFactory())
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let stopped = await eventually(timeout: .seconds(8)) {
            if case .stopped = await model.state { return true }
            return false
        }
        XCTAssertTrue(stopped, "three failures in a row must stop the pipeline")
        await transcript.finish()

        let finalState = await model.state
        guard case .stopped(let message) = finalState else {
            XCTFail("expected .stopped, got \(finalState)")
            return
        }
        let expected = try XCTUnwrap(LiveChunkFailure().errorDescription)
        XCTAssertEqual(message, expected, "the shown text must be the error's own, not a new interface string")
        let linesAfterStop = await model.lines
        XCTAssertTrue(linesAfterStop.isEmpty, "a never-recognized chunk must never produce a line")
    }

    // MARK: - Nothing publishes into the model after finish(), including mid-load

    func testFinishDuringModelLoadPublishesNothingAfterwardOnceTheLoadCompletes() async throws {
        let gate = LiveGate()
        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.5), (false, 2, 0)], seed: 252)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, model) = await makeRecognition(
            factory: LiveGatedLoadFactory(gate: gate, replies: [0.25: "после загрузки"])
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let loading = await eventually { await model.state == .preparingModel }
        XCTAssertTrue(loading, "the model load must be reported before finish() is ever called")
        let stateBeforeFinish = await model.state

        let started = ContinuousClock.now
        await transcript.finish()
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2), "finish() must not wait for a load already in progress")

        await gate.open()
        let completed = await eventually(timeout: .seconds(5)) { await gate.didComplete }
        XCTAssertTrue(completed, "the gated load must actually complete once opened")
        // The load has now finished inside the cache; give the orphaned
        // recognition task a few scheduling turns to try (and fail) to
        // publish its result, instead of guessing a single fixed delay.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            let stateNow = await model.state
            let linesNow = await model.lines
            XCTAssertEqual(stateNow, stateBeforeFinish, "nothing may publish into the model after finish()")
            XCTAssertTrue(linesNow.isEmpty)
        }
    }

    // MARK: - The chunk's temporary file is removed after a request and after a cancelled one

    func testTempChunkDirectoryIsRemovedAfterARequest() async throws {
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcript-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.5), (false, 2, 0)], seed: 253)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.25: "готово"]), temporaryRoot: workRoot
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotLine = await eventually { await !model.lines.isEmpty }
        XCTAssertTrue(gotLine)
        await transcript.finish()

        let leftover = try FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftover.isEmpty, "the chunk's temporary directory must be removed after its own request: \(leftover)")
    }

    func testTempChunkDirectoryIsRemovedEvenAfterACancelledRequest() async throws {
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcript-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let gate = LiveGate()
        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.5), (false, 2, 0)], seed: 254)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, _) = await makeRecognition(
            factory: LiveGatedEngineFactory(gate: gate, text: "застрявший кусок"), temporaryRoot: workRoot
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let entered = await eventually { await gate.wasEntered }
        XCTAssertTrue(entered, "the engine must have been asked, and the chunk file written, before finish() is called")
        let duringRequest = try FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(duringRequest.count, 1, "exactly one chunk directory must exist while the request is in flight")

        await transcript.finish()
        await gate.open()
        let completed = await eventually(timeout: .seconds(5)) { await gate.didComplete }
        XCTAssertTrue(completed, "the cancelled-but-orphaned request must actually complete once opened")

        var cleaned = false
        for _ in 0..<50 {
            let remaining = try FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)
            if remaining.isEmpty { cleaned = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(cleaned, "the chunk's temporary directory must be removed even for a request cancelled mid-flight")
    }

    // MARK: - Names through the real CallFeedWatcher, not a fake array

    func testRealCallFeedWatcherNamesASystemLine() async throws {
        let feedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcript-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: feedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: feedDirectory) }

        let event = CallFeed.Event(
            t: 0, service: "test", visible: true, ownName: nil, selfSpeaking: false,
            people: ["Аня"], speaking: ["Аня"]
        )
        let pin = MeetingPageReader.Pin(service: "test", app: "test-app", meeting: nil)
        let watcher = CallFeedWatcher(
            directory: feedDirectory,
            snapshotSource: { _ in .found(event, pin) },
            writtenSeconds: { 0 },
            isEnabled: { true },
            interval: .milliseconds(5)
        )
        await watcher.start()
        let gotEvent = await eventually { await !(watcher.events().isEmpty) }
        XCTAssertTrue(gotEvent, "the real watcher must have written and kept at least one event")

        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.6), (false, 2, 0)], seed: 255)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.3: "фраза от Ани"]),
            feed: { await watcher.events() }
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotLine = await eventually { await !model.lines.isEmpty }
        XCTAssertTrue(gotLine)
        await transcript.finish()
        await watcher.finish()

        let namedLines = await model.lines
        let line = try XCTUnwrap(namedLines.first)
        XCTAssertEqual(line.name, "Аня", "the name must come from the real watcher's own events(), not a fake array")
    }

    // MARK: - A trailing closing line never un-names an earlier, already-ended line

    func testClosingFeedLineDoesNotUnnameAnEarlierSystemLine() async throws {
        let feed = FeedBox([
            CallFeed.Event(
                t: 0, service: "test", visible: true, ownName: nil, selfSpeaking: false,
                people: ["Аня"], speaking: ["Аня"]
            ),
        ])

        let (mic, system) = padded(
            [Float](repeating: 0, count: 1),
            amplitudeSignal(pattern: [(true, 6, 0.6), (false, 2, 0)], seed: 256)
        )
        let snapshots = makeSnapshots(
            system: system, microphone: mic, channels: 1, rate: Self.rate16, firstFrame: 0, sizes: [Self.block16]
        )
        let source = QueueSource(snapshots)
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.3: "фраза", 0.45: "вторая фраза"]),
            feed: { feed.snapshot() }
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotFirstLine = await eventually { await !model.lines.isEmpty }
        XCTAssertTrue(gotFirstLine)
        let linesBeforeClose = await model.lines
        let nameBeforeClose = try XCTUnwrap(linesBeforeClose.first).name
        XCTAssertEqual(nameBeforeClose, "Аня")

        // The feed's own closing line, as `CallFeedWatcher.finish()` would
        // append it: visible false, no names, dated long after this line
        // already ended.
        feed.append(CallFeed.Event(
            t: 999, service: "test", visible: false, ownName: nil, selfSpeaking: false, people: [], speaking: []
        ))
        // Force a recompute under the grown feed: an unrelated, later chunk.
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: Int64(system.count),
            system: amplitudeSignal(pattern: [(true, 6, 0.9), (false, 2, 0)], seed: 257),
            microphone: [Float](repeating: 0, count: blockFrames(rate: Self.rate16) * 8), dropped: 0
        ))
        let gotSecondLine = await eventually { await model.lines.count >= 2 }
        XCTAssertTrue(gotSecondLine)
        await transcript.finish()

        let linesAfterClose = await model.lines
        let firstLine = try XCTUnwrap(linesAfterClose.first)
        XCTAssertEqual(
            firstLine.name, "Аня",
            "the closing (visible: false) line, dated after this line already ended, must not un-name it"
        )
    }

    // MARK: - A visible line past the window and echo margin stays under the line cap

    func testEarlyVisibleLineStaysUntilTheLineCapIsReached() async throws {
        let earlySystem = amplitudeSignal(pattern: [(true, 6, 0.3), (false, 2, 0)], seed: 271)
        let earlyMic = [Float](repeating: 0, count: 1)
        let (paddedEarlyMic, paddedEarlySystem) = padded(earlyMic, earlySystem)
        let source = QueueSource([LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
            system: paddedEarlySystem, microphone: paddedEarlyMic, dropped: 0
        )])
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.15: "ранняя фраза", 0.45: "наполнитель"]),
            windowSeconds: 2.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotEarly = await eventually { await !model.lines.isEmpty }
        XCTAssertTrue(gotEarly)
        let linesAtStart = await model.lines
        let earlyID = try XCTUnwrap(linesAtStart.first).id

        // Nine unrelated filler chunks of about 2 s each push the window more
        // than `windowSeconds + maximumChunkSeconds` (17 s) past the early
        // line's own end — well under the model's own line cap, so the early
        // line must be kept rather than dropped for being out of the
        // recompute window alone.
        var frame = Int64(paddedEarlySystem.count)
        for (index, seed) in Array(280..<289).enumerated() {
            let fillerSystem = amplitudeSignal(pattern: [(true, 6, 0.9), (false, 2, 0)], seed: UInt64(seed))
            let fillerMic = [Float](repeating: 0, count: fillerSystem.count)
            await source.push(LiveTranscript.Audio(
                sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: frame,
                system: fillerSystem, microphone: fillerMic, dropped: 0
            ))
            frame += Int64(fillerSystem.count)
            let gotFiller = await eventually(timeout: .seconds(5)) {
                await model.lines.filter { $0.displayText == "наполнитель" }.count >= index + 1
            }
            XCTAssertTrue(gotFiller, "filler \(index) must be recognized")
        }
        await transcript.finish()

        let lines = await model.lines
        XCTAssertTrue(
            lines.contains { $0.id == earlyID },
            "a visible line must stay in the model while fewer than its own cap of lines exist, "
                + "however far behind the window it falls"
        )
        XCTAssertEqual(lines.count, 10, "the early line plus the nine fillers, none dropped")
    }

    // MARK: - Five hundred chunks keep exactly the pipeline's own line cap

    /// A `lineLimit` override of 200, not the model's real 5000: 500 chunks
    /// at the real cap would need thousands of chunks and minutes to prove
    /// anything. The cap itself, and the cut-start flag it sets, are the
    /// recompute pipeline's own behaviour — this is the seam that exercises
    /// it, not a test of the production constant.
    func testFiveHundredChunksKeepExactlyTheLineCap() async throws {
        let chunkPattern: [(speech: Bool, blocks: Int, amplitude: Float)] = [(true, 2, 0.6), (false, 2, 0)]
        let source = QueueSource()
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.3: "кусок"]), windowSeconds: 2.0, lineLimit: 200
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(2),
            recognition: recognition
        )
        await transcript.start()

        // Paced, not dumped all at once: pushing every chunk in one tight
        // loop would fill the bounded ingestion queue (capacity 8) before
        // the recognition pipeline — one request at a time — ever got a
        // chance to drain it, so almost everything would show up as
        // `skippedChunks` rather than as a recognized line.
        var frame: Int64 = 0
        for index in 0..<500 {
            let samples = amplitudeSignal(pattern: chunkPattern, seed: UInt64(300 + index))
            await source.push(LiveTranscript.Audio(
                sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: frame,
                system: samples, microphone: [Float](repeating: 0, count: samples.count), dropped: 0
            ))
            frame += Int64(samples.count)
            try? await Task.sleep(for: .milliseconds(5))
        }

        let gotAll = await eventually(timeout: .seconds(60)) {
            await model.lines.count == 200
        }
        XCTAssertTrue(gotAll, "the model must settle at exactly its own line-limit cap once enough chunks have been recognized")
        await transcript.finish()

        let lines = await model.lines
        XCTAssertEqual(lines.count, 200)
        // Each chunk advances the recording clock by about 1 s (two speech
        // blocks plus two silent ones); with 500 pushed and only 200 kept,
        // the earliest surviving line can only be one recognized well after
        // the start — proof the trim kept the later lines, not whichever 200
        // happened to still be around.
        let firstStart = try XCTUnwrap(lines.first).start
        XCTAssertGreaterThan(firstStart, 200, "the surviving lines must be the later ones, not the earliest 200")
        let hasEarlierLines = await model.hasEarlierLines
        XCTAssertTrue(hasEarlierLines, "dropping visible lines over the cap must set the cut-start flag")
    }

    // MARK: - A late feed event renames an active line but never a frozen one

    func testLateFeedEventRenamesAnActiveLineButNeverAFrozenOne() async throws {
        let feed = FeedBox()

        let (mic1, system1) = padded(
            amplitudeSignal(pattern: [(true, 6, 0.3), (false, 2, 0)], seed: 261),
            [Float](repeating: 0, count: 1)
        )
        let source = QueueSource([LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
            system: system1, microphone: mic1, dropped: 0
        )])
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.15: "первая фраза", 0.3: "наполнитель", 0.45: "вторая фраза"]),
            feed: { feed.snapshot() }, windowSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let gotFirstLine = await eventually { await !model.lines.isEmpty }
        XCTAssertTrue(gotFirstLine)
        let linesAtStart = await model.lines
        let firstLineID = try XCTUnwrap(linesAtStart.first { $0.track == .microphone }).id

        // Three unrelated, later filler chunks (system track) push the
        // window (1 s wide) far past the first microphone line's own end,
        // freezing it, well before the feed ever grows.
        var frame = Int64(system1.count)
        for (index, seed) in ([262, 263, 264] as [UInt64]).enumerated() {
            let fillerSystem = amplitudeSignal(pattern: [(true, 6, 0.6), (false, 2, 0)], seed: seed)
            let fillerMic = [Float](repeating: 0, count: fillerSystem.count)
            await source.push(LiveTranscript.Audio(
                sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: frame,
                system: fillerSystem, microphone: fillerMic, dropped: 0
            ))
            frame += Int64(fillerSystem.count)
            let gotFiller = await eventually(timeout: .seconds(5)) {
                await model.lines.filter { $0.track == .system }.count >= index + 1
            }
            XCTAssertTrue(gotFiller, "filler \(index) must be recognized")
        }

        // Dated at t: 0, before every line's own end — exactly the shape
        // `pickedNames` would use to name the first line too, were it still
        // active.
        feed.append(CallFeed.Event(
            t: 0, service: "test", visible: true, ownName: "Иван", selfSpeaking: true, people: [], speaking: []
        ))

        let (mic2, system2) = padded(
            amplitudeSignal(pattern: [(true, 6, 0.9), (false, 2, 0)], seed: 265),
            [Float](repeating: 0, count: 1)
        )
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: frame,
            system: system2, microphone: mic2, dropped: 0
        ))

        let gotSecondMicLine = await eventually(timeout: .seconds(5)) {
            await model.lines.contains { $0.track == .microphone && $0.id != firstLineID }
        }
        XCTAssertTrue(gotSecondMicLine, "the second microphone line must appear")
        await transcript.finish()

        let lines = await model.lines
        let firstLine = lines.first { $0.id == firstLineID }
        let secondLine = lines.first { $0.track == .microphone && $0.id != firstLineID }
        XCTAssertEqual(
            firstLine?.name, nil,
            "a feed event added after the line left the recompute window must never rename it, even though "
                + "pickedNames itself would have named it from this same event"
        )
        XCTAssertEqual(secondLine?.name, "Иван", "the same feed event must still name a line still inside the window")
    }

    // MARK: - 17. A growing interim line, then the final line replaces it

    func testLongChunkShowsGrowingInterimLineThenFinalReplacesIt() async throws {
        let engine = LiveLengthEngine()
        let source = QueueSource()
        let (recognition, model) = await makeRecognition(
            factory: LiveLengthEngineFactory(engine: engine), interimSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        let observer = await LinesObserver(model)
        await transcript.start()

        var frame: Int64 = 0
        var firstID: UUID?
        for k in 1...6 {
            // 4 blocks (≈1.02 s) of continuous speech: each push grows the
            // open chunk by just over the 1 s interim threshold, so exactly
            // one interim request fires per push.
            let block = scriptedTrackSignal(blocks: 4, seed: UInt64(1000 + k))
            await source.push(LiveTranscript.Audio(
                sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: frame,
                system: block, microphone: [Float](repeating: 0, count: block.count), dropped: 0
            ))
            frame += Int64(block.count)

            // `engine.calls.count` ticks up as soon as the engine is asked,
            // well before the result works its way back through the
            // pipeline and into the model — wait for the publication
            // itself, not the request that led to it.
            let got = await eventually(timeout: .seconds(5)) { await model.lines.first?.displayText == "речь \(k)" }
            XCTAssertTrue(got, "interim update \(k) must have been published")
            let lines = await model.lines
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(lines.first?.isFinal, false, "the chunk is still open at push \(k)")
            if firstID == nil { firstID = lines.first?.id }
        }

        let silence = [Float](repeating: 0, count: 2 * blockFrames(rate: Self.rate16))
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: frame,
            system: silence, microphone: [Float](repeating: 0, count: silence.count), dropped: 0
        ))
        let gotFinal = await eventually(timeout: .seconds(5)) { await model.lines.first?.isFinal == true }
        XCTAssertTrue(gotFinal)
        await transcript.finish()

        let lines = await model.lines
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.id, firstID, "the final line must replace the interim one, keeping its id")
        XCTAssertEqual(lines.first?.isFinal, true)

        let interimSnapshots = await observer.snapshots.filter { $0.contains { !$0.isFinal } }
        XCTAssertGreaterThanOrEqual(interimSnapshots.count, 4, "at least four interim updates must have been published")
        XCTAssertTrue(
            interimSnapshots.allSatisfy { $0.count == 1 && $0.first?.id == firstID },
            "every interim publication must show exactly one line, always the same id"
        )
    }

    // MARK: - 18. An interim request never goes while a final chunk is queued

    func testInterimWaitsWhileAFinalChunkIsQueued() async throws {
        let systemPattern: [(speech: Bool, blocks: Int, amplitude: Float)] = [
            (true, 6, 0.9), (false, 2, 0), (true, 6, 0.9), (false, 2, 0),
        ]
        let system = amplitudeSignal(pattern: systemPattern, seed: 1101)
        // Continuous speech for every one of the system's 16 blocks, no
        // trailing silence: its chunk stays open the whole time, so it
        // is only ever an interim candidate, never a final one here.
        let microphone = amplitudeSignal(pattern: [(true, 16, 0.3)], seed: 1102)
        XCTAssertEqual(system.count, microphone.count)

        let engine = LiveLengthEngine()
        let source = QueueSource()
        let (recognition, _) = await makeRecognition(
            factory: LiveLengthEngineFactory(engine: engine), interimSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
            system: system, microphone: microphone, dropped: 0
        ))
        // Cut before the pipeline starts, so both final system chunks are
        // already queued the moment recognition begins.
        await transcript.drain()
        await transcript.start()

        let gotThree = await eventually(timeout: .seconds(5)) { await engine.calls.count >= 3 }
        XCTAssertTrue(gotThree)
        await transcript.finish()

        let calls = await engine.calls
        XCTAssertGreaterThanOrEqual(calls.count, 3)
        // System noise at amplitude 0.9 sorts to a median magnitude near
        // 0.45; the microphone's 0.3 near 0.15 — well apart from the 0.3
        // split used to tell the tracks apart here.
        XCTAssertGreaterThan(calls[0].level, 0.3, "the first request must be the system's final chunk")
        XCTAssertGreaterThan(calls[1].level, 0.3, "the second request must be the system's other final chunk")
        XCTAssertLessThan(
            calls[2].level, 0.3,
            "only once the final queue is empty does the microphone's interim request go"
        )
    }

    // MARK: - 19. A late interim result is dropped once its chunk has closed

    func testLateInterimResultIsDroppedOnceItsChunkClosed() async throws {
        let gate = LiveGate()
        let engine = LiveLengthEngine(gate: gate)
        let system = scriptedTrackSignal(blocks: 6, seed: 1201)
        let source = QueueSource()
        let (recognition, model) = await makeRecognition(
            factory: LiveLengthEngineFactory(engine: engine), interimSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        let observer = await LinesObserver(model)

        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
            system: system, microphone: [Float](repeating: 0, count: system.count), dropped: 0
        ))
        await transcript.drain()
        await transcript.start()

        let entered = await eventually(timeout: .seconds(5)) { await gate.wasEntered }
        XCTAssertTrue(entered, "the interim request must have started before the chunk closes")

        let silence = [Float](repeating: 0, count: 2 * blockFrames(rate: Self.rate16))
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: Int64(system.count),
            system: silence, microphone: silence, dropped: 0
        ))
        await transcript.drain()

        await gate.open()
        let gotFinal = await eventually(timeout: .seconds(5)) {
            await model.lines.contains { $0.isFinal && $0.track == .system }
        }
        XCTAssertTrue(gotFinal)
        await transcript.finish()

        let snapshots = await observer.snapshots
        XCTAssertFalse(
            snapshots.contains { $0.contains { !$0.isFinal } },
            "the late interim result must never be published once its own chunk has closed"
        )
        let lines = await model.lines
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isFinal)
    }

    // MARK: - 20. `finish()` during an interim request returns at once and publishes nothing

    func testFinishDuringInterimRequestReturnsAtOncePublishingNothing() async throws {
        let gate = LiveGate()
        let engine = LiveLengthEngine(gate: gate)
        let system = scriptedTrackSignal(blocks: 6, seed: 1301)
        let source = QueueSource()
        let (recognition, model) = await makeRecognition(
            factory: LiveLengthEngineFactory(engine: engine), interimSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
            system: system, microphone: [Float](repeating: 0, count: system.count), dropped: 0
        ))
        await transcript.drain()
        await transcript.start()

        let entered = await eventually(timeout: .seconds(5)) { await gate.wasEntered }
        XCTAssertTrue(entered)
        let stateBefore = await model.state

        let started = ContinuousClock.now
        await transcript.finish()
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2), "finish() must not wait for a hung interim request")

        await gate.open()
        let completed = await eventually(timeout: .seconds(5)) { await gate.didComplete }
        XCTAssertTrue(completed, "the gated interim request must actually complete once opened")

        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            let lines = await model.lines
            XCTAssertTrue(lines.isEmpty, "a result arriving after finish() must never be published")
            let state = await model.state
            XCTAssertEqual(state, stateBefore, "state must not change once finish() has been called")
        }
    }

    // MARK: - An interim line gets the dictionary and a feed name, and is hidden as echo, exactly like a final one

    func testInterimLineAppliesDictionaryNameAndEchoHiding() async throws {
        let feed: [CallFeed.Event] = [
            CallFeed.Event(
                t: 0, service: "test", visible: true, ownName: "Я", selfSpeaking: true,
                people: ["Аня"], speaking: ["Аня"], selfVisible: true
            ),
        ]
        let replacer = DictionarySnapshot(
            entries: [DictionaryEntry(heard: ["сервис"], written: "платформа")]
        ).replacer(for: .meetings)
        let source = QueueSource()
        // At least `MeetingTranscriber.minimumEchoWords` (3) words, or the
        // echo check skips the line unconditionally, whatever it overlaps.
        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [
                0.45: "сервис привет всем друзья", 0.15: "привет всем друзья",
            ]),
            dictionaryReplacer: replacer, feed: { feed }, interimSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        let systemSpeech = amplitudeSignal(pattern: [(true, 4, 0.9)], seed: 1401)
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: 0,
            system: systemSpeech, microphone: [Float](repeating: 0, count: systemSpeech.count), dropped: 0
        ))

        let gotSystemInterim = await eventually(timeout: .seconds(5)) {
            await model.lines.contains { $0.track == .system && !$0.isFinal }
        }
        XCTAssertTrue(gotSystemInterim)
        let systemLine = await model.lines.first { $0.track == .system }
        XCTAssertEqual(
            systemLine?.displayText, "платформа привет всем друзья",
            "the personal dictionary must apply to an interim line's displayed text"
        )
        XCTAssertEqual(
            systemLine?.rawText, "сервис привет всем друзья", "the raw text stays as the engine returned it"
        )
        XCTAssertEqual(systemLine?.name, "Аня", "the call feed's name must apply to an interim line")
        XCTAssertEqual(systemLine?.isFinal, false)

        // A fresh microphone chunk whose words are the ones the system's own
        // line (interim, then final once the push below closes it) already
        // carries — the same overlap an echoed final microphone line would
        // show.
        let microphoneSpeech = amplitudeSignal(pattern: [(true, 4, 0.3)], seed: 1402)
        await source.push(LiveTranscript.Audio(
            sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: Int64(systemSpeech.count),
            system: [Float](repeating: 0, count: microphoneSpeech.count), microphone: microphoneSpeech, dropped: 0
        ))

        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            let hasMicrophoneLine = await model.lines.contains { $0.track == .microphone }
            XCTAssertFalse(
                hasMicrophoneLine,
                "a microphone line whose words echo the system track must stay hidden, interim or final"
            )
        }
        await transcript.finish()
    }

    // MARK: - 22. An hour of synthetic speech keeps lines and open chunks bounded

    func testHourOfSyntheticSpeechKeepsLinesAndOpenChunksBounded() async throws {
        let engine = LiveLengthEngine(trackLevel: false)
        let source = QueueSource()
        let (recognition, model) = await makeRecognition(
            factory: LiveLengthEngineFactory(engine: engine), windowSeconds: 120, interimSeconds: 1.0
        )
        let transcript = LiveTranscript(
            source: { await source.pop() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(1),
            recognition: recognition
        )
        await transcript.start()

        let secondSamples = 16_000
        var generator = SeededGenerator(seed: 1501)
        let noise = (0..<secondSamples).map { _ in Float.random(in: -1...1, using: &generator) }
        // 20 s of speech, 2 s of silence, repeating; the microphone shifted
        // by 7 s so the two tracks are never in lockstep.
        func amplitude(atSecond second: Int, phase: Int) -> Float {
            (second + phase) % 22 < 20 ? 0.6 : 0
        }
        let maxRequestSamples = Int(15.2 * 16_000)

        func assertBounds() async {
            let lines = await model.lines
            XCTAssertLessThanOrEqual(lines.count, LiveTranscriptModel.maximumLines)
            XCTAssertLessThanOrEqual(lines.filter { !$0.isFinal && $0.track == .system }.count, 1)
            XCTAssertLessThanOrEqual(lines.filter { !$0.isFinal && $0.track == .microphone }.count, 1)
            let largestOpen = await transcript.largestOpenChunkSamples
            XCTAssertLessThanOrEqual(largestOpen, 15 * 16_000)
            let maxCall = await engine.calls.map(\.samples).max() ?? 0
            XCTAssertLessThanOrEqual(maxCall, maxRequestSamples)
        }

        for second in 0..<3600 {
            let systemAmplitude = amplitude(atSecond: second, phase: 0)
            let microphoneAmplitude = amplitude(atSecond: second, phase: 7)
            let system = noise.map { $0 * systemAmplitude }
            let microphone = noise.map { $0 * microphoneAmplitude }
            // Chunks may be skipped under this pace — allowed here, unlike
            // the queued final chunks in the other tests above.
            await source.push(LiveTranscript.Audio(
                sampleRate: Self.rate16, microphoneChannels: 1, firstFrame: Int64(second * secondSamples),
                system: system, microphone: microphone, dropped: 0
            ))
            try? await Task.sleep(for: .milliseconds(1))

            if second % 100 == 0 {
                await assertBounds()
            }
        }

        await transcript.finish()
        await assertBounds()
    }

    // MARK: - The model's own 5000-line cap, and the cut-start flag it never sets by itself

    /// `publishForTesting` bypasses the recognition pipeline entirely — it
    /// calls `setLines` directly, the same as a late interim result pushing
    /// the published count momentarily over the cap. Trimming to the real
    /// 5000-line cap must still happen, but `hasEarlierLines` must stay
    /// false: only `recompute`'s own count of lines it actually dropped sets
    /// it (`testFiveHundredChunksKeepExactlyTheLineCap`, above, exercises
    /// that through the real pipeline with a small `lineLimit` override).
    @MainActor
    func testModelKeepsFiveThousandLinesAndMarksTheCutStart() throws {
        let model = LiveTranscriptModel()
        let lines = (0..<5_001).map { index in
            LiveLine(
                id: UUID(), track: .system, start: Double(index), end: Double(index) + 1,
                rawText: "строка \(index)", displayText: "строка \(index)", name: nil, isFinal: true
            )
        }
        model.publishForTesting(lines: lines, state: .running)

        XCTAssertEqual(model.lines.count, 5_000)
        // A `suffix` truncation keeps the latest lines, never the earliest.
        XCTAssertEqual(model.lines.first?.displayText, "строка 1")
        XCTAssertEqual(model.lines.last?.displayText, "строка 5000")
        XCTAssertFalse(
            model.hasEarlierLines,
            "setLines' own truncation of an over-the-cap publish must never set the cut-start flag by itself"
        )
    }

    // MARK: - Seam: a line's start matches where its speech really sits in the recorded file

    /// Runs the real `SystemAudioCapture` (the recorder's actual source of
    /// `LiveAudio`, not a synthetic queue) through its DEBUG test seams
    /// (`adoptSessionForTesting`/`deliverCycleForTesting`), so the ground
    /// truth is the bytes `system.caf` actually holds, not this test's own
    /// arithmetic repeated on both sides. The pre-roll `adoptSessionForTesting`
    /// writes ahead of the ring is a constant 0.1, never exact silence, so the
    /// search below for "real speech" uses a threshold above it.
    func testLiveLineStartMatchesSpeechPositionInTheRecordedFile() async throws {
        let rate = Self.rate16
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = SystemAudioCapture()
        let preRollFrames: UInt32 = 4_800
        try await capture.adoptSessionForTesting(
            directory: directory, sampleRate: rate, systemFrames: preRollFrames, microphoneFrames: preRollFrames,
            enqueuedFrames: Int64(preRollFrames), startedAt: Date()
        )

        // A block-aligned, non-random signal (unlike `amplitudeSignal`
        // elsewhere): the exact sample the real speech starts on must be
        // found by scanning the written file, not guessed from noise.
        let block = Self.block16
        var system: [Float] = []
        system.append(contentsOf: [Float](repeating: 0, count: 8 * block))
        system.append(contentsOf: [Float](repeating: 0.6, count: 6 * block))
        system.append(contentsOf: [Float](repeating: 0, count: 4 * block))
        let microphone = [Float](repeating: 0, count: system.count)

        var offset = 0
        let cycleFrames = 4_000
        while offset < system.count {
            let count = min(cycleFrames, system.count - offset)
            await capture.deliverCycleForTesting(
                frames: [UInt32(count), UInt32(count)],
                systemSamples: Array(system[offset..<(offset + count)]),
                microphoneSamples: Array(microphone[offset..<(offset + count)])
            )
            offset += count
        }

        let (recognition, model) = await makeRecognition(
            factory: LiveLevelEngineFactory(replies: [0.6: "речь в файле"])
        )
        let transcript = LiveTranscript(
            source: { await capture.liveAudio() }, detector: levelDetector(),
            makeEchoCanceller: { PassthroughCanceller() }, pollInterval: .milliseconds(5),
            recognition: recognition
        )
        await transcript.start()

        var found = false
        for _ in 0..<500 {
            if await model.lines.contains(where: { $0.displayText == "речь в файле" }) { found = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(found, "the real ring must recognize the chunk written to the real file")
        await transcript.finish()
        _ = try await capture.stop()

        let recognizedLine = await model.lines.first { $0.displayText == "речь в файле" }
        let line = try XCTUnwrap(recognizedLine)

        let file = try AVAudioFile(forReading: directory.appendingPathComponent("system.caf"))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        // Above the pre-roll filler's own 0.1, so the onset found here is the
        // real speech, never the constant the filler itself carries.
        let onsetFrame = try XCTUnwrap(samples.firstIndex { abs($0) > 0.2 })
        let expectedStart = Double(onsetFrame) / rate

        let blockSeconds = Double(block) / rate
        XCTAssertGreaterThanOrEqual(
            line.start, expectedStart - (0.1 + blockSeconds),
            "a line must not claim speech started earlier than the pre-roll pad plus one VAD block before it really did"
        )
        XCTAssertLessThanOrEqual(
            line.start, expectedStart + blockSeconds,
            "a line must not claim speech started later than one VAD block after it really did"
        )
    }
}
