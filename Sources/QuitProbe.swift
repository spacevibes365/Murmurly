#if DEBUG
import AppKit
import AVFoundation
import Foundation

/// UI-test harness for real quit checks, enabled only by launch arguments:
/// `-QuitProbe <scenario> -QuitProbeRoot <dir> [-QuitProbeTrigger signal]`.
/// It swaps in a fake microphone, engine, archive and meeting backend, drives
/// one recording to the requested stage, records that stage in `ready.json`
/// and then asks to quit. It holds no quit logic of its own, so the very same
/// file also builds on the tree before the quit fix for the red check.
@MainActor
final class QuitProbe {
    enum Scenario: String {
        case dictationRecording = "dictation-recording"
        case dictationRecognizing = "dictation-recognizing"
        case meetingRecording = "meeting-recording"
    }

    let dictation: DictationCoordinator
    let meeting: MeetingRecorder
    private let scenario: Scenario
    private let root: URL
    private let quitBySignal: Bool
    private let settings: SettingsStore
    private let engine: QuitProbeEngine

    static func fromLaunchArguments(
        settings: SettingsStore,
        indicator: RecordingIndicator
    ) -> QuitProbe? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let name = value(after: "-QuitProbe", in: arguments),
              let scenario = Scenario(rawValue: name),
              let rootPath = value(after: "-QuitProbeRoot", in: arguments) else { return nil }
        do {
            return try QuitProbe(
                scenario: scenario,
                root: URL(fileURLWithPath: rootPath, isDirectory: true),
                quitBySignal: value(after: "-QuitProbeTrigger", in: arguments) == "signal",
                settings: settings,
                indicator: indicator
            )
        } catch {
            AppLog.error("quit-probe", "setup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private init(
        scenario: Scenario,
        root: URL,
        quitBySignal: Bool,
        settings: SettingsStore,
        indicator: RecordingIndicator
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let template = root.appendingPathComponent("template.caf")
        try Self.writeTemplate(to: template)
        // The probe's engine stands in for Whisper; no model is read.
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "auto"

        let engine = QuitProbeEngine(answers: scenario != .dictationRecognizing)
        self.scenario = scenario
        self.root = root
        self.quitBySignal = quitBySignal
        self.settings = settings
        self.engine = engine
        dictation = DictationCoordinator(
            mic: QuitProbeMic(template: template),
            indicator: indicator,
            whisperCache: WhisperKitCache(factory: QuitProbeEngineFactory(engine: engine)),
            historyStore: DictationHistoryStore(
                root: root.appendingPathComponent("Dictations", isDirectory: true)
            ),
            deliveryOverride: { _, _ in },
            feedbackPlayer: { _ in },
            beepPlayer: {}
        )
        meeting = MeetingRecorder(
            capture: QuitProbeMeetingCapture(
                directory: root.appendingPathComponent("Meetings/probe", isDirectory: true)
            ),
            indicator: indicator,
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
        Task { await self.run() }
    }

    private func run() async {
        // Let MenuBarLabel.task activate the recorders first, as on a real launch.
        try? await Task.sleep(for: .seconds(1.5))
        dictation.configureForTesting(settings: settings)
        let reached: Bool
        switch scenario {
        case .dictationRecording:
            dictation.beginCaptureForTesting()
            reached = await waitFor { self.dictation.state == .recording }
        case .dictationRecognizing:
            dictation.beginCaptureForTesting()
            if await waitFor({ self.dictation.state == .recording }) {
                dictation.toggle()
                reached = await waitFor { await self.engine.wasCalled() }
            } else {
                reached = false
            }
        case .meetingRecording:
            meeting.toggle()
            reached = await waitFor { self.meeting.state == .recording }
        }
        await writeReady(reached: reached)
        guard reached else { return }
        if quitBySignal {
            kill(getpid(), SIGTERM)
        } else if scenario == .meetingRecording {
            // A recording that would be transcribed after it stops is a loss:
            // the first quit only warns. The marker records whether the
            // recording was still running a second later, then quit repeats.
            NSApp.terminate(nil)
            try? await Task.sleep(for: .seconds(1))
            await writeReady(reached: reached, afterFirstQuit: "\(meeting.state)")
            NSApp.terminate(nil)
        } else {
            NSApp.terminate(nil)
        }
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Written right before quit, so the test can prove that quit caught the
    /// recording at the intended stage and not after it had ended.
    private func writeReady(reached: Bool, afterFirstQuit: String? = nil) async {
        let engineCalled = await engine.wasCalled()
        var marker: [String: Any] = [
            "scenario": scenario.rawValue,
            "reached": reached,
            "dictationState": "\(dictation.state)",
            "meetingState": "\(meeting.state)",
            "engineCalled": engineCalled,
            "pid": Int(getpid()),
        ]
        marker["meetingStateAfterFirstQuit"] = afterFirstQuit
        do {
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        } catch {
            AppLog.error("quit-probe", "ready marker not written: \(error.localizedDescription)")
        }
    }

    private static func writeTemplate(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = 24_000
        for frame in 0..<24_000 {
            channel[frame] = sinf(Float(frame) * 0.05) * 0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

private actor QuitProbeMic: MicCapturing {
    let template: URL

    init(template: URL) { self.template = template }

    func start() async throws {}

    func stop() async throws -> URL? {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-probe-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: template, to: source)
        return source
    }
}

private actor QuitProbeEngine: WhisperEngine {
    private let answers: Bool
    private var called = false
    /// Kept, never resumed: the "recognizing" scenario needs a model that
    /// does not answer, not even to cancellation.
    private var parked: [CheckedContinuation<Void, Never>] = []

    init(answers: Bool) { self.answers = answers }

    func wasCalled() -> Bool { called }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        called = true
        if !answers { await withCheckedContinuation { parked.append($0) } }
        return ([WhisperSegmentDTO(text: "probe text", start: 0)], "ru")
    }
}

private struct QuitProbeEngineFactory: WhisperEngineFactory {
    let engine: QuitProbeEngine
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { engine }
}

/// Like the real backend, it writes `metadata.json` only in `stop()`.
private actor QuitProbeMeetingCapture: MeetingCaptureBackend {
    let directory: URL
    private var startedAt: Date?

    init(directory: URL) { self.directory = directory }

    func start() async throws -> Date {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["system.caf", "microphone.caf"] {
            try Data("probe".utf8).write(to: directory.appendingPathComponent(name))
        }
        let now = Date()
        startedAt = now
        return now
    }

    func stop() async throws -> [URL] {
        guard let startedAt else { throw SystemAudioCaptureError.notRunning }
        self.startedAt = nil
        let formatter = ISO8601DateFormatter()
        let metadata = MeetingMetadata(
            startedAt: formatter.string(from: startedAt),
            endedAt: formatter.string(from: Date()),
            sampleRate: 48_000,
            state: "done",
            segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}
#endif
