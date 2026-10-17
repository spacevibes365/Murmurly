import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// One IOProc cycle for an adopted session (`deliverCycleForTesting`): frames
/// per stream, system then microphone, and the microphone's every sample.
struct IOProcCycle: ExpressibleByArrayLiteral {
    var frames: [UInt32]
    var microphone: Float = 0.1

    /// `seconds` of whole 0.1 s cycles at 24 kHz; a `microphone` of 0 is the
    /// exact silence of a headset that gave its voice channel away.
    static func steady(_ seconds: Double, microphone: Float = 0.1) -> [IOProcCycle] {
        Array(repeating: IOProcCycle(frames: [2_400, 2_400], microphone: microphone), count: Int(seconds * 10))
    }
}

extension IOProcCycle {
    init(arrayLiteral frames: UInt32...) { self.init(frames: frames) }
}

/// The real `SystemAudioCapture` behind a recorder, without Core Audio: start
/// adopts an empty 24 kHz session begun `elapsed` seconds ago, stop hands
/// `cycles` to the real IOProc, optionally loses a track, then runs the real
/// stop.
actor AdoptedMeetingCapture: MeetingCaptureBackend {
    /// An AirPods headset dropping out and coming back mid-call: between
    /// steady cycles, one without the microphone stream (live, the aggregate
    /// ran on the tap's clock for 0.7 s without it), one with it empty and one
    /// with it out of step. The steady ones make 0.4 s at 24 kHz.
    static let dropout: [IOProcCycle] = Array(repeating: [480, 480], count: 10)
        + [[480], [480, 0], [480, 960]]
        + Array(repeating: [480, 480], count: 10)

    let directory: URL
    let cycles: [IOProcCycle]
    let elapsed: TimeInterval
    let deleting: String?
    private let capture = SystemAudioCapture()

    init(directory: URL, cycles: [IOProcCycle], elapsed: TimeInterval = 0, deleting: String? = nil) {
        self.directory = directory
        self.cycles = cycles
        self.elapsed = elapsed
        self.deleting = deleting
    }

    func start(in _: URL) async throws -> Date {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let startedAt = Date()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: 24_000,
            systemFrames: 0,
            microphoneFrames: 0,
            enqueuedFrames: 0,
            startedAt: startedAt.addingTimeInterval(-elapsed)
        )
        return startedAt
    }

    func stop() async throws -> [URL] {
        for cycle in cycles {
            await capture.deliverCycleForTesting(frames: cycle.frames, microphone: cycle.microphone)
        }
        if let deleting { try FileManager.default.removeItem(at: directory.appendingPathComponent(deleting)) }
        return try await capture.stop()
    }
}

/// Regressions on the real `SystemAudioCapture.stop()`. The DEBUG seam
/// `adoptSessionForTesting`, added unchanged to the tree before the fix by
/// the red check, only stands in for a running tap: open CAFs with some frames
/// written and a queue count. Assertions read the raw metadata.json and what
/// `stop()` hands back to the meeting coordinator.
@MainActor
final class SystemAudioCaptureStopTests: XCTestCase {
    /// The folder is the recorder's, made for the session: a start refused
    /// before any tap exists removes it, so no empty folder passes for a
    /// recording that broke off.
    func testRefusedStartRemovesTheFolderItWasGiven() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = root.appendingPathComponent("running", isDirectory: true)
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        for folder in [running, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: running, sampleRate: 48_000, systemFrames: 0, microphoneFrames: 0,
            enqueuedFrames: 0, startedAt: Date()
        )

        do {
            _ = try await capture.start(in: fresh)
            XCTFail("a second start began")
        } catch {
            XCTAssertEqual(error as? SystemAudioCaptureError, .alreadyRunning)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "the refused session's folder stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path), "the running session's folder went")
        _ = try? await capture.stop()
    }

    func testShortTracksAreSuspectWithMeasuredFrames() async throws {
        let session = try await stopAdoptedSession(systemFrames: 1_024, microphoneFrames: 1_024, enqueued: 48_000)
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        let segment = try XCTUnwrap(session.segment)
        XCTAssertEqual(segment["frames"] as? Int, 1_024, "metadata must hold measured frames, not the queue count")
        XCTAssertEqual(session.metadata["state"] as? String, "suspect")
        XCTAssertTrue(session.issues.contains { $0.contains("system.caf") }, "\(session.issues)")
    }

    func testUnequalTracksAreSuspect() async throws {
        let session = try await stopAdoptedSession(systemFrames: 48_000, microphoneFrames: 24_000, enqueued: 48_000)
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "suspect")
        XCTAssertEqual(session.segment?["micFrames"] as? Int, 24_000)
        XCTAssertTrue(session.issues.contains { $0.contains("microphone.caf") }, "\(session.issues)")
    }

    func testMissingMicrophoneTrackFails() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 48_000,
            microphoneFrames: 48_000,
            enqueued: 48_000,
            deleting: "microphone.caf"
        )
        defer { session.cleanup() }

        assertFailsSavedAt(session)
        XCTAssertEqual(session.metadata["state"] as? String, "failed")
        XCTAssertTrue(session.issues.contains { $0.contains("microphone.caf") }, "\(session.issues)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
    }

    func testMissingSystemTrackFailsWithoutInventedFrames() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 48_000,
            microphoneFrames: 48_000,
            enqueued: 48_000,
            deleting: "system.caf"
        )
        defer { session.cleanup() }

        assertFailsSavedAt(session)
        XCTAssertEqual(session.metadata["state"] as? String, "failed")
        XCTAssertNil(session.segment?["frames"], "an unmeasured track must not report frames")
        XCTAssertTrue(session.issues.contains { $0.contains("system.caf") }, "\(session.issues)")
    }

    /// Three microphone channels with the voice only in the
    /// second. The first channel is what is written, so this recording holds
    /// no voice — and says so: suspect with the reason, which the menu shows
    /// for its folder, and metadata that counts the channels and names
    /// the one kept.
    func testFirstOfManyMicrophoneChannelsIsSaidAndRecordedInTheMetadata() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 48_000, microphoneFrames: 48_000, enqueued: 48_000,
            microphoneChannels: 3, microphoneSignalChannel: 1
        )
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "suspect", "a partial microphone track passed for a whole one")
        XCTAssertTrue(
            session.issues.contains("Only the first of 3 microphone channels was recorded"), "\(session.issues)"
        )
        let segment = try XCTUnwrap(session.segment)
        XCTAssertEqual(segment["micInputChannels"] as? Int, 3)
        XCTAssertEqual(segment["micRecordedChannel"] as? Int, 1)
        let microphone = try AVAudioFile(forReading: session.directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(microphone.fileFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: microphone.processingFormat, frameCapacity: 48_000))
        try microphone.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        XCTAssertEqual((0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max(), 0, "the second channel's voice was kept")
    }

    /// Mono stays as it was: one channel in, that channel written, nothing to say.
    func testMonoMicrophoneNamesItsOneChannelWithoutAWarning() async throws {
        let session = try await stopAdoptedSession(systemFrames: 48_000, microphoneFrames: 48_000, enqueued: 48_000)
        defer { session.cleanup() }

        XCTAssertEqual(session.metadata["state"] as? String, "done")
        let segment = try XCTUnwrap(session.segment)
        XCTAssertEqual(segment["micInputChannels"] as? Int, 1)
        XCTAssertNil(segment["micRecordedChannel"], "every channel of a mono microphone is written")
    }

    func testCompleteEqualTracksAreDone() async throws {
        let session = try await stopAdoptedSession(systemFrames: 48_000, microphoneFrames: 48_000, enqueued: 48_000)
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "done")
        XCTAssertEqual(session.segment?["frames"] as? Int, 48_000)
    }

    /// AirPods in headset mode: both tracks at the shared 24 kHz clock. The
    /// checks after stop count frames of one rate and set the wall clock
    /// against it, so a second at 24 kHz is a second, not half of one.
    func testHeadsetRateSessionIsDoneWithItsRateInTheMetadata() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 24_000, microphoneFrames: 24_000, enqueued: 24_000, sampleRate: 24_000
        )
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "done", "\(session.issues)")
        XCTAssertEqual(session.issues, [])
        XCTAssertEqual(session.metadata["sampleRate"] as? Int, 24_000)
        let segment = try XCTUnwrap(session.segment)
        XCTAssertEqual(segment["frames"] as? Int, 24_000)
        XCTAssertEqual(segment["micFrames"] as? Int, 24_000)
        for name in ["system.caf", "microphone.caf"] {
            let file = try AVAudioFile(forReading: session.directory.appendingPathComponent(name))
            XCTAssertEqual(file.fileFormat.sampleRate, 24_000, name)
        }
    }

    /// Seen live with AirPods: the headset's channel dropped out for four
    /// seconds mid-call and came back, and the recording ended as failed
    /// ("Core Audio 'what'") with both tracks whole. Cycles whose streams
    /// don't match are left out of both tracks, which stay aligned: the
    /// recording is saved with a warning that says how much is missing.
    func testCyclesOutOfStepAreSkippedOnBothTracksAndTheRecordingIsSuspect() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 0, microphoneFrames: 0, enqueued: 0, sampleRate: 24_000, cycles: AdoptedMeetingCapture.dropout
        )
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "suspect", "\(session.issues)")
        let segment = try XCTUnwrap(session.segment)
        XCTAssertEqual(segment["frames"] as? Int, 9_600, "only the whole cycles are written")
        XCTAssertEqual(segment["micFrames"] as? Int, 9_600, "both tracks skip the same cycles")
        // One warning that says how much is missing, by the clock, and no
        // second one about the clock: 0.4 s of audio in about a second.
        XCTAssertEqual(session.issues.count, 1, "\(session.issues)")
        let issue = try XCTUnwrap(session.issues.first)
        XCTAssertTrue(issue.hasPrefix("About "), issue)
        XCTAssertTrue(issue.contains(" s is missing from both tracks"), issue)
        XCTAssertFalse(issue.contains("Core Audio"), issue)
    }

    /// A stream went and never came back: the aggregate ran on without it
    /// until the stop. The headset's microphone stream ([480]) or the system
    /// audio with the microphone still live ([0, 480]) give the same flag, so
    /// the reason names neither alone. Not a short gap: the recording keeps
    /// what came before and says plainly where it ended in fact, at the same
    /// time the transcript would show.
    func testDropoutThatNeverRecoversSaysWhereTheRecordingEnded() async throws {
        for gone: IOProcCycle in [[480], [0, 480]] {
            let session = try await stopAdoptedSession(
                systemFrames: 0, microphoneFrames: 0, enqueued: 0, sampleRate: 24_000,
                cycles: Array(repeating: [480, 480], count: 50) + Array(repeating: gone, count: 5)
            )
            defer { session.cleanup() }

            assertReturnsBothTracks(session)
            XCTAssertEqual(session.metadata["state"] as? String, "suspect", "\(gone.frames): \(session.issues)")
            XCTAssertEqual(
                session.segment?["frames"] as? Int, 24_000, "\(gone.frames): the second before the dropout is kept"
            )
            XCTAssertEqual(
                session.issues,
                ["The microphone or the system audio dropped out at 0:01 and did not come back: nothing after that was recorded"],
                "\(gone.frames)"
            )
        }
    }

    /// A skipped cycle explains audio shorter than the clock, never longer.
    /// Tracks 2 s and more ahead of the clock mean a wrong rate (an aggregate
    /// back at another rate with equal frames on both streams), and the
    /// skipped moment must not hide it.
    func testAudioLongerThanTheClockIsReportedDespiteSkippedCycles() async throws {
        let steady: [IOProcCycle] = Array(repeating: [480, 480], count: 75)
        let session = try await stopAdoptedSession(
            systemFrames: 0, microphoneFrames: 0, enqueued: 0, sampleRate: 24_000,
            cycles: steady + [[480]] + steady,
            elapsed: 0
        )
        defer { session.cleanup() }

        XCTAssertEqual(session.metadata["state"] as? String, "suspect", "\(session.issues)")
        XCTAssertEqual(session.segment?["frames"] as? Int, 72_000)
        XCTAssertTrue(
            session.issues.contains { $0.hasPrefix("audio lasts 3.0 s while the clock says ") }, "\(session.issues)"
        )
    }

    /// A headset that gave its voice channel to another Mac stays the input:
    /// Core Audio goes on delivering whole microphone buffers of exact zeros,
    /// nothing is skipped and the tracks are whole (live, 5.5 minutes of a
    /// call passed for a complete recording). A live microphone never sends
    /// exact zeros, so a run of 10 s and more is said, at the times the
    /// transcript shows.
    func testMicrophoneSendingOnlySilenceIsSuspectWithWhenAndHowLong() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 0, microphoneFrames: 0, enqueued: 0, sampleRate: 24_000,
            cycles: IOProcCycle.steady(2) + IOProcCycle.steady(12, microphone: 0) + IOProcCycle.steady(1),
            elapsed: 15
        )
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "suspect", "\(session.issues)")
        XCTAssertEqual(session.segment?["frames"] as? Int, 360_000, "the tracks are whole")
        XCTAssertEqual(
            session.issues,
            ["The microphone sent only silence for 0:12 between 0:02 and 0:14: it was muted or taken by another device"]
        )
    }

    /// The live switch of a headset between two Macs, scaled down: silence
    /// across a dropout that recovered, two one-second sounds as the voice
    /// channel came up and went again, a short run of silence between them,
    /// more silence until the headset went for good. One reason spans the
    /// first long run to the last, counts every silent second in it and only
    /// those, and stands next to the reason of the dropout.
    func testSilenceAcrossADropoutAndShortSoundsIsOneReasonNextToTheDropout() async throws {
        let gone: [IOProcCycle] = Array(repeating: [2_400], count: 5)
        let parts: [[IOProcCycle]] = [
            IOProcCycle.steady(2),
            IOProcCycle.steady(12, microphone: 0), gone, IOProcCycle.steady(3, microphone: 0),
            IOProcCycle.steady(1),
            IOProcCycle.steady(5, microphone: 0),
            IOProcCycle.steady(1),
            IOProcCycle.steady(11, microphone: 0), gone,
        ]
        let session = try await stopAdoptedSession(
            systemFrames: 0, microphoneFrames: 0, enqueued: 0, sampleRate: 24_000,
            cycles: parts.flatMap { $0 },
            elapsed: 36
        )
        defer { session.cleanup() }

        assertReturnsBothTracks(session)
        XCTAssertEqual(session.metadata["state"] as? String, "suspect", "\(session.issues)")
        XCTAssertEqual(session.segment?["frames"] as? Int, 840_000)
        XCTAssertEqual(
            Set(session.issues),
            [
                "The microphone sent only silence for 0:31 between 0:02 and 0:35: it was muted or taken by another device",
                "The microphone or the system audio dropped out at 0:35 and did not come back: nothing after that was recorded",
            ]
        )
    }

    /// A headset's microphone starts with up to 1.5 s of exact zeros, and a
    /// silent stretch shorter than 10 s is no proof of anything: neither is
    /// said, and short runs don't add up to a long one.
    func testShortSilenceIsNotAReason() async throws {
        let session = try await stopAdoptedSession(
            systemFrames: 0, microphoneFrames: 0, enqueued: 0, sampleRate: 24_000,
            cycles: IOProcCycle.steady(1.5, microphone: 0)
                + IOProcCycle.steady(3)
                + IOProcCycle.steady(9.5, microphone: 0)
                + IOProcCycle.steady(1),
            elapsed: 15
        )
        defer { session.cleanup() }

        XCTAssertEqual(session.metadata["state"] as? String, "done", "\(session.issues)")
        XCTAssertEqual(session.segment?["frames"] as? Int, 360_000)
        XCTAssertEqual(session.issues, [])
    }

    private func assertReturnsBothTracks(
        _ session: StoppedSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch session.outcome {
        case let .success(urls):
            XCTAssertEqual(
                urls.map(\.lastPathComponent),
                ["system.caf", "microphone.caf"],
                file: file,
                line: line
            )
        case let .failure(error):
            XCTFail("stop must hand both tracks to the coordinator, threw \(error)", file: file, line: line)
        }
    }

    private func assertFailsSavedAt(
        _ session: StoppedSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch session.outcome {
        case .success:
            XCTFail("an unreadable track must fail the stop, not pass as saved", file: file, line: line)
        case let .failure(error):
            let saved = (error as? SystemAudioCaptureError)?.savedDirectory
            XCTAssertEqual(
                saved?.standardizedFileURL.path,
                session.directory.standardizedFileURL.path,
                "stop must report captureFailed with this very folder, got \(error)",
                file: file,
                line: line
            )
        }
    }

    private struct StoppedSession {
        let directory: URL
        let outcome: Result<[URL], any Error>
        let metadata: [String: Any]

        var segment: [String: Any]? { (metadata["segments"] as? [[String: Any]])?.first }
        var issues: [String] { metadata["issues"] as? [String] ?? [] }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Adopts a session started `elapsed` seconds ago (48 kHz unless said
    /// otherwise), hands `cycles` to the real IOProc, optionally removes a
    /// track while it is still open, runs the real stop and reads what it
    /// wrote.
    private func stopAdoptedSession(
        systemFrames: UInt32,
        microphoneFrames: UInt32,
        enqueued: Int64,
        sampleRate: Double = 48_000,
        cycles: [IOProcCycle] = [],
        elapsed: TimeInterval = 1,
        deleting trackName: String? = nil,
        microphoneChannels: UInt32 = 1,
        microphoneSignalChannel: UInt32 = 0
    ) async throws -> StoppedSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture = SystemAudioCapture()
        try await capture.adoptSessionForTesting(
            directory: directory,
            sampleRate: sampleRate,
            systemFrames: systemFrames,
            microphoneFrames: microphoneFrames,
            enqueuedFrames: enqueued,
            startedAt: Date().addingTimeInterval(-elapsed),
            microphoneChannels: microphoneChannels,
            microphoneSignalChannel: microphoneSignalChannel
        )
        for cycle in cycles {
            await capture.deliverCycleForTesting(frames: cycle.frames, microphone: cycle.microphone)
        }
        if let trackName {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(trackName))
        }

        let outcome: Result<[URL], any Error>
        do {
            outcome = .success(try await capture.stop())
        } catch {
            outcome = .failure(error)
        }

        let data = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return StoppedSession(directory: directory, outcome: outcome, metadata: metadata)
    }
}
