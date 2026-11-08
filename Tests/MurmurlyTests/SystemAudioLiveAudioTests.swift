import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// `LiveAudioRing` through the real IOProc (`adoptSessionForTesting` /
/// `deliverCycleForTesting`): the live snapshot must hold the same frames the
/// meeting's tracks got, by the same frame count as `writtenFrames`.
@MainActor
final class SystemAudioLiveAudioTests: XCTestCase {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Distinguishable, deterministic mono samples: `base`, `base + 1`, …
    private func samples(_ base: Int, _ count: Int, sign: Float = 1) -> [Float] {
        (0..<count).map { sign * Float(base + $0) / 100_000 }
    }

    func testLiveAudioHoldsTheFramesTheTracksGot() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 1_000,
            microphoneFrames: 1_000,
            enqueuedFrames: 1_000,
            startedAt: Date()
        )
        let systemA = samples(0, 480)
        let microphoneA = samples(0, 480, sign: -1)
        let systemB = samples(480, 480)
        let microphoneB = samples(480, 480, sign: -1)
        await capture.deliverCycleForTesting(frames: [480, 480], systemSamples: systemA, microphoneSamples: microphoneA)
        await capture.deliverCycleForTesting(frames: [480, 480], systemSamples: systemB, microphoneSamples: microphoneB)

        let snapshotOrNil = await capture.liveAudio()
        let snapshot = try XCTUnwrap(snapshotOrNil)
        XCTAssertEqual(snapshot.firstFrame, 1_000)
        XCTAssertEqual(snapshot.system.count, 960)
        XCTAssertEqual(snapshot.microphone.count, 960)
        XCTAssertEqual(snapshot.dropped, 0)
        XCTAssertEqual(snapshot.system, systemA + systemB)
        XCTAssertEqual(snapshot.microphone, microphoneA + microphoneB)
        let writtenSecondsOrNil = await capture.writtenSeconds()
        let writtenSeconds = try XCTUnwrap(writtenSecondsOrNil)
        XCTAssertEqual(Double(snapshot.firstFrame + 960) / snapshot.sampleRate, writtenSeconds, accuracy: 0.0001)

        _ = try await capture.stop()
        let systemFile = try AVAudioFile(forReading: directory.appendingPathComponent("system.caf"))
        let systemBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: systemFile.processingFormat, frameCapacity: AVAudioFrameCount(systemFile.length))
        )
        try systemFile.read(into: systemBuffer)
        let systemData = try XCTUnwrap(systemBuffer.floatChannelData)[0]
        XCTAssertEqual(Array(UnsafeBufferPointer(start: systemData + 1_000, count: 960)), systemA + systemB)

        let microphoneFile = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        let microphoneBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: microphoneFile.processingFormat, frameCapacity: AVAudioFrameCount(microphoneFile.length))
        )
        try microphoneFile.read(into: microphoneBuffer)
        let microphoneData = try XCTUnwrap(microphoneBuffer.floatChannelData)[0]
        XCTAssertEqual(Array(UnsafeBufferPointer(start: microphoneData + 1_000, count: 960)), microphoneA + microphoneB)
    }

    func testLiveAudioRateIsTheClockNotTheTapsDeclaredRate() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date(),
            declaredSystemRate: 48_000
        )
        await capture.deliverCycleForTesting(frames: [480, 480])

        let snapshotOrNil = await capture.liveAudio()
        let snapshot = try XCTUnwrap(snapshotOrNil)
        XCTAssertEqual(snapshot.sampleRate, 24_000)
        _ = try await capture.stop()
    }

    func testStereoMicrophoneKeepsBothChannelsAsTheFileDoes() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date(),
            microphoneChannels: 2
        )
        let frames = 480
        var microphoneSamples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            microphoneSamples[i * 2] = Float(i) / 100_000
            microphoneSamples[i * 2 + 1] = -Float(i) / 100_000
        }
        await capture.deliverCycleForTesting(
            frames: [UInt32(frames), UInt32(frames)], microphoneSamples: microphoneSamples
        )

        let snapshotOrNil = await capture.liveAudio()
        let snapshot = try XCTUnwrap(snapshotOrNil)
        XCTAssertEqual(snapshot.microphoneChannels, 2)
        XCTAssertEqual(snapshot.microphone.count, frames * 2)
        XCTAssertEqual(snapshot.microphone, microphoneSamples)

        _ = try await capture.stop()
        let microphoneFile = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(microphoneFile.fileFormat.channelCount, 2)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: microphoneFile.processingFormat, frameCapacity: AVAudioFrameCount(microphoneFile.length))
        )
        try microphoneFile.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<frames {
            XCTAssertEqual(channels[0][i], microphoneSamples[i * 2])
            XCTAssertEqual(channels[1][i], microphoneSamples[i * 2 + 1])
        }
    }

    func testManyChannelMicrophoneKeepsOnlyTheFirstChannel() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date(),
            microphoneChannels: 3
        )
        let frames = 480
        let channels = 3
        var microphoneSamples = [Float](repeating: 0, count: frames * channels)
        for i in 0..<(frames * channels) {
            microphoneSamples[i] = Float(i % channels) + Float(i / channels) / 100_000
        }
        await capture.deliverCycleForTesting(
            frames: [UInt32(frames), UInt32(frames)], microphoneSamples: microphoneSamples
        )

        let snapshotOrNil = await capture.liveAudio()
        let snapshot = try XCTUnwrap(snapshotOrNil)
        XCTAssertEqual(snapshot.microphoneChannels, 1)
        var expectedChannel0 = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            expectedChannel0[i] = microphoneSamples[i * channels]
        }
        XCTAssertEqual(snapshot.microphone, expectedChannel0)

        _ = try await capture.stop()
        let microphoneFile = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(microphoneFile.fileFormat.channelCount, 1)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: microphoneFile.processingFormat, frameCapacity: AVAudioFrameCount(microphoneFile.length))
        )
        try microphoneFile.read(into: buffer)
        let channel0 = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<frames {
            XCTAssertEqual(channel0[i], expectedChannel0[i])
        }
    }

    func testSkippedCycleAndFailedWriteDoNotMoveTheLiveAudio() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date()
        )
        let systemA = samples(0, 480)
        let microphoneA = samples(0, 480, sign: -1)
        let systemB = samples(480, 480)
        let microphoneB = samples(480, 480, sign: -1)

        await capture.deliverCycleForTesting(frames: [480, 480], systemSamples: systemA, microphoneSamples: microphoneA)
        await capture.deliverCycleForTesting(frames: [480, 960]) // streams out of step: left out of both tracks
        await capture.deliverCycleForTesting(frames: [480]) // no microphone stream: left out of both tracks
        await capture.deliverCycleForTesting(frames: [480, 480], failingWrite: true) // a write error: not accepted
        await capture.deliverCycleForTesting(frames: [480, 480], systemSamples: systemB, microphoneSamples: microphoneB)

        let snapshotOrNil = await capture.liveAudio()
        let snapshot = try XCTUnwrap(snapshotOrNil)
        XCTAssertEqual(snapshot.firstFrame, 0)
        XCTAssertEqual(snapshot.system.count, 960)
        XCTAssertEqual(snapshot.system, systemA + systemB)
        XCTAssertEqual(snapshot.microphone, microphoneA + microphoneB)
        XCTAssertEqual(snapshot.dropped, 0)

        // The write error makes `stop()` report a capture failure; that is
        // the existing stop() behaviour, not this card's concern.
        _ = try? await capture.stop()
    }

    func testFullRingLosesCyclesOnlyFromTheLiveAudio() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date(),
            liveCapacityFrames: 1_000
        )
        await capture.deliverCycleForTesting(frames: [480, 480])
        await capture.deliverCycleForTesting(frames: [480, 480])
        await capture.deliverCycleForTesting(frames: [480, 480]) // ring full: dropped
        await capture.deliverCycleForTesting(frames: [480, 480]) // still waiting for an empty ring: dropped

        let firstOrNil = await capture.liveAudio()
        let first = try XCTUnwrap(firstOrNil)
        XCTAssertEqual(first.firstFrame, 0)
        XCTAssertEqual(first.system.count, 960)
        XCTAssertEqual(first.dropped, 960)

        await capture.deliverCycleForTesting(frames: [480, 480])
        let secondOrNil = await capture.liveAudio()
        let second = try XCTUnwrap(secondOrNil)
        XCTAssertEqual(second.firstFrame, first.firstFrame + Int64(first.system.count) + first.dropped)
        XCTAssertEqual(second.system.count, 480)
        XCTAssertEqual(second.dropped, 0)

        _ = try await capture.stop()
        let systemFile = try AVAudioFile(forReading: directory.appendingPathComponent("system.caf"))
        XCTAssertEqual(systemFile.length, 2_400, "the file keeps every cycle even when the live ring drops some")

        // A cycle bigger than the whole ring must be dropped before copying,
        // never copied past the buffer.
        let tinyDirectory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: tinyDirectory) }
        let tinyCapture = SystemAudioCapture()
        try await tinyCapture.adoptSessionForTesting(
            directory: tinyDirectory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date(),
            liveCapacityFrames: 100
        )
        await tinyCapture.deliverCycleForTesting(frames: [480, 480])
        let tinySnapshot = await tinyCapture.liveAudio()
        XCTAssertNil(tinySnapshot, "a cycle bigger than the whole ring must be dropped, not overrun it")
        _ = try? await tinyCapture.stop()
    }

    func testLiveAudioIsEmptyBeforeAndAfterTheSession() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        let beforeStart = await capture.liveAudio()
        XCTAssertNil(beforeStart, "nothing has started yet")
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date()
        )
        let beforeAnyCycle = await capture.liveAudio()
        XCTAssertNil(beforeAnyCycle, "no cycle has come in yet")
        await capture.deliverCycleForTesting(frames: [480, 480])
        let afterCycle = await capture.liveAudio()
        XCTAssertNotNil(afterCycle)
        let readAgain = await capture.liveAudio()
        XCTAssertNil(readAgain, "already read; nothing new since")
        _ = try await capture.stop()
        let afterStop = await capture.liveAudio()
        XCTAssertNil(afterStop, "stopped; nothing to read and no crash")
    }

    /// One channel makes non-interleaved the same bytes as interleaved: the
    /// ring must still be built, not switched off by that flag alone.
    func testMonoNonInterleavedFlagStillGetsALiveRing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: Date(),
            microphoneNonInterleaved: true
        )
        await capture.deliverCycleForTesting(frames: [480, 480])

        let snapshotOrNil = await capture.liveAudio()
        let snapshot = try XCTUnwrap(snapshotOrNil)
        XCTAssertEqual(snapshot.microphoneChannels, 1)
        XCTAssertEqual(snapshot.system.count, 480)
        _ = try await capture.stop()
    }
}
