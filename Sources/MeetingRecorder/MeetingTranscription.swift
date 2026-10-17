import Accelerate
import AppKit
import AVFoundation
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import SwiftUI

/// Turns a saved meeting folder into `transcript.md` with the app's own engine:
/// each track is cut into speech chunks by Silero VAD, every chunk is one short
/// request to the shared engine cache, the microphone's copy of the remote side
/// is dropped as echo, and the two tracks are interleaved by time.
///
/// Nonisolated on purpose: converting two hours of audio and running the VAD
/// over it must never run on the main actor, or the menu and the hotkey freeze.
struct MeetingTranscriber: Sendable {
    /// Sample ranges at 16 kHz that contain speech.
    typealias SpeechDetector = @Sendable (any AudioSampleSource) async throws -> [Range<Int>]

    /// The engine one chunk goes to. Read again before every chunk, from the
    /// settings with the job's choice laid over them: a job without a choice
    /// follows the settings, since one that kept its first engine would reload
    /// the model after each dictation once the user switched engines (the
    /// cache holds one engine); a job with a choice keeps it to the end.
    struct Engine: Sendable, Equatable {
        let descriptor: EngineDescriptor
        let request: EngineDecodeRequest
        /// Engine and model folder, for the transcript header.
        let label: String
    }

    struct Utterance: Sendable, Equatable, Codable {
        var speaker: String
        var text: String
        var start: Double
        var end: Double
    }

    enum Step: Sendable, Equatable {
        case reading(track: String)
        case detecting(track: String)
        /// The cache is loading the model for the next chunk.
        case preparingModel
        /// The cache is busy with another request; it may be a dictation, or
        /// the model being prepared for one. Or the dictation holds its own
        /// engine, and this chunk needs another (`heldByDictation`).
        case waitingForEngine
        /// Sent once the engine is ready, while chunk `done` is recognized.
        case recognizing(track: String, done: Int, total: Int)
        case compressing(track: String)
        case moving
        case removingAudio
    }

    struct TrackReport: Sendable, Equatable, Codable {
        var name: String
        var speechSeconds: Double = 0
        var chunks = 0
        var skippedChunks = 0
        var failedChunks = 0
        var longestChunkSeconds: Double = 0
    }

    struct Report: Sendable {
        var tracks: [TrackReport] = []
        /// Both tracks as recognized, before echo removal; kept for calibration.
        var microphone: [Utterance] = []
        var system: [Utterance] = []
        var echoRemoved = 0
        var lines: [Utterance] = []
        var engines: [String] = []
        /// The same engines as `DictationEngine` raw values, for the attempt record.
        var engineIDs: [String] = []
        /// The labels this run wrote for each track; a line's source is the
        /// track whose label it carries.
        var microphoneSpeaker = ""
        var systemSpeaker = ""
        /// Every language a kept chunk was recognized in, for the header:
        /// codes, or "auto" for Parakeet left without a filter.
        var languages: [String] = []
        /// Whisper on "auto": what the first chunk over
        /// `languageFixSeconds` was recognized in; every later chunk is.
        var fixedLanguage: String?
        /// Wall time of every chunk request, including any wait in the queue.
        var chunkSeconds: [Double] = []
        /// Nil when there was no speech: no file is written then.
        var transcript: URL?
        /// Of the bytes written to `transcript`.
        var fingerprint: MeetingAttempt.Fingerprint?
        /// Where the job was, for the note on a transcript cut short.
        var position = ""
        /// The track by its file, not its shown name: that name is translated.
        var positionTrack: URL?
        /// Set when the job broke off after recognizing something.
        var interruption: String?
        /// Why the last chunk that failed did.
        var lastChunkFailure: String?
    }

    enum Failure: LocalizedError, Equatable {
        case notAMeetingFolder(String)
        case stillRecording(String)
        case missingVADModel(String)
        case modelNotDownloaded
        case unreadableAudio(name: String, reason: String)
        /// A file with some chunks recognized and some not: what was
        /// recognized comes with it, so nothing is lost and nothing passes
        /// for complete.
        case incompleteFile(lines: [Utterance], failedChunks: Int, reason: String)
        /// A file that broke off after something was recognized: that text
        /// comes with it, and the rest of the file was never reached.
        case fileCutShort(lines: [Utterance], position: String, reason: String)
        case repeatedChunkFailures(String)
        case nothingRecognized(failed: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .notAMeetingFolder(let name):
                return String(localized: "“\(name)” is not a meeting folder: it has no system.caf or microphone.caf")
            case .stillRecording(let name):
                return String(localized: "Meeting “\(name)” is still recording, or the recording broke off")
            case .missingVADModel(let path):
                return String(localized: "The speech detection model (VAD) is missing: \(path)")
            case .modelNotDownloaded:
                return String(localized: """
                    The transcription model is not downloaded. Download it from the “M” menu → \
                    “Download Model…”, then choose “Transcribe Meeting…” and pick this folder
                    """)
            case .unreadableAudio(let name, let reason):
                return String(localized: "Couldn’t read the audio in “\(name)”: \(reason)")
            case .incompleteFile(_, let failed, let reason):
                return String(localized: """
                    Not everything was transcribed: pieces not recognized — \(failed) (\(reason)). \
                    The text has gaps
                    """)
            case .fileCutShort(_, let position, let reason):
                return String(localized: """
                    Transcription stopped at \(position) (\(reason)); \
                    the rest of the file was not transcribed
                    """)
            case .repeatedChunkFailures(let reason):
                return String(localized: "Three pieces in a row were not recognized: \(reason)")
            case .nothingRecognized(let failed, let reason):
                return String(localized: "Speech was found but not recognized (errors: \(failed)): \(reason)")
            }
        }
    }

    static let sampleRate = 16_000
    /// Speaker labels in the transcript, in the language of the interface.
    static var microphoneSpeaker: String { String(localized: "Me", comment: "Transcript speaker: the microphone track") }
    static var systemSpeaker: String {
        String(localized: "Others", comment: "Transcript speaker: everyone heard through the system audio")
    }
    static let vadModelPath = ModelDownloader.defaultRoot
        .appendingPathComponent(ModelSource.vad.destination, isDirectory: true).path
    /// FluidAudio's own ASR guard (0.3 s); a shorter chunk would fail the request.
    static let minimumChunkSamples = ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
    /// Whisper detects a language anew on every request, and on a short reply
    /// it can be any language; a chunk this long is trusted for the meeting.
    static let languageFixSeconds = 5.0

    let cache: WhisperKitCache
    /// Given the job's choice, like `currentEngine` and `dictionary`; nil
    /// follows the settings.
    let loadSpeechDetector: @Sendable (SettingsSnapshot.Choice?) async throws -> SpeechDetector
    let currentEngine: @Sendable (SettingsSnapshot.Choice?) async throws -> Engine
    var temporaryRoot = FileManager.default.temporaryDirectory
    /// The personal dictionary, read once as a job starts, unlike the engine:
    /// every line of a meeting gets the same one. None by default.
    var dictionary: @Sendable (SettingsSnapshot.Choice?) async -> DictionarySnapshot? = { _ in nil }
    /// The engine the dictation holds now (`DictationCoordinator.heldEngine`);
    /// a chunk in another engine waits for it. None by default.
    var heldByDictation: @Sendable () async -> EngineDescriptor? = { nil }

    func transcribe(
        _ folder: Folder,
        choice: SettingsSnapshot.Choice? = nil,
        report progress: @Sendable (Step) async -> Void
    ) async throws -> Report {
        Self.removeStaleTemporaryFiles(in: folder.directory)
        // Taken before the first wait: an edit made while the speech model
        // loads belongs to the next job.
        let snapshot = await dictionary(choice)
        // Before any conversion: a missing model must fail the job at once.
        let detect = try await loadSpeechDetector(choice)
        let replacer = snapshot?.replacer(for: .meetings)
        let work = temporaryRoot.appendingPathComponent(
            "Murmurly-meeting-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var report = Report()
        report.microphoneSpeaker = Self.microphoneSpeaker
        report.systemSpeaker = Self.systemSpeaker
        let tracks: [(URL?, Float, String, String, WritableKeyPath<Report, [Utterance]>)] = [
            (folder.microphone, folder.microphoneGain, report.microphoneSpeaker, String(localized: "microphone"), \.microphone),
            (folder.system, folder.systemGain, report.systemSpeaker, String(localized: "others"), \.system),
        ]
        do {
            for case let (url?, gain, speaker, name, list) in tracks {
                try await transcribeTrack(
                    url, gain: gain, speaker: speaker, name: name, into: list, work: work,
                    choice: choice, detect: detect, report: &report, progress: progress
                )
            }
        } catch {
            // The user's cancel writes nothing. Any other break keeps what was
            // already recognized: on a two-hour call that is most of the work.
            if Task.isCancelled || error is CancellationError { throw error }
            guard !report.microphone.isEmpty || !report.system.isEmpty else { throw error }
            report.interruption = Self.interruptionNote(report, folder: folder, error: error)
            AppLog.error("meeting-transcript", "cut short at \(report.position): \(error.localizedDescription)")
        }

        let echo = Self.removingEcho(microphone: report.microphone, system: report.system)
        report.echoRemoved = echo.removed
        report.lines = Self.finished(echo.kept + report.system, dictionary: replacer)
        try Task.checkCancellation()
        guard !report.lines.isEmpty else {
            // Speech was found and not one chunk of it came back: a failure,
            // not a silent call, or the user never learns the engine broke.
            let failed = report.tracks.reduce(0) { $0 + $1.failedChunks }
            if failed > 0 {
                throw Failure.nothingRecognized(failed: failed, reason: report.lastChunkFailure ?? "")
            }
            AppLog.info("meeting-transcript", "no speech in \(folder.directory.lastPathComponent)")
            return report
        }
        let markdown = Self.markdown(report, folder: folder)
        let bytes = Data(markdown.utf8)
        report.fingerprint = MeetingAttempt.Fingerprint(
            bytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        report.transcript = try Self.write(markdown, into: folder.directory)
        return report
    }

    /// One file from the Files tab: the meeting pipeline on a single track,
    /// in the tab's choice of engine and language or, without one, as the
    /// settings say chunk by chunk, timecodes and cancellation included.
    /// Unlike `transcribe(_:)` it leaves the file's folder alone — that is the
    /// user's own folder, so nothing is cleaned or written next to the file;
    /// the work chunks live in the temporary folder only.
    func transcribeFile(
        _ url: URL,
        choice: SettingsSnapshot.Choice? = nil,
        report progress: @Sendable (Step) async -> Void
    ) async throws -> [Utterance] {
        let snapshot = await dictionary(choice)
        let detect = try await loadSpeechDetector(choice)
        let replacer = snapshot?.replacer(for: .files)
        let work = temporaryRoot.appendingPathComponent(
            "Murmurly-file-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var report = Report()
        do {
            try await transcribeTrack(
                url, gain: 1, speaker: "", name: String(localized: "file"), into: \.system, work: work,
                choice: choice, detect: detect, report: &report, progress: progress
            )
        } catch {
            // As with a meeting, a break keeps what was recognized; the user's
            // cancel is still a cancel.
            if Task.isCancelled || error is CancellationError || report.system.isEmpty { throw error }
            AppLog.error("run", "cut short at \(report.position): \(error.localizedDescription)")
            throw Failure.fileCutShort(
                lines: Self.finished(report.system, dictionary: replacer),
                position: report.position, reason: error.localizedDescription
            )
        }
        let failed = report.tracks.reduce(0) { $0 + $1.failedChunks }
        let reason = report.lastChunkFailure ?? ""
        if failed > 0 {
            if report.system.isEmpty { throw Failure.nothingRecognized(failed: failed, reason: reason) }
            throw Failure.incompleteFile(
                lines: Self.finished(report.system, dictionary: replacer), failedChunks: failed, reason: reason
            )
        }
        return Self.finished(report.system, dictionary: replacer)
    }

    /// Recognized lines go straight into `report`, so a later failure cannot
    /// take them with it.
    private func transcribeTrack(
        _ url: URL,
        gain: Float,
        speaker: String,
        name: String,
        into list: WritableKeyPath<Report, [Utterance]>,
        work: URL,
        choice: SettingsSnapshot.Choice?,
        detect: SpeechDetector,
        report: inout Report,
        progress: @Sendable (Step) async -> Void
    ) async throws {
        report.positionTrack = url
        report.position = String(localized: "\(name), start of the track")
        await progress(.reading(track: name))
        let disk: DiskBackedAudioSampleSource
        do {
            disk = try AudioSourceFactory()
                .makeDiskBackedSource(from: url, targetSampleRate: Self.sampleRate).source
        } catch {
            // AVAudioFile's own message is a bare OSStatus.
            throw Failure.unreadableAudio(name: url.lastPathComponent, reason: error.localizedDescription)
        }
        defer { disk.cleanup() }
        // A compressed track was scaled down to fit 24-bit ALAC; both the VAD
        // and the engine get the original level back, since a quieter track
        // is recognized worse.
        let source: any AudioSampleSource = gain == 1 ? disk : GainRestoredSource(base: disk, gain: gain)
        try Task.checkCancellation()
        await progress(.detecting(track: name))
        let ranges = try await detect(source)
        var track = TrackReport(name: name, chunks: ranges.count)
        track.speechSeconds = Double(ranges.reduce(0) { $0 + $1.count }) / Double(Self.sampleRate)
        defer { report.tracks.append(track) }

        var consecutiveFailures = 0
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let seconds = Double(range.count) / Double(Self.sampleRate)
            track.longestChunkSeconds = max(track.longestChunkSeconds, seconds)
            guard range.count >= Self.minimumChunkSamples else {
                track.skippedChunks += 1
                continue
            }
            let start = Double(range.lowerBound) / Double(Self.sampleRate)
            report.position = String(
                localized: "\(name), \(TranscriptSegment.timecode(start)), piece \(index + 1) of \(ranges.count)"
            )
            let chunk = work.appendingPathComponent("chunk-\(index).caf")
            defer { try? FileManager.default.removeItem(at: chunk) }
            try Self.writeChunk(from: source, range: range, to: chunk)

            let engine = try await engine(for: choice, progress: progress)
            if !report.engines.contains(engine.label) { report.engines.append(engine.label) }
            let engineID = engine.descriptor.engine.rawValue
            if !report.engineIDs.contains(engineID) { report.engineIDs.append(engineID) }
            // Until the language is fixed, chunks go on "auto": a short reply
            // must not be dropped or forced into a language it may not be in.
            let automatic = engine.request == .whisper(WhisperDecodeRequest(language: nil))
            let request: EngineDecodeRequest = automatic
                ? .whisper(WhisperDecodeRequest(language: report.fixedLanguage))
                : engine.request
            let started = ContinuousClock.now
            do {
                let decoded = try await recognize(
                    chunk, engine: engine.descriptor, request: request,
                    as: .recognizing(track: name, done: index, total: ranges.count), progress: progress
                )
                report.chunkSeconds.append(Self.seconds(since: started))
                consecutiveFailures = 0
                let text = decoded.segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Parakeet answers a breath or a click with a lone ".".
                guard !Self.normalizedWords(text).isEmpty else { continue }
                if !report.languages.contains(decoded.language) { report.languages.append(decoded.language) }
                if automatic, report.fixedLanguage == nil, seconds > Self.languageFixSeconds {
                    report.fixedLanguage = decoded.language
                }
                report[keyPath: list].append(
                    Utterance(speaker: speaker, text: text, start: start, end: start + seconds)
                )
            } catch let error as TranscriptionError {
                // A missing or broken model fails every next chunk the same way.
                throw error
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                track.failedChunks += 1
                report.lastChunkFailure = error.localizedDescription
                consecutiveFailures += 1
                AppLog.error("meeting-transcript", "\(name) chunk \(index) failed: \(error.localizedDescription)")
                if consecutiveFailures >= 3 {
                    throw Failure.repeatedChunkFailures(error.localizedDescription)
                }
            }
        }
        if track.skippedChunks > 0 {
            AppLog.info("meeting-transcript", "\(name): skipped \(track.skippedChunks) chunks under 0.3 s")
        }
    }

    /// The engine for the next chunk, once the dictation lets the cache have
    /// it: a chunk in an engine other than the dictation's waits while the
    /// dictation records or is recognized and a while after, so a dictation
    /// does not wait for its model to load back. Checked right before the
    /// request; read again after a wait, as the settings may have changed.
    /// The wait is a part of the job: quit and updates see it running.
    private func engine(
        for choice: SettingsSnapshot.Choice?,
        progress: @Sendable (Step) async -> Void
    ) async throws -> Engine {
        var engine = try await currentEngine(choice)
        var waiting = false
        while let held = await heldByDictation(), held != engine.descriptor {
            if !waiting {
                waiting = true
                await progress(.waitingForEngine)
            }
            try await Task.sleep(for: .milliseconds(250))
            engine = try await currentEngine(choice)
        }
        return engine
    }

    /// One chunk through the cache, its phases shown from inside that very
    /// operation: the cache reports in order whether it waits for the engine,
    /// loads the model or has the engine ready, and the job shows each state
    /// before reading the next. The stream is read to its end before the result
    /// is taken, so no step can arrive after it, and "recognizing" means the
    /// engine really is at work on this chunk.
    private func recognize(
        _ chunk: URL,
        engine: EngineDescriptor,
        request: EngineDecodeRequest,
        as recognizing: Step,
        progress: @Sendable (Step) async -> Void
    ) async throws -> EngineTranscriptDTO {
        let (states, reported) = AsyncStream.makeStream(of: WhisperModelState.self)
        async let decoded = Self.decode(chunk.path, engine: engine, request: request, cache: cache, reporting: reported)
        for await state in states {
            switch state {
            case .waiting: await progress(.waitingForEngine)
            case .loading: await progress(.preparingModel)
            case .ready: await progress(recognizing)
            case .cold: break   // never reported by an operation
            }
        }
        return try await decoded
    }

    private static func decode(
        _ path: String,
        engine: EngineDescriptor,
        request: EngineDecodeRequest,
        cache: WhisperKitCache,
        reporting states: AsyncStream<WhisperModelState>.Continuation
    ) async throws -> EngineTranscriptDTO {
        defer { states.finish() }
        return try await cache.transcribe(audioPath: path, descriptor: engine, request: request) {
            _ = states.yield($0)
        }
    }

    /// Says where the job stopped and what the text below does and does not
    /// cover, so a cut-short transcript is never mistaken for a whole one.
    private static func interruptionNote(_ report: Report, folder: Folder, error: Error) -> String {
        var note = String(localized: """
            ⚠︎ Transcription broke off: \(report.position) — \(error.localizedDescription). \
            What was recognized up to that point is saved.
            """)
        if report.positionTrack == folder.microphone, folder.system != nil {
            note += " " + String(localized: "The others were not transcribed.")
        } else if report.positionTrack == folder.system, folder.microphone != nil {
            note += " " + String(localized: "After this point the echo from the microphone was not removed.")
        }
        return note
    }

    private static func writeChunk(from source: any AudioSampleSource, range: Range<Int>, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw TranscriptionError.conversionFailed(String(localized: "couldn’t prepare a piece of audio"))
        }
        try source.copySamples(into: channel, offset: range.lowerBound, count: range.count)
        buffer.frameLength = AVAudioFrameCount(range.count)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// Divides every sample by the gain compression applied. Division rather
/// than multiplying by the inverse: one rounding instead of two.
private struct GainRestoredSource: AudioSampleSource {
    let base: any AudioSampleSource
    let gain: Float

    var sampleCount: Int { base.sampleCount }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        try base.copySamples(into: destination, offset: offset, count: count)
        var divisor = gain
        vDSP_vsdiv(destination, 1, &divisor, destination, 1, vDSP_Length(count))
    }
}

// MARK: - Production wiring

extension MeetingTranscriber {
    /// `speechDetector` loads the VAD from its model folder; a test gives one
    /// of its own and keeps the rest of this wiring.
    static func live(
        settings: SettingsStore,
        models: ModelDownloader,
        cache: WhisperKitCache = .shared,
        speechDetector: @escaping @Sendable (_ modelPath: String) async throws -> SpeechDetector = {
            try await sileroDetector(modelPath: $0)
        }
    ) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: cache,
            // Checked first, before any conversion: the recording is kept, and
            // the job says how to get the model and come back to it. The
            // job's own engine, with its tokenizer and the VAD: the settings'
            // engine may be missing while the chosen one is there, and the
            // other way round. Again as each job starts, whatever was checked
            // when it was queued.
            loadSpeechDetector: { choice in
                try await MainActor.run {
                    guard models.missing(settings.snapshot.applying(choice).dictationEngine).isEmpty else {
                        throw Failure.modelNotDownloaded
                    }
                }
                return try await speechDetector(models.root.appendingPathComponent(ModelSource.vad.destination).path)
            },
            currentEngine: { choice in
                try await MainActor.run { try Engine.forMeeting(settings.snapshot.applying(choice)) }
            },
            dictionary: dictionary(of: settings)
        )
    }

    /// Only the snapshot is read on the main actor; the job prepares the
    /// variants' word forms from it, off the main actor, once. Entries and
    /// switches are the settings'; whether word forms match follows the job's
    /// engine and language, as its request does: a meeting chosen in English
    /// is not bent by a Russian tagger.
    static func dictionary(of settings: SettingsStore) -> @Sendable (SettingsSnapshot.Choice?) async -> DictionarySnapshot? {
        { choice in
            await MainActor.run {
                var dictionary = settings.dictionarySnapshot
                let job = settings.snapshot.applying(choice)
                dictionary.matchesWordForms = DictionarySnapshot.matchesWordForms(
                    engine: job.dictationEngine, language: job.dictationLanguage
                )
                return dictionary
            }
        }
    }

    /// Loaded by hand rather than through `VadManager(modelDirectory:)`: that
    /// path goes through ModelHub, which downloads when offline mode is off and
    /// deletes the model folder after a failed load.
    static func sileroDetector(modelPath: String) async throws -> SpeechDetector {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.missingVADModel(modelPath)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(
            contentsOf: URL(fileURLWithPath: modelPath, isDirectory: true),
            configuration: configuration
        )
        let vad = VadManager(config: .default, vadModel: model)
        return { source in try await speechRanges(in: source, vad: vad) }
    }

    /// Streams the track through the VAD block by block instead of
    /// `segmentSpeech(_ samples:)`, which needs the whole track in memory (a
    /// two-hour track would cost about 1 GB on top of its conversion) and cannot
    /// be cancelled. The probabilities are the same: same blocks, same carried
    /// model state.
    private static func speechRanges(
        in source: any AudioSampleSource,
        vad: VadManager
    ) async throws -> [Range<Int>] {
        let total = source.sampleCount
        var state = VadStreamState.initial()
        var probabilities: [Float] = []
        probabilities.reserveCapacity(total / VadManager.chunkSize + 1)
        var offset = 0
        while offset < total {
            try Task.checkCancellation()
            let count = min(VadManager.chunkSize, total - offset)
            var block = [Float](repeating: 0, count: count)
            try block.withUnsafeMutableBufferPointer {
                try source.copySamples(into: $0.baseAddress!, offset: offset, count: count)
            }
            let result = try await vad.processStreamingChunk(block, state: state)
            state = result.state
            probabilities.append(result.probability)
            offset += count
        }
        // Segmentation reads only the probabilities; one shared blank state
        // keeps tens of thousands of results from each allocating their own.
        let blank = VadState.initial()
        let threshold = VadConfig.default.defaultThreshold
        let results = probabilities.map {
            VadResult(probability: $0, isVoiceActive: $0 >= threshold, processingTime: 0, outputState: blank)
        }
        let segments = await vad.segmentSpeech(from: results, totalSamples: total)
        return segments.compactMap { segment in
            let start = max(0, min(total, segment.startSample(sampleRate: sampleRate)))
            let end = max(start, min(total, segment.endSample(sampleRate: sampleRate)))
            return end > start ? start..<end : nil
        }
    }
}

extension MeetingTranscriber.Engine {
    /// The snapshot's engine and language: the dictation's, or a job's
    /// choice laid over them. On "auto" Whisper's language is fixed during
    /// the job (`languageFixSeconds`).
    static func forMeeting(_ snapshot: SettingsSnapshot) throws -> Self {
        let descriptor = snapshot.dictationDescriptor
        let model = URL(fileURLWithPath: descriptor.modelPath).lastPathComponent
        return Self(
            descriptor: descriptor,
            request: snapshot.decodeRequest,
            label: "\(snapshot.dictationEngine.title) (\(model))"
        )
    }
}

// MARK: - Meeting folder

extension MeetingTranscriber {
    struct Folder: Sendable, Equatable {
        let directory: URL
        let startedAt: Date?
        let microphone: URL?
        let system: URL?
        /// What compression scaled each track by (see `MeetingStorage`).
        var microphoneGain: Float = 1
        var systemGain: Float = 1

        /// Reads `metadata.json` loosely, not as `MeetingMetadata`: July
        /// recordings have no `endedAt`, and that type must keep requiring it
        /// for the quit-time proof that a recording was saved.
        static func inspect(_ directory: URL) throws -> Folder {
            struct Metadata: Decodable {
                struct Segment: Decodable {
                    var system: String?
                    var mic: String?
                    var systemGain: Double?
                    var micGain: Double?
                }
                var startedAt: String?
                var state: String?
                var segments: [Segment]?
            }
            let name = directory.lastPathComponent
            let metadata = (try? Data(contentsOf: directory.appendingPathComponent("metadata.json")))
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            if metadata?.state == "recording" { throw Failure.stillRecording(name) }

            // Names are reduced to their last component so the tracks always
            // stay inside the chosen folder.
            func track(_ listed: String?, fallback: String) -> URL? {
                let file = listed.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallback
                let url = directory.appendingPathComponent(file)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return nil }
                return url
            }
            let first = metadata?.segments?.first
            let microphone = track(first?.mic, fallback: "microphone.caf")
            let system = track(first?.system, fallback: "system.caf")
            guard microphone != nil || system != nil else { throw Failure.notAMeetingFolder(name) }

            let startedAt = metadata?.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? Self.date(fromFolderName: name)
            // A gain that is not a positive finite number is not ours: ignored.
            func gain(_ value: Double?) -> Float {
                guard let value, value.isFinite, value > 0 else { return 1 }
                return Float(value)
            }
            return Folder(
                directory: directory,
                startedAt: startedAt,
                microphone: microphone,
                system: system,
                microphoneGain: gain(first?.micGain),
                systemGain: gain(first?.systemGain)
            )
        }

        /// `yyyy-MM-dd HH-mm-ss Meeting`, as `RecordingsStore.createSession` names folders.
        static func date(fromFolderName name: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            return formatter.date(from: String(name.prefix(19)))
        }
    }
}

// MARK: - Attempt record

extension MeetingAttempt {
    /// The result from the transcriber's report, before it is reduced to the
    /// menu's outcome: only the report knows the failed chunks, the tracks it
    /// had and where each line came from. Complete means nothing missing:
    /// not cut short, no chunk failed, and both tracks the folder names (or,
    /// without names, the default ones) were there and transcribed.
    mutating func finish(_ report: MeetingTranscriber.Report, folder: MeetingTranscriber.Folder, at date: Date = Date()) {
        endedAt = date
        engines = report.engineIDs
        languages = report.languages
        failedChunks = report.tracks.reduce(0) { $0 + $1.failedChunks }
        cutShort = report.interruption != nil
        missingTracks = (folder.microphone == nil ? [.microphone] : []) + (folder.system == nil ? [.system] : [])
        speakers = Speakers(microphone: report.microphoneSpeaker, system: report.systemSpeaker)
        lines = report.lines.map {
            Line(start: $0.start, end: $0.end, source: $0.speaker == report.microphoneSpeaker ? .microphone : .system)
        }
        transcript = report.transcript?.lastPathComponent
        fingerprint = report.fingerprint
        if transcript == nil {
            result = .noSpeech
        } else {
            result = !cutShort && failedChunks == 0 && missingTracks.isEmpty ? .complete : .incomplete
        }
    }

    mutating func fail(_ reason: String, at date: Date = Date()) {
        result = .failed
        self.reason = reason
        endedAt = date
    }
}

// MARK: - Echo, order, markdown, file

extension MeetingTranscriber {
    /// Without headphones the microphone also records the remote side. A
    /// microphone chunk is echo when the system text overlapping it in time
    /// contains its words in order; containment rather than a symmetric ratio,
    /// because the overlapping system chunks usually hold more speech than the
    /// microphone chunk does.
    static let echoContainment = 0.5
    /// Short replies ("yes", "uh-huh") match by chance in any long system chunk.
    static let minimumEchoWords = 3
    static let echoSlack = 0.5

    static func removingEcho(
        microphone: [Utterance],
        system: [Utterance]
    ) -> (kept: [Utterance], removed: Int) {
        let systemWords = system.map { normalizedWords($0.text) }
        var kept: [Utterance] = []
        var removed = 0
        for utterance in microphone {
            let words = normalizedWords(utterance.text)
            guard words.count >= minimumEchoWords else {
                kept.append(utterance)
                continue
            }
            let reference = system.indices.filter {
                system[$0].start < utterance.end + echoSlack && system[$0].end > utterance.start - echoSlack
            }.flatMap { systemWords[$0] }
            let found = commonSubsequenceLength(words, reference)
            if !reference.isEmpty, Double(found) / Double(words.count) >= echoContainment {
                removed += 1
            } else {
                kept.append(utterance)
            }
        }
        return (kept, removed)
    }

    /// The microphone track comes out without punctuation and the system track
    /// with it, so words are compared without case, punctuation or the Russian
    /// yo/ye spelling difference (the same word is written both ways).
    static func normalizedWords(_ text: String) -> [String] {
        let letters = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(letters).split(separator: " ").map(String.init)
    }

    private static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for word in a {
            for (index, other) in b.enumerated() {
                current[index + 1] = word == other
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Every result's last step: merged lines, then the personal dictionary
    /// on each line's text. After echo removal, which counts words, and
    /// after merging, so a phrase split between two chunks of one speaker
    /// is found too. Speakers, times and the recognized tracks stay as they are.
    static func finished(_ utterances: [Utterance], dictionary: DictionaryReplacer?) -> [Utterance] {
        var lines = merged(utterances)
        guard let dictionary else { return lines }
        let replaced = dictionary.replacing(in: lines.map(\.text))
        for index in lines.indices { lines[index].text = replaced.texts[index] }
        // The count only: the log never holds what was said.
        if replaced.count > 0 { AppLog.info("dictionary", "replacements=\(replaced.count)") }
        return lines
    }

    static let glueGap = 1.5
    /// A timecode at least once a minute: the user checks the text against
    /// the audio by it, and without voices every remote speaker is one label.
    static let maximumBlockSeconds = 60.0

    /// Time order, then neighbouring chunks of one speaker joined while the
    /// pause is short and the block stays under a minute.
    static func merged(_ utterances: [Utterance]) -> [Utterance] {
        let ordered = utterances.enumerated().sorted {
            ($0.element.start, $0.offset) < ($1.element.start, $1.offset)
        }.map(\.element)
        var lines: [Utterance] = []
        for utterance in ordered {
            if var last = lines.last,
               last.speaker == utterance.speaker,
               utterance.start - last.end < glueGap,
               utterance.end - last.start <= maximumBlockSeconds {
                last.text += " " + utterance.text
                last.end = max(last.end, utterance.end)
                lines[lines.count - 1] = last
            } else {
                lines.append(utterance)
            }
        }
        return lines
    }

    static func markdown(_ report: Report, folder: Folder) -> String {
        let title: String
        if let startedAt = folder.startedAt {
            let date = startedAt.formatted(.dateTime.day().month(.wide).year().hour().minute())
            title = String(localized: "Meeting \(date)")
        } else {
            title = String(localized: "Meeting \(folder.directory.lastPathComponent)")
        }
        // Language names come from the system in the interface language.
        let languages = report.languages.map {
            $0 == "auto" ? String(localized: "auto", comment: "Transcript header: language not fixed")
                : DictationEngine.languageName($0)
        }.joined(separator: ", ")
        let engines = report.engines.joined(separator: ", ")
        var notes = [
            [
                String(localized: "Automatic transcript."),
                report.engines.count > 1
                    ? String(localized: "Engines: \(engines).") : String(localized: "Engine: \(engines)."),
                report.languages.count > 1
                    ? String(localized: "Languages: \(languages).") : String(localized: "Language: \(languages)."),
            ].joined(separator: " "),
            String(localized: """
                “\(microphoneSpeaker)” is the microphone, “\(systemSpeaker)” is the system audio; \
                the other voices are not told apart. Echo lines removed from the microphone: \(report.echoRemoved).
                """),
        ]
        let failed = report.tracks.reduce(0) { $0 + $1.failedChunks }
        if failed > 0 { notes.append(String(localized: "Pieces not recognized: \(failed).")) }
        if let interruption = report.interruption { notes.append(interruption) }
        let lines = report.lines.map {
            "[\(TranscriptSegment.timecode($0.start))] **\($0.speaker):** \($0.text)"
        }
        return (["# \(title)", notes.joined(separator: "\n"), "---"] + lines)
            .joined(separator: "\n\n") + "\n"
    }

    static let temporaryPrefix = ".transcript-"
    static let temporarySuffix = ".tmp"

    /// Never replaces a file: a manual transcript already lives in some folders.
    /// The text goes to a hidden file in the same folder first and is then
    /// moved, so a killed process leaves no half transcript, and the move stays
    /// atomic when meetings later live on another disk.
    static func write(_ markdown: String, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let temporary = directory.appendingPathComponent(
            temporaryPrefix + UUID().uuidString + temporarySuffix
        )
        try Data(markdown.utf8).write(to: temporary, options: .withoutOverwriting)
        defer { try? fileManager.removeItem(at: temporary) }
        for index in 1...999 {
            let target = directory.appendingPathComponent(
                index == 1 ? "transcript.md" : "transcript \(index).md"
            )
            if fileManager.fileExists(atPath: target.path) { continue }
            do {
                try fileManager.moveItem(at: temporary, to: target)
                return target
            } catch {
                // Someone took the name between the check and the move.
                if fileManager.fileExists(atPath: target.path) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// What a killed run left behind; only names this code creates.
    static func removeStaleTemporaryFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(temporaryPrefix) && name.hasSuffix(temporarySuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

// MARK: - Queue

/// Works through meeting folders one at a time: transcription when asked for
/// and a copy of the new transcript, then, for a finished folder in the local
/// meetings root, compression and the move to the chosen meetings folder. One
/// queue for all of it, so a track is never read by one step while another
/// replaces or moves it. Deliberately not attached to `AppDelegate`: quit
/// never waits for it, and every step leaves files a later run can finish
/// from. Nothing is remembered across restarts; scans find the work again.
/// Claims one answer of several racing for it, on any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { claimed ? false : { claimed = true; return true }() } }
}

@MainActor
final class MeetingTranscriptionQueue: ObservableObject {
    enum Outcome: Equatable {
        case saved(URL)
        /// Written, but the job broke off; the reason is also in the file.
        case cutShort(URL, reason: String)
        case noSpeech(folder: URL)
        case failed(folder: URL, reason: String)
        case cancelled(folder: URL)

        var transcript: URL? {
            switch self {
            case .saved(let url), .cutShort(let url, _): return url
            case .noSpeech, .failed, .cancelled: return nil
            }
        }
    }

    struct Job: Equatable, Sendable {
        /// Where the meeting is; rewritten once this queue moves it.
        var folder: URL
        var transcribe: Bool
        /// The engine and language asked for by hand; nil follows the
        /// settings, chunk by chunk. A property of the job, not of the
        /// folder: it goes wherever the folder has moved.
        var choice: SettingsSnapshot.Choice? = nil
        /// The folder itself: as the asker knew it (the window), read at once
        /// in the local root, read off the main actor after queueing
        /// elsewhere, and read again after a move of the queue's own. Nil
        /// until known; a transcription without it holds every deletion back.
        var identity: FolderIdentity? = nil
        /// The old audio this job deletes, and under which rule; nil when
        /// it deletes none.
        var removesAudio: AudioRemoval? = nil
    }

    /// The rule's deletion of one meeting's old audio: the meeting itself,
    /// as it was counted, and the rule's generation then. Another folder put
    /// at its address is not it.
    struct AudioRemoval: Equatable, Sendable {
        let generation: Int
        let identity: FolderIdentity
    }

    /// Something done to a folder that may move or remove it: the queue's
    /// moves (their source and their destination) and its deletion of old
    /// audio, and the window's deletions. Marks, other moves and deletions
    /// ask here first. A folder is matched by itself or by its address, so a
    /// destination not made yet, or a folder reached through a link, still
    /// matches.
    struct Operation: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case moving, removing, removingAudio }
        let id: Int
        let kind: Kind
        let address: MeetingStorage.Address
    }

    /// Where finished meetings move and where transcripts are copied; nil
    /// keeps meetings in the local root and makes no copy.
    struct Destinations: Equatable, Sendable {
        var meetings: URL?
        var transcripts: URL?
    }

    /// What kept one folder from its place, step by step. In memory only:
    /// the next attempt finds the same reason again.
    struct Issues: Equatable, Sendable {
        var compression: [String] = []
        var transcriptCopy: String?
        var move: String?

        var lines: [String] {
            compression
                + (transcriptCopy.map { [String(localized: "transcript copy: \($0)")] } ?? [])
                + (move.map { [String(localized: "move: \($0)")] } ?? [])
        }
    }

    @Published private(set) var activeFolder: URL?
    @Published private(set) var step: MeetingTranscriber.Step?
    @Published private(set) var pending: [Job] = []
    /// The job under way, from the moment it leaves `pending` until it ends.
    @Published private(set) var activeJob: Job?
    /// The last transcription's outcome; the other steps report in `issues`.
    @Published private(set) var lastOutcome: Outcome?
    /// Only this step can be stopped: the others are safe to kill.
    @Published private(set) var isTranscribing = false
    /// By the folder's local path.
    @Published private(set) var issues: [URL: Issues] = [:]
    /// What became of a meeting's last attempt when it left no record in the
    /// folder: refused before it began (not a meeting folder, the recording
    /// under way) or the record could not be made. By the folder's path, not
    /// its URL: one folder comes with and without a trailing slash. Carried
    /// along when this queue moves the folder; any new attempt at the folder
    /// clears it. The cancelled are not kept: they are not results.
    @Published private(set) var unrecordedOutcomes: [String: Outcome] = [:]
    /// Counts finished jobs, so a view showing sizes knows to read them again.
    @Published private(set) var finishedJobs = 0
    /// Set by the recorder. Scans, compression and moves wait while it
    /// records, starts or stops: the stop writes `metadata.json` before the
    /// recorder rewrites it, and a folder being recorded has none yet.
    var isRecorderBusy: @MainActor () -> Bool = { false }
    /// Set by the recorder: the folder of the recording under way, which no
    /// job transcribes. It has no `metadata.json` until its stop, so
    /// `Folder.inspect` alone takes it for one cut off by a crash.
    var currentRecording: @MainActor () -> URL? = { nil }
    /// Set by the recorder: the folder of the recording under way itself,
    /// from its making to its saved stop, wherever it has been moved.
    var currentRecordingIdentity: @MainActor () -> FolderIdentity? = { nil }
    /// How a finished local folder goes to the meetings folder. A test holds
    /// it between the copy and the local folder's removal, the moment a
    /// change written into the local folder would be lost.
    var mover: @Sendable (_ folder: URL, _ target: URL, _ localRoot: URL) throws -> URL = {
        try MeetingStorage.move($0, into: $1, localRoot: $2)
    }
    /// How a scan finds the local folders with work; a test holds it with
    /// what it found, as a deletion goes on.
    var folderScan: @Sendable (_ root: URL, _ moving: Bool) -> [URL] = {
        MeetingStorage.foldersNeedingWork(in: $0, moving: $1)
    }
    /// Set by the recorder: the engine the dictation holds now
    /// (`DictationCoordinator.heldEngine`), for the job to leave alone.
    var heldByDictation: @MainActor () -> EngineDescriptor? = { nil }
    /// Set by the recorder: the dictation's own warm-up
    /// (`DictationCoordinator.prepareAfterOtherEngineJob`).
    var prepareDictationEngine: @MainActor () -> Void = {}
    /// A job with a choice may have left its own engine in the cache; the
    /// dictation's goes back once no transcription is left to run.
    private var returnsDictationEngine = false
    private let transcriber: MeetingTranscriber
    private let meetingsRoot: URL
    /// The local root's path as given and with its links resolved, read once.
    /// A folder is matched against them by its path alone: one chosen by hand
    /// may be on a network volume, and touching a dead one hangs the main actor.
    private let meetingsRootPaths: Set<String>
    private let destinations: @MainActor () -> Destinations
    private var job: Task<Void, Never>?
    private var transcription: Task<(Outcome, unrecorded: Bool), Never>?
    private var mountObserver: NSObjectProtocol?
    /// Where this run's moves put each folder, by its local path. The folder
    /// setting may change or reset afterwards; the meeting stays where it went.
    /// Published for the window, which follows a meeting it shows to its new
    /// place; only this queue writes it.
    @Published private(set) var movedTo: [String: URL] = [:]
    /// What is done now to folders that may move or remove them. Set on the
    /// main actor before the first touch of the disk, cleared at the end.
    @Published private(set) var operations: [Operation] = []
    private var operationsStarted = 0
    /// Where the job under way is, read as it starts; nil until then.
    @Published private(set) var activeAddress: MeetingStorage.Address?
    /// Counts the window's deletions: a scan that began before one drops what
    /// it found and looks again.
    private(set) var removalEpoch = 0
    /// Every deletion of a meeting's files goes through it.
    let removal: MeetingStorage.Removal
    /// Set by the window: whether a write of this folder's marks is under way
    /// or waiting. A move waits for it, or the copy would leave it behind.
    var marksBeingWritten: @MainActor (FolderIdentity) -> Bool = { _ in false }
    /// Set by the window: closes the player's files of these folders, at
    /// once, before an operation takes them.
    var releaseAudio: @MainActor (_ addresses: [MeetingStorage.Address], _ kind: Operation.Kind) -> Void = { _, _ in }
    /// Set by the window: whether the player is still opening files of any
    /// of these folders, off the main actor, where `releaseAudio` can't
    /// reach them. No operation takes a folder meanwhile.
    var audioOpening: @MainActor (Set<FolderIdentity>) -> Bool = { _ in false }

    init(
        transcriber: MeetingTranscriber,
        meetingsRoot: URL = RecordingsStore.meetingsRoot(),
        removal: MeetingStorage.Removal = .live,
        destinations: @escaping @MainActor () -> Destinations = { Destinations() }
    ) {
        self.transcriber = transcriber
        self.meetingsRoot = meetingsRoot
        self.removal = removal
        meetingsRootPaths = [meetingsRoot.standardizedFileURL.path, meetingsRoot.resolvingSymlinksInPath().path]
        self.destinations = destinations
    }

    /// Once, from the recorder's activation: the launch scan, and a scan
    /// whenever a volume appears, since the meetings folder may be on it.
    func activate() {
        guard mountObserver == nil else { return }
        restartRetentionTimer()
        pruneAudio()
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanLocalFolders() }
        }
        scanLocalFolders()
    }

    /// A folder is queued again only for a transcription it does not have
    /// yet: a scan joins any job of the folder, a transcription as the
    /// settings say joins any transcription of it, and a choice joins only the
    /// same choice. A waiting job that would transcribe as the settings say,
    /// or not at all, takes the choice over: one transcription, not two. Any
    /// other choice is a job of its own, after the others; its transcript gets
    /// the next number.
    func enqueue(
        _ directory: URL, transcribe: Bool = true, choice: SettingsSnapshot.Choice? = nil, identity: FolderIdentity? = nil
    ) {
        let folder = directory.standardizedFileURL
        // A folder of the local root is resolved here (the disk is local);
        // any other is matched by itself when the asker knew it, by its path
        // otherwise, and the job checks again as it starts, off the main actor.
        let address = isInMeetingsRoot(folder)
            ? MeetingStorage.address(of: folder) : MeetingStorage.Address(identity: identity, path: folder.path)
        if let address, let busy = operations.first(where: { $0.kind == .removing && $0.address.isSameFolder(as: address) }) {
            AppLog.info("meeting-transcript", "\(folder.lastPathComponent) is being deleted; not queued (operation \(busy.id))")
            return
        }
        // The folder itself, as resolved here or as the asker knew it.
        let identity = address?.identity ?? identity
        let transcribe = transcribe || choice != nil
        let waiting = pending.indices.filter { pending[$0].folder == folder }
        let jobs = waiting.map { pending[$0] } + [activeJob].compactMap { $0 }.filter { $0.folder == folder }
        if jobs.contains(where: { !transcribe || $0.transcribe && (choice == nil || $0.choice == choice) }) {
            AppLog.info("meeting-transcript", "already queued: \(folder.lastPathComponent)")
            return
        }
        if let index = waiting.first(where: { !pending[$0].transcribe || choice != nil && pending[$0].choice == nil }) {
            pending[index].transcribe = true
            pending[index].choice = choice
            if pending[index].identity == nil { pending[index].identity = identity }
            if pending[index].identity == nil { tell(folder) }
            AppLog.info("meeting-transcript", "queued job takes the transcription: \(folder.lastPathComponent)")
            return
        }
        pending.append(Job(folder: folder, transcribe: transcribe, choice: choice, identity: identity))
        if identity == nil { tell(folder) }
        startNextIfIdle()
    }

    /// Queues, without transcription, every finished local folder that still
    /// has work: a CAF track, or a move when the meetings folder is available.
    func scanLocalFolders() {
        let root = meetingsRoot
        let target = destinations().meetings
        let epoch = removalEpoch
        let scan = folderScan
        Task { [self] in
            let folders = await Task.detached(priority: .utility) {
                scan(root, target.map { MeetingStorage.isAvailable($0) } ?? false)
            }.value
            // A deletion since the scan began: what it found may be gone.
            guard removalEpoch == epoch else {
                AppLog.info("meeting-storage", "scan dropped: a meeting was deleted meanwhile; scanning again")
                scanLocalFolders()
                return
            }
            // Checked when the folders go in, not when the scan starts: that
            // is the moment a stop in progress could be overtaken.
            guard !isRecorderBusy() else {
                AppLog.info("meeting-storage", "scan dropped: a recording is starting or stopping")
                return
            }
            if !folders.isEmpty { AppLog.info("meeting-storage", "scan: \(folders.count) with work") }
            for folder in folders { enqueue(folder, transcribe: false) }
        }
    }

    func cancelCurrent() {
        transcription?.cancel()
    }

    /// The chosen meetings folder when there is one, unchecked: a dead
    /// network volume would hang the main actor, and the panel copes with a
    /// folder that is not there.
    var panelDirectory: URL {
        destinations().meetings ?? meetingsRoot
    }

    /// The engine and language a folder panel offers for one transcription,
    /// and the panel's delegate. Taken from the settings as the panel opens;
    /// nothing the settings do afterwards changes it, and it is never
    /// written back.
    @MainActor
    final class ChoiceDraft: NSObject, ObservableObject, NSOpenSavePanelDelegate {
        @Published var engine: DictationEngine
        /// As picked, kept across a change of engine: an engine that does
        /// not know the code shows Auto, and switching back brings it back.
        @Published var language: String
        /// Whose files the panel's Transcribe asks for; nil checks nothing.
        let models: ModelDownloader?

        init(_ settings: SettingsSnapshot, models: ModelDownloader? = nil) {
            engine = settings.dictationEngine
            language = settings.dictationLanguage
            self.models = models
        }

        struct ModelMissing: LocalizedError {
            let engine: DictationEngine
            var errorDescription: String? {
                String(localized: "The \(engine.modelName) model is not downloaded. Download it below, or choose another engine.")
            }
        }

        /// Transcribe is refused while the chosen engine misses a file, its
        /// tokenizer and the VAD included: the panel stays open, says why,
        /// and the download is right below. Its OK button cannot be turned
        /// off; a model removed later is found again as the job starts.
        func panel(_ sender: Any, validate url: URL) throws {
            guard let models, !models.missing(engine).isEmpty else { return }
            throw ModelMissing(engine: engine)
        }

        /// What the language list shows, by the settings' own rule
        /// (`SettingsStore.pickedLanguage`). Choosing writes the code.
        var shownLanguage: String {
            get { engine.language(for: language) ?? "auto" }
            set { language = newValue }
        }

        /// What the job takes when the panel is confirmed.
        var choice: SettingsSnapshot.Choice { .init(engine: engine, language: language) }
    }

    /// The folder panel with this transcription's engine and language below
    /// it, starting from the settings as they are now. Transcribe puts the
    /// folder and the whole choice into the queue at once; Cancel, nothing.
    /// `show` is a test's stand-in for the panel.
    func chooseFolder(
        settings: SettingsSnapshot, models: ModelDownloader, in directory: URL? = nil, show: AppWindowController.FolderPanel? = nil
    ) {
        let draft = ChoiceDraft(settings, models: models)
        AppWindowController.chooseFolder(
            message: String(localized: "Choose a meeting folder to transcribe"),
            prompt: String(localized: "Transcribe"),
            directory: directory ?? panelDirectory,
            accessory: Self.choiceAccessory(draft, models: models),
            delegate: draft,
            show: show
        ) { [weak self] url in
            self?.enqueue(url, choice: draft.choice)
        }
    }

    /// The view below the folders, as the panel gets it: sized as it opens.
    static func choiceAccessory(_ draft: ChoiceDraft, models: ModelDownloader) -> NSView {
        let accessory = NSHostingView(rootView: TranscriptionChoiceView(draft: draft, models: models))
        accessory.sizingOptions = [.intrinsicContentSize]
        accessory.frame.size = accessory.fittingSize
        return accessory
    }

    /// The panel again, open inside the last outcome's meeting wherever it is
    /// now: Transcribe with nothing selected takes the folder it shows.
    func transcribeAgain(settings: SettingsSnapshot, models: ModelDownloader) {
        guard let meeting = lastMeeting else { return }
        chooseFolder(settings: settings, models: models, in: meeting)
    }

    /// The last outcome's meeting, wherever it is now: where "Show…" and
    /// "Transcribe Again…" go; "Show Transcript" also names its version.
    var lastMeeting: URL? {
        switch lastOutcome {
        case .saved(let url), .cutShort(let url, _): location(of: url.deletingLastPathComponent())
        case .noSpeech(let folder), .failed(let folder, _), .cancelled(let folder): location(of: folder)
        case nil: nil
        }
    }

    func dismissOutcome() {
        lastOutcome = nil
    }

    /// The menu's line: the step and how many wait behind it.
    var statusLabel: String? {
        guard let stepLabel else { return nil }
        return stepLabel + (pending.isEmpty ? "" : " · " + String(localized: "\(pending.count) more in the queue"))
    }

    /// What the job under way is doing, in the menu's words; the window shows
    /// it on the meeting's row.
    var stepLabel: String? {
        guard activeFolder != nil else { return nil }
        switch step {
        case nil:
            return isTranscribing
                ? String(localized: "Transcribing the meeting…") : String(localized: "Processing the meeting…")
        case .reading(let track)?:
            return String(localized: "Transcribing the meeting: reading the audio (\(track))…")
        case .detecting(let track)?:
            return String(localized: "Transcribing the meeting: looking for speech (\(track))…")
        case .preparingModel?:
            return String(localized: "Transcribing the meeting: preparing the model…")
        case .waitingForEngine?:
            return String(localized: "Transcribing the meeting: waiting for the engine…")
        case .recognizing(let track, let done, let total)?:
            return String(localized: "Transcribing the meeting: \(track), \(done) of \(total)")
        case .compressing(let track)?:
            return String(localized: "Compressing the meeting: \(track)…")
        case .moving?:
            return String(localized: "Moving the meeting to the meetings folder…")
        case .removingAudio?:
            return Self.describe(.removingAudio)
        }
    }

    private func startNextIfIdle() {
        guard job == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        activeJob = next
        activeFolder = next.folder
        step = nil
        job = Task { [self] in
            // A folder queued before an earlier job moved it is found there;
            // only the address changes, the job's choice goes with it.
            let folder = location(of: next.folder)
            // The folder as it is now, read off the main actor; one the window
            // is deleting is left alone, whatever the job knew of it.
            let resolved = await Task.detached(priority: .utility) { MeetingStorage.address(of: folder) }.value
            guard let address = resolved else {
                // Unknown is no reason to go past a deletion, nor to work;
                // a transcription asked for says why it did not happen.
                AppLog.error("meeting-transcript", "\(folder.lastPathComponent) can’t be told; job dropped")
                if next.transcribe {
                    let outcome = Outcome.failed(
                        folder: folder, reason: String(localized: "The meeting folder isn’t available: \(folder.path)")
                    )
                    unrecordedOutcomes[folder.standardizedFileURL.path] = outcome
                    lastOutcome = outcome
                }
                finish(folder)
                return
            }
            activeAddress = address
            if let busy = operations.first(where: { $0.kind == .removing && $0.address.isSameFolder(as: address) }) {
                AppLog.info("meeting-transcript", "\(folder.lastPathComponent) is being deleted; job dropped (operation \(busy.id))")
                finish(folder)
                return
            }
            if next.transcribe {
                let outcome = await transcribe(next, at: folder)
                lastOutcome = outcome
                if let transcript = outcome.transcript { await copy(transcript, of: folder) }
                // After the result and its copy, and apart from them. At the
                // end of a series, whatever its last job was: one in between
                // would load both models in turn.
                if next.choice != nil { returnsDictationEngine = true }
                if returnsDictationEngine, !pending.contains(where: \.transcribe) {
                    returnsDictationEngine = false
                    prepareDictationEngine()
                }
            }
            // After the transcription and its copy: the rule looks at what
            // they left. Before compression, which need not touch audio
            // that goes.
            if let removal = next.removesAudio { await removeOldAudio(folder, removal: removal) }
            // A folder asked for by hand may be the one being recorded; the
            // scan after the stop comes back for whatever is skipped here.
            if isInMeetingsRoot(folder) {
                if isRecorderBusy() {
                    AppLog.info("meeting-storage", "\(folder.lastPathComponent): recorder busy, compression waits")
                } else {
                    await compress(folder)
                }
                if isRecorderBusy() {
                    AppLog.info("meeting-storage", "\(folder.lastPathComponent): recorder busy, move waits")
                } else {
                    await move(folder)
                }
            }
            finish(folder)
        }
    }

    /// Runs in its own task, so stopping it leaves the other steps for the
    /// same folder to go ahead.
    private func transcribe(_ next: Job, at folder: URL) async -> Outcome {
        let key = folder.standardizedFileURL.path
        unrecordedOutcomes[key] = nil
        if currentRecording()?.standardizedFileURL.path == key {
            let outcome = Outcome.failed(
                folder: folder,
                reason: MeetingTranscriber.Failure.stillRecording(folder.lastPathComponent).localizedDescription
            )
            AppLog.error("meeting-transcript", "\(folder.lastPathComponent): still recording, not transcribed")
            unrecordedOutcomes[key] = outcome
            return outcome
        }
        isTranscribing = true
        step = nil
        // The language as a code: what was said never goes to the log.
        AppLog.info("meeting-transcript", "start \(folder.lastPathComponent) " + (next.choice.map {
            "engine=\($0.engine.rawValue) language=\($0.language)"
        } ?? "as the settings say"))
        var transcriber = self.transcriber
        let held = heldByDictation
        transcriber.heldByDictation = { await MainActor.run { held() } }
        let choice = next.choice
        // The record is made and finished inside this task, before
        // `isTranscribing` goes back: quit and updates see the whole attempt.
        let task = Task.detached(priority: .utility) { [self] () -> (Outcome, unrecorded: Bool) in
            let started = ContinuousClock.now
            // Only a folder the transcript could go to gets a record: not one
            // chosen by mistake, nor one recorded right now.
            let inspected: MeetingTranscriber.Folder
            let record: (url: URL, attempt: MeetingAttempt)
            do {
                inspected = try MeetingTranscriber.Folder.inspect(folder)
            } catch {
                let outcome = Outcome.failed(folder: folder, reason: error.localizedDescription)
                AppLog.error("meeting-transcript", "\(folder.lastPathComponent): \(outcome)")
                return (outcome, true)
            }
            do {
                record = try MeetingAttempt.begin(in: folder)
            } catch {
                // Without a record a later failure would leave no trace, and
                // an earlier success would pass for the last word.
                let outcome = Outcome.failed(folder: folder, reason: String(
                    localized: "Couldn’t keep a record of this transcription in the meeting folder: \(error.localizedDescription)"
                ))
                AppLog.error("meeting-transcript", "\(folder.lastPathComponent): attempt not recorded: \(error.localizedDescription)")
                return (outcome, true)
            }
            var attempt = record.attempt
            let outcome: Outcome
            do {
                // Progress updates are awaited in order, so all of them land
                // before the outcome; no stale update can follow it.
                let report = try await transcriber.transcribe(inspected, choice: choice) { step in
                    await self.show(step)
                }
                if let transcript = report.transcript {
                    outcome = report.interruption.map { Outcome.cutShort(transcript, reason: $0) }
                        ?? .saved(transcript)
                } else {
                    outcome = .noSpeech(folder: folder)
                }
                attempt.finish(report, folder: inspected)
                AppLog.info("meeting-transcript", "done \(folder.lastPathComponent) in "
                    + "\(started.duration(to: .now)): \(report.tracks), echo removed \(report.echoRemoved)")
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // Stopped on purpose, from the menu or by quitting: not an
                    // error, and not an attempt to remember.
                    let outcome = Outcome.cancelled(folder: folder)
                    AppLog.info("meeting-transcript", "\(folder.lastPathComponent): \(outcome)")
                    do {
                        try FileManager.default.removeItem(at: record.url)
                    } catch {
                        AppLog.error("meeting-transcript", "attempt record stays in progress: \(error.localizedDescription)")
                    }
                    return (outcome, false)
                }
                outcome = .failed(folder: folder, reason: error.localizedDescription)
                attempt.fail(error.localizedDescription)
                AppLog.error("meeting-transcript", "\(folder.lastPathComponent): \(outcome)")
            }
            do {
                try attempt.write(to: record.url)
                AppLog.info("meeting-transcript", "attempt \(attempt.number): \(attempt.result.rawValue)")
            } catch {
                // It stays in progress, which proves nothing either way.
                AppLog.error("meeting-transcript", "attempt result not recorded: \(error.localizedDescription)")
            }
            return (outcome, false)
        }
        transcription = task
        let (outcome, unrecorded) = await task.value
        if unrecorded { unrecordedOutcomes[key] = outcome }
        transcription = nil
        isTranscribing = false
        step = nil
        return outcome
    }

    /// One copy, right after the transcript is written; scans never copy, so
    /// a note the user renamed or deleted does not come back.
    private func copy(_ transcript: URL, of folder: URL) async {
        guard let target = destinations().transcripts else { return }
        let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
            Result { try MeetingStorage.copyTranscript(transcript, of: folder, into: target) }
        }.value
        switch result {
        case .success(let copy):
            issues[folder, default: Issues()].transcriptCopy = nil
            AppLog.info("meeting-storage", "transcript copied: \(copy.path)")
        case .failure(let error):
            issues[folder, default: Issues()].transcriptCopy = error.localizedDescription
            AppLog.error("meeting-storage", "transcript not copied: \(error.localizedDescription)")
        }
    }

    private func compress(_ folder: URL) async {
        let started = ContinuousClock.now
        let result = await Task.detached(priority: .utility) { [self] in
            await MeetingStorage.compress(folder) { track in await self.show(.compressing(track: track)) }
        }.value
        issues[folder, default: Issues()].compression = result.issues
        if !result.compressed.isEmpty || !result.issues.isEmpty {
            AppLog.info("meeting-storage", "\(folder.lastPathComponent): compressed \(result.compressed), "
                + "kept \(result.issues.count) in \(started.duration(to: .now))")
        }
    }

    /// Only with a meetings folder chosen; checked on its own thread, since a
    /// dead network volume hangs whatever touches it.
    private func move(_ folder: URL) async {
        guard let target = destinations().meetings else {
            issues[folder]?.move = nil
            return
        }
        // The folder itself, local, read here, and the destination as the
        // meetings folder holds it (there or not), read off the main actor
        // before anything touches it. A write of the folder's marks under
        // way goes first; then, in one turn of the main actor, the folder is
        // read again and both the source and the destination are taken:
        // neither may be another operation's (a deletion of a copy left
        // there by an earlier move above all). A folder that is not the one
        // waited for, or unreadable, is not moved this time; the next scan
        // finds it as what it is.
        guard let identity = FolderIdentity.of(folder), let source = MeetingStorage.address(of: folder) else {
            AppLog.error("meeting-storage", "\(folder.lastPathComponent) can’t be read; not moved")
            return
        }
        let destinationFolder = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        guard let destination = await Task.detached(priority: .utility, operation: {
            MeetingStorage.address(of: destinationFolder)
        }).value else {
            issues[folder, default: Issues()].move = MeetingStorage.DeliveryFailure.unavailable(target.path).localizedDescription
            AppLog.error("meeting-storage", "\(folder.lastPathComponent) stays here: the meetings folder can’t be resolved")
            return
        }
        // Neither a write of its marks nor an open of its audio, at either
        // end, may be under way as the move takes them.
        let ends = Set([identity] + [destination.identity].compactMap { $0 })
        while marksBeingWritten(identity) || audioOpening(ends) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard FolderIdentity.of(folder) == identity else {
            AppLog.error("meeting-storage", "\(folder.lastPathComponent) changed while its marks were written; not moved")
            return
        }
        guard let taken = beginOperations(.moving, on: [source, destination]) else {
            AppLog.info("meeting-storage", "\(folder.lastPathComponent) or its place in the meetings folder is busy; not moved this time")
            return
        }
        defer { endOperations(taken) }
        show(.moving)
        let root = meetingsRoot
        let started = ContinuousClock.now
        let mover = self.mover
        let (result, placeAddress) = await Task.detached(priority: .utility) { () -> (Result<URL, Error>, MeetingStorage.Address?) in
            // The destination found before the waits is still the one there,
            // by its whole address: the same path, and the same folder or
            // none, proven.
            guard MeetingStorage.address(of: destinationFolder) == destination else {
                return (.failure(MeetingStorage.DeliveryFailure.conflict(folder.lastPathComponent)), nil)
            }
            let result = Result { try mover(folder, target, root) }
            return (result, (try? result.get()).flatMap(MeetingStorage.address(of:)))
        }.value
        switch result {
        case .success(let place):
            issues[folder]?.move = nil
            movedTo[folder.standardizedFileURL.path] = place
            // The jobs of this meeting now name its new place, so a request
            // for that place finds them. Only after a move of our own: no
            // path is resolved here, and a folder made anew at the old
            // address is another meeting.
            // So do their identities: the folder there is another one.
            // Unknown, it is read again and holds deletions back meanwhile.
            let local = folder.standardizedFileURL
            for index in pending.indices where pending[index].folder == local {
                pending[index].folder = place.standardizedFileURL
                pending[index].identity = placeAddress?.identity
            }
            if placeAddress?.identity == nil, pending.contains(where: { $0.folder == place.standardizedFileURL }) {
                tell(place.standardizedFileURL)
            }
            if activeJob?.folder == local {
                activeJob?.folder = place.standardizedFileURL
                activeJob?.identity = placeAddress?.identity
                activeAddress = placeAddress
            }
            if let outcome = unrecordedOutcomes.removeValue(forKey: local.path) {
                unrecordedOutcomes[place.standardizedFileURL.path] = outcome
            }
            AppLog.info("meeting-storage", "moved \(folder.lastPathComponent) → \(place.path) "
                + "in \(started.duration(to: .now))")
        case .failure(let error):
            issues[folder, default: Issues()].move = error.localizedDescription
            AppLog.error("meeting-storage", "\(folder.lastPathComponent) stays here: \(error.localizedDescription)")
        }
    }

    /// Compression and the move touch only folders directly in the local
    /// root; a folder chosen anywhere else is only transcribed. By the path
    /// alone, see `meetingsRootPaths`.
    func isInMeetingsRoot(_ folder: URL) -> Bool {
        meetingsRootPaths.contains(folder.deletingLastPathComponent().standardizedFileURL.path)
    }

    // MARK: - Old audio

    /// The audio rule as the settings have it: days (0 keeps) and its
    /// generation. Set by the app.
    var audioRetention: @MainActor () -> (days: Int, generation: Int) = { (0, 0) }
    /// Writes the audio rule once the user agreed; set by the app.
    var writeAudioRetention: @MainActor (Int) -> Void = { _ in }
    /// The rule's clock; tests stand in for it.
    var now: @Sendable () -> Date = { Date() }

    /// One meeting whose audio the rule takes now, as counted: its folder,
    /// the folder itself, and the size of what goes.
    struct AudioCandidate: Equatable, Sendable {
        let folder: URL
        let identity: FolderIdentity
        let bytes: Int64
    }

    /// What the rule takes now. Not complete when anything could not be
    /// counted: a root away, not answering or unreadable, a meeting whose
    /// facts cannot be read. Only a complete count of nothing proves nothing goes.
    struct AudioCount: Equatable, Sendable {
        var candidates: [AudioCandidate] = []
        var complete = true
    }

    /// What a choice of the audio rule would delete now, for its question.
    struct AudioQuestion: Identifiable, Equatable {
        let id: Int
        let days: Int
        /// The meetings whose audio goes now, each by itself: a yes takes
        /// these and no other, wherever the rule finds them.
        let candidates: [AudioCandidate]
        /// False when something could not be counted: it goes by the rule
        /// later, uncounted.
        let complete: Bool
        /// The rule's generation the count was made under: a yes under
        /// another (the meetings folder changed meanwhile) counts again.
        let generation: Int

        var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    }

    /// The question asked now, once counted.
    @Published private(set) var audioQuestion: AudioQuestion?
    /// The days of a rule being counted for its question.
    @Published private(set) var countingAudioRule: Int?
    private var audioQuestionsAsked = 0
    private var retentionTimer: Timer?
    /// Roots still being counted, a dead network volume's above all: not
    /// counted again until that count ends.
    private var countingRoots: Set<String> = []
    private let audioWork = DispatchQueue(label: "meeting-audio-removal", qos: .utility)
    /// How one root is counted for the rule; a test holds it.
    var countAudio: @Sendable (_ root: URL, _ local: Bool, _ days: Int, _ now: Date) -> AudioCount = {
        MeetingTranscriptionQueue.due(in: $0, local: $1, days: $2, now: $3)
    }

    /// Counts what keeping audio `days` would delete now; the question comes
    /// once counted, unless asked anew or answered meanwhile. Keeping deletes
    /// nothing and is written at once.
    func askAudioRetention(days: Int) {
        audioQuestionsAsked += 1
        let asked = audioQuestionsAsked
        audioQuestion = nil
        guard days > 0 else {
            countingAudioRule = nil
            writeAudioRetention(0)
            return
        }
        countingAudioRule = days
        let generation = audioRetention().generation
        Task {
            let due = await dueAudio(days: days, waitingAtMost: .seconds(3))
            guard asked == audioQuestionsAsked else { return }
            // Counted while the meetings folder or the rule changed: not
            // what goes now.
            guard audioRetention().generation == generation else {
                askAudioRetention(days: days)
                return
            }
            countingAudioRule = nil
            audioQuestion = AudioQuestion(
                id: asked, days: days, candidates: due.candidates, complete: due.complete, generation: generation
            )
        }
    }

    /// The answer. The rule is written only on yes, and its first pass
    /// deletes no more than the question showed; the daily pass starts
    /// counting from now. A count still under way is dropped either way.
    func answerAudioQuestion(_ question: AudioQuestion, accepted: Bool) {
        audioQuestionsAsked += 1
        audioQuestion = nil
        countingAudioRule = nil
        guard accepted else { return }
        // The meetings folder or the rule changed since the count: what the
        // question showed may not be what goes. Counted and asked again.
        guard audioRetention().generation == question.generation else {
            AppLog.info("meeting-storage", "audio rule not set: counted under another generation; counting again")
            askAudioRetention(days: question.days)
            return
        }
        writeAudioRetention(question.days)
        restartRetentionTimer()
        pruneAudio(only: question.candidates)
    }

    /// Cancel while counting, or on the question: nothing changes, and a
    /// count still under way asks nothing.
    func cancelAudioQuestion() {
        audioQuestionsAsked += 1
        audioQuestion = nil
        countingAudioRule = nil
    }

    /// Finds the meetings whose audio the rule takes now and queues each,
    /// with the folder itself as counted; `only`: the first pass after the
    /// user agreed, which takes those very meetings and no folder put at
    /// their address since. A pass that began under another rule or
    /// meetings folder queues nothing.
    func pruneAudio(only: [AudioCandidate]? = nil) {
        let (days, generation) = audioRetention()
        guard days > 0 else { return }
        let agreed = only.map { Set($0.map(\.identity)) }
        Task {
            let due = await dueAudio(days: days, waitingAtMost: nil)
            guard audioRetention().generation == generation else {
                AppLog.info("meeting-storage", "audio pass dropped: the rule or the meetings folder changed")
                return
            }
            for candidate in due.candidates.sorted(by: { $0.folder.path < $1.folder.path })
            where agreed?.contains(candidate.identity) ?? true {
                enqueueAudioRemoval(candidate, generation: generation)
            }
        }
    }

    private func enqueueAudioRemoval(_ candidate: AudioCandidate, generation: Int) {
        let folder = candidate.folder.standardizedFileURL
        let address = isInMeetingsRoot(folder)
            ? MeetingStorage.address(of: folder) : MeetingStorage.Address(identity: candidate.identity, path: folder.path)
        if let address, operations.contains(where: { $0.kind == .removing && $0.address.isSameFolder(as: address) }) { return }
        let removal = AudioRemoval(generation: generation, identity: candidate.identity)
        if let index = pending.firstIndex(where: { $0.folder == folder || $0.identity == candidate.identity }) {
            pending[index].removesAudio = removal
            return
        }
        pending.append(Job(folder: folder, transcribe: false, identity: candidate.identity, removesAudio: removal))
        startNextIfIdle()
    }

    /// The meetings in the local root and the meetings folder whose audio the
    /// rule takes now, each root read on a thread of its own. A root still
    /// being counted from before, away, or not answering within
    /// `waitingAtMost` is not counted, and the answer says so.
    private func dueAudio(days: Int, waitingAtMost limit: Duration?) async -> AudioCount {
        var count = AudioCount()
        let now = self.now()
        let countAudio = self.countAudio
        for root in [meetingsRoot] + [destinations().meetings].compactMap({ $0 }) {
            let path = root.standardizedFileURL.path
            guard !countingRoots.contains(path) else {
                count.complete = false
                continue
            }
            countingRoots.insert(path)
            let local = root == meetingsRoot
            let found: AudioCount? = await withCheckedContinuation { continuation in
                let answered = Once()
                DispatchQueue(label: "meeting-audio-count \(path)", qos: .utility).async { [weak self] in
                    let counted = countAudio(root, local, days, now)
                    if answered.claim() { continuation.resume(returning: counted) }
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.countingRoots.remove(path) } }
                }
                if let limit {
                    let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                        if answered.claim() { continuation.resume(returning: .none) }
                    }
                }
            }
            guard let found else {
                count.complete = false
                continue
            }
            // One folder reached through both roots is one meeting.
            count.candidates += found.candidates.filter { new in !count.candidates.contains { $0.identity == new.identity } }
            if !found.complete { count.complete = false }
        }
        return count
    }

    /// A meetings folder that is away is not read at all; a root that
    /// cannot be listed, or a meeting whose facts cannot be read, leaves the
    /// count incomplete: it may hold audio the rule takes once it can be read.
    nonisolated static func due(in root: URL, local: Bool, days: Int, now: Date) -> AudioCount {
        guard local || MeetingStorage.isAvailable(root), let folders = try? MeetingStorage.meetingFolders(in: root) else {
            return AudioCount(complete: false)
        }
        var count = AudioCount()
        for folder in folders {
            let rule = MeetingStorage.audioRetention(of: folder)
            if case .unknown = rule {
                count.complete = false
                continue
            }
            guard let files = rule.due(days: days, now: now) else { continue }
            guard let identity = FolderIdentity.of(folder) else {
                count.complete = false
                continue
            }
            count.candidates.append(AudioCandidate(folder: folder, identity: identity, bytes: files.reduce(0) { $0 + $1.bytes }))
        }
        return count
    }

    /// Once a day while the app runs, and as it starts.
    private func restartRetentionTimer() {
        retentionTimer?.invalidate()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneAudio() }
        }
    }

    /// The rule's step of a job, for the meeting that was counted and no
    /// other folder at its address. Every transcription that is or may be of
    /// the meeting (one whose folder is not told yet may be any) goes first:
    /// the last of them takes the step over, looks at what they all left,
    /// and, being another folder after all, keeps the audio this time. The
    /// folder is taken for the step, so its marks are refused meanwhile;
    /// every file is admitted again, from the disk, right before it goes for
    /// good, and the rule's generation is checked inside that last call,
    /// after its last read of the disk.
    private func removeOldAudio(_ folder: URL, removal: AudioRemoval) async {
        let generation = removal.generation
        if let reason = stillWanted(generation) {
            AppLog.info("meeting-storage", "\(folder.lastPathComponent): old audio kept: \(reason)")
            return
        }
        guard let address = activeAddress, let identity = address.identity else {
            AppLog.info("meeting-storage", "\(folder.lastPathComponent): old audio kept: the folder can’t be read")
            return
        }
        guard identity == removal.identity else {
            AppLog.info("meeting-storage", "\(folder.lastPathComponent): old audio kept: another folder is at its address")
            return
        }
        let path = folder.standardizedFileURL.path
        let waiting = pending.indices.filter { index in
            pending[index].transcribe && (pending[index].identity == identity || pending[index].identity == nil
                || pending[index].folder.standardizedFileURL.path == path)
        }
        if let last = waiting.last {
            pending[last].removesAudio = removal
            AppLog.info("meeting-storage", "\(folder.lastPathComponent): old audio waits for the transcriptions asked for it")
            return
        }
        guard !marksBeingWritten(identity), let taken = beginOperations(.removingAudio, on: [address]) else {
            AppLog.info("meeting-storage", "\(folder.lastPathComponent): old audio kept this time: the folder is busy")
            return
        }
        defer { endOperations(taken) }
        show(.removingAudio)
        let removal = self.removal
        let now = self.now
        let days = audioRetention().days
        let check: @Sendable () -> String? = { [weak self] in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self else { return "the queue is gone" }
                    return self.stillWanted(generation, identity: identity)
                }
            }
        }
        let summary = await withCheckedContinuation { continuation in
            audioWork.async {
                continuation.resume(returning: Self.removeAudio(
                    in: folder, identity: identity, days: days, now: now, removal: removal, stillWanted: check
                ))
            }
        }
        AppLog.info("meeting-storage", "\(folder.lastPathComponent): old audio: \(summary)")
    }

    /// Why a deletion of old audio asked for under `generation` does not go
    /// on now, or nil.
    private func stillWanted(_ generation: Int, identity: FolderIdentity? = nil) -> String? {
        let (days, current) = audioRetention()
        if days == 0 { return "the audio is kept now" }
        if current != generation { return "the audio rule or the meetings folder changed" }
        if let identity, marksBeingWritten(identity) { return "a star or a name is being saved" }
        if let identity, pending.contains(where: { $0.transcribe && ($0.identity == identity || $0.identity == nil) }) {
            return "a transcription was asked for meanwhile"
        }
        return nil
    }

    /// Off the main actor. The files the rule takes, each admitted again
    /// right before it goes; the first that is not stops the rest.
    private nonisolated static func removeAudio(
        in folder: URL,
        identity: FolderIdentity,
        days: Int,
        now: @Sendable () -> Date,
        removal: MeetingStorage.Removal,
        stillWanted: @escaping @Sendable () -> String?
    ) -> String {
        guard let files = MeetingStorage.audioRetention(of: folder).due(days: days, now: now()) else {
            return "not due: \(MeetingStorage.audioRetention(of: folder))"
        }
        var removed: [String] = []
        for file in files {
            let rule = MeetingStorage.audioRetention(of: folder)
            guard let again = rule.due(days: days, now: now()), again.contains(file) else {
                return "stopped before \(file.name) (\(rule)); removed \(removed)"
            }
            switch removal.perform(.file(file), in: folder, folderIdentity: identity, forGood: true, stillWanted: stillWanted) {
            case .success: removed.append(file.name)
            case .failure(let failure): return "stopped at \(file.name): \(failure); removed \(removed)"
            }
        }
        return "removed \(removed)"
    }

    // MARK: - Operations

    /// The operation on this folder, if any, by the folder itself.
    func operation(on identity: FolderIdentity?) -> Operation? {
        guard let identity else { return nil }
        return operations.first { $0.address.identity == identity }
    }

    /// Takes these folders for one kind of work if none of them is another
    /// operation's; nil otherwise. On the main actor, in the caller's turn.
    func beginOperations(_ kind: Operation.Kind, on addresses: [MeetingStorage.Address]) -> [Int]? {
        guard !addresses.contains(where: { address in operations.contains { $0.address.isSameFolder(as: address) } }) else {
            return nil
        }
        // Nothing keeps a file of theirs open while they move or go: files
        // being opened can't be closed from here, so not now; open ones are
        // closed in this turn.
        guard !audioOpening(Set(addresses.compactMap(\.identity))) else { return nil }
        releaseAudio(addresses, kind)
        let taken = addresses.map { address -> Operation in
            operationsStarted += 1
            return Operation(id: operationsStarted, kind: kind, address: address)
        }
        operations += taken
        return taken.map(\.id)
    }

    func endOperations(_ ids: [Int]) {
        operations.removeAll { ids.contains($0.id) }
    }

    /// The window's deletion of a folder: refused while anything else is
    /// done to it or waits to transcribe it; otherwise the upkeep waiting for
    /// it is dropped and the folder is taken until `endOperations`. In one
    /// turn of the main actor; the address was read before, off it.
    func reserve(_ address: MeetingStorage.Address, folder: URL) -> Result<Int, ReserveRefusal> {
        let path = folder.standardizedFileURL.path
        func isThis(_ job: Job) -> Bool {
            job.folder.standardizedFileURL.path == path || job.identity != nil && job.identity == address.identity
        }
        if currentRecording()?.standardizedFileURL.path == path
            || address.identity != nil && currentRecordingIdentity() == address.identity {
            return .failure(ReserveRefusal(reason: String(localized: "The meeting is being recorded.")))
        }
        if let busy = operations.first(where: { $0.address.isSameFolder(as: address) }) {
            return .failure(ReserveRefusal(reason: Self.describe(busy.kind)))
        }
        if let job = activeJob, activeAddress.map({ $0.isSameFolder(as: address) }) ?? isThis(job) {
            return .failure(ReserveRefusal(reason: String(localized: "The meeting is being processed: \(stepLabel ?? "")")))
        }
        if pending.contains(where: { $0.transcribe && isThis($0) }) {
            return .failure(ReserveRefusal(reason: String(localized: "The meeting is waiting to be transcribed.")))
        }
        if let reason = untoldTranscription { return .failure(ReserveRefusal(reason: reason)) }
        if let identity = address.identity, audioOpening([identity]) {
            return .failure(ReserveRefusal(reason: String(localized: "The meeting’s audio is being opened: try again in a moment.")))
        }
        guard let taken = beginOperations(.removing, on: [address]) else {
            return .failure(ReserveRefusal(reason: Self.describe(.removing)))
        }
        let dropped = pending.filter { !$0.transcribe && isThis($0) }.count
        pending.removeAll { !$0.transcribe && isThis($0) }
        if dropped > 0 { AppLog.info("meeting-storage", "\(folder.lastPathComponent): \(dropped) waiting jobs dropped for its deletion") }
        removalEpoch += 1
        return .success(taken[0])
    }

    /// A transcription waits whose folder is not known by itself yet (being
    /// read, or unreadable): it may be any folder, so no deletion goes until
    /// it is told.
    var untoldTranscription: String? {
        pending.contains { $0.transcribe && $0.identity == nil }
            ? String(localized: "A meeting waiting to be transcribed can’t be told apart yet: try again in a moment.") : nil
    }

    /// Reads a waiting job's folder off the main actor, for jobs that do not
    /// know it yet. Unknown stays unknown: that job then holds deletions
    /// back until it runs, and drops itself.
    private func tell(_ folder: URL) {
        Task {
            let address = await Task.detached(priority: .utility) { MeetingStorage.address(of: folder) }.value
            guard let identity = address?.identity else { return }
            for index in pending.indices where pending[index].folder == folder && pending[index].identity == nil {
                pending[index].identity = identity
            }
        }
    }

    struct ReserveRefusal: Error, Equatable {
        let reason: String
    }

    /// What the window says of a folder under an operation.
    static func describe(_ kind: Operation.Kind) -> String {
        switch kind {
        case .moving: String(localized: "Moving the meeting to the meetings folder…")
        case .removing: String(localized: "Deleting the meeting…")
        case .removingAudio: String(localized: "Deleting the meeting’s old audio…")
        }
    }

    /// A meeting deleted by the window: the menu's last outcome and what
    /// this run kept about the folder go, so nothing points to it.
    func forget(_ folder: URL, wholeMeeting: Bool) {
        let path = folder.standardizedFileURL.path
        let addresses = Set([path] + movedTo.filter { $0.value.standardizedFileURL.path == path }.map(\.key))
        for key in issues.keys where addresses.contains(key.standardizedFileURL.path) {
            if wholeMeeting { issues[key] = nil } else { issues[key]?.compression = [] }
        }
        guard wholeMeeting else { return }
        for key in addresses { unrecordedOutcomes[key] = nil }
        if lastMeeting?.standardizedFileURL.path == path { lastOutcome = nil }
    }

    /// Where a folder is now. Only one in the local root can have moved, and
    /// only then is the disk asked, there; any other is where it was chosen.
    /// A move made in this run is known exactly; for an older one the current
    /// meetings folder is the best guess.
    func location(of folder: URL) -> URL {
        guard isInMeetingsRoot(folder) else { return folder }
        if let place = movedTo[folder.standardizedFileURL.path],
           !FileManager.default.fileExists(atPath: folder.path) {
            return place
        }
        return RecordingsStore.currentLocation(of: folder, meetingsFolder: destinations().meetings)
    }

    private func show(_ step: MeetingTranscriber.Step) {
        self.step = step
    }

    private func finish(_ folder: URL) {
        if issues[folder]?.lines.isEmpty == true { issues[folder] = nil }
        job = nil
        activeJob = nil
        activeAddress = nil
        activeFolder = nil
        step = nil
        finishedJobs += 1
        startNextIfIdle()
    }
}

/// Below the folders in the panel, and in the window's Transcribe Again
/// sheet: this transcription's engine and language, and the chosen engine's
/// model to download when it is missing. Both engines stay choosable;
/// Transcribe waits until the model is there.
struct TranscriptionChoiceView: View {
    @ObservedObject var draft: MeetingTranscriptionQueue.ChoiceDraft
    @ObservedObject var models: ModelDownloader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Engine", selection: $draft.engine) {
                ForEach(DictationEngine.allCases, id: \.self) { engine in
                    Text(models.missing(engine).isEmpty ? engine.title : String(localized: "\(engine.title) · not downloaded"))
                        .tag(engine)
                }
            }
            .accessibilityIdentifier("transcriptionEnginePicker")
            Picker("Language", selection: $draft.shownLanguage) {
                Text("Auto").tag("auto")
                Divider()
                ForEach(draft.engine.languageChoices, id: \.code) { choice in
                    Text(choice.name).tag(choice.code)
                }
            }
            .accessibilityIdentifier("transcriptionLanguagePicker")
            Text("For this transcription only — your settings stay as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The panel sizes its accessory once, as it opens, and keeps
            // that size: the model's place always holds its tallest state,
            // the button over two lines of a failure, so whatever comes
            // after the panel opened is shown whole. When nothing is
            // missing it is room at the bottom.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Button(String(" ")) {}
                    Text(verbatim: " \n ").font(.caption)
                }
                .hidden()
                .accessibilityHidden(true)
                modelRow
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 460, alignment: .leading)
    }

    @ViewBuilder private var modelRow: some View {
        let missing = models.missing(draft.engine)
        // One download at a time: while any runs, it is shown instead.
        if let download = models.download {
            Text("\(download.engine.modelName) · downloading \(download.progressText)")
                .font(.caption)
                .lineLimit(2)
        } else if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button("Download Model \(draft.engine.modelName) (\(ModelDownloader.sizeText(missing.reduce(0) { $0 + $1.bytes })))…") {
                    models.start(draft.engine)
                }
                .accessibilityIdentifier("transcriptionDownloadButton")
                if let failure = models.failure, failure.engine == draft.engine {
                    // A longer reason, a folder's path in it, ends in the tooltip.
                    Text("Download failed: \(failure.message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(failure.message)
                }
            }
        }
    }
}
