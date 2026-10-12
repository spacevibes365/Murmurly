import AppKit
import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

private actor AudioFileMic: MicCapturing {
    private var url: URL?

    init(url: URL) {
        self.url = url
    }

    func start() async throws {}

    func stop() async throws -> URL? {
        defer { url = nil }
        return url
    }
}

/// Real, local Stage 1 audio gate. This target is intentionally excluded from
/// the normal `Murmurly` scheme because it loads real models and uses TCC.
@MainActor
final class RealAudioStageGateTests: XCTestCase {
    private let defaults = Defaults()

    func testRealDictationUsesPersistentModelPath() async throws {
        let source = URL(fileURLWithPath: defaults.monologue)
        try requireFile(source, label: "known Russian dictation source")
        let temporaryAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try FileManager.default.copyItem(at: source, to: temporaryAudio)
        defer { try? FileManager.default.removeItem(at: temporaryAudio) }

        let settings = SettingsStore()
        XCTAssertTrue(ModelDownloader().isReady(.whisper))
        XCTAssertEqual(settings.snapshot.whisperModelPath, defaults.model)
        let coordinator = DictationCoordinator(
            mic: AudioFileMic(url: temporaryAudio),
            indicator: RecordingIndicator(renderingEnabled: false),
            startTimeout: 2,
            maxRecordingSeconds: 60
        )
        coordinator.configureForTesting(settings: settings)
        coordinator.beginCaptureForTesting()
        for _ in 0..<100 where coordinator.state != .recording {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.state, .recording)

        coordinator.toggle()
        for _ in 0..<3_000 where coordinator.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.state, .idle)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("грамот")
                || text.localizedCaseInsensitiveContains("ликвидац"),
            "Real dictation did not deliver the known Russian speech: \(text)"
        )
    }

    func testLiveMeetingCaptureRecordsKnownSystemSpeech() async throws {
        XCTAssertEqual(
            AVCaptureDevice.authorizationStatus(for: .audio),
            .authorized,
            "The stable local signing identity must retain microphone authorization"
        )
        let source = URL(fileURLWithPath: defaults.monologue)
        try requireFile(source, label: "known Russian playback source")

        let capture = SystemAudioCapture()
        _ = try await capture.start()
        let tracks: [URL]
        do {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-t", "12", source.path]
            try player.run()
            player.waitUntilExit()
            XCTAssertEqual(player.terminationStatus, 0)
            try await Task.sleep(for: .milliseconds(300))
            tracks = try await capture.stop()
        } catch {
            _ = try? await capture.stop()
            throw error
        }

        let systemURL = try XCTUnwrap(tracks.first { $0.lastPathComponent == "system.caf" })
        let microphoneURL = try XCTUnwrap(
            tracks.first { $0.lastPathComponent == "microphone.caf" }
        )
        for track in [systemURL, microphoneURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: track.path)
            let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(bytes, 100_000, "Meeting track is unexpectedly empty: \(track.path)")
        }

        let segments = try await whisperSegments(systemURL, model: defaults.model, language: "ru")
        let text = segments.map(\.text).joined(separator: " ")
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("грамот")
                || text.localizedCaseInsensitiveContains("ликвидац"),
            "Live system track does not contain the known Russian speech: \(text)"
        )

        let attachment = XCTAttachment(string: text)
        attachment.name = "LIVE-MEETING-SYSTEM-TRANSCRIPT.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecordedMeetingTracksContainRecognizableSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        let systemURL: URL
        let microphoneURL: URL
        if let systemPath = environment["MURMURLY_MEETING_SYSTEM_AUDIO"],
           let microphonePath = environment["MURMURLY_MEETING_MIC_AUDIO"] {
            systemURL = URL(fileURLWithPath: systemPath)
            microphoneURL = URL(fileURLWithPath: microphonePath)
        } else {
            (systemURL, microphoneURL) = try latestMeetingTracks()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))

        let systemSegments = try await whisperSegments(
            systemURL, model: SettingsStore.defaultWhisperModel, language: nil
        )
        let systemText = systemSegments.map(\.text).joined(separator: " ")

        XCTAssertFalse(systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(
            systemText.localizedCaseInsensitiveContains("систем")
                || systemText.localizedCaseInsensitiveContains("собесед")
                || systemText.localizedCaseInsensitiveContains("грамот")
                || systemText.localizedCaseInsensitiveContains("ликвидац"),
            "System track transcript does not contain the phrase played through macOS: \(systemText)"
        )
        let microphoneFile = try AVAudioFile(forReading: microphoneURL)
        XCTAssertGreaterThan(microphoneFile.length, 0, "Microphone track contains no PCM frames")

        let report = """
        # Real meeting capture transcript

        ## System track

        \(systemText)

        Microphone PCM frames: \(microphoneFile.length)
        """
        let attachment = XCTAttachment(string: report)
        attachment.name = "MEETING-CAPTURE-TRANSCRIPT.md"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func latestMeetingTracks() throws -> (system: URL, microphone: URL) {
        let root = RecordingsStore.meetingsRoot()
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let directory = directories.first else {
            throw GateError.missing("completed meeting recording in \(root.path)")
        }
        let system = directory.appendingPathComponent("system.caf")
        let microphone = directory.appendingPathComponent("microphone.caf")
        try requireFile(system, label: "meeting system track")
        try requireFile(microphone, label: "meeting microphone track")
        return (system, microphone)
    }

    /// The app as shipped, not an isolated test copy: the scheme's
    /// MURMURLY_PRODUCTION_SERVICES=1 keeps the real hotkeys, process
    /// snapshot, archives and log, and this gate fails if that ever stops.
    func testProductionColdLaunchIsMenuBarOnly() async throws {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-UITesting"))
        XCTAssertFalse(TestIsolation.isEnabled, "Stage gate must launch the app as shipped, not isolated")
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertFalse(
            NSApp.windows.contains { $0.isVisible && AppWindowController.isRealWindow($0) },
            "Production cold launch unexpectedly presented a main/settings window"
        )

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmurly", isDirectory: true)
        XCTAssertEqual(AppLog.fileURL, library.appendingPathComponent("Logs/Murmurly/murmurly.log"))
        XCTAssertEqual(
            DictationHistoryStore.defaultRoot(),
            support.appendingPathComponent("Dictations", isDirectory: true)
        )
        XCTAssertEqual(RecordingsStore.meetingsRoot(), support.appendingPathComponent("Meetings", isDirectory: true))
        XCTAssertNotNil(MeetingWatchdog.readSystemSnapshot(), "Production watchdog must read real processes")

        // The menu-bar label's launch task registers the dictation and meeting
        // hotkeys with the system; it may still be running when the test starts.
        for _ in 0..<500 where HotkeyManager.systemRegistrationsForTesting < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(
            HotkeyManager.systemRegistrationsForTesting, 2,
            "Production launch did not register its global hotkeys"
        )
    }

    func testCurrentTCCStatusAndAuthorizedMicrophoneCapture() async throws {
        let paths = try resolvePaths()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micStatusText: String = switch micStatus {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown(\(micStatus.rawValue))"
        }
        let axTrusted = AccessibilityAuthorization.isTrusted
        var captureResult = "not run (microphone status is \(micStatusText))"

        if micStatus == .authorized {
            let capture = MicCapture(levelMeter: MicrophoneLevelMeter())
            try await capture.start()
            try await Task.sleep(for: .seconds(1))
            let possibleURL = try await capture.stop()
            let url = try XCTUnwrap(possibleURL, "Authorized capture returned no CAF")
            defer { try? FileManager.default.removeItem(at: url) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 0, "Authorized microphone capture wrote an empty CAF")
            captureResult = "passed (\(size) bytes in one second)"
        }

        let report = """
        # Current Murmurly TCC status

        - Microphone: `\(micStatusText)`
        - Accessibility trusted: `\(axTrusted)`
        - Authorized microphone capture: \(captureResult)

        Reading status never triggers a TCC prompt. Missing permissions still require
        the explicit buttons in Murmurly and confirmation in System Settings.
        """
        let reportURL = paths.outputDirectory.appendingPathComponent("TCC-STATUS.md")
        try FileManager.default.createDirectory(
            at: paths.outputDirectory,
            withIntermediateDirectories: true
        )
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: report)
        attachment.name = "TCC-STATUS.md"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRealWhisperLoadCancellation() async throws {
        let paths = try resolvePaths()
        let cache = WhisperKitCache(factory: LiveWhisperEngineFactory())
        let task = Task {
            try await self.whisperSegments(paths.monologue, model: paths.model.path, cache: cache)
        }

        try await Task.sleep(for: .milliseconds(10))
        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled real model load must not start decode")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(
            cancelStart.duration(to: .now),
            .seconds(5),
            "Cancelling model load took too long"
        )
    }

    func testRealWhisperDecodeCancellation() async throws {
        let paths = try resolvePaths()
        let cache = WhisperKitCache(factory: LiveWhisperEngineFactory())
        _ = try await whisperSegments(paths.monologue, model: paths.model.path, cache: cache)

        let task = Task {
            try await self.whisperSegments(paths.dialogue, model: paths.model.path, cache: cache)
        }
        try await Task.sleep(for: .milliseconds(200))
        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled real decode must throw CancellationError")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(
            cancelStart.duration(to: .now),
            .seconds(5),
            "Cancelling real decode took too long"
        )
    }

    func testRealWhisperTranscribesMonologueAndDialogue() async throws {
        let paths = try resolvePaths()
        try FileManager.default.createDirectory(
            at: paths.outputDirectory,
            withIntermediateDirectories: true
        )

        let clock = ContinuousClock()

        let monoStart = clock.now
        let monoSegments = try await whisperSegments(paths.monologue, model: paths.model.path)
        let monoElapsed = monoStart.duration(to: clock.now)
        let monoText = monoSegments.map(\.text).joined(separator: " ")
        XCTAssertFalse(monoSegments.isEmpty, "large-v3 returned no monologue segments")
        XCTAssertGreaterThan(monoText.count, 100, "Monologue transcript is unexpectedly short")
        XCTAssertTrue(
            monoText.localizedCaseInsensitiveContains("грамот")
                || monoText.localizedCaseInsensitiveContains("ликвидац"),
            "Monologue transcript does not resemble the selected Russian source"
        )

        let dialogueStart = clock.now
        let dialogueSegments = try await whisperSegments(paths.dialogue, model: paths.model.path)
        let whisperDialogueElapsed = dialogueStart.duration(to: clock.now)
        let dialogueText = dialogueSegments.map(\.text).joined(separator: " ")
        XCTAssertFalse(dialogueSegments.isEmpty, "large-v3 returned no dialogue segments")
        XCTAssertGreaterThan(dialogueText.count, 300, "Dialogue transcript is unexpectedly short")

        let monoMarkdown = render(monoSegments)
        let dialogueMarkdown = render(dialogueSegments)
        let report = """
        # Murmurly real-audio stage gate

        - Model: `\(paths.model.path)`
        - Monologue: `\(paths.monologue.path)`
        - Dialogue: `\(paths.dialogue.path)`
        - Monologue Whisper time: \(monoElapsed)
        - Dialogue Whisper time: \(whisperDialogueElapsed)
        - Monologue Whisper segments: \(monoSegments.count)
        - Dialogue Whisper segments: \(dialogueSegments.count)

        ## Monologue transcript

        \(monoMarkdown)

        ## Dialogue transcript

        \(dialogueMarkdown)
        """

        try monoMarkdown.write(
            to: paths.outputDirectory.appendingPathComponent("monologue-transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        try dialogueMarkdown.write(
            to: paths.outputDirectory.appendingPathComponent("dialogue-transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        try report.write(
            to: paths.outputDirectory.appendingPathComponent("REAL-AUDIO-RESULT.md"),
            atomically: true,
            encoding: .utf8
        )

        let attachment = XCTAttachment(string: report)
        attachment.name = "REAL-AUDIO-RESULT.md"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The file tab's own path: the meeting pipeline on one file with the
    /// shipped VAD and each engine. Nothing may appear next to the file.
    func testFilesTabTranscribesMonologueWithEitherEngine() async throws {
        let paths = try resolvePaths()
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("files-gate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let file = folder.appendingPathComponent(paths.monologue.lastPathComponent)
        try fileManager.copyItem(at: paths.monologue, to: file)

        for engine in DictationEngine.allCases {
            let choice = try MeetingTranscriber.Engine.forMeeting(
                SettingsSnapshot(dictationLanguage: "auto", dictationEngine: engine)
            )
            let transcriber = MeetingTranscriber(
                cache: WhisperKitCache(factory: LiveWhisperEngineFactory(), parakeetFactory: LiveParakeetEngineFactory()),
                loadSpeechDetector: {
                    try await MeetingTranscriber.sileroDetector(modelPath: MeetingTranscriber.vadModelPath)
                },
                currentEngine: { choice }
            )
            let lines = try await transcriber.transcribeFile(file) { _ in }
            let text = lines.map(\.text).joined(separator: " ")
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("грамот")
                    || text.localizedCaseInsensitiveContains("ликвидац"),
                "\(engine.rawValue): the file transcript does not resemble the source: \(text)"
            )
            XCTAssertTrue(lines.allSatisfy { $0.end - $0.start <= MeetingTranscriber.maximumBlockSeconds }, "a block without a timecode for over a minute")
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: folder.path), [file.lastPathComponent])
        }
    }

    /// Whole-file Whisper through the app's engine cache, as this gate has
    /// always measured it.
    private func whisperSegments(
        _ url: URL,
        model: String,
        language: String? = "ru",
        cache: WhisperKitCache = .shared
    ) async throws -> [TranscriptSegment] {
        try await cache.transcribe(
            audioPath: url.path,
            modelFolder: model,
            request: WhisperDecodeRequest(language: language)
        ).segments.map { TranscriptSegment(speaker: "", text: $0.text, start: $0.start) }
    }

    private func resolvePaths() throws -> Paths {
        let environment = ProcessInfo.processInfo.environment
        let paths = Paths(
            model: URL(fileURLWithPath: environment["MURMURLY_MODEL_PATH"] ?? defaults.model),
            monologue: URL(fileURLWithPath: environment["MURMURLY_MONO_AUDIO"] ?? defaults.monologue),
            dialogue: URL(fileURLWithPath: environment["MURMURLY_DIALOGUE_AUDIO"] ?? defaults.dialogue),
            outputDirectory: URL(
                fileURLWithPath: environment["MURMURLY_STAGE_GATE_OUTPUT"] ?? defaults.output,
                isDirectory: true
            )
        )

        try requireDirectory(paths.model, label: "Whisper model")
        try requireFile(paths.monologue, label: "monologue")
        try requireFile(paths.dialogue, label: "dialogue")
        return paths
    }

    private func requireDirectory(_ url: URL, label: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GateError.missing("\(label) directory: \(url.path)")
        }
    }

    private func requireFile(_ url: URL, label: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw GateError.missing("\(label) file: \(url.path)")
        }
    }

    private func render(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let timecode = segment.start.map(TranscriptSegment.timecode) ?? "--:--"
            let speaker = segment.speaker.isEmpty ? "Speech" : segment.speaker
            return "**[\(timecode)] \(speaker):** \(segment.text)"
        }.joined(separator: "\n\n")
    }
}

private struct Paths {
    let model: URL
    let monologue: URL
    let dialogue: URL
    let outputDirectory: URL
}

private struct Defaults {
    // Single source of truth: the gate must assert against whatever the app ships.
    let model = SettingsStore.defaultWhisperModel
    let monologue = NSHomeDirectory()
        + "/Library/Caches/Murmurly/StageGate/murmurly-stage-gate-monologue.wav"
    let dialogue = NSHomeDirectory()
        + "/Library/Caches/Murmurly/StageGate/murmurly-stage-gate-dialogue.wav"
    let output = NSHomeDirectory() + "/Library/Caches/Murmurly/StageGate/Results"
}

private enum GateError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let message): return "Missing Stage Gate input: \(message)"
        }
    }
}
