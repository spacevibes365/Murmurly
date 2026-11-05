import AppKit
import ApplicationServices
import Darwin
import Foundation

/// A node of a browser's (or, later, a native app's) accessibility tree,
/// trimmed to what the meeting page reader needs. The live tree (`AXPageNode`,
/// in `AccessibilityAuthorization.swift`) and the synthetic trees in tests
/// both conform to this, so the traversal below never touches `AXUIElement`
/// directly and runs the same way in a test process as it will on a real
/// page.
protocol AccessibilityPageNode: Sendable {
    var role: String { get }
    /// `AXURL`, meaningful only on an `AXWebArea`.
    var axURL: String? { get }
    /// `AXDOMClassList`, the page's own CSS classes on this element.
    var domClassList: [String] { get }
    var title: String? { get }
    var value: String? { get }
    var description: String? { get }
    var children: [AccessibilityPageNode] { get }
    /// `AXIdentifier`, read only for a `Service.Place.app` row's own call
    /// window; a browser page never sets it, and only a row whose program
    /// currently holds the microphone is ever asked for it.
    var identifier: String? { get }
    /// `AXDOMIdentifier`, the page's own DOM id on this element — read only
    /// for a row whose `selfTileIdentifier` is set (Jitsi's own tile has no
    /// class of its own, only this id).
    var domIdentifier: String? { get }
    /// Address of the node's own AX object (0: none) — a `Sendable`
    /// stand-in for the object, turned back into it at once while the node
    /// is alive (`WindowElement`). `AccessibilityPageNode` is itself
    /// `Sendable`, so no requirement on it may carry a non-`Sendable` type
    /// such as `AnyObject`/`AXUIElement` — this number is the witness that
    /// makes `.app` window identity (1c) comparable without one. Read only
    /// for a top-level `.app` window, the one place a candidate's identity
    /// needs more than its title.
    var axElementAddress: UInt { get }
}

extension AccessibilityPageNode {
    var identifier: String? { nil }
    var domIdentifier: String? { nil }
    var axElementAddress: UInt { 0 }
}

/// `element` is internal to `AXPageNode` (`AccessibilityAuthorization.swift`)
/// and visible here within the same module — no need to touch that file for
/// one more computed property.
extension AXPageNode {
    var axElementAddress: UInt { UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque()) }
}

/// What a meeting's web page said, read once. `found` is the only field kept
/// when the read breaks off after the meeting's own area was already located
/// (see `Limits`): a half-read grid must never report a name or a speaker
/// that might belong to someone else's tile.
struct MeetingPageSnapshot: Equatable {
    var found = false
    var visible = false
    var selfName = ""
    var selfSpeaking = false
    var people: [String] = []
    var speaking: [String] = []
    /// The id of the `MeetingPageReader.Service` row that was found —
    /// `.call.murmurly.jsonl`'s own `service` field (`CallFeed.Event.service`).
    var service = ""
    /// The main app whose window was read (after `mainApp(ofHolder:)`),
    /// e.g. `com.google.Chrome` for a Telemost tab found there.
    var app = ""
    /// The meeting itself, not merely the service and app: the page's own
    /// address or the native call window's identity. `nil` only for
    /// `.notFound` and for a snapshot built directly by a test that doesn't
    /// exercise this field.
    var meeting: MeetingPageReader.Meeting?
    /// Whether the user's own tile was seen on the page, for
    /// `CallFeed.Event.selfVisible`: `handleTile`'s `isSelf` branch and
    /// `applyCaptionTiles`' own-name branch are the only two places that set
    /// it. A caption-only reader with no self detection at all (web Zoom)
    /// leaves it `false`, which keeps the single-other naming rule from
    /// firing for it — there is no own tile here to confirm the pair.
    var selfVisible = false

    static let notFound = MeetingPageSnapshot()
}

/// Reads the participants and the speaking highlight off a meeting's own
/// page — the same thing a sighted user sees on their screen, nothing from
/// the chat, no other tab, no video, no screen content — from one row of
/// `services` at a time, and only in the app that is currently holding the
/// microphone: a row whose program isn't a holder is never even tried, so it
/// can neither spend the shared budget nor have its tab picked up by
/// mistake. Never writes an attribute or sends an action, so the browser's
/// windows are never changed by reading them.
enum MeetingPageReader {
    /// Bounds on one call to `snapshot`/`readLive`, so a browser tab that
    /// never settles (or doesn't answer) cannot hold the caller: node count,
    /// tree depth and wall-clock deadline, checked before every node is
    /// visited, never by sleeping.
    struct Limits {
        var maxNodes: Int
        var maxDepth: Int
        var deadline: Date

        static func standard(now: Date = Date()) -> Limits {
            Limits(maxNodes: 5000, maxDepth: 40, deadline: now.addingTimeInterval(5))
        }
    }

    // MARK: - The services table

    /// How class names are compared against a service's rules: a fixed
    /// prefix followed by a per-session hash (Telemost), or the exact class
    /// name (Jitsi Meet's own classes; Bitrix24's `bx-messenger-videocall-user`
    /// and friends).
    enum ClassMatch: Sendable {
        case prefix
        case exact
    }

    /// One address rule: a host (the domain itself, or any subdomain of it —
    /// never a host that merely contains it as a substring) and the start of
    /// the path. Query, fragment and user info are never looked at: a search
    /// engine's own address with a meeting's host inside the query, or
    /// another site with the meeting's domain inside its own path, must
    /// never match.
    struct Address: Sendable, Equatable {
        /// Lower-case, without a leading dot.
        var domains: [String]
        /// `"/"` matches any page of the host, root included even when the
        /// root itself carries no trailing slash (`https://host` and
        /// `https://host/` are the same page).
        var pathPrefix: String

        func matches(_ components: URLComponents) -> Bool {
            guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return false
            }
            guard let host = components.host?.lowercased(), !host.isEmpty else { return false }
            guard domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            return path.hasPrefix(pathPrefix)
        }
    }

    /// Where a service's meeting page lives.
    enum Place: Sendable {
        /// A tab in one of `browserBundleIDs`. `meetingAreas` mark the
        /// meeting's own page outright — any one of them matching is enough
        /// (a service with several public servers, e.g. Jitsi: `meet.jit.si`,
        /// `8x8.vc`, `meet.ffmuc.net`). `shells`, when not empty, mark an
        /// outer shell worth descending into to look for a nested meeting
        /// area — never a meeting area by themselves. An empty list never
        /// matches any address, so an unset one simply never fires.
        case browser(meetingAreas: [Address], shells: [Address] = [])
        /// A native app's own window, found by `AXIdentifier`
        /// (`windowIdentifier`); not used by any row today.
        case app(bundleID: String, windowIdentifier: String)
        /// A native app's own window with a page embedded in it (a bundled
        /// Chromium or a `WKWebView`) — anywhere inside the app's windows,
        /// the first `AXWebArea` whose `AXURL` matches one of `meetingAreas`
        /// is treated exactly like a `.browser` row's meeting area: the same
        /// `classMatch`/grid/tile rules run against its subtree. An empty
        /// `meetingAreas` accepts any `AXWebArea` at all, for an app whose
        /// embedded page never leaves the call (Bitrix24 for macOS today; a
        /// program that wraps its whole call UI in one embedded page, rather
        /// than exposing it through native accessibility, is expected to use
        /// this place too — Microsoft Teams and the Telemost desktop app
        /// among them).
        case appWeb(bundleID: String, meetingAreas: [Address])
    }

    /// One call service's rules: everything `MeetingPageReader`'s traversal
    /// needs to find its meeting area, its participants grid and each
    /// tile's details. A later service is one more row here, not a new type.
    struct Service: Sendable {
        var id: String
        var place: Place
        var classMatch: ClassMatch
        /// The participants grid's own class (an anchor to descend from).
        var gridClass: String
        /// A tile's own class(es); a tile also needs `tileDevicesClass`.
        var tileClasses: [String]
        /// The class every real (non-screen-share) tile carries alongside
        /// one of `tileClasses`.
        var tileDevicesClass: String
        /// The class a screen-share tile carries instead of `tileDevicesClass`.
        var tileDisplayClass: String
        var selfClass: String
        /// The own tile's DOM id (`AXDOMIdentifier`), for a service whose own
        /// tile carries no class of its own (Jitsi's `localVideoContainer`).
        /// `nil` for every row above (Telemost): `domIdentifier` is then
        /// never asked for, since `searchTileDetails`'s `if let` checks it
        /// only when this is set.
        var selfTileIdentifier: String? = nil
        var nameClass: String
        var speakingClass: String
        /// A second, parallel way to read a tile: by the text a screen reader
        /// would read off it, for a program that exposes no page classes at
        /// all (a native app's own window, not a browser tab). `nil` for
        /// every row above; set, it replaces `gridClass`/`tileClasses`/… for
        /// that row entirely. Appended last, with a default, so the three
        /// calls above (all class-based) are unaffected.
        var captionRules: CaptionRules? = nil
        /// A tile's name may live in a text child of the `nameClass` element
        /// rather than on the element itself (Zoom's web client: a bare
        /// `span` inside `video-avatar__avatar-footer`; Telemost's web and
        /// app rows: a bare `AXStaticText` inside `TextName_…`); the first
        /// `AXStaticText` below it with text is taken when the element
        /// itself has none. `true` by default, so a new row gets this
        /// fallback for free; a row for which it would risk reading an
        /// unrelated label as the name sets it `false` explicitly (Google
        /// Meet's `meet` row, below).
        var nameFromStaticText = true
        /// More classes that also count as `nameClass`, any one of them
        /// matching — for a service whose class names are unstable and were
        /// only ever observed on third-party projects (Google Meet), so
        /// several independently-observed candidates are tried rather than
        /// trusting one. Empty for every row above.
        var alternateNameClasses: [String] = []
        /// More classes that also count as `speakingClass`, same reasoning.
        /// Empty for every row above.
        var alternateSpeakingClasses: [String] = []
        /// A class that, anywhere in the tile, means the tile is not
        /// speaking even if some other node of the same tile carries
        /// `speakingClass` or one of `alternateSpeakingClasses` — a few
        /// third-party projects mark their speaking indicator's resting
        /// state with a class of its own, on an element of its own, rather
        /// than simply omitting the active one from the same node. Found
        /// anywhere in the tile's subtree, it clears `speaking` for the whole
        /// tile (the name is kept regardless). Empty for every row above.
        var silenceClass: String = ""
        /// Query parameters that are part of this service's own meeting
        /// identity, by name (matched case-insensitively), in no particular
        /// order — for a service whose room lives in the query string
        /// rather than the path (Bitrix24: `IM_DIALOG` for its messenger
        /// chat, `videoconf` for a scheduled call's own link; not checked
        /// against a live portal, so a missing key here reads two different
        /// rooms as one meeting, and an extra one is harmless). Empty for
        /// every other row: the room is already in the path there, and
        /// `meetingAddress(of:queryKeys:)` ignores the query entirely, same
        /// as before this field existed. Appended last, with a default.
        var meetingQueryKeys: [String] = []
    }

    /// Rules for reading a tile from its accessibility description alone —
    /// the same text a screen reader announces — rather than from DOM
    /// classes a native app simply does not expose. `Sendable` like every
    /// other rule type here, so `Service` stays `Sendable` too.
    struct CaptionRules: Sendable {
        /// The accessibility role every participant tile carries (observed
        /// on Zoom: `"AXTabGroup"`).
        var tileRole: String
        /// Every status phrase that can trail a name, in no particular
        /// order; checked against the end of what is left after the
        /// speaking marker (if any) is removed, up to `statusCount` times.
        var statuses: [String]
        /// How many status phrases a tile's description always carries, so
        /// a comma inside the name itself is never mistaken for one more
        /// status to strip: exactly `statusCount` known statuses must be
        /// found at the end, or the whole description is an unknown shape
        /// and the tile is skipped — better no name than a wrong one.
        var statusCount: Int
        /// Phrases marking the active speaker, one per language the
        /// program might be running in (Zoom follows the system locale).
        var speakingMarkers: [String]
        /// The accessibility role of the participants list itself (observed
        /// on Zoom: `"AXOutline"`). Only a node inside this role's own
        /// subtree is ever checked for the self suffix: a button, a chat
        /// line or any other node elsewhere in the window must never supply
        /// the local user's name, however it happens to read.
        var listRole: String
        /// The suffix the local user's own row in the participants list
        /// ends with, e.g. `" (me)"`. Read only from a node inside
        /// `listRole`'s subtree — checking its title, value and
        /// description, never a tile's own description.
        var selfSuffix: String
        /// More suffixes meaning the same thing in another language (Zoom's
        /// own `" (я)"` next to `" (me)"`), checked the same way as
        /// `selfSuffix`. Appended last, with a default, so every existing
        /// caller that names only `selfSuffix` is unaffected.
        var additionalSelfSuffixes: [String] = []
        /// Status phrases that may or may not trail a name, stripped before
        /// the exactly-`statusCount` mandatory ones are looked for (Zoom's
        /// own "Hand raised" / "Screen sharing", in either language): a
        /// tile that never shows them must parse exactly as one that always
        /// would. Appended last, with a default, so every row above
        /// (Telemost, Jitsi) is unaffected.
        var optionalStatuses: [String] = []

        /// Whether a node matching `tileRole` whose own description does not
        /// parse as a known caption shape is still descended into, looking
        /// for a nested tile, rather than treated as not a person at all
        /// (and its children left unread either way). `false` for every row
        /// above (Zoom): an unparsed tile there is simply not a person.
        /// Appended last, with a default, so every existing row is
        /// unaffected.
        var descendsIntoUnparsedTiles = false

        /// `selfSuffix` followed by `additionalSelfSuffixes`, in that order:
        /// the one list `collectCaptionTiles` actually checks.
        var selfSuffixes: [String] { [selfSuffix] + additionalSelfSuffixes }
    }

    // MARK: - Rows (Telemost's browser tab first, its own behavior
    // unchanged; Jitsi next; then Bitrix24 and Zoom — each a browser tab and
    // its macOS program sharing one id — Google Meet, then Telemost's own
    // macOS app, with an id of its own)

    /// Bitrix24 cloud zones known to us — not proven complete, and a portal
    /// on a zone missing here is not read; a boxed (self-hosted) portal never
    /// was, on this list or off it.
    static let bitrix24CloudDomains: [String] = [
        "bitrix24.ru", "bitrix24.by", "bitrix24.kz", "bitrix24.ua", "bitrix24.com",
        "bitrix24.de", "bitrix24.eu", "bitrix24.es", "bitrix24.fr", "bitrix24.it",
        "bitrix24.pl", "bitrix24.uk", "bitrix24.com.br", "bitrix24.com.tr",
        "bitrix24.in", "bitrix24.cn", "bitrix24.jp", "bitrix24.vn", "bitrix24.id",
    ]

    static let services: [Service] = [
        Service(
            id: "telemost",
            place: .browser(
                meetingAreas: [Address(domains: ["telemost.yandex.ru"], pathPrefix: "/private-join/")],
                shells: [Address(domains: ["telemost.yandex.ru"], pathPrefix: "/j/")]
            ),
            classMatch: .prefix,
            gridClass: "GoloomParticipantsRenderer",
            tileClasses: ["item_", "newGridItem_"],
            tileDevicesClass: "itemDevices_",
            tileDisplayClass: "itemDisplay_",
            selfClass: "selfView_",
            nameClass: "TextName_",
            speakingClass: "rootStroke_"
        ),
        Service(
            id: "jitsi",
            place: .browser(
                meetingAreas: [Address(domains: ["meet.jit.si", "8x8.vc", "meet.ffmuc.net"], pathPrefix: "/")]
            ),
            classMatch: .exact,
            gridClass: "",
            tileClasses: ["videocontainer"],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            selfTileIdentifier: "localVideoContainer",
            nameClass: "displayname",
            speakingClass: "dominant-speaker"
        ),
        // Bitrix24's own call UI (`modules/call/install/js/call/core/src/view/call-user.js`,
        // bitrix24-core-corp, version 25.750.0): a tile is
        // `div.bx-messenger-videocall-user` (the own tile adds
        // `bx-messenger-videocall-user-self`), its name
        // `span.bx-messenger-videocall-user-name`, and the active-speaker
        // highlight `bx-messenger-videocall-user-talking` on the tile's own
        // root — all exact class names, never a per-session hash. No grid
        // wrapper and no separate "has devices" class of their own: the tile
        // classes alone decide. A screen-share tile carries the very same
        // class as a person's; this card cannot tell the two apart by class
        // alone and reads it as a (silent) participant rather than hide a
        // real one — a known risk, not a defect, for the owner's live check.
        Service(
            id: "bitrix24",
            place: .browser(
                // Cloud portals only (`bitrix24CloudDomains`, above): the
                // call opens both as its own `/video/<code>` page and over
                // the portal's messenger, same tab either way, so any page of
                // the portal (`pathPrefix: "/"`) covers both. A boxed
                // (on-premises) portal's own domain is not covered — the
                // owner's live check decides.
                meetingAreas: [Address(domains: bitrix24CloudDomains, pathPrefix: "/")]
            ),
            classMatch: .exact,
            gridClass: "",
            tileClasses: ["bx-messenger-videocall-user"],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "bx-messenger-videocall-user-self",
            nameClass: "bx-messenger-videocall-user-name",
            speakingClass: "bx-messenger-videocall-user-talking",
            // Not checked against a live portal (owner's live check):
            // `IM_DIALOG` keys the messenger's own chat, `videoconf` a
            // scheduled call's own link; a missing key here reads two
            // different rooms as one meeting.
            meetingQueryKeys: ["IM_DIALOG", "videoconf"]
        ),
        // Bitrix24 for macOS (`com.bitrixsoft.bitrix24desktop`): the same
        // call UI, embedded in the program's own window. Same id as the
        // browser row above — the browser tab and the program are one
        // service for name lookup and any future highlight lead — found
        // through `.appWeb` instead of `.browser`, same class rules.
        Service(
            id: "bitrix24",
            place: .appWeb(bundleID: "com.bitrixsoft.bitrix24desktop", meetingAreas: []),
            classMatch: .exact,
            gridClass: "",
            tileClasses: ["bx-messenger-videocall-user"],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "bx-messenger-videocall-user-self",
            nameClass: "bx-messenger-videocall-user-name",
            speakingClass: "bx-messenger-videocall-user-talking",
            meetingQueryKeys: ["IM_DIALOG", "videoconf"]
        ),
        // Zoom: the program's own window, read by caption (no page classes
        // of its own to anchor on), and its web client's Speaker-view tab,
        // read by class — two rows sharing one `id`, the feed's own key, so
        // either is reported as "zoom" (see `targets`'s fix above).
        Service(
            id: "zoom",
            place: .app(bundleID: "us.zoom.xos", windowIdentifier: "zm.meeting.window.main"),
            classMatch: .exact,
            gridClass: "",
            tileClasses: [],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            nameClass: "",
            speakingClass: "",
            // These English phrases are the fallback; every other language
            // Zoom itself ships is added at runtime from the installed
            // program's own bundle, see `addingInstalledZoomCaptions` below.
            captionRules: CaptionRules(
                tileRole: "AXTabGroup",
                statuses: [
                    "Computer audio unmuted", "Computer audio muted",
                    "Telephone unmuted", "Telephone muted", "No audio connected",
                    "Video on", "Video off", "No video connected",
                ],
                statusCount: 2,
                speakingMarkers: ["active speaker"],
                listRole: "AXOutline",
                selfSuffix: " (me)",
                optionalStatuses: ["Hand raised", "Screen sharing"]
            )
        ),
        // Zoom's web client, Speaker view only (Vexa's `zoom-speakers.ts`):
        // one large tile, its class starting `single-` and containing
        // `-container__video-frame`; only the two class names Vexa observed
        // are matched exactly, pending the owner's own check of the live
        // page (see the card's report for a prefix+contains rule if Zoom
        // uses a third). No self detection and no grid: Speaker view's
        // `people` is always the one other person on the big tile, but
        // which tile Zoom pins there can be a deliberately pinned video
        // rather than whoever is actually speaking — this row never claims
        // `speaking` for it. The tile's name lives in a text
        // child of its footer, not the footer element itself
        // (`nameFromStaticText`, `true` by default).
        Service(
            id: "zoom",
            place: .browser(meetingAreas: [Address(domains: ["zoom.us"], pathPrefix: "/wc/")]),
            classMatch: .exact,
            gridClass: "",
            tileClasses: ["single-main-container__video-frame", "single-suspension-container__video-frame"],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            nameClass: "video-avatar__avatar-footer",
            speakingClass: ""
        ),
        // Google Meet's own classes are not published and change without
        // notice; every class below is a candidate observed on third-party
        // open-source projects that read the same page (Granola, Vexa,
        // Whadio), not a stable contract — the least reliable row in this
        // table, to be checked against a real call before it is trusted
        // (card "Google Meet", 2026-10-30).
        Service(
            id: "meet",
            place: .browser(
                meetingAreas: [Address(domains: ["meet.google.com"], pathPrefix: "/")]
            ),
            classMatch: .exact,
            gridClass: "",
            tileClasses: ["dkjMxf"],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "aGWPv",
            nameClass: "notranslate",
            speakingClass: "kssMZb",
            // `notranslate` is also the class Meet's Material Icons carry
            // (their text is the icon's own name, e.g. `mic_off`, in a child
            // `AXStaticText`), and this row is not yet checked against a
            // live call: the static-text fallback stays off here until the
            // owner's live check of Google Meet confirms it would find the
            // name and not an icon's text.
            nameFromStaticText: false,
            alternateNameClasses: ["zWGUib", "XWGOtd"],
            alternateSpeakingClasses: ["Oaajhc", "HX2H7", "wEsLMd", "OgVli"],
            silenceClass: "gjg47c"
        ),
        // The Yandex Telemost desktop app (`ru.yandex.desktop.telemost`, the
        // same vendor prefix as `ru.yandex.desktop.yandex-browser` above; its
        // audio-input helper is `ru.yandex.desktop.telemost.helper…`, mapped
        // back to this bundle ID by `programHelperMainApp`). A separate id
        // from the browser tab's `telemost` (every row above keeps its own
        // id, so no shared highlight lead and no shared matching with the
        // tab, per this card's own rule): the real app has not been seen
        // live on a call, only reasoned from the tab's own page, so a wrong
        // guess here must never silently also affect the tab. `meetingAreas`
        // is deliberately not empty, unlike Bitrix24's `.appWeb` row above:
        // Telemost also has a chats/contacts screen with its own
        // `AXWebArea`, and an empty list (any web area at all) would read
        // that screen as a call and pin the recording to it. Both of the
        // tab's own meeting-area path prefixes are matched directly, since
        // `.appWeb` has no shell-descent of its own to find a nested
        // `/private-join/` page inside an outer `/j/` one. `telemost.yandex.com`
        // is added alongside `.ru` on this row only — the cask's own home
        // page is on `.com`, so a call opened straight from it must also
        // match; the browser tab row above keeps `.ru` only, not a byte
        // changed. Same class rules
        // as the `telemost` row: if the 3.x app does not embed this exact
        // web page (a Qt UI instead, say), every read here simply finds no
        // matching `AXWebArea` and reports nothing — safe, not a guess from
        // an unrelated window — which is what the owner's live check is for.
        Service(
            id: "telemost-app",
            place: .appWeb(
                bundleID: "ru.yandex.desktop.telemost",
                meetingAreas: [
                    Address(domains: ["telemost.yandex.ru", "telemost.yandex.com"], pathPrefix: "/private-join/"),
                    Address(domains: ["telemost.yandex.ru", "telemost.yandex.com"], pathPrefix: "/j/"),
                ]
            ),
            classMatch: .prefix,
            gridClass: "GoloomParticipantsRenderer",
            tileClasses: ["item_", "newGridItem_"],
            tileDevicesClass: "itemDevices_",
            tileDisplayClass: "itemDisplay_",
            selfClass: "selfView_",
            nameClass: "TextName_",
            speakingClass: "rootStroke_"
        ),
    ]

    /// Microsoft Teams' own hosts for the web client: `teams.microsoft.com`,
    /// `teams.live.com` (the consumer client) and `teams.cloud.microsoft` (a
    /// newer tenant domain). A tenant-branded subdomain of the first
    /// (`contoso.teams.microsoft.com`) matches through `Address`'s own
    /// subdomain rule.
    static let teamsDomains: [String] = [
        "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
    ]

    /// Microsoft Teams — browser and the macOS program
    /// (`com.microsoft.teams2`). No rule here is proven through macOS
    /// accessibility, unlike Bitrix24 or Zoom above: open bots (Vexa's
    /// `msteams-speakers.ts`, 2026-08) key off `data-tid`
    /// (`[data-tid="voice-level-stream-outline"]`, a CSS-only indicator
    /// toggling opacity), and `data-*` attributes never reach
    /// `AXDOMClassList`/`AXDOMIdentifier`; Granola reads Teams by
    /// accessibility too, but through closed code. Teams' own
    /// screen-reader documentation says there is in fact no accessible way
    /// to learn who is currently speaking at all ("Teams Needs a Shortcut
    /// to Announce the Active Speaker", teamsaccessibility.com, checked
    /// 2026-10-31) — hence `speakingMarkers` below is empty, unlike Zoom's
    /// row. `tileRole` is guessed as `"AXGroup"` (a plain `div[role=group]`
    /// tile, not Zoom's `"AXTabGroup"`), which is also the role of countless
    /// other nodes on the page — so `descendsIntoUnparsedTiles` is `true`
    /// here: a group whose own description does not parse as "Name,
    /// Muted"/"Name, Unmuted" (`statusCount: 1`) is not treated as a person
    /// at all, and the walk continues into its children looking for an
    /// actual tile, rather than stopping at the first outer group on the
    /// page the way Zoom's row deliberately does. `selfSuffix` is a guess
    /// from Teams' own roster wording ("(You)" next to a participant's own
    /// name); `listRole` mirrors Zoom's own tree-view role, the shape used
    /// by every program this reader has read by caption so far — not a
    /// Teams-specific finding. This is the best available guess, by caption
    /// as Zoom's row is, and both rows below are held back in
    /// `unconfirmedServices`, never `services`, until the owner's own
    /// window snapshot confirms or corrects it.
    static let teamsCaptionRules = CaptionRules(
        tileRole: "AXGroup",
        statuses: ["Muted", "Unmuted"],
        statusCount: 1,
        speakingMarkers: [],
        listRole: "AXOutline",
        selfSuffix: " (You)",
        descendsIntoUnparsedTiles: true
    )

    /// Rows held back from `services` for lack of any accessibility-proven
    /// signal (see `teamsCaptionRules`'s own doc comment): `readLive` only
    /// ever consults `services`, so neither row here is read on a live call
    /// — they exist for this card's own tests and for the card that follows
    /// to move into `services` once the owner's live check confirms the
    /// shape. `teams` (the browser tab) and `teams-app` (the macOS program)
    /// are two rows, not duplicates: a browser tab and the native program
    /// never share one id-less identity the way Bitrix24's two rows share
    /// `"bitrix24"`, since nothing here is confirmed enough yet to treat
    /// them as the one service a highlight lead or a report could name
    /// together.
    static let unconfirmedServices: [Service] = [
        Service(
            id: "teams",
            place: .browser(meetingAreas: [Address(domains: teamsDomains, pathPrefix: "/")]),
            classMatch: .exact,
            gridClass: "",
            tileClasses: [],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            nameClass: "",
            speakingClass: "",
            captionRules: teamsCaptionRules
        ),
        // The macOS program: not Electron, its call UI lives in a separate
        // helper program built on Chromium (`Microsoft Teams WebView.app`),
        // so `.appWeb` reads that helper's embedded page. An empty
        // `meetingAreas` would accept any `AXWebArea` the program shows at
        // all, chat included — so this row reuses `teamsDomains`, same as
        // the browser row, on the guess that the embedded page's own
        // address stays on one of Teams' own hosts even inside the program;
        // unconfirmed, like the rest of this row. Whether the window with
        // that `AXWebArea` actually belongs to `com.microsoft.teams2` itself
        // or to the helper's own bundle ID is for the owner's live check
        // (see the card's report); this row assumes the former, as
        // `collectWindows` only ever opens the windows of the bundle ID
        // actually holding the microphone.
        Service(
            id: "teams-app",
            place: .appWeb(
                bundleID: "com.microsoft.teams2",
                meetingAreas: [Address(domains: teamsDomains, pathPrefix: "/")]
            ),
            classMatch: .exact,
            gridClass: "",
            tileClasses: [],
            tileDevicesClass: "",
            tileDisplayClass: "",
            selfClass: "",
            nameClass: "",
            speakingClass: "",
            captionRules: teamsCaptionRules
        ),
    ]

    /// Zoom's own program bundle identifier, read from the `zoom` row's
    /// `.app` place by `addingInstalledZoomCaptions` to find the matching
    /// row without duplicating it here.
    private static let zoomBundleID = "us.zoom.xos"

    /// Zoom's own localization keys (observed in its 7.1.9 bundle, every
    /// one of its 17 `.lproj` folders) for the phrases `CaptionRules` reads
    /// off a tile's accessibility description, in `statuses`' order.
    private static let zoomStatusKeys = [
        "LN_Plist_Accessibility_VoIP_Unmuted_20044",
        "LN_Plist_Accessibility_VoIP_Muted_20044",
        "LN_Plist_Accessibility_Tele_Unmuted_20044",
        "LN_Plist_Accessibility_Tele_Muted_20044",
        "LN_Plist_Accessibility_No_Audio_20044",
        "LN_Plist_Accessibility_Video_On_20044",
        "LN_Plist_Accessibility_Video_Off_20044",
        "LN_Plist_Accessibility_No_Video_20044",
    ]
    private static let zoomOptionalStatusKeys = [
        "LN_Plist_Accessibility_HandRaised_20044",
        "LN_Plist_Accessibility_Share_Screen_41522",
    ]
    private static let zoomSpeakingMarkerKeys = ["LN_Studio_Active_Speaker_391545"]
    /// The key behind Zoom's own self suffix, e.g. `"%@ (me)"`; the format
    /// string's own leading `"%@"` is stripped to get the suffix itself.
    private static let zoomSelfFormatKey = "LN-183814_%@ (me)"

    /// Bounds on reading Zoom's own installed bundle
    /// (`addingInstalledZoomCaptions`): one program's `Localizable.strings`
    /// files, never anything larger that a hostile or merely huge bundle
    /// might otherwise make this read.
    struct ZoomResourceLimits: Sendable {
        var maxFileBytes: Int
        var maxTotalBytes: Int
        var maxLocalizations: Int
        /// The most entries `Contents/Resources` itself may list before any
        /// `.lproj` filter: past it, the whole read is skipped (the English
        /// literals stay as they are) rather than enumerate and filter a
        /// directory a hostile or corrupted bundle made huge. Defaulted so
        /// every existing three-argument call site keeps compiling unchanged.
        var maxResourceEntries: Int = 4096

        static let standard = ZoomResourceLimits(
            maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 64 * 1024 * 1024, maxLocalizations: 64
        )
    }

    /// Whether `url` is, by `lstat`, a real directory — never a symbolic
    /// link: a `/var` → `/private/var` link on the path leading to the
    /// `.app` itself is resolved once, up front
    /// (`resolvingSymlinksInPath()`), but nothing below `Contents/Resources`
    /// may be a link, including the language folders themselves.
    private static func isPlainDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Opens `url` with `O_NOFOLLOW` (a link is refused outright, never
    /// followed) and reads at most `maxFileBytes` of it, only while the
    /// running total stays within `maxTotalBytes`; `nil` for anything that
    /// doesn't look like an ordinary file within the limits, so the caller
    /// simply skips that one language rather than failing the whole read.
    ///
    /// A named pipe at this path would otherwise block `open` itself —
    /// forever, since nothing on the other end ever writes to it — and with
    /// it the whole read queue, in every service, until the app restarts. An
    /// `lstat` first refuses anything that is not already a plain file
    /// before `open` is even called, `O_NONBLOCK` keeps `open` itself from
    /// blocking if the path is swapped for a pipe in the gap between that
    /// check and the call, and the existing `fstat` after opening still
    /// catches that same swap once the descriptor exists. `O_NONBLOCK` makes
    /// no difference to an ordinary file's `read`.
    private static func readLimitedFile(
        _ url: URL, maxFileBytes: Int, maxTotalBytes: Int, totalBytes: inout Int
    ) -> Data? {
        var preOpenInfo = stat()
        guard lstat(url.path, &preOpenInfo) == 0, (preOpenInfo.st_mode & S_IFMT) == S_IFREG else { return nil }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size <= maxFileBytes, totalBytes + size <= maxTotalBytes else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: size) else { return nil }
        totalBytes += data.count
        return data
    }

    /// Every `services` row whose program is Zoom (`.app(bundleID:
    /// "us.zoom.xos", _)` with `captionRules`) gets the phrases of every
    /// language `appURL`'s bundle ships, appended after its own English
    /// ones; every other row, and every row when `appURL` is `nil` or
    /// nothing can be read, is returned unchanged. Reads files only, never
    /// writes anything, and only ordinary files and directories strictly
    /// below the (already-resolved) `.app` bundle itself — never through a
    /// symbolic link, and never past `limits` (5).
    static func addingInstalledZoomCaptions(
        appURL: URL?, to services: [Service], limits: ZoomResourceLimits = .standard
    ) -> [Service] {
        guard let appURL else { return services }
        let resolvedAppURL = appURL.resolvingSymlinksInPath()
        let contentsURL = resolvedAppURL.appendingPathComponent("Contents")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        guard isPlainDirectory(contentsURL), isPlainDirectory(resourcesURL) else { return services }
        guard let languageFolders = try? FileManager.default.contentsOfDirectory(
            at: resourcesURL, includingPropertiesForKeys: nil
        ), languageFolders.count <= limits.maxResourceEntries else { return services }
        let lprojFolders = languageFolders
            .filter { $0.pathExtension == "lproj" && isPlainDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(limits.maxLocalizations)
        guard !lprojFolders.isEmpty else { return services }

        func contains(_ list: [String], _ value: String) -> Bool {
            list.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        }

        var totalBytes = 0
        return services.map { row in
            guard case .app(let bundleID, _) = row.place, bundleID == zoomBundleID,
                  var rules = row.captionRules
            else { return row }

            for folder in lprojFolders {
                let stringsURL = folder.appendingPathComponent("Localizable.strings")
                guard let data = readLimitedFile(
                        stringsURL, maxFileBytes: limits.maxFileBytes, maxTotalBytes: limits.maxTotalBytes,
                        totalBytes: &totalBytes
                      ),
                      let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }

                func phrase(forKey key: String) -> String? {
                    guard let raw = table[key] as? String else { return nil }
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, !value.contains("%") else { return nil }
                    return value
                }

                // Checked against `rules`' own growing lists, never a
                // per-language scratch list: a language whose phrase is
                // identical (case aside) to the row's own English literal,
                // or to an earlier language already added, contributes
                // nothing new.
                for key in zoomStatusKeys {
                    if let value = phrase(forKey: key), !contains(rules.statuses, value) {
                        rules.statuses.append(value)
                    }
                }
                for key in zoomOptionalStatusKeys {
                    if let value = phrase(forKey: key), !contains(rules.optionalStatuses, value) {
                        rules.optionalStatuses.append(value)
                    }
                }
                for key in zoomSpeakingMarkerKeys {
                    if let value = phrase(forKey: key), !contains(rules.speakingMarkers, value) {
                        rules.speakingMarkers.append(value)
                    }
                }
                if let raw = table[zoomSelfFormatKey] as? String,
                   raw.hasPrefix("%@"), raw.components(separatedBy: "%@").count == 2 {
                    let suffix = String(raw.dropFirst(2))
                    if !suffix.isEmpty, !contains(rules.selfSuffixes, suffix) {
                        rules.additionalSelfSuffixes.append(suffix)
                    }
                }
            }

            var copy = row
            copy.captionRules = rules
            return copy
        }
    }

    static let browserBundleIDs: Set<String> = [
        "company.thebrowser.Browser",       // Arc
        "com.google.Chrome",
        "ru.yandex.desktop.yandex-browser", // Yandex Browser
        "com.microsoft.edgemac",            // Edge
        "com.brave.Browser",
        "com.apple.Safari",
    ]

    /// Chromium browsers hold audio input in a helper process, not the app
    /// whose windows show the call: `<app>.helper` and its `.helper.<kind>`
    /// variants. Keys lower-case (the real case of a Chromium helper, e.g.
    /// Arc's, is unverified); values are exactly the entries of
    /// `browserBundleIDs`, in their canonical case.
    static let browserHelpers: [String: String] = [
        "com.google.chrome.helper": "com.google.Chrome",
        "company.thebrowser.browser.helper": "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac.helper": "com.microsoft.edgemac",
        "com.brave.browser.helper": "com.brave.Browser",
        "ru.yandex.desktop.yandex-browser.helper": "ru.yandex.desktop.yandex-browser",
    ]

    /// Microsoft Teams for macOS (`com.microsoft.teams2`) is not Electron:
    /// its call page is held by a separate helper program built on Chromium,
    /// `Microsoft Teams WebView.app` (`com.microsoft.teams2.helper`), the
    /// same way a Chromium browser's own capture runs in its own helper; the
    /// microphone itself during a call is held by a third process,
    /// `com.microsoft.teams2.modulehost` (reported holding audio input
    /// across many calls in a row, TypeWhisper issue #1583), which the
    /// `.helper`/`.helper.<kind>` pattern does not cover. Mapped here rather
    /// than through `programHelperMainApp` below, because that function only
    /// considers the bundle IDs of `.app`/`.appWeb` rows actually in
    /// `services` (`programBundleIDs()`), and the Teams program row
    /// (`teams-app`) is held back in `unconfirmedServices` instead, never
    /// read by `readLive` — this table exists so `mainApp(ofHolder:)` still
    /// resolves the holder correctly while the row waits there.
    static let programHelpers: [String: String] = [
        "com.microsoft.teams2.helper": "com.microsoft.teams2",
        "com.microsoft.teams2.modulehost": "com.microsoft.teams2",
    ]

    /// The program whose window actually shows the call, from the process
    /// Core Audio reports as holding the microphone: a Chromium helper is
    /// mapped to its browser; a helper of an `.app`/`.appWeb` row's own
    /// program (`<bundleID>.helper…`) is mapped to that program, the longest
    /// matching `bundleID` winning if more than one row's program could be a
    /// prefix of the holder's; anything else (e.g. `us.zoom.xos`) is returned
    /// as is, case unchanged. A bare `com.apple.WebKit.*` process is one such
    /// "anything else": it is the one capture process shared by every app
    /// that embeds `WKWebView` — Safari included, but also any other program
    /// on the Mac that does — so it is never folded into Safari specifically
    /// any more; the price is that a call in an actual Safari tab is not read
    /// until the owner's live check finds a way to tell the two apart. Google
    /// Meet's own "install as app" button (a PWA) runs in a process of its
    /// own (`com.google.Chrome.app.<id>`, etc.) that is not mapped here:
    /// which process Core Audio actually reports for it, and whose windows
    /// that process has, is for the owner to confirm on a live call.
    static func mainApp(ofHolder bundleID: String) -> String {
        let lower = bundleID.lowercased()
        for (helper, app) in browserHelpers where lower == helper || lower.hasPrefix(helper + ".") {
            return app
        }
        for (helper, app) in programHelpers where lower == helper || lower.hasPrefix(helper + ".") {
            return app
        }
        if let app = programHelperMainApp(ofHolder: lower) { return app }
        return bundleID
    }

    /// The default table's own `.app`/`.appWeb` programs — never a custom
    /// `services` array passed into `snapshot` for a test — each a
    /// candidate whose helper processes (`<bundleID>.helper…`) should also
    /// resolve to it, the same way a Chromium browser's helper does.
    private static func programBundleIDs() -> [String] {
        services.compactMap { service in
            switch service.place {
            case .browser: return nil
            case .app(let bundleID, _): return bundleID
            case .appWeb(let bundleID, _): return bundleID
            }
        }
    }

    private static func programHelperMainApp(ofHolder lower: String) -> String? {
        var best: String?
        for bundleID in programBundleIDs() {
            // ".helper" or ".helper.<kind>" only, as the doc comment above
            // promises — any other dot-suffix (e.g. a test fixture's own
            // "<bundleID>.test") is a holder in its own right, never this
            // program's helper.
            let helperPrefix = bundleID.lowercased() + ".helper"
            guard lower == helperPrefix || lower.hasPrefix(helperPrefix + ".") else { continue }
            if best == nil || bundleID.count > best!.count { best = bundleID }
        }
        return best
    }

    /// The window's own AX object, held for the whole recording and compared
    /// only with `CFEqual`: two `AXUIElement`s of one window are equal, a new
    /// window with the same title is not. `@unchecked`: an `AXUIElement` is
    /// immutable and safe to compare from any thread.
    struct WindowElement: Equatable, @unchecked Sendable {
        let object: AnyObject

        /// `nil` when `address` is 0 (no AX object at all, e.g. a test node
        /// that never set one) — such a window can never be pinned (1c).
        /// Only valid while the node that gave `address` is still alive
        /// (inside `walk`): the address is turned straight back into a
        /// strong reference here and never stored as a number again.
        init?(address: UInt) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return nil }
            object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }

        static func == (l: Self, r: Self) -> Bool { CFEqual(l.object as CFTypeRef, r.object as CFTypeRef) }
    }

    /// The meeting a pin is fixed to, not merely the program: a tab's or an
    /// embedded page's own address (never port, query or fragment — see
    /// `meetingAddress(of:queryKeys:)` — but significant query parameters
    /// where a service names them, `Service.meetingQueryKeys`), or a native
    /// app's call window, identified by its `AXIdentifier`, its title as of
    /// the pin, and the window's own AX object (`WindowElement`): a new
    /// window with the very same identifier and title (Zoom reopening its
    /// call window after one meeting ends and another starts) is still told
    /// apart from the pinned one, since `CFEqual` never equates two
    /// different windows.
    enum Meeting: Equatable, Sendable {
        case page(address: String)
        case window(identifier: String, title: String, element: WindowElement)
    }

    /// The service, the app and the meeting whose call a recording follows:
    /// fixed by the first find and never changed until the recording ends.
    /// `meeting` is never defaulted — every caller names it explicitly. `nil`
    /// means the pinned meeting itself is unknown (a `MeetingPageSnapshot`
    /// built without one, as every scripted test feed in `CallFeedWatcherTests`
    /// does, or a candidate whose own identity could not be read — 1b/1c):
    /// once pinned, a read then matches nothing at all, the safe side —
    /// reading on would risk another meeting's names. Never compared as
    /// `Optional == Optional`, which would treat two unknown identities as
    /// the same meeting: `snapshot` always unwraps `pin.meeting` first.
    struct Pin: Equatable, Sendable {
        var service: String
        var app: String
        var meeting: Meeting?
    }

    /// `axURL`, normalized to scheme, lower-cased host and path, plus —
    /// only for the query names in `queryKeys` — the room identity that
    /// lives in the query string on some services (Bitrix24): never port,
    /// fragment or any other query parameter, so a search engine's or
    /// tracker's own extra parameters never change a tab's identity. `nil`
    /// when `axURL` does not parse to at least a scheme and a host, or when
    /// any one of `queryKeys` appears more than once in the query (an
    /// address murmurly cannot be sure it has correctly identified must
    /// never be treated as any particular meeting).
    static func meetingAddress(of axURL: String?, queryKeys: [String] = []) -> String? {
        guard let axURL, let components = URLComponents(string: axURL),
              let scheme = components.scheme, let host = components.host, !host.isEmpty else {
            return nil
        }
        let base = "\(scheme.lowercased())://\(host.lowercased())\(components.percentEncodedPath)"
        guard !queryKeys.isEmpty, let items = components.percentEncodedQueryItems, !items.isEmpty else {
            return base
        }
        var matched: [String: String] = [:]
        for key in queryKeys {
            let values = items.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
            guard values.count <= 1 else { return nil }
            if let value = values.first { matched[key] = value.value ?? "" }
        }
        guard !matched.isEmpty else { return base }
        let query = matched.keys.sorted().map { "\($0)=\(matched[$0] ?? "")" }.joined(separator: "&")
        return base + "?" + query
    }

    // MARK: - The read

    /// Every call to `readLive` or `snapshotOffMainQueue` hands its blocking
    /// AX work to this one serial queue, never the cooperative thread pool and
    /// never the caller's own thread (the caller may well be the main actor):
    /// a browser tab that never answers holds this queue's one thread, not
    /// whoever asked for a snapshot.
    private static let readQueue = DispatchQueue(label: "murmurly.meeting-page-reader", qos: .utility)

    private static func onReadQueue<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            readQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Reads the live accessibility tree, off the main thread and off the
    /// caller's own thread, but only of the app(s) currently holding the
    /// microphone (`holders`, before `mainApp(ofHolder:)`) — or, once pinned,
    /// only of the pinned app, whatever holds the microphone now. A test
    /// process, or a process without Accessibility trust, gets `.notFound`
    /// without ever asking for the permission: this call must never surface a
    /// system prompt. No holder with a call row of its own: `.notFound`
    /// without a single `AXUIElement` call.
    static func readLive(holders: Set<String>, pin: Pin?, limits: Limits = .standard()) async -> MeetingPageSnapshot {
        guard !TestIsolation.isTestProcess else { return .notFound }
        guard AccessibilityAuthorization.isTrusted else { return .notFound }
        let apps = Set(targets(holders: holders, pin: pin, services: services).map(\.1))
        guard !apps.isEmpty else { return .notFound }
        return await onReadQueue {
            snapshot(
                windows: collectWindows(of: apps), holders: holders, pin: pin, limits: limits,
                services: servicesForRead(holders: holders, pin: pin) { zoomCaptionedServices }
            )
        }
    }

    /// Built once, lazily (Swift's own guarantee for a `static let`), the
    /// first time `servicesForRead` actually needs it.
    private static let zoomCaptionedServices: [Service] = addingInstalledZoomCaptions(
        appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: zoomBundleID), to: services
    )

    /// `services` unless this read's own `targets` include the Zoom program
    /// row (`.app(bundleID: zoomBundleID, _)`), in which case `zoomCaptions`
    /// is asked for its table instead — so a call in Chrome, in any other
    /// service, or even Zoom's own web client, never opens Zoom's installed
    /// bundle at all (5): only an actual Zoom-program read does.
    /// `zoomCaptions` is a parameter, not a direct reference to
    /// `zoomCaptionedServices`, purely so a test can count how often it
    /// actually runs.
    static func servicesForRead(holders: Set<String>, pin: Pin?, zoomCaptions: () -> [Service]) -> [Service] {
        let needsZoomProgram = targets(holders: holders, pin: pin, services: services).contains { pair in
            if case .app(let bundleID, _) = pair.0.place { return bundleID == zoomBundleID }
            return false
        }
        return needsZoomProgram ? zoomCaptions() : services
    }

    /// The same queue hop `readLive` uses, over trees the caller already has.
    /// Exists so tests can prove the hop itself never blocks the caller —
    /// `readLive` itself always answers `.notFound` in a test process and
    /// never reaches this code with a live tree.
    static func snapshotOffMainQueue(
        windows: [String: [AccessibilityPageNode]], holders: Set<String>, pin: Pin?, limits: Limits
    ) async -> MeetingPageSnapshot {
        await onReadQueue {
            snapshot(windows: windows, holders: holders, pin: pin, limits: limits)
        }
    }

    /// Only the windows of `apps` — the programs `targets` picked out for
    /// this read, whether a `.browser` row's browser or an `.app` row's own
    /// bundle ID — keyed by bundle ID; several processes of the same app
    /// would append to the same key. This is the one path for both kinds of
    /// row: nothing outside `apps` is ever asked for its windows.
    private static func collectWindows(of apps: Set<String>) -> [String: [AccessibilityPageNode]] {
        var windows: [String: [AccessibilityPageNode]] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, apps.contains(bundleID) else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // Short-lived, like every `AXPageNode`'s own timeout below: a hung
            // browser must not hold this queue, a normal answer takes
            // milliseconds. `axApp` only ever answers this one question, so it
            // is not worth wrapping as a page node of its own.
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == CFArrayGetTypeID(),
                  let array = value as? [AnyObject] else { continue }
            windows[bundleID, default: []].append(contentsOf: array.compactMap { item in
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
                return AXPageNode(element: unsafeDowncast(item, to: AXUIElement.self))
            })
        }
        return windows
    }

    /// Whether `service`'s program is `app`: any browser from
    /// `browserBundleIDs` for a `.browser` row, or the row's own bundle ID
    /// for an `.app` row.
    private static func runs(_ service: Service, in app: String) -> Bool {
        switch service.place {
        case .browser: return browserBundleIDs.contains(app)
        case .app(let bundleID, _): return bundleID == app
        case .appWeb(let bundleID, _): return bundleID == app
        }
    }

    /// The (row, app) pairs worth trying this read, in a fixed order so the
    /// same inputs always pick the same one: pinned, only that row in its
    /// pinned app — holders are not consulted at all once pinned; otherwise
    /// every row, for every currently held app (reduced to its main program,
    /// sorted for a deterministic order) whose program it runs in. A pinned
    /// lookup matches both the id and the app: two rows can share one id
    /// (Bitrix24's browser tab and its program), each running in a
    /// different app, so the id alone would not tell them apart.
    private static func targets(holders: Set<String>, pin: Pin?, services: [Service]) -> [(Service, String)] {
        if let pin {
            // Two rows may share one `id` (the feed's own key), each for a
            // different place (Zoom's native app and its web client): the
            // pinned row must be the one that actually runs in the pinned
            // app, not merely the first row of that id in the table.
            guard let row = services.first(where: { $0.id == pin.service && runs($0, in: pin.app) }) else { return [] }
            return [(row, pin.app)]
        }
        let heldApps = Set(holders.map(mainApp(ofHolder:))).sorted()
        var result: [(Service, String)] = []
        for service in services {
            for app in heldApps where runs(service, in: app) {
                result.append((service, app))
            }
        }
        return result
    }

    /// One candidate area found while collecting: `target` indexes the
    /// `(Service, String)` pair in the caller's own `targets` list, `area` is
    /// the node found for it and `meeting` is that area's own identity (a
    /// page's address or a native window's identifier and title) — `nil`
    /// when the identity itself could not be read (an unparseable address
    /// missing one of `meetingQueryKeys`, 1a/1b, or a window with no AX
    /// object at all, 1c): such a candidate can never be chosen, pinned or
    /// not, since nothing distinguishes it from any other meeting that might
    /// one day read the same way.
    private struct Candidate {
        var target: Int
        var area: AccessibilityPageNode
        var meeting: Meeting?
    }

    /// One walk over the chosen programs' windows collects every area any
    /// candidate row accepts; the choice is made only after the walk. With a
    /// pin, exactly one candidate matching the pinned (known) meeting is
    /// read. Without one, every candidate's tiles are read with the shared
    /// budget, and the area chosen is the one and only candidate that both
    /// turned out to have a confirmed tile (`visible == true`) and has a
    /// known identity — zero or several confirmed areas, or a confirmed area
    /// with an unknown identity, read nothing: table order no longer decides
    /// anything, since an empty area intercepting the choice before its
    /// tiles are even read was exactly this card's defect. A walk, or a
    /// candidate's own tile read, that the budget cuts short reads nothing
    /// at all, even if some candidates were already confirmed: an unwalked
    /// window may hold a second area of the same meeting, or of another one,
    /// which only a complete read can rule out.
    static func snapshot(
        windows: [String: [AccessibilityPageNode]], holders: Set<String>, pin: Pin?, limits: Limits,
        services: [Service] = MeetingPageReader.services
    ) -> MeetingPageSnapshot {
        let budget = Budget(limits: limits)
        let targetList = targets(holders: holders, pin: pin, services: services)
        guard !targetList.isEmpty else { return .notFound }
        guard let candidates = collectCandidates(windows: windows, targets: targetList, budget: budget) else {
            return .notFound
        }

        if let pin {
            // Never `candidate.meeting == pin.meeting` on the `Meeting?`
            // values directly: two unknown identities (`nil == nil`) would
            // then equal each other, exactly the hole 1b closes.
            guard let pinnedMeeting = pin.meeting else { return .notFound }
            let matching = candidates.filter { $0.meeting.map { $0 == pinnedMeeting } ?? false }
            guard matching.count == 1 else { return .notFound }
            let candidate = matching[0]
            let (service, app) = targetList[candidate.target]
            return read(candidate, service: service, app: app, budget: budget)
        }

        var confirmed: [(Candidate, MeetingPageSnapshot)] = []
        for candidate in candidates {
            let (service, app) = targetList[candidate.target]
            let result = read(candidate, service: service, app: app, budget: budget)
            guard !budget.truncated else { return .notFound }
            if result.visible { confirmed.append((candidate, result)) }
        }
        guard confirmed.count == 1, confirmed[0].0.meeting != nil else { return .notFound }
        return confirmed[0].1
    }

    /// Reads one candidate's tiles with what is left of `budget`. `found:
    /// true` with no names at all, `visible` included, is the budget-cut
    /// answer: a half-read grid must never report a name or a speaker that
    /// might belong to someone else's tile.
    private static func read(_ candidate: Candidate, service: Service, app: String, budget: Budget) -> MeetingPageSnapshot {
        var result = MeetingPageSnapshot(found: true, service: service.id, app: app, meeting: candidate.meeting)
        if let rules = service.captionRules {
            var tiles: [(name: String, speaking: Bool)] = []
            var selfName: String?
            collectCaptionTiles(in: candidate.area, rules: rules, depth: 1, budget: budget, tiles: &tiles, selfName: &selfName)
            if !budget.truncated { applyCaptionTiles(tiles, selfName: selfName, into: &result) }
        } else if let grid = findGrid(in: candidate.area, for: service, depth: 1, budget: budget) {
            collectTiles(grid, for: service, depth: 1, budget: budget, into: &result)
        }
        return budget.truncated
            ? MeetingPageSnapshot(found: true, service: service.id, app: app, meeting: candidate.meeting)
            : result
    }

    /// Walks every target program's windows exactly once, in the order its
    /// app first appears in `targets`, collecting a `Candidate` for every
    /// target that accepts an area it finds. `nil` means the budget ran out
    /// before the walk finished — the caller must then read nothing, even if
    /// some candidates were already found: an unwalked window might hold a
    /// second area of the same meeting, which only a complete walk can rule
    /// out.
    private static func collectCandidates(
        windows: [String: [AccessibilityPageNode]], targets: [(Service, String)], budget: Budget
    ) -> [Candidate]? {
        var appOrder: [String] = []
        var targetsByApp: [String: [(index: Int, service: Service)]] = [:]
        for (index, pair) in targets.enumerated() {
            let (service, app) = pair
            if targetsByApp[app] == nil { appOrder.append(app) }
            targetsByApp[app, default: []].append((index, service))
        }

        var candidates: [Candidate] = []
        for app in appOrder {
            let appTargets = targetsByApp[app] ?? []
            let hasAppTargets = appTargets.contains { if case .app = $0.service.place { return true }; return false }
            let hasWebTargets = appTargets.contains {
                switch $0.service.place {
                case .browser, .appWeb: return true
                case .app: return false
                }
            }
            for window in windows[app] ?? [] {
                guard walk(
                    window, appTargets: appTargets, hasAppTargets: hasAppTargets, hasWebTargets: hasWebTargets,
                    depth: 0, budget: budget, candidates: &candidates
                ) else {
                    return nil
                }
            }
        }
        return candidates
    }

    /// One node of one target program's window tree. `false` means the
    /// budget ran out — propagated straight up through every caller, so the
    /// whole walk (every window, every program) stops at once. Order of
    /// checks at one node: a top-level window's own `.app` identifier first
    /// (never descended into further, matched or not reached by later
    /// checks); then, on an `AXWebArea`, every `.browser`/`.appWeb` target's
    /// meeting address (matched areas are never descended into either — their
    /// tiles are read later, with the area already chosen) and, failing
    /// that, a shell address to descend through; any other node is opened
    /// (its children visited) only while this program still has an
    /// unmatched web target to look for — a program with only `.app` targets
    /// never opens a window that didn't match at the top.
    private static func walk(
        _ node: AccessibilityPageNode, appTargets: [(index: Int, service: Service)],
        hasAppTargets: Bool, hasWebTargets: Bool, depth: Int, budget: Budget, candidates: inout [Candidate]
    ) -> Bool {
        guard budget.enter(depth: depth) else { return false }

        if depth == 0, hasAppTargets {
            var matched = false
            for (index, service) in appTargets {
                guard case .app(_, let windowIdentifier) = service.place, !windowIdentifier.isEmpty,
                      node.identifier == windowIdentifier else { continue }
                let meeting: Meeting? = WindowElement(address: node.axElementAddress).map {
                    .window(identifier: windowIdentifier, title: node.title ?? "", element: $0)
                }
                candidates.append(Candidate(target: index, area: node, meeting: meeting))
                matched = true
            }
            if matched { return true }
        }

        if node.role == "AXWebArea" {
            guard hasWebTargets else { return true }
            let components = node.axURL.flatMap { URLComponents(string: $0) }
            var matched = false
            for (index, service) in appTargets {
                switch service.place {
                case .browser(let meetingAreas, _):
                    guard let components, meetingAreas.contains(where: { $0.matches(components) }) else { continue }
                    let meeting = meetingAddress(of: node.axURL, queryKeys: service.meetingQueryKeys)
                        .map { Meeting.page(address: $0) }
                    candidates.append(Candidate(target: index, area: node, meeting: meeting))
                    matched = true
                case .appWeb(_, let meetingAreas):
                    let isMeetingArea = meetingAreas.isEmpty
                        || (components.map { c in meetingAreas.contains(where: { $0.matches(c) }) } ?? false)
                    guard isMeetingArea else { continue }
                    let meeting = meetingAddress(of: node.axURL, queryKeys: service.meetingQueryKeys)
                        .map { Meeting.page(address: $0) }
                    candidates.append(Candidate(target: index, area: node, meeting: meeting))
                    matched = true
                case .app:
                    continue
                }
            }
            if matched { return true }
            let descendsForShell = appTargets.contains { pair in
                guard case .browser(_, let shells) = pair.service.place, let components else { return false }
                return shells.contains { $0.matches(components) }
            }
            guard descendsForShell else { return true }
        } else if !hasWebTargets {
            return true
        }

        for child in node.children {
            guard walk(
                child, appTargets: appTargets, hasAppTargets: hasAppTargets, hasWebTargets: hasWebTargets,
                depth: depth + 1, budget: budget, candidates: &candidates
            ) else {
                return false
            }
        }
        return true
    }

    // MARK: - The budget

    private final class Budget {
        private var remainingNodes: Int
        private let deadline: Date
        private let maxDepth: Int
        private(set) var truncated = false

        init(limits: Limits) {
            remainingNodes = limits.maxNodes
            deadline = limits.deadline
            maxDepth = limits.maxDepth
        }

        /// Call once per node, before reading anything off it. `false` once
        /// the budget is spent; `truncated` then stays set for the rest of
        /// this traversal.
        func enter(depth: Int) -> Bool {
            guard !truncated else { return false }
            guard depth <= maxDepth, remainingNodes > 0, Date() < deadline else {
                truncated = true
                return false
            }
            remainingNodes -= 1
            return true
        }
    }

    // MARK: - Matching a node's classes against a service's rules

    private static func matchesClass(_ classes: [String], pattern: String, mode: ClassMatch) -> Bool {
        guard !pattern.isEmpty else { return false }
        switch mode {
        case .prefix: return classes.contains { $0.hasPrefix(pattern) }
        case .exact: return classes.contains { $0 == pattern }
        }
    }

    private static func matchesAnyClass(_ classes: [String], patterns: [String], mode: ClassMatch) -> Bool {
        patterns.contains { matchesClass(classes, pattern: $0, mode: mode) }
    }

    // MARK: - Finding the participants grid inside the meeting area

    private static func findGrid(
        in node: AccessibilityPageNode, for service: Service, depth: Int, budget: Budget
    ) -> AccessibilityPageNode? {
        // An empty `gridClass` (Jitsi: no grid container of its own) means
        // the meeting area itself is where tiles are searched for, rather
        // than some anchor inside it: `matchesClass` never matches an empty
        // pattern, so that case is handled here instead.
        if service.gridClass.isEmpty { return node }
        guard budget.enter(depth: depth) else { return nil }
        if matchesClass(node.domClassList, pattern: service.gridClass, mode: service.classMatch) {
            return node
        }
        for child in node.children {
            if let found = findGrid(in: child, for: service, depth: depth + 1, budget: budget) {
                return found
            }
            if budget.truncated { return nil }
        }
        return nil
    }

    // MARK: - Tiles

    private static func collectTiles(
        _ grid: AccessibilityPageNode, for service: Service, depth: Int, budget: Budget, into result: inout MeetingPageSnapshot
    ) {
        for child in grid.children {
            visitForTile(child, for: service, depth: depth + 1, budget: budget, into: &result)
            if budget.truncated { return }
        }
    }

    private static func visitForTile(
        _ node: AccessibilityPageNode, for service: Service, depth: Int, budget: Budget, into result: inout MeetingPageSnapshot
    ) {
        guard budget.enter(depth: depth) else { return }
        if isTile(node, service: service) {
            handleTile(node, for: service, depth: depth, budget: budget, into: &result)
            return
        }
        // A screen-share tile (`tileDisplayClass` instead of
        // `tileDevicesClass`) is never even opened: its subtree is not a
        // person and must not spend the budget that a real tile elsewhere in
        // the grid still needs.
        if isDisplayTile(node, service: service) { return }
        for child in node.children {
            visitForTile(child, for: service, depth: depth + 1, budget: budget, into: &result)
            if budget.truncated { return }
        }
    }

    private static func isTile(_ node: AccessibilityPageNode, service: Service) -> Bool {
        let classes = node.domClassList
        let hasItemClass = matchesAnyClass(classes, patterns: service.tileClasses, mode: service.classMatch)
        // An empty `tileDevicesClass` (Jitsi: no paired class) means a tile
        // needs no second class at all; `matchesClass` itself never matches
        // an empty pattern, so that case is handled separately here.
        let hasDevicesClass = service.tileDevicesClass.isEmpty
            || matchesClass(classes, pattern: service.tileDevicesClass, mode: service.classMatch)
        return hasItemClass && hasDevicesClass
    }

    private static func isDisplayTile(_ node: AccessibilityPageNode, service: Service) -> Bool {
        let classes = node.domClassList
        let hasItemClass = matchesAnyClass(classes, patterns: service.tileClasses, mode: service.classMatch)
        let hasDisplayClass = matchesClass(classes, pattern: service.tileDisplayClass, mode: service.classMatch)
        return hasItemClass && hasDisplayClass
    }

    private static func handleTile(
        _ tile: AccessibilityPageNode, for service: Service, depth: Int, budget: Budget, into result: inout MeetingPageSnapshot
    ) {
        var isSelf = false
        var name: String?
        var speaking = false
        var silenced = false
        searchTileDetails(
            tile, for: service, depth: depth, budget: budget,
            isSelf: &isSelf, name: &name, speaking: &speaking, silenced: &silenced
        )
        guard !budget.truncated else { return }
        // No name class anywhere in the tile: not a person (covers a
        // display tile that slipped past `isTile`, belt and suspenders).
        guard let name, !name.isEmpty else { return }
        if silenced { speaking = false }
        result.visible = true
        if isSelf {
            result.selfName = name
            result.selfSpeaking = speaking
            result.selfVisible = true
        } else {
            if !result.people.contains(name) { result.people.append(name) }
            if speaking, !result.speaking.contains(name) { result.speaking.append(name) }
        }
    }

    private static func searchTileDetails(
        _ node: AccessibilityPageNode, for service: Service, depth: Int, budget: Budget,
        isSelf: inout Bool, name: inout String?, speaking: inout Bool, silenced: inout Bool
    ) {
        guard budget.enter(depth: depth) else { return }
        let classes = node.domClassList
        if matchesClass(classes, pattern: service.selfClass, mode: service.classMatch) {
            isSelf = true
        }
        if let selfTileIdentifier = service.selfTileIdentifier, node.domIdentifier == selfTileIdentifier {
            isSelf = true
        }
        if !service.silenceClass.isEmpty,
           matchesClass(classes, pattern: service.silenceClass, mode: service.classMatch) {
            silenced = true
        }
        if matchesClass(classes, pattern: service.speakingClass, mode: service.classMatch)
            || matchesAnyClass(classes, patterns: service.alternateSpeakingClasses, mode: service.classMatch) {
            speaking = true
        }
        if name == nil,
           matchesClass(classes, pattern: service.nameClass, mode: service.classMatch)
               || matchesAnyClass(classes, patterns: service.alternateNameClasses, mode: service.classMatch) {
            name = nodeText(node)
            if name == nil, service.nameFromStaticText {
                name = firstStaticText(in: node, depth: depth, budget: budget)
            }
        }
        for child in node.children {
            searchTileDetails(
                child, for: service, depth: depth + 1, budget: budget,
                isSelf: &isSelf, name: &name, speaking: &speaking, silenced: &silenced
            )
            if budget.truncated { return }
        }
    }

    /// The first descendant whose role is `AXStaticText` and that has text
    /// of its own (Zoom's web client: a bare `span` inside a tile's footer,
    /// next to icons that carry only a description — those must never
    /// become the name, hence the role check rather than any text field).
    private static func firstStaticText(in node: AccessibilityPageNode, depth: Int, budget: Budget) -> String? {
        guard budget.enter(depth: depth) else { return nil }
        if node.role == "AXStaticText", let text = nodeText(node) { return text }
        for child in node.children {
            if let found = firstStaticText(in: child, depth: depth + 1, budget: budget) { return found }
            if budget.truncated { return nil }
        }
        return nil
    }

    // MARK: - Reading tiles by caption (a service with `captionRules`)

    /// Walks the whole meeting window once: a node whose role matches
    /// `rules.tileRole` is a tile. One that parses is never descended into,
    /// so a name-shaped description nested inside it (another tile, say) is
    /// never picked up as a tile of its own. One that does not parse is, by
    /// default (`rules.descendsIntoUnparsedTiles == false`, every row
    /// above), left alone the same way; set `true`, its children are
    /// visited instead, for a program whose own outer tile-role node is not
    /// itself a parseable caption and only a nested node is. The local user's own row is
    /// looked for only inside the subtree of a node whose role matches
    /// `rules.listRole` (the participants list): once inside that subtree,
    /// every node's title, value and description are each checked against
    /// `rules.selfSuffix`, and the first match anywhere in the list is kept
    /// as the candidate self name, matched against the tiles once the whole
    /// window has been walked — never read off a tile itself, and never
    /// read off a node outside the list.
    private static func collectCaptionTiles(
        in node: AccessibilityPageNode, rules: CaptionRules, depth: Int, budget: Budget,
        tiles: inout [(name: String, speaking: Bool)], selfName: inout String?, insideList: Bool = false
    ) {
        guard budget.enter(depth: depth) else { return }
        if node.role == rules.tileRole {
            if let description = trimmed(node.description),
               let parsed = parseCaptionDescription(description, rules: rules) {
                tiles.append(parsed)
                return
            }
            guard rules.descendsIntoUnparsedTiles else { return }
        }
        let insideListNow = insideList || node.role == rules.listRole
        if insideListNow, selfName == nil {
            outer: for text in [node.title, node.value, node.description] {
                guard let trimmedText = trimmed(text) else { continue }
                for suffix in rules.selfSuffixes {
                    if let candidate = selfNameCandidate(trimmedText, suffix: suffix) {
                        selfName = candidate
                        break outer
                    }
                }
            }
        }
        for child in node.children {
            collectCaptionTiles(
                in: child, rules: rules, depth: depth + 1, budget: budget,
                tiles: &tiles, selfName: &selfName, insideList: insideListNow
            )
            if budget.truncated { return }
        }
    }

    /// Parses from the end, one trailing `", <phrase>"` at a time, in
    /// whatever order Zoom happens to print them: the speaking marker (at
    /// most once), a mandatory status from `rules.statuses` (at most
    /// `rules.statusCount` times) or an optional one from
    /// `rules.optionalStatuses` (each at most once). The loop stops at the
    /// first trailing phrase that matches none of those, so an unknown tail
    /// — or a third mandatory status beyond `statusCount` — is left in the
    /// name rather than stripped. Anything left over once the loop stops is
    /// the name, commas and all. If fewer than `statusCount` mandatory
    /// statuses were found, the description is an unknown shape and this
    /// returns `nil` — better no name than a wrong one, never a guess from a
    /// partial match.
    static func parseCaptionDescription(_ description: String, rules: CaptionRules) -> (name: String, speaking: Bool)? {
        var remaining = description
        var speaking = false
        var markerStripped = false
        var requiredCount = 0
        var strippedOptional = Set<Int>()
        while true {
            if !markerStripped,
               let marker = rules.speakingMarkers.first(where: { hasSuffixCaseInsensitive(remaining, suffix: ", \($0)") }) {
                remaining.removeLast(", \(marker)".count)
                speaking = true
                markerStripped = true
                continue
            }
            if requiredCount < rules.statusCount,
               let status = rules.statuses.first(where: { hasSuffixCaseInsensitive(remaining, suffix: ", \($0)") }) {
                remaining.removeLast(", \(status)".count)
                requiredCount += 1
                continue
            }
            if let index = rules.optionalStatuses.indices.first(where: { i in
                !strippedOptional.contains(i) && hasSuffixCaseInsensitive(remaining, suffix: ", \(rules.optionalStatuses[i])")
            }) {
                remaining.removeLast(", \(rules.optionalStatuses[index])".count)
                strippedOptional.insert(index)
                continue
            }
            break
        }
        guard requiredCount == rules.statusCount else { return nil }
        let name = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (name, speaking)
    }

    private static func hasSuffixCaseInsensitive(_ text: String, suffix: String) -> Bool {
        guard text.count >= suffix.count else { return false }
        return text.suffix(suffix.count).caseInsensitiveCompare(suffix) == .orderedSame
    }

    /// `text` is a participants-list row, e.g. `"Jane Doe (me)"`; `nil`
    /// unless it ends with `suffix` and something besides the suffix is
    /// left over.
    private static func selfNameCandidate(_ text: String, suffix: String) -> String? {
        guard !suffix.isEmpty, text.count >= suffix.count,
              text.suffix(suffix.count).caseInsensitiveCompare(suffix) == .orderedSame else { return nil }
        let name = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Matches parsed tiles against the candidate self name read from the
    /// participants list: an exact match (never a suffix check — a tile's
    /// own description never carries `selfSuffix` by this rule) names the
    /// local user, everyone else is a participant.
    private static func applyCaptionTiles(
        _ tiles: [(name: String, speaking: Bool)], selfName: String?, into result: inout MeetingPageSnapshot
    ) {
        guard !tiles.isEmpty else { return }
        result.visible = true
        for tile in tiles {
            if let selfName, tile.name == selfName {
                result.selfName = tile.name
                result.selfVisible = true
                if tile.speaking { result.selfSpeaking = true }
            } else {
                if !result.people.contains(tile.name) { result.people.append(tile.name) }
                if tile.speaking, !result.speaking.contains(tile.name) { result.speaking.append(tile.name) }
            }
        }
    }

    /// Title, else value, else description, each trimmed of leading and
    /// trailing spaces and line breaks; a field that is empty after trimming
    /// is treated as absent, so it neither becomes the name nor blocks the
    /// fall-through to the next field. " Гость " and "Гость" must read as the
    /// same name, not two different people.
    private static func nodeText(_ node: AccessibilityPageNode) -> String? {
        if let title = trimmed(node.title) { return title }
        if let value = trimmed(node.value) { return value }
        if let description = trimmed(node.description) { return description }
        return nil
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
