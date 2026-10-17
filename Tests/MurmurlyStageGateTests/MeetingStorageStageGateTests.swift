import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Murmurly

/// Polls this process's `phys_footprint` while one step runs.
private final class StoragePeakSampler: @unchecked Sendable {
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

/// Live check of meeting compression on a real recording. Two APFS clones of
/// MURMURLY_MEETING_FIXTURE: one is compressed, its m4a compared with the
/// fixture's CAF by a reader independent of `MeetingStorage.verify`, and then
/// both clones are transcribed with Parakeet.
///
/// What must hold is what compression could break: the same VAD chunks, none
/// skipped or failed, every sample within one 24-bit step. Echo and line
/// counts are recorded but need not match: Parakeet answers a difference in
/// the last 24-bit bit with another comma now and then, the uncompressed
/// system track (gain 1) included. Both runs' utterances are written out so
/// they can be compared word by word. Without the variable the test skips,
/// so acceptance requires "Executed 1, 0 skipped".
@MainActor
final class MeetingStorageStageGateTests: XCTestCase {
    func testCompressedFixtureIsExactAndTranscribesTheSameChunks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["MURMURLY_MEETING_FIXTURE"] else {
            throw XCTSkip("MURMURLY_MEETING_FIXTURE is not set: the live compression check did not run")
        }
        let fileManager = FileManager.default
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let output = URL(
            fileURLWithPath: environment["MURMURLY_STAGE_GATE_OUTPUT"]
                ?? NSHomeDirectory() + "/Library/Caches/Murmurly/StageGate/Results",
            isDirectory: true
        ).appendingPathComponent("meeting-storage-\(Int(Date().timeIntervalSince1970))")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        // APFS clones outside any meetings root: the fixture itself is never
        // written, and no running app's scan can see the clones.
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("meeting-storage-gate-\(UUID().uuidString)", isDirectory: true)
        let scratch = work.appendingPathComponent("scratch", isDirectory: true)
        let plain = work.appendingPathComponent("plain", isDirectory: true)
            .appendingPathComponent(fixture.lastPathComponent, isDirectory: true)
        let copy = work.appendingPathComponent("compressed", isDirectory: true)
            .appendingPathComponent(fixture.lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        try fileManager.copyItem(at: fixture, to: plain)
        try fileManager.copyItem(at: fixture, to: copy)
        let fixtureBefore = try digests(of: fixture)
        let otherFiles = fixtureBefore.filter { !$0.key.hasSuffix(".caf") && $0.key != "metadata.json" }

        let cafBytes = try ["microphone.caf", "system.caf"].reduce(Int64(0)) { $0 + (try size(copy.appendingPathComponent($1))) }
        let sampler = StoragePeakSampler()
        let baseline = StoragePeakSampler.current()
        sampler.start()
        let clock = ContinuousClock()
        let compressionStarted = clock.now
        let result = await MeetingStorage.compress(copy)
        let compressionSeconds = seconds(compressionStarted.duration(to: clock.now))
        let compressionPeak = sampler.stop()

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(Set(result.compressed), ["microphone.caf", "system.caf"])
        let names = Set(try fileManager.contentsOfDirectory(atPath: copy.path))
        XCTAssertEqual(names, Set(otherFiles.keys).union(["metadata.json", "microphone.m4a", "system.m4a"]))
        var copyAfter = try digests(of: copy)
        for name in ["metadata.json", "microphone.m4a", "system.m4a"] { copyAfter[name] = nil }
        XCTAssertEqual(copyAfter, otherFiles, "only the tracks and metadata changed")
        let m4aBytes = try ["microphone.m4a", "system.m4a"].reduce(Int64(0)) { $0 + (try size(copy.appendingPathComponent($1))) }

        let folder = try MeetingTranscriber.Folder.inspect(copy)
        let checkStarted = clock.now
        let microphoneCheck = try compare(
            folder.microphone!, with: fixture.appendingPathComponent("microphone.caf"), gain: folder.microphoneGain
        )
        let systemCheck = try compare(
            folder.system!, with: fixture.appendingPathComponent("system.caf"), gain: folder.systemGain
        )
        let checkSeconds = seconds(checkStarted.duration(to: clock.now))
        XCTAssertEqual(microphoneCheck.frames, systemCheck.frames)
        XCTAssertLessThanOrEqual(microphoneCheck.worst, MeetingStorage.tolerance)
        XCTAssertLessThanOrEqual(systemCheck.worst, MeetingStorage.tolerance)

        let choice = try MeetingTranscriber.Engine.forMeeting(SettingsSnapshot(
            dictationLanguage: "auto",
            dictationEngine: .parakeet,
            whisperModelPath: SettingsStore.defaultWhisperModel,
            parakeetModelPath: SettingsStore.defaultParakeetModel
        ))
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: LiveWhisperEngineFactory(), parakeetFactory: LiveParakeetEngineFactory()),
            loadSpeechDetector: { _ in
                try await MeetingTranscriber.sileroDetector(modelPath: MeetingTranscriber.vadModelPath)
            },
            currentEngine: { _ in choice },
            temporaryRoot: scratch
        )
        var runs: [String: Any] = [:]
        var reports: [String: MeetingTranscriber.Report] = [:]
        for (name, target) in [("uncompressed", plain), ("compressed", copy)] {
            let started = clock.now
            let report = try await transcriber.transcribe(try .inspect(target)) { _ in }
            reports[name] = report
            XCTAssertEqual(report.tracks.map(\.chunks), [577, 487], "\(name): VAD chunks (microphone, system)")
            XCTAssertEqual(report.tracks.map(\.skippedChunks), [0, 0], name)
            XCTAssertEqual(report.tracks.map(\.failedChunks), [0, 0], name)
            runs[name] = [
                "seconds": seconds(started.duration(to: clock.now)),
                "chunks": report.tracks.map(\.chunks),
                "echoRemoved": report.echoRemoved,
                "lines": report.lines.count,
                "microphoneUtterances": report.microphone.count,
                "systemUtterances": report.system.count,
            ] as [String: Any]
            try JSONEncoder().encode([
                "microphone": report.microphone, "system": report.system, "lines": report.lines,
            ]).write(to: output.appendingPathComponent("utterances-\(name).json"))
        }
        let before = try XCTUnwrap(reports["uncompressed"])
        let after = try XCTUnwrap(reports["compressed"])
        XCTAssertEqual(before.microphone.map(\.start), after.microphone.map(\.start), "the same microphone chunks spoke")
        XCTAssertEqual(try digests(of: fixture), fixtureBefore, "the fixture is untouched")

        let summary: [String: Any] = [
            "fixture": fixture.lastPathComponent,
            "cafBytes": cafBytes,
            "m4aBytes": m4aBytes,
            "ratio": Double(cafBytes) / Double(max(m4aBytes, 1)),
            "compressionSeconds": compressionSeconds,
            "footprintBaselineMB": Double(baseline) / 1_048_576,
            "compressionFootprintPeakMB": Double(compressionPeak) / 1_048_576,
            "microphoneGain": Double(folder.microphoneGain),
            "systemGain": Double(folder.systemGain),
            "independentCheckSeconds": checkSeconds,
            "microphoneFrames": microphoneCheck.frames,
            "systemFrames": systemCheck.frames,
            "microphoneWorstDifference": Double(microphoneCheck.worst),
            "systemWorstDifference": Double(systemCheck.worst),
            "microphoneOriginalPeak": Double(microphoneCheck.originalPeak),
            "systemOriginalPeak": Double(systemCheck.originalPeak),
            "transcriptions": runs,
            "changedUtterances": [
                "microphone": changed(before.microphone, after.microphone),
                "system": changed(before.system, after.system),
            ],
            "metadata": String(decoding: try Data(contentsOf: copy.appendingPathComponent("metadata.json")), as: UTF8.self),
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("summary.json"))
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "MEETING-STORAGE-SUMMARY.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MEETING-STORAGE-GATE: \(String(decoding: json, as: UTF8.self))")
        print("MEETING-STORAGE-GATE output: \(output.path)")
    }

    /// Utterances whose text changed, paired by start time; one missing on
    /// either side counts too.
    private func changed(_ before: [MeetingTranscriber.Utterance], _ after: [MeetingTranscriber.Utterance]) -> Int {
        let old = Dictionary(before.map { ($0.start, $0.text) }, uniquingKeysWith: { $0 + " " + $1 })
        let new = Dictionary(after.map { ($0.start, $0.text) }, uniquingKeysWith: { $0 + " " + $1 })
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.count
    }

    /// Decodes the m4a and reads the fixture's CAF each to the end in its own
    /// loop, independent of the check inside `MeetingStorage`, and compares
    /// them frame by frame through a carried-over window.
    private func compare(
        _ m4a: URL,
        with caf: URL,
        gain: Float
    ) throws -> (frames: Int64, worst: Float, originalPeak: Float) {
        let source = try AVAudioFile(forReading: caf)
        let copy = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(copy.length, source.length)
        let channels = Int(source.processingFormat.channelCount)
        XCTAssertEqual(Int(copy.processingFormat.channelCount), channels)
        let capacity: AVAudioFrameCount = 1 << 18
        let a = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity))
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: copy.processingFormat, frameCapacity: capacity))
        var pendingSource = [[Float]](repeating: [], count: channels)
        var pendingCopy = [[Float]](repeating: [], count: channels)
        var worst: Float = 0
        var peak: Float = 0
        var frames: Int64 = 0
        while source.framePosition < source.length || copy.framePosition < copy.length {
            if source.framePosition < source.length, pendingSource[0].count < Int(capacity) {
                try source.read(into: a, frameCount: capacity)
                for channel in 0..<channels {
                    pendingSource[channel] += UnsafeBufferPointer(start: a.floatChannelData![channel], count: Int(a.frameLength))
                }
            }
            if copy.framePosition < copy.length, pendingCopy[0].count < Int(capacity) {
                try copy.read(into: b, frameCount: capacity)
                for channel in 0..<channels {
                    pendingCopy[channel] += UnsafeBufferPointer(start: b.floatChannelData![channel], count: Int(b.frameLength))
                }
            }
            let ready = min(pendingSource[0].count, pendingCopy[0].count)
            if ready == 0, a.frameLength == 0, b.frameLength == 0 { break }
            for channel in 0..<channels {
                for index in 0..<ready {
                    let original = pendingSource[channel][index]
                    peak = max(peak, abs(original))
                    worst = max(worst, abs(pendingCopy[channel][index] - original * gain))
                }
                pendingSource[channel].removeFirst(ready)
                pendingCopy[channel].removeFirst(ready)
            }
            frames += Int64(ready)
        }
        XCTAssertEqual(pendingSource[0].count, 0, "frames left in the CAF")
        XCTAssertEqual(pendingCopy[0].count, 0, "frames left in the m4a")
        return (frames, worst, peak)
    }

    private func size(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func digests(of folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent(name))
            defer { try? handle.close() }
            var hash = SHA256()
            while try autoreleasepool(invoking: {
                guard let data = try handle.read(upToCount: 4 << 20), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }) {}
            result[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}
