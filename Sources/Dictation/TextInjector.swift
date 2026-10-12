import AppKit

/// Inserts text into the focused field of the frontmost app.
///
/// Primary method (Cyrillic-safe, app-agnostic): put our text on the clipboard
/// and post a synthetic ⌘V. Per-character Unicode events are NOT used — they
/// drop Cyrillic in Electron/Qt/Java apps.
///
/// Posting synthetic key events requires Accessibility permission. NSPasteboard
/// and CGEvent are main-thread APIs → the type is `@MainActor`.
@MainActor
enum TextInjector {
    typealias PasteboardPrepare = @MainActor (
        NSPasteboard,
        NSPasteboard.ContentsOptions
    ) -> Int
    typealias PasteboardWriteText = @MainActor (NSPasteboard, String) -> Bool
    typealias PasteAction = @MainActor () -> Bool
    typealias RestorePause = @MainActor () async -> Void

    private struct ClipboardSnapshot: Sendable {
        struct Item: Sendable {
            struct Representation: Sendable {
                let type: String
                let data: Data
            }

            let representations: [Representation]
        }

        let changeCount: Int
        let items: [Item]
    }

    /// Trusted for Accessibility (required to post ⌘V)? No prompt.
    static func isTrusted() -> Bool { AccessibilityAuthorization.isTrusted }

    /// Explicit user copy (history menu): normal pasteboard semantics, including
    /// Universal Clipboard. This content intentionally remains on the pasteboard.
    @discardableResult
    static func place(_ text: String) -> Bool {
        place(
            text,
            pasteboard: .general,
            prepare: livePrepare,
            writeText: liveWriteText
        )
    }

    /// Manual dictation fallback: leave our text on this Mac's pasteboard so the
    /// user can press ⌘V, but do not offer it to Universal Clipboard.
    @discardableResult
    static func placeLocally(_ text: String) -> Bool {
        placeLocally(
            text,
            pasteboard: .general,
            prepare: livePrepare,
            writeText: liveWriteText
        )
    }

    /// Clipboard + synthetic ⌘V into the frontmost application. `true` means
    /// only that the complete synthetic chord was posted; AppKit provides no way
    /// to prove that the target application accepted the paste.
    static func inject(_ text: String) async -> Bool {
        await inject(
            text,
            pasteboard: .general,
            prepare: livePrepare,
            writeText: liveWriteText,
            postPaste: postPasteKeystroke,
            pause: {
                try? await Task.sleep(for: .milliseconds(400))
            }
        )
    }

    @discardableResult
    static func place(
        _ text: String,
        pasteboard: NSPasteboard,
        prepare: PasteboardPrepare,
        writeText: PasteboardWriteText
    ) -> Bool {
        _ = prepare(pasteboard, [])
        return writeText(pasteboard, text)
    }

    @discardableResult
    static func placeLocally(
        _ text: String,
        pasteboard: NSPasteboard,
        prepare: PasteboardPrepare,
        writeText: PasteboardWriteText
    ) -> Bool {
        _ = prepare(pasteboard, .currentHostOnly)
        return writeText(pasteboard, text)
    }

    static func inject(
        _ text: String,
        pasteboard: NSPasteboard,
        prepare: PasteboardPrepare,
        writeText: PasteboardWriteText,
        postPaste: PasteAction,
        pause: RestorePause
    ) async -> Bool {
        guard let snapshot = snapshot(pasteboard) else {
            AppLog.error("inject", "pasteboard changed while taking snapshot")
            return false
        }

        guard pasteboard.changeCount == snapshot.changeCount else {
            AppLog.error("inject", "pasteboard changed before local write")
            return false
        }

        let localChangeCount = prepare(pasteboard, .currentHostOnly)
        guard writeText(pasteboard, text) else {
            restore(
                snapshot,
                to: pasteboard,
                ifUnchangedFrom: localChangeCount,
                prepare: prepare
            )
            AppLog.error("inject", "failed to write dictated text to pasteboard")
            return false
        }

        guard postPaste() else {
            restore(
                snapshot,
                to: pasteboard,
                ifUnchangedFrom: localChangeCount,
                prepare: prepare
            )
            AppLog.error("inject", "failed to allocate synthetic paste events")
            return false
        }

        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        AppLog.info("inject", "⌘V → frontmost: \(front), \(text.count) chars")
        await pause()
        restore(
            snapshot,
            to: pasteboard,
            ifUnchangedFrom: localChangeCount,
            prepare: prepare
        )
        return true
    }

    private static var livePrepare: PasteboardPrepare {
        { pasteboard, options in
            pasteboard.prepareForNewContents(with: options)
        }
    }

    private static var liveWriteText: PasteboardWriteText {
        { pasteboard, text in
            pasteboard.writeObjects([text as NSString])
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        let initialChangeCount = pasteboard.changeCount
        var items: [ClipboardSnapshot.Item] = []

        // Lazy providers are deliberately materialized on MainActor before the
        // pasteboard is cleared. A very large or slow provider can briefly block
        // the UI; carrying NSPasteboardItem across the suspension is not safe.
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [ClipboardSnapshot.Item.Representation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations.append(.init(type: type.rawValue, data: data))
            }
            items.append(.init(representations: representations))
        }

        guard pasteboard.changeCount == initialChangeCount else { return nil }
        return ClipboardSnapshot(changeCount: initialChangeCount, items: items)
    }

    private static func restore(
        _ snapshot: ClipboardSnapshot,
        to pasteboard: NSPasteboard,
        ifUnchangedFrom expectedChangeCount: Int,
        prepare: PasteboardPrepare
    ) {
        // changeCount prevents us from overwriting a newer user copy, but it says
        // nothing about whether the synthetic ⌘V was accepted by the target app.
        guard pasteboard.changeCount == expectedChangeCount else { return }

        let restoredItems = snapshot.items.map { savedItem in
            let item = NSPasteboardItem()
            for representation in savedItem.representations {
                let type = NSPasteboard.PasteboardType(representation.type)
                item.setData(representation.data, forType: type)
            }
            return item
        }

        // AppKit does not expose whether the old contents were currentHostOnly
        // (password managers use this). Normal restoration preserves ordinary
        // Universal Clipboard behavior, but could theoretically expose such an
        // unknowable local-only value. This is the intentional product tradeoff.
        _ = prepare(pasteboard, [])
        guard !restoredItems.isEmpty else { return }
        if !pasteboard.writeObjects(restoredItems) {
            AppLog.error("inject", "failed to restore previous pasteboard contents")
        }
    }

    /// Synthetic ⌘V to the frontmost application. Posts a FULL chord — real
    /// Command key down/up around V — and sets `.flags` explicitly so a stray
    /// physical modifier (e.g. Option still settling from ⌥Space) can't turn it
    /// into ⌘⌥V. More compatible across apps than flags-only.
    private static func postPasteKeystroke() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmd: CGKeyCode = 55   // left Command
        let v: CGKeyCode = 9      // 'v'
        // All-or-nothing: if any event fails to allocate, post NONE — a lone
        // cmd-down with no cmd-up would leave the Command modifier stuck.
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: false)
        else { return false }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }
}
