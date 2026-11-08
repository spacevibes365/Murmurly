import Foundation
import XCTest
@testable import Murmurly

/// A capture whose start can be held (to land inside `.starting`) and whose
/// `writtenSeconds()` is whatever the test sets. `stop()` remembers the
/// feed's bytes at the moment it is called, before writing `metadata.json`,
/// so a test can prove the feed was already final by then.
private actor FeedCapture: MeetingCaptureBackend {
    private var holding = false
    private var writtenSecondsValue: TimeInterval = 0
    private var directory: URL?
    private(set) var startWasCancelled = false
    private(set) var feedBytesAtStop: Data?
    private(set) var stops = 0

    func hold() { holding = true }
    func release() { holding = false }
    func setWrittenSeconds(_ value: TimeInterval) { writtenSecondsValue = value }

    func start(in directory: URL) async throws -> Date {
        self.directory = directory
        // `try?`, not `try`: a cancelled task must still return a date, the
        // same shape `JointCapture` uses, so the recorder's own cancelled-
        // start path (not a thrown `CancellationError`) is the one exercised.
        for _ in 0..<1_000 where holding { try? await Task.sleep(for: .milliseconds(10)) }
        startWasCancelled = Task.isCancelled
        for name in ["system.caf", "microphone.caf"] {
            try Data([0]).write(to: directory.appendingPathComponent(name))
        }
        return Date(timeIntervalSinceReferenceDate: 1_000)
    }

    func writtenSeconds() async -> TimeInterval? { writtenSecondsValue }

    func stop() async throws -> [URL] {
        guard let directory else { throw SystemAudioCaptureError.notRunning }
        stops += 1
        feedBytesAtStop = try? Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        let metadata = MeetingMetadata(
            startedAt: "2026-10-20T10:00:00Z", endedAt: "2026-10-20T10:01:00Z",
            sampleRate: 48_000, state: "done", segments: []
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        return ["system.caf", "microphone.caf"].map { directory.appendingPathComponent($0) }
    }
}

/// A snapshot source driven by a fixed script: snapshots come out in order,
/// the last one repeating once the list is exhausted. A plain lock-guarded
/// class, not an actor: `MeetingPageSnapshot` is not `Sendable`, and an
/// actor method could not hand it back across its own isolation boundary.
private final class ScriptedPage: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [MeetingPageSnapshot]
    private var count = 0

    init(_ snapshots: [MeetingPageSnapshot]) {
        self.snapshots = snapshots
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func snapshot() -> MeetingPageSnapshot {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        guard !snapshots.isEmpty else { return .notFound }
        return snapshots[min(current - 1, snapshots.count - 1)]
    }
}

private actor QuietMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// A synthetic accessibility node for this file's own tests of the seam
/// between holder selection and the call feed — independent of
/// `MeetingPageReaderTests`' own `FakeNode`, which is private to that file.
private final class FakeAXNode: AccessibilityPageNode, @unchecked Sendable {
    var role: String
    var axURL: String?
    var domClassList: [String]
    var title: String?
    var value: String?
    var description: String?
    var children: [AccessibilityPageNode]
    var identifier: String?
    /// Stands in for the live `AXUIElement` a `.app` window would carry (1c);
    /// not read on a browser or `.appWeb` node's own candidate, only on a
    /// top-level `.app` window's. A plain, legal type on this test-only
    /// class — the protocol itself never names it, only the `Sendable`
    /// number `axElementAddress` below.
    var axElement: AnyObject?

    init(
        role: String = "AXGroup", axURL: String? = nil, classes: [String] = [],
        title: String? = nil, value: String? = nil, description: String? = nil,
        children: [AccessibilityPageNode] = [], identifier: String? = nil, axElement: AnyObject? = nil
    ) {
        self.role = role
        self.axURL = axURL
        self.domClassList = classes
        self.title = title
        self.value = value
        self.description = description
        self.children = children
        self.identifier = identifier
        self.axElement = axElement
    }

    var axElementAddress: UInt {
        axElement.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    }
}

/// Minimal synthetic Telemost and Zoom-like pages, just enough for one named
/// tile each, built for this file's own seam tests.
private enum FakePage {
    /// `room` lets a test move the same tab to another address without
    /// rebuilding the whole tree by hand.
    static func telemostArea(name: String, room: String = "abc123") -> FakeAXNode {
        let nameNode = FakeAXNode(classes: ["TextName_q1a"], title: name)
        let tile = FakeAXNode(classes: ["item_Kb2PJ", "itemDevices_aa11"], children: [nameNode])
        let grid = FakeAXNode(classes: ["GoloomParticipantsRenderer"], children: [tile])
        return FakeAXNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/\(room)", children: [grid])
    }

    static func telemostWindow(name: String, room: String = "abc123") -> FakeAXNode {
        FakeAXNode(role: "AXWindow", children: [telemostArea(name: name, room: room)])
    }

    /// Several tabs (areas) inside one window — a browser with more than one
    /// tab open.
    static func windowWithTabs(_ areas: [FakeAXNode]) -> FakeAXNode {
        FakeAXNode(role: "AXWindow", children: areas)
    }

    /// A made-up native-app row, shaped like Telemost's own classes.
    static let zoomLikeService = MeetingPageReader.Service(
        id: "zoom-test",
        place: .app(bundleID: "us.zoom.xos", windowIdentifier: "test-call-window"),
        classMatch: .prefix,
        gridClass: "GoloomParticipantsRenderer",
        tileClasses: ["item_", "newGridItem_"],
        tileDevicesClass: "itemDevices_",
        tileDisplayClass: "itemDisplay_",
        selfClass: "selfView_",
        nameClass: "TextName_",
        speakingClass: "rootStroke_"
    )

    /// `title` lets a test prove a window recreated with a different title is
    /// not the one that was pinned, even though its `AXIdentifier` (constant,
    /// like Zoom's own) stays the same. `element` stands in for the window's
    /// own `AXUIElement` (1c): a fresh `NSObject()` by default, so calling
    /// this twice — as a test does to build "the same window polled again"
    /// vs. "a new window" — gets two different objects unless the same one
    /// is explicitly passed through.
    static func zoomWindow(name: String, title: String? = nil, element: AnyObject = NSObject()) -> FakeAXNode {
        let nameNode = FakeAXNode(classes: ["TextName_q1a"], title: name)
        let tile = FakeAXNode(classes: ["item_Kb2PJ", "itemDevices_aa11"], children: [nameNode])
        let grid = FakeAXNode(classes: ["GoloomParticipantsRenderer"], children: [tile])
        return FakeAXNode(
            role: "AXWindow", title: title, children: [grid], identifier: "test-call-window", axElement: element
        )
    }
}

/// A holder snapshot that can be switched mid-test, with separate counts of
/// every read and of the reads that answered `nil` (unreadable).
private final class HolderScript: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<String>?
    private var count = 0
    private var nilCount = 0

    init(_ value: Set<String>?) { self.value = value }

    func set(_ newValue: Set<String>?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var nilCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return nilCount
    }

    func read() -> Set<String>? {
        lock.lock()
        count += 1
        let current = value
        if current == nil { nilCount += 1 }
        lock.unlock()
        return current
    }
}

/// Runs the real `MeetingPageReader.snapshot` over a fixed set of synthetic
/// windows, recording every `(holders, pin)` it was called with.
private final class PageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [String: [AccessibilityPageNode]]
    private let limits: MeetingPageReader.Limits
    private let services: [MeetingPageReader.Service]
    private var calls: [(holders: Set<String>, pin: MeetingPageReader.Pin?)] = []

    init(
        windows: [String: [AccessibilityPageNode]], limits: MeetingPageReader.Limits = .standard(),
        services: [MeetingPageReader.Service] = MeetingPageReader.services
    ) {
        self.windows = windows
        self.limits = limits
        self.services = services
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var recordedCalls: [(holders: Set<String>, pin: MeetingPageReader.Pin?)] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    /// Replaces the windows a later read sees — a tab moving to another
    /// room, a window closing, a window being recreated — without rebuilding
    /// the probe itself (which would also reset `calls`).
    func setWindows(_ newValue: [String: [AccessibilityPageNode]]) {
        lock.lock()
        windows = newValue
        lock.unlock()
    }

    func read(holders: Set<String>, pin: MeetingPageReader.Pin?) -> MeetingPageSnapshot {
        lock.lock()
        calls.append((holders, pin))
        let currentWindows = windows
        lock.unlock()
        return MeetingPageReader.snapshot(
            windows: currentWindows, holders: holders, pin: pin, limits: limits, services: services
        )
    }
}

/// A synthetic accessibility node, local to this file: proves that a
/// `MeetingPageSnapshot` actually produced by `MeetingPageReader.snapshot`
/// for a captions-based row (a native app's window, not a browser tab)
/// travels the same path to a `CallFeed.Event` that Telemost's class-based
/// snapshot already does. Not reused from `MeetingPageReaderTests.swift`:
/// `FakeNode` there is file-private. Every name is made up.
private final class JoinTestNode: AccessibilityPageNode, @unchecked Sendable {
    var role: String
    var axURL: String?
    var domClassList: [String] = []
    var title: String?
    var value: String?
    var description: String?
    var identifier: String?
    var children: [AccessibilityPageNode]
    /// Stands in for a top-level `.app` window's own `AXUIElement` (1c).
    var axElement: AnyObject?

    init(
        role: String = "AXGroup", description: String? = nil, identifier: String? = nil,
        children: [AccessibilityPageNode] = [], axElement: AnyObject? = nil
    ) {
        self.role = role
        self.description = description
        self.identifier = identifier
        self.children = children
        self.axElement = axElement
    }

    var axElementAddress: UInt {
        axElement.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    }
}

/// Records every pin `CallFeedWatcher` hands to `snapshotSource`, answering
/// with the scripted `Read` at that position (the last one repeating once
/// the list is exhausted) — an actor, since the watcher calls this from an
/// `async` context, not the plain lock the other scripted sources use.
private actor PinRecorder {
    private let reads: [CallFeedWatcher.Read]
    private(set) var pins: [MeetingPageReader.Pin?] = []

    init(reads: [CallFeedWatcher.Read]) {
        self.reads = reads
    }

    var count: Int { pins.count }

    func record(_ pin: MeetingPageReader.Pin?) -> CallFeedWatcher.Read {
        pins.append(pin)
        return reads[min(pins.count - 1, reads.count - 1)]
    }
}

/// A plain lock-guarded counter whose `increment()` hands back the value
/// after incrementing, so a caller can both advance and index off it in one
/// call.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class CallFeedWatcherTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("call-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func isolatedSettings() throws -> SettingsStore {
        SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings").path)))
    }

    /// `holderSource` defaults to a fixed Chrome helper, so a test that does
    /// not care about holder selection keeps the pre-selection behavior: the
    /// page is always asked for, exactly as before this card.
    private func makeRecorder(
        capture: FeedCapture, page: ScriptedPage, interval: Duration = .milliseconds(10),
        holderSource: @escaping @Sendable () -> Set<String>? = { ["com.google.Chrome.helper"] }
    ) -> MeetingRecorder {
        MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { [root] in try RecordingsStore().createSession(root: root!) },
            holderSource: holderSource,
            pageSnapshotSource: { _, _ in page.snapshot() },
            callFeedInterval: interval
        )
    }

    private func activate(_ recorder: MeetingRecorder, settings: SettingsStore) {
        let dictation = DictationCoordinator(mic: QuietMic(), indicator: RecordingIndicator(renderingEnabled: false))
        recorder.activate(settings: settings, permissions: PermissionManager(), dictation: dictation)
    }

    private func waitUntil(timeout: Int = 500, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never became true")
    }

    private func wait(_ recorder: MeetingRecorder, for state: MeetingRecorder.State) async throws {
        try await waitUntil { recorder.state == state }
        XCTAssertEqual(recorder.state, state)
    }

    private func feedLines(in directory: URL) throws -> [CallFeed.Event] {
        try CallFeed.read(in: directory) ?? []
    }

    private func feedExists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(CallFeed.fileName).path)
    }

    /// Up to 200 checks of 10 ms (2 s): some single read may already be in
    /// flight when the stop happens, so one further increase is allowed,
    /// but no more.
    private func assertCountSettles(_ count: @escaping @MainActor () -> Int) async throws {
        let baseline = count()
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            let current = count()
            XCTAssertLessThanOrEqual(current, baseline + 1, "kept growing after the stop")
        }
    }

    // MARK: - Tests

    /// The feed is already final (closed) by the time `stop()` reads it,
    /// before `metadata.json` is written — a plain stop.
    func testFeedIsClosedBeforeTheMetadataOnAStop() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage(Array(
            [
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: ["Анна Тестова"]),
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Борис Пример"], speaking: ["Борис Пример"]),
            ].repeated(times: 30)
        ))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 3 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let feedBytesAtStop = await capture.feedBytesAtStop
        let bytesAtStop = try XCTUnwrap(feedBytesAtStop)
        let finalBytes = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(bytesAtStop, finalBytes, "the feed must already be final when stop() reads it")

        try await assertCountSettles { page.callCount }
        let afterBytes = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(afterBytes, finalBytes, "nothing more was written after the stop")
    }

    /// The same guarantee on quit: `beginTermination()` must close the feed
    /// before the save's `metadata.json` too.
    func testFeedIsClosedBeforeTheMetadataOnQuit() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage(Array(
            [
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: ["Анна Тестова"]),
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Борис Пример"], speaking: ["Борис Пример"]),
            ].repeated(times: 30)
        ))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 3 }

        let saved = await recorder.beginTermination().value
        XCTAssertTrue(saved)

        let feedBytesAtStop = await capture.feedBytesAtStop
        let bytesAtStop = try XCTUnwrap(feedBytesAtStop)
        let finalBytes = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(bytesAtStop, finalBytes, "the feed must already be final when the quit-time stop reads it")

        try await assertCountSettles { page.callCount }
        let afterBytes = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(afterBytes, finalBytes)
    }

    /// A start cancelled mid-way (`stopCancelledStart`) never reaches the
    /// page at all, and leaves no feed file.
    func testCancelledStartReadsNoPageAndLeavesNoFeed() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage([MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: [])])
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        await capture.hold()
        recorder.toggle()
        try await wait(recorder, for: .starting)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)

        let quit = recorder.beginTermination()
        await capture.release()
        let saved = await quit.value
        XCTAssertTrue(saved)
        try await wait(recorder, for: .idle)

        let startWasCancelled = await capture.startWasCancelled
        XCTAssertTrue(startWasCancelled, "the start's own task must have been cancelled")
        XCTAssertEqual(page.callCount, 0, "the page was never read")
        XCTAssertFalse(feedExists(in: directory))
    }

    /// `t` is the capture's own `writtenSeconds()`, read right after each
    /// snapshot — never the wall clock, which keeps going through a hole in
    /// the tracks.
    func testTimeIsTheCapturesWrittenSecondsNotTheClock() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage([
            MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: ["Анна Тестова"]),
            MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Борис Пример"], speaking: ["Борис Пример"]),
            MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова", "Борис Пример"], speaking: []),
        ])
        let recorder = makeRecorder(capture: capture, page: page, interval: .milliseconds(50))
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        await capture.setWrittenSeconds(1.5)
        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        // The clock stands still (a "hole" in the tracks) while the second
        // snapshot is read — `writtenSeconds()` is bumped only once the
        // watcher has read exactly two snapshots (the script's own third one
        // must not be read before the clock moves): with ticks a full
        // `interval` apart, that leaves a wide margin before a third tick
        // could start.
        try await waitUntil { page.callCount >= 2 }
        await capture.setWrittenSeconds(2.25)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 3 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        // `finish()` appends one more line, at the clock's last known value
        // (2.25): `isUnchanged` compares without `t`, so it is written even
        // though the page's own content never changed again.
        XCTAssertEqual(lines.map(\.t), [1.5, 1.5, 2.25, 2.25])
        XCTAssertEqual(lines.last?.visible, false)
    }

    /// Ten identical reads, then one that differs only by cleaning (padding
    /// spaces around a name), then a real change: exactly two lines.
    func testOnlyChangesAreWritten() async throws {
        let capture = FeedCapture()
        let steady = MeetingPageSnapshot(
            found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Гость"], speaking: []
        )
        let paddedSameName = MeetingPageSnapshot(
            found: true, visible: true, selfName: "", selfSpeaking: false, people: [" Гость "], speaking: []
        )
        let changed = MeetingPageSnapshot(
            found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: ["Анна Тестова"]
        )
        var script = Array(repeating: steady, count: 10)
        script.append(paddedSameName)
        script += Array(repeating: changed, count: 10)
        let page = ScriptedPage(script)
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { page.callCount >= 21 }
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 2 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        // A third line is `finish()`'s own closing one, hidden and with no
        // names: the stop always appends it once anything was ever written.
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.people), [["Гость"], ["Анна Тестова"], []])
        XCTAssertEqual(lines.last?.visible, false)
    }

    /// A page that is never found leaves no file at all.
    func testNoPageEverFoundLeavesNoFile() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage([.notFound])
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { page.callCount >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        XCTAssertFalse(feedExists(in: directory))
    }

    /// Found, then not found many times in a row: exactly two lines, the
    /// second one hidden (not visible, nobody speaking, no own name).
    func testPageLostAfterBeingFoundIsWrittenAsHidden() async throws {
        let capture = FeedCapture()
        let found = MeetingPageSnapshot(
            found: true, visible: true, selfName: "Анна Тестова", selfSpeaking: true, people: ["Борис Пример"], speaking: ["Борис Пример"]
        )
        var script = [found]
        script += Array(repeating: MeetingPageSnapshot.notFound, count: 15)
        let page = ScriptedPage(script)
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { page.callCount >= 16 }
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 2 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertEqual(lines.count, 2)
        let hidden = lines[1]
        XCTAssertFalse(hidden.visible)
        XCTAssertNil(hidden.ownName, "a late null in self must take back the earlier own name")
        XCTAssertFalse(hidden.selfSpeaking)
        XCTAssertEqual(hidden.people, [])
        XCTAssertEqual(hidden.speaking, [])
    }

    /// The setting is off from before the start: the page is never read,
    /// and no file appears.
    func testSettingOffNeverReadsThePage() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage([MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: [])])
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        settings.namesFromCallWindow = false
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await Task.sleep(for: .milliseconds(100))

        recorder.toggle()
        try await wait(recorder, for: .idle)

        XCTAssertEqual(page.callCount, 0)
        XCTAssertFalse(feedExists(in: directory))
    }

    /// Turning the setting off while recording stops the watcher reading the
    /// page from then on, and the file stops changing.
    func testTurningTheSettingOffStopsReading() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage(Array(
            [
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: ["Анна Тестова"]),
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Борис Пример"], speaking: ["Борис Пример"]),
            ].repeated(times: 60)
        ))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        settings.namesFromCallWindow = false
        try await assertCountSettles { page.callCount }
        let bytesAfterOff = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        try await Task.sleep(for: .milliseconds(50))
        let bytesLater = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(bytesAfterOff, bytesLater, "the file must not change once the setting is off")

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    /// With no injected page source (the production default, `readLive`), a
    /// test process's recorder never reaches the live accessibility tree:
    /// `readLive` itself answers `.notFound` in a test process, so no feed
    /// file ever appears.
    /// Two separate barriers, neither related to the other: the watchdog's
    /// own snapshot source (unrelated here, fixed to `{ [] }` as in every
    /// other test in this file) never feeds the call feed's holder source,
    /// which keeps its production default — unreadable in a test process —
    /// and `readLive` itself refuses a live tree regardless.
    func testATestProcessRecorderNeverReachesTheLiveTree() async throws {
        let liveSnapshot = await MeetingPageReader.readLive(holders: ["com.google.Chrome.helper"], pin: nil)
        XCTAssertEqual(liveSnapshot, .notFound)

        let capture = FeedCapture()
        let recorder = MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { [root] in try RecordingsStore().createSession(root: root!) },
            callFeedInterval: .milliseconds(10)
        )
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await Task.sleep(for: .milliseconds(100))

        recorder.toggle()
        try await wait(recorder, for: .idle)

        XCTAssertFalse(feedExists(in: directory))
    }

    /// The feed's `service` field is whatever the snapshot itself says, not
    /// a constant inside `MeetingRecorder`: a snapshot carrying another
    /// service's id (here a made-up "bitrix24") must come out in the feed
    /// line as that id, not "telemost".
    func testFeedServiceComesFromTheSnapshotNotAConstant() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage(Array(
            [
                MeetingPageSnapshot(
                    found: true, visible: true, selfName: "", selfSpeaking: false,
                    people: ["Гость Один"], speaking: [], service: "bitrix24"
                ),
            ].repeated(times: 30)
        ))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        // The closing hidden line carries the same service id as the last
        // line actually written, not a guess.
        XCTAssertEqual(lines.map(\.service), ["bitrix24", "bitrix24"])
    }

    /// A snapshot read through `MeetingPageReader.snapshot` for a
    /// captions-based row (the native-app `Place`, read by `CaptionRules`,
    /// not by DOM classes) must reach `CallFeed.Event` through the very
    /// same `MeetingRecorder` → `CallFeedWatcher` path Telemost's own
    /// class-based snapshot already does: its `service`, `people` and
    /// `speaking` carried through unchanged.
    func testCaptionBasedSnapshotTravelsTheSamePathToCallFeedAsTelemost() async throws {
        let rules = MeetingPageReader.CaptionRules(
            tileRole: "AXTabGroup",
            statuses: ["Computer audio unmuted", "Video off"],
            statusCount: 2,
            speakingMarkers: ["active speaker"],
            listRole: "AXOutline",
            selfSuffix: " (me)"
        )
        let service = MeetingPageReader.Service(
            id: "zoom-test",
            place: .app(bundleID: "us.zoom.xos.test", windowIdentifier: "zm.meeting.window.main"),
            classMatch: .exact,
            gridClass: "",
            tileClasses: [],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            nameClass: "",
            speakingClass: "",
            captionRules: rules
        )
        let tile = JoinTestNode(
            role: "AXTabGroup", description: "Гость Один, Computer audio unmuted, Video off, active speaker"
        )
        let window = JoinTestNode(
            role: "AXWindow", identifier: "zm.meeting.window.main", children: [tile], axElement: NSObject()
        )
        let readSnapshot = MeetingPageReader.snapshot(
            windows: ["us.zoom.xos.test": [window]], holders: ["us.zoom.xos.test"], pin: nil, limits: .standard(), services: [service]
        )
        XCTAssertEqual(readSnapshot.service, "zoom-test")
        XCTAssertEqual(readSnapshot.people, ["Гость Один"])
        XCTAssertEqual(readSnapshot.speaking, ["Гость Один"])

        let capture = FeedCapture()
        let page = ScriptedPage(Array(repeating: readSnapshot, count: 30))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertEqual(lines.map(\.service), ["zoom-test", "zoom-test"])
        XCTAssertEqual(lines.first?.people, ["Гость Один"])
        XCTAssertEqual(lines.first?.speaking, ["Гость Один"])
    }

    /// On by default, and not written to `defaults` until a person flips it.
    func testNamesFromCallWindowIsOnByDefaultAndKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.appendingPathComponent("settings-default").path))
        let first = SettingsStore(defaults: defaults)
        XCTAssertTrue(first.namesFromCallWindow)
        XCTAssertNil(defaults.object(forKey: "meeting.namesFromCallWindow"), "on by default must not itself write anything")

        first.namesFromCallWindow = false
        XCTAssertEqual(defaults.object(forKey: "meeting.namesFromCallWindow") as? Bool, false)

        let second = SettingsStore(defaults: defaults)
        XCTAssertFalse(second.namesFromCallWindow)
    }

    // MARK: - The seam: holder selection → the call feed

    private func makeSeamRecorder(
        capture: FeedCapture, holderSource: @escaping @Sendable () -> Set<String>?, probe: PageProbe,
        interval: Duration = .milliseconds(10)
    ) -> MeetingRecorder {
        MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {},
            createSession: { [root] in try RecordingsStore().createSession(root: root!) },
            holderSource: holderSource,
            pageSnapshotSource: { holders, pin in probe.read(holders: holders, pin: pin) },
            callFeedInterval: interval
        )
    }

    /// No holder is ever known: the page is read (holders is an empty, not
    /// unreadable, set) but finds nothing to try, and no feed file appears.
    func testNoHoldersLeavesNoFeed() async throws {
        let capture = FeedCapture()
        let holders = HolderScript([])
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { holders.callCount >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        XCTAssertFalse(feedExists(in: directory))
    }

    /// The holder snapshot can never be read: every poll is skipped, the
    /// page is never asked for at all, and no feed file appears.
    func testUnreadHoldersBeforeTheFind_noReadNoFeed() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(nil)
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { holders.callCount >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        XCTAssertEqual(probe.count, 0, "the page must never be asked for while holders cannot be read")
        XCTAssertFalse(feedExists(in: directory))
    }

    // MARK: - Pinning the meeting itself, not merely the program

    /// Pinned to Telemost's room `abc123` in Chrome; the tab then moves to
    /// another room of the very same service and app. The recording must not
    /// follow it: once the room changes, a hidden line is written and no
    /// name from the new room ever appears.
    func testPinnedRoom_tabMovesToAnotherRoom_otherRoomsNamesNeverWritten() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        probe.setWindows(["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Два", room: "room-b")]])
        try await waitUntil { ((try? self.feedLines(in: directory)) ?? []).contains(where: { !$0.visible }) }
        try await waitUntil { probe.count >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.allSatisfy { !$0.people.contains("Гость Два") })
        XCTAssertEqual(lines.first?.visible, true)
        XCTAssertEqual(lines.first?.people, ["Гость Один"])
        XCTAssertTrue(lines.dropFirst().allSatisfy { !$0.visible })
    }

    /// Two tabs of the same service open at once, A first; the pinned
    /// choice (table order before a pin) fixes on A. A is then closed,
    /// leaving only B: the pinned tab is gone, so nothing is read — B's name
    /// must never be substituted for it.
    func testPinnedTab_closed_otherTabOfSameServiceNotSubstituted() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let tabA = FakePage.telemostArea(name: "Гость Один", room: "abc123")
        // Only the one room with tiles exists at first (2): a second
        // confirmed room beside it, before anything is pinned, would leave
        // the choice ambiguous and nothing would ever get pinned at all.
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.windowWithTabs([tabA])]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        // Now that A is pinned, a second tab of the same service appears
        // beside it — the pin, not the table, must decide which one is read.
        let tabB = FakePage.telemostArea(name: "Гость Два", room: "room-b")
        probe.setWindows(["com.google.Chrome": [FakePage.windowWithTabs([tabA, tabB])]])
        try await waitUntil { probe.count >= 5 }

        probe.setWindows([
            "com.google.Chrome": [FakePage.windowWithTabs([FakePage.telemostArea(name: "Гость Два", room: "room-b")])],
        ])
        try await waitUntil { ((try? self.feedLines(in: directory)) ?? []).contains(where: { !$0.visible }) }
        try await waitUntil { probe.count >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.allSatisfy { !$0.people.contains("Гость Два") })
    }

    /// Two separate windows, A and B, pinned to A; the window order then
    /// reverses. Order never matters once pinned — only the pinned address
    /// does — so every visible line still names A's own guest, never B's.
    func testPinnedTab_windowOrderChanges_pinnedRoomStillRead() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let windowA = FakePage.telemostWindow(name: "Гость Один", room: "abc123")
        let windowB = FakePage.telemostWindow(name: "Гость Два", room: "room-b")
        // Only A exists at first (2): B joins only after A is pinned, so the
        // initial pin is never ambiguous between two confirmed rooms.
        let probe = PageProbe(windows: ["com.google.Chrome": [windowA]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        probe.setWindows(["com.google.Chrome": [windowA, windowB]])
        let countAtSwitch = probe.count
        probe.setWindows(["com.google.Chrome": [windowB, windowA]])
        try await waitUntil { probe.count >= countAtSwitch + 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.filter(\.visible).allSatisfy { $0.people == ["Гость Один"] })
        XCTAssertTrue(lines.allSatisfy { !$0.people.contains("Гость Два") })
    }

    /// A native app's call pinned by its window's `AXIdentifier` and title;
    /// the window is then replaced by another one with the same (constant,
    /// Zoom-like) identifier but a different title — a different call,
    /// recreated rather than the same window kept open. The pinned read must
    /// not treat it as the same meeting.
    func testPinnedAppWindow_replacedByAnotherWindow_notRead() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["us.zoom.xos"])
        let probe = PageProbe(
            windows: ["us.zoom.xos": [FakePage.zoomWindow(name: "Гость Три", title: "Call A")]],
            services: [FakePage.zoomLikeService]
        )
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        probe.setWindows(["us.zoom.xos": [FakePage.zoomWindow(name: "Гость Четыре", title: "Call B")]])
        try await waitUntil { ((try? self.feedLines(in: directory)) ?? []).contains(where: { !$0.visible }) }
        try await waitUntil { probe.count >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.allSatisfy { !$0.people.contains("Гость Четыре") })
    }

    /// Pinned to a tab; a second tab with the very same address then appears
    /// in the same window. The choice can no longer tell the pinned tab from
    /// the new one, so a hidden line is written and nothing more is read
    /// while both remain — never a guess at which of the two is the pinned
    /// one.
    func testPinnedAddress_secondTabWithSameAddress_nothingRead() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        probe.setWindows([
            "com.google.Chrome": [FakePage.windowWithTabs([
                FakePage.telemostArea(name: "Гость Один"),
                FakePage.telemostArea(name: "Гость Два"),
            ])],
        ])
        try await waitUntil { ((try? self.feedLines(in: directory)) ?? []).contains(where: { !$0.visible }) }
        let countAfterHiddenLine = probe.count
        try await waitUntil { probe.count >= countAfterHiddenLine + 3 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.allSatisfy { !$0.people.contains("Гость Два") })
        XCTAssertTrue(lines.dropFirst().allSatisfy { !$0.visible })
    }

    // MARK: - The end of observation always closes with a hidden line

    /// A stop after the page was found: the last line in the file is hidden,
    /// with no names — the one before it is still the visible one.
    func testStop_lastLineIsHidden() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage(Array(
            [
                MeetingPageSnapshot(
                    found: true, visible: true, selfName: "", selfSpeaking: false,
                    people: ["Гость Один"], speaking: [], service: "telemost"
                ),
            ].repeated(times: 30)
        ))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        let last = try XCTUnwrap(lines.last)
        XCTAssertFalse(last.visible)
        XCTAssertNil(last.ownName)
        XCTAssertEqual(last.people, [])
        XCTAssertEqual(last.speaking, [])
        XCTAssertEqual(last.service, "telemost")
        XCTAssertTrue(lines[lines.count - 2].visible)
    }

    /// Turning the setting off mid-meeting closes the feed exactly like a
    /// stop: the last line is hidden, and nothing more is written after it.
    func testTurningTheSettingOffMidMeeting_lastLineIsHidden() async throws {
        let capture = FeedCapture()
        let page = ScriptedPage(Array(
            [
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Анна Тестова"], speaking: ["Анна Тестова"]),
                MeetingPageSnapshot(found: true, visible: true, selfName: "", selfSpeaking: false, people: ["Борис Пример"], speaking: ["Борис Пример"]),
            ].repeated(times: 60)
        ))
        let recorder = makeRecorder(capture: capture, page: page)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        settings.namesFromCallWindow = false
        try await assertCountSettles { page.callCount }

        let lines = try feedLines(in: directory)
        XCTAssertEqual(lines.last?.visible, false)

        let bytesAfterOff = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        try await Task.sleep(for: .milliseconds(50))
        let bytesLater = try Data(contentsOf: directory.appendingPathComponent(CallFeed.fileName))
        XCTAssertEqual(bytesAfterOff, bytesLater, "nothing more is written once the feed is closed")

        recorder.toggle()
        try await wait(recorder, for: .idle)
    }

    /// Found once with Chrome's helper holding the microphone, so the page is
    /// pinned; the holder snapshot then stops being readable at all. Before
    /// this card an unreadable holder list always skipped the read, pinned or
    /// not — but once pinned, the read must not depend on holders any more:
    /// the pinned page keeps being read, with `pin` set on every call.
    func testUnreadHoldersAfterThePin_pinnedPageStillRead() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        let countAtSwitch = probe.count
        holders.set(nil)
        try await waitUntil { probe.count >= countAtSwitch + 3 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let calls = probe.recordedCalls
        for call in calls[countAtSwitch...] {
            XCTAssertNotNil(call.pin, "an unreadable holder list must not stop the pinned page being read")
        }
        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.filter(\.visible).allSatisfy { $0.people == ["Гость Один"] })
    }

    /// Found once, pinned to Telemost in Chrome; the holder snapshot then
    /// reads as empty (nobody holds the microphone any more, briefly) —
    /// holders no longer matter once pinned, so the pinned row keeps being
    /// read and the name is never dropped.
    func testHoldersGoneAfterThePin_pinnedRowStillRead() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let probe = PageProbe(windows: ["com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")]])
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        holders.set([])
        try await waitUntil { probe.count >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let calls = probe.recordedCalls
        XCTAssertNil(calls.first?.pin)
        let expectedPin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        for call in calls.dropFirst() {
            XCTAssertEqual(call.pin, expectedPin)
        }
        let lines = try feedLines(in: directory)
        // `finish()`'s own closing line is hidden, same as every other stop.
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.visible && $0.people == ["Гость Один"] })
        XCTAssertEqual(lines.last?.visible, false)
    }

    /// Pinned to Telemost in Chrome; a second program (made-up, Zoom-shaped)
    /// then holds the microphone with a call of its own. The recording must
    /// not switch to it: every line stays Telemost, in Chrome, with the
    /// first guest's name.
    func testPinnedRecordingDoesNotSwitchToZoom() async throws {
        let capture = FeedCapture()
        let holders = HolderScript(["com.google.Chrome.helper"])
        let probe = PageProbe(
            windows: [
                "com.google.Chrome": [FakePage.telemostWindow(name: "Гость Один")],
                "us.zoom.xos": [FakePage.zoomWindow(name: "Гость Три")],
            ],
            services: [MeetingPageReader.services[0], FakePage.zoomLikeService]
        )
        let recorder = makeSeamRecorder(capture: capture, holderSource: { holders.read() }, probe: probe)
        let settings = try isolatedSettings()
        activate(recorder, settings: settings)

        recorder.toggle()
        try await wait(recorder, for: .recording)
        let directory = try XCTUnwrap(recorder.currentSession?.directory)
        try await waitUntil { (try? self.feedLines(in: directory).count) ?? 0 >= 1 }

        holders.set(["us.zoom.xos"])
        try await waitUntil { probe.count >= 5 }

        recorder.toggle()
        try await wait(recorder, for: .idle)

        let lines = try feedLines(in: directory)
        XCTAssertTrue(lines.allSatisfy { $0.service == "telemost" })
        XCTAssertTrue(lines.allSatisfy { !$0.people.contains("Гость Три") })
        // `finish()`'s own closing line is hidden, same as every other stop.
        XCTAssertTrue(lines.dropLast().allSatisfy(\.visible))
        XCTAssertEqual(lines.last?.visible, false)
    }

    // MARK: - A find without a confirmed tile must never be pinned (2)

    /// `found: true, visible: false` first (an area with no tile at all —
    /// `MeetingPageReader.snapshot` itself must never produce such a thing
    /// any more after (2), but `CallFeedWatcher` guards against it on its
    /// own too, old API, old risk: before this card, `pin` was set on any
    /// `.found`), then `visible: true` with a different meeting entirely.
    /// The watcher's own `pin` must still be unset after the first read —
    /// seen by the pin it hands to `snapshotSource` on the next poll — and
    /// set only once the second, confirmed read comes in.
    func testFoundButNotVisible_isNotPinned() async throws {
        let emptyPin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/empty")
        )
        let confirmedPin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/room-b")
        )
        let reads: [CallFeedWatcher.Read] = [
            .found(
                CallFeed.Event(t: 0, service: "telemost", visible: false, ownName: nil, selfSpeaking: false, people: [], speaking: []),
                emptyPin
            ),
            .found(
                CallFeed.Event(t: 0, service: "telemost", visible: true, ownName: nil, selfSpeaking: false, people: ["Гость Один"], speaking: []),
                confirmedPin
            ),
        ]
        let recorder = PinRecorder(reads: reads)

        let watcher = CallFeedWatcher(
            directory: root,
            snapshotSource: { pin in await recorder.record(pin) },
            writtenSeconds: { 0 },
            isEnabled: { true },
            interval: .milliseconds(10)
        )
        await watcher.start()
        var settled = false
        for _ in 0..<500 {
            if await recorder.count >= 3 { settled = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(settled, "condition never became true")
        await watcher.finish()

        let pins = await recorder.pins
        XCTAssertNil(pins[0], "the very first read has no pin yet")
        XCTAssertNil(pins[1], "the first, unconfirmed read must not have set the pin")
        XCTAssertEqual(
            pins[2], confirmedPin,
            "the pin must be the confirmed meeting, never the empty one read first"
        )
    }

    /// K3 of the other-desktop card: a highlight change that happens while
    /// the page IS on screen, sandwiched between two off-screen reads, must
    /// never count toward `offscreenHighlightChanges` — a service that
    /// freezes a page it cannot see would otherwise look as if it kept
    /// updating it.
    func testOnScreenHighlightChangeBetweenOffscreenReadsIsNotCounted() async throws {
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        func event(speaking: [String], offscreen: Bool) -> CallFeed.Event {
            CallFeed.Event(
                t: 0, service: "telemost", visible: true, ownName: nil, selfSpeaking: false,
                people: ["Арина Веткина", "Борис Луков"], speaking: speaking, offscreen: offscreen
            )
        }
        let reads: [CallFeedWatcher.Read] = [
            .found(event(speaking: ["Арина Веткина"], offscreen: true), pin),
            .found(event(speaking: ["Борис Луков"], offscreen: false), pin),
            .found(event(speaking: ["Борис Луков"], offscreen: true), pin),
        ]
        // A plain lock-guarded counter, not `PinRecorder`: `isEnabled` is a
        // synchronous closure and must stop the loop itself, right after the
        // script's last read, so the watcher never repeats that last
        // (off-screen) read an unpredictable number of times and inflates
        // `offscreenReadCount` beyond what this test can name exactly.
        let served = LockedCounter()
        let watcher = CallFeedWatcher(
            directory: root,
            snapshotSource: { _ in
                let index = served.increment() - 1
                return reads[min(index, reads.count - 1)]
            },
            writtenSeconds: { 0 },
            isEnabled: { served.count < reads.count },
            interval: .milliseconds(10)
        )
        await watcher.start()
        var settled = false
        for _ in 0..<500 {
            if served.count >= reads.count { settled = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(settled, "condition never became true")
        await watcher.finish()

        let offscreenReadCount = await watcher.offscreenReadCount
        let offscreenHighlightChanges = await watcher.offscreenHighlightChanges
        XCTAssertEqual(offscreenReadCount, 2)
        XCTAssertEqual(
            offscreenHighlightChanges, 0,
            "the on-screen read in between must not make this look like a change seen while off screen"
        )
    }

    // MARK: - K2 (the live-transcript card): events() outlives a feed file that never opens

    /// The feed's directory has no parent on disk, so every write fails to
    /// open the file (`O_CREAT` itself fails with `ENOENT`): `events()` must
    /// still hand back what was found, for `LiveTranscript`'s names — this
    /// watcher must never stop remembering events in memory just because the
    /// disk write failed.
    func testEventsStayInMemoryEvenWhenTheFeedFileCannotBeOpened() async throws {
        let unopenable = root.appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let event = CallFeed.Event(
            t: 0, service: "telemost", visible: true, ownName: "Я", selfSpeaking: false,
            people: ["Гость Один"], speaking: ["Гость Один"]
        )
        let pin = MeetingPageReader.Pin(service: "telemost", app: "com.google.Chrome", meeting: nil)
        let served = LockedCounter()
        let watcher = CallFeedWatcher(
            directory: unopenable,
            snapshotSource: { _ in
                _ = served.increment()
                return .found(event, pin)
            },
            writtenSeconds: { 0 },
            isEnabled: { served.count < 3 },
            interval: .milliseconds(10)
        )
        await watcher.start()
        var settled = false
        for _ in 0..<500 {
            if served.count >= 3 { settled = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(settled, "condition never became true")
        await watcher.finish()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unopenable.appendingPathComponent(CallFeed.fileName).path)
        )
        let events = await watcher.events()
        XCTAssertFalse(events.isEmpty, "events must be kept in memory even though the feed file never opened")
        XCTAssertEqual(events.first?.people, ["Гость Один"])
    }
}

private extension Array {
    func repeated(times: Int) -> [Element] {
        var result: [Element] = []
        for _ in 0..<times { result += self }
        return result
    }
}
