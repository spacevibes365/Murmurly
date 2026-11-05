import Darwin
import XCTest
@testable import Murmurly

/// A synthetic accessibility node: build a fake Telemost page without ever
/// touching a real `AXUIElement` or a real browser window.
private final class FakeNode: AccessibilityPageNode, @unchecked Sendable {
    var role: String
    var axURL: String?
    var domClassList: [String]
    var title: String?
    var value: String?
    var description: String?
    var children: [AccessibilityPageNode]
    var identifier: String?
    /// Stands in for a top-level `.app` window's own `AXUIElement` (1c): read
    /// only on such a window; `nil` (the default, as for every node that is
    /// not one) answers `axElementAddress` with 0, which `WindowElement`
    /// reads as "no object" — a window candidate with no element at all can
    /// never be pinned, by the very same rule a real one without one would
    /// follow.
    var axElement: AnyObject?

    init(
        role: String = "AXGroup",
        axURL: String? = nil,
        classes: [String] = [],
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        children: [AccessibilityPageNode] = [],
        identifier: String? = nil,
        axElement: AnyObject? = nil
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

/// Counts how many times its `role`, `children` or `domClassList` were read,
/// so a test can prove a window was never even opened: the traversal reads
/// every node's `domClassList` and `children` at least once before deciding
/// anything about it.
private final class CountingNode: AccessibilityPageNode, @unchecked Sendable {
    private let lock = NSLock()
    private let wrapped: FakeNode
    private var accessCount = 0

    init(_ wrapped: FakeNode) {
        self.wrapped = wrapped
    }

    var accesses: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessCount
    }

    private func touch() {
        lock.lock()
        accessCount += 1
        lock.unlock()
    }

    var role: String { touch(); return wrapped.role }
    var axURL: String? { touch(); return wrapped.axURL }
    var domClassList: [String] { touch(); return wrapped.domClassList }
    var title: String? { touch(); return wrapped.title }
    var value: String? { touch(); return wrapped.value }
    var description: String? { touch(); return wrapped.description }
    var identifier: String? { touch(); return wrapped.identifier }
    var axElementAddress: UInt { touch(); return wrapped.axElementAddress }
    var children: [AccessibilityPageNode] { touch(); return wrapped.children }
}

/// A synthetic node that also carries `domIdentifier` (`AXDOMIdentifier`),
/// for Jitsi's own tile — found by DOM id, not by any class. `FakeNode`
/// itself stays untouched: every other fixture's own tile is still found by
/// class alone, through the protocol's own `nil` default.
private final class DOMIdentifiedNode: AccessibilityPageNode, @unchecked Sendable {
    var role: String
    var axURL: String?
    var domClassList: [String]
    var title: String?
    var value: String?
    var description: String?
    var children: [AccessibilityPageNode]
    var identifier: String?
    var domIdentifier: String?

    init(
        role: String = "AXGroup", axURL: String? = nil, classes: [String] = [], title: String? = nil,
        children: [AccessibilityPageNode] = [], domIdentifier: String? = nil
    ) {
        self.role = role
        self.axURL = axURL
        self.domClassList = classes
        self.title = title
        self.children = children
        self.domIdentifier = domIdentifier
    }
}

/// Wraps a `FakeNode`, counting only `domIdentifier` reads (always answering
/// `nil`, as the protocol default would), so a test can prove a row without
/// `selfTileIdentifier` (Telemost) never asks for it: the `if let` in
/// `searchTileDetails` short-circuits on the `nil` identifier before ever
/// reading this property.
private final class DOMIdentifierCountingNode: AccessibilityPageNode, @unchecked Sendable {
    private let lock = NSLock()
    private let wrapped: FakeNode
    private var accessCount = 0

    init(_ wrapped: FakeNode) {
        self.wrapped = wrapped
    }

    var accesses: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessCount
    }

    var role: String { wrapped.role }
    var axURL: String? { wrapped.axURL }
    var domClassList: [String] { wrapped.domClassList }
    var title: String? { wrapped.title }
    var value: String? { wrapped.value }
    var description: String? { wrapped.description }
    var identifier: String? { wrapped.identifier }
    var axElementAddress: UInt { wrapped.axElementAddress }
    var domIdentifier: String? {
        lock.lock()
        accessCount += 1
        lock.unlock()
        return nil
    }
    var children: [AccessibilityPageNode] {
        wrapped.children.map { child -> AccessibilityPageNode in
            guard let fakeChild = child as? FakeNode else { return child }
            return DOMIdentifierCountingNode(fakeChild)
        }
    }
}

/// A node whose `title` answers slowly, like a browser tab that takes a
/// moment to respond. Used only to prove the read runs off the caller's own
/// thread — never found in a passing test by coincidence of speed.
private final class SlowFakeNode: AccessibilityPageNode, @unchecked Sendable {
    var role: String = "AXGroup"
    var axURL: String?
    var domClassList: [String] = ["TextName_slow"]
    var value: String?
    var description: String?
    var children: [AccessibilityPageNode] = []
    var title: String? {
        Thread.sleep(forTimeInterval: 0.2)
        return "Гость"
    }
}

/// Builds the synthetic tree pieces every test shares: a tile, a grid, a
/// meeting area, a browser window. Class names always carry a made-up hash
/// suffix (`_Kb2PJ`-style), as the real page does, so a test that passed by
/// matching a literal class name would be caught by every other test too.
/// Every name used anywhere in this file is made up — never a real person's
/// name — as the factory's own rules require.
private enum Telemost {
    static func tile(name: String, isSelf: Bool = false, speaking: Bool = false, selfOnDescendant: Bool = false) -> FakeNode {
        tile(nameNode: FakeNode(classes: ["TextName_q1a"], title: name), isSelf: isSelf, speaking: speaking, selfOnDescendant: selfOnDescendant)
    }

    static func tile(nameNode: FakeNode, isSelf: Bool = false, speaking: Bool = false, selfOnDescendant: Bool = false) -> FakeNode {
        var rootClasses = ["root_7f2"]
        if speaking { rootClasses.append("rootStroke_9z1") }
        let rootLayer = FakeNode(classes: rootClasses)
        var tileClasses = ["item_Kb2PJ", "itemDevices_aa11"]
        if isSelf && !selfOnDescendant { tileClasses.append("selfView_m0p") }
        var tileChildren: [AccessibilityPageNode] = [nameNode, rootLayer]
        if isSelf && selfOnDescendant {
            tileChildren.append(FakeNode(classes: ["selfView_m0p"]))
        }
        return FakeNode(classes: tileClasses, children: tileChildren)
    }

    static func screenShareTile(children: [AccessibilityPageNode] = []) -> FakeNode {
        FakeNode(classes: ["item_Kb2PJ", "itemDisplay_7h3"], children: children)
    }

    static func grid(tiles: [FakeNode]) -> FakeNode {
        FakeNode(classes: ["GoloomParticipantsRenderer"], children: tiles)
    }

    static func meetingArea(grid: FakeNode?) -> FakeNode {
        FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/abc123", children: grid.map { [$0] } ?? [])
    }

    static func window(_ children: [AccessibilityPageNode]) -> FakeNode {
        FakeNode(role: "AXWindow", children: children)
    }
}

/// A `TextName_` node with no text of its own — Chrome's actual shape for
/// Telemost (both the browser tab and the program's embedded page): the name
/// lives in the `value` of its first `AXStaticText` child, not on the node
/// itself. Every name passed in is made up.
private func telemostNameInStaticText(_ name: String) -> FakeNode {
    FakeNode(classes: ["TextName_q1a"], children: [FakeNode(role: "AXStaticText", value: name)])
}

/// Builds a synthetic tree in the shape of Jitsi Meet's own page (a `span`
/// per tile, class `videocontainer`; a name `span`, class `displayname`; a
/// speaking tile carries `dominant-speaker`; the own tile is found only by
/// its DOM id, `localVideoContainer` — it carries no class of its own),
/// measured on a public `meet.ffmuc.net` stand, 2026-10-30. Every name is
/// made up; `TestRoomAlpha` is a made-up room.
private enum Jitsi {
    static func tile(name: String, isSelf: Bool = false, speaking: Bool = false) -> DOMIdentifiedNode {
        let nameNode = DOMIdentifiedNode(classes: ["displayname"], title: name)
        var classes = ["videocontainer"]
        if speaking { classes.append("dominant-speaker") }
        return DOMIdentifiedNode(
            classes: classes, children: [nameNode], domIdentifier: isSelf ? "localVideoContainer" : nil
        )
    }

    /// A tile whose class carries only the per-session hash class
    /// (`css-…-activeSpeaker`) and not `dominant-speaker` itself: must never
    /// read as speaking.
    static func tileWithHashedSpeakerClassOnly(name: String) -> DOMIdentifiedNode {
        let nameNode = DOMIdentifiedNode(classes: ["displayname"], title: name)
        return DOMIdentifiedNode(classes: ["videocontainer", "css-1a2b3c-activeSpeaker"], children: [nameNode])
    }

    static func meetingArea(
        tiles: [AccessibilityPageNode], server: String = "meet.ffmuc.net"
    ) -> DOMIdentifiedNode {
        DOMIdentifiedNode(role: "AXWebArea", axURL: "https://\(server)/TestRoomAlpha", children: tiles)
    }

    static func window(_ children: [AccessibilityPageNode]) -> DOMIdentifiedNode {
        DOMIdentifiedNode(role: "AXWindow", children: children)
    }
}

/// Builds a synthetic tree in the shape of Zoom's own program window, for
/// the real `"zoom"` row in `MeetingPageReader.services` (not the generic
/// `ZoomShape` fixture below, which is a stand-in for a hypothetical
/// caption-based service and predates this card). Statuses, markers and
/// suffixes are the ones read off Zoom 7.1.9's own English and Russian
/// `Localizable.strings`. Every name is made up.
private enum ZoomNative {
    static let windowIdentifier = "zm.meeting.window.main"
    static let bundleID = "us.zoom.xos"

    static func tile(
        name: String, speaking: Bool = false, handRaised: Bool = false,
        audio: String = "Computer audio unmuted", video: String = "Video off",
        handRaisedPhrase: String = "Hand raised", speakingMarker: String = "active speaker"
    ) -> FakeNode {
        var description = "\(name), \(audio), \(video)"
        if handRaised { description += ", \(handRaisedPhrase)" }
        if speaking { description += ", \(speakingMarker)" }
        return FakeNode(role: "AXTabGroup", description: description)
    }

    /// The participants list's own row for the local user, found only
    /// inside `AXOutline`'s subtree — never a tile's own description.
    static func selfListRow(name: String, suffix: String = " (me)") -> FakeNode {
        FakeNode(title: "\(name)\(suffix)")
    }

    static func participantsList(_ rows: [AccessibilityPageNode]) -> FakeNode {
        FakeNode(role: "AXOutline", children: rows)
    }

    /// `element` stands in for the window's own `AXUIElement` (1c): a fresh
    /// `NSObject()` by default, so two calls build two different windows
    /// unless the very same object is passed through on purpose.
    static func window(
        identifier: String = ZoomNative.windowIdentifier, children: [AccessibilityPageNode], element: AnyObject? = NSObject()
    ) -> FakeNode {
        FakeNode(role: "AXWindow", children: children, identifier: identifier, axElement: element)
    }

    /// Zoom's own Russian phrases, symbol for symbol as read off its 7.1.9
    /// `ru.lproj/Localizable.strings` (`LN_Plist_Accessibility_*` keys): used
    /// only as values inside a fixture bundle built by `stubBundle`, never as
    /// a literal in `Sources/`.
    static let russianStrings: [String: String] = [
        "LN_Plist_Accessibility_VoIP_Unmuted_20044": "Звук компьютера включен",
        "LN_Plist_Accessibility_VoIP_Muted_20044": "Звук компьютера выключен",
        "LN_Plist_Accessibility_Tele_Unmuted_20044": "Звук телефона включен",
        "LN_Plist_Accessibility_Tele_Muted_20044": "Звук телефона выключен",
        "LN_Plist_Accessibility_No_Audio_20044": "Звуковое устройство не подключено",
        "LN_Plist_Accessibility_Video_On_20044": "Видео вкл.",
        "LN_Plist_Accessibility_Video_Off_20044": "Видео выкл.",
        "LN_Plist_Accessibility_No_Video_20044": "Видео не подключено",
        "LN_Plist_Accessibility_HandRaised_20044": "Рука поднята",
        "LN_Plist_Accessibility_Share_Screen_41522": "Демонстрация экрана",
        "LN_Studio_Active_Speaker_391545": "Активный докладчик",
        "LN-183814_%@ (me)": "%@ (я)",
    ]

    /// The same keys with their real English values, the same shape
    /// `en.lproj` ships, built here only so a test can prove a second
    /// language is merged rather than replacing the row's own fallback.
    static let englishStrings: [String: String] = [
        "LN_Plist_Accessibility_VoIP_Unmuted_20044": "Computer audio unmuted",
        "LN_Plist_Accessibility_VoIP_Muted_20044": "Computer audio muted",
        "LN_Plist_Accessibility_Tele_Unmuted_20044": "Telephone unmuted",
        "LN_Plist_Accessibility_Tele_Muted_20044": "Telephone muted",
        "LN_Plist_Accessibility_No_Audio_20044": "No audio connected",
        "LN_Plist_Accessibility_Video_On_20044": "Video on",
        "LN_Plist_Accessibility_Video_Off_20044": "Video off",
        "LN_Plist_Accessibility_No_Video_20044": "No video connected",
        "LN_Plist_Accessibility_HandRaised_20044": "Hand raised",
        "LN_Plist_Accessibility_Share_Screen_41522": "Screen sharing",
        "LN_Studio_Active_Speaker_391545": "Active speaker",
        "LN-183814_%@ (me)": "%@ (me)",
    ]

    /// Writes a fake Zoom-shaped bundle — `<root>/zoom.us.app/Contents/Resources/<lang>.lproj/Localizable.strings`,
    /// one text (NeXTSTEP-style) `.strings` file per language, UTF-16
    /// encoded like the real program's own — and returns the `.app`
    /// folder's own URL. A plain static helper cannot register its own
    /// cleanup; the caller must do so with `addTeardownBlock`.
    static func stubBundle(languages: [String: [String: String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appURL = root.appendingPathComponent("zoom.us.app")
        for (language, entries) in languages {
            let lprojURL = appURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: true)
            var text = ""
            for (key, value) in entries {
                let escapedKey = key.replacingOccurrences(of: "\"", with: "\\\"")
                let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
                text += "\"\(escapedKey)\" = \"\(escapedValue)\";\n"
            }
            guard let data = text.data(using: .utf16) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: lprojURL.appendingPathComponent("Localizable.strings"))
        }
        return appURL
    }
}

/// Builds a synthetic tree in the shape of Zoom's web client, Speaker view
/// (Vexa's `zoom-speakers.ts`): one large tile whose class is one of the two
/// Vexa observed, the name a `span` inside `.video-avatar__avatar-footer`
/// nested in that tile. Every name is made up.
private enum ZoomWeb {
    static func bigTile(name: String, tileClass: String = "single-main-container__video-frame") -> FakeNode {
        let footer = FakeNode(classes: ["video-avatar__avatar-footer"], title: name)
        return FakeNode(classes: [tileClass], children: [footer])
    }

    static func meetingArea(_ children: [AccessibilityPageNode], address: String = "https://app.zoom.us/wc/1234/join") -> FakeNode {
        FakeNode(role: "AXWebArea", axURL: address, children: children)
    }

    static func window(_ children: [AccessibilityPageNode]) -> FakeNode {
        FakeNode(role: "AXWindow", children: children)
    }
}

/// Builds a synthetic tree in the shape of Google Meet's own page. Meet
/// publishes no stable classes; every class below is one candidate observed
/// on a third-party open-source project reading the same page (Granola:
/// `dkjMxf` tile, `aGWPv` own tile, `kssMZb` speaking; Vexa/Whadio:
/// `notranslate`/`zWGUib`/`XWGOtd` name, `Oaajhc`/`HX2H7`/`wEsLMd`/`OgVli`
/// speaking, `gjg47c` the resting (non-speaking) indicator). Every name is
/// made up, and `abc-defg-hij` is a made-up room code.
private enum Meet {
    static func tile(
        name: String, nameClass: String = "notranslate", tileClass: String = "dkjMxf",
        isSelf: Bool = false, speaking: Bool = false, speakingClass: String = "kssMZb", silenced: Bool = false
    ) -> FakeNode {
        let nameNode = FakeNode(classes: [nameClass], title: name)
        var indicatorClasses: [String] = []
        if speaking { indicatorClasses.append(speakingClass) }
        if silenced { indicatorClasses.append("gjg47c") }
        let indicator = FakeNode(classes: indicatorClasses)
        var tileClasses = [tileClass]
        if isSelf { tileClasses.append("aGWPv") }
        return FakeNode(classes: tileClasses, children: [nameNode, indicator])
    }

    static func meetingArea(tiles: [FakeNode], address: String = "https://meet.google.com/abc-defg-hij") -> FakeNode {
        FakeNode(role: "AXWebArea", axURL: address, children: tiles)
    }

    static func window(_ children: [AccessibilityPageNode]) -> FakeNode {
        FakeNode(role: "AXWindow", children: children)
    }
}

/// Builds a synthetic tree in the shape of a native call program's own
/// window, read by `CaptionRules` instead of DOM classes — Zoom's own shape
/// (`AXTabGroup` tiles, "Computer audio unmuted"/"Video off", an active-
/// speaker marker in two languages, a participants-list row ending " (me)"),
/// used only as a fixture: this card does not add a Zoom row to
/// `MeetingPageReader.services`. Every name is made up.
private enum ZoomShape {
    static let windowIdentifier = "zm.meeting.window.main"

    static func rules() -> MeetingPageReader.CaptionRules {
        MeetingPageReader.CaptionRules(
            tileRole: "AXTabGroup",
            statuses: ["Computer audio unmuted", "Computer audio muted", "Video off", "Video on"],
            statusCount: 2,
            speakingMarkers: ["active speaker", "Активный докладчик"],
            listRole: "AXOutline",
            selfSuffix: " (me)"
        )
    }

    static func service(windowIdentifier: String = ZoomShape.windowIdentifier) -> MeetingPageReader.Service {
        MeetingPageReader.Service(
            id: "zoom-test",
            place: .app(bundleID: "us.zoom.xos.test", windowIdentifier: windowIdentifier),
            classMatch: .exact,
            gridClass: "",
            tileClasses: [],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            nameClass: "",
            speakingClass: "",
            captionRules: rules()
        )
    }

    static func tile(
        name: String, speaking: Bool = false,
        statuses: [String] = ["Computer audio unmuted", "Video off"],
        children: [AccessibilityPageNode] = []
    ) -> FakeNode {
        var description = "\(name), \(statuses.joined(separator: ", "))"
        if speaking { description += ", active speaker" }
        return FakeNode(role: "AXTabGroup", description: description, children: children)
    }

    static func window(
        identifier: String = ZoomShape.windowIdentifier, children: [AccessibilityPageNode], element: AnyObject? = NSObject()
    ) -> FakeNode {
        FakeNode(role: "AXWindow", children: children, identifier: identifier, axElement: element)
    }
}

/// Builds a synthetic tree in the shape of Bitrix24's own call UI
/// (`modules/call/install/js/call/core/src/view/call-user.js`,
/// bitrix24-core-corp, version 25.750.0): a tile is
/// `div.bx-messenger-videocall-user` (the own tile adds
/// `bx-messenger-videocall-user-self`), its name
/// `span.bx-messenger-videocall-user-name`, and the active-speaker
/// highlight `bx-messenger-videocall-user-talking` on the tile's own root
/// — all exact class names, no per-session hash, no grid wrapper. Every
/// name and portal address below is made up.
private enum Bitrix24 {
    static func tile(name: String, isSelf: Bool = false, speaking: Bool = false) -> FakeNode {
        var classes = ["bx-messenger-videocall-user"]
        if isSelf { classes.append("bx-messenger-videocall-user-self") }
        if speaking { classes.append("bx-messenger-videocall-user-talking") }
        let nameNode = FakeNode(classes: ["bx-messenger-videocall-user-name"], title: name)
        return FakeNode(classes: classes, children: [nameNode])
    }

    static func meetingArea(
        children: [AccessibilityPageNode], portal: String = "testportal.bitrix24.ru", path: String = "video/AbC123xyz"
    ) -> FakeNode {
        FakeNode(role: "AXWebArea", axURL: "https://\(portal)/\(path)", children: children)
    }

    static func window(_ children: [AccessibilityPageNode]) -> FakeNode {
        FakeNode(role: "AXWindow", children: children)
    }
}

/// Builds a synthetic tree in Microsoft Teams' guessed shape
/// (`MeetingPageReader.teamsCaptionRules`): unverified, to be replaced from
/// the owner's own first live snapshot (see that constant's own comment).
/// Every name below is made up.
private enum TeamsShape {
    /// A participant tile: an `AXGroup` whose own description is "Name,
    /// Muted" or "Name, Unmuted" — the one shape `teamsCaptionRules` parses.
    static func tile(name: String, status: String) -> FakeNode {
        FakeNode(role: "AXGroup", description: "\(name), \(status)")
    }

    /// A UI element that merely carries a description on the same role as a
    /// tile (Teams' own "Meeting controls", "Chat", a device picker) — never
    /// a comma-plus-status, so it must never parse as a person.
    static func interfaceGroup(description: String) -> FakeNode {
        FakeNode(role: "AXGroup", description: description)
    }

    /// The participants list (`AXOutline`), with the local user's own row
    /// ending in `teamsCaptionRules.selfSuffix`.
    static func roster(selfName: String) -> FakeNode {
        FakeNode(role: "AXOutline", children: [FakeNode(title: "\(selfName) (You)")])
    }

    /// The call's own `AXWebArea`, with its tiles (and roster, if any)
    /// nested one level inside an outer `AXGroup` that carries no
    /// description of its own — the same role as a tile, with none of its
    /// own tiles at the very top: `descendsIntoUnparsedTiles` must walk
    /// through it rather than stop, the way Zoom's row deliberately does.
    static func page(url: String? = nil, children: [AccessibilityPageNode]) -> FakeNode {
        let outer = FakeNode(role: "AXGroup", children: children)
        return FakeNode(role: "AXWebArea", axURL: url, children: [outer])
    }
}

final class MeetingPageReaderTests: XCTestCase {
    private func limits(maxNodes: Int = 5000, maxDepth: Int = 40, seconds: TimeInterval = 5) -> MeetingPageReader.Limits {
        MeetingPageReader.Limits(maxNodes: maxNodes, maxDepth: maxDepth, deadline: Date().addingTimeInterval(seconds))
    }

    /// Every existing test reads one browser (Chrome, held by its helper),
    /// so holder selection always picks exactly the one pair the table used
    /// to try unconditionally: the traversal and the budget spend are
    /// identical to before this card.
    private func readInChrome(
        _ windows: [AccessibilityPageNode], limits: MeetingPageReader.Limits,
        services: [MeetingPageReader.Service] = MeetingPageReader.services, pin: MeetingPageReader.Pin? = nil
    ) -> MeetingPageSnapshot {
        MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: ["com.google.Chrome.helper"],
            pin: pin, limits: limits, services: services
        )
    }

    /// A made-up native-app row, shaped like Telemost's own classes so the
    /// same tile builders apply, to prove an `.app` row is read only in its
    /// own program's window.
    private func zoomLikeService() -> MeetingPageReader.Service {
        MeetingPageReader.Service(
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
    }

    // MARK: - Two participants, self and other

    func testTwoParticipants_selfAndOther() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Я Сам", isSelf: true),
            Telemost.tile(name: "Участник Первый"),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertTrue(snapshot.visible)
        XCTAssertEqual(snapshot.selfName, "Я Сам")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Участник Первый"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    func testSelfRecognizedBySelfViewOnDescendant_notOnlyTileRoot() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Я Сам", isSelf: true, selfOnDescendant: true),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.selfName, "Я Сам")
        XCTAssertEqual(snapshot.people, [])
    }

    /// Chrome's real shape, found live 2026-11-01: `TextName_…` carries no
    /// title, value or description of its own, and the name is the `value`
    /// of its first `AXStaticText` child. Covers the `telemost` row's own
    /// bug — on the previous code the tile has no name at all and is
    /// dropped, so neither `selfName` nor any guest is read.
    func testTelemostChrome_nameInStaticTextChildOfTextName_readsSelfGuestsAndSpeaker() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(nameNode: telemostNameInStaticText("Анна Тестова"), isSelf: true),
            Telemost.tile(nameNode: telemostNameInStaticText("Борис Пример"), speaking: true),
            Telemost.tile(nameNode: telemostNameInStaticText("Гость Три")),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertTrue(snapshot.visible)
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    // MARK: - Speaking highlight

    func testSpeakingHighlightsOther_notSelf() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Я Сам", isSelf: true, speaking: false),
            Telemost.tile(name: "Участник Первый", speaking: true),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.speaking, ["Участник Первый"])
    }

    func testSpeakingHighlightsSelf() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Я Сам", isSelf: true, speaking: true),
            Telemost.tile(name: "Участник Первый", speaking: false),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.speaking, [])
    }

    // MARK: - Two tiles with the same name

    func testDuplicateNames_dedupedInPeople_secondHighlightVisibleInSpeaking() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Гость", speaking: false),
            Telemost.tile(name: "Гость", speaking: true),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Гость"])
        // A naive implementation that skips a tile whose name is already in
        // `people` would miss that this very tile is the one speaking.
        XCTAssertEqual(snapshot.speaking, ["Гость"])
    }

    // MARK: - A screen-share tile is not a person

    func testScreenShareTile_withoutDevicesClassOrName_isNotAPerson() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Участник Первый"),
            Telemost.screenShareTile(),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Участник Первый"])
    }

    /// The screen-share tile's own subtree must never be opened: a decoy
    /// subtree big enough to exhaust a tight node budget, with a real tile
    /// right after it in the same grid. Finding the real tile proves the
    /// display tile's children were never visited.
    func testScreenShareTile_subtreeNeverOpened_realTileStillFound() {
        let decoyChildren = (0..<200).map { FakeNode(classes: ["decoy_\($0)"]) }
        let grid = Telemost.grid(tiles: [
            Telemost.screenShareTile(children: decoyChildren),
            Telemost.tile(name: "Участник Первый"),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits(maxNodes: 12))

        XCTAssertTrue(snapshot.visible)
        XCTAssertEqual(snapshot.people, ["Участник Первый"])
    }

    // MARK: - Hash suffixes vary; only the prefixes are matched

    func testClassHashSuffixesDoNotMatter_onlyPrefixesAnchorTheRules() {
        let nameNode = FakeNode(classes: ["TextName_zzHash9"], title: "Участник Второй")
        let rootLayer = FakeNode(classes: ["root_1", "rootStroke_differentHash"])
        let tile = FakeNode(classes: ["newGridItem_otherHash", "itemDevices_anotherHash"], children: [nameNode, rootLayer])
        let grid = FakeNode(classes: ["GoloomParticipantsRenderer_someSuffix"], children: [tile])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.people, ["Участник Второй"])
        XCTAssertEqual(snapshot.speaking, ["Участник Второй"])
    }

    // MARK: - No Telemost page at all

    func testNoTelemostTab_notFound() {
        let windows = [Telemost.window([FakeNode(role: "AXWebArea", axURL: "https://example.com/")])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - Addresses: only private-join is the meeting area, only /j/ is descended into

    func testPrivateJoinURL_isTheMeetingAreaDirectly() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/xyz", children: [grid])
        let windows = [Telemost.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.people, ["Участник Первый"])
    }

    func testShellURL_descendsIntoNestedPrivateJoinArea() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let nestedArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/xyz", children: [grid])
        let shell = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/j/abc123", children: [nestedArea])
        let windows = [Telemost.window([shell])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.people, ["Участник Первый"])
    }

    /// Neither the shell nor the meeting area: Telemost's own home page, a
    /// settings tab, anything that isn't `/j/` or `/private-join/`. Must not
    /// be opened at all — not its children, not its classes — even though it
    /// happens to contain something that looks like a participants grid.
    func testOtherTelemostPage_neitherShellNorMeetingArea_neverOpened() {
        let plantedGrid = Telemost.grid(tiles: [Telemost.tile(name: "НеДолженНайтись")])
        let otherPage = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/", children: [plantedGrid])
        let windows = [Telemost.window([otherPage])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Same rule, but proven by budget: the other Telemost page carries a
    /// large subtree that would exhaust a tight node limit if it were ever
    /// descended into. A real meeting area sits right after it in the same
    /// window; finding it proves the other page's subtree was never opened.
    func testOtherTelemostPage_budgetUntouched_realMeetingAreaStillFound() {
        let bigSubtree = (0..<200).map { FakeNode(classes: ["decoy_\($0)"]) }
        let otherPage = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/settings", children: bigSubtree)
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let realArea = Telemost.meetingArea(grid: grid)
        let windows = [Telemost.window([otherPage, realArea])]

        let snapshot = readInChrome(windows, limits: limits(maxNodes: 12))

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.people, ["Участник Первый"])
    }

    // MARK: - A page bigger than the budget

    func testNodeLimitExceededBeforeAreaFound_notFound() {
        // A deep, wide decoy tree with no Telemost page in it at all, large
        // enough to spend a tiny node budget before the traversal gives up.
        func decoy(depth: Int) -> FakeNode {
            guard depth > 0 else { return FakeNode(classes: ["leaf_\(depth)"]) }
            return FakeNode(children: (0..<4).map { _ in decoy(depth: depth - 1) })
        }
        let windows = [Telemost.window([decoy(depth: 6)])]

        let snapshot = readInChrome(windows, limits: limits(maxNodes: 20))

        // Same snapshot as a page that was never there: an aborted search
        // before the meeting area was located must not claim `found`.
        XCTAssertEqual(snapshot, .notFound)
    }

    func testTimeLimitExceededBeforeAreaFound_notFound_withoutSleeping() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]
        // The deadline is already in the past: the very first budget check
        // must trip it, with no `Task.sleep` or `usleep` anywhere in this test.
        let expiredLimits = MeetingPageReader.Limits(maxNodes: 5000, maxDepth: 40, deadline: Date().addingTimeInterval(-1))

        let start = Date()
        let snapshot = readInChrome(windows, limits: expiredLimits)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(snapshot, .notFound)
        XCTAssertLessThan(elapsed, 0.25)
    }

    // MARK: - A page bigger than the budget, after the area was already found

    /// Pinned (2): without a pin, a candidate the budget cut short while
    /// reading its tiles can never be confirmed one way or the other, so the
    /// whole read is `.notFound` instead (the test right below). With a pin,
    /// the old invariant still holds: `found`, with nothing claimed about
    /// any particular tile.
    func testNodeLimitExceededAfterAreaFound_resetsEverythingButFound() {
        let manyTiles = (0..<50).map { Telemost.tile(name: "Гость \($0)") }
        let grid = Telemost.grid(tiles: manyTiles)
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )

        // Enough budget to find the meeting area (one AXWindow, one
        // AXWebArea) but not enough left to read the whole grid.
        let snapshot = readInChrome(windows, limits: limits(maxNodes: 5), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, [])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// The same budget, without a pin: a candidate the budget cut short
    /// while reading its tiles can never be confirmed, so nothing is read —
    /// never a guess that it was the right (or the only) area.
    func testPrePin_budgetCutShort_notFound() {
        let manyTiles = (0..<50).map { Telemost.tile(name: "Гость \($0)") }
        let grid = Telemost.grid(tiles: manyTiles)
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits(maxNodes: 5))

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Pinned (2): without a pin, an area the budget cut short while
    /// reading its tiles can never be confirmed, so `.notFound` instead.
    func testDepthLimitExceeded_afterAreaFound_resetsEverythingButFound() {
        // A tile nested far deeper than the depth limit allows, inside an
        // already-found meeting area.
        var node: FakeNode = Telemost.tile(name: "Участник Первый")
        for _ in 0..<30 {
            node = FakeNode(children: [node])
        }
        let grid = Telemost.grid(tiles: [node])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )

        let snapshot = readInChrome(windows, limits: limits(maxDepth: 5), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.people, [])
    }

    // MARK: - A name is trimmed, and falls back from title to value to description

    func testNameWhitespacePadding_sameAsTrimmedName_dedupedInPeople() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Гость"),
            Telemost.tile(name: " Гость "),
        ])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Гость"])
    }

    func testNameTitleWhitespaceOnly_fallsBackToValue() {
        let nameNode = FakeNode(classes: ["TextName_q1a"], title: "  \n  ", value: "Участник Первый")
        let grid = Telemost.grid(tiles: [Telemost.tile(nameNode: nameNode)])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Участник Первый"])
    }

    func testNameTitleAndValueWhitespaceOnly_fallsBackToDescription() {
        let nameNode = FakeNode(classes: ["TextName_q1a"], title: "", value: " ", description: "Участник Второй")
        let grid = Telemost.grid(tiles: [Telemost.tile(nameNode: nameNode)])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Участник Второй"])
    }

    func testNameAllFieldsWhitespaceOrEmpty_notAPerson() {
        let nameNode = FakeNode(classes: ["TextName_q1a"], title: "  ", value: "", description: "\n")
        let grid = Telemost.grid(tiles: [Telemost.tile(nameNode: nameNode)])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    // MARK: - A row with exact-match classes, shaped like Bitrix24 but with
    // its own synthetic grid and devices classes, read through the same
    // traversal when passed in explicitly

    /// `bx-messenger-videocall-user` and friends are exact class names, not
    /// prefixes: a service row with `classMatch: .exact` must find a tile,
    /// its own name, and nobody else's class accidentally matching as a
    /// prefix of another. This row's own `gridClass` and `tileDevicesClass`
    /// are not part of the real `bitrix24` row in `MeetingPageReader.services`
    /// below (which has neither) — only proof that the traversal is driven by
    /// the row, not by Telemost's own constants.
    private func bitrix24Service(shells: [MeetingPageReader.Address] = []) -> MeetingPageReader.Service {
        MeetingPageReader.Service(
            id: "bitrix24",
            place: .browser(
                meetingAreas: [MeetingPageReader.Address(domains: ["bitrix24test.example"], pathPrefix: "/call/")],
                shells: shells
            ),
            classMatch: .exact,
            gridClass: "bx-messenger-videocall-grid",
            tileClasses: ["bx-messenger-videocall-user"],
            tileDevicesClass: "bx-messenger-videocall-user",
            tileDisplayClass: "bx-messenger-videocall-user-display",
            selfClass: "bx-messenger-videocall-user-self",
            nameClass: "bx-messenger-videocall-user-name",
            speakingClass: "bx-messenger-videocall-user-talking"
        )
    }

    func testExactClassMatchRow_bitrix24Style_readsThroughTheSameTraversal() {
        let selfNameNode = FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Анна Тестова")
        let selfTile = FakeNode(
            classes: ["bx-messenger-videocall-user", "bx-messenger-videocall-user-self"], children: [selfNameNode]
        )
        let otherNameNode = FakeNode(
            classes: ["bx-messenger-videocall-user-name", "bx-messenger-videocall-user-talking"], title: "Борис Пример"
        )
        let otherTile = FakeNode(classes: ["bx-messenger-videocall-user"], children: [otherNameNode])
        let grid = FakeNode(classes: ["bx-messenger-videocall-grid"], children: [selfTile, otherTile])
        let area = FakeNode(role: "AXWebArea", axURL: "https://bitrix24test.example/call/xyz", children: [grid])
        let windows = [Telemost.window([area])]

        let snapshot = readInChrome(windows, limits: limits(), services: [bitrix24Service()])

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "bitrix24")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// This synthetic row (its own `gridClass`, a separate `tileDevicesClass`)
    /// is not the real `bitrix24` row in the default table, and its made-up
    /// domain `bitrix24test.example` doesn't contain `.bitrix24.` either: the
    /// default table (what `readLive` actually uses) must not find this page.
    func testExactClassMatchRow_notInDefaultServices_defaultTraversalNeverSeesIt() {
        let nameNode = FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Гость Один")
        let tile = FakeNode(classes: ["bx-messenger-videocall-user"], children: [nameNode])
        let grid = FakeNode(classes: ["bx-messenger-videocall-grid"], children: [tile])
        let area = FakeNode(role: "AXWebArea", axURL: "https://bitrix24test.example/call/xyz", children: [grid])
        let windows = [Telemost.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - `.exact` and `.prefix` must disagree on a near-miss class

    private func bitrix24ExactVsPrefixService(classMatch: MeetingPageReader.ClassMatch) -> MeetingPageReader.Service {
        MeetingPageReader.Service(
            id: "bitrix24-exact-vs-prefix",
            place: .browser(
                meetingAreas: [MeetingPageReader.Address(domains: ["bitrix24test.example"], pathPrefix: "/call/")]
            ),
            classMatch: classMatch,
            gridClass: "bx-messenger-videocall-grid",
            tileClasses: ["bx-messenger-videocall-user"],
            tileDevicesClass: "bx-messenger-videocall-user",
            tileDisplayClass: "bx-messenger-videocall-user-display",
            selfClass: "bx-messenger-videocall-user-self",
            nameClass: "bx-messenger-videocall-user-name",
            speakingClass: "bx-messenger-videocall-user-talking"
        )
    }

    /// Classes `…-talking-hint` and `…-self-preview` stand in for the exact
    /// `…-talking` and `…-self` classes: under `.exact` they must never
    /// match (a plain string comparison), but under `.prefix` they do (both
    /// classes start with the shorter pattern). One synthetic row run twice,
    /// through `com.google.Chrome`'s own window shape, with only the match
    /// mode changed, must give two different answers — proof that
    /// `matchesClass` actually tells the two modes apart, not just that it
    /// compiles two cases.
    func testClassMatchMode_bitrix24Style_exactAndPrefixDisagreeOnNearMissClasses() {
        func window() -> FakeNode {
            let talkingHintNode = FakeNode(classes: ["bx-messenger-videocall-user-talking-hint"])
            let nameNode1 = FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Boris Example")
            let tile1 = FakeNode(classes: ["bx-messenger-videocall-user"], children: [nameNode1, talkingHintNode])

            let selfPreviewNode = FakeNode(classes: ["bx-messenger-videocall-user-self-preview"])
            let nameNode2 = FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Anna Example")
            let tile2 = FakeNode(classes: ["bx-messenger-videocall-user"], children: [nameNode2, selfPreviewNode])

            let grid = FakeNode(classes: ["bx-messenger-videocall-grid"], children: [tile1, tile2])
            let area = FakeNode(role: "AXWebArea", axURL: "https://bitrix24test.example/call/xyz", children: [grid])
            return FakeNode(role: "AXWindow", children: [area], identifier: "com.google.Chrome")
        }

        let exactSnapshot = readInChrome(
            [window()], limits: limits(), services: [bitrix24ExactVsPrefixService(classMatch: .exact)]
        )
        XCTAssertEqual(exactSnapshot.speaking, [])
        XCTAssertEqual(exactSnapshot.selfName, "")
        XCTAssertEqual(Set(exactSnapshot.people), ["Boris Example", "Anna Example"])

        let prefixSnapshot = readInChrome(
            [window()], limits: limits(), services: [bitrix24ExactVsPrefixService(classMatch: .prefix)]
        )
        XCTAssertEqual(prefixSnapshot.speaking, ["Boris Example"])
        XCTAssertEqual(prefixSnapshot.selfName, "Anna Example")
        XCTAssertFalse(prefixSnapshot.people.contains("Anna Example"))
    }

    // MARK: - No shell rule at all: a shell address is never descended into

    /// An empty `shells` list must never act as a wildcard: without a guard,
    /// a row that leaves it unset would open any tab at all as a shell to
    /// search inside. Proven with the real Telemost shell shape, so the
    /// nested area would be found if the guard were missing.
    func testNoShellRule_shellAddressIsNeverDescendedInto() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let nestedArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/xyz", children: [grid])
        let shell = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/j/abc123", children: [nestedArea])
        let windows = [Telemost.window([shell])]
        let service = MeetingPageReader.Service(
            id: "telemost",
            place: .browser(meetingAreas: [MeetingPageReader.Address(domains: ["telemost.yandex.ru"], pathPrefix: "/private-join/")]),
            classMatch: .prefix,
            gridClass: "GoloomParticipantsRenderer",
            tileClasses: ["item_", "newGridItem_"],
            tileDevicesClass: "itemDevices_",
            tileDisplayClass: "itemDisplay_",
            selfClass: "selfView_",
            nameClass: "TextName_",
            speakingClass: "rootStroke_"
        )

        let snapshot = readInChrome(windows, limits: limits(), services: [service])

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - readLive never prompts in a test process

    func testReadLive_inTestProcess_returnsNotFoundWithoutTouchingAccessibility() async {
        // This test host is itself a test process (`TestIsolation.isTestProcess`),
        // so `readLive` must bail out before it ever asks whether Accessibility
        // is trusted, let alone request the system prompt.
        let snapshot = await MeetingPageReader.readLive(holders: ["com.google.Chrome.helper"], pin: nil)

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - The read hops off the caller's own thread

    /// Calls `snapshotOffMainQueue` from the main actor over a tree whose
    /// name node answers slowly (0.2 s). If the traversal ran synchronously
    /// on the caller's thread, work queued on the main queue right after
    /// would have to wait behind it; off the caller's thread, that work runs
    /// almost immediately, well inside the 0.1 s timeout below.
    func testSnapshotOffMainQueue_doesNotBlockTheCallersThread() async {
        let rootLayer = FakeNode(classes: ["root_1"])
        let tile = FakeNode(classes: ["item_a", "itemDevices_a"], children: [SlowFakeNode(), rootLayer])
        let grid = Telemost.grid(tiles: [tile])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let readLimits = limits()
        let mainQueueRanWhileReadWasPending = XCTestExpectation(description: "main queue work ran while the read was still pending")
        let task = Task { @MainActor in
            await MeetingPageReader.snapshotOffMainQueue(windows: ["com.google.Chrome": windows], holders: ["com.google.Chrome.helper"], pin: nil, limits: readLimits)
        }
        DispatchQueue.main.async { mainQueueRanWhileReadWasPending.fulfill() }

        await fulfillment(of: [mainQueueRanWhileReadWasPending], timeout: 0.1)
        let snapshot = await task.value

        XCTAssertEqual(snapshot.people, ["Гость"])
    }

    func testSnapshotOffMainQueue_stillRespectsDeadline() async {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]
        let expiredLimits = MeetingPageReader.Limits(maxNodes: 5000, maxDepth: 40, deadline: Date().addingTimeInterval(-1))

        let snapshot = await MeetingPageReader.snapshotOffMainQueue(windows: ["com.google.Chrome": windows], holders: ["com.google.Chrome.helper"], pin: nil, limits: expiredLimits)

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - Selecting the row by who holds the microphone

    func testChromeHelperHoldsTheMicrophone_telemostTabInChromeIsRead() {
        let holders = MeetingWatchdog.holderBundleIDs(
            in: [MeetingWatchdog.ProcessSnapshot(pid: 501, bundleID: "com.google.Chrome.helper", isRunningInput: true)],
            ownPID: 1
        )
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: holders, pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.people, ["Гость Один"])
    }

    func testOnlyZoomHoldsTheMicrophone_telemostTabInChromeIsNotRead() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let countingWindow = CountingNode(Telemost.window([Telemost.meetingArea(grid: grid)]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [countingWindow]], holders: ["us.zoom.xos"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
        XCTAssertEqual(countingWindow.accesses, 0, "Chrome's windows must never be opened: Zoom has no row")
    }

    func testNoHolders_nothingIsRead() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let countingWindow = CountingNode(Telemost.window([Telemost.meetingArea(grid: grid)]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [countingWindow]], holders: [], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
        XCTAssertEqual(countingWindow.accesses, 0)

        // The same, from a snapshot where nobody is actually running input.
        let holders = MeetingWatchdog.holderBundleIDs(
            in: [MeetingWatchdog.ProcessSnapshot(pid: 502, bundleID: "com.google.Chrome.helper", isRunningInput: false)],
            ownPID: 1
        )
        XCTAssertTrue(holders.isEmpty)
    }

    func testPinned_holdersNoLongerMatter() {
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        let chromeGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let chromeWindows = [Telemost.window([Telemost.meetingArea(grid: chromeGrid)])]

        let withoutHolders = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": chromeWindows], holders: [], pin: pin, limits: limits()
        )
        XCTAssertTrue(withoutHolders.found)
        XCTAssertEqual(withoutHolders.people, ["Гость Один"])

        let zoomGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let zoomWindow = CountingNode(FakeNode(role: "AXWindow", children: [zoomGrid], identifier: "test-call-window"))
        let withZoomHolding = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": chromeWindows, "us.zoom.xos": [zoomWindow]],
            holders: ["us.zoom.xos"], pin: pin, limits: limits(), services: [MeetingPageReader.services[0], zoomLikeService()]
        )
        XCTAssertEqual(withZoomHolding.app, "com.google.Chrome")
        XCTAssertEqual(withZoomHolding.people, ["Гость Один"])
        XCTAssertEqual(zoomWindow.accesses, 0, "a pinned recording never looks at another app's window")
    }

    func testPinned_onlyThePinnedAppsWindowsAreRead() {
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        let chromeGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let chromeWindows = [Telemost.window([Telemost.meetingArea(grid: chromeGrid)])]
        let safariGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let safariWindow = CountingNode(Telemost.window([Telemost.meetingArea(grid: safariGrid)]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": chromeWindows, "com.apple.Safari": [safariWindow]],
            holders: ["com.google.Chrome.helper", "com.apple.WebKit.GPU"], pin: pin, limits: limits()
        )

        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.people, ["Гость Один"])
        XCTAssertEqual(safariWindow.accesses, 0)
    }

    func testHolderMapping_helpersToTheirBrowsers() {
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "company.thebrowser.browser.helper"), "company.thebrowser.Browser")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "company.thebrowser.Browser.helper"), "company.thebrowser.Browser")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.edgemac.helper"), "com.microsoft.edgemac")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.brave.Browser.helper"), "com.brave.Browser")
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "ru.yandex.desktop.yandex-browser.helper"),
            "ru.yandex.desktop.yandex-browser"
        )
        // WebKit's own capture processes are shared by every app that embeds
        // `WKWebView`, not just Safari (4): no longer folded into it, so
        // such a holder is returned unchanged, same as any unmapped one.
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.apple.WebKit.GPU"), "com.apple.WebKit.GPU")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.apple.WebKit.WebContent"), "com.apple.WebKit.WebContent")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "us.zoom.xos"), "us.zoom.xos")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.google.Chrome.helperX"), "com.google.Chrome.helperX")

        for app in MeetingPageReader.browserHelpers.values {
            XCTAssertTrue(MeetingPageReader.browserBundleIDs.contains(app), "\(app) must be one of browserBundleIDs")
        }
    }

    /// A `com.apple.WebKit.*` holder is shared by every app that embeds
    /// `WKWebView`, not Safari alone (4): it is no longer folded into
    /// Safari, so a Telemost tab actually open in Safari is not read any
    /// more — the price of this fix, until a way to tell the two apart is
    /// found.
    func testWebKitHolder_safariTelemostTab_notFound() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let windows = [Telemost.window([Telemost.meetingArea(grid: grid)])]

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.apple.Safari": windows], holders: ["com.apple.WebKit.GPU"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    /// A browser installed as a PWA (Google Meet's own "install as app"
    /// button) runs the call in a process of its own
    /// (`com.google.Chrome.app.<id>`, etc.), not mapped back to its browser:
    /// the owner has not yet confirmed what process Core Audio reports for
    /// it on a live call, so for now such a holder is simply not one of the
    /// programs any row runs in.
    func testHolderMapping_pwaAppProcessIsNotMappedToABrowser() {
        let holder = "com.google.Chrome.app.abcdefghij"
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: holder), holder)

        let area = Meet.meetingArea(tiles: [Meet.tile(name: "Анна Тестова")])
        let windows = [Meet.window([area])]
        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: [holder], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    func testHolderBundleIDs_sameFilterAsTheWatchdog() {
        let ownPID: pid_t = 1
        let snapshot: [MeetingWatchdog.ProcessSnapshot] = [
            MeetingWatchdog.ProcessSnapshot(pid: ownPID, bundleID: "com.google.Chrome.helper", isRunningInput: true),
            MeetingWatchdog.ProcessSnapshot(pid: 2, bundleID: Bundle.main.bundleIdentifier, isRunningInput: true),
            MeetingWatchdog.ProcessSnapshot(pid: 3, bundleID: "com.apple.systempreferences", isRunningInput: true),
            MeetingWatchdog.ProcessSnapshot(pid: 4, bundleID: "com.google.Chrome.helper", isRunningInput: false),
            MeetingWatchdog.ProcessSnapshot(pid: 5, bundleID: nil, isRunningInput: true),
            MeetingWatchdog.ProcessSnapshot(pid: 6, bundleID: "com.google.Chrome.helper", isRunningInput: true),
        ]

        let holders = MeetingWatchdog.holderBundleIDs(in: snapshot, ownPID: ownPID)

        XCTAssertEqual(holders, ["com.google.Chrome.helper"])
    }

    func testAppRow_readsOnlyItsOwnAppsWindow() {
        let zoomGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let zoomWindow = FakeNode(
            role: "AXWindow", children: [zoomGrid], identifier: "test-call-window", axElement: NSObject()
        )
        let chromeGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let chromeWindow = CountingNode(Telemost.window([Telemost.meetingArea(grid: chromeGrid)]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["us.zoom.xos": [zoomWindow], "com.google.Chrome": [chromeWindow]],
            holders: ["us.zoom.xos"], pin: nil, limits: limits(), services: [MeetingPageReader.services[0], zoomLikeService()]
        )

        XCTAssertEqual(snapshot.service, "zoom-test")
        XCTAssertEqual(snapshot.app, "us.zoom.xos")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(chromeWindow.accesses, 0)
    }

    /// Two held programs, both with a Telemost tab: not "nobody" — the first
    /// A `com.apple.WebKit.GPU` holder is no longer folded into Safari (4):
    /// it is simply its own, unmapped holder, with no window of its own in
    /// this fixture, so the only confirmed area left is Chrome's own tab —
    /// read every time, deterministically, whatever Safari's own window
    /// would otherwise have shown.
    func testWebKitHolderBesideChrome_onlyTheChromeTabIsRead() {
        let chromeGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let chromeWindows = [Telemost.window([Telemost.meetingArea(grid: chromeGrid)])]
        let safariGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let safariWindows = [Telemost.window([Telemost.meetingArea(grid: safariGrid)])]
        let windows = ["com.google.Chrome": chromeWindows, "com.apple.Safari": safariWindows]
        let holders: Set<String> = ["com.google.Chrome.helper", "com.apple.WebKit.GPU"]

        let first = MeetingPageReader.snapshot(windows: windows, holders: holders, pin: nil, limits: limits())
        let second = MeetingPageReader.snapshot(windows: windows, holders: holders, pin: nil, limits: limits())

        XCTAssertEqual(first.app, "com.google.Chrome")
        XCTAssertEqual(first.people, ["Гость Один"])
        XCTAssertEqual(second.app, first.app)
        XCTAssertEqual(second.people, first.people)
    }

    // MARK: - Reading by caption (a native app's own window, no page classes)

    /// Every caption-service test's own program is the holder: the row's
    /// bundle ID itself (`ZoomShape.service`'s `.app` place, not a Chromium
    /// helper), so holder selection picks exactly this one row and program,
    /// same as before this card's `snapshot` grew `holders`/`pin`.
    private func readZoom(
        _ windows: [AccessibilityPageNode], limits: MeetingPageReader.Limits,
        service: MeetingPageReader.Service = ZoomShape.service(), pin: MeetingPageReader.Pin? = nil
    ) -> MeetingPageSnapshot {
        MeetingPageReader.snapshot(
            windows: windows.isEmpty ? [:] : ["us.zoom.xos.test": windows],
            holders: ["us.zoom.xos.test"], pin: pin, limits: limits, services: [service]
        )
    }

    func testCaptionService_threeParticipants_oneWithSpeakingMarker() {
        let window = ZoomShape.window(children: [
            ZoomShape.tile(name: "Анна Тестова"),
            ZoomShape.tile(name: "Борис Пример", speaking: true),
            ZoomShape.tile(name: "Вера Образцова"),
        ])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "zoom-test")
        XCTAssertEqual(Set(snapshot.people), ["Анна Тестова", "Борис Пример", "Вера Образцова"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    func testCaptionService_speakingMarkerInRussian() {
        let tile = FakeNode(
            role: "AXTabGroup",
            description: "Анна Тестова, Computer audio unmuted, Video off, Активный докладчик"
        )
        let window = ZoomShape.window(children: [tile])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.people, ["Анна Тестова"])
        XCTAssertEqual(snapshot.speaking, ["Анна Тестова"])
    }

    /// A comma inside the name itself must survive: parsing from the end
    /// strips exactly the two known statuses, nothing more.
    func testCaptionService_commaInsideNameIsPreserved() {
        let window = ZoomShape.window(children: [ZoomShape.tile(name: "Иванов, Иван")])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.people, ["Иванов, Иван"])
    }

    /// Two participants, neither with a speaking marker and no "(me)" row
    /// anywhere: nobody is self, both are strangers in `people`.
    func testCaptionService_twoParticipantsNoMarker_bothAreStrangers() {
        let window = ZoomShape.window(children: [
            ZoomShape.tile(name: "Анна Тестова"),
            ZoomShape.tile(name: "Борис Пример"),
        ])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertEqual(Set(snapshot.people), ["Анна Тестова", "Борис Пример"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// The local user's own name comes from the participants list's "(me)"
    /// row, matched by equality against a tile's own parsed name.
    func testCaptionService_selfNameReadFromParticipantsListMeRow() {
        let selfRow = FakeNode(role: "AXStaticText", description: "Анна Тестова (me)")
        let list = FakeNode(role: "AXOutline", children: [selfRow])
        let window = ZoomShape.window(children: [
            ZoomShape.tile(name: "Анна Тестова"),
            ZoomShape.tile(name: "Борис Пример"),
            list,
        ])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
    }

    /// The self row's name may live in `value` alone, with no `description`
    /// at all — the same way `AXStaticText` often answers.
    func testCaptionService_selfNameFromValueInsideParticipantsList() {
        let selfRow = FakeNode(role: "AXStaticText", value: "Anna Example (me)")
        let list = FakeNode(role: "AXOutline", children: [selfRow])
        let window = ZoomShape.window(children: [
            ZoomShape.tile(name: "Anna Example"),
            ZoomShape.tile(name: "Boris Example"),
            list,
        ])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.selfName, "Anna Example")
        XCTAssertEqual(snapshot.people, ["Boris Example"])
    }

    /// A node outside the participants list — a button, say — must never
    /// supply the self name, even with the very same "(me)" suffix: only a
    /// node inside the list (`AXOutline`) counts. Without that restriction
    /// the button, visited first, would wrongly name Boris as the local
    /// user and lose him from `people`.
    func testCaptionService_selfNameOnlyFromInsideTheParticipantsList() {
        let outsideButton = FakeNode(role: "AXButton", description: "Boris Example (me)")
        let selfRow = FakeNode(role: "AXStaticText", description: "Anna Example (me)")
        let list = FakeNode(role: "AXOutline", children: [selfRow])
        let window = ZoomShape.window(children: [
            outsideButton,
            ZoomShape.tile(name: "Anna Example"),
            ZoomShape.tile(name: "Boris Example"),
            list,
        ])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.selfName, "Anna Example")
        XCTAssertEqual(snapshot.people, ["Boris Example"])
    }

    /// "(me)" on a tile's own description is never read as the self marker
    /// — only a separate participants-list row counts. The literal text
    /// stays part of the (stranger's) name.
    func testCaptionService_meSuffixOnATileItselfIsNotUsedForSelfDetection() {
        let window = ZoomShape.window(children: [ZoomShape.tile(name: "Анна Тестова (me)")])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertEqual(snapshot.people, ["Анна Тестова (me)"])
    }

    func testCaptionService_wrongWindowIdentifier_notFound() {
        let window = ZoomShape.window(identifier: "something.else", children: [ZoomShape.tile(name: "Анна Тестова")])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Only a top-level window is ever accepted by its own `AXIdentifier`:
    /// an element nested inside a window that doesn't match, even one that
    /// happens to carry the exact identifier the row looks for, must not be
    /// mistaken for the call's own window.
    func testAppPlace_nestedIdentifierInsideNonMatchingWindow_notFound() {
        let impostor = FakeNode(role: "AXGroup", identifier: ZoomShape.windowIdentifier)
        let window = FakeNode(role: "AXWindow", children: [impostor], identifier: "something.else")

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// No window of the row's own bundle ID at all — the honest equivalent,
    /// at this pure-function level, of "the program isn't running": the
    /// live collection of a native app's windows cannot itself be driven in
    /// a test process (`readLive` always answers `.notFound` there).
    func testCaptionService_noWindowsAtAll_notFound() {
        let snapshot = readZoom([], limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Pinned (2): without a pin, a window the budget cut short while
    /// reading its tiles can never be confirmed, so `.notFound` instead (the
    /// test right below). With a pin, the old invariant still holds.
    func testCaptionService_nodeLimitExceededAfterAreaFound_resetsEverythingButFound() {
        let manyTiles = (0..<50).map { ZoomShape.tile(name: "Гость \($0)") }
        let window = ZoomShape.window(children: manyTiles)
        let element = MeetingPageReader.WindowElement(address: window.axElementAddress)!
        let pin = MeetingPageReader.Pin(
            service: "zoom-test", app: "us.zoom.xos.test",
            meeting: .window(identifier: ZoomShape.windowIdentifier, title: "", element: element)
        )

        let snapshot = readZoom([window], limits: limits(maxNodes: 3), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    /// The same budget, without a pin: a window the budget cut short while
    /// reading its tiles can never be confirmed, so nothing is read.
    func testCaptionService_prePin_budgetCutShort_notFound() {
        let manyTiles = (0..<50).map { ZoomShape.tile(name: "Гость \($0)") }
        let window = ZoomShape.window(children: manyTiles)

        let snapshot = readZoom([window], limits: limits(maxNodes: 3))

        XCTAssertEqual(snapshot, .notFound)
    }

    /// A tile found once must never be descended into: its own child, even
    /// one that is itself a fully valid caption for another person, must
    /// not surface as a participant.
    func testCaptionService_neverDescendsIntoATilesChildren() {
        let nested = ZoomShape.tile(name: "Скрытый Человек")
        let outer = ZoomShape.tile(name: "Видимый Человек", children: [nested])
        let window = ZoomShape.window(children: [outer])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.people, ["Видимый Человек"])
        XCTAssertFalse(snapshot.people.contains("Скрытый Человек"))
    }

    /// Only two of the two expected statuses are known: the middle one is
    /// an unrecognized phrase. The whole description is an unknown shape,
    /// so the tile is skipped rather than guessed at.
    func testCaptionService_unknownStatusTail_tileSkipped() {
        let tile = FakeNode(role: "AXTabGroup", description: "Анна Тестова, Some unknown status, Video off")
        let window = ZoomShape.window(children: [tile])

        let snapshot = readZoom([window], limits: limits())

        XCTAssertEqual(snapshot.people, [])
        XCTAssertFalse(snapshot.visible)
    }

    // MARK: - Jitsi Meet (tab in a browser, found by DOM class and id)

    /// Three tiles: the own one found only by `localVideoContainer`
    /// (no class of its own), a stranger carrying `dominant-speaker`, and a
    /// third plain stranger.
    func testJitsi_threeTiles_selfByID_dominantSpeakerOnAStranger() {
        let area = Jitsi.meetingArea(tiles: [
            Jitsi.tile(name: "Анна Тестова", isSelf: true),
            Jitsi.tile(name: "Борис Пример", speaking: true),
            Jitsi.tile(name: "Гость Три"),
        ])
        let windows = [Jitsi.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "jitsi")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// `dominant-speaker` on the own tile itself (found by id) sets
    /// `selfSpeaking`, same as a stranger's tile sets `speaking`.
    func testJitsi_ownTileDominantSpeaker_setsSelfSpeaking() {
        let area = Jitsi.meetingArea(tiles: [
            Jitsi.tile(name: "Анна Тестова", isSelf: true, speaking: true),
            Jitsi.tile(name: "Борис Пример"),
        ])
        let windows = [Jitsi.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertTrue(snapshot.selfSpeaking)
    }

    /// The per-session hash class (`css-…-activeSpeaker`) alone, without
    /// `dominant-speaker` itself, must never read as speaking — the card's
    /// own measurement says the two are not interchangeable.
    func testJitsi_hashedActiveSpeakerClassAlone_doesNotCountAsSpeaking() {
        let area = Jitsi.meetingArea(tiles: [Jitsi.tileWithHashedSpeakerClassOnly(name: "Гость Три")])
        let windows = [Jitsi.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// A page at another address entirely (not one of Jitsi's three public
    /// servers) must never be mistaken for a Jitsi meeting area.
    func testJitsi_wrongAddress_notFound() {
        let area = Jitsi.meetingArea(tiles: [Jitsi.tile(name: "Гость Три")], server: "example.com")
        let windows = [Jitsi.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Telemost and Jitsi areas in the very same window, the same program
    /// holding the microphone, each with a tile of its own: two confirmed
    /// areas with different meeting identities (2) — table order no longer
    /// decides between two calls that are both actually on screen, so
    /// nothing is read, rather than guessing which of the two is real.
    func testJitsi_besideTelemostInTheSameWindow_twoCallsWithTilesNothingRead() {
        let telemostGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let telemostArea = Telemost.meetingArea(grid: telemostGrid)
        let jitsiArea = Jitsi.meetingArea(tiles: [Jitsi.tile(name: "Гость Три", isSelf: true)])
        let window = FakeNode(role: "AXWindow", children: [telemostArea, jitsiArea])

        let snapshot = readInChrome([window], limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Telemost's row sets no `selfTileIdentifier`, so `searchTileDetails`'s
    /// `if let` never reaches `domIdentifier` at all for it: proven by a
    /// counter on every node of a Telemost-only tree, read through the full
    /// (Telemost + Jitsi) services table exactly as `readLive` would use it.
    func testJitsi_domIdentifierNeverAskedWhileReadingTelemost() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Я Сам", isSelf: true),
            Telemost.tile(name: "Участник Первый"),
        ])
        let countingWindow = DOMIdentifierCountingNode(Telemost.window([Telemost.meetingArea(grid: grid)]))

        let snapshot = readInChrome([countingWindow], limits: limits())

        XCTAssertEqual(snapshot.service, "telemost")
        XCTAssertEqual(snapshot.people, ["Участник Первый"])
        XCTAssertEqual(countingWindow.accesses, 0, "Telemost's row has no selfTileIdentifier: domIdentifier must never be read")
    }

    /// `.exact` class matching for Jitsi's tile class: a near-miss class
    /// (`videocontainer-extra`) that a prefix match would wrongly accept
    /// must not be treated as a tile at all.
    func testJitsi_exactClassMode_nearMissTileClassIsNotATile() {
        let nameNode = DOMIdentifiedNode(classes: ["displayname"], title: "Гость Три")
        let impostorTile = DOMIdentifiedNode(classes: ["videocontainer-extra"], children: [nameNode])
        let area = Jitsi.meetingArea(tiles: [impostorTile])
        let windows = [Jitsi.window([area])]

        // An area with no real tile is never confirmed on its own (2); read
        // with a pin on this very address, so this test still proves the
        // near-miss class itself is not a tile, not that an address alone
        // is ambiguous.
        let pin = MeetingPageReader.Pin(
            service: "jitsi", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://meet.ffmuc.net/TestRoomAlpha")!)
        )
        let snapshot = readInChrome(windows, limits: limits(), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    // MARK: - Bitrix24 (a browser tab, and the macOS program's own window)

    /// Three tiles on a cloud portal's `/video/` page: the own tile by its
    /// `-self` class, a stranger carrying `-talking`, and a third plain
    /// stranger — all through the default table's real `bitrix24` row.
    func testBitrix24_browserTab_threeTiles_selfSpeakingAndPlain() {
        let area = Bitrix24.meetingArea(children: [
            Bitrix24.tile(name: "Анна Тестова", isSelf: true),
            Bitrix24.tile(name: "Борис Пример", speaking: true),
            Bitrix24.tile(name: "Гость Три"),
        ])
        let windows = [Bitrix24.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "bitrix24")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// Classes that merely start with the real ones must never match under
    /// `.exact`, the production row's own match mode: a list wrapper
    /// (`bx-messenger-videocall-user-list`, a prefix of the tile class
    /// itself) around the real tiles, and `-talking-hint`/`-self-preview`
    /// modifiers nested inside them. The wrapper carries a name of its own,
    /// made up and distinct from the real tiles' names — a false match would
    /// then show up as an extra person rather than silently dedupe into a
    /// real one.
    func testBitrix24_exactMatch_listWrapperAndNearMissModifiersAreNeverTiles() {
        let talkingHint = FakeNode(classes: ["bx-messenger-videocall-user-talking-hint"])
        let selfTile = FakeNode(
            classes: ["bx-messenger-videocall-user", "bx-messenger-videocall-user-self"],
            children: [FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Анна Тестова"), talkingHint]
        )
        let selfPreview = FakeNode(classes: ["bx-messenger-videocall-user-self-preview"])
        let otherTile = FakeNode(
            classes: ["bx-messenger-videocall-user"],
            children: [FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Борис Пример"), selfPreview]
        )
        let wrapperName = FakeNode(classes: ["bx-messenger-videocall-user-name"], title: "Виктор Декоев")
        let listWrapper = FakeNode(
            classes: ["bx-messenger-videocall-user-list"], children: [wrapperName, selfTile, otherTile]
        )
        let area = Bitrix24.meetingArea(children: [listWrapper])
        let windows = [Bitrix24.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking, "the near-miss -talking-hint class inside the self tile must not count")
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// The macOS program's own window, with its embedded page nested a level
    /// deeper than the window itself (a real Chromium embed is not the
    /// window's direct child): the same classes, the same snapshot as the
    /// browser tab above, found through `.appWeb` instead of `.browser`.
    func testBitrix24App_windowWithEmbeddedWebArea_sameSnapshotAsBrowserTab() {
        let area = Bitrix24.meetingArea(children: [
            Bitrix24.tile(name: "Анна Тестова", isSelf: true),
            Bitrix24.tile(name: "Борис Пример", speaking: true),
            Bitrix24.tile(name: "Гость Три"),
        ])
        let outer = FakeNode(role: "AXGroup", children: [area])
        let window = FakeNode(role: "AXWindow", children: [outer])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.bitrixsoft.bitrix24desktop": [window]],
            holders: ["com.bitrixsoft.bitrix24desktop.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "bitrix24")
        XCTAssertEqual(snapshot.app, "com.bitrixsoft.bitrix24desktop")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// Held by Chrome: only the browser row is tried, in the fixed table
    /// order (browser row before the program row); the program's own window
    /// must never even be opened.
    func testBitrix24_chromeHolder_readsBrowserRow_programWindowNeverOpened() {
        let chromeArea = Bitrix24.meetingArea(children: [Bitrix24.tile(name: "Гость Три")])
        let chromeWindows = [Bitrix24.window([chromeArea])]
        let programArea = Bitrix24.meetingArea(children: [Bitrix24.tile(name: "НеДолженНайтись")])
        let programWindow = CountingNode(FakeNode(role: "AXWindow", children: [programArea]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": chromeWindows, "com.bitrixsoft.bitrix24desktop": [programWindow]],
            holders: ["com.google.Chrome.helper"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.service, "bitrix24")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(programWindow.accesses, 0, "only the browser row is tried: the program's window must never be opened")
    }

    /// Pinned to the program: the lookup must match the pin's `service` id
    /// *and* its `app`, not just the id — `bitrix24` names two rows (the
    /// browser tab and the program), and the browser row comes first in the
    /// table. Without matching on `app` too, this pin would resolve to the
    /// browser row, find it doesn't run in the program's bundle ID, and
    /// answer `.notFound` instead of reading the program's own window.
    func testBitrix24App_pinned_readsTheProgramsWindow() {
        let pin = MeetingPageReader.Pin(
            service: "bitrix24", app: "com.bitrixsoft.bitrix24desktop",
            meeting: .page(address: "https://testportal.bitrix24.ru/video/AbC123xyz")
        )
        let area = Bitrix24.meetingArea(children: [Bitrix24.tile(name: "Гость Три", isSelf: true)])
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.bitrixsoft.bitrix24desktop": [window]], holders: [], pin: pin, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "bitrix24")
        XCTAssertEqual(snapshot.app, "com.bitrixsoft.bitrix24desktop")
        XCTAssertEqual(snapshot.selfName, "Гость Три")
    }

    /// Two different chats in the same tab, one after another: the query
    /// parameter `IM_DIALOG` is part of the meeting's own identity (1a), so
    /// the second chat is a different meeting entirely and the pin from the
    /// first must not match it.
    func testBitrix24_twoDialogsInOneTab_secondDialogIsAnotherMeeting() {
        let chat11Area = FakeNode(
            role: "AXWebArea", axURL: "https://testportal.bitrix24.ru/online/?IM_DIALOG=chat11",
            children: [Bitrix24.tile(name: "Гость Один")]
        )
        let first = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [Bitrix24.window([chat11Area])]],
            holders: ["com.google.Chrome.helper"], pin: nil, limits: limits()
        )
        XCTAssertTrue(first.found)
        XCTAssertEqual(first.people, ["Гость Один"])
        let pin = MeetingPageReader.Pin(service: first.service, app: first.app, meeting: first.meeting)

        let chat22Area = FakeNode(
            role: "AXWebArea", axURL: "https://testportal.bitrix24.ru/online/?IM_DIALOG=chat22",
            children: [Bitrix24.tile(name: "Гость Два")]
        )
        let second = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [Bitrix24.window([chat22Area])]],
            holders: ["com.google.Chrome.helper"], pin: pin, limits: limits()
        )
        XCTAssertEqual(second, .notFound, "the chat changed underneath the pin, so the page is simply not there any more")
    }

    /// An embedded page with no address at all (`AXURL` absent): its
    /// identity cannot be told apart from any other such page, so it must
    /// never be pinned — even though the row's own `meetingAreas` is empty
    /// and would otherwise accept it as a call.
    func testAppWeb_areaWithoutAddress_neverPinned() {
        let area = FakeNode(role: "AXWebArea", axURL: nil, children: [Bitrix24.tile(name: "Гость Один")])
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.bitrixsoft.bitrix24desktop": [window]],
            holders: ["com.bitrixsoft.bitrix24desktop"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    /// The messenger's own chat screen (no tiles at all) beside the actual
    /// call (with one): only the call is confirmed, so it is the one chosen
    /// — the messenger intercepting the choice before any tiles are even
    /// read was exactly this card's defect (2).
    func testBitrix24App_messengerWithoutTilesAndCall_callChosen() {
        let messengerArea = FakeNode(
            role: "AXWebArea", axURL: "https://testportal.bitrix24.ru/online/?IM_DIALOG=chat11", children: []
        )
        let callArea = Bitrix24.meetingArea(children: [Bitrix24.tile(name: "Гость Один")])
        let window = FakeNode(role: "AXWindow", children: [messengerArea, callArea])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.bitrixsoft.bitrix24desktop": [window]],
            holders: ["com.bitrixsoft.bitrix24desktop"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.people, ["Гость Один"])
    }

    /// The program's helper processes (`<bundleID>.helper…`) map to the
    /// program itself, the same rule `browserHelpers` applies to a Chromium
    /// browser's own helper; a near-miss without the separating dot, and the
    /// program itself, are unaffected.
    func testHolderMapping_programHelpersToTheirProgram() {
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "com.bitrixsoft.bitrix24desktop.helper"),
            "com.bitrixsoft.bitrix24desktop"
        )
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "com.bitrixsoft.bitrix24desktop.helper.renderer"),
            "com.bitrixsoft.bitrix24desktop"
        )
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "com.bitrixsoft.bitrix24desktop"),
            "com.bitrixsoft.bitrix24desktop"
        )
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "com.bitrixsoft.bitrix24desktopX"),
            "com.bitrixsoft.bitrix24desktopX"
        )
    }

    // MARK: - Telemost's own macOS app (`ru.yandex.desktop.telemost`), an
    // `.appWeb` row with its own id `telemost-app`, same classes as the
    // browser tab's `telemost` row above.

    /// The program's own window, with an embedded call page nested a level
    /// deeper than the window itself, at the tab row's own `/private-join/`
    /// path: the same classes, a snapshot under the program's own id and
    /// app, never `telemost` and never the browser's bundle ID.
    func testTelemostApp_windowWithEmbeddedCallPage_readsTwoGuestsAndSelf() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(name: "Анна Тестова", isSelf: true),
            Telemost.tile(name: "Борис Пример", speaking: true),
            Telemost.tile(name: "Гость Три"),
        ])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/abc123", children: [grid])
        let outer = FakeNode(role: "AXGroup", children: [area])
        let window = FakeNode(role: "AXWindow", children: [outer])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost-app")
        XCTAssertEqual(snapshot.app, "ru.yandex.desktop.telemost")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// The program's own embedded page has the same real Chrome shape as the
    /// browser tab: `TextName_…` carries no text of its own, and the name
    /// lives in its first `AXStaticText` child.
    func testTelemostApp_nameInStaticTextChildOfTextName_readsSelfGuestsAndSpeaker() {
        let grid = Telemost.grid(tiles: [
            Telemost.tile(nameNode: telemostNameInStaticText("Анна Тестова"), isSelf: true),
            Telemost.tile(nameNode: telemostNameInStaticText("Борис Пример"), speaking: true),
            Telemost.tile(nameNode: telemostNameInStaticText("Гость Три")),
        ])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/abc123", children: [grid])
        let outer = FakeNode(role: "AXGroup", children: [area])
        let window = FakeNode(role: "AXWindow", children: [outer])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost-app")
        XCTAssertEqual(snapshot.app, "ru.yandex.desktop.telemost")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// `.appWeb` has no shell-descent of its own (unlike the browser row's
    /// `shells`): the outer `/j/` path must match directly, as one of
    /// `telemost-app`'s own `meetingAreas`, not only the nested
    /// `/private-join/` path.
    func testTelemostApp_embeddedCallPageAtOuterJoinPath_alsoFound() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/j/xyz789", children: [grid])
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost-app")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
    }

    /// A web area outside both of the tab's own meeting-area paths (the
    /// program's chats/contacts screen, say) must never be read as a call:
    /// `telemost-app`'s `meetingAreas` is deliberately not empty, unlike
    /// Bitrix24's `.appWeb` row, exactly to keep this case from matching. A
    /// sibling node with an `app://` address (a native, non-web screen of
    /// the same program) sits right beside it: an unmatched web area is
    /// never descended into looking for something else to match, so this
    /// neighbor changes nothing either.
    func testTelemostApp_nonCallWebArea_notFound() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "НеДолженНайтись")])
        let chatsArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/chats", children: [grid])
        let nativeScreen = FakeNode(role: "AXWebArea", axURL: "app://telemost/index.html", children: [])
        let window = FakeNode(role: "AXWindow", children: [chatsArea, nativeScreen])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertFalse(snapshot.found)
    }

    /// An empty `/j/` area beside a `/private-join/` area that actually has
    /// a tile, in the same window: only the one with a tile is confirmed
    /// (2), so it is the one chosen — an empty area intercepting the choice
    /// before any tiles are read was exactly this card's defect.
    func testTelemostApp_emptyJoinBesidePrivateJoinWithTiles_privateJoinChosen() {
        let emptyJoinArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/j/aaa111", children: [])
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let privateJoinArea = FakeNode(
            role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/bbb222", children: [grid]
        )
        let window = FakeNode(role: "AXWindow", children: [emptyJoinArea, privateJoinArea])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.meeting, .page(address: "https://telemost.yandex.ru/private-join/bbb222"))
        XCTAssertEqual(snapshot.people, ["Гость Один"])
    }

    /// Two rooms, each with a real tile: both confirmed, with different
    /// meeting identities — ambiguous, so nothing is read (2).
    func testTwoRoomsWithTiles_nothingChosen() {
        let gridA = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let areaA = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/room-a", children: [gridA])
        let gridB = Telemost.grid(tiles: [Telemost.tile(name: "Гость Два")])
        let areaB = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/room-b", children: [gridB])
        let window = FakeNode(role: "AXWindow", children: [areaA, areaB])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    /// The outer web area is the tab row's own shell path (`/j/`), with the
    /// real meeting area — and its grid — nested a level inside it, at
    /// `/private-join/`: `findGrid` descends every child regardless of role,
    /// so the nested grid is found through the outer, matched area, and the
    /// meeting's address is the outer page's own (`.appWeb` never descends
    /// past an area that already matched, so the inner page is never treated
    /// as a second, competing meeting area).
    func testTelemostApp_outerJoinPageWithNestedPrivateJoinGrid_readsTheNestedGuest() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let nestedArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/xyz", children: [grid])
        let outerArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/j/abc123", children: [nestedArea])
        let window = FakeNode(role: "AXWindow", children: [outerArea])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost-app")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(snapshot.meeting, .page(address: "https://telemost.yandex.ru/j/abc123"))
    }

    /// `telemost.yandex.com` is one of this row's own `meetingAreas` hosts
    /// (added for K2, alongside `.ru`): a `/private-join/` page straight on
    /// the `.com` host is found, through the default table — the row is
    /// already in `services`, not a row added only for the test.
    func testTelemostApp_readyRow_comHost_privateJoinDirectly() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.com/private-join/abc123", children: [grid])
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]],
            holders: ["ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost-app")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
    }

    /// A pin fixed to the tab's own id (`telemost`), not the program's
    /// (`telemost-app`), must never read the program's window: the two ids
    /// are deliberately kept separate, so a pin naming one is never
    /// satisfied by the other, even against the very same program and
    /// address the real `telemost-app` pin would match.
    func testTelemostApp_pinWithTheTabsID_doesNotReadTheProgram() {
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "ru.yandex.desktop.telemost",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/abc123", children: [grid])
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]], holders: [], pin: pin, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Held by Chrome: only the browser's `telemost` row is tried, in the
    /// fixed table order (it comes before `telemost-app`); the program's own
    /// window must never even be opened, and the snapshot keeps the tab's
    /// own id, not the program's.
    func testTelemostApp_chromeHolder_readsBrowserRow_programWindowNeverOpened() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let chromeWindows = [Telemost.window([Telemost.meetingArea(grid: grid)])]
        let programGrid = Telemost.grid(tiles: [Telemost.tile(name: "НеДолженНайтись")])
        let programArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/zzz", children: [programGrid])
        let programWindow = CountingNode(FakeNode(role: "AXWindow", children: [programArea]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": chromeWindows, "ru.yandex.desktop.telemost": [programWindow]],
            holders: ["com.google.Chrome.helper"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.service, "telemost")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(programWindow.accesses, 0, "only the browser row is tried: the program's window must never be opened")
    }

    /// Pinned to the program: the lookup must match the pin's `service` id
    /// *and* its `app`, the same rule Bitrix24's two rows need, since
    /// `telemost-app` could otherwise be confused with the tab's `telemost`
    /// if only the id were checked.
    func testTelemostApp_pinned_readsTheProgramsWindow() {
        let pin = MeetingPageReader.Pin(
            service: "telemost-app", app: "ru.yandex.desktop.telemost",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три", isSelf: true)])
        let area = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/abc123", children: [grid])
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["ru.yandex.desktop.telemost": [window]], holders: [], pin: pin, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "telemost-app")
        XCTAssertEqual(snapshot.app, "ru.yandex.desktop.telemost")
        XCTAssertEqual(snapshot.selfName, "Гость Три")
    }

    /// The program's helper processes (`<bundleID>.helper…`) map to the
    /// program itself, the same rule `browserHelpers` applies to a Chromium
    /// browser's own helper — automatic once `telemost-app`'s own bundle ID
    /// is in the table, no code change of its own needed.
    func testHolderMapping_telemostAppHelpersMapToTheProgram() {
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "ru.yandex.desktop.telemost.helper"),
            "ru.yandex.desktop.telemost"
        )
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "ru.yandex.desktop.telemost.helper.renderer"),
            "ru.yandex.desktop.telemost"
        )
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "ru.yandex.desktop.telemost"),
            "ru.yandex.desktop.telemost"
        )
    }

    /// Both the browser tab and the program hold the microphone at once (two
    /// held apps), each with a tile of its own, in two different rooms: two
    /// confirmed areas with different meeting identities (2) — nothing is
    /// read, rather than the table's own order silently picking one call
    /// over the other that is just as real.
    func testTelemostApp_tabAndAppBothWithTilesInDifferentRooms_nothingRead() {
        let tabGrid = Telemost.grid(tiles: [Telemost.tile(name: "Участник Первый")])
        let chromeWindows = [Telemost.window([Telemost.meetingArea(grid: tabGrid)])]
        let appGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Три")])
        let appArea = FakeNode(role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/zzz", children: [appGrid])
        let appWindow = FakeNode(role: "AXWindow", children: [appArea])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": chromeWindows, "ru.yandex.desktop.telemost": [appWindow]],
            holders: ["com.google.Chrome.helper", "ru.yandex.desktop.telemost.helper"], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - Zoom, the program (`us.zoom.xos`, read by caption; the real
    // "zoom" row of `MeetingPageReader.services`, not the generic
    // `ZoomShape` fixture above)

    /// Three tiles, two carrying the English "active speaker" marker in the
    /// very same snapshot (the feed's own data shape, not a claim that real
    /// Zoom lights up two tiles at once): Boris lands in `people` only,
    /// Guest and Anna in both `people` and `speaking`, and — no
    /// participants list open at all — nobody is the local user.
    func testZoomNative_threeParticipants_twoWithSpeakingMarker_englishCaptions() {
        let window = ZoomNative.window(children: [
            ZoomNative.tile(name: "Борис Пример"),
            ZoomNative.tile(name: "Гость Три", speaking: true),
            ZoomNative.tile(name: "Анна Тестова", speaking: true),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "zoom")
        XCTAssertEqual(snapshot.app, "us.zoom.xos")
        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три", "Анна Тестова"])
        XCTAssertEqual(snapshot.speaking, ["Гость Три", "Анна Тестова"])
    }

    // MARK: - A window's own AX object is its identity, not just its title (1c)

    /// Pinned to a Zoom call window; the window is then recreated (a new
    /// `AXUIElement`, a different object) with the very same `AXIdentifier`
    /// and the very same title — a second call started after the first
    /// ended, not the same window kept open. The pin must not follow it.
    func testZoomApp_newWindowWithTheSameTitle_isAnotherMeeting() {
        let firstElement = NSObject()
        let firstWindow = ZoomNative.window(
            children: [ZoomNative.tile(name: "Гость Один")], element: firstElement
        )
        firstWindow.title = "Zoom Meeting"
        let first = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [firstWindow]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )
        XCTAssertTrue(first.found)
        XCTAssertEqual(first.people, ["Гость Один"])
        let pin = MeetingPageReader.Pin(service: first.service, app: first.app, meeting: first.meeting)

        let secondElement = NSObject()
        let secondWindow = ZoomNative.window(
            children: [ZoomNative.tile(name: "Гость Два")], element: secondElement
        )
        secondWindow.title = "Zoom Meeting"
        let second = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [secondWindow]], holders: [ZoomNative.bundleID], pin: pin, limits: limits()
        )
        XCTAssertEqual(second, .notFound, "a new window, even with the same identifier and title, is a different meeting")

        // The very same window, read again (a fresh node, the same object):
        // still recognized as the pinned one.
        let firstAgain = ZoomNative.window(children: [ZoomNative.tile(name: "Гость Один")], element: firstElement)
        firstAgain.title = "Zoom Meeting"
        let third = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [firstAgain]], holders: [ZoomNative.bundleID], pin: pin, limits: limits()
        )
        XCTAssertTrue(third.found)
        XCTAssertEqual(third.people, ["Гость Один"])
    }

    /// A window with no AX object at all (an address of 0, the protocol's
    /// own default): it can never be pinned, since nothing distinguishes it
    /// from any other such window.
    func testZoomApp_windowWithoutElement_notPinned() {
        let window = ZoomNative.window(children: [ZoomNative.tile(name: "Гость Один")], element: nil)

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    // Zoom's own Russian captions are not literals in the "zoom" row at all
    // (a Cyrillic literal in `Sources/` is refused outright): they are read
    // at runtime from the installed program's own bundle by
    // `addingInstalledZoomCaptions`, exercised below under "Zoom captions
    // read from Zoom's own bundle".

    /// "Hand raised" as a third, optional status before the two mandatory
    /// ones (audio, video), with a speaking marker on top of it: the own
    /// tile must still parse to a name, not be skipped as an unknown shape.
    /// The mechanism itself (`CaptionRules.optionalStatuses` and
    /// `.additionalSelfSuffixes`, both general lists) is proven language-
    /// agnostically by `testCaptionRules_optionalStatusesAndAdditionalSelfSuffixes_genericMechanism`
    /// below, with made-up, non-Cyrillic stand-ins.
    func testZoomNative_handRaisedOptionalStatus_englishCaptions() {
        let window = ZoomNative.window(children: [
            ZoomNative.tile(name: "Я Сам", handRaised: true),
            ZoomNative.tile(name: "Борис Пример", speaking: true),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertEqual(snapshot.people, ["Я Сам", "Борис Пример"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// A comma inside the name itself (not a status separator) must survive:
    /// exactly `statusCount` known statuses are stripped from the end, and
    /// whatever is left — commas included — is the name.
    func testZoomNative_commaInsideNameIsPreserved() {
        let window = ZoomNative.window(children: [ZoomNative.tile(name: "Иванов, Иван")])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.people, ["Иванов, Иван"])
    }

    /// "Hand raised" as the trailing phrase, in both languages and before or
    /// after a capitalized marker: three tiles, each a different order of
    /// the same two optional-and-marker phrases, must all still parse.
    func testZoomNative_handRaisedAsThirdStatus_stillParsed() {
        let boris = FakeNode(role: "AXTabGroup", description: "Борис Пример, Computer audio unmuted, Video off, Hand raised")
        let guestThree = FakeNode(
            role: "AXTabGroup",
            description: "Гость Три, Computer audio muted, Video on, Hand raised, Active speaker"
        )
        let window = ZoomNative.window(children: [boris, guestThree])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Гость Три"])
    }

    /// The speaking marker does not have to be the very last phrase: here it
    /// sits before "Hand raised", the opposite order from every tile above.
    func testZoomNative_markerBeforeHandRaised_alsoParsed() {
        let tile = FakeNode(
            role: "AXTabGroup",
            description: "Борис Пример, Computer audio unmuted, Video off, active speaker, Hand raised"
        )
        let window = ZoomNative.window(children: [tile])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// "Screen sharing" (English and Russian) sits *between* the two
    /// mandatory statuses, not only at the very end: the parse must still
    /// find both mandatory ones and strip the optional one wherever it is.
    // The Russian form of this case ("Демонстрация экрана" between two
    // Russian statuses) is exercised below, under "Zoom captions read from
    // Zoom's own bundle" (testZoomInstalledCaptions_russian_handRaisedAndScreenSharingAnywhereInTail).
    func testZoomNative_screenSharingStatus_survives() {
        let boris = FakeNode(
            role: "AXTabGroup",
            description: "Борис Пример, Computer audio unmuted, Screen sharing, Video on"
        )
        let window = ZoomNative.window(children: [boris])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    // MARK: - Google Meet (tab in a browser; least reliable row, see the owner's live check)

    /// Granola's own candidate classes: `dkjMxf` tile, `aGWPv` own tile,
    /// `notranslate` name, `kssMZb` speaking.
    func testMeet_granolaCandidates_threeTiles_selfByOwnTileClass_oneSpeaking() {
        let area = Meet.meetingArea(tiles: [
            Meet.tile(name: "Анна Тестова", isSelf: true),
            Meet.tile(name: "Борис Пример", speaking: true),
            Meet.tile(name: "Гость Три"),
        ])
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "meet")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// Vexa/Whadio's own candidate classes: `zWGUib`/`XWGOtd` name (instead
    /// of `notranslate`), `Oaajhc`/`HX2H7`/`wEsLMd`/`OgVli` speaking (instead
    /// of `kssMZb`) — every one of them must be tried, not only the first.
    func testMeet_vexaCandidates_alternateNameAndSpeakingClasses() {
        let area = Meet.meetingArea(tiles: [
            Meet.tile(name: "Анна Тестова", nameClass: "zWGUib", isSelf: true),
            Meet.tile(name: "Борис Пример", nameClass: "XWGOtd", speaking: true, speakingClass: "Oaajhc"),
            Meet.tile(name: "Гость Три", nameClass: "zWGUib", speaking: true, speakingClass: "HX2H7"),
            Meet.tile(name: "Гость Четыре", nameClass: "XWGOtd", speaking: true, speakingClass: "wEsLMd"),
            Meet.tile(name: "Гость Пять", nameClass: "zWGUib", speaking: true, speakingClass: "OgVli"),
        ])
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три", "Гость Четыре", "Гость Пять"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример", "Гость Три", "Гость Четыре", "Гость Пять"])
    }

    /// Meet's `notranslate` class also marks its Material Icons, whose own
    /// text is the icon's name (`mic_off`) in a child `AXStaticText`: this
    /// row's `nameFromStaticText` stays `false` so such an icon, placed
    /// before the real name node in the tile, never becomes the name.
    func testMeet_iconWithNotranslateBeforeName_neverBecomesTheName() {
        let icon = FakeNode(classes: ["notranslate"], children: [FakeNode(role: "AXStaticText", value: "mic_off")])
        let nameNode = FakeNode(classes: ["notranslate"], title: "Борис Пример")
        let tile = FakeNode(classes: ["dkjMxf"], children: [icon, nameNode])
        let area = Meet.meetingArea(tiles: [tile])
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertFalse(snapshot.people.contains("mic_off"))
        XCTAssertFalse(snapshot.speaking.contains("mic_off"))
    }

    /// `gjg47c` on the speaking indicator itself vetoes a candidate class on
    /// that very same node: a tile whose indicator carries both is not
    /// speaking. The person must stay named and in `people` (or `selfName`)
    /// regardless — only `speaking`/`selfSpeaking` go empty, so this never
    /// reads the same as a tile that was dropped from the grid entirely.
    func testMeet_silenceClassVetoesSpeaking_personStaysNamed() {
        let area = Meet.meetingArea(tiles: [
            Meet.tile(name: "Анна Тестова", isSelf: true, speaking: true, silenced: true),
            Meet.tile(name: "Борис Пример", speaking: true, silenced: true),
        ])
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// `gjg47c` vetoes speaking for the whole tile, not only the node it sits
    /// on: here the speaking class is on the tile element itself, and
    /// `gjg47c` is on a separate child of that same tile. The person must
    /// still stay named and in `people`.
    func testMeet_silenceClassOnDifferentNodeThanSpeakingClass_vetoesWholeTile() {
        let nameNode = FakeNode(classes: ["notranslate"], title: "Борис Пример")
        let silenceNode = FakeNode(classes: ["gjg47c"])
        let tile = FakeNode(classes: ["dkjMxf", "kssMZb"], children: [nameNode, silenceNode])
        let area = Meet.meetingArea(tiles: [tile])
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// `CaptionRules.optionalStatuses` and `.additionalSelfSuffixes` are
    /// both general lists, not Zoom-specific: proven here with a made-up,
    /// non-Cyrillic second status and suffix, independent of the real
    /// "zoom" row's own (currently English-only) data. A tile ending in
    /// "Extra flag" (an optional status the rules don't require) still
    /// parses once the two mandatory statuses are found behind it, and the
    /// own name is matched by the *second* suffix in the list, not only the
    /// first.
    func testCaptionRules_optionalStatusesAndAdditionalSelfSuffixes_genericMechanism() {
        var rules = ZoomShape.rules()
        rules.optionalStatuses = ["Extra flag"]
        rules.additionalSelfSuffixes = [" (owner)"]
        let service = MeetingPageReader.Service(
            id: "caption-mechanism-test", place: .app(bundleID: "test.mechanism", windowIdentifier: ZoomShape.windowIdentifier),
            classMatch: .exact, gridClass: "", tileClasses: [], tileDevicesClass: "", tileDisplayClass: "",
            selfClass: "", nameClass: "", speakingClass: "", captionRules: rules
        )
        let list = FakeNode(role: "AXOutline", children: [FakeNode(title: "Анна Тестова (owner)")])
        let tile = FakeNode(
            role: "AXTabGroup", description: "Анна Тестова, Computer audio unmuted, Video off, Extra flag"
        )
        let window = FakeNode(
            role: "AXWindow", children: [list, tile], identifier: ZoomShape.windowIdentifier, axElement: NSObject()
        )

        let snapshot = MeetingPageReader.snapshot(
            windows: ["test.mechanism": [window]], holders: ["test.mechanism"], pin: nil, limits: limits(), services: [service]
        )

        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, [])
    }

    /// The local user's own name, read only from the participants list row
    /// ending " (me)", never from a tile's own matching description.
    func testZoomNative_selfNameFoundFromParticipantsList() {
        let list = ZoomNative.participantsList([ZoomNative.selfListRow(name: "Я Сам")])
        let window = ZoomNative.window(children: [
            list,
            ZoomNative.tile(name: "Я Сам"),
            ZoomNative.tile(name: "Борис Пример", speaking: true),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot.selfName, "Я Сам")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    // MARK: - Zoom captions read from Zoom's own bundle
    //
    // `addingInstalledZoomCaptions` is exercised directly against a fixture
    // bundle (never the real, installed Zoom: a test process never reads
    // one) built by `ZoomNative.stubBundle`, a text (NeXTSTEP-style)
    // `.strings` file per language, UTF-16 encoded like Zoom's own. Every
    // name is made up.

    func testZoomInstalledCaptions_russian_threeParticipants_oneSpeaking() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        let window = ZoomNative.window(children: [
            ZoomNative.tile(name: "Борис Пример", audio: "Звук компьютера включен", video: "Видео выкл."),
            ZoomNative.tile(
                name: "Гость Три", speaking: true, audio: "Звук компьютера включен", video: "Видео выкл.",
                speakingMarker: "Активный докладчик"
            ),
            ZoomNative.tile(name: "Анна Тестова", audio: "Звук компьютера включен", video: "Видео выкл."),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
        )

        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три", "Анна Тестова"])
        XCTAssertEqual(snapshot.speaking, ["Гость Три"])
    }

    func testZoomInstalledCaptions_russian_selfNameFromParticipantsList() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        let list = ZoomNative.participantsList([ZoomNative.selfListRow(name: "Я Сам", suffix: " (я)")])
        let window = ZoomNative.window(children: [
            list,
            ZoomNative.tile(name: "Я Сам", audio: "Звук компьютера включен", video: "Видео выкл."),
            ZoomNative.tile(
                name: "Борис Пример", speaking: true, audio: "Звук компьютера включен", video: "Видео выкл.",
                speakingMarker: "Активный докладчик"
            ),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
        )

        XCTAssertEqual(snapshot.selfName, "Я Сам")
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример"])
    }

    /// The optional statuses ("Рука поднята", "Демонстрация экрана") appear
    /// in a different place in each of the three tiles' tails — before the
    /// marker, between the two mandatory statuses, and before both mandatory
    /// statuses — and all three still parse to a name.
    func testZoomInstalledCaptions_russian_handRaisedAndScreenSharingAnywhereInTail() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        let selfTile = FakeNode(
            role: "AXTabGroup", description: "Я Сам, Звук компьютера включен, Видео выкл., Рука поднята"
        )
        let guestThree = FakeNode(
            role: "AXTabGroup",
            description: "Гость Три, Звук компьютера включен, Демонстрация экрана, Видео вкл., Активный докладчик"
        )
        let boris = FakeNode(
            role: "AXTabGroup", description: "Борис Пример, Рука поднята, Звук компьютера выключен, Видео не подключено"
        )
        let window = ZoomNative.window(children: [selfTile, guestThree, boris])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
        )

        XCTAssertEqual(snapshot.people, ["Я Сам", "Гость Три", "Борис Пример"])
        XCTAssertEqual(snapshot.speaking, ["Гость Три"])
    }

    func testZoomInstalledCaptions_russian_commaInsideName() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        let window = ZoomNative.window(children: [
            ZoomNative.tile(name: "Пример, Борис", audio: "Звук компьютера включен", video: "Видео выкл."),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
        )

        XCTAssertEqual(snapshot.people, ["Пример, Борис"])
    }

    /// Zoom itself never mixes languages in one call, but the phrase lists
    /// are checked independently of each other: a tile whose statuses are in
    /// one language and whose marker is in another still parses to its name,
    /// and the marker is still found regardless of its case — exactly as the
    /// existing, single-language English marker already is. Refusing a tile
    /// over an unfamiliar mix, instead, would lose a real speaker's name for
    /// no benefit: nothing here can make one phrase swallow a different
    /// status or a different name.
    func testZoomInstalledCaptions_mixedLanguageInOneDescription() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        let russianNameEnglishMarker = FakeNode(
            role: "AXTabGroup", description: "Борис Пример, Звук компьютера включен, Видео выкл., active speaker"
        )
        let englishStatusesRussianMarker = FakeNode(
            role: "AXTabGroup", description: "Анна Тестова, Computer audio unmuted, Video off, активный докладчик"
        )
        let window = ZoomNative.window(children: [russianNameEnglishMarker, englishStatusesRussianMarker])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
        )

        XCTAssertEqual(snapshot.people, ["Борис Пример", "Анна Тестова"])
        XCTAssertEqual(snapshot.speaking, ["Борис Пример", "Анна Тестова"])
    }

    /// No bundle at all (`nil`) and a bundle folder that does not exist
    /// behave the same way: the row keeps only its English fallback, so an
    /// English tile still parses and a Russian one — not in the table at all
    /// — is silently dropped, never mistaken for an unknown shape that
    /// crashes or errors.
    func testZoomInstalledCaptions_noBundle_englishStillWorks() {
        let missingAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("not-zoom.app")

        for appURL in [nil, missingAppURL] {
            let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)
            let window = ZoomNative.window(children: [
                ZoomNative.tile(name: "Борис Пример"),
                ZoomNative.tile(name: "Анна Тестова", audio: "Звук компьютера включен", video: "Видео выкл."),
            ])

            let snapshot = MeetingPageReader.snapshot(
                windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
            )

            XCTAssertEqual(snapshot.people, ["Борис Пример"])
        }
    }

    /// A fixture `ru.lproj` missing exactly one key (the "Video off" one)
    /// never adds that one phrase: a tile ending in it stays unparsed, while
    /// a tile ending in the sibling phrase that is present still works.
    func testZoomInstalledCaptions_missingKey_phraseNotAdded() throws {
        var incompleteRussian = ZoomNative.russianStrings
        incompleteRussian.removeValue(forKey: "LN_Plist_Accessibility_Video_Off_20044")
        let appURL = try ZoomNative.stubBundle(languages: ["ru": incompleteRussian])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        guard let zoomService = services.first(where: { service in
            guard case .app(let bundleID, _) = service.place else { return false }
            return bundleID == ZoomNative.bundleID
        }) else {
            return XCTFail("Zoom row not found")
        }
        XCTAssertFalse(zoomService.captionRules?.statuses.contains("Видео выкл.") ?? true)
        XCTAssertTrue(zoomService.captionRules?.statuses.contains("Видео вкл.") ?? false)

        let window = ZoomNative.window(children: [
            ZoomNative.tile(name: "Борис Пример", audio: "Звук компьютера включен", video: "Видео выкл."),
            ZoomNative.tile(name: "Анна Тестова", audio: "Звук компьютера включен", video: "Видео вкл."),
        ])

        let snapshot = MeetingPageReader.snapshot(
            windows: [ZoomNative.bundleID: [window]], holders: [ZoomNative.bundleID], pin: nil, limits: limits(), services: services
        )

        XCTAssertEqual(snapshot.people, ["Анна Тестова"])
    }

    /// A bundle shipping both `en.lproj` (the row's own English phrases,
    /// different case on the marker) and `ru.lproj`: the English phrases are
    /// not duplicated, only the Russian ones are genuinely new, and every
    /// other row in the table — including Zoom's own web-client row, which
    /// shares the "zoom" id but has no `captionRules` — is untouched.
    func testZoomInstalledCaptions_otherRowsUnchanged_andNoDuplicates() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["en": ZoomNative.englishStrings, "ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)

        XCTAssertEqual(services.count, MeetingPageReader.services.count)

        guard let zoomService = services.first(where: { service in
            guard case .app(let bundleID, _) = service.place else { return false }
            return bundleID == ZoomNative.bundleID
        }), let rules = zoomService.captionRules else {
            return XCTFail("Zoom row not found")
        }
        XCTAssertEqual(rules.statuses.count, 16)
        XCTAssertEqual(rules.speakingMarkers.count, 2)
        XCTAssertEqual(rules.optionalStatuses.count, 4)
        XCTAssertEqual(rules.additionalSelfSuffixes, [" (я)"])

        for row in services {
            guard case .app(let bundleID, _) = row.place, bundleID == ZoomNative.bundleID else {
                XCTAssertNil(row.captionRules)
                continue
            }
        }
    }

    // MARK: - Reading Zoom's own bundle is bounded and lazy (5)

    private func zoomCaptionRules(in services: [MeetingPageReader.Service]) -> MeetingPageReader.CaptionRules? {
        services.first { service in
            guard case .app(let bundleID, _) = service.place else { return false }
            return bundleID == ZoomNative.bundleID
        }?.captionRules
    }

    /// A `Localizable.strings` that is a link, not a file, must never be
    /// opened at all: the English fallback stays, the linked-to Russian
    /// phrase never arrives. `O_NOFOLLOW` refuses it outright.
    func testZoomInstalledCaptions_symlinkedStringsFile_skipped() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["en": ZoomNative.englishStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let root = appURL.deletingLastPathComponent()
        let ruLprojURL = appURL.appendingPathComponent("Contents").appendingPathComponent("Resources")
            .appendingPathComponent("ru.lproj")
        try FileManager.default.createDirectory(at: ruLprojURL, withIntermediateDirectories: true)

        var text = ""
        for (key, value) in ZoomNative.russianStrings { text += "\"\(key)\" = \"\(value)\";\n" }
        let outsideFile = root.appendingPathComponent("outside-ru.strings")
        try XCTUnwrap(text.data(using: .utf16)).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: ruLprojURL.appendingPathComponent("Localizable.strings"), withDestinationURL: outsideFile
        )

        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)
        let rules = try XCTUnwrap(zoomCaptionRules(in: services), "Zoom row not found")
        XCTAssertTrue(rules.statuses.contains("Video off"))
        XCTAssertFalse(rules.statuses.contains("Видео выкл."), "a symlinked strings file must never be opened")
    }

    /// A whole `<lang>.lproj` that is a link, not a directory, must never be
    /// descended into either — not just the file inside it.
    func testZoomInstalledCaptions_symlinkedLprojFolder_skipped() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["en": ZoomNative.englishStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let root = appURL.deletingLastPathComponent()
        let resourcesURL = appURL.appendingPathComponent("Contents").appendingPathComponent("Resources")

        let outsideDir = root.appendingPathComponent("outside-ru.lproj")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        var text = ""
        for (key, value) in ZoomNative.russianStrings { text += "\"\(key)\" = \"\(value)\";\n" }
        try XCTUnwrap(text.data(using: .utf16)).write(to: outsideDir.appendingPathComponent("Localizable.strings"))
        try FileManager.default.createSymbolicLink(
            at: resourcesURL.appendingPathComponent("ru.lproj"), withDestinationURL: outsideDir
        )

        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)
        let rules = try XCTUnwrap(zoomCaptionRules(in: services), "Zoom row not found")
        XCTAssertFalse(rules.statuses.contains("Видео выкл."), "a symlinked lproj folder must never be descended into")
    }

    /// A `Localizable.strings` whose valid phrases are followed by an inert
    /// comment padded well past the 8 MiB per-file limit must be skipped
    /// whole — not partially parsed, not read past the limit.
    func testZoomInstalledCaptions_oversizedStringsFile_skipped() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["en": ZoomNative.englishStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let ruLprojURL = appURL.appendingPathComponent("Contents").appendingPathComponent("Resources")
            .appendingPathComponent("ru.lproj")
        try FileManager.default.createDirectory(at: ruLprojURL, withIntermediateDirectories: true)

        var text = ""
        for (key, value) in ZoomNative.russianStrings { text += "\"\(key)\" = \"\(value)\";\n" }
        let padding = String(repeating: " ", count: 8 * 1024 * 1024)
        text += "/*\(padding)*/\n"
        let data = try XCTUnwrap(text.data(using: .utf16))
        XCTAssertGreaterThan(data.count, 8 * 1024 * 1024, "the fixture itself must exceed the per-file limit")
        try data.write(to: ruLprojURL.appendingPathComponent("Localizable.strings"))

        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)
        let rules = try XCTUnwrap(zoomCaptionRules(in: services), "Zoom row not found")
        XCTAssertTrue(rules.statuses.contains("Video off"))
        XCTAssertFalse(rules.statuses.contains("Видео выкл."), "a file over the per-file byte limit must be skipped whole")
    }

    /// Only the first `maxLocalizations` folders, sorted the same way as
    /// before, are even opened — a later one is never read, whatever it
    /// contains.
    func testZoomInstalledCaptions_localizationCountLimit() throws {
        let languages: [String: [String: String]] = [
            "aa": ["LN_Plist_Accessibility_Video_Off_20044": "Aa phrase"],
            "bb": ["LN_Plist_Accessibility_Video_Off_20044": "Bb phrase"],
            "cc": ["LN_Plist_Accessibility_Video_Off_20044": "Cc phrase"],
        ]
        let appURL = try ZoomNative.stubBundle(languages: languages)
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let limits = MeetingPageReader.ZoomResourceLimits(
            maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 64 * 1024 * 1024, maxLocalizations: 2
        )

        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services, limits: limits)
        let rules = try XCTUnwrap(zoomCaptionRules(in: services), "Zoom row not found")
        XCTAssertTrue(rules.statuses.contains("Aa phrase"))
        XCTAssertTrue(rules.statuses.contains("Bb phrase"))
        XCTAssertFalse(rules.statuses.contains("Cc phrase"), "a third localization beyond the limit must never be opened")
    }

    /// A named pipe sitting where `ru.lproj`'s `Localizable.strings` should
    /// be must never block the read: on the code before this card, `open`
    /// itself blocked forever on it (nothing ever writes to this pipe), and
    /// with it every caption read in every service, until the app
    /// restarted. The call runs on its own thread so this test fails by
    /// timing out, not by hanging the whole suite, if that regresses; the
    /// English language still loads, and the FIFO's own language is simply
    /// skipped.
    func testZoomInstalledCaptions_fifoInsteadOfStringsFile_skippedWithoutHanging() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["en": ZoomNative.englishStrings, "ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let ruStringsURL = appURL.appendingPathComponent("Contents").appendingPathComponent("Resources")
            .appendingPathComponent("ru.lproj").appendingPathComponent("Localizable.strings")
        try FileManager.default.removeItem(at: ruStringsURL)
        guard mkfifo(ruStringsURL.path, 0o600) == 0 else { return XCTFail("could not create the FIFO fixture") }
        // Wake a reader that is already stuck in `open` on this FIFO (a
        // writer's own `open` does that); if the reader has not reached
        // `open` yet this returns ENXIO instead, so a short retry covers
        // that race without leaving the old code's reader thread blocked
        // past this test (K3).
        addTeardownBlock {
            for _ in 0..<10 {
                let descriptor = ruStringsURL.path.withCString { Darwin.open($0, O_WRONLY | O_NONBLOCK) }
                if descriptor >= 0 { Darwin.close(descriptor); break }
                usleep(50_000)
            }
        }

        final class ResultBox: @unchecked Sendable {
            var services: [MeetingPageReader.Service] = []
        }
        let box = ResultBox()
        let returned = expectation(description: "addingInstalledZoomCaptions returns")
        Thread.detachNewThread {
            box.services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)

        let rules = try XCTUnwrap(zoomCaptionRules(in: box.services), "Zoom row not found")
        XCTAssertTrue(rules.statuses.contains("Video off"), "the English language must still load")
        XCTAssertFalse(rules.statuses.contains("Видео выкл."), "the FIFO's own language must be skipped, never read")
    }

    /// `Contents/Resources` listing more entries than `maxResourceEntries`
    /// skips the whole bundle read — the row keeps only its own English
    /// literal, never Zoom's installed phrases in any language: enumerating
    /// and filtering a directory a hostile or corrupted bundle made huge is
    /// never attempted at all. The limit is passed as a small parameter
    /// here, not proven with thousands of real fixture files.
    func testZoomInstalledCaptions_resourceEntryLimit_skipsTheWholeBundle() throws {
        let appURL = try ZoomNative.stubBundle(languages: ["en": ZoomNative.englishStrings, "ru": ZoomNative.russianStrings])
        addTeardownBlock { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let limits = MeetingPageReader.ZoomResourceLimits(
            maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 64 * 1024 * 1024, maxLocalizations: 64, maxResourceEntries: 1
        )

        let services = MeetingPageReader.addingInstalledZoomCaptions(appURL: appURL, to: MeetingPageReader.services, limits: limits)
        let rules = try XCTUnwrap(zoomCaptionRules(in: services), "Zoom row not found")
        XCTAssertTrue(rules.statuses.contains("Video off"), "the row's own English literal must stay")
        XCTAssertFalse(rules.statuses.contains("Видео выкл."), "past the entry limit, nothing from the bundle is read")
    }

    /// Zoom's installed bundle is read only when an actual Zoom-program read
    /// is going to happen — never for a call in Chrome, nor even for Zoom's
    /// own web client, which shares the "zoom" id but not the program row.
    func testChromeCall_neverLoadsZoomBundle() {
        var count = 0
        func zoomCaptions() -> [MeetingPageReader.Service] {
            count += 1
            return MeetingPageReader.services
        }

        _ = MeetingPageReader.servicesForRead(holders: ["com.google.Chrome.helper"], pin: nil, zoomCaptions: zoomCaptions)
        XCTAssertEqual(count, 0, "a Chrome-only call must never load Zoom's installed bundle")

        let webZoomPin = MeetingPageReader.Pin(
            service: "zoom", app: "com.google.Chrome", meeting: .page(address: "https://app.zoom.us/wc/1234/join")
        )
        _ = MeetingPageReader.servicesForRead(holders: [], pin: webZoomPin, zoomCaptions: zoomCaptions)
        XCTAssertEqual(count, 0, "Zoom's own web client must not load the installed program's bundle either")

        _ = MeetingPageReader.servicesForRead(holders: ["us.zoom.xos"], pin: nil, zoomCaptions: zoomCaptions)
        XCTAssertEqual(count, 1, "an actual Zoom-program read must load it exactly once")
    }

    // MARK: - Zoom's web client (a Chrome tab, Speaker view; also the
    // "zoom" row — a second row sharing the first one's id, same as
    // Bitrix24's two rows)

    /// The big tile's class is one of the two Vexa observed
    /// (`single-main-container__video-frame`); the name comes from a `span`
    /// inside `.video-avatar__avatar-footer` nested in it. Speaker view has
    /// no self detection at all, so the one other person found goes to
    /// `people`, never `selfName`.
    func testZoomWeb_presenterMode_bigTileNamesTheOtherPerson() {
        let area = ZoomWeb.meetingArea([ZoomWeb.bigTile(name: "Гость Три")])
        let windows = [ZoomWeb.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "zoom")
        XCTAssertEqual(snapshot.selfName, "")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
        // The big tile may be a deliberately pinned video, not necessarily
        // whoever is speaking (3a): this row never claims `speaking` for it.
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// The other class Vexa observed (`single-suspension-container__video-frame`)
    /// must also be read, not only the first of the two.
    func testZoomWeb_suspensionContainerClassVariant_alsoMatchesTheBigTile() {
        let area = ZoomWeb.meetingArea([
            ZoomWeb.bigTile(name: "Участник Один", tileClass: "single-suspension-container__video-frame"),
        ])
        let windows = [ZoomWeb.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Участник Один"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// The footer carries no text of its own (as the real `video-avatar__avatar-footer`
    /// div usually doesn't): the name must come from the `AXStaticText` span
    /// nested inside it, and a sibling icon that only carries a description
    /// (the muted-microphone glyph) must never become the name.
    func testZoomWeb_nameFromStaticTextInsideFooter_iconIsNotTheName() {
        let icon = FakeNode(role: "AXImage", description: "Audio muted")
        let nameText = FakeNode(role: "AXStaticText", value: "Борис Пример")
        let footer = FakeNode(classes: ["video-avatar__avatar-footer"], children: [icon, nameText])
        let bigTile = FakeNode(classes: ["single-main-container__video-frame"], children: [footer])
        let area = ZoomWeb.meetingArea([bigTile])
        let windows = [ZoomWeb.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.service, "zoom")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.people, ["Борис Пример"])
        XCTAssertEqual(snapshot.speaking, [])
        XCTAssertEqual(snapshot.selfName, "")
    }

    /// The same footer-with-no-own-text shape, on the other known class
    /// (`single-suspension-container__video-frame`) and a different Zoom
    /// host (`us05web.zoom.us`, covered by the `zoom.us/wc/` substring).
    func testZoomWeb_suspensionFrame_otherZoomHost_nameFromStaticText() {
        let icon = FakeNode(role: "AXImage", description: "Audio muted")
        let nameText = FakeNode(role: "AXStaticText", value: "Гость Три")
        let footer = FakeNode(classes: ["video-avatar__avatar-footer"], children: [icon, nameText])
        let bigTile = FakeNode(classes: ["single-suspension-container__video-frame"], children: [footer])
        let area = ZoomWeb.meetingArea([bigTile], address: "https://us05web.zoom.us/wc/1234567890/join")
        let windows = [ZoomWeb.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// Speaker view's one big tile is not necessarily the active speaker —
    /// Zoom lets a user pin someone's video there regardless of who is
    /// talking (3a) — so this row never claims the big tile is speaking
    /// merely because it is the one tile found.
    func testZoomWeb_bigTile_isNotSpeakingByPlaceAlone() {
        let area = ZoomWeb.meetingArea([ZoomWeb.bigTile(name: "Гость Три")])
        let windows = [ZoomWeb.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.people, ["Гость Три"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// The gallery view carries none of the known classes: the meeting area
    /// is found (the address matches), but no tile is, so `visible` stays
    /// false — by design (the card's own claim), not a bug.
    func testZoomWeb_galleryView_noKnownTileClass_notVisible() {
        let decoyTile = FakeNode(
            classes: ["gallery-tile-unknown"],
            children: [FakeNode(classes: ["video-avatar__avatar-footer"], title: "Участник Один")]
        )
        let area = ZoomWeb.meetingArea([decoyTile])
        let windows = [ZoomWeb.window([area])]

        // An area with no real tile is never confirmed on its own (2): read
        // with a pin on this very address.
        let pin = MeetingPageReader.Pin(
            service: "zoom", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://app.zoom.us/wc/1234/join")!)
        )
        let snapshot = readInChrome(windows, limits: limits(), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    /// Same veto for the own tile: `aGWPv` and the name are on the tile
    /// itself, `kssMZb` is on one child and `gjg47c` on another — the veto
    /// must still reach across the whole tile and clear `selfSpeaking`.
    func testMeet_silenceClassOnDifferentNodeThanSpeakingClass_vetoesSelfTile() {
        let nameNode = FakeNode(classes: ["notranslate"], title: "Анна Тестова")
        let speakingNode = FakeNode(classes: ["kssMZb"])
        let silenceNode = FakeNode(classes: ["gjg47c"])
        let tile = FakeNode(classes: ["dkjMxf", "aGWPv"], children: [nameNode, speakingNode, silenceNode])
        let area = Meet.meetingArea(tiles: [tile])
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking)
    }

    /// `.exact` class matching for Meet's tile class: a near-miss class
    /// (`dkjMxf-extra`) must not be treated as a tile at all.
    func testMeet_exactClassMode_nearMissTileClassIsNotATile() {
        let impostorTile = Meet.tile(name: "Гость Три", tileClass: "dkjMxf-extra")
        let area = Meet.meetingArea(tiles: [impostorTile])
        let windows = [Meet.window([area])]

        let pin = MeetingPageReader.Pin(
            service: "meet", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://meet.google.com/abc-defg-hij")!)
        )
        let snapshot = readInChrome(windows, limits: limits(), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    // MARK: - Fix: a pinned recording must match the row that actually runs
    // in the pinned app, not merely the first row sharing its id

    /// Before this card's fix, `targets(holders:pin:services:)` picked
    /// `services.first(where: { $0.id == pin.service })` regardless of
    /// `pin.app` — the native `.app` row (listed first for id "zoom")
    /// even when the pinned app is a browser. A recording pinned to Zoom's
    /// web client would then never find its tab again. With the fix, the
    /// row that actually `runs(_:in:)` the pinned app is picked.
    func testPinned_duplicateServiceID_picksTheRowThatRunsInThePinnedApp() {
        let pin = MeetingPageReader.Pin(
            service: "zoom", app: "com.google.Chrome", meeting: .page(address: "https://app.zoom.us/wc/1234/join")
        )
        let area = ZoomWeb.meetingArea([ZoomWeb.bigTile(name: "Гость Три")])
        let windows = [ZoomWeb.window([area])]

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: [], pin: pin, limits: limits()
        )

        XCTAssertTrue(snapshot.found, "the web row for \"zoom\" must be tried, not the native app row sharing its id")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
    }

    /// `.exact` class matching for Meet's name classes too: a near-miss
    /// (`notranslate-xyz`, matching none of the candidates exactly) leaves
    /// the tile without a name, so it contributes no one.
    func testMeet_exactClassMode_nearMissNameClassDoesNotNameTheTile() {
        let tile = Meet.tile(name: "Гость Три", nameClass: "notranslate-xyz")
        let area = Meet.meetingArea(tiles: [tile])
        let windows = [Meet.window([area])]

        let pin = MeetingPageReader.Pin(
            service: "meet", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://meet.google.com/abc-defg-hij")!)
        )
        let snapshot = readInChrome(windows, limits: limits(), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    /// The starting `meet.google.com/landing` page, with recording on but no
    /// one in a call yet: the meeting area is still accepted (it is the
    /// owner's own recorded tab), `service` is already written, but with no
    /// tiles at all `visible` must stay false — "not seen" rather than a
    /// guess.
    func testMeet_landingPage_areaFoundButNoTilesSoNotVisible() {
        let area = Meet.meetingArea(tiles: [], address: "https://meet.google.com/landing")
        let windows = [Meet.window([area])]

        let pin = MeetingPageReader.Pin(
            service: "meet", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://meet.google.com/landing")!)
        )
        let snapshot = readInChrome(windows, limits: limits(), pin: pin)

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "meet")
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    /// A page at another address entirely must never be mistaken for a Meet
    /// call.
    func testMeet_wrongAddress_notFound() {
        let area = Meet.meetingArea(tiles: [Meet.tile(name: "Гость Три")], address: "https://example.com/abc-defg-hij")
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - Address parsing: host boundary and path, never query/fragment/a foreign path

    /// A search engine's own address with the meeting's host inside the
    /// query string must never be mistaken for the meeting itself: only
    /// `scheme://host/path` is ever looked at.
    func testMeetAddressInsideGoogleSearchQuery_notAMeeting() {
        let area = Meet.meetingArea(
            tiles: [Meet.tile(name: "Гость Три")],
            address: "https://www.google.com/search?q=meet.google.com/abc-defg-hij"
        )
        let windows = [Meet.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// `cdn.bitrix24.ru.example.com` carries the substring `.bitrix24.` (the
    /// old `url.contains` rule would have accepted it) but is neither
    /// `bitrix24.ru` nor a subdomain of it: the domain-boundary check must
    /// reject it. The literal host from the card, `bitrix24.ru.example.com`,
    /// is checked too, though the old substring rule already rejected it on
    /// its own (no dot stands right before `bitrix24` there).
    func testBitrix24LookalikeHost_notAMeeting() {
        let area = Bitrix24.meetingArea(
            children: [Bitrix24.tile(name: "Гость Три")], portal: "cdn.bitrix24.ru.example.com"
        )
        let windows = [Bitrix24.window([area])]
        XCTAssertEqual(readInChrome(windows, limits: limits()), .notFound)

        let literalArea = Bitrix24.meetingArea(
            children: [Bitrix24.tile(name: "Гость Три")], portal: "bitrix24.ru.example.com"
        )
        let literalWindows = [Bitrix24.window([literalArea])]
        XCTAssertEqual(readInChrome(literalWindows, limits: limits()), .notFound)
    }

    /// A foreign site with a Bitrix24 portal's domain inside its own path
    /// (not its host) must never be read as that portal.
    func testBitrix24DomainInsideForeignPath_notAMeeting() {
        let area = Bitrix24.meetingArea(
            children: [Bitrix24.tile(name: "Гость Три")],
            portal: "example.com", path: "go/testportal.bitrix24.ru/video/x"
        )
        let windows = [Bitrix24.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Zoom's own `/wc/` path, on a host that is not `zoom.us` or one of its
    /// subdomains, must never be read as a Zoom web call.
    func testZoomWebPathOnForeignHost_notAMeeting() {
        let area = ZoomWeb.meetingArea(
            [ZoomWeb.bigTile(name: "Гость Три")], address: "https://example.com/zoom.us/wc/1234/join"
        )
        let windows = [ZoomWeb.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// Jitsi's own server name inside another site's query string (not its
    /// own host) must never be read as a Jitsi call.
    func testJitsiServerInsideQuery_notAMeeting() {
        let tile = Jitsi.tile(name: "Гость Три")
        let area = DOMIdentifiedNode(role: "AXWebArea", axURL: "https://example.com/?r=meet.jit.si/room", children: [tile])
        let windows = [Jitsi.window([area])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    // MARK: - One pass: a later row still finds its area in a big window

    /// Before this card, each row walked the window from scratch, so a row
    /// after several large ones could starve on the shared budget even
    /// though a single walk would have reached it easily. Here Meet (the
    /// last browser row) sits behind ~1300 plain nodes that none of the
    /// earlier rows' addresses match: a single walk collecting candidates
    /// for every row at once reaches it well inside the default budget.
    func testOnePass_laterRowFindsItsAreaInABigWindow() {
        var padding: [AccessibilityPageNode] = []
        for i in 0..<1300 {
            padding.append(FakeNode(classes: ["filler-\(i)"]))
        }
        let meetArea = Meet.meetingArea(tiles: [Meet.tile(name: "Гость Три")])
        let group = FakeNode(children: padding + [meetArea])
        let windows = [Telemost.window([group])]

        let snapshot = readInChrome(windows, limits: limits())

        XCTAssertTrue(snapshot.found)
        XCTAssertEqual(snapshot.service, "meet")
        XCTAssertEqual(snapshot.people, ["Гость Три"])
    }

    // MARK: - The Bitrix24 cloud zone list

    func testBitrix24CloudDomains_recognized() {
        for domain in ["de", "kz", "com.br", "eu"] {
            let area = Bitrix24.meetingArea(
                children: [Bitrix24.tile(name: "Гость Три")], portal: "testportal.bitrix24.\(domain)"
            )
            let windows = [Bitrix24.window([area])]

            let snapshot = readInChrome(windows, limits: limits())

            XCTAssertTrue(snapshot.found, "testportal.bitrix24.\(domain) must be recognized")
            XCTAssertEqual(snapshot.people, ["Гость Три"])
        }
    }

    // MARK: - Pinning the meeting itself, not merely the service and app

    /// Two areas sharing the pinned address, both there when this read is
    /// made: the choice cannot tell them apart, so nothing is read rather
    /// than guess which one is the pinned meeting.
    func testPinned_twoAreasWithThePinnedAddress_nothingRead() {
        let pin = MeetingPageReader.Pin(
            service: "telemost", app: "com.google.Chrome",
            meeting: .page(address: "https://telemost.yandex.ru/private-join/abc123")
        )
        let area1 = Telemost.meetingArea(grid: Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")]))
        let area2 = Telemost.meetingArea(grid: Telemost.grid(tiles: [Telemost.tile(name: "Гость Два")]))
        let windows = [Telemost.window([area1, area2])]

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: [], pin: pin, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
    }

    /// The pinned meeting's address ignores the query and the fragment (a
    /// browser may add either without changing the page), and a read against
    /// that pin keeps finding the same tab across several polls; once the
    /// tab moves to another room, the pinned read finds nothing.
    func testPinned_addressIgnoresQueryAndFragment() {
        let grid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Один")])
        let areaWithQuery = FakeNode(
            role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/abc123?lang=ru#x", children: [grid]
        )
        let windows = [Telemost.window([areaWithQuery])]

        let firstRead = readInChrome(windows, limits: limits())
        XCTAssertEqual(firstRead.meeting, .page(address: "https://telemost.yandex.ru/private-join/abc123"))

        let pin = MeetingPageReader.Pin(service: firstRead.service, app: firstRead.app, meeting: firstRead.meeting)

        let secondRead = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: [], pin: pin, limits: limits()
        )
        XCTAssertEqual(secondRead.people, ["Гость Один"])

        let thirdRead = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": windows], holders: [], pin: pin, limits: limits()
        )
        XCTAssertEqual(thirdRead.people, ["Гость Один"])

        let movedGrid = Telemost.grid(tiles: [Telemost.tile(name: "Гость Два")])
        let movedArea = FakeNode(
            role: "AXWebArea", axURL: "https://telemost.yandex.ru/private-join/room-b", children: [movedGrid]
        )
        let movedWindows = [Telemost.window([movedArea])]
        let fourthRead = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": movedWindows], holders: [], pin: pin, limits: limits()
        )
        XCTAssertEqual(fourthRead, .notFound)
    }

    // MARK: - Microsoft Teams: a scaffold, held back in `unconfirmedServices`
    // — no accessibility-proven tile/speaking signal exists in open sources;
    // see `MeetingPageReader.teamsCaptionRules`'s own comment. Every name
    // below is made up.

    /// Neither Teams row is in the real, live table — `readLive` never
    /// reads either on a live call — and both are in `unconfirmedServices`
    /// instead, under their own distinct ids.
    func testTeamsRows_notInConfirmedServicesTable() {
        XCTAssertFalse(MeetingPageReader.services.contains { $0.id == "teams" || $0.id == "teams-app" })
        XCTAssertEqual(MeetingPageReader.unconfirmedServices.map(\.id), ["teams", "teams-app"])
        XCTAssertEqual(MeetingPageReader.services.first?.id, "telemost", "Telemost stays first, untouched")
    }

    /// A Teams tab, read against the real (default) `services` table: the
    /// row isn't there yet, so this must read nothing at all.
    func testTeamsBrowser_defaultServicesTable_notFound() {
        let area = FakeNode(
            role: "AXWebArea", axURL: "https://teams.microsoft.com/l/meetup-join/abc",
            children: [FakeNode(role: "AXTabGroup", description: "Анна Тестова")]
        )
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = readInChrome([window], limits: limits())

        XCTAssertEqual(snapshot, .notFound)
    }

    /// The macOS program's own window, against the default table: no row
    /// names `com.microsoft.teams2` yet, so its windows must never even be
    /// opened.
    func testTeamsApp_defaultServicesTable_windowNeverOpened() {
        let area = FakeNode(role: "AXWebArea", children: [FakeNode(role: "AXTabGroup", description: "Анна Тестова")])
        let countingWindow = CountingNode(FakeNode(role: "AXWindow", children: [area]))

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.microsoft.teams2": [countingWindow]], holders: ["com.microsoft.teams2"],
            pin: nil, limits: limits()
        )

        XCTAssertEqual(snapshot, .notFound)
        XCTAssertEqual(countingWindow.accesses, 0, "no row names this program yet: its windows must never be opened")
    }

    /// The three known Teams hosts, and a tenant-branded subdomain of the
    /// main one, all match.
    func testTeamsDomains_matchesKnownHostsAndSubdomain() {
        let address = MeetingPageReader.Address(domains: MeetingPageReader.teamsDomains, pathPrefix: "/")
        for host in ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft", "contoso.teams.microsoft.com"] {
            let components = URLComponents(string: "https://\(host)/l/meetup-join/abc")!
            XCTAssertTrue(address.matches(components), host)
        }
    }

    /// A host that merely starts with or contains "teams.microsoft.com", and
    /// the same host inside a search engine's own query, must never match.
    func testTeamsDomains_rejectsLookalikeHostsAndQuery() {
        let address = MeetingPageReader.Address(domains: MeetingPageReader.teamsDomains, pathPrefix: "/")
        for url in [
            "https://xteams.microsoft.com/l/meetup-join/abc",
            "https://teams.microsoft.com.example.org/l/meetup-join/abc",
            "https://www.google.com/search?q=teams.microsoft.com",
        ] {
            let components = URLComponents(string: url)!
            XCTAssertFalse(address.matches(components), url)
        }
    }

    /// The three known hosts other than `teams.microsoft.com` (tested by
    /// `testTeamsBrowser_captionTiles_selfFromRoster_noSpeaking`), and a
    /// tenant-branded subdomain, all mark a Teams tab found, end to end
    /// through `snapshot`.
    func testTeamsBrowser_allThreeHosts() {
        for url in [
            "https://teams.live.com/meet/123",
            "https://teams.cloud.microsoft/",
            "https://contoso.teams.microsoft.com/l/meetup-join/abc",
        ] {
            let area = FakeNode(role: "AXWebArea", axURL: url)
            let window = FakeNode(role: "AXWindow", children: [area])
            // No tile at all, so the area is never confirmed on its own (2):
            // read with a pin on this very address — this test's own point
            // is that the address matched, not that one address alone is
            // ambiguous.
            let pin = MeetingPageReader.Pin(
                service: "teams", app: "com.google.Chrome",
                meeting: .page(address: MeetingPageReader.meetingAddress(of: url)!)
            )

            let snapshot = MeetingPageReader.snapshot(
                windows: ["com.google.Chrome": [window]], holders: ["com.google.Chrome.helper"],
                pin: pin, limits: limits(), services: MeetingPageReader.unconfirmedServices
            )

            XCTAssertTrue(snapshot.found, url)
            XCTAssertEqual(snapshot.service, "teams", url)
            XCTAssertFalse(snapshot.visible, url)
        }
    }

    /// The browser row, tried through `unconfirmedServices` (never the
    /// default table): three tiles by caption, the local user's own name
    /// read from the roster (never from a tile's own description), nobody
    /// speaking since Teams exposes no such signal at all
    /// (`teamsCaptionRules.speakingMarkers == []`).
    func testTeamsBrowser_captionTiles_selfFromRoster_noSpeaking() {
        let tiles: [AccessibilityPageNode] = [
            TeamsShape.tile(name: "Анна Тестова", status: "Muted"),
            TeamsShape.tile(name: "Борис Пример", status: "Unmuted"),
            TeamsShape.tile(name: "Гость Три", status: "Muted"),
        ]
        let area = TeamsShape.page(
            url: "https://teams.microsoft.com/v2/", children: tiles + [TeamsShape.roster(selfName: "Анна Тестова")]
        )
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [window]], holders: ["com.google.Chrome.helper"],
            pin: nil, limits: limits(), services: MeetingPageReader.unconfirmedServices
        )

        XCTAssertTrue(snapshot.visible)
        XCTAssertEqual(snapshot.service, "teams")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertFalse(snapshot.selfSpeaking)
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
        XCTAssertEqual(snapshot.speaking, [])
    }

    /// Teams' own interface groups — "Meeting controls", "Chat", a device
    /// picker — carry a description on the very same role as a tile
    /// (`AXGroup`) but never the mandatory "Name, Muted"/"Name, Unmuted"
    /// shape, nor does a bare name with no status at all: none of them may
    /// become a person. The area is still found (the page itself is a
    /// Teams meeting), but nothing is visible.
    func testTeamsBrowser_interfaceGroupsWithDescriptions_areNotPeople() {
        let groups: [AccessibilityPageNode] = [
            TeamsShape.interfaceGroup(description: "Meeting controls"),
            TeamsShape.interfaceGroup(description: "Chat"),
            TeamsShape.interfaceGroup(description: "Камера и микрофон"),
            TeamsShape.interfaceGroup(description: "Анна Тестова"),
        ]
        let area = TeamsShape.page(url: "https://teams.microsoft.com/v2/", children: groups)
        let window = FakeNode(role: "AXWindow", children: [area])
        // None of these groups is a tile, so the area is never confirmed on
        // its own (2): read with a pin.
        let pin = MeetingPageReader.Pin(
            service: "teams", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://teams.microsoft.com/v2/")!)
        )

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [window]], holders: ["com.google.Chrome.helper"],
            pin: pin, limits: limits(), services: MeetingPageReader.unconfirmedServices
        )

        XCTAssertTrue(snapshot.found)
        XCTAssertFalse(snapshot.visible)
        XCTAssertEqual(snapshot.people, [])
    }

    /// The program row, through the holder path: `com.microsoft.teams2.
    /// modulehost` (the process that actually holds the microphone,
    /// TypeWhisper issue #1583) resolves to `com.microsoft.teams2` through
    /// `programHelpers`, and the same tiles as the browser row are read from
    /// the program's own window.
    func testTeamsApp_modulehostHolder_readsProgramRow() {
        let tiles: [AccessibilityPageNode] = [
            TeamsShape.tile(name: "Анна Тестова", status: "Muted"),
            TeamsShape.tile(name: "Борис Пример", status: "Unmuted"),
            TeamsShape.tile(name: "Гость Три", status: "Muted"),
        ]
        let area = TeamsShape.page(
            url: "https://teams.microsoft.com/v2/", children: tiles + [TeamsShape.roster(selfName: "Анна Тестова")]
        )
        let window = FakeNode(role: "AXWindow", children: [area])

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.microsoft.teams2": [window]], holders: ["com.microsoft.teams2.modulehost"],
            pin: nil, limits: limits(), services: MeetingPageReader.unconfirmedServices
        )

        XCTAssertTrue(snapshot.visible)
        XCTAssertEqual(snapshot.service, "teams-app")
        XCTAssertEqual(snapshot.app, "com.microsoft.teams2")
        XCTAssertEqual(snapshot.selfName, "Анна Тестова")
        XCTAssertEqual(snapshot.people, ["Борис Пример", "Гость Три"])
    }

    /// Chrome holds the microphone, not the program: the program's own
    /// window must never even be opened, however many plausible-looking
    /// tiles it carries — "НеДолженНайтись" ("must not be found") never
    /// reaches `people`.
    func testTeams_chromeHolder_programWindowNeverOpened() {
        let chromeArea = FakeNode(role: "AXWebArea", axURL: "https://teams.microsoft.com/v2/")
        let chromeWindow = FakeNode(role: "AXWindow", children: [chromeArea])
        let programArea = TeamsShape.page(
            url: "https://teams.microsoft.com/v2/",
            children: [TeamsShape.tile(name: "НеДолженНайтись", status: "Muted")]
        )
        let programWindow = CountingNode(FakeNode(role: "AXWindow", children: [programArea]))
        // The Chrome area carries no tile, so it is never confirmed on its
        // own (2): read with a pin.
        let pin = MeetingPageReader.Pin(
            service: "teams", app: "com.google.Chrome",
            meeting: .page(address: MeetingPageReader.meetingAddress(of: "https://teams.microsoft.com/v2/")!)
        )

        let snapshot = MeetingPageReader.snapshot(
            windows: ["com.google.Chrome": [chromeWindow], "com.microsoft.teams2": [programWindow]],
            holders: ["com.google.Chrome.helper"], pin: pin, limits: limits(),
            services: MeetingPageReader.unconfirmedServices
        )

        XCTAssertEqual(snapshot.service, "teams")
        XCTAssertEqual(snapshot.app, "com.google.Chrome")
        XCTAssertEqual(programWindow.accesses, 0, "the program's own window must never be opened")
    }

    /// Closing in on a meeting requires matching both the row's own id and
    /// its program (`targets`, as Bitrix24's own two rows already do): a pin
    /// naming `teams-app`'s program but `teams`'s id matches nothing, even
    /// though a window and an area are right there to be read.
    func testTeamsApp_pinnedByIDAndProgram() {
        let area = TeamsShape.page(
            url: "https://teams.microsoft.com/v2/", children: [TeamsShape.tile(name: "Гость Три", status: "Muted")]
        )
        let window = FakeNode(role: "AXWindow", children: [area])

        let positivePin = MeetingPageReader.Pin(
            service: "teams-app", app: "com.microsoft.teams2", meeting: .page(address: "https://teams.microsoft.com/v2/")
        )
        let positiveSnapshot = MeetingPageReader.snapshot(
            windows: ["com.microsoft.teams2": [window]], holders: [], pin: positivePin, limits: limits(),
            services: MeetingPageReader.unconfirmedServices
        )
        XCTAssertTrue(positiveSnapshot.found)
        XCTAssertEqual(positiveSnapshot.service, "teams-app")
        XCTAssertEqual(positiveSnapshot.people, ["Гость Три"])

        let negativePin = MeetingPageReader.Pin(service: "teams", app: "com.microsoft.teams2", meeting: nil)
        let negativeSnapshot = MeetingPageReader.snapshot(
            windows: ["com.microsoft.teams2": [window]], holders: [], pin: negativePin, limits: limits(),
            services: MeetingPageReader.unconfirmedServices
        )
        XCTAssertEqual(negativeSnapshot, .notFound)
    }

    /// A tile caption with no trailing status at all does not parse: Teams'
    /// guessed shape always requires exactly one of "Muted"/"Unmuted"
    /// (`statusCount: 1`), unlike a service with no mandatory status.
    func testTeamsCaptionRules_plainNameWithoutAnyTailDoesNotParse() {
        let parsed = MeetingPageReader.parseCaptionDescription("Анна Тестова", rules: MeetingPageReader.teamsCaptionRules)
        XCTAssertNil(parsed)
    }

    /// Either mandatory status strips to leave just the name — "Muted" and
    /// "Unmuted" are each one of the `statusCount: 1` statuses, not an
    /// optional tail.
    func testTeamsCaptionRules_mutedOrUnmutedStrippedAsTheOneMandatoryStatus() {
        let muted = MeetingPageReader.parseCaptionDescription(
            "Борис Пример, Muted", rules: MeetingPageReader.teamsCaptionRules
        )
        XCTAssertEqual(muted?.name, "Борис Пример")
        let unmuted = MeetingPageReader.parseCaptionDescription(
            "Борис Пример, Unmuted", rules: MeetingPageReader.teamsCaptionRules
        )
        XCTAssertEqual(unmuted?.name, "Борис Пример")
    }

    /// The program's two held processes — `Microsoft Teams WebView.app`
    /// (`com.microsoft.teams2.helper`, Cisco Talos TALOS-2024-1990) and the
    /// one that actually holds the microphone during a call
    /// (`com.microsoft.teams2.modulehost`, TypeWhisper issue #1583) — both
    /// map to the program itself, the same rule a Chromium browser's own
    /// helper follows — through `programHelpers`, since `teams-app` is never
    /// in `services` for `programHelperMainApp` to find on its own; an
    /// unrelated suffix, the program itself and classic Teams
    /// (`com.microsoft.teams`, unsupported) are unaffected.
    func testHolderMapping_teamsProcessesToTheProgram() {
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams2.helper"), "com.microsoft.teams2")
        XCTAssertEqual(
            MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams2.helper.renderer"), "com.microsoft.teams2"
        )
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams2.modulehost"), "com.microsoft.teams2")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams2"), "com.microsoft.teams2")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams2X"), "com.microsoft.teams2X")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams2.other"), "com.microsoft.teams2.other")
        XCTAssertEqual(MeetingPageReader.mainApp(ofHolder: "com.microsoft.teams"), "com.microsoft.teams")
    }

    /// No highlight lead is set for either Teams row: the echo-removal lead
    /// Jitsi and Zoom get does not apply here, by omission from the table.
    func testHighlightLeads_noLeadForTeamsRows() {
        XCTAssertNil(CallFeed.highlightLeads["teams"])
        XCTAssertNil(CallFeed.highlightLeads["teams-app"])
    }

    /// `CaptionRules.descendsIntoUnparsedTiles`, a generic mechanism (not
    /// Teams-specific): with the default (`false`, every row in `services`
    /// today), a tile-role node whose own description does not parse is
    /// simply skipped, its children never read as tiles of their own. Set
    /// `true` on the very same tree, the nested, parseable tile is found.
    func testCaptionRules_descendsIntoUnparsedTilesWhenSet() {
        let nested = FakeNode(role: "AXTabGroup", description: "Гость Три, Computer audio unmuted, Video off")
        let outer = FakeNode(role: "AXTabGroup", description: "неразборчивый текст", children: [nested])
        let window = ZoomShape.window(children: [outer])

        let defaultSnapshot = readZoom([window], limits: limits())
        XCTAssertEqual(defaultSnapshot.people, [], "the default must still skip an unparsed tile's children")

        var descendingRules = ZoomShape.rules()
        descendingRules.descendsIntoUnparsedTiles = true
        let descendingService = MeetingPageReader.Service(
            id: "zoom-test", place: .app(bundleID: "us.zoom.xos.test", windowIdentifier: ZoomShape.windowIdentifier),
            classMatch: .exact, gridClass: "", tileClasses: [], tileDevicesClass: "", tileDisplayClass: "",
            selfClass: "", nameClass: "", speakingClass: "", captionRules: descendingRules
        )
        let descendingSnapshot = readZoom([window], limits: limits(), service: descendingService)
        XCTAssertEqual(descendingSnapshot.people, ["Гость Три"])
    }
}
