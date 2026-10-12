import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Murmurly

/// Live check of the move on real volumes: for an exFAT and an APFS disk
/// image, the meetings folder is chosen on the image, the image is detached
/// (its `/Volumes/…` vanishes), a finished meeting is compressed and waits,
/// then the image is attached again and the real `didMountNotification` alone
/// gets the meeting moved. On exFAT macOS writes `._*` beside files with
/// extended attributes; the move must pass over them. Runs only with
/// MURMURLY_MOVE_GATE=1 (from xcodebuild as TEST_RUNNER_MURMURLY_MOVE_GATE):
/// it mounts volumes, so acceptance requires "Executed 1, 0 skipped".
@MainActor
final class MeetingMoveStageGateTests: XCTestCase {
    private var attached: [URL] = []

    override func tearDown() async throws {
        for mount in attached where FileManager.default.fileExists(atPath: mount.path) {
            _ = try? hdiutil(["detach", mount.path, "-force"])
        }
    }

    func testMeetingWaitsForItsVolumeAndMovesWhenItIsMounted() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MURMURLY_MOVE_GATE"] == "1" else {
            throw XCTSkip("MURMURLY_MOVE_GATE is not set: the live move check did not run")
        }
        let output = URL(
            fileURLWithPath: environment["MURMURLY_STAGE_GATE_OUTPUT"]
                ?? NSHomeDirectory() + "/Library/Caches/Murmurly/StageGate/Results",
            isDirectory: true
        ).appendingPathComponent("meeting-move-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-move-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var summary: [String: Any] = [:]
        for format in ["ExFAT", "APFS"] {
            summary[format] = try await check(format, work: work)
        }
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("summary.json"))
        print("MEETING-MOVE-GATE: \(String(decoding: json, as: UTF8.self))")
    }

    private func check(_ format: String, work: URL) async throws -> [String: Any] {
        // A short label: newfs refuses a long exFAT one, and hdiutil reports
        // that as "Operation not permitted".
        let volumeName = "M2b\(format.prefix(1))\(UUID().uuidString.prefix(4))"
        let image = work.appendingPathComponent("\(volumeName).sparseimage")
        _ = try hdiutil(["create", "-size", "64m", "-fs", format, "-volname", volumeName,
                         "-type", "SPARSE", image.deletingPathExtension().path])
        var mount = try attach(image)
        let target = mount.appendingPathComponent("Meetings", isDirectory: true)
        // The user creates and chooses this folder on the disk.
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        _ = try hdiutil(["detach", mount.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount.path), "\(format): /Volumes entry left after detach")

        let local = work.appendingPathComponent("\(format)-Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let folder = try finishedMeeting("2026-10-07 13-00-00 Meeting", in: local)

        let queue = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: LiveWhisperEngineFactory()),
                loadSpeechDetector: { throw CocoaError(.featureUnsupported) },
                currentEngine: { throw CocoaError(.featureUnsupported) }
            ),
            meetingsRoot: local,
            destinations: { .init(meetings: target, transcripts: nil) },
            fileViewer: { _ in }
        )
        queue.activate()
        let waited = await eventually(within: .seconds(60)) {
            queue.activeFolder == nil && queue.issues[folder.standardizedFileURL]?.move != nil
        }
        XCTAssertTrue(waited, "\(format): the meeting did not wait for its volume")
        let reason = queue.issues[folder.standardizedFileURL]?.lines ?? []
        XCTAssertEqual(reason, ["move: folder not available: \(target.path)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount.path), "\(format): the absent volume's path was created")
        let compressed = try digests(of: folder)
        XCTAssertEqual(Set(compressed.keys), ["metadata.json", "microphone.m4a", "system.m4a"])
        // An extended attribute, so exFAT gets an AppleDouble `._system.m4a`.
        // Set after compression, which rewrites metadata.json and the tracks.
        let value = Array("m2b".utf8)
        XCTAssertEqual(setxattr(folder.appendingPathComponent("system.m4a").path,
                                "io.github.spacevibes365.murmurly.gate", value, value.count, 0, 0), 0)

        let clock = ContinuousClock()
        let attachedAt = clock.now
        mount = try attach(image)
        let moved = await eventually(within: .seconds(60)) {
            !FileManager.default.fileExists(atPath: folder.path) && queue.activeFolder == nil
        }
        let movedAfter = attachedAt.duration(to: clock.now)
        XCTAssertTrue(moved, "\(format): the mount did not move the meeting")
        let place = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        let names = rawNames(in: place)
        var arrived = try digests(of: place)
        arrived = arrived.filter { !$0.key.hasPrefix("._") }
        XCTAssertEqual(arrived, compressed, "\(format): the moved folder differs")
        if format == "ExFAT" {
            XCTAssertTrue(names.contains("._system.m4a"), "exFAT wrote no AppleDouble file: \(names)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), [], "\(format): left behind")
        let targetNames = rawNames(in: target)
        XCTAssertFalse(targetNames.contains { $0.contains(MeetingStorage.movePartialMarker) }, "\(format): partial left")
        XCTAssertEqual(queue.issues, [:])
        _ = try hdiutil(["detach", mount.path])

        return [
            "volume": volumeName,
            "movedSecondsAfterAttach": Double(movedAfter.components.seconds)
                + Double(movedAfter.components.attoseconds) / 1e18,
            "waitingReason": reason,
            "namesOnTarget": names,
            "targetFolder": targetNames,
        ]
    }

    /// A folder as `SystemAudioCapture.stop` leaves it: two one-second CAF
    /// tracks of noise and the metadata naming them.
    private func finishedMeeting(_ name: String, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        var state: UInt32 = 7
        for index in 0..<48_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            buffer.floatChannelData![0][index] = (Float(state >> 8) / Float(1 << 24) * 2 - 1) * 0.4
        }
        for track in ["system.caf", "microphone.caf"] {
            let file = try AVAudioFile(
                forWriting: folder.appendingPathComponent(track), settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            try file.write(from: buffer)
        }
        let metadata = MeetingMetadata(
            startedAt: "2026-10-07T10:00:00Z", endedAt: "2026-10-07T10:00:01Z", sampleRate: 48_000, state: "done",
            segments: [.init(index: 0, system: "system.caf", mic: "microphone.caf", frames: 48_000, micFrames: 48_000)]
        )
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
        return folder
    }

    /// Every name as `readdir` gives it: FileManager's listings hide the
    /// `._*` files exFAT keeps for extended attributes.
    private func rawNames(in folder: URL) -> [String] {
        guard let directory = opendir(folder.path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private func attach(_ image: URL) throws -> URL {
        let plist = try hdiutil(["attach", image.path, "-plist"])
        let object = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        let entities = object?["system-entities"] as? [[String: Any]] ?? []
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: image.path])
        }
        let url = URL(fileURLWithPath: mount, isDirectory: true)
        attached.append(url)
        return url
    }

    @discardableResult
    private func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: "hdiutil \(arguments.joined(separator: " ")): \(process.terminationStatus) \(message)",
            ])
        }
        return data
    }

    private func digests(of folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            result[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func eventually(within limit: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
