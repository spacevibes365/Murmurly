import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Murmurly

/// Polls this process's `phys_footprint`: the peak of one test, not of the
/// whole process (the lifetime maximum would carry the previous engine's run).
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var task: Task<Void, Never>?

    static func current() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    func start() {
        record(Self.current())
        task = Task.detached(priority: .high) { [self] in
            while !Task.isCancelled {
                record(Self.current())
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() -> UInt64 {
        task?.cancel()
        record(Self.current())
        return lock.withLock { peak }
    }

    private func record(_ value: UInt64) {
        lock.withLock { peak = max(peak, value) }
    }
}

/// Live check of meeting transcription on the real VAD and ASR models and a
/// real recording. The folder is given by MURMURLY_MEETING_FIXTURE (from
/// xcodebuild as TEST_RUNNER_MURMURLY_MEETING_FIXTURE); without it both
/// tests skip, so acceptance requires "Executed 2, 0 skipped".
@MainActor
final class MeetingTranscriptionStageGateTests: XCTestCase {
    func testParakeetTranscribesMeetingFixture() async throws {
        try await transcribeFixture(with: .parakeet)
    }

    func testWhisperTranscribesMeetingFixture() async throws {
        try await transcribeFixture(with: .whisper)
    }

    private func transcribeFixture(with engine: DictationEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["MURMURLY_MEETING_FIXTURE"] else {
            throw XCTSkip("MURMURLY_MEETING_FIXTURE is not set: the live meeting check did not run")
        }
        let fileManager = FileManager.default
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let output = URL(
            fileURLWithPath: environment["MURMURLY_STAGE_GATE_OUTPUT"]
                ?? NSHomeDirectory() + "/Library/Caches/Murmurly/StageGate/Results",
            isDirectory: true
        ).appendingPathComponent("meeting-\(engine.rawValue)-\(Int(Date().timeIntervalSince1970))")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        // Work on an APFS clone: the fixture itself is never written.
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("meeting-gate-\(UUID().uuidString)", isDirectory: true)
        let scratch = work.appendingPathComponent("scratch", isDirectory: true)
        let copy = work.appendingPathComponent(fixture.lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        try fileManager.copyItem(at: fixture, to: copy)

        let fixtureBefore = try digests(of: fixture)
        let copyBefore = try digests(of: copy)
        let streamingBefore = streamingTemporaryFiles()

        let choice = try MeetingTranscriber.Engine.forMeeting(SettingsSnapshot(
            dictationLanguage: "auto",
            dictationEngine: engine,
            whisperModelPath: SettingsStore.defaultWhisperModel,
            parakeetModelPath: SettingsStore.defaultParakeetModel
        ))
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: LiveWhisperEngineFactory(), parakeetFactory: LiveParakeetEngineFactory()),
            loadSpeechDetector: {
                try await MeetingTranscriber.sileroDetector(modelPath: MeetingTranscriber.vadModelPath)
            },
            currentEngine: { choice },
            temporaryRoot: scratch
        )

        let baseline = FootprintSampler.current()
        let sampler = FootprintSampler()
        sampler.start()
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await transcriber.transcribe(try .inspect(copy)) { _ in }
        let elapsed = started.duration(to: clock.now)
        let peak = sampler.stop()

        let transcript = try XCTUnwrap(report.transcript, "no transcript was written")
        let markdown = try String(contentsOf: transcript, encoding: .utf8)
        XCTAssertFalse(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(markdown.contains("**Me:**"), "no microphone line")
        XCTAssertTrue(markdown.contains("**Others:**"), "no system line")
        if copyBefore["transcript.md"] != nil {
            XCTAssertNotEqual(transcript.lastPathComponent, "transcript.md")
        }
        for track in report.tracks {
            XCTAssertLessThanOrEqual(track.longestChunkSeconds, 15, "\(track.name) has a chunk over 15 s")
            XCTAssertGreaterThan(track.chunks, 0, "\(track.name) found no speech")
        }
        XCTAssertEqual(report.tracks.count, 2)
        XCTAssertGreaterThan(report.echoRemoved, 0, "no echo removed")

        // Only the new transcript was added to the clone; the fixture is untouched.
        var copyAfter = try digests(of: copy)
        copyAfter[transcript.lastPathComponent] = nil
        XCTAssertEqual(copyAfter, copyBefore)
        XCTAssertEqual(try digests(of: fixture), fixtureBefore)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: scratch.path), [])
        XCTAssertEqual(streamingTemporaryFiles(), streamingBefore)

        let summary = summary(
            report, engine: engine, elapsed: elapsed, baseline: baseline, peak: peak, transcript: transcript
        )
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("summary.json"))
        try JSONEncoder().encode([
            "microphone": report.microphone, "system": report.system, "lines": report.lines,
        ]).write(to: output.appendingPathComponent("utterances.json"))
        try Data(markdown.utf8).write(to: output.appendingPathComponent(transcript.lastPathComponent))
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "MEETING-\(engine.rawValue.uppercased())-SUMMARY.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MEETING-GATE \(engine.rawValue): \(String(decoding: json, as: UTF8.self))")
        print("MEETING-GATE output: \(output.path)")
    }

    private func summary(
        _ report: MeetingTranscriber.Report,
        engine: DictationEngine,
        elapsed: Duration,
        baseline: UInt64,
        peak: UInt64,
        transcript: URL
    ) -> [String: Any] {
        let chunks = report.chunkSeconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !chunks.isEmpty else { return 0 }
            return chunks[min(chunks.count - 1, Int((Double(chunks.count - 1) * fraction).rounded()))]
        }
        let megabytes = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        return [
            "engine": engine.rawValue,
            "engines": report.engines,
            "languages": report.languages,
            "elapsedSeconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "footprintBaselineMB": megabytes(baseline),
            "footprintPeakMB": megabytes(peak),
            "chunkSecondsP50": percentile(0.5),
            "chunkSecondsP95": percentile(0.95),
            "chunkSecondsMax": chunks.last ?? 0,
            "recognizedChunks": chunks.count,
            "tracks": report.tracks.map {
                [
                    "name": $0.name,
                    "speechSeconds": $0.speechSeconds,
                    "chunks": $0.chunks,
                    "skippedChunks": $0.skippedChunks,
                    "failedChunks": $0.failedChunks,
                    "longestChunkSeconds": $0.longestChunkSeconds,
                ] as [String: Any]
            },
            "microphoneUtterances": report.microphone.count,
            "systemUtterances": report.system.count,
            "echoRemoved": report.echoRemoved,
            "lines": report.lines.count,
            "transcript": transcript.lastPathComponent,
        ]
    }

    private func digests(of folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            // Each read is drained at once; otherwise hashing two 2 GB copies
            // parks gigabytes in the autorelease pool and hides the real peak.
            while try autoreleasepool(invoking: {
                guard let data = try handle.read(upToCount: 4 << 20), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }) {}
            result[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func streamingTemporaryFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("fluidaudio-streaming-") })
    }
}
