import Accelerate
import AVFoundation
import AudioToolbox
import Foundation

extension DictationHistoryStore {
    /// Archived as mono 24-bit ALAC at the source rate: lossless, so a saved
    /// dictation can be listened to without artifacts. Recognition alone would
    /// tolerate compressed audio; the larger archive is the accepted cost.
    static let dictationArchiveFormatID: AudioFormatID = kAudioFormatAppleLossless

    /// The audio reached the archive but its JSONL line did not. The copy is
    /// kept, so a retry indexes it instead of archiving under the same name.
    struct IndexWriteFailed: LocalizedError, Sendable {
        let audioPath: String
        let duration: TimeInterval
        let reason: String

        var errorDescription: String? { reason }
    }

    /// A retry found the earlier archived copy gone, e.g. cleared meanwhile.
    struct ArchivedAudioMissing: Error {}

    /// Why a dictation was kept as its source CAF instead of ALAC.
    enum ArchiveSampleError: LocalizedError {
        case outOfRange
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .outOfRange: String(localized: "peaks outside [-1, 1] or samples that are not numbers")
            case .unsupportedFormat: String(localized: "the sample format can’t be checked for ALAC")
            }
        }
    }

    /// Archives the audio and indexes it in one actor turn. There is no `await`
    /// here on purpose: `clearAll()` and `delete(id:)` can then only run before
    /// or after the whole save, never between the audio file and its JSONL line.
    /// `preserveSource` keeps a byte-identical CAF instead of converting it, for
    /// a possibly damaged fragment that conversion could degrade further.
    func saveDictation(
        from sourceURL: URL,
        id: UUID,
        at date: Date,
        preserveSource: Bool = false,
        saveAudio: Bool = true,
        makeEntry: @Sendable (_ audioPath: String, _ duration: TimeInterval) -> DictationHistoryEntry
    ) throws -> DictationHistoryEntry {
        if !saveAudio && !preserveSource {
            let entry = makeEntry("", audioDuration(at: sourceURL) ?? 0)
            try append(entry)
            return entry
        }
        let archived = try preserveSource
            ? preserveSourceCAF(from: sourceURL, id: id, at: date)
            : archiveAudio(from: sourceURL, id: id, at: date)
        let entry = makeEntry(archived.relativePath, archived.duration)
        do {
            try append(entry)
        } catch {
            // append may have written part of the line, so deleting the audio
            // could leave an index entry pointing at nothing. Keep the copy.
            AppLog.error(
                "dictation-history",
                "index append failed; archived audio kept at \(archived.relativePath): \(error.localizedDescription)"
            )
            throw IndexWriteFailed(
                audioPath: archived.relativePath,
                duration: archived.duration,
                reason: error.localizedDescription
            )
        }
        return entry
    }

    /// Writes only the line for audio that an earlier save already archived.
    /// The check and the append share one actor turn, so a clear in between
    /// cannot leave a line without its audio.
    func indexArchivedDictation(_ entry: DictationHistoryEntry) throws {
        guard audioURL(for: entry) != nil else { throw ArchivedAudioMissing() }
        do {
            try append(entry)
        } catch {
            throw IndexWriteFailed(
                audioPath: entry.audioPath,
                duration: entry.duration,
                reason: error.localizedDescription
            )
        }
    }

    func archiveAudio(
        from sourceURL: URL,
        id: UUID,
        at date: Date
    ) throws -> (relativePath: String, duration: TimeInterval, fileSize: Int64) {
        let destination = try ensurePrivateAudioDirectory(for: date)
        let duration = audioDuration(at: sourceURL) ?? 0
        let m4aURL = destination.directory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("m4a")

        try createPrivateEmptyFile(at: m4aURL)
        do {
            try Self.encodeAppleLossless(from: sourceURL, to: m4aURL)
            let size = try fileSize(at: m4aURL)
            guard size > 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: m4aURL.path])
            }
            return (
                "\(destination.relativePath)/\(m4aURL.lastPathComponent)",
                duration,
                size
            )
        } catch {
            try? FileManager.default.removeItem(at: m4aURL)
            AppLog.error(
                "dictation-history",
                "ALAC conversion failed; preserving source CAF: \(error.localizedDescription)"
            )
        }

        let cafURL = destination.directory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("caf")
        try createPrivateEmptyFile(at: cafURL)
        do {
            try copyContents(from: sourceURL, to: cafURL)
            return (
                "\(destination.relativePath)/\(cafURL.lastPathComponent)",
                duration,
                try fileSize(at: cafURL)
            )
        } catch {
            try? FileManager.default.removeItem(at: cafURL)
            throw error
        }
    }

    func preserveSourceCAF(
        from sourceURL: URL,
        id: UUID,
        at date: Date
    ) throws -> (relativePath: String, duration: TimeInterval, fileSize: Int64) {
        let destination = try ensurePrivateAudioDirectory(for: date)
        let cafURL = destination.directory
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("caf")
        try createPrivateEmptyFile(at: cafURL)
        do {
            try copyContents(from: sourceURL, to: cafURL)
            return (
                "\(destination.relativePath)/\(cafURL.lastPathComponent)",
                audioDuration(at: sourceURL) ?? 0,
                try fileSize(at: cafURL)
            )
        } catch {
            try? FileManager.default.removeItem(at: cafURL)
            throw error
        }
    }

    /// Shared with meeting compression, so it holds no actor state: a meeting
    /// track takes many seconds, and dictation saves must not wait behind it.
    /// Dictations keep the defaults (mono, unscaled). A meeting passes its
    /// source's channel count and the gain that brings its peak into [-1, 1].
    nonisolated static func encodeAppleLossless(
        from sourceURL: URL,
        to destinationURL: URL,
        gain: Float = 1,
        channels: UInt32 = 1
    ) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let sampleRate = source.fileFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }

        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: Self.dictationArchiveFormatID,
            mFormatFlags: kAppleLosslessFormatFlag_24BitSourceData,
            mBytesPerPacket: 0,
            mFramesPerPacket: 4_096,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkStatus(
            AudioFormatGetProperty(
                kAudioFormatProperty_FormatInfo,
                0,
                nil,
                &formatSize,
                &outputFormat
            ),
            path: destinationURL
        )

        var outputFile: ExtAudioFileRef?
        try checkStatus(
            ExtAudioFileCreateWithURL(
                destinationURL as CFURL,
                kAudioFileM4AType,
                &outputFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &outputFile
            ),
            path: destinationURL
        )
        guard let outputFile else { throw CocoaError(.fileWriteUnknown) }
        defer { ExtAudioFileDispose(outputFile) }

        var inputFormat = source.processingFormat.streamDescription.pointee
        try checkStatus(
            ExtAudioFileSetProperty(
                outputFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &inputFormat
            ),
            path: destinationURL
        )

        let frameCapacity: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: frameCapacity)
            guard buffer.frameLength > 0 else { break }
            if gain != 1 { try scale(buffer, by: gain) }
            try requireLosslessRange(buffer)
            try checkStatus(
                ExtAudioFileWrite(outputFile, buffer.frameLength, buffer.audioBufferList),
                path: destinationURL
            )
        }
    }

    /// 24-bit ALAC can only hold [-1, 1]; anything beyond, or not finite, would
    /// be clipped silently. Checked per block before the encoder sees it, so
    /// the caller falls back to keeping the source CAF byte-identical. A format
    /// this check cannot read takes the same fallback instead of skipping it.
    nonisolated static func requireLosslessRange(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            throw ArchiveSampleError.unsupportedFormat
        }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let pointers = buffer.format.isInterleaved ? 1 : channelCount
        let samplesPerPointer = buffer.format.isInterleaved ? frames * channelCount : frames
        for pointer in 0..<pointers {
            let samples = channels[pointer]
            for index in 0..<samplesPerPointer {
                let sample = samples[index]
                guard sample.isFinite, sample >= -1, sample <= 1 else {
                    throw ArchiveSampleError.outOfRange
                }
            }
        }
    }

    /// The same multiplication the meeting check repeats, so both sides of
    /// its comparison round alike.
    nonisolated static func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            throw ArchiveSampleError.unsupportedFormat
        }
        let pointers = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let count = buffer.format.isInterleaved
            ? Int(buffer.frameLength) * Int(buffer.format.channelCount)
            : Int(buffer.frameLength)
        var factor = gain
        for pointer in 0..<pointers {
            vDSP_vsmul(channels[pointer], 1, &factor, channels[pointer], 1, vDSP_Length(count))
        }
    }

    private nonisolated static func checkStatus(_ status: OSStatus, path: URL) throws {
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSFilePathErrorKey: path.path]
            )
        }
    }

    private func audioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func copyContents(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
