import AppKit
import Combine
import Foundation
import XCTest
@testable import Murmurly

private actor SilentMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

@MainActor
final class AppUpdaterTests: XCTestCase {
    // One fixed suite, cleared around every test: per-test UUID suites exhaust
    // cfprefsd's descriptors under repeated runs.
    private static let suiteName = "io.github.spacevibes365.MurmurlyTests.AppUpdater"
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// The update settings travel Signing.xcconfig → Info.plist → Sparkle. An
    /// xcconfig treats "//" as a comment, so a URL written plainly there reaches
    /// the app as "https:" and every update check fails.
    func testInfoPlistCarriesTheUpdateSettingsFromTheBuild() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String, "Info.plist has no SUFeedURL")
        let url = try XCTUnwrap(URL(string: feed), "SUFeedURL is not a URL: \(feed)")
        XCTAssertEqual(url.scheme, "https", feed)
        XCTAssertFalse(url.host?.isEmpty ?? true, "SUFeedURL has no host: \(feed)")
        XCTAssertEqual(url.lastPathComponent, "appcast.xml", feed)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        // Empty turns the updater off; anything else must be a whole Ed25519 key.
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String, "Info.plist has no SUPublicEDKey")
        if !key.isEmpty {
            XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "SUPublicEDKey is not an Ed25519 key: \(key)")
        }
    }

    /// The test copy is told apart from a build without a key: the gate must
    /// hold even when the clone has one (the unit-test host is the app itself).
    func testTestCopyNeverStartsTheUpdater() {
        let updater = AppUpdater(busy: Just(false))
        XCTAssertEqual(updater.state, .testCopy)
        XCTAssertFalse(updater.canCheckForUpdates)
    }

    /// Sparkle's install stage brings the app into the Dock, and closing its
    /// windows never sent it back. The end of Sparkle's update session, with
    /// no window of the app open, takes the app out of the Dock. Sparkle
    /// itself is off in a test copy, so this calls the delegate as it would.
    func testEndOfSparklesSessionTakesTheAppOutOfTheDock() async throws {
        let before = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(before) }
        XCTAssertEqual(
            AppWindowController.visibleRealWindowCount(in: NSApp.windows), 0,
            "a window of the test host is open: the check proves nothing"
        )
        NSApp.setActivationPolicy(.regular)
        let updater = AppUpdater(busy: Just(false))

        updater.standardUserDriverWillFinishUpdateSession()

        try await waitUntil { NSApp.activationPolicy() == .accessory }
    }

    /// Sparkle's windows (the update alert, its errors) take their text from
    /// its own bundle, in the language the app runs in; a language Sparkle
    /// has no localization for would show them in English inside a
    /// translated app. Sparkle names Chinese zh_CN, the app zh-Hans.
    func testSparkleHasEveryInterfaceLanguageOfTheApp() throws {
        let url = try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"))
        let sparkle = try XCTUnwrap(Bundle(url: url), "no Sparkle.framework in \(url.path)")
        let languages = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }
        XCTAssertEqual(languages.count, 11, "the app's translations: \(languages)")
        for language in languages {
            let match = Bundle.preferredLocalizations(from: sparkle.localizations, forPreferences: [language]).first
            XCTAssertEqual(
                match.map { Locale.Language(identifier: $0).maximalIdentifier },
                Locale.Language(identifier: language).maximalIdentifier,
                "\(language): Sparkle would answer with \(match ?? "nothing") from \(sparkle.localizations.sorted())"
            )
        }
    }

    /// "Install and Relaunch" quits the app, so Sparkle is refused while the
    /// real recorder records or saves a call, and let through once it has.
    func testNoRelaunchUntilTheMeetingRecordingIsSaved() async throws {
        let app = makeApp(afterStop: .nothing)
        let metadata = SavingMeetingCapture.folder(1, in: root).appendingPathComponent("metadata.json")
        XCTAssertTrue(app.updater.relaunchNow(), "nothing is recorded: relaunch at once")

        app.recorder.toggle()
        try await waitUntil { app.recorder.state == .recording }
        XCTAssertFalse(app.updater.installsAtQuit)
        XCTAssertFalse(app.updater.relaunchNow(), "a call is being recorded")
        XCTAssertTrue(app.updater.installsAtQuit, "the menu and Settings say the update waits for the quit")
        let clicks = clickAfterEveryChange(app)

        app.recorder.toggle()
        try await waitUntil { app.updater.relaunchNow() }
        try await settle()
        XCTAssertFalse(app.recorder.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(clicks.allowed.isEmpty)
        XCTAssertTrue(clicks.allowed.allSatisfy { !$0.recorderBusy }, "\(clicks.allowed)")
    }

    /// A stopped recording goes idle a moment before the queue takes it for
    /// transcription; no click may get through in between.
    func testNoRelaunchWhileTheStoppedRecordingIsTranscribed() async throws {
        let app = makeApp(afterStop: .transcribe)
        app.recorder.toggle()
        try await waitUntil { app.recorder.state == .recording }
        let clicks = clickAfterEveryChange(app)

        app.recorder.toggle()
        try await waitUntil { app.entered.value == 1 }
        try await settle()
        XCTAssertFalse(app.updater.relaunchNow(), "the stopped recording is being transcribed")

        app.released.increment()
        try await waitUntil { app.updater.relaunchNow() }
        try await settle()
        XCTAssertEqual(transcripts(), 1)
        XCTAssertFalse(clicks.allowed.isEmpty)
        XCTAssertTrue(clicks.allowed.allSatisfy { $0.transcripts == 1 },
                      "let through before the transcription ended: \(clicks.allowed)")
    }

    /// The last queued transcription leaves the queue before its job starts;
    /// no click may get through on that handover either.
    func testNoRelaunchWhenTheLastQueuedTranscriptionStarts() async throws {
        let app = makeApp(afterStop: .nothing)
        let capture = SavingMeetingCapture(root: root)
        _ = try await capture.stop()
        _ = try await capture.stop()
        app.queue.enqueue(SavingMeetingCapture.folder(1, in: root))
        app.queue.enqueue(SavingMeetingCapture.folder(2, in: root))
        try await waitUntil { app.entered.value == 1 }
        XCTAssertEqual(app.queue.pending.count, 1)
        XCTAssertFalse(app.updater.relaunchNow(), "two transcriptions to go")
        let clicks = clickAfterEveryChange(app)

        app.released.increment()
        try await waitUntil { app.entered.value == 2 }
        try await settle()
        XCTAssertFalse(app.updater.relaunchNow(), "the last queued transcription is running")

        app.released.increment()
        try await waitUntil { app.updater.relaunchNow() }
        try await settle()
        XCTAssertEqual(transcripts(), 2)
        XCTAssertFalse(clicks.allowed.isEmpty)
        XCTAssertTrue(clicks.allowed.allSatisfy { $0.transcripts == 2 },
                      "let through before the last transcription ended: \(clicks.allowed)")
    }

    /// The copy into the chosen transcripts folder is made once and never
    /// again: no click may get through until the job has delivered it.
    func testNoRelaunchUntilTheTranscriptIsCopied() async throws {
        let target = root.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let app = makeApp(afterStop: .nothing, transcripts: target)
        _ = try await SavingMeetingCapture(root: root).stop()
        app.queue.enqueue(SavingMeetingCapture.folder(1, in: root))
        try await waitUntil { app.entered.value == 1 }
        let clicks = clickAfterEveryChange(app, copiesIn: target)

        app.released.increment()
        try await waitUntil { app.updater.relaunchNow() }
        try await settle()
        XCTAssertEqual(transcripts(), 1)
        XCTAssertFalse(clicks.allowed.isEmpty)
        XCTAssertTrue(clicks.allowed.allSatisfy { $0.transcripts == 1 && $0.copies == 1 },
                      "let through before the transcript was copied: \(clicks.allowed)")
    }

    /// A Files run is cut short by a relaunch and nothing reruns it: refused
    /// while it goes, let through once it ends. Its unsaved result does not
    /// hold the update; the quit Sparkle then sends is a person's quit, which
    /// warns about the text and stays cancelled, so the text is not lost.
    func testNoRelaunchDuringAFilesRunAndItsUnsavedTextStopsTheQuit() async throws {
        let released = JobCounter()
        let files = FilesModel(transcription: { _ in { _, _ in
            while released.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
            return [TranscriptSegment(speaker: "", text: "text")]
        } })
        let app = makeApp(afterStop: .nothing, files: files)
        XCTAssertTrue(app.updater.relaunchNow(), "nothing runs: relaunch at once")

        files.select(root.appendingPathComponent("talk.wav"))
        files.start()
        XCTAssertTrue(files.isTranscribing)
        XCTAssertFalse(app.updater.relaunchNow(), "a file is being transcribed")

        released.increment()
        try await waitUntil { app.updater.relaunchNow() }
        XCTAssertFalse(files.isTranscribing)
        XCTAssertTrue(files.hasUnsavedText)

        // Sparkle's quit after the relaunch was let through, as the app wires it.
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish: no recording runs") }
        delegate.attach(dictation: app.dictation, meeting: app.recorder, settings: app.settings)
        delegate.fileLosses = { files.quitLosses }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertTrue(files.hasUnsavedText, "the warning leaves the text where it is")
    }

    /// Unsaved Files text lets "Install and Relaunch" through; the quit that
    /// follows is cancelled by its warning, and the menu and Settings must
    /// then say the update waits for the next quit.
    func testRelaunchCancelledByUnsavedFilesTextSaysTheUpdateInstallsAtQuit() async throws {
        let files = FilesModel(transcription: { _ in { _, _ in [TranscriptSegment(speaker: "", text: "text")] } })
        let app = makeApp(afterStop: .nothing, files: files)
        files.select(root.appendingPathComponent("talk.wav"))
        files.start()
        try await waitUntil { files.hasUnsavedText }
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish: no recording runs") }
        delegate.attach(dictation: app.dictation, meeting: app.recorder, settings: app.settings)
        delegate.fileLosses = { files.quitLosses }

        XCTAssertTrue(app.updater.relaunchNow(), "unsaved text does not hold the update")
        XCTAssertFalse(app.updater.installsAtQuit)
        // What Sparkle does next, right before it quits the app.
        app.updater.willRelaunch()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertTrue(app.updater.installsAtQuit, "the menu and Settings say the update installs at quit")
    }

    // MARK: - Helpers

    private struct App {
        let recorder: MeetingRecorder
        let queue: MeetingTranscriptionQueue
        let updater: AppUpdater
        let settings: SettingsStore
        let dictation: DictationCoordinator
        let files: FilesModel
        let library: MeetingLibrary
        /// Jobs that reached speech detection, and how many may go on past it.
        let entered: JobCounter
        let released: JobCounter
    }

    /// The app's own wiring: the recorder hands stopped recordings to the
    /// queue, and the updater watches all three. Only the capture, speech
    /// detection and the engine stand in; every job waits at detection until
    /// the test releases it.
    private func makeApp(
        afterStop: MeetingAfterStop,
        transcripts: URL? = nil,
        files: FilesModel = FilesModel(transcription: { _ in { _, _ in [] } })
    ) -> App {
        let entered = JobCounter()
        let released = JobCounter()
        let queue = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: ConstantEngineFactory()),
                loadSpeechDetector: { _ in
                    entered.increment()
                    let job = entered.value
                    while released.value < job { try await Task.sleep(for: .milliseconds(10)) }
                    // Some speech on every track, so each job writes a transcript.
                    return { _ in [0..<16_000] }
                },
                currentEngine: { _ in
                    MeetingTranscriber.Engine(
                        descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                        request: .whisper(WhisperDecodeRequest(language: "ru")),
                        label: "Whisper (whisper)"
                    )
                },
                temporaryRoot: root
            ),
            destinations: { .init(meetings: nil, transcripts: transcripts) }
        )
        let settings = SettingsStore(defaults: defaults)
        settings.meetingAfterStop = afterStop
        let recorder = MeetingRecorder(
            capture: SavingMeetingCapture(root: root),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
        let dictation = DictationCoordinator(mic: SilentMic(), indicator: RecordingIndicator(renderingEnabled: false))
        recorder.transcripts = queue
        recorder.activate(settings: settings, permissions: PermissionManager(), dictation: dictation)
        let library = MeetingLibrary(recorder: recorder, queue: queue, settings: settings)
        let updater = AppUpdater(busy: AppUpdater.busy(
            meeting: recorder, dictation: dictation, transcripts: queue, files: files, library: library
        ))
        // The recorder holds settings and queue weakly, as the app's state
        // objects do; the returned value keeps them alive.
        return App(
            recorder: recorder, queue: queue, updater: updater, settings: settings,
            dictation: dictation, files: files, library: library, entered: entered, released: released
        )
    }

    /// What was done at one moment; a relaunch then would cut short the rest.
    private struct Moment: CustomStringConvertible {
        let recorderBusy: Bool
        let transcripts: Int
        let copies: Int
        var description: String { "recorder busy \(recorderBusy), transcripts \(transcripts), copies \(copies)" }
    }

    @MainActor
    private final class Clicks {
        var allowed: [Moment] = []
        var subscription: AnyCancellable?
    }

    /// "Install and Relaunch" clicked at the worst moments. Sparkle asks from
    /// a block of its own on the main queue, so the question can come right
    /// after any change the updater sees; every change here schedules one
    /// and keeps what each let-through would have cut short.
    private func clickAfterEveryChange(_ app: App, copiesIn target: URL? = nil) -> Clicks {
        let clicks = Clicks()
        let root: URL = root
        clicks.subscription = AppUpdater.busy(
            meeting: app.recorder, dictation: app.dictation, transcripts: app.queue, files: app.files,
            library: app.library
        )
            .sink { _ in
                Task { @MainActor in
                    guard app.updater.relaunchNow() else { return }
                    let copies = target.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
                    clicks.allowed.append(Moment(
                        recorderBusy: app.recorder.isBusy,
                        transcripts: Self.transcripts(in: root),
                        copies: copies.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.count
                    ))
                }
            }
        return clicks
    }

    /// Transcripts written into the test's meeting folders; jobs the
    /// recorder's scans may add for other folders do not count.
    private func transcripts() -> Int { Self.transcripts(in: root) }

    private static func transcripts(in root: URL) -> Int {
        (1...2).filter {
            FileManager.default.fileExists(
                atPath: SavingMeetingCapture.folder($0, in: root).appendingPathComponent("transcript.md").path
            )
        }.count
    }

    /// Room for the clicks already scheduled on the main actor to run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    private func waitUntil(_ done: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), "timed out")
    }
}
