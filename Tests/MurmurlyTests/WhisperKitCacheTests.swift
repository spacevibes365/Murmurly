import FluidAudio
import XCTest
@testable import Murmurly

private enum FakeWhisperError: Error { case loadFailed }

private final class WhisperStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WhisperModelState] = []

    func append(_ state: WhisperModelState) {
        lock.lock()
        storage.append(state)
        lock.unlock()
    }

    func states() -> [WhisperModelState] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class EngineLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var creationLiveCounts: [Int] = []
    private var live = 0
    private(set) var maximumLive = 0
    func created() { lock.withLock { creationLiveCounts.append(live); live += 1; maximumLive = max(maximumLive, live) } }
    func released() { lock.withLock { live -= 1 } }
}

private actor FakeWhisperEngine: WhisperEngine {
    let path: String
    let decodeDelay: Duration
    let lifetime: EngineLifetimeProbe?
    private(set) var decodeCalls = 0
    private var active = 0
    private(set) var maxActive = 0

    init(path: String, decodeDelay: Duration = .zero, lifetime: EngineLifetimeProbe? = nil) {
        self.path = path
        self.decodeDelay = decodeDelay
        self.lifetime = lifetime
        lifetime?.created()
    }

    deinit { lifetime?.released() }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        decodeCalls += 1
        active += 1
        maxActive = max(maxActive, active)
        if decodeDelay > .zero { try await Task.sleep(for: decodeDelay) }
        active -= 1
        return ([WhisperSegmentDTO(text: path, start: 0)], request.language ?? "auto")
    }

    func stats() -> (calls: Int, maxActive: Int) { (decodeCalls, maxActive) }
}

private actor FakeWhisperFactory: WhisperEngineFactory {
    let failures: Set<String>
    let loadDelay: Duration
    let decodeDelay: Duration
    let lifetime: EngineLifetimeProbe?
    let retainEngines: Bool
    private var failuresBeforeSuccess: [String: Int]
    private var counts: [String: Int] = [:]
    private var prewarmModes: [String: [Bool]] = [:]
    private var engines: [String: FakeWhisperEngine] = [:]

    init(
        failures: Set<String> = [],
        failuresBeforeSuccess: [String: Int] = [:],
        loadDelay: Duration = .zero,
        decodeDelay: Duration = .zero,
        lifetime: EngineLifetimeProbe? = nil,
        retainEngines: Bool = true
    ) {
        self.failures = failures
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.loadDelay = loadDelay
        self.decodeDelay = decodeDelay
        self.lifetime = lifetime
        self.retainEngines = retainEngines
    }

    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        counts[modelFolder, default: 0] += 1
        prewarmModes[modelFolder, default: []].append(prewarm)
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        if failures.contains(modelFolder) { throw FakeWhisperError.loadFailed }
        if failuresBeforeSuccess[modelFolder, default: 0] > 0 {
            failuresBeforeSuccess[modelFolder, default: 0] -= 1
            throw FakeWhisperError.loadFailed
        }
        let engine = FakeWhisperEngine(path: modelFolder, decodeDelay: decodeDelay, lifetime: lifetime)
        if retainEngines { engines[modelFolder] = engine }
        return engine
    }

    func count(for path: String) -> Int { counts[path, default: 0] }
    func modes(for path: String) -> [Bool] { prewarmModes[path, default: []] }
    func engine(for path: String) -> FakeWhisperEngine? { engines[path] }
}

/// Holds the first load of `gatedPath` until the test opens the gate, so a
/// second caller can be queued behind a known owner.
private actor GatedWhisperFactory: WhisperEngineFactory {
    let gatedPath: String
    private var gateEntered = false
    private var isOpen = false
    private var gate: CheckedContinuation<Void, Never>?
    private var engines: [String: FakeWhisperEngine] = [:]

    init(gatedPath: String) { self.gatedPath = gatedPath }

    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        if modelFolder == gatedPath, !gateEntered {
            gateEntered = true
            if !isOpen { await withCheckedContinuation { gate = $0 } }
        }
        let engine = FakeWhisperEngine(path: modelFolder)
        engines[modelFolder] = engine
        return engine
    }

    func hasEnteredGate() -> Bool { gateEntered }
    func open() { isOpen = true; gate?.resume(); gate = nil }
    func engine(for path: String) -> FakeWhisperEngine? { engines[path] }
}

/// Tracks every task of the hand-off scenario so cleanup can cancel them and
/// wait with a deadline instead of awaiting a value that may never arrive.
private final class HandoffProbe: @unchecked Sendable {
    enum Outcome: Equatable { case succeeded, cancelled, failed }

    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var states: [String: [WhisperModelState]] = [:]

    func start(_ name: String, _ body: @escaping @Sendable () async throws -> Void) {
        let task = Task {
            let outcome: Outcome
            do { try await body(); outcome = .succeeded }
            catch is CancellationError { outcome = .cancelled }
            catch { outcome = .failed }
            self.lock.withLock { self.outcomes[name] = outcome }
        }
        lock.withLock { tasks[name] = task }
    }

    func cancel(_ name: String) { lock.withLock { tasks[name] }?.cancel() }
    func cancelAll() { lock.withLock { Array(tasks.values) }.forEach { $0.cancel() } }
    func outcome(_ name: String) -> Outcome? { lock.withLock { outcomes[name] } }
    var allFinished: Bool { lock.withLock { outcomes.count == tasks.count } }

    func record(_ state: WhisperModelState, for name: String) {
        lock.withLock { states[name, default: []].append(state) }
    }

    func states(for name: String) -> [WhisperModelState] { lock.withLock { states[name, default: []] } }
}

private actor FakeParakeetEngine: ParakeetEngine {
    let path: String
    let lifetime: EngineLifetimeProbe?
    init(path: String, lifetime: EngineLifetimeProbe? = nil) {
        self.path = path; self.lifetime = lifetime; lifetime?.created()
    }
    deinit { lifetime?.released() }
    func transcribe(audioPath: String, language: String?) async throws
        -> (segments: [WhisperSegmentDTO], language: String) {
        ([WhisperSegmentDTO(text: path, start: 0)], language ?? "auto")
    }
}

private actor FakeParakeetFactory: ParakeetEngineFactory {
    let lifetime: EngineLifetimeProbe?
    private var loads = 0
    init(lifetime: EngineLifetimeProbe? = nil) { self.lifetime = lifetime }
    func make(modelFolder: String) async throws -> any ParakeetEngine {
        loads += 1
        return FakeParakeetEngine(path: modelFolder, lifetime: lifetime)
    }
    func count() -> Int { loads }
}

@MainActor
final class WhisperKitCacheTests: XCTestCase {
    private func segment(_ text: String) -> WhisperSegmentDTO {
        WhisperSegmentDTO(text: text, start: 0)
    }

    private func waitForLoad(_ factory: FakeWhisperFactory, path: String) async throws {
        for _ in 0..<100 {
            if await factory.count(for: path) > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected model load for \(path)")
    }

    /// Polls until `condition` holds or the deadline passes, so a wedged cache
    /// becomes a failed assertion instead of a hung test run.
    private func eventually(
        within limit: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// The one request builder: a code the engine knows goes as is; "auto"
    /// and a code the engine does not know go as no language.
    func testLanguageSettingBecomesTheEngineRequest() {
        func request(_ language: String, _ engine: DictationEngine) -> EngineDecodeRequest {
            SettingsSnapshot(dictationLanguage: language, dictationEngine: engine).decodeRequest
        }
        XCTAssertEqual(request("auto", .whisper), .whisper(WhisperDecodeRequest(language: nil)))
        XCTAssertEqual(request("de", .whisper), .whisper(WhisperDecodeRequest(language: "de")))
        XCTAssertEqual(request("ja", .whisper), .whisper(WhisperDecodeRequest(language: "ja")))
        XCTAssertEqual(request("xx", .whisper), .whisper(WhisperDecodeRequest(language: nil)))
        XCTAssertEqual(request("auto", .parakeet), .parakeet(nil))
        XCTAssertEqual(request("de", .parakeet), .parakeet("de"))
        XCTAssertEqual(request("ja", .parakeet), .parakeet(nil), "Parakeet does not know Japanese")
        XCTAssertEqual(request("be", .parakeet), .parakeet(nil), "FluidAudio lists it, the model does not know it")
    }

    /// A typo in Parakeet's list would turn that language into "auto" without
    /// a word: every code must be a FluidAudio filter.
    func testEngineLanguageListsMatchTheEngines() {
        let parakeet = DictationEngine.parakeet.languages
        XCTAssertEqual(parakeet.count, 25)
        XCTAssertEqual(parakeet.filter { Language(rawValue: $0) == nil }, [])
        let whisper = DictationEngine.whisper.languages
        XCTAssertGreaterThanOrEqual(whisper.count, 99)
        XCTAssertTrue(parakeet.isSubset(of: whisper))
        XCTAssertTrue(whisper.isSuperset(of: ["zh", "ja", "ko", "ar", "hi"]))
    }

    func testKnownSubtitleHallucinationRemovesWholeSegment() {
        let filtered = WhisperSegmentDTO.removingKnownSubtitleHallucinations(
            from: [segment("Первая фраза"), segment("Спасибо за просмотр"), segment("Вторая фраза")]
        )

        XCTAssertEqual(filtered.map(\.text), ["Первая фраза", "Вторая фраза"])
    }

    func testKnownSubtitleHallucinationInsideLiveSpeechRemains() {
        let text = "Я сказал спасибо за просмотр и выключил запись"

        let filtered = WhisperSegmentDTO.removingKnownSubtitleHallucinations(from: [segment(text)])

        XCTAssertEqual(filtered.map(\.text), [text])
    }

    func testKnownSubtitleHallucinationIgnoresCaseWhitespaceAndTrailingPunctuation() {
        let filtered = WhisperSegmentDTO.removingKnownSubtitleHallucinations(
            from: [segment("  ПРОДОЛЖЕНИЕ   СЛЕДУЕТ…!!!  ")]
        )

        XCTAssertTrue(filtered.isEmpty)
    }

    func testKnownSubtitleHallucinationCanLeaveEmptyResult() {
        let filtered = WhisperSegmentDTO.removingKnownSubtitleHallucinations(
            from: [segment("Subscribe!"), segment("THANK YOU FOR WATCHING...")]
        )

        XCTAssertTrue(filtered.isEmpty)
    }

    func testLiveWhisperFactoryRefusesMissingModelFolder() async {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        do {
            _ = try await LiveWhisperEngineFactory().make(modelFolder: missingPath, prewarm: false)
            XCTFail("a missing model folder must not load")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The Whisper model is not downloaded: \(missingPath)")
        }
    }

    func testTokenizerIsFoundNextToTheModelWhereTheDownloaderPutsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent(ModelSource.whisper.destination, isDirectory: true)
        let tokenizer = root.appendingPathComponent(ModelSource.whisperTokenizer.destination, isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        XCTAssertNil(WhisperTokenizerLocator.folder(for: model))

        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))

        XCTAssertEqual(WhisperTokenizerLocator.folder(for: model), tokenizer.standardizedFileURL)
    }

    func testTokenizerDirectoryMustContainConfigAndTokenizerData() throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-large-v3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: model) }
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))

        XCTAssertFalse(WhisperTokenizerLocator.isCompleteTokenizerFolder(model))
    }

    func testPathFailureNeverFallsBackToPreviousEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(failures: ["B"])
        let cache = WhisperKitCache(factory: factory)
        let first = try await cache.transcribe(audioPath: "x", modelFolder: "A", request: request)
        XCTAssertEqual(first.segments.first?.text, "A")

        for _ in 0..<2 {
            do {
                _ = try await cache.transcribe(audioPath: "x", modelFolder: "B", request: request)
                XCTFail("B must fail")
            } catch is FakeWhisperError {
                // expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        let count = await factory.count(for: "B")
        XCTAssertEqual(count, 2)
    }

    func testPrepareThenTranscribeReusesPrewarmedEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory()
        let cache = WhisperKitCache(factory: factory)

        try await cache.prepare(modelFolder: "A")
        let result = try await cache.transcribe(
            audioPath: "x",
            modelFolder: "A",
            request: request
        )

        XCTAssertEqual(result.segments.first?.text, "A")
        let loadCount = await factory.count(for: "A")
        let modes = await factory.modes(for: "A")
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(modes, [true])
    }

    func testTranscribeWaitsForConcurrentPrepareAndReusesItsEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(loadDelay: .milliseconds(120))
        let cache = WhisperKitCache(factory: factory)
        let recorder = WhisperStateRecorder()
        let preparing = Task { try await cache.prepare(modelFolder: "A") }
        try await waitForLoad(factory, path: "A")

        let result = try await cache.transcribe(
            audioPath: "x",
            modelFolder: "A",
            request: request,
            progress: { recorder.append($0) }
        )
        try await preparing.value

        XCTAssertEqual(result.segments.first?.text, "A")
        let loadCount = await factory.count(for: "A")
        let modes = await factory.modes(for: "A")
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(modes, [true])
        XCTAssertEqual(recorder.states(), [.waiting, .ready])
    }

    func testFailedPrepareRetriesWithoutPrewarmOnDemand() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(failuresBeforeSuccess: ["A": 1])
        let cache = WhisperKitCache(factory: factory)

        do {
            try await cache.prepare(modelFolder: "A")
            XCTFail("Initial prepare must fail")
        } catch is FakeWhisperError {
            // expected
        }
        let result = try await cache.transcribe(
            audioPath: "x",
            modelFolder: "A",
            request: request
        )

        XCTAssertEqual(result.segments.first?.text, "A")
        let loadCount = await factory.count(for: "A")
        let modes = await factory.modes(for: "A")
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(modes, [true, false])
    }

    func testPreparePathSwitchEvictsPreviousEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory()
        let cache = WhisperKitCache(factory: factory)

        try await cache.prepare(modelFolder: "A")
        try await cache.prepare(modelFolder: "B")
        _ = try await cache.transcribe(
            audioPath: "x",
            modelFolder: "A",
            request: request
        )

        let aCount = await factory.count(for: "A")
        let bCount = await factory.count(for: "B")
        let aModes = await factory.modes(for: "A")
        XCTAssertEqual(aCount, 2)
        XCTAssertEqual(bCount, 1)
        XCTAssertEqual(aModes, [true, false])
    }

    func testCancellationDuringPrepareDoesNotCacheEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(loadDelay: .milliseconds(150))
        let cache = WhisperKitCache(factory: factory)
        let preparing = Task { try await cache.prepare(modelFolder: "A") }
        try await waitForLoad(factory, path: "A")
        preparing.cancel()

        do {
            try await preparing.value
            XCTFail("Cancelled prepare must throw")
        } catch is CancellationError {
            // expected
        }
        _ = try await cache.transcribe(
            audioPath: "x",
            modelFolder: "A",
            request: request
        )

        let loadCount = await factory.count(for: "A")
        let modes = await factory.modes(for: "A")
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(modes, [true, false])
    }

    func testConcurrentDecodesAreSerialized() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(decodeDelay: .milliseconds(80))
        let cache = WhisperKitCache(factory: factory)
        async let one = cache.transcribe(audioPath: "1", modelFolder: "A", request: request)
        async let two = cache.transcribe(audioPath: "2", modelFolder: "A", request: request)
        _ = try await (one, two)
        let possibleEngine = await factory.engine(for: "A")
        let engine = try XCTUnwrap(possibleEngine)
        let stats = await engine.stats()
        XCTAssertEqual(stats.maxActive, 1)
        XCTAssertEqual(stats.calls, 2)
    }

    func testCancelledWaiterNeverStartsDecode() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(decodeDelay: .milliseconds(250))
        let cache = WhisperKitCache(factory: factory)
        let first = Task { try await cache.transcribe(audioPath: "1", modelFolder: "A", request: request) }
        try await Task.sleep(for: .milliseconds(30))
        let waiter = Task { try await cache.transcribe(audioPath: "2", modelFolder: "A", request: request) }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }
        _ = try await first.value
        let possibleEngine = await factory.engine(for: "A")
        let engine = try XCTUnwrap(possibleEngine)
        let stats = await engine.stats()
        XCTAssertEqual(stats.calls, 1)
    }

    func testCancellationAfterQueueHandoffReleasesQueue() async {
        let factory = GatedWhisperFactory(gatedPath: "A")
        let cache = WhisperKitCache(factory: factory)
        let first = EngineDescriptor(engine: .whisper, modelPath: "A")
        let second = EngineDescriptor(engine: .whisper, modelPath: "B")
        let request = EngineDecodeRequest.whisper(
            WhisperDecodeRequest(language: "ru")
        )
        let probe = HandoffProbe()

        scenario: do {
            await cache.updateDesired(first)
            probe.start("warming") {
                try await cache.prepareDesired { state in
                    probe.record(state, for: "warming")
                    // Warm-up sees `.waiting` only on its second pass, in the same
                    // actor turn in which the first pass handed the queue to the
                    // waiter. Cancelling synchronously here lands after the hand-off
                    // and before the waiter resumes.
                    if state == .waiting { probe.cancel("waiter") }
                }
            }
            guard await eventually({ await factory.hasEnteredGate() }) else {
                XCTFail("Warm-up never started loading A")
                break scenario
            }
            probe.start("waiter") {
                _ = try await cache.transcribe(
                    audioPath: "queued", descriptor: first, request: request
                ) { state in
                    probe.record(state, for: "waiter")
                }
            }
            guard await eventually({ probe.states(for: "waiter").contains(.waiting) }) else {
                XCTFail("Waiter never queued behind warm-up")
                break scenario
            }
            // Runs after the waiter's actor turn, so the waiter is enqueued by now
            // and warm-up will take a second pass for B.
            await cache.updateDesired(second)
            await factory.open()

            let waiterEnded = await eventually { probe.outcome("waiter") != nil }
            XCTAssertTrue(waiterEnded, "Cancelled waiter never finished")
            XCTAssertEqual(probe.outcome("waiter"), .cancelled)
            XCTAssertEqual(
                Array(probe.states(for: "warming").prefix(3)), [.loading, .ready, .waiting],
                "Cancellation must land after the first pass released the queue to the waiter"
            )
            XCTAssertFalse(probe.states(for: "waiter").contains(.ready))
            let engineA = await factory.engine(for: "A")
            let cancelledDecodes = await engineA?.stats().calls
            XCTAssertEqual(cancelledDecodes, 0)

            guard await eventually({ probe.outcome("warming") != nil }) else {
                XCTFail("Cache wedged: warm-up stays queued after a cancellation that landed after the queue hand-off")
                break scenario
            }
            XCTAssertEqual(probe.outcome("warming"), .succeeded)
            let resident = await cache.residentDescriptorForTesting()
            XCTAssertEqual(resident, second)

            probe.start("next") {
                _ = try await cache.transcribe(audioPath: "next", descriptor: first, request: request)
            }
            let nextEnded = await eventually { probe.outcome("next") != nil }
            XCTAssertTrue(nextEnded, "Request after the cancelled hand-off never finished")
            XCTAssertEqual(probe.outcome("next"), .succeeded)
        }

        // Bounded cleanup on every path: a red run must end in a failure, not a hang.
        probe.cancelAll()
        await factory.open()
        let drained = await eventually { probe.allFinished }
        XCTAssertTrue(drained, "Scenario tasks still running after cleanup")
    }

    func testReleaseDuringLoadDoesNotRecacheEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(loadDelay: .milliseconds(150))
        let cache = WhisperKitCache(factory: factory)
        let loading = Task {
            try await cache.transcribe(audioPath: "1", modelFolder: "A", request: request)
        }
        try await Task.sleep(for: .milliseconds(30))
        await cache.release()
        do {
            _ = try await loading.value
            XCTFail("Released load must not commit")
        } catch is CancellationError {
            // expected
        }
        _ = try await cache.transcribe(audioPath: "2", modelFolder: "A", request: request)
        let count = await factory.count(for: "A")
        XCTAssertEqual(count, 2)
    }

    func testCancellationDuringLoadDoesNotCacheEngine() async throws {
        let request = WhisperDecodeRequest(language: "ru")
        let factory = FakeWhisperFactory(loadDelay: .milliseconds(150))
        let cache = WhisperKitCache(factory: factory)
        let loading = Task {
            try await cache.transcribe(audioPath: "1", modelFolder: "A", request: request)
        }
        try await Task.sleep(for: .milliseconds(30))
        loading.cancel()
        do {
            _ = try await loading.value
            XCTFail("Cancelled load must throw")
        } catch is CancellationError {
            // expected
        }
        _ = try await cache.transcribe(audioPath: "2", modelFolder: "A", request: request)
        let count = await factory.count(for: "A")
        XCTAssertEqual(count, 2)
    }

    func testParakeetLoaderEnablesOfflineModeBeforeFirstCall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        ModelHub.offlineMode = false
        let factory = LiveParakeetEngineFactory { url in
            XCTAssertTrue(ModelHub.offlineMode)
            return FakeParakeetEngine(path: url.path)
        }
        _ = try await factory.make(modelFolder: folder.path)
        XCTAssertTrue(ModelHub.offlineMode)
    }

    func testMissingParakeetModelFailsWithoutWhisperFallback() async {
        let whisper = FakeWhisperFactory()
        let cache = WhisperKitCache(factory: whisper)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        do {
            _ = try await cache.transcribe(
                audioPath: "x",
                descriptor: EngineDescriptor(engine: .parakeet, modelPath: missing),
                request: .parakeet(nil)
            )
            XCTFail("Missing Parakeet must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains(missing)) }
        let count = await whisper.count(for: missing)
        XCTAssertEqual(count, 0)
    }

    func testEngineSwitchReleasesResidentBeforeCreatingReplacement() async throws {
        let lifetime = EngineLifetimeProbe()
        let parakeet = FakeParakeetFactory(lifetime: lifetime)
        let cache = WhisperKitCache(
            factory: FakeWhisperFactory(lifetime: lifetime, retainEngines: false),
            parakeetFactory: parakeet
        )
        await cache.updateDesired(EngineDescriptor(engine: .whisper, modelPath: "A"))
        try await cache.prepareDesired()
        await cache.updateDesired(EngineDescriptor(engine: .parakeet, modelPath: "P"))
        try await cache.prepareDesired()
        XCTAssertEqual(lifetime.maximumLive, 1)
        XCTAssertEqual(lifetime.creationLiveCounts, [0, 0])
    }

    func testSwitchQueuedBehindDecodeCompletesSnapshotThenWarmsSelectedEngine() async throws {
        let parakeet = FakeParakeetFactory()
        let cache = WhisperKitCache(
            factory: FakeWhisperFactory(decodeDelay: .milliseconds(80)),
            parakeetFactory: parakeet
        )
        let decode = Task { try await cache.transcribe(
            audioPath: "x", modelFolder: "A",
            request: WhisperDecodeRequest(language: "ru")
        ) }
        try await Task.sleep(for: .milliseconds(10))
        let selected = EngineDescriptor(engine: .parakeet, modelPath: "P")
        await cache.updateDesired(selected)
        async let warm: Void = cache.prepareDesired()
        let result = try await decode.value
        XCTAssertEqual(result.segments.first?.text, "A")
        try await warm
        let resident = await cache.residentDescriptorForTesting()
        XCTAssertEqual(resident, selected)
    }

    func testRapidDesiredChangesEndAtLastSelectedDescriptor() async throws {
        let parakeet = FakeParakeetFactory()
        let cache = WhisperKitCache(factory: FakeWhisperFactory(), parakeetFactory: parakeet)
        let last = EngineDescriptor(engine: .whisper, modelPath: "W")
        await cache.updateDesired(last, generation: 2)
        await cache.updateDesired(EngineDescriptor(engine: .parakeet, modelPath: "P"), generation: 1)
        try await cache.prepareDesired()
        let resident = await cache.residentDescriptorForTesting()
        XCTAssertEqual(resident, last)
        let count = await parakeet.count()
        XCTAssertEqual(count, 0)
    }

    func testFileWhisperEvictionRestoresDesiredParakeetWarm() async throws {
        let parakeet = FakeParakeetFactory()
        let cache = WhisperKitCache(factory: FakeWhisperFactory(), parakeetFactory: parakeet)
        let selected = EngineDescriptor(engine: .parakeet, modelPath: "P")
        await cache.updateDesired(selected)
        try await cache.prepareDesired()
        _ = try await cache.transcribe(
            audioPath: "file", modelFolder: "W",
            request: WhisperDecodeRequest(language: "ru")
        )
        try await cache.prepareDesired()
        let resident = await cache.residentDescriptorForTesting()
        XCTAssertEqual(resident, selected)
        let count = await parakeet.count()
        XCTAssertEqual(count, 2)
    }

    func testDecodeTimerExcludesModelLoad() async throws {
        let cache = WhisperKitCache(factory: FakeWhisperFactory(
            loadDelay: .milliseconds(100), decodeDelay: .milliseconds(20)
        ))
        let result = try await cache.transcribe(
            audioPath: "x", modelFolder: "A",
            request: WhisperDecodeRequest(language: "ru")
        )
        XCTAssertGreaterThan(result.decodeDuration, 0.015)
        XCTAssertLessThan(result.decodeDuration, 0.08)
    }

    func testEngineDescriptorNormalizesEquivalentPaths() {
        XCTAssertEqual(
            EngineDescriptor(engine: .parakeet, modelPath: "/tmp/models/../parakeet"),
            EngineDescriptor(engine: .parakeet, modelPath: "/tmp/parakeet")
        )
    }
}
