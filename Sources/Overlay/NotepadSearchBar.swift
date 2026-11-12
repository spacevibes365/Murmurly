import AppKit
import SwiftUI

/// The notepad's search: `⌘F` shows it only while the notepad's window is
/// key, `⌘G` / `⇧⌘G` step through the matches while it is shown, and Esc
/// hides it only with the cursor in its own field (so Esc in a note, or in
/// an edit, goes on). A local key monitor bound to this window, never a menu
/// item or `.keyboardShortcut`: the main window's Find and `⌘G` already
/// belong to `TranscriptNSTextView` (`Sources/MainWindow/TranscriptTextView.swift`),
/// and a shared shortcut would otherwise race it.
struct NotepadSearchBar: View {
    @ObservedObject var notepad: NotepadModel
    @State private var isShown = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isShown {
                searchRow
            }
        }
        .onChange(of: notepad.searchQuery) { _, _ in
            notepad.refreshSearch(resetCurrent: true)
        }
        .onChange(of: notepad.searchLines) { _, _ in
            notepad.refreshSearch()
        }
        .onChange(of: notepad.notes) { _, _ in
            notepad.refreshSearch()
        }
        .background(
            NotepadSearchMonitor(
                isShown: isShown,
                fieldFocused: fieldFocused,
                onFind: show,
                onStep: { notepad.stepSearch(by: $0) },
                onEscape: hide
            )
            .frame(width: 0, height: 0)
        )
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Live Text", text: $notepad.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { notepad.stepSearch(by: 1) }
                .accessibilityIdentifier("notepadSearchField")
            counter
            Button {
                notepad.stepSearch(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help(String(localized: "Previous match"))
            .accessibilityIdentifier("notepadSearchPrevious")
            .disabled(notepad.matchLineIDs.isEmpty)
            Button {
                notepad.stepSearch(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help(String(localized: "Next match"))
            .accessibilityIdentifier("notepadSearchNext")
            .disabled(notepad.matchLineIDs.isEmpty)
            Button(action: hide) {
                Image(systemName: "xmark.circle.fill")
            }
            .help(String(localized: "Hide Search"))
            .accessibilityIdentifier("notepadSearchClose")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var counter: some View {
        if notepad.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if notepad.matchLineIDs.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notepadSearchCount")
        } else {
            Text(verbatim: "\((notepad.currentMatch ?? 0) + 1)/\(notepad.matchLineIDs.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notepadSearchCount")
        }
    }

    private func show() {
        isShown = true
        fieldFocused = true
    }

    private func hide() {
        notepad.clearSearch()
        isShown = false
        fieldFocused = false
    }
}

/// The search logic: everything is derived from the feed
/// (`NotepadFeedItem.merge`) and `MeetingSearch`'s one rule for a match (case
/// and ё/е folded, nothing else), the same rule the meetings window uses.
/// Nothing here adds a stored property — `NotepadModel` already carries
/// `searchQuery` / `matchLineIDs` / `currentMatch` / `highlightedLineID`.
extension NotepadModel {
    /// The lines the feed shows: the recording's own model while there is
    /// one, else the lines kept at the stop.
    var searchLines: [LiveLine] { liveModel?.lines ?? keptLines }

    /// Match IDs in feed order (top to bottom): a line's `displayText` or a
    /// note's text, never the speaker name or the time — as the meetings
    /// window searches "the lines' own words only". `anchored` keeps this in
    /// step with the feed actually on screen: a moment drawn on its own line
    /// is never counted, or found, as a separate item.
    static func searchMatches(_ query: String, lines: [LiveLine], notes: [MeetingNote], anchored: Set<UUID> = []) -> [UUID] {
        NotepadFeedItem.merge(lines: lines, notes: notes, anchored: anchored).compactMap { item in
            let id: UUID
            let text: String
            switch item {
            case .line(let line):
                id = line.id
                text = line.displayText
            case .note(let note):
                id = note.id
                text = note.text
            }
            return MeetingSearch.matches(query, text) ? id : nil
        }
    }

    /// Recomputes `matchLineIDs` / `currentMatch` / `highlightedLineID` from
    /// `searchQuery`, `searchLines` and `notes`. `resetCurrent` is for a new
    /// query (the field's `onChange`): it starts at the first match and lets
    /// go of "follow the bottom" so that first match stays on screen. A plain
    /// recompute (new lines or notes arriving) never touches
    /// `isFollowingBottom` and keeps the current match by its ID, so it
    /// cannot be pulled away from what the user is looking at — only its
    /// index may change as the feed grows. Every property is assigned only
    /// when it actually changed, so an unchanged recompute publishes nothing.
    func refreshSearch(resetCurrent: Bool = false) {
        let ids = Self.searchMatches(searchQuery, lines: searchLines, notes: notes, anchored: Set(resolvedMomentLines.keys))

        let newCurrent: Int?
        if ids.isEmpty {
            newCurrent = nil
        } else if resetCurrent {
            newCurrent = 0
        } else if let highlightedLineID, let kept = ids.firstIndex(of: highlightedLineID) {
            newCurrent = kept
        } else if let currentMatch {
            newCurrent = min(currentMatch, ids.count - 1)
        } else {
            newCurrent = 0
        }
        let newHighlight = newCurrent.map { ids[$0] }

        if matchLineIDs != ids { matchLineIDs = ids }
        if currentMatch != newCurrent { currentMatch = newCurrent }
        if highlightedLineID != newHighlight { highlightedLineID = newHighlight }
        if resetCurrent, !ids.isEmpty, isFollowingBottom { isFollowingBottom = false }
    }

    /// Steps to the next (`delta == 1`) or previous (`delta == -1`) match,
    /// wrapping around; does nothing without any match. Swift's `%` is not a
    /// positive modulo, so the wrap is computed with an explicit positive
    /// remainder.
    func stepSearch(by delta: Int) {
        guard !matchLineIDs.isEmpty else { return }
        let count = matchLineIDs.count
        let base = currentMatch ?? (delta > 0 ? -1 : 0)
        let newIndex = ((base + delta) % count + count) % count
        currentMatch = newIndex
        highlightedLineID = matchLineIDs[newIndex]
        isFollowingBottom = false
    }

    /// Hiding the search bar clears its query: a stale highlight must not
    /// outlive the field that found it.
    func clearSearch() {
        searchQuery = ""
        matchLineIDs = []
        currentMatch = nil
        highlightedLineID = nil
    }
}

/// An invisible `NSView` that installs a local key monitor bound to its own
/// window: `⌘F`, `⌘G` / `⇧⌘G` and Esc, read by key code (not
/// `charactersIgnoringModifiers`) so `⌘F` works as the physical F key on any
/// layout, as AppKit's own menu does for a Latin-equivalent `⌘`-shortcut.
/// Only events addressed to this very window are handled; everything else is
/// passed through untouched.
private struct NotepadSearchMonitor: NSViewRepresentable {
    var isShown: Bool
    var fieldFocused: Bool
    var onFind: () -> Void
    var onStep: (Int) -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isShown = isShown
        context.coordinator.fieldFocused = fieldFocused
        context.coordinator.onFind = onFind
        context.coordinator.onStep = onStep
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var isShown = false
        var fieldFocused = false
        var onFind: (() -> Void)?
        var onStep: ((Int) -> Void)?
        var onEscape: (() -> Void)?
        private weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // `MainActor.assumeIsolated`'s result must be `Sendable`, and
                // `NSEvent` is not: decide whether the event was consumed
                // (a `Bool`) inside the isolated closure, then return the
                // event itself, if at all, outside it.
                let consumed = MainActor.assumeIsolated {
                    self.handle(event)
                }
                return consumed ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        /// Whether the event was consumed (`⌘F`, `⌘G` / `⇧⌘G` while shown, or
        /// Esc while the field itself is focused), for this window alone.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window else { return false }
            let eventWindow = event.window ?? NSApp.keyWindow
            guard eventWindow === window, window.isKeyWindow else { return false }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch (event.keyCode, flags) {
            case (3, .command):
                onFind?()
                return true
            case (5, .command) where isShown:
                onStep?(1)
                return true
            case (5, [.command, .shift]) where isShown:
                onStep?(-1)
                return true
            case (53, []) where isShown && fieldFocused:
                onEscape?()
                return true
            default:
                return false
            }
        }
    }
}
