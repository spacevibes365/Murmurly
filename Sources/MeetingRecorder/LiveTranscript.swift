@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import WebRTCAEC3
import os

/// Cuts a meeting's two tracks into speech chunks while the meeting is still
/// being recorded. Its own actor, its own lifetime (created with the
/// recording, finished with it): no recognition, no line model, no wiring
/// into the recorder here — only chunks of 16 kHz mono audio on the way out.
///
/// The audio comes from a closure (`source`) rather than a concrete ring
/// buffer, so tests feed it synthetic snapshots; the recorder's own source
/// is `capture.liveAudio()`, the ring itself. `start()` polls it every
/// `pollInterval` and never waits for anything downstream — the queue
/// (`takeChunks`) is bounded, and a slow or absent consumer only drops the
/// oldest chunk (`skippedChunks`), never blocks ingestion.
actor LiveTranscript {
    /// One snapshot of both tracks since the last poll, at the recording
    /// clock's own rate. `system` is already mono; `microphone` is frames ×
    /// `microphoneChannels`, interleaved, as the file would hold it. The
    /// ring's own snapshot type (`LiveAudio`, `SystemAudioCapture.swift`) is
    /// the one source of truth for this shape; this is that same type.
    typealias Audio = LiveAudio

    enum Track: Sendable, Equatable, CustomStringConvertible {
        case microphone, system
        var description: String {
            switch self {
            case .microphone: return "microphone"
            case .system: return "system"
            }
        }
    }

    /// A finished piece of speech, 16 kHz mono, with its track and its time
    /// in the recording (source frame ÷ clock rate — not a sample count,
    /// which a break would make meaningless).
    struct Chunk: Sendable, Equatable {
        let track: Track
        let start: Double
        let end: Double
        let samples: [Float]
        /// Unique and strictly increasing for the whole meeting, never reset
        /// by a break in the audio — a result naming a number that is no
        /// longer this track's open chunk is stale and dropped.
        let number: Int
    }

    /// Classifies one block of `VadManager.chunkSize` samples (or, at
    /// `finish()`, whatever is left of one): the probability Silero gives it
    /// and the carried streaming state. The cutting itself is this actor's
    /// own rule, not FluidAudio's own hysteresis events.
    struct Detector: Sendable {
        let classify: @Sendable ([Float], VadStreamState) async throws -> (probability: Float, state: VadStreamState)

        static func silero(modelPath: String = MeetingTranscriber.vadModelPath) throws -> Detector {
            let vad = try MeetingTranscriber.sileroVAD(modelPath: modelPath)
            return Detector { block, state in
                let result = try await vad.processStreamingChunk(block, state: state)
                return (result.probability, result.state)
            }
        }
    }

    /// The seam a fake AEC crosses in tests: `EchoCanceller` itself already
    /// matches this shape.
    protocol EchoCancelling: AnyObject {
        func process(microphone: [Float], reference: [Float]) throws -> [Float]
        func finish() throws -> [Float]
    }

    enum Failure: Error {
        case conversionFailed
    }

    static let capacity = 8
    static let maximumChunkSeconds = 15.0
    static let silentBlocksToCut = 2

    /// Entry at Silero's own default (`VadConfig.default.defaultThreshold`);
    /// exit at FluidAudio's own derived negative threshold for that entry
    /// (`VadSegmentationConfig.default`) — the same hysteresis the measured
    /// run (3.16 % errors) was tuned under.
    private static let entryThreshold = VadConfig.default.defaultThreshold
    private static let exitThreshold = VadSegmentationConfig.default
        .effectiveNegativeThreshold(baseThreshold: entryThreshold)
    /// 0.1 s of padding on each side of a chunk — the pause itself is
    /// scissors, not sound.
    private static let padSamples = Int(0.1 * Double(MeetingTranscriber.sampleRate))
    private static let hardCutSamples = Int(maximumChunkSeconds * Double(MeetingTranscriber.sampleRate))

    private struct Lane {
        var pending: [Float] = []
        var vadState = VadStreamState.initial()
        /// 16 kHz samples consumed by a full classification since the last
        /// reset; the position a new chunk opens at is read from here.
        var consumed16k = 0
        var preRoll: [Float] = []
        var isOpen = false
        var openStart16k = 0
        var openSamples: [Float] = []
        var speechEndOffset = 0
        var silentRun = 0
        /// This lane's open chunk, unique for the whole meeting.
        var number = 0
        /// `speechEndOffset` at the last interim request for this open
        /// chunk; 0 again whenever a new chunk opens.
        var interimMark = 0
    }

    private let source: @Sendable () async -> Audio?
    private let detector: Detector
    private let makeEchoCanceller: @Sendable () throws -> any EchoCancelling
    private let pollInterval: Duration

    private var task: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var finished = false
    private let recognition: Recognition?

    private var rate: Double?
    private var channels: Int?
    private var origin: Int64 = 0
    private var expectedFrame: Int64?

    private var converterSystem: AVAudioConverter?
    private var converterMicrophone: AVAudioConverter?

    private var laneSystem = Lane()
    private var laneMicrophone = Lane()
    private var vadFailedSystem = false
    private var vadFailedMicrophone = false

    private var micForEcho: [Float] = []
    private var systemForEcho: [Float] = []
    private var echoCanceller: (any EchoCancelling)?
    private var echoFailed = false

    private var chunks: [Chunk] = []
    private(set) var skippedChunks = 0
    /// Never reset by `resetState`, so a chunk's number stays unique for the
    /// whole meeting even across a break in the audio.
    private var nextChunkNumber = 0
    private var lastInterimTrack: Track?
    /// The largest an open chunk's `openSamples` has grown to, across both
    /// lanes — proof the 15 s hard cut (`cut`, before a block is appended)
    /// keeps an open chunk bounded even while the recognition queue is full
    /// and no interim request ever sees it.
    private(set) var largestOpenChunkSamples = 0

    init(
        source: @escaping @Sendable () async -> Audio?,
        detector: Detector,
        makeEchoCanceller: @escaping @Sendable () throws -> any EchoCancelling = {
            try EchoCanceller(sampleRate: MeetingTranscriber.sampleRate)
        },
        pollInterval: Duration = .milliseconds(250),
        recognition: Recognition? = nil
    ) {
        self.source = source
        self.detector = detector
        self.makeEchoCanceller = makeEchoCanceller
        self.pollInterval = pollInterval
        self.recognition = recognition
    }

    /// Starts the emptying task and, if configured, the recognition pipeline
    /// — two independent tasks under one guard, so a second `start()` never
    /// starts a second pipeline of either kind. The emptying task never
    /// awaits recognition, because there is none here — only the bounded
    /// queue below; recognition pulls from that same queue on its own.
    func start() {
        guard task == nil, !finished else { return }
        task = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                await self?.drain()
                if Task.isCancelled { break }
                try? await Task.sleep(for: pollInterval)
            }
        }
        if let recognition {
            recognitionTask = Task { [weak self] in
                await Self.runRecognition(on: self, config: recognition)
            }
        }
    }

    /// Pulls every snapshot the source has right now. Internal so tests can
    /// call it directly, without the task's clock.
    func drain() async {
        guard !finished else { return }
        while !finished, let audio = await source() {
            await ingest(audio)
        }
    }

    /// Stops accepting audio, flushes every open chunk's tail and ends the
    /// task. Idempotent; a cancellation inside it never reaches the caller.
    /// Cancels the recognition pipeline too, but never waits for it: a
    /// request or a model load already in flight is abandoned, not awaited,
    /// so a hung engine can never hold up the end of a recording. Its result,
    /// if it ever arrives, is dropped — `finished` is already `true`.
    func finish() async {
        guard !finished else { return }
        finished = true
        recognitionTask?.cancel()
        task?.cancel()
        await task?.value

        let systemTail = flushConverterTail(.system)
        let microphoneTail = flushConverterTail(.microphone)

        await ingestSamples(systemTail, track: .system)

        systemForEcho.append(contentsOf: systemTail)
        micForEcho.append(contentsOf: microphoneTail)
        await finishEcho()

        if let chunk = await closeOpenFinal(track: .system) { enqueue(chunk) }
        if let chunk = await closeOpenFinal(track: .microphone) { enqueue(chunk) }
    }

    /// The whole queue, emptied; the caller owns the chunks from here on.
    func takeChunks() -> [Chunk] {
        defer { chunks = [] }
        return chunks
    }

    /// One chunk off the front of the same queue `takeChunks()` drains —
    /// the recognition pipeline's own way of taking chunks one at a time,
    /// in order, never more than one in flight.
    fileprivate func takeNextChunk() -> Chunk? {
        guard !chunks.isEmpty else { return nil }
        return chunks.removeFirst()
    }

    fileprivate var pendingChunkCount: Int { chunks.count }
    fileprivate var isFinished: Bool { finished }

    /// A snapshot of a lane's still-open chunk, for the recognition
    /// pipeline's interim request — only while there is nothing final
    /// waiting (an interim request is never this pipeline's own reason the
    /// queue stays full), the open chunk has grown by at least
    /// `minimumSpeech` of speech since its last interim (or since it opened,
    /// for the first one), and the open chunk has at least `minimumSpeech`
    /// of speech at all. When both lanes qualify, the one that did not get
    /// the previous interim goes first, so a slow engine (one request at a
    /// time) does not starve one track; with no previous interim at all,
    /// the system track goes first (K2).
    fileprivate func takeInterim(minimumSpeech: Int) -> Chunk? {
        guard !finished, chunks.isEmpty else { return nil }

        func qualifies(_ lane: Lane) -> Bool {
            lane.isOpen
                && lane.speechEndOffset >= minimumSpeech
                && lane.speechEndOffset - lane.interimMark >= minimumSpeech
        }

        let systemQualifies = qualifies(laneSystem)
        let microphoneQualifies = qualifies(laneMicrophone)
        guard systemQualifies || microphoneQualifies else { return nil }

        let track: Track
        if systemQualifies && microphoneQualifies {
            track = (lastInterimTrack == .system) ? .microphone : .system
        } else {
            track = systemQualifies ? .system : .microphone
        }

        var lane = (track == .system) ? laneSystem : laneMicrophone
        let trimmed = Array(lane.openSamples.prefix(lane.speechEndOffset))
        let samples = lane.preRoll + trimmed
        let start16k = lane.openStart16k - lane.preRoll.count
        let end16k = lane.openStart16k + lane.speechEndOffset
        let chunk = Chunk(
            track: track,
            start: frameSeconds(of: start16k),
            end: frameSeconds(of: end16k),
            samples: samples,
            number: lane.number
        )

        lane.interimMark = lane.speechEndOffset
        switch track {
        case .system: laneSystem = lane
        case .microphone: laneMicrophone = lane
        }
        lastInterimTrack = track
        return chunk
    }

    /// Whether `number` is still this lane's open chunk — a result naming
    /// any other number is stale: its chunk either closed (and a final
    /// result will or already did replace it) or the lane broke and
    /// reopened.
    fileprivate func isOpenChunk(track: Track, number: Int) -> Bool {
        let lane = (track == .system) ? laneSystem : laneMicrophone
        return lane.isOpen && lane.number == number
    }

    // MARK: - Ingestion

    private func ingest(_ audio: Audio) async {
        guard !finished else { return }

        let malformed = !(1...2).contains(audio.microphoneChannels)
            || audio.microphone.count != audio.system.count * audio.microphoneChannels
        let isBreak = malformed || detectBreak(audio)
        if isBreak || rate == nil {
            resetState(newOrigin: audio.firstFrame)
        }
        if malformed {
            AppLog.error("live-transcript", "malformed audio snapshot dropped")
            rate = nil
            channels = nil
            expectedFrame = nil
            return
        }
        rate = audio.sampleRate
        channels = audio.microphoneChannels
        expectedFrame = audio.firstFrame &+ Int64(audio.system.count)

        guard !audio.system.isEmpty else { return }

        do {
            let sysConverter = try converter(for: .system, audio: audio)
            let micConverter = try converter(for: .microphone, audio: audio)
            guard let sysBuffer = systemBuffer(audio, format: sysConverter.inputFormat),
                  let micBuffer = microphoneBuffer(audio, format: micConverter.inputFormat) else {
                throw Failure.conversionFailed
            }
            let system16 = try convert(sysConverter, input: sysBuffer, endOfStream: false)
            let microphone16 = try convert(micConverter, input: micBuffer, endOfStream: false)

            await ingestSamples(system16, track: .system)
            await ingestCancellingEcho(microphone16: microphone16, system16: system16)
        } catch {
            AppLog.error("live-transcript", "conversion failed: \(error)")
        }
    }

    private func detectBreak(_ audio: Audio) -> Bool {
        if audio.dropped > 0 { return true }
        if let expectedFrame, audio.firstFrame != expectedFrame { return true }
        if let rate, rate != audio.sampleRate { return true }
        if let channels, channels != audio.microphoneChannels { return true }
        return false
    }

    /// `echoFailed`, `vadFailedSystem` and `vadFailedMicrophone` outlive a
    /// break on purpose — each is a whole-meeting decision, not a per-segment
    /// one. A break drops a lane's open chunk with no final result for it:
    /// a track's interim line can then be left showing stale text until that
    /// track's next interim or final result replaces it. One line, briefly
    /// wrong rather than briefly missing — accepted, not fixed here.
    private func resetState(newOrigin: Int64) {
        origin = newOrigin
        laneSystem = Lane()
        laneMicrophone = Lane()
        converterSystem = nil
        converterMicrophone = nil
        micForEcho = []
        systemForEcho = []
        if !echoFailed { echoCanceller = nil }
    }

    // MARK: - Echo cancellation

    private func ingestCancellingEcho(microphone16: [Float], system16: [Float]) async {
        if echoFailed {
            await ingestSamples(microphone16, track: .microphone)
            return
        }
        micForEcho.append(contentsOf: microphone16)
        systemForEcho.append(contentsOf: system16)
        let k = min(micForEcho.count, systemForEcho.count)
        guard k > 0 else { return }
        let micSlice = Array(micForEcho.prefix(k))
        let sysSlice = Array(systemForEcho.prefix(k))
        micForEcho.removeFirst(k)
        systemForEcho.removeFirst(k)
        do {
            if echoCanceller == nil { echoCanceller = try makeEchoCanceller() }
            let cleaned = try echoCanceller!.process(microphone: micSlice, reference: sysSlice)
            await ingestSamples(cleaned, track: .microphone)
        } catch {
            AppLog.error("live-transcript", "echo cancellation off for the rest of the meeting: \(error)")
            echoFailed = true
            echoCanceller = nil
            await ingestSamples(micSlice, track: .microphone)
        }
    }

    /// Flushes whatever either buffer still owes the other at `finish()`:
    /// one last `process()` of the matched length, then the canceller's own
    /// `finish()` for its sub-frame remainder, then any leftover (mic and
    /// system tails can differ by a sample or two) straight through.
    private func finishEcho() async {
        if echoFailed {
            await ingestSamples(micForEcho, track: .microphone)
            micForEcho = []
            systemForEcho = []
            return
        }
        let k = min(micForEcho.count, systemForEcho.count)
        if k > 0 {
            let micSlice = Array(micForEcho.prefix(k))
            let sysSlice = Array(systemForEcho.prefix(k))
            micForEcho.removeFirst(k)
            systemForEcho.removeFirst(k)
            do {
                if echoCanceller == nil { echoCanceller = try makeEchoCanceller() }
                let cleaned = try echoCanceller!.process(microphone: micSlice, reference: sysSlice)
                await ingestSamples(cleaned, track: .microphone)
            } catch {
                AppLog.error("live-transcript", "echo cancellation off for the rest of the meeting: \(error)")
                echoFailed = true
                echoCanceller = nil
                await ingestSamples(micSlice, track: .microphone)
            }
        }
        if !echoFailed, let canceller = echoCanceller {
            if let tail = try? canceller.finish(), !tail.isEmpty {
                await ingestSamples(tail, track: .microphone)
            }
        }
        await ingestSamples(micForEcho, track: .microphone)
        micForEcho = []
        systemForEcho = []
    }

    // MARK: - Conversion

    private func converter(for track: Track, audio: Audio) throws -> AVAudioConverter {
        switch track {
        case .system:
            if let existing = converterSystem { return existing }
            guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
                  let outFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(MeetingTranscriber.sampleRate),
                    channels: 1,
                    interleaved: false
                  ),
                  let created = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw Failure.conversionFailed
            }
            converterSystem = created
            return created
        case .microphone:
            if let existing = converterMicrophone { return existing }
            guard let inFormat = AVAudioFormat(
                    standardFormatWithSampleRate: audio.sampleRate,
                    channels: AVAudioChannelCount(audio.microphoneChannels)
                  ),
                  let outFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(MeetingTranscriber.sampleRate),
                    channels: 1,
                    interleaved: false
                  ),
                  let created = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw Failure.conversionFailed
            }
            converterMicrophone = created
            return created
        }
    }

    private func systemBuffer(_ audio: Audio, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.system.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(audio.system.count)
        audio.system.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: audio.system.count)
        }
        return buffer
    }

    private func microphoneBuffer(_ audio: Audio, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = audio.microphoneChannels
        guard channels > 0, audio.microphone.count % channels == 0 else { return nil }
        let frames = audio.microphone.count / channels
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        audio.microphone.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for c in 0..<channels {
                let channel = destination[c]
                for i in 0..<frames { channel[i] = base[i * channels + c] }
            }
        }
        return buffer
    }

    /// One call of a streaming `AVAudioConverter`: `input` nil (with
    /// `endOfStream`) flushes whatever the filter still holds, without a
    /// dummy zero-frame buffer standing in for real audio.
    private func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> [Float] {
        let delivered = OSAllocatedUnfairLock(initialState: input == nil)
        // The input block runs synchronously, on this call stack alone; the
        // lock is only here to satisfy `AVAudioConverterInputBlock`'s own
        // `@Sendable` requirement, not because of real concurrency.
        nonisolated(unsafe) let capturedInput = input
        let outputFormat = converter.outputFormat
        let estimated = input.map {
            AVAudioFrameCount((Double($0.frameLength) * outputFormat.sampleRate / converter.inputFormat.sampleRate).rounded(.up))
        } ?? 0
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(1024, estimated + 1024)) else {
            throw Failure.conversionFailed
        }
        var result: [Float] = []
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                let alreadyDelivered = delivered.withLock { value -> Bool in
                    let was = value
                    value = true
                    return was
                }
                if alreadyDelivered {
                    outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return capturedInput
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }
            if status != .haveData { break }
        }
        return result
    }

    private func flushConverterTail(_ track: Track) -> [Float] {
        let converter: AVAudioConverter?
        switch track {
        case .system: converter = converterSystem
        case .microphone: converter = converterMicrophone
        }
        guard let converter else { return [] }
        return (try? convert(converter, input: nil, endOfStream: true)) ?? []
    }

    // MARK: - VAD and cutting

    private func ingestSamples(_ samples: [Float], track: Track) async {
        guard !samples.isEmpty else { return }
        switch track {
        case .system: guard !vadFailedSystem else { return }
        case .microphone: guard !vadFailedMicrophone else { return }
        }
        var lane = (track == .system) ? laneSystem : laneMicrophone
        lane.pending.append(contentsOf: samples)
        while lane.pending.count >= VadManager.chunkSize {
            let block = Array(lane.pending.prefix(VadManager.chunkSize))
            lane.pending.removeFirst(VadManager.chunkSize)
            if let chunk = await classify(block, lane: &lane, track: track) {
                enqueue(chunk)
            }
            if (track == .system ? vadFailedSystem : vadFailedMicrophone) { break }
        }
        switch track {
        case .system: laneSystem = lane
        case .microphone: laneMicrophone = lane
        }
    }

    /// At `finish()`, whatever is left of a lane's `pending` (short of a full
    /// block) goes to the detector exactly as it is — Silero's own
    /// `processChunk` pads a short block by repeating its last sample, never
    /// with zeros, and only the real samples ever reach a chunk.
    private func closeOpenFinal(track: Track) async -> Chunk? {
        var lane = (track == .system) ? laneSystem : laneMicrophone
        var finishedChunk: Chunk?
        let vadFailed = (track == .system) ? vadFailedSystem : vadFailedMicrophone
        if !lane.pending.isEmpty, !vadFailed {
            let block = lane.pending
            lane.pending = []
            finishedChunk = await classify(block, lane: &lane, track: track)
        } else {
            lane.pending = []
        }
        if finishedChunk == nil, lane.isOpen {
            finishedChunk = closeChunk(lane: &lane, track: track)
        }
        switch track {
        case .system: laneSystem = lane
        case .microphone: laneMicrophone = lane
        }
        return finishedChunk
    }

    private func classify(_ block: [Float], lane: inout Lane, track: Track) async -> Chunk? {
        do {
            let result = try await detector.classify(block, lane.vadState)
            lane.vadState = result.state
            return cut(probability: result.probability, block: block, lane: &lane, track: track)
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.error("live-transcript", "speech detection failed on \(track); no more chunks from it: \(error)")
            switch track {
            case .system: vadFailedSystem = true
            case .microphone: vadFailedMicrophone = true
            }
            lane.isOpen = false
            lane.openSamples = []
            lane.preRoll = []
            return nil
        }
    }

    /// Silero's own hysteresis: while a chunk is **open**, a block at or
    /// above the lower (exit) threshold is still speech — it moves the
    /// accepted end of speech to this block and clears the silent run; only
    /// two blocks below it in a row close the chunk. While **closed**, only
    /// the higher (entry) threshold opens a new one — a block in the band
    /// between the two thresholds is pre-roll, not speech, until something
    /// stronger opens a chunk.
    /// `lane.consumed16k` is the 16 kHz index, since the last reset, of the
    /// sample about to be appended; it advances on every block, open or not,
    /// so an opening chunk always knows where it starts.
    private func cut(probability: Float, block: [Float], lane: inout Lane, track: Track) -> Chunk? {
        let blockStart16k = lane.consumed16k
        lane.consumed16k += block.count

        if lane.isOpen, lane.openSamples.count + block.count > Self.hardCutSamples {
            let finished = closeChunk(lane: &lane, track: track)
            // The cut itself is scissors, not a pause: a block that continues
            // speech (≥ the lower threshold) opens the next chunk right here,
            // with no left padding; a quiet block at the boundary is never
            // declared speech, and falls back to ordinary pre-roll.
            if probability >= Self.exitThreshold {
                lane.isOpen = true
                lane.openStart16k = blockStart16k
                lane.openSamples = block
                lane.speechEndOffset = block.count
                lane.silentRun = 0
                lane.interimMark = 0
                lane.number = nextChunkNumber
                nextChunkNumber += 1
                largestOpenChunkSamples = max(largestOpenChunkSamples, lane.openSamples.count)
            } else {
                appendPreRoll(block, lane: &lane)
            }
            return finished
        }

        if probability >= Self.exitThreshold {
            if !lane.isOpen {
                guard probability >= Self.entryThreshold else {
                    appendPreRoll(block, lane: &lane)
                    return nil
                }
                lane.isOpen = true
                lane.openStart16k = blockStart16k
                lane.openSamples = []
                lane.interimMark = 0
                lane.number = nextChunkNumber
                nextChunkNumber += 1
            }
            lane.openSamples.append(contentsOf: block)
            lane.speechEndOffset = lane.openSamples.count
            lane.silentRun = 0
            largestOpenChunkSamples = max(largestOpenChunkSamples, lane.openSamples.count)
            return nil
        } else {
            if lane.isOpen {
                lane.openSamples.append(contentsOf: block)
                largestOpenChunkSamples = max(largestOpenChunkSamples, lane.openSamples.count)
                lane.silentRun += 1
                if lane.silentRun >= Self.silentBlocksToCut {
                    return closeChunk(lane: &lane, track: track)
                }
                return nil
            } else {
                appendPreRoll(block, lane: &lane)
                return nil
            }
        }
    }

    private func appendPreRoll(_ block: [Float], lane: inout Lane) {
        lane.preRoll.append(contentsOf: block)
        if lane.preRoll.count > Self.padSamples {
            lane.preRoll.removeFirst(lane.preRoll.count - Self.padSamples)
        }
    }

    private func closeChunk(lane: inout Lane, track: Track) -> Chunk? {
        defer {
            lane.isOpen = false
            lane.openSamples = []
            lane.speechEndOffset = 0
            lane.silentRun = 0
            lane.preRoll = []
        }
        let trimmed = Array(lane.openSamples.prefix(lane.speechEndOffset))
        guard trimmed.count >= MeetingTranscriber.minimumChunkSamples else { return nil }
        let postRoll = Array(lane.openSamples[lane.speechEndOffset...].prefix(Self.padSamples))
        var samples = lane.preRoll
        samples.append(contentsOf: trimmed)
        samples.append(contentsOf: postRoll)
        let start16k = lane.openStart16k - lane.preRoll.count
        let end16k = lane.openStart16k + trimmed.count + postRoll.count
        return Chunk(
            track: track,
            start: frameSeconds(of: start16k),
            end: frameSeconds(of: end16k),
            samples: samples,
            number: lane.number
        )
    }

    private func frameSeconds(of index16k: Int) -> Double {
        guard let rate else { return 0 }
        let frame = origin &+ Int64((Double(index16k) * rate / Double(MeetingTranscriber.sampleRate)).rounded())
        return Double(frame) / rate
    }

    private func enqueue(_ chunk: Chunk) {
        chunks.append(chunk)
        if chunks.count > Self.capacity {
            chunks.removeFirst()
            skippedChunks += 1
        }
    }
}

extension EchoCanceller: LiveTranscript.EchoCancelling {}

// MARK: - Recognition

extension LiveTranscript {
    /// Everything the recognition pipeline needs, captured once when
    /// `LiveTranscript` is created: a settings change mid-call never reloads
    /// or swaps the model underneath a live transcript, since `engine` is a
    /// value, not a closure read again later.
    struct Recognition: Sendable {
        let cache: WhisperKitCache
        let engine: MeetingTranscriber.Engine
        /// The same check a meeting job makes before it starts: model,
        /// tokenizer and VAD. True means recognition never runs at all.
        let modelMissing: @Sendable () async -> Bool
        /// The meetings' personal dictionary, already a replacer (word forms
        /// prepared) — nil when there is nothing to replace.
        let dictionaryReplacer: DictionaryReplacer?
        /// The call feed's own events so far, in memory — never the feed
        /// file, and never a second poll of the call page.
        let callFeedEvents: @Sendable () async -> [CallFeed.Event]
        let model: LiveTranscriptModel
        var temporaryRoot: URL = FileManager.default.temporaryDirectory
        /// How far back lines are recomputed on every new one; older lines
        /// keep whatever they were last shown as.
        var windowSeconds: Double = 120
        /// How much speech a track's open chunk must gain before it is asked
        /// about again as an interim request — never more than once a
        /// second of real speech, since the owner wants "instant" without a
        /// flood of requests. `nil` turns interim requests off entirely.
        var interimSeconds: Double? = 1.0
    }

    /// One line as the recognition pipeline keeps it internally, before it is
    /// handed to the model: the engine's raw text, whether it is hidden as
    /// echo (never reversed, once set) and whether it has left the recompute
    /// window (frozen — never recomputed again, so a name or a dictionary
    /// edit from later in the call never reaches back into it).
    private struct RawLine {
        let id: UUID
        let track: Track
        let start: Double
        let end: Double
        let rawText: String
        var displayText: String
        var name: String?
        var hiddenAsEcho = false
        var frozen = false

        init(id: UUID = UUID(), track: Track, start: Double, end: Double, rawText: String) {
            self.id = id
            self.track = track
            self.start = start
            self.end = end
            self.rawText = rawText
            self.displayText = rawText
        }
    }

    /// Wraps one chunk's own samples as an `AudioSampleSource`, so the one
    /// chunk-writing function (`MeetingTranscriber.writeChunk`) serves the
    /// batch job and this live pipeline alike.
    private struct ArraySource: AudioSampleSource {
        let samples: [Float]
        var sampleCount: Int { samples.count }
        func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
            guard count > 0 else { return }
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                destination.update(from: base + offset, count: count)
            }
        }
    }

    /// Recomputes `displayText`, `name` and `hiddenAsEcho` for every line
    /// still inside the window ending at the latest line's own `end`; a line
    /// that just fell behind the window gets one last recompute right here
    /// and is then frozen. Echo is checked against every system line ever
    /// kept, not only the ones still in the window: a chunk up to
    /// `maximumChunkSeconds` long can start well before the microphone line
    /// it overlaps leaves the window, and that microphone line, once hidden,
    /// must stay hidden whatever its echo partner does later (K1).
    private static func recompute(
        _ rawLines: inout [RawLine],
        dictionary: DictionaryReplacer?,
        feed: [CallFeed.Event],
        windowSeconds: Double
    ) {
        guard let windowEnd = rawLines.map(\.end).max() else { return }
        let windowStart = windowEnd - windowSeconds

        let allSystem = rawLines.filter { $0.track == .system }.map {
            MeetingTranscriber.Utterance(speaker: "system", text: $0.rawText, start: $0.start, end: $0.end)
        }
        let micIndices = rawLines.indices.filter {
            rawLines[$0].track == .microphone && !rawLines[$0].hiddenAsEcho && !rawLines[$0].frozen
        }
        if !micIndices.isEmpty {
            let micUtterances = micIndices.map {
                MeetingTranscriber.Utterance(
                    speaker: "microphone", text: rawLines[$0].rawText, start: rawLines[$0].start, end: rawLines[$0].end
                )
            }
            let kept = MeetingTranscriber.removingEcho(microphone: micUtterances, system: allSystem).kept
            var keptIndex = 0
            for (offset, index) in micIndices.enumerated() {
                if keptIndex < kept.count, micUtterances[offset] == kept[keptIndex] {
                    keptIndex += 1
                } else {
                    rawLines[index].hiddenAsEcho = true
                }
            }
        }

        let activeIndices = rawLines.indices.filter { !rawLines[$0].hiddenAsEcho && !rawLines[$0].frozen }
        for index in activeIndices {
            rawLines[index].displayText = dictionary?.replacing(in: rawLines[index].rawText).text
                ?? rawLines[index].rawText
        }
        if !feed.isEmpty, !activeIndices.isEmpty {
            let asLines = activeIndices.map {
                MeetingAttempt.Line(
                    start: rawLines[$0].start, end: rawLines[$0].end,
                    source: rawLines[$0].track == .microphone ? .microphone : .system
                )
            }
            let names = CallFeed.pickedNames(for: asLines, feed: feed)
            for (offset, index) in activeIndices.enumerated() { rawLines[index].name = names[offset] }
        }

        for index in rawLines.indices where rawLines[index].end < windowStart {
            rawLines[index].frozen = true
        }

        // K5: a frozen line is never recomputed again, and once far enough
        // behind the window that no future chunk could still overlap it
        // (bounded by the longest a chunk can be, `maximumChunkSeconds`) it
        // is not kept for echo-matching either. A hidden (echoed) line past
        // that point is dropped outright: nothing reads it again. A visible
        // one is kept regardless, UNLESS the model already has more than its
        // own `maximumLines` to show — then only the oldest excess is
        // dropped, so `rawLines` stays bounded by the window and the echo
        // margin while a quiet call still keeps up to `maximumLines` of
        // visible history, rather than losing it to the window's length
        // alone (K1).
        let retainFrom = windowStart - maximumChunkSeconds
        let visibleCount = rawLines.lazy.filter { !$0.hiddenAsEcho }.count
        var overflow = max(0, visibleCount - LiveTranscriptModel.maximumLines)
        rawLines.removeAll { line in
            guard line.frozen, line.end < retainFrom else { return false }
            if line.hiddenAsEcho { return true }
            guard overflow > 0 else { return false }
            overflow -= 1
            return true
        }
    }

    /// The echo, dictionary and name steps `recompute` runs for a final
    /// line, run once for a track's single interim line instead: never
    /// stored, never marked permanently (K7) — every publication recomputes
    /// it fresh from the finals gathered so far and, for a microphone line,
    /// the system track's own interim (still growing, so echo of a phrase
    /// not yet final must still be caught). `nil` means hidden as echo, not
    /// shown at all.
    private static func interimLine(
        _ line: RawLine,
        finals: [RawLine],
        systemInterim: RawLine?,
        dictionary: DictionaryReplacer?,
        feed: [CallFeed.Event]
    ) -> RawLine? {
        var line = line
        if line.track == .microphone {
            let micUtterance = MeetingTranscriber.Utterance(
                speaker: "microphone", text: line.rawText, start: line.start, end: line.end
            )
            var systemUtterances = finals.filter { $0.track == .system }.map {
                MeetingTranscriber.Utterance(speaker: "system", text: $0.rawText, start: $0.start, end: $0.end)
            }
            if let systemInterim {
                systemUtterances.append(
                    MeetingTranscriber.Utterance(
                        speaker: "system", text: systemInterim.rawText, start: systemInterim.start, end: systemInterim.end
                    )
                )
            }
            let kept = MeetingTranscriber.removingEcho(microphone: [micUtterance], system: systemUtterances).kept
            guard !kept.isEmpty else { return nil }
        }
        line.displayText = dictionary?.replacing(in: line.rawText).text ?? line.rawText
        if !feed.isEmpty {
            let asLine = MeetingAttempt.Line(
                start: line.start, end: line.end,
                source: line.track == .microphone ? .microphone : .system
            )
            line.name = CallFeed.pickedNames(for: [asLine], feed: feed)[0]
        }
        return line
    }

    /// Both tracks' interim lines, resolved and ready to publish — system
    /// first, then microphone, always after every final line (K8).
    private static func pendingInterimLines(
        _ interims: [Track: (number: Int, line: RawLine)],
        finals: [RawLine],
        dictionary: DictionaryReplacer?,
        feed: [CallFeed.Event]
    ) -> [LiveLine] {
        let systemInterim = interims[.system]?.line
        let microphoneInterim = interims[.microphone]?.line
        var result: [LiveLine] = []
        if let systemInterim,
           let resolved = interimLine(systemInterim, finals: finals, systemInterim: nil, dictionary: dictionary, feed: feed) {
            result.append(LiveLine(
                id: resolved.id, track: resolved.track, start: resolved.start, end: resolved.end,
                rawText: resolved.rawText, displayText: resolved.displayText, name: resolved.name, isFinal: false
            ))
        }
        if let microphoneInterim,
           let resolved = interimLine(
               microphoneInterim, finals: finals, systemInterim: systemInterim, dictionary: dictionary, feed: feed
           ) {
            result.append(LiveLine(
                id: resolved.id, track: resolved.track, start: resolved.start, end: resolved.end,
                rawText: resolved.rawText, displayText: resolved.displayText, name: resolved.name, isFinal: false
            ))
        }
        return result
    }

    private static func visibleLines(_ rawLines: [RawLine]) -> [LiveLine] {
        rawLines.filter { !$0.hiddenAsEcho }.map {
            LiveLine(
                id: $0.id, track: $0.track, start: $0.start, end: $0.end,
                rawText: $0.rawText, displayText: $0.displayText, name: $0.name, isFinal: true
            )
        }
    }

    /// One chunk through the engine, its model-loading phase reported as it
    /// happens — the same pattern `MeetingTranscriber`'s own `decode` uses,
    /// so "preparing the model" is shown only while that is really
    /// happening and never after.
    private static func decodeChunk(
        _ path: String,
        descriptor: EngineDescriptor,
        request: EngineDecodeRequest,
        cache: WhisperKitCache,
        reporting states: AsyncStream<WhisperModelState>.Continuation
    ) async throws -> EngineTranscriptDTO {
        defer { states.finish() }
        return try await cache.transcribe(audioPath: path, descriptor: descriptor, request: request) {
            _ = states.yield($0)
        }
    }

    private static func status(pending: Int, skipped: Int, modelLoaded: Bool) -> LiveTranscriptModel.State {
        guard modelLoaded else { return .preparingModel }
        if skipped > 0 { return .skipped(skipped) }
        if pending >= 3 { return .lagging }
        return .running
    }

    /// The recognition pipeline itself: a final chunk off the queue
    /// `takeNextChunk()` drains always goes first; only when that queue is
    /// empty does an interim request for a still-open chunk go instead
    /// (`takeInterim`), so an interim request is never this pipeline's own
    /// reason the final queue stays full. Never more than one request of
    /// either kind in flight, and never touching the actor while the
    /// dictionary or the names are worked out (K4), so audio ingestion
    /// (`drain()`) never waits on it. `live` is weak: a `LiveTranscript` that
    /// is already gone has nothing left to recognize for.
    fileprivate static func runRecognition(on live: LiveTranscript?, config: Recognition) async {
        guard let live else { return }

        // Every publication into the model goes through these two, so
        // `finish()` (K3) stops all of them at once — the state the cache's
        // own progress loop sets while it is loading included — rather than
        // needing a separate `isFinished` guard before each call.
        func publishState(_ state: LiveTranscriptModel.State) async {
            guard !(await live.isFinished) else { return }
            await config.model.setState(state)
        }
        func publishLines(_ lines: [LiveLine]) async {
            guard !(await live.isFinished) else { return }
            await config.model.setLines(lines)
        }

        if await config.modelMissing() {
            await publishState(.noModel)
            return
        }
        await publishState(.waitingForSpeech)

        var rawLines: [RawLine] = []
        /// At most one entry per track: the chunk number it is still an
        /// interim answer for, and the line itself. Never published from
        /// anywhere but the two sites below, both of which keep it in step
        /// with the chunk it answers.
        var interims: [Track: (number: Int, line: RawLine)] = [:]
        var fixedLanguage: String?
        var modelEverLoaded = false
        var consecutiveFailures = 0
        /// The error from the most recent failed chunk request — never its
        /// recognized text, only shown once three in a row have failed.
        var lastError: (any Error)?
        let automatic = config.engine.request == .whisper(WhisperDecodeRequest(language: nil))
        let minimumInterimSpeech = config.interimSeconds.map { Int($0 * Double(MeetingTranscriber.sampleRate)) }

        // One chunk through the engine, whichever kind it is: writes it to a
        // temporary file (removed whatever happens next), decodes it,
        // reporting model-loading states the same way for both kinds.
        func recognize(_ chunk: Chunk) async throws -> EngineTranscriptDTO {
            let work = config.temporaryRoot.appendingPathComponent(
                "Murmurly-live-\(UUID().uuidString)", isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let chunkFile = work.appendingPathComponent("chunk.caf")
            try MeetingTranscriber.writeChunk(
                from: ArraySource(samples: chunk.samples), range: 0..<chunk.samples.count, to: chunkFile
            )

            let effectiveRequest: EngineDecodeRequest = automatic
                ? .whisper(WhisperDecodeRequest(language: fixedLanguage))
                : config.engine.request
            let (states, continuation) = AsyncStream.makeStream(of: WhisperModelState.self)
            async let decodedTask = Self.decodeChunk(
                chunkFile.path, descriptor: config.engine.descriptor, request: effectiveRequest,
                cache: config.cache, reporting: continuation
            )
            for await modelState in states {
                switch modelState {
                case .loading, .waiting:
                    await publishState(.preparingModel)
                case .ready:
                    modelEverLoaded = true
                case .cold:
                    break
                }
            }
            return try await decodedTask
        }

        while !Task.isCancelled {
            if await live.isFinished { return }

            if let chunk = await live.takeNextChunk() {
                if Task.isCancelled { return }

                let pendingBefore = await live.pendingChunkCount
                let skippedBefore = await live.skippedChunks
                await publishState(Self.status(pending: pendingBefore, skipped: skippedBefore, modelLoaded: modelEverLoaded))

                var isCancellation = false
                var didFail = false
                var text: String?

                do {
                    let decoded = try await recognize(chunk)
                    consecutiveFailures = 0
                    if await live.isFinished { return }

                    let decodedText = decoded.segments.map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Parakeet answers a breath or a click with a lone ".":
                    // the same guard as the batch job's, before the language
                    // is ever fixed from this chunk (K2).
                    if !MeetingTranscriber.normalizedWords(decodedText).isEmpty {
                        text = decodedText
                        let seconds = Double(chunk.samples.count) / Double(MeetingTranscriber.sampleRate)
                        if automatic, fixedLanguage == nil, seconds > MeetingTranscriber.languageFixSeconds {
                            fixedLanguage = decoded.language
                        }
                    }
                } catch is CancellationError {
                    isCancellation = true
                } catch {
                    if Task.isCancelled {
                        isCancellation = true
                    } else {
                        didFail = true
                        lastError = error
                        AppLog.error("live-transcript", "chunk request failed on \(chunk.track)")
                    }
                }

                if isCancellation { return }

                // The final chunk settles its track's interim line whatever
                // happened to the request — success with or without text, or
                // a failure — so a stale interim never keeps showing once
                // its own chunk is done (K6).
                var changed = false
                if let text {
                    let reusedID = (interims[chunk.track]?.number == chunk.number) ? interims[chunk.track]?.line.id : nil
                    rawLines.append(RawLine(
                        id: reusedID ?? UUID(), track: chunk.track, start: chunk.start, end: chunk.end, rawText: text
                    ))
                    changed = true
                }
                if let existing = interims[chunk.track], existing.number <= chunk.number {
                    interims[chunk.track] = nil
                    changed = true
                }
                if changed {
                    let feed = await config.callFeedEvents()
                    Self.recompute(&rawLines, dictionary: config.dictionaryReplacer, feed: feed, windowSeconds: config.windowSeconds)
                    await publishLines(
                        Self.visibleLines(rawLines)
                            + Self.pendingInterimLines(interims, finals: rawLines, dictionary: config.dictionaryReplacer, feed: feed)
                    )
                }

                if !didFail {
                    let pendingAfter = await live.pendingChunkCount
                    let skippedAfter = await live.skippedChunks
                    await publishState(Self.status(pending: pendingAfter, skipped: skippedAfter, modelLoaded: modelEverLoaded))
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        await publishState(.stopped(lastError?.localizedDescription ?? ""))
                        return
                    }
                }
                continue
            }

            if let minimumInterimSpeech, let chunk = await live.takeInterim(minimumSpeech: minimumInterimSpeech) {
                if Task.isCancelled { return }

                let pendingBefore = await live.pendingChunkCount
                let skippedBefore = await live.skippedChunks
                await publishState(Self.status(pending: pendingBefore, skipped: skippedBefore, modelLoaded: modelEverLoaded))

                do {
                    let decoded = try await recognize(chunk)
                    if await live.isFinished { return }
                    // A result for a chunk that is no longer this track's
                    // open one (closed meanwhile, or the lane reopened) is
                    // stale — dropped without a trace, never an error: a
                    // final result for the same or a later chunk is already
                    // on its way or already published.
                    guard await live.isOpenChunk(track: chunk.track, number: chunk.number) else { continue }

                    let text = decoded.segments.map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !MeetingTranscriber.normalizedWords(text).isEmpty else { continue }

                    let reusedID = (interims[chunk.track]?.number == chunk.number) ? interims[chunk.track]?.line.id : nil
                    let line = RawLine(id: reusedID ?? UUID(), track: chunk.track, start: chunk.start, end: chunk.end, rawText: text)
                    interims[chunk.track] = (number: chunk.number, line: line)
                    let feed = await config.callFeedEvents()
                    await publishLines(
                        Self.visibleLines(rawLines)
                            + Self.pendingInterimLines(interims, finals: rawLines, dictionary: config.dictionaryReplacer, feed: feed)
                    )

                    let pendingAfter = await live.pendingChunkCount
                    let skippedAfter = await live.skippedChunks
                    await publishState(Self.status(pending: pendingAfter, skipped: skippedAfter, modelLoaded: modelEverLoaded))
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    // An interim request failing changes nothing about the
                    // final pipeline: no retry count, no stop condition —
                    // only the batch job's three-in-a-row rule decides that
                    // (K5). The next loop simply tries again.
                    AppLog.error("live-transcript", "interim request failed on \(chunk.track)")
                }
                continue
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// One line of the live transcript: a finished chunk, recognized, with the
/// personal dictionary and the call feed's names applied. `id` never changes
/// once a line is created, even as later chunks make the surrounding window
/// recompute `displayText` and `name` — a future panel keys its rows on it.
struct LiveLine: Sendable, Equatable, Identifiable {
    let id: UUID
    var track: LiveTranscript.Track
    var start: Double
    var end: Double
    /// As the engine returned it, before the personal dictionary.
    var rawText: String
    /// After the personal dictionary — what a panel would show.
    var displayText: String
    /// nil shows the track's own label; set from the call feed.
    var name: String?
    /// `false` while its chunk is still open and being recognized as it
    /// grows — at most one such line per track, replaced in place (same
    /// `id`) by each new interim result and, once the chunk closes, by the
    /// final line for it.
    var isFinal: Bool
}

/// The recognition pipeline's own line list and state: one instance per
/// recording, created and owned by `MeetingRecorder`
/// (`liveTranscriptModel`), published on the main actor. `LiveTranscript`
/// writes into it; nothing here drives anything — no recorder, no settings,
/// no panel. The floating panel (`LiveTranscriptPanel`) reads it from the
/// recorder.
@MainActor
final class LiveTranscriptModel: ObservableObject {
    enum State: Equatable, Sendable {
        /// Before the first chunk has been taken off the queue.
        case waitingForSpeech
        /// The engine is loading the model for a chunk already taken.
        case preparingModel
        /// The model is loaded and chunks are recognized as they arrive.
        case running
        /// The model is loaded, but three or more chunks are already
        /// waiting.
        case lagging
        /// The audio side has dropped chunks (`LiveTranscript.skippedChunks`);
        /// this stays in place until the pipeline ends, even once the queue
        /// catches up.
        case skipped(Int)
        /// Three chunks in a row failed to recognize; nothing more will be.
        case stopped(String)
        /// The model is not downloaded; recognition never starts.
        case noModel
    }

    /// The most recent lines, oldest first, echoed-out microphone lines
    /// never included; at most one interim line (`isFinal == false`) per
    /// track, always after every final line.
    @Published private(set) var lines: [LiveLine] = []
    @Published private(set) var state: State = .waitingForSpeech

    /// `nonisolated`: a plain constant, read by `LiveTranscript.recompute`
    /// (not on the main actor) to decide how many frozen lines to keep.
    nonisolated static let maximumLines = 200

    fileprivate func setState(_ newState: State) {
        state = newState
    }

    fileprivate func setLines(_ newLines: [LiveLine]) {
        lines = Array(newLines.suffix(Self.maximumLines))
    }

    /// Set directly by the recorder, before any pipeline exists: the
    /// engine's model is not installed (`.noModel`), or preparing the VAD or
    /// the dictionary off the main actor failed (`.stopped`, with the
    /// reason) — the same two outcomes `runRecognition` itself reports once
    /// a pipeline has started.
    func reportBeforeRecognition(_ newState: State) {
        state = newState
    }
}

#if DEBUG
extension LiveTranscriptModel {
    /// `LiveTranscriptProbe`: publishes made-up lines and a state directly,
    /// bypassing the recognition pipeline.
    func publishForTesting(lines: [LiveLine], state: State) {
        setLines(lines)
        setState(state)
    }
}
#endif
