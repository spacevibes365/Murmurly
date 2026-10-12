import AVFoundation
import XCTest
@testable import Murmurly

/// Tracks and metadata as `SystemAudioCapture` leaves them, and the in-between
/// states a killed run leaves behind. Everything is read back from disk.
final class MeetingStorageTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Compression

    func testBothTracksBecomeCheckedALACAndTheGainIsRecorded() async throws {
        var microphone = MeetingAudio.noise(count: 48_000, amplitude: 0.5, seed: 1)
        microphone[1_000] = 1.6
        microphone[30_000] = -1.2
        let system = MeetingAudio.noise(count: 48_000, amplitude: 0.9, seed: 2)
        let folder = try MeetingAudio.folder("2026-10-06 10-00-00 Meeting", in: root, microphone: [microphone], system: [system])

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.compressed, ["microphone.caf", "system.caf"])
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a"])
        let metadata = try JSONDecoder().decode(
            MeetingMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(metadata.segments.first?.mic, "microphone.m4a")
        XCTAssertEqual(metadata.segments.first?.system, "system.m4a")
        XCTAssertNil(metadata.segments.first?.systemGain, "a track already in range is not scaled")
        let gain = try XCTUnwrap(metadata.segments.first?.micGain.map { Float($0) })
        XCTAssertLessThanOrEqual(1.6 * gain, 1)
        XCTAssertEqual(gain, 1 / 1.6, accuracy: 1e-6)
        // Everything else the stop wrote is still there.
        XCTAssertEqual(metadata.state, "done")
        XCTAssertEqual(metadata.endedAt, "2026-10-06T10:01:00Z")
        XCTAssertEqual(metadata.trigger, "us.zoom.xos")
        XCTAssertEqual(metadata.segments.first?.frames, 48_000)

        let format = try MeetingAudio.dataFormat(of: folder.appendingPathComponent("microphone.m4a"))
        XCTAssertEqual(format.mFormatID, kAudioFormatAppleLossless)
        XCTAssertEqual(format.mFormatFlags, kAppleLosslessFormatFlag_24BitSourceData)
        XCTAssertEqual(format.mSampleRate, 48_000)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: gain)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("system.m4a"), equals: [system], gain: 1)

        let inspected = try MeetingTranscriber.Folder.inspect(folder)
        XCTAssertEqual(inspected.microphone?.lastPathComponent, "microphone.m4a")
        XCTAssertEqual(inspected.microphoneGain, gain)
        XCTAssertEqual(inspected.systemGain, 1)
    }

    /// July recordings: no `endedAt` (so `MeetingMetadata` cannot read them),
    /// `frames` from the old write-queue count and a microphone of another
    /// length, no `micFrames`.
    func testJulyMetadataWithoutEndedAtIsCompressedWithEveryKeyKept() async throws {
        let folder = root.appendingPathComponent("2026-07-14 19-40-35 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let microphone = MeetingAudio.noise(count: 47_000, amplitude: 0.3, seed: 3)
        let system = MeetingAudio.noise(count: 48_000, amplitude: 0.3, seed: 4)
        try MeetingAudio.write([microphone], to: folder.appendingPathComponent("microphone.caf"))
        try MeetingAudio.write([system], to: folder.appendingPathComponent("system.caf"))
        let july = """
        {"sampleRate":48000,"segments":[{"frames":48000,"index":0,"mic":"microphone.caf","system":"system.caf"}],\
        "startedAt":"2026-07-14T16:40:37Z","state":"done"}
        """
        try Data(july.utf8).write(to: folder.appendingPathComponent("metadata.json"))

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        ) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sampleRate", "segments", "startedAt", "state"])
        XCTAssertEqual(object["startedAt"] as? String, "2026-07-14T16:40:37Z")
        XCTAssertEqual(object["sampleRate"] as? Int, 48_000)
        let segment = try XCTUnwrap((object["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(segment.keys), ["frames", "index", "mic", "system"])
        XCTAssertEqual(segment["frames"] as? Int, 48_000)
        XCTAssertEqual(segment["mic"] as? String, "microphone.m4a")
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: 1)
        // M1 still reads it.
        let inspected = try MeetingTranscriber.Folder.inspect(folder)
        XCTAssertEqual(inspected.system?.lastPathComponent, "system.m4a")
    }

    /// The gain is plain 1/peak: rounded to nearest, peak × (1/peak) never
    /// exceeds 1 for a normal float, so no scaled sample passes full scale.
    /// The sweep pins that property; the folder shows the top of the range.
    func testPeaksUpToSixteenFitAfterScalingAndAboveAreKept() async throws {
        var state: UInt32 = 1
        for index in 0..<1_000_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let peak = index < 16 ? Float(index + 1) : 1 + 15 * Float(state >> 8 | 1) / Float(1 << 24)
            XCTAssertLessThanOrEqual(peak * (1 / peak), 1, "peak \(peak)")
        }
        var top = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 5)
        top[12_000] = MeetingStorage.maximumPeak
        var over = top
        over[12_000] = MeetingStorage.maximumPeak.nextUp
        let folder = try MeetingAudio.folder("2026-10-06 11-00-00 Meeting", in: root, microphone: [top], system: [over])

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.compressed, ["microphone.caf"])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].hasPrefix("others: peak ×16"), result.issues[0])
        XCTAssertEqual(try MeetingTranscriber.Folder.inspect(folder).microphoneGain, 1 / 16)
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [top], gain: 1 / 16)
    }

    func testGlitchPeakAndNonFiniteSamplesKeepTheCAF() async throws {
        var glitch = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 6)
        glitch[100] = 20
        var broken = MeetingAudio.noise(count: 24_000, amplitude: 0.4, seed: 7)
        broken[23_999] = .nan
        let folder = try MeetingAudio.folder("2026-10-06 12-00-00 Meeting", in: root, microphone: [glitch], system: [broken])
        let before = try Data(contentsOf: folder.appendingPathComponent("microphone.caf"))

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.compressed, [])
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(result.issues[0].hasPrefix("microphone: peak ×20"), result.issues[0])
        XCTAssertTrue(result.issues[0].contains("audio glitch"), result.issues[0])
        XCTAssertTrue(result.issues[1].hasPrefix("others: samples that are not numbers"), result.issues[1])
        XCTAssertTrue(result.issues.allSatisfy { $0.hasSuffix("kept as CAF") })
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.caf", "system.caf"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("microphone.caf")), before)
        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: root, moving: false).map(\.lastPathComponent),
            [folder.lastPathComponent],
            "tried again by the next scan"
        )
    }

    func testStereoMicrophoneKeepsBothChannels() async throws {
        let left = MeetingAudio.noise(count: 30_000, amplitude: 0.5, seed: 8)
        var right = MeetingAudio.noise(count: 30_000, amplitude: 0.2, seed: 9)
        right[7] = 1.3
        let system = MeetingAudio.noise(count: 30_000, amplitude: 0.5, seed: 10)
        let folder = try MeetingAudio.folder("2026-10-06 13-00-00 Meeting", in: root, microphone: [left, right], system: [system])

        let result = await MeetingStorage.compress(folder)

        XCTAssertEqual(result.issues, [])
        let microphone = folder.appendingPathComponent("microphone.m4a")
        XCTAssertEqual(try MeetingAudio.dataFormat(of: microphone).mChannelsPerFrame, 2)
        let gain = try XCTUnwrap(MeetingTranscriber.Folder.inspect(folder).microphoneGain)
        XCTAssertLessThan(gain, 1)
        try MeetingAudio.assertDecoded(microphone, equals: [left, right], gain: gain)
    }

    /// The check is what lets the CAF go, so it is tested on its own: one
    /// 24-bit step passes (a full-scale +1.0 is stored as 8388607), two steps
    /// or a missing frame do not.
    func testCheckAcceptsOneStepAndRejectsTwoStepsOrAShorterFile() throws {
        var samples = MeetingAudio.noise(count: 20_000, amplitude: 0.5, seed: 11)
        samples[500] = 1
        samples[501] = -1
        let source = root.appendingPathComponent("source.caf")
        try MeetingAudio.write([samples], to: source)
        let m4a = root.appendingPathComponent("copy.m4a")
        try DictationHistoryStore.encodeAppleLossless(from: source, to: m4a)

        XCTAssertNoThrow(try MeetingStorage.verify(m4a, against: source, gain: 1))

        var changed = samples
        changed[9_000] += 2 * MeetingStorage.tolerance
        let other = root.appendingPathComponent("changed.caf")
        try MeetingAudio.write([changed], to: other)
        XCTAssertThrowsError(try MeetingStorage.verify(m4a, against: other, gain: 1)) {
            XCTAssertEqual($0 as? MeetingStorage.Rejection, .mismatch("frame 9,000, channel 1"))
        }

        let shorter = root.appendingPathComponent("shorter.caf")
        try MeetingAudio.write([Array(samples.dropLast(10))], to: shorter)
        XCTAssertThrowsError(try MeetingStorage.verify(m4a, against: shorter, gain: 1)) {
            XCTAssertEqual($0 as? MeetingStorage.Rejection, .mismatch("20,000 frames instead of 19,990"))
        }
    }

    // MARK: - Recovery from the files alone

    func testKilledRunsAreFinishedFromTheFilesAlone() async throws {
        let microphone = MeetingAudio.noise(count: 24_000, amplitude: 0.5, seed: 12)
        let system = MeetingAudio.noise(count: 24_000, amplitude: 0.5, seed: 13)

        // Killed while writing: a hidden partial.
        let writing = try MeetingAudio.folder("2026-10-06 14-00-01 Meeting", in: root, microphone: [microphone], system: [system])
        try Data("half".utf8).write(to: writing.appendingPathComponent(".microphone.partial.m4a"))
        // Killed after the rename, before the commit: an m4a the metadata does not name.
        let renamed = try MeetingAudio.folder("2026-10-06 14-00-02 Meeting", in: root, microphone: [microphone], system: [system])
        try Data("not audio".utf8).write(to: renamed.appendingPathComponent("microphone.m4a"))
        // Killed after the commit, before the CAF was removed.
        let committed = try MeetingAudio.folder("2026-10-06 14-00-03 Meeting", in: root, microphone: [microphone], system: [system])
        _ = await MeetingStorage.compress(committed)
        try MeetingAudio.write([microphone], to: committed.appendingPathComponent("microphone.caf"))
        let committedM4A = try Data(contentsOf: committed.appendingPathComponent("microphone.m4a"))
        // Someone else's files are not ours to remove.
        for name in ["notes.m4a", ".other.m4a", "talk.partial.m4a"] {
            try Data(name.utf8).write(to: renamed.appendingPathComponent(name))
        }

        for folder in [writing, renamed, committed] {
            let result = await MeetingStorage.compress(folder)
            XCTAssertEqual(result.issues, [], folder.lastPathComponent)
        }

        XCTAssertEqual(try names(in: writing), ["metadata.json", "microphone.m4a", "system.m4a"])
        XCTAssertEqual(
            try names(in: renamed),
            [".other.m4a", "metadata.json", "microphone.m4a", "notes.m4a", "system.m4a", "talk.partial.m4a"]
        )
        XCTAssertEqual(try names(in: committed), ["metadata.json", "microphone.m4a", "system.m4a"])
        XCTAssertEqual(try Data(contentsOf: committed.appendingPathComponent("microphone.m4a")), committedM4A)
        for folder in [writing, renamed, committed] {
            try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: 1)
        }
        XCTAssertEqual(MeetingStorage.foldersNeedingWork(in: root, moving: false), [])
    }

    /// The CAF goes only after the metadata names the m4a: when the commit
    /// fails (here metadata.json cannot be replaced), the CAF is still there
    /// and the metadata still names it; the next run finishes the job.
    func testFailedCommitKeepsTheCAF() async throws {
        let microphone = MeetingAudio.noise(count: 24_000, amplitude: 0.5, seed: 15)
        let folder = try MeetingAudio.folder("2026-10-06 14-30-00 Meeting", in: root, microphone: [microphone], system: [microphone])
        let metadata = folder.appendingPathComponent("metadata.json")
        let original = try Data(contentsOf: metadata)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: metadata.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadata.path) }

        let failed = await MeetingStorage.compress(folder)

        XCTAssertEqual(failed.compressed, [])
        XCTAssertEqual(failed.issues.count, 2)
        XCTAssertTrue(failed.issues.allSatisfy { $0.contains("couldn’t compress") }, "\(failed.issues)")
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("microphone.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadata.path)
        let finished = await MeetingStorage.compress(folder)

        XCTAssertEqual(finished.issues, [])
        XCTAssertEqual(try names(in: folder), ["metadata.json", "microphone.m4a", "system.m4a"])
        try MeetingAudio.assertDecoded(folder.appendingPathComponent("microphone.m4a"), equals: [microphone], gain: 1)
    }

    // MARK: - Which folders

    /// `metadata.json` is written only by a finished stop, so a folder without
    /// it is a recording in progress (or cut off by a crash) and stays as is.
    func testOnlyFinishedFoldersWithACAFTrackAreFound() async throws {
        let samples = [MeetingAudio.noise(count: 4_800, amplitude: 0.5, seed: 14)]
        let recording = root.appendingPathComponent("2026-10-06 15-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try MeetingAudio.write(samples, to: recording.appendingPathComponent("system.caf"))
        try MeetingAudio.write(samples, to: recording.appendingPathComponent("microphone.caf"))
        let unknownState = try MeetingAudio.folder("2026-10-06 15-00-01 Meeting", in: root, microphone: samples, system: samples, state: "recording")
        let suspect = try MeetingAudio.folder("2026-10-06 15-00-02 Meeting", in: root, microphone: samples, system: samples, state: "suspect")
        let failed = try MeetingAudio.folder("2026-10-06 15-00-03 Meeting", in: root, microphone: samples, system: samples, state: "failed")
        let done = try MeetingAudio.folder("2026-10-06 15-00-04 Meeting", in: root, microphone: samples, system: samples)
        let compressed = try MeetingAudio.folder("2026-10-06 15-00-05 Meeting", in: root, microphone: samples, system: samples)
        _ = await MeetingStorage.compress(compressed)
        _ = try MeetingAudio.folder(".hidden", in: root, microphone: samples, system: samples)
        let before = try MeetingAudio.digests(of: recording)

        XCTAssertEqual(
            MeetingStorage.foldersNeedingWork(in: root, moving: false).map(\.lastPathComponent),
            [suspect, failed, done].map(\.lastPathComponent)
        )
        XCTAssertEqual(MeetingStorage.foldersNeedingWork(in: root.appendingPathComponent("absent"), moving: false), [])

        for folder in [recording, unknownState] {
            let result = await MeetingStorage.compress(folder)
            XCTAssertEqual(result, MeetingStorage.Result())
        }
        XCTAssertEqual(try MeetingAudio.digests(of: recording), before)
        XCTAssertEqual(try names(in: unknownState), ["metadata.json", "microphone.caf", "system.caf"])
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

// MARK: - Fixtures shared with the queue tests

enum MeetingAudio {
    /// Deterministic noise, so a failure can be reproduced sample for sample.
    static func noise(count: Int, amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed &* 2_654_435_761 | 1
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    /// A finished meeting folder as `SystemAudioCapture.stop` writes it.
    static func folder(
        _ name: String,
        in root: URL,
        microphone: [[Float]],
        system: [[Float]],
        state: String = "done",
        rate: Double = 48_000
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(microphone, to: folder.appendingPathComponent("microphone.caf"), rate: rate)
        try write(system, to: folder.appendingPathComponent("system.caf"), rate: rate)
        let metadata = MeetingMetadata(
            startedAt: "2026-10-06T10:00:00Z",
            endedAt: "2026-10-06T10:01:00Z",
            sampleRate: rate,
            state: state,
            segments: [.init(
                index: 0,
                system: "system.caf",
                mic: "microphone.caf",
                frames: Int64(system[0].count),
                micFrames: Int64(microphone[0].count),
                enqueuedFrames: Int64(system[0].count)
            )],
            trigger: "us.zoom.xos"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
        return folder
    }

    static func write(_ channels: [[Float]], to url: URL, rate: Double = 48_000) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
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
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Reads to the end in a loop: a single read may stop short.
    static func decode(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 4_096)
            guard buffer.frameLength > 0 else { break }
            for index in channels.indices {
                channels[index] += UnsafeBufferPointer(start: buffer.floatChannelData![index], count: Int(buffer.frameLength))
            }
        }
        return channels
    }

    /// Every decoded sample within one 24-bit step of the original × gain.
    static func assertDecoded(
        _ url: URL,
        equals channels: [[Float]],
        gain: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decoded = try decode(url)
        XCTAssertEqual(decoded.count, channels.count, "channels", file: file, line: line)
        for (got, expected) in zip(decoded, channels) {
            XCTAssertEqual(got.count, expected.count, "frames", file: file, line: line)
            let worst = zip(got, expected).map { abs($0 - $1 * gain) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, MeetingStorage.tolerance, "worst difference", file: file, line: line)
        }
    }

    /// The description is copied while its format is alive: it points into it.
    static func dataFormat(of url: URL) throws -> AudioStreamBasicDescription {
        let format = try AVAudioFile(forReading: url).fileFormat
        return withExtendedLifetime(format) { format.streamDescription.pointee }
    }

    static func digests(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return result
    }
}
