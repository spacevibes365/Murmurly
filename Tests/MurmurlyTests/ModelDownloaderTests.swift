import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import Murmurly

/// Hugging Face as the downloader sees it: a tree listing at a revision and
/// file bodies, any one of which can stall, break off or come back damaged.
private final class FakeHub: @unchecked Sendable {
    enum Fault { case stall, drop, damage, truncate }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hubs: [String: FakeHub] = [:]

    static func serving(_ host: String?) -> FakeHub? {
        lock.withLock { host.flatMap { hubs[$0] } }
    }

    let host: URL
    let session: URLSession
    private let lock = NSLock()
    /// "repo@revision" → path → body.
    private var files: [String: [String: Data]] = [:]
    /// By path; each fault fires once.
    private var faults: [String: Fault] = [:]
    private var requests: [String] = []
    private var stalls = 0

    init() {
        let name = "hub-\(UUID().uuidString.lowercased()).invalid"
        host = URL(string: "https://\(name)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHubProtocol.self]
        session = URLSession(configuration: configuration)
        Self.lock.withLock { Self.hubs[name] = self }
    }

    /// Every path the source asks for, plus one file it must not take. A
    /// compiled model gets its `coremldata.bin` and a weight file.
    func publish(_ source: ModelSource) {
        var bodies: [String: Data] = [:]
        for path in source.paths {
            let names = path.hasSuffix("/") ? [path + "coremldata.bin", path + "weights/weight.bin"] : [path]
            for name in names {
                let large = name.hasSuffix("weight.bin")
                bodies[source.folder + name] = Data(
                    (0..<(large ? 256 * 1024 : 64)).map { UInt8(truncatingIfNeeded: $0 &+ name.count) }
                )
            }
        }
        bodies[source.folder + "README.md"] = Data("not part of the model".utf8)
        lock.withLock { files["\(source.repo)@\(source.revision)", default: [:]].merge(bodies) { $1 } }
    }

    func body(_ source: ModelSource, _ path: String) -> Data? {
        lock.withLock { files["\(source.repo)@\(source.revision)"]?[source.folder + path] }
    }

    func fail(_ path: String, with fault: Fault) { lock.withLock { faults[path] = fault } }
    var requested: [String] { lock.withLock { requests } }
    var stalledRequests: Int { lock.withLock { stalls } }

    func answer(_ request: URLRequest, to loader: URLProtocol) {
        let client = loader.client
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        lock.withLock { requests.append(url.path) }
        if parts.count >= 5, parts[0] == "api", parts[1] == "models", parts[4] == "tree" {
            let repo = "\(parts[2])/\(parts[3])"
            let folder = parts.dropFirst(6).joined(separator: "/")
            reply(listing(repo: repo, revision: parts[5], folder: folder), to: loader, client: client)
        } else if parts.count >= 5, parts[2] == "resolve" {
            let repo = "\(parts[0])/\(parts[1])"
            let path = parts.dropFirst(4).joined(separator: "/")
            let (body, fault): (Data?, Fault?) = lock.withLock {
                (files["\(repo)@\(parts[3])"]?[path], faults.removeValue(forKey: path))
            }
            guard var body else { return reply(nil, to: loader, client: client) }
            switch fault {
            case .stall?:
                lock.withLock { stalls += 1 }
                send(body.prefix(body.count / 2), declaring: body.count, to: loader, client: client)
            case .drop?:
                send(body.prefix(body.count / 2), declaring: body.count, to: loader, client: client)
                client?.urlProtocol(loader, didFailWithError: URLError(.networkConnectionLost))
            case .damage?:
                body[body.count / 2] ^= 0xFF
                reply(body, to: loader, client: client)
            case .truncate?:
                reply(body.dropLast(), to: loader, client: client)
            case nil:
                reply(body, to: loader, client: client)
            }
        } else {
            reply(nil, to: loader, client: client)
        }
    }

    private func listing(repo: String, revision: String, folder: String) -> Data? {
        guard let bodies = lock.withLock({ files["\(repo)@\(revision)"] }) else { return nil }
        let prefix = folder.isEmpty ? "" : folder + "/"
        var entries: [[String: Any]] = [["type": "directory", "path": prefix + "weights", "size": 0]]
        for (path, body) in bodies where path.hasPrefix(prefix) {
            var entry: [String: Any] = ["type": "file", "path": path, "size": body.count, "oid": "git"]
            if path.hasSuffix(".bin") {
                let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                entry["lfs"] = ["oid": digest, "size": body.count, "pointerSize": 134]
            }
            entries.append(entry)
        }
        return try? JSONSerialization.data(withJSONObject: entries)
    }

    private func reply(_ body: Data?, to loader: URLProtocol, client: (any URLProtocolClient)?) {
        let response = HTTPURLResponse(
            url: loader.request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(loader, didLoad: body) }
        client?.urlProtocolDidFinishLoading(loader)
    }

    private func send(_ part: Data, declaring size: Int, to loader: URLProtocol, client: (any URLProtocolClient)?) {
        let response = HTTPURLResponse(
            url: loader.request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": "\(size)"]
        )!
        client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(loader, didLoad: part)
    }
}

private final class FakeHubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let hub = FakeHub.serving(request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        hub.answer(request, to: self)
    }

    override func stopLoading() {}
}

private actor RefusingMic: MicCapturing {
    private var starts = 0
    func start() async throws {
        starts += 1
        throw CocoaError(.featureUnsupported)
    }
    func stop() async throws -> URL? { nil }
    func startCount() -> Int { starts }
}

private struct UnusedWhisperFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        throw TranscriptionError.engineUnavailable("not used")
    }
}

private actor SilentParakeet: ParakeetEngine {
    func transcribe(audioPath: String, language: String?) async throws
        -> (segments: [WhisperSegmentDTO], language: String) { ([], "auto") }
}

private actor CountingParakeetFactory: ParakeetEngineFactory {
    private var loads = 0
    func make(modelFolder: String) async throws -> any ParakeetEngine {
        loads += 1
        return SilentParakeet()
    }
    func count() -> Int { loads }
}

private struct PreparationFailure: LocalizedError {
    var errorDescription: String? { "model files unreadable" }
}

/// Fails its first loads, optionally holding each until opened.
private actor FailingParakeetFactory: ParakeetEngineFactory {
    private let failures: Int
    private var holds: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var entered = 0
    private(set) var failed = 0

    init(failures: Int, holds: Bool = false) {
        self.failures = failures
        self.holds = holds
    }

    func make(modelFolder: String) async throws -> any ParakeetEngine {
        entered += 1
        if holds { await withCheckedContinuation { gate = $0 } }
        guard failed >= failures else {
            failed += 1
            throw PreparationFailure()
        }
        return SilentParakeet()
    }

    func open() {
        holds = false
        gate?.resume()
        gate = nil
    }
}

/// The seam between the downloader and the folder the engines read from,
/// and between a finished download and the parts of the app that wait for it.
@MainActor
final class ModelDownloaderTests: XCTestCase {
    private var root: URL!
    private var hub: FakeHub!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        hub = FakeHub()
        for source in [ModelSource.parakeet, .vad, .whisper, .whisperTokenizer] { hub.publish(source) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDownloader() -> ModelDownloader {
        ModelDownloader(root: root, session: hub.session, host: hub.host)
    }

    private func finish(_ downloader: ModelDownloader) async {
        let finished = await eventually { downloader.download == nil }
        XCTAssertTrue(finished, "the download never finished")
    }

    private func partials() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(ModelDownloader.partialPrefix) }
    }

    /// Where a URLSession download task keeps a body, and leaves it when the
    /// download is cancelled or cut off.
    private func systemTemporaryDownloads() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("CFNetworkDownload_") })
    }

    private func exists(_ source: ModelSource) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(source.destination).path)
    }

    /// Lays out a complete copy by hand, as an earlier download would have.
    private func installByHand(_ source: ModelSource) throws {
        for path in source.required {
            let file = root.appendingPathComponent(source.destination).appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("by hand".utf8).write(to: file)
        }
    }

    func testDownloadPutsEachModelInPlaceWithOnlyItsFilesAndSweepsLeftovers() async throws {
        // A killed download's folder, named the way the downloader names it.
        let leftover = root.appendingPathComponent(
            ModelDownloader.partialPrefix + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: leftover.appendingPathComponent("weight.bin"))
        let notes = root.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: notes)
        // Someone else's folder that only looks like ours.
        let lookalike = root.appendingPathComponent(".partial-personal-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: lookalike.appendingPathComponent("notes.txt"))
        let downloader = makeDownloader()
        XCTAssertFalse(downloader.isReady(.parakeet))
        XCTAssertEqual(downloader.missing(.parakeet), [.parakeet, .vad])

        downloader.start(.parakeet)
        await finish(downloader)

        XCTAssertNil(downloader.failure)
        XCTAssertEqual(downloader.installs, 1)
        XCTAssertTrue(downloader.isReady(.parakeet))
        XCTAssertTrue(downloader.missing(.parakeet).isEmpty)
        let encoder = root.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights/weight.bin")
        XCTAssertEqual(try Data(contentsOf: encoder), hub.body(.parakeet, "Encoder.mlmodelc/weights/weight.bin"))
        let vad = root.appendingPathComponent("silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil")
        XCTAssertEqual(try Data(contentsOf: vad), hub.body(.vad, "model.mil"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("parakeet-tdt-0.6b-v3/README.md").path))
        XCTAssertFalse(hub.requested.contains { $0.hasSuffix("README.md") })
        XCTAssertTrue(hub.requested.allSatisfy {
            $0.contains(ModelSource.parakeet.revision) || $0.contains(ModelSource.vad.revision)
        }, "\(hub.requested)")
        XCTAssertEqual(partials(), [".partial-personal-backup"])
        XCTAssertEqual(try Data(contentsOf: notes), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: lookalike.appendingPathComponent("notes.txt")), Data("keep".utf8))
    }

    func testCancelAfterTheLastFileInstallsNothing() async throws {
        // The last progress report comes from the download's own task once
        // every file is in; a cancel there lands before anything moves into place.
        let task = Task { [root, hub] in
            try await ModelDownloader.install([.vad], into: root!, session: hub!.session, host: hub!.host) { received, total in
                if total > 0, received == total { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            try await task.value
            XCTFail("a download cancelled before it was put in place must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(exists(.vad))
        XCTAssertEqual(partials(), [])
    }

    func testProgressCountsBytesUpToTheListedTotal() async throws {
        let recorder = ProgressRecorder()
        try await ModelDownloader.install(
            [.vad], into: root, session: hub.session, host: hub.host
        ) { received, total in recorder.add(received, total) }

        let expected = ModelSource.vad.paths.compactMap { hub.body(.vad, $0)?.count }.reduce(0, +)
        let steps = recorder.steps
        XCTAssertEqual(steps.first?.total, Int64(expected))
        XCTAssertEqual(steps.map(\.received).max(), Int64(expected))
        XCTAssertTrue(steps.allSatisfy { $0.total == Int64(expected) && $0.received <= $0.total })
    }

    func testCancelInTheMiddleOfAFileLeavesNoModelAndKeepsTheOnesInPlace() async throws {
        try installByHand(.vad)
        hub.fail("Encoder.mlmodelc/weights/weight.bin", with: .stall)
        let downloader = makeDownloader()
        let temporaryBefore = systemTemporaryDownloads()

        downloader.start(.parakeet)
        let stalled = await eventually { self.hub.stalledRequests == 1 }
        XCTAssertTrue(stalled)
        downloader.cancel()
        await finish(downloader)

        XCTAssertNil(downloader.failure, "a cancel is not a failure")
        XCTAssertEqual(downloader.installs, 0)
        XCTAssertFalse(exists(.parakeet))
        XCTAssertTrue(downloader.isInstalled(.vad))
        XCTAssertFalse(hub.requested.contains { $0.contains("silero") }, "an installed model is not fetched again")
        XCTAssertEqual(partials(), [])
        XCTAssertEqual(systemTemporaryDownloads().subtracting(temporaryBefore), [], "nothing is left outside the models folder")
    }

    func testDamagedOrShortFileInstallsNothing() async throws {
        for (path, fault) in [
            ("Decoder.mlmodelc/weights/weight.bin", FakeHub.Fault.damage),
            ("parakeet_vocab.json", .truncate),
        ] {
            hub.fail(path, with: fault)
            let downloader = makeDownloader()

            downloader.start(.parakeet)
            await finish(downloader)

            XCTAssertEqual(
                downloader.failure,
                .init(engine: .parakeet, message: ModelDownloader.InstallError.damaged(path).localizedDescription)
            )
            XCTAssertEqual(downloader.installs, 0)
            XCTAssertFalse(exists(.parakeet))
            XCTAssertFalse(exists(.vad))
            XCTAssertEqual(partials(), [])
        }
    }

    func testRetryAfterABrokenConnectionFinishes() async throws {
        hub.fail("Encoder.mlmodelc/weights/weight.bin", with: .drop)
        let downloader = makeDownloader()
        let temporaryBefore = systemTemporaryDownloads()

        downloader.start(.parakeet)
        await finish(downloader)
        XCTAssertNotNil(downloader.failure)
        XCTAssertFalse(downloader.isReady(.parakeet))
        XCTAssertEqual(partials(), [])
        XCTAssertEqual(systemTemporaryDownloads().subtracting(temporaryBefore), [], "nothing is left outside the models folder")

        downloader.start(.parakeet)
        XCTAssertNil(downloader.failure, "a new attempt clears the old error")
        await finish(downloader)

        XCTAssertNil(downloader.failure)
        XCTAssertEqual(downloader.installs, 1)
        XCTAssertTrue(downloader.missing(.parakeet).isEmpty)
        XCTAssertEqual(partials(), [])
    }

    func testIncompleteFolderInTheWayIsReportedNotReplaced() async throws {
        let folder = root.appendingPathComponent(ModelSource.parakeet.destination, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let downloader = makeDownloader()

        downloader.start(.parakeet)
        await finish(downloader)

        XCTAssertEqual(
            downloader.failure?.message,
            ModelDownloader.InstallError.occupied(folder.path).localizedDescription
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["notes.txt"])
        XCTAssertEqual(partials(), [])
    }

    func testWhisperComesWithItsTokenizerWhereTheEngineLooksForIt() async throws {
        let downloader = makeDownloader()

        downloader.start(.whisper)
        await finish(downloader)

        XCTAssertNil(downloader.failure)
        XCTAssertTrue(downloader.isReady(.whisper))
        let model = root.appendingPathComponent(ModelSource.whisper.destination, isDirectory: true)
        XCTAssertEqual(
            WhisperTokenizerLocator.folder(for: model),
            root.appendingPathComponent("openai/whisper-large-v3", isDirectory: true).standardizedFileURL
        )
        XCTAssertFalse(hub.requested.contains { $0.hasSuffix("README.md") })
    }

    // MARK: - Dictation and meetings

    func testHotkeyWithoutAModelDoesNotRecordAndSaysWhereToGetOne() async throws {
        let name = "io.github.spacevibes365.MurmurlyTests.NoModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let indicator = RecordingIndicator(renderingEnabled: false)
        let mic = RefusingMic()
        let coordinator = DictationCoordinator(
            mic: mic, indicator: indicator, models: makeDownloader()
        )
        coordinator.configureForTesting(settings: settings)

        coordinator.toggle()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(indicator.presentedState, DictationCoordinator.modelMissingFlash)
        try await Task.sleep(for: .milliseconds(50))
        let starts = await mic.startCount()
        XCTAssertEqual(starts, 0, "nothing is recorded without a model")

        try installByHand(.parakeet)
        coordinator.toggle()
        // Past the model the microphone permission decides; either way the
        // model is no longer what stops the hotkey.
        XCTAssertNotEqual(indicator.presentedState, DictationCoordinator.modelMissingFlash)
        _ = await eventually { coordinator.state == .idle }
    }

    func testFinishedDownloadWarmsTheSelectedModelUp() async throws {
        let name = "io.github.spacevibes365.MurmurlyTests.WarmAfterDownload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let parakeet = CountingParakeetFactory()
        let downloader = makeDownloader()
        let coordinator = DictationCoordinator(
            mic: RefusingMic(),
            indicator: RecordingIndicator(renderingEnabled: false),
            hotkeyManager: HotkeyManager(installsSystemHandlers: false),
            whisperCache: WhisperKitCache(factory: UnusedWhisperFactory(), parakeetFactory: parakeet),
            models: downloader,
            warmsUp: true
        )
        coordinator.activate(settings: settings, permissions: PermissionManager(runningTests: true))
        try await Task.sleep(for: .milliseconds(100))
        let before = await parakeet.count()
        XCTAssertEqual(before, 0, "no warm-up of a model that is not there")
        XCTAssertEqual(coordinator.modelState, .cold)

        downloader.start(.parakeet)
        await finish(downloader)

        let warmed = await eventually { await parakeet.count() == 1 }
        XCTAssertTrue(warmed, "the downloaded model is warmed up without another engine switch")
        let ready = await eventually { coordinator.modelState == .ready }
        XCTAssertTrue(ready)
    }

    /// Warm-up → coordinator → what the app says: a failed preparation is not
    /// "ready", and Try Again prepares the model once it loads.
    func testFailedPreparationIsToldAndTryAgainPreparesTheModel() async throws {
        let name = "io.github.spacevibes365.MurmurlyTests.FailedWarmup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        try installByHand(.parakeet)
        let parakeet = FailingParakeetFactory(failures: 1)
        let coordinator = DictationCoordinator(
            mic: RefusingMic(),
            indicator: RecordingIndicator(renderingEnabled: false),
            hotkeyManager: HotkeyManager(installsSystemHandlers: false),
            whisperCache: WhisperKitCache(factory: UnusedWhisperFactory(), parakeetFactory: parakeet),
            models: makeDownloader(),
            warmsUp: true
        )
        func readiness() -> DictationCoordinator.Readiness {
            DictationCoordinator.readiness(
                modelDownloaded: true,
                microphoneGranted: true,
                modelState: coordinator.modelState,
                modelFailure: coordinator.modelFailure
            )
        }

        coordinator.activate(settings: settings, permissions: PermissionManager(runningTests: true))

        let failed = await eventually { coordinator.modelFailure != nil }
        XCTAssertTrue(failed, "a failed warm-up must be told, not left as an untried model")
        XCTAssertEqual(coordinator.modelFailure, "model files unreadable")
        XCTAssertEqual(readiness(), .modelFailed)

        coordinator.retryModelPreparation()

        let ready = await eventually { coordinator.modelState == .ready }
        XCTAssertTrue(ready)
        XCTAssertNil(coordinator.modelFailure)
        XCTAssertEqual(readiness(), .ready)
        let loads = await parakeet.entered
        XCTAssertEqual(loads, 2)
    }

    /// A load of the previous engine that fails after the switch belongs to
    /// that engine: the new choice must not show its error.
    func testFailureOfTheEarlierEngineDoesNotShowOnTheNewChoice() async throws {
        let name = "io.github.spacevibes365.MurmurlyTests.StaleWarmupFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        // Whisper has no model here, so the new choice starts no warm-up of
        // its own that could fail or succeed.
        try installByHand(.parakeet)
        let parakeet = FailingParakeetFactory(failures: 1, holds: true)
        let coordinator = DictationCoordinator(
            mic: RefusingMic(),
            indicator: RecordingIndicator(renderingEnabled: false),
            hotkeyManager: HotkeyManager(installsSystemHandlers: false),
            whisperCache: WhisperKitCache(factory: UnusedWhisperFactory(), parakeetFactory: parakeet),
            models: makeDownloader(),
            warmsUp: true
        )
        coordinator.activate(settings: settings, permissions: PermissionManager(runningTests: true))
        let loading = await eventually { await parakeet.entered == 1 }
        XCTAssertTrue(loading)

        settings.dictationEngine = .whisper
        await parakeet.open()

        let threw = await eventually { await parakeet.failed == 1 }
        XCTAssertTrue(threw, "the earlier load must really fail, or the check proves nothing")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(coordinator.modelFailure)
        XCTAssertEqual(coordinator.modelState, .cold)
    }

    /// Checked top to bottom, the first match wins; "ready" only once the
    /// model is prepared.
    func testReadinessTable() {
        let cases: [(downloaded: Bool, microphone: Bool, state: WhisperModelState, failure: String?,
                     expected: DictationCoordinator.Readiness)] = [
            (false, true, .ready, nil, .needsModel),
            (false, false, .cold, "broken", .needsModel),
            (true, true, .cold, "broken", .modelFailed),
            (true, false, .ready, "broken", .modelFailed),
            (true, false, .ready, nil, .needsMicrophone),
            (true, false, .cold, nil, .needsMicrophone),
            (true, true, .loading, nil, .preparing),
            (true, true, .waiting, nil, .waitingForEngine),
            (true, true, .cold, nil, .notPrepared),
            (true, true, .ready, nil, .ready),
        ]
        for item in cases {
            XCTAssertEqual(
                DictationCoordinator.readiness(
                    modelDownloaded: item.downloaded,
                    microphoneGranted: item.microphone,
                    modelState: item.state,
                    modelFailure: item.failure
                ),
                item.expected,
                "\(item)"
            )
        }
    }

    func testMeetingWithoutAModelIsKeptAndSaysHowToTranscribeItLater() async throws {
        let name = "io.github.spacevibes365.MurmurlyTests.MeetingNoModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        try installByHand(.parakeet)
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        let folder = root.appendingPathComponent("2026-10-08 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let track = folder.appendingPathComponent("system.caf")
        try Data("recorded".utf8).write(to: track)
        let queue = MeetingTranscriptionQueue(
            transcriber: .live(settings: settings, models: makeDownloader()),
            meetingsRoot: meetingsRoot
        )

        // The engine is there, speech detection is not: still no transcript.
        queue.enqueue(folder)
        let done = await eventually { queue.lastOutcome != nil && queue.activeFolder == nil }
        XCTAssertTrue(done)

        XCTAssertEqual(
            queue.lastOutcome,
            .failed(
                folder: folder.standardizedFileURL,
                reason: MeetingTranscriber.Failure.modelNotDownloaded.localizedDescription
            )
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["system.caf"])
        XCTAssertEqual(try Data(contentsOf: track), Data("recorded".utf8))
    }

    /// Polls with a deadline, so a wedged download fails instead of hanging the run.
    private func eventually(
        within limit: Duration = .seconds(10),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Step { let received: Int64; let total: Int64 }
    private let lock = NSLock()
    private var recorded: [Step] = []
    func add(_ received: Int64, _ total: Int64) { lock.withLock { recorded.append(Step(received: received, total: total)) } }
    var steps: [Step] { lock.withLock { recorded } }
}
