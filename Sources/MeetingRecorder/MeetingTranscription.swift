import Accelerate
import AppKit
import AVFoundation
import CoreML
import FluidAudio
import Foundation

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

    /// The engine one chunk goes to. Read again before every chunk: a job that
    /// kept its first choice would reload the model after each dictation once
    /// the user switched engines (the cache holds one engine).
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
        /// the model being prepared for one.
        case waitingForEngine
        /// Sent once the engine is ready, while chunk `done` is recognized.
        case recognizing(track: String, done: Int, total: Int)
        case compressing(track: String)
        case moving
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
    let loadSpeechDetector: @Sendable () async throws -> SpeechDetector
    let currentEngine: @Sendable () async throws -> Engine
    var temporaryRoot = FileManager.default.temporaryDirectory

    func transcribe(
        _ folder: Folder,
        report progress: @Sendable (Step) async -> Void
    ) async throws -> Report {
        Self.removeStaleTemporaryFiles(in: folder.directory)
        // Before any conversion: a missing model must fail the job at once.
        let detect = try await loadSpeechDetector()
        let work = temporaryRoot.appendingPathComponent(
            "Murmurly-meeting-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var report = Report()
        let tracks: [(URL?, Float, String, String, WritableKeyPath<Report, [Utterance]>)] = [
            (folder.microphone, folder.microphoneGain, Self.microphoneSpeaker, String(localized: "microphone"), \.microphone),
            (folder.system, folder.systemGain, Self.systemSpeaker, String(localized: "others"), \.system),
        ]
        do {
            for case let (url?, gain, speaker, name, list) in tracks {
                try await transcribeTrack(
                    url, gain: gain, speaker: speaker, name: name, into: list, work: work,
                    detect: detect, report: &report, progress: progress
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
        report.lines = Self.merged(echo.kept + report.system)
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
        report.transcript = try Self.write(markdown, into: folder.directory)
        return report
    }

    /// One file from the Files tab: the meeting pipeline on a single track,
    /// with the engine the dictation uses, timecodes and cancellation included.
    /// Unlike `transcribe(_:)` it leaves the file's folder alone — that is the
    /// user's own folder, so nothing is cleaned or written next to the file;
    /// the work chunks live in the temporary folder only.
    func transcribeFile(
        _ url: URL,
        report progress: @Sendable (Step) async -> Void
    ) async throws -> [Utterance] {
        let detect = try await loadSpeechDetector()
        let work = temporaryRoot.appendingPathComponent(
            "Murmurly-file-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var report = Report()
        do {
            try await transcribeTrack(
                url, gain: 1, speaker: "", name: String(localized: "file"), into: \.system, work: work,
                detect: detect, report: &report, progress: progress
            )
        } catch {
            // As with a meeting, a break keeps what was recognized; the user's
            // cancel is still a cancel.
            if Task.isCancelled || error is CancellationError || report.system.isEmpty { throw error }
            AppLog.error("run", "cut short at \(report.position): \(error.localizedDescription)")
            throw Failure.fileCutShort(
                lines: Self.merged(report.system), position: report.position, reason: error.localizedDescription
            )
        }
        let failed = report.tracks.reduce(0) { $0 + $1.failedChunks }
        let reason = report.lastChunkFailure ?? ""
        if failed > 0 {
            if report.system.isEmpty { throw Failure.nothingRecognized(failed: failed, reason: reason) }
            throw Failure.incompleteFile(lines: Self.merged(report.system), failedChunks: failed, reason: reason)
        }
        return Self.merged(report.system)
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

            let engine = try await currentEngine()
            if !report.engines.contains(engine.label) { report.engines.append(engine.label) }
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
    static func live(
        settings: SettingsStore,
        models: ModelDownloader,
        cache: WhisperKitCache = .shared
    ) -> MeetingTranscriber {
        MeetingTranscriber(
            cache: cache,
            // Checked first, before any conversion: the recording is kept, and
            // the job says how to get the model and come back to it.
            loadSpeechDetector: {
                try await MainActor.run {
                    guard models.missing(settings.dictationEngine).isEmpty else {
                        throw Failure.modelNotDownloaded
                    }
                }
                return try await sileroDetector(
                    modelPath: models.root.appendingPathComponent(ModelSource.vad.destination).path
                )
            },
            currentEngine: {
                try await MainActor.run { try Engine.forMeeting(settings.snapshot) }
            }
        )
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
    /// The dictation's engine and language. On "auto" Whisper's language is
    /// fixed during the job (`languageFixSeconds`).
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
        let folder: URL
        var transcribe: Bool
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
    /// Counts finished jobs, so a view showing sizes knows to read them again.
    @Published private(set) var finishedJobs = 0
    /// Set by the recorder. Scans, compression and moves wait while it
    /// records, starts or stops: the stop writes `metadata.json` before the
    /// recorder rewrites it, and a folder being recorded has none yet.
    var isRecorderBusy: @MainActor () -> Bool = { false }
    private let transcriber: MeetingTranscriber
    private let meetingsRoot: URL
    /// The local root's path as given and with its links resolved, read once.
    /// A folder is matched against them by its path alone: one chosen by hand
    /// may be on a network volume, and touching a dead one hangs the main actor.
    private let meetingsRootPaths: Set<String>
    private let destinations: @MainActor () -> Destinations
    private let fileViewer: @MainActor (URL) -> Void
    private var job: Task<Void, Never>?
    private var transcription: Task<Outcome, Never>?
    private var mountObserver: NSObjectProtocol?
    /// Where this run's moves put each folder, by its local path. The folder
    /// setting may change or reset afterwards; the meeting stays where it went.
    private var movedTo: [String: URL] = [:]

    init(
        transcriber: MeetingTranscriber,
        meetingsRoot: URL = RecordingsStore.meetingsRoot(),
        destinations: @escaping @MainActor () -> Destinations = { Destinations() },
        fileViewer: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.transcriber = transcriber
        self.meetingsRoot = meetingsRoot
        meetingsRootPaths = [meetingsRoot.standardizedFileURL.path, meetingsRoot.resolvingSymlinksInPath().path]
        self.destinations = destinations
        self.fileViewer = fileViewer
    }

    /// Once, from the recorder's activation: the launch scan, and a scan
    /// whenever a volume appears, since the meetings folder may be on it.
    func activate() {
        guard mountObserver == nil else { return }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanLocalFolders() }
        }
        scanLocalFolders()
    }

    /// A folder already waiting is not queued twice, but a transcription asked
    /// for later is kept even when a scan queued the folder first.
    func enqueue(_ directory: URL, transcribe: Bool = true) {
        let folder = directory.standardizedFileURL
        if let index = pending.firstIndex(where: { $0.folder == folder }) {
            if transcribe, !pending[index].transcribe { pending[index].transcribe = true }
            AppLog.info("meeting-transcript", "already queued: \(folder.lastPathComponent)")
            return
        }
        if let activeJob, activeJob.folder == folder, activeJob.transcribe || !transcribe {
            AppLog.info("meeting-transcript", "already queued: \(folder.lastPathComponent)")
            return
        }
        pending.append(Job(folder: folder, transcribe: transcribe))
        startNextIfIdle()
    }

    /// Queues, without transcription, every finished local folder that still
    /// has work: a CAF track, or a move when the meetings folder is available.
    func scanLocalFolders() {
        let root = meetingsRoot
        let target = destinations().meetings
        Task { [self] in
            let folders = await Task.detached(priority: .utility) {
                MeetingStorage.foldersNeedingWork(in: root, moving: target.map { MeetingStorage.isAvailable($0) } ?? false)
            }.value
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

    func chooseFolder() {
        AppWindowController.chooseFolder(
            message: String(localized: "Choose a meeting folder"),
            prompt: String(localized: "Transcribe"),
            directory: panelDirectory
        ) { [weak self] url in
            self?.enqueue(url)
        }
    }

    func revealOutcome() {
        switch lastOutcome {
        case .saved(let url), .cutShort(let url, _):
            fileViewer(location(of: url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent))
        case .noSpeech(let folder), .failed(let folder, _), .cancelled(let folder):
            fileViewer(location(of: folder))
        case nil:
            break
        }
    }

    func dismissOutcome() {
        lastOutcome = nil
    }

    var statusLabel: String? {
        guard activeFolder != nil else { return nil }
        let queued = pending.isEmpty ? "" : " · " + String(localized: "\(pending.count) more in the queue")
        switch step {
        case nil:
            return (isTranscribing
                ? String(localized: "Transcribing the meeting…") : String(localized: "Processing the meeting…")) + queued
        case .reading(let track)?:
            return String(localized: "Transcribing the meeting: reading the audio (\(track))…") + queued
        case .detecting(let track)?:
            return String(localized: "Transcribing the meeting: looking for speech (\(track))…") + queued
        case .preparingModel?:
            return String(localized: "Transcribing the meeting: preparing the model…") + queued
        case .waitingForEngine?:
            return String(localized: "Transcribing the meeting: waiting for the engine…") + queued
        case .recognizing(let track, let done, let total)?:
            return String(localized: "Transcribing the meeting: \(track), \(done) of \(total)") + queued
        case .compressing(let track)?:
            return String(localized: "Compressing the meeting: \(track)…") + queued
        case .moving?:
            return String(localized: "Moving the meeting to the meetings folder…") + queued
        }
    }

    private func startNextIfIdle() {
        guard job == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        activeJob = next
        activeFolder = next.folder
        step = nil
        job = Task { [self] in
            // A folder queued before an earlier job moved it is found there.
            let folder = location(of: next.folder)
            if next.transcribe {
                let outcome = await transcribe(folder)
                lastOutcome = outcome
                if let transcript = outcome.transcript { await copy(transcript, of: folder) }
            }
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
    private func transcribe(_ folder: URL) async -> Outcome {
        isTranscribing = true
        step = nil
        AppLog.info("meeting-transcript", "start \(folder.lastPathComponent)")
        let transcriber = self.transcriber
        let task = Task.detached(priority: .utility) { [self] () -> Outcome in
            let outcome: Outcome
            let started = ContinuousClock.now
            do {
                // Progress updates are awaited in order, so all of them land
                // before the outcome; no stale update can follow it.
                let report = try await transcriber.transcribe(.inspect(folder)) { step in
                    await self.show(step)
                }
                if let transcript = report.transcript {
                    outcome = report.interruption.map { Outcome.cutShort(transcript, reason: $0) }
                        ?? .saved(transcript)
                } else {
                    outcome = .noSpeech(folder: folder)
                }
                AppLog.info("meeting-transcript", "done \(folder.lastPathComponent) in "
                    + "\(started.duration(to: .now)): \(report.tracks), echo removed \(report.echoRemoved)")
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // Stopped on purpose, from the menu or by quitting: not an error.
                    outcome = .cancelled(folder: folder)
                    AppLog.info("meeting-transcript", "\(folder.lastPathComponent): \(outcome)")
                } else {
                    outcome = .failed(folder: folder, reason: error.localizedDescription)
                    AppLog.error("meeting-transcript", "\(folder.lastPathComponent): \(outcome)")
                }
            }
            return outcome
        }
        transcription = task
        let outcome = await task.value
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
        show(.moving)
        let root = meetingsRoot
        let started = ContinuousClock.now
        let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
            Result { try MeetingStorage.move(folder, into: target, localRoot: root) }
        }.value
        switch result {
        case .success(let place):
            issues[folder]?.move = nil
            movedTo[folder.standardizedFileURL.path] = place
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
    private func isInMeetingsRoot(_ folder: URL) -> Bool {
        meetingsRootPaths.contains(folder.deletingLastPathComponent().standardizedFileURL.path)
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
        activeFolder = nil
        step = nil
        finishedJobs += 1
        startNextIfIdle()
    }
}
