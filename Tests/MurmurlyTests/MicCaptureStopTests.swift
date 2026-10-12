import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// Microphone stand-in for the joint tests: start does nothing; stop hands a
/// fresh copy of the template clip to a real MicCapture as a session that has
/// already failed, then runs MicCapture's own stop().
actor AdoptedFailingMic: MicCapturing {
    private let template: URL
    private let capture = MicCapture(levelMeter: MicrophoneLevelMeter())
    private(set) var lastSource: URL?

    init(template: URL) { self.template = template }

    func start() async throws {}

    func stop() async throws -> URL? {
        let source = template.deletingLastPathComponent()
            .appendingPathComponent("capture-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: template, to: source)
        lastSource = source
        await capture.adoptRecordingForTesting(
            url: source,
            error: MicCapture.CaptureError.configurationChanged
        )
        return try await capture.stop()
    }
}

/// Microphone stop regressions. Besides the DEBUG seam `adoptRecordingForTesting`, which
/// the red check adds unchanged to the pre-fix tree, they use only API that
/// exists there: assertions read real files, raw JSONL and the indicator.
@MainActor
final class MicCaptureStopTests: XCTestCase {
    func testFailedStopKeepsCapturedAudio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.caf")
        try writeCAF(at: url, frames: 9_600)
        let capture = MicCapture(levelMeter: MicrophoneLevelMeter())
        await capture.adoptRecordingForTesting(
            url: url,
            error: MicCapture.CaptureError.configurationChanged
        )

        do {
            _ = try await capture.stop()
            XCTFail("stop must report the capture failure")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "captured audio was deleted")
        if FileManager.default.fileExists(atPath: url.path) {
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 9_600)
        }
    }

    func testFailedStopKeepsUnreadableNonEmptyFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.caf")
        let bytes = Data("damaged audio bytes".utf8)
        try bytes.write(to: url)
        let capture = MicCapture(levelMeter: MicrophoneLevelMeter())
        await capture.adoptRecordingForTesting(
            url: url,
            error: MicCapture.CaptureError.configurationChanged
        )

        do {
            _ = try await capture.stop()
            XCTFail("stop must report the capture failure")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "unreadable source was deleted")
        XCTAssertEqual(try? Data(contentsOf: url), bytes)
    }

    func testFailedStopRemovesRecordingWithoutAudio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.caf")
        try writeCAF(at: url, frames: 0)
        let capture = MicCapture(levelMeter: MicrophoneLevelMeter())
        await capture.adoptRecordingForTesting(
            url: url,
            error: MicCapture.CaptureError.configurationChanged
        )

        do {
            _ = try await capture.stop()
            XCTFail("stop must report the capture failure")
        } catch let error as MicCapture.CaptureError {
            XCTAssertEqual(error, .configurationChanged)
        } catch {
            XCTFail("expected the original capture error, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInterruptedDictationIsArchivedAndNotPasted() async throws {
        let fixture = try DictationPipelineFixture(
            text: "first half",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        if let line = lines.first {
            XCTAssertEqual(line["interrupted"] as? Bool, true)
            XCTAssertNil(line["recognition_failed"])
            XCTAssertEqual(line["text"] as? String, "first half")
            let audioPath = try XCTUnwrap(line["audio_path"] as? String)
            XCTAssertEqual((audioPath as NSString).pathExtension, "caf", "fragment must stay raw CAF")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(audioPath).path
            ))
        }
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [], "a cut-off dictation must not be pasted")
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(message: "Recording interrupted (the audio device changed) — the fragment is in the “M” menu")
        )
    }

    func testUnrecognizedFragmentIsArchivedWithEmptyText() async throws {
        let fixture = try DictationPipelineFixture(
            text: "never decoded",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }
        await fixture.engine.failNextDecode()

        try await fixture.dictate()

        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        if let line = lines.first {
            XCTAssertEqual(line["interrupted"] as? Bool, true)
            XCTAssertEqual(line["recognition_failed"] as? Bool, true)
            XCTAssertEqual(line["text"] as? String, "")
            let audioPath = try XCTUnwrap(line["audio_path"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(audioPath).path
            ))
        }
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(
                message: "Recording interrupted (the audio device changed), fragment not recognized — the source audio is kept"
            )
        )
    }

    func testSilentFragmentSaysNoSpeech() async throws {
        let fixture = try DictationPipelineFixture(
            text: "",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        if let line = lines.first {
            XCTAssertEqual(line["interrupted"] as? Bool, true)
            XCTAssertNil(line["recognition_failed"])
            XCTAssertEqual(line["text"] as? String, "")
        }
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(
                message: "Recording interrupted (the audio device changed), no speech recognized — the source audio is kept"
            )
        )
    }

    func testInterruptedDictationWithBrokenHistoryKeepsSource() async throws {
        let fixture = try DictationPipelineFixture(
            text: "half",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(message: "Recording interrupted (the audio device changed) — the fragment is in the “M” menu")
        )
        let mic = try XCTUnwrap(fixture.activeMic as? AdoptedFailingMic)
        let lastSource = await mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "fragment source was deleted")
    }

    func testOrdinaryDictationHasNoInterruptionKeys() async throws {
        let fixture = try DictationPipelineFixture(text: "whole sentence")
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(lines.first?["interrupted"])
        XCTAssertNil(lines.first?["recognition_failed"])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeCAF(at url: URL, frames: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard frames > 0 else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    private func historyLines(in root: URL) throws -> [[String: Any]] {
        let url = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url)
            .split(separator: DictationHistoryStore.newline)
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }
}
