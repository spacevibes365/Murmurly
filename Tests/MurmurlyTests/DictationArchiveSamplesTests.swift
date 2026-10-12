import AVFoundation
import CryptoKit
import XCTest
@testable import Murmurly

/// Dictation archiving after the ALAC encoder moved out of the store for
/// meetings to share. The archived m4a is compared by its decoded samples, not
/// its bytes: the container may carry time stamps. The digests are printed, so
/// a run on the code before the move and one after compare sample for sample;
/// on both, a stereo source decoded to its first channel (`fdac3e45…`).
@MainActor
final class DictationArchiveSamplesTests: XCTestCase {
    func testArchivedDictationDecodesToTheSameSamples() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-samples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Dictations", isDirectory: true)
        let store = DictationHistoryStore(root: root)
        let left = Self.noise(count: 48_000, amplitude: 0.7, seed: 21)
        let right = Self.noise(count: 48_000, amplitude: 0.4, seed: 22)

        // A stereo microphone still archives as mono, its first channel, as
        // it always has.
        for (name, channels) in [("mono", [left]), ("stereo", [left, right])] {
            let source = base.appendingPathComponent("\(name).caf")
            try Self.write(channels, to: source)

            let archived = try await store.archiveAudio(
                from: source, id: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let url = root.appendingPathComponent(archived.relativePath)
            XCTAssertEqual(url.pathExtension, "m4a", name)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.channelCount, 1, name)
            XCTAssertEqual(file.length, 48_000, name)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ))
            try file.read(into: buffer)
            let decoded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let worst = zip(decoded, left).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertLessThanOrEqual(worst, 1 / 8_388_608, "\(name): the first channel within one 24-bit step")
            let digest = decoded.withUnsafeBytes { SHA256.hash(data: Data($0)) }
                .map { String(format: "%02x", $0) }.joined()
            print("DICTATION-DECODED \(name) frames=\(decoded.count) sha256=\(digest)")
        }
    }

    private static func noise(count: Int, amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed &* 2_654_435_761 | 1
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private static func write(_ channels: [[Float]], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channels.count), interleaved: false
        ))
        let frames = channels[0].count
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames)
            }
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }
}
