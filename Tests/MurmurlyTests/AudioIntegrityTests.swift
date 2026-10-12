import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// Archive integrity regressions on the production archiver. They use only API that exists
/// on the tree before the fix: `archiveAudio` and the dictation pipeline.
@MainActor
final class AudioIntegrityTests: XCTestCase {
    func testPeakAfterFirstBlockKeepsByteIdenticalPrivateCAF() async throws {
        // One peak per file, deliberately after frame 4096: the encoder reads
        // in 4096-frame blocks, so this is the second block.
        for peak: Float in [1.0001, -1.5, .nan, .infinity] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var samples = [Float](repeating: 0.1, count: 10_000)
            samples[6_000] = peak
            let source = directory.appendingPathComponent("source.caf")
            try writeCAF(at: source, channels: [samples])
            let root = directory.appendingPathComponent("Dictations", isDirectory: true)
            let store = DictationHistoryStore(root: root)

            let archived = try await store.archiveAudio(from: source, id: UUID(), at: Date())

            let audioURL = root.appendingPathComponent(archived.relativePath)
            XCTAssertEqual(audioURL.pathExtension, "caf", "peak \(peak) was clipped into ALAC")
            XCTAssertEqual(try Data(contentsOf: audioURL), try Data(contentsOf: source), "peak \(peak)")
            XCTAssertEqual(try permissions(of: audioURL), 0o600, "peak \(peak)")
            XCTAssertTrue(files(under: root, withExtension: "m4a").isEmpty, "partial m4a left for \(peak)")
        }
    }

    func testPeakInSecondChannelOnlyKeepsCAF() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let left = [Float](repeating: 0.1, count: 2_000)
        var right = [Float](repeating: 0.1, count: 2_000)
        right[100] = 1.25
        let source = directory.appendingPathComponent("stereo.caf")
        try writeCAF(at: source, channels: [left, right])
        let root = directory.appendingPathComponent("Dictations", isDirectory: true)
        let store = DictationHistoryStore(root: root)

        let archived = try await store.archiveAudio(from: source, id: UUID(), at: Date())

        let audioURL = root.appendingPathComponent(archived.relativePath)
        XCTAssertEqual(audioURL.pathExtension, "caf", "a peak in the second channel was clipped")
        XCTAssertEqual(try Data(contentsOf: audioURL), try Data(contentsOf: source))
    }

    func testDictationWithPeakArchivesSourceCAF() async throws {
        var samples = [Float](repeating: 0.1, count: 9_000)
        samples[5_000] = 1.5
        let fixture = try DictationPipelineFixture(text: "peak", templateSamples: samples)
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let history = fixture.root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let lines = (try? Data(contentsOf: history))?.split(separator: DictationHistoryStore.newline) ?? []
        XCTAssertEqual(lines.count, 1)
        guard let first = lines.first else { return }
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first)) as? [String: Any])
        let audioPath = try XCTUnwrap(line["audio_path"] as? String)
        XCTAssertEqual((audioPath as NSString).pathExtension, "caf", "the dictation was clipped into ALAC")
        let template = fixture.parent.appendingPathComponent("template.caf")
        XCTAssertEqual(
            try Data(contentsOf: fixture.root.appendingPathComponent(audioPath)),
            try Data(contentsOf: template)
        )
        let lastSource = await fixture.mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "source kept after a confirmed save")
    }

    func testFullScaleWithinRangeStaysALAC() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples = [Float](repeating: 0.25, count: 10_000)
        samples[10] = 1.0
        samples[6_000] = -1.0
        samples[7_000] = -0.25
        let source = directory.appendingPathComponent("source.caf")
        try writeCAF(at: source, channels: [samples])
        let store = DictationHistoryStore(root: directory.appendingPathComponent("Dictations", isDirectory: true))

        let archived = try await store.archiveAudio(from: source, id: UUID(), at: Date())

        XCTAssertEqual((archived.relativePath as NSString).pathExtension, "m4a")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Float32, non-interleaved, one array per channel.
    private func writeCAF(at url: URL, channels: [[Float]]) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels.count))
        )
        let frames = AVAudioFrameCount(channels.first?.count ?? 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (channel, samples) in channels.enumerated() {
            for (index, sample) in samples.enumerated() { data[channel][index] = sample }
        }
        try file.write(from: buffer)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    }

    private func files(under root: URL, withExtension pathExtension: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == pathExtension }
    }
}
