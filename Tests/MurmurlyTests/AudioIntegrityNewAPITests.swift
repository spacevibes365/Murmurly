import Foundation
import XCTest
@testable import Murmurly

/// Hands out one folder per recording and finishes each stop as scripted.
private actor ScriptedMeetingCapture: MeetingCaptureBackend {
    enum Finish: Sendable {
        case done
        case suspect([String])
        case failed([String])
    }

    private let root: URL
    private var finishes: [Finish]
    private var directory: URL?

    init(root: URL, finishes: [Finish]) {
        self.root = root
        self.finishes = finishes
    }

    func start(in _: URL) async throws -> Date {
        let directory = root.appendingPathComponent("meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        return Date()
    }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        self.directory = nil
        let finish: Finish = finishes.isEmpty ? .done : finishes.removeFirst()
        switch finish {
        case .done:
            try write(state: "done", issues: nil, to: directory)
        case let .suspect(issues):
            try write(state: "suspect", issues: issues, to: directory)
        case let .failed(issues):
            try write(state: "failed", issues: issues, to: directory)
            throw SystemAudioCaptureError.captureFailed(message: issues.joined(separator: "; "), savedAt: directory)
        }
        return [directory.appendingPathComponent("system.caf")]
    }

    private func write(state: String, issues: [String]?, to directory: URL) throws {
        let metadata = MeetingMetadata(
            startedAt: "2026-10-02T10:00:00Z",
            endedAt: "2026-10-02T10:01:00Z",
            sampleRate: 48_000,
            state: state,
            segments: [],
            issues: issues
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
    }
}

@MainActor
final class AudioIntegrityNewAPITests: XCTestCase {
    func testOldMetadataStillDecodes() throws {
        let json = """
        {"startedAt":"2026-08-06T10:00:00Z","endedAt":"2026-08-06T10:01:00Z","sampleRate":48000,
         "state":"done","segments":[{"index":0,"system":"system.caf","mic":"microphone.caf","frames":48000}]}
        """
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.segments.first?.frames, 48_000)
        XCTAssertNil(metadata.segments.first?.micFrames)
        XCTAssertNil(metadata.segments.first?.enqueuedFrames)
        XCTAssertNil(metadata.issues)
    }

    func testUnmeasuredFramesAreOmittedAndFactsRoundTrip() throws {
        let metadata = MeetingMetadata(
            startedAt: "2026-10-02T10:00:00Z",
            endedAt: "2026-10-02T10:01:00Z",
            sampleRate: 48_000,
            state: "failed",
            segments: [
                .init(
                    index: 0,
                    system: "system.caf",
                    mic: "microphone.caf",
                    frames: nil,
                    micFrames: 24_000,
                    enqueuedFrames: 48_000
                ),
            ],
            issues: ["system.caf can’t be read"]
        )
        let data = try JSONEncoder().encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segment = try XCTUnwrap((json["segments"] as? [[String: Any]])?.first)

        XCTAssertNil(segment["frames"], "an unmeasured track must not look measured")
        XCTAssertEqual(segment["micFrames"] as? Int, 24_000)
        XCTAssertEqual(segment["enqueuedFrames"] as? Int, 48_000)
        XCTAssertEqual(json["issues"] as? [String], ["system.caf can’t be read"])
        XCTAssertEqual(try JSONDecoder().decode(MeetingMetadata.self, from: data), metadata)
    }

    func testWarningStaysWithItsFolderAfterACleanRecording() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-warning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ScriptedMeetingCapture(
            root: root,
            finishes: [
                .failed(["microphone.caf can’t be read"]),
                .done,
                .suspect(["system.caf: 1,024 of 48,000 accepted frames written"]),
            ]
        )
        let recorder = MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )

        try await record(with: recorder)
        let first = try XCTUnwrap(recorder.recordingWarning)
        XCTAssertEqual(first.issues, ["microphone.caf can’t be read"])

        try await record(with: recorder)
        XCTAssertEqual(recorder.recordingWarning, first, "a clean recording must not clear or relabel the warning")

        try await record(with: recorder)
        let third = try XCTUnwrap(recorder.recordingWarning)
        XCTAssertNotEqual(third.directory, first.directory, "a newer problem replaces the warning with its own folder")
        XCTAssertEqual(third.issues, ["system.caf: 1,024 of 48,000 accepted frames written"])

        recorder.dismissRecordingWarning()
        XCTAssertNil(recorder.recordingWarning)
    }

    private func record(with recorder: MeetingRecorder) async throws {
        recorder.toggle()
        try await waitForDictation { recorder.state == .recording }
        recorder.toggle()
        try await waitForDictation { recorder.state != .stopping && recorder.state != .recording }
    }
}
