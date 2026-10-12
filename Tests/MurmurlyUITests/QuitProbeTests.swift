import XCTest

/// Real-process quit checks through the app's DEBUG quit probe. Each test
/// first proves from `ready.json` that quit caught a live recording, and only
/// then judges what reached the disk after the process exited. The probe file
/// is identical on the tree before the quit fix, so the same tests show the red there.
@MainActor
final class QuitProbeTests: XCTestCase {
    func testQuitDuringDictationRecordingSavesAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let ready = launchProbe("dictation-recording", root: root) else { return }
        XCTAssertEqual(ready["dictationState"] as? String, "recording")

        try assertSkippedDictationSaved(in: root)
    }

    func testQuitDuringRecognitionDoesNotWaitForModel() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let ready = launchProbe("dictation-recognizing", root: root) else { return }
        XCTAssertEqual(ready["dictationState"] as? String, "transcribing")
        XCTAssertEqual(ready["engineCalled"] as? Bool, true, "the model must already be busy")

        // The probe's model never answers, so an exit at all proves quit did
        // not wait for it.
        try assertSkippedDictationSaved(in: root)
    }

    /// The recording would be transcribed after it stops, which quit never
    /// queues: the first quit only warns and the recording goes on; the
    /// probe quits again, and that one stops and saves it.
    func testQuitDuringMeetingRecordingWarnsFirstThenWritesMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let ready = launchProbe("meeting-recording", root: root) else { return }
        XCTAssertEqual(ready["meetingState"] as? String, "recording")
        let final = try readyMarker(in: root)
        XCTAssertEqual(
            final["meetingStateAfterFirstQuit"] as? String,
            "recording",
            "the first quit must warn and leave the recording running"
        )

        let metadata = root.appendingPathComponent("Meetings/probe/metadata.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metadata.path),
            "quit must stop the meeting so its metadata is written"
        )
    }

    func testSIGTERMDuringDictationRecordingSavesAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let ready = launchProbe("dictation-recording", root: root, viaSignal: true) else { return }
        XCTAssertEqual(ready["dictationState"] as? String, "recording")

        try assertSkippedDictationSaved(in: root)
    }

    /// Launches the probe and waits for it to quit on its own. Returns the
    /// ready marker, or nil after failing the run as inconclusive.
    private func launchProbe(
        _ scenario: String,
        root: URL,
        viaSignal: Bool = false
    ) -> [String: Any]? {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITesting", "-UITestSettingsStore",
            "-QuitProbe", scenario,
            "-QuitProbeRoot", root.path,
        ] + (viaSignal ? ["-QuitProbeTrigger", "signal"] : []) + AppLanguage.launchArguments
        app.launch()

        let readyURL = root.appendingPathComponent("ready.json")
        let readyDeadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let data = try? Data(contentsOf: readyURL),
              let ready = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("the probe did not write ready.json — the check proves nothing")
            app.terminate()
            return nil
        }
        guard ready["reached"] as? Bool == true else {
            XCTFail("the probe did not reach the needed stage: \(ready) — the check proves nothing")
            app.terminate()
            return nil
        }
        // The test's own deadline, longer than the app's 20 s quit deadline.
        guard app.wait(for: .notRunning, timeout: 45) else {
            XCTFail("the app did not quit within 45 s of the quit request")
            app.terminate()
            return nil
        }
        return ready
    }

    /// The marker as the probe left it at exit.
    private func readyMarker(in root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("ready.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertSkippedDictationSaved(in root: URL) throws {
        let dictations = root.appendingPathComponent("Dictations", isDirectory: true)
        let history = dictations.appendingPathComponent("history.jsonl")
        let lines = (try? Data(contentsOf: history))?.split(separator: 0x0A) ?? []
        XCTAssertEqual(lines.count, 1, "after quitting the history must hold exactly one entry")
        guard let first = lines.first else { return }
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first)) as? [String: Any])
        XCTAssertEqual(line["recognition_skipped"] as? Bool, true)
        let audioPath = try XCTUnwrap(line["audio_path"] as? String)
        XCTAssertEqual((audioPath as NSString).pathExtension, "caf", "quit saves the raw source")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dictations.appendingPathComponent(audioPath).path)
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
