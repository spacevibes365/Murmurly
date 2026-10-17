import SwiftUI

/// The list refreshes when the query or the archive changes; SwiftUI cancels
/// the refresh for an outdated key and when the view goes away.
private struct HistoryRefreshKey: Equatable {
    let query: String
    let revision: UInt64
    let retry: Int
}

/// The count follows the archive and Try Again, not the search.
private struct HistorySummaryKey: Equatable {
    let revision: UInt64
    let retry: Int
}

private struct DictationHistoryDay: Identifiable {
    let date: Date
    let entries: [DictationHistoryEntry]

    var id: Date { date }
}

struct DictationHistoryView: View {
    @ObservedObject var dictation: DictationCoordinator
    @StateObject private var model: DictationHistoryViewModel
    @StateObject private var changes: DictationHistoryChanges
    @State private var pendingDeletion: DictationHistoryEntry?
    @State private var showingDeleteConfirmation = false
    @State private var showingClearConfirmation = false
    @State private var hoveredEntryID: UUID?
    @State private var selectedEntryID: UUID?
    /// The dictation a dictionary entry is being made from; in memory only.
    @State private var addingToDictionary: DictationHistoryEntry?
    /// The count for the current search only; without a search the total is shown.
    @State private var matchingCount: Int?
    /// Bumped by Try Again after a failed read: part of the refresh's identity.
    @State private var readRetry = 0
    /// The error the alert shows: taken from the model only while the
    /// section is shown, and let go only by OK, so a change of section with
    /// the alert up never closes it.
    @State private var shownError: String?
    private let store: DictationHistoryStore
    /// The main window shows this section: hidden, the sound stops and an
    /// error waits for it.
    let isShown: Bool
    /// The way to the Dictionary section, for an entry's sheet.
    let openDictionary: () -> Void

    init(
        dictation: DictationCoordinator,
        store: DictationHistoryStore = .shared,
        isShown: Bool,
        openDictionary: @escaping () -> Void
    ) {
        self.dictation = dictation
        self.store = store
        self.isShown = isShown
        self.openDictionary = openDictionary
        _model = StateObject(wrappedValue: DictationHistoryViewModel(store: store))
        // Before the first read: no change of the archive is missed.
        _changes = StateObject(wrappedValue: DictationHistoryChanges(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            Group {
                if model.entries.isEmpty, model.isLoading {
                    ProgressView("Reading history…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
        }
        .task(id: HistoryRefreshKey(query: model.searchText, revision: changes.revision, retry: readRetry)) {
            if !model.searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await model.reload()
            await refreshMatchingCount()
        }
        .task(id: HistorySummaryKey(revision: changes.revision, retry: readRetry)) {
            await model.refreshSummary()
        }
        .onChange(of: model.searchText) { matchingCount = nil }
        // Sections are only hidden, never closed: nothing would stop playback
        // in another one. The dictionary sheet stays over it with its draft
        // until Cancel or Save, as the Dictionary section's own does.
        .onChange(of: isShown) { _, shown in
            if shown { showErrorIfShown() } else { model.stopAudio() }
        }
        .onChange(of: model.errorMessage) { showErrorIfShown() }
        .onAppear { showErrorIfShown() }
        .sheet(item: $addingToDictionary) { entry in
            DictionaryEntrySheet(dictation: entry, openDictionary: openDictionary)
        }
        .onDisappear { model.stopAudio() }
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete(entry) {
                        selectedEntryID = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The text and its audio will be deleted for good.")
        }
        .confirmationDialog(
            "Clear the whole dictation history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task {
                    if await model.clearAll() {
                        selectedEntryID = nil
                        matchingCount = 0
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The whole archive and all dictation audio will be deleted.")
        }
        .alert("Error", isPresented: errorIsPresented) {
            Button("OK") { dismissError() }
        } message: {
            Text(shownError ?? String(localized: "Unknown error"))
        }
    }

    private var searchBar: some View {
        HStack(spacing: SettingsChrome.compactSpacing) {
            HStack(spacing: SettingsChrome.compactSpacing) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search dictation text", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("historySearchField")
            }
            .frame(maxWidth: .infinity)

            Text(resultCountText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("historyResultCount")

            let canClear = !model.isMutating && model.summary?.hasFiles == true
            Button {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            // A colour set here also covers the disabled look, so off is
            // dimmed by hand: otherwise the trash looks on with nothing to clear.
            .foregroundStyle(canClear ? HierarchicalShapeStyle.secondary : .tertiary)
            .help("Clear history")
            .disabled(!canClear)
            .accessibilityIdentifier("clearHistoryButton")
        }
        .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
        .padding(.vertical, SettingsChrome.historyToolbarVerticalPadding)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(daySections) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            historyRow(entry)
                        }
                    } header: {
                        dayHeader(day.date)
                    }
                }
                if let failure = model.readFailure {
                    readFailure(failure)
                        .padding(SettingsChrome.rowVerticalPadding)
                } else if model.canLoadMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(SettingsChrome.rowVerticalPadding)
                        .onAppear { Task { await model.loadMore() } }
                }
            }
            .padding(.horizontal, SettingsChrome.historyHorizontalPadding)
            .padding(.bottom, SettingsChrome.historyBottomPadding)
        }
    }

    private func dayHeader(_ date: Date) -> some View {
        Text(dayTitle(date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SettingsChrome.historyDayTopPadding)
            .padding(.horizontal, SettingsChrome.historyDayHorizontalPadding)
            .padding(.bottom, SettingsChrome.historyDayBottomPadding)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func historyRow(_ entry: DictationHistoryEntry) -> some View {
        let buttonsShown = hoveredEntryID == entry.id || selectedEntryID == entry.id
            || model.playingEntryID == entry.id
        return HStack(alignment: .top, spacing: SettingsChrome.historyRowSpacing) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .frame(width: SettingsChrome.historyTimeWidth, alignment: .leading)
            Text(entry.actualLanguage.uppercased())
                .font(.system(size: SettingsChrome.historyLanguageFontSize, weight: .semibold))
                .frame(width: SettingsChrome.historyLanguageWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                Text(entry.text.isEmpty
                     ? (entry.recognitionSkipped == true ? String(localized: "— not recognized: the app was quitting —")
                        : entry.recognitionFailed == true ? String(localized: "— not recognized —")
                        : String(localized: "— no speech recognized —"))
                     : entry.text)
                    .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                Text(verbatim: "\(applicationName(for: entry)) · \(durationText(entry.duration))"
                     + (entry.interrupted == true ? " · " + String(localized: "recording interrupted") : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            actionButtons(entry)
                .opacity(buttonsShown ? 1 : 0)
                .allowsHitTesting(buttonsShown)
                // Hidden buttons are no stops for the keyboard or VoiceOver:
                // the row's own actions reach the same things.
                .disabled(!buttonsShown)
                .accessibilityHidden(!buttonsShown)
        }
        .padding(.horizontal, SettingsChrome.historyRowHorizontalPadding)
        .padding(.vertical, SettingsChrome.historyRowVerticalPadding)
        .background(
            selectedEntryID == entry.id ? Color.accentColor.opacity(0.16) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardCornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { selectedEntryID = entry.id }
        .onHover { hovering in hoveredEntryID = hovering ? entry.id : nil }
        // Without a mouse over the row its buttons do not show; the context
        // menu and VoiceOver's actions offer them. The row stays a container:
        // its texts are separate elements, and tests find them by text.
        .contextMenu {
            rowActions(entry)
            if !model.isMutating {
                Divider()
                deleteAction(entry)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            rowActions(entry)
            if !model.isMutating { deleteAction(entry) }
        }
    }

    /// What applies to this entry; a context menu leaves out the rest rather
    /// than dimming it. Delete is apart, below a divider in the menu.
    @ViewBuilder private func rowActions(_ entry: DictationHistoryEntry) -> some View {
        if model.audioEntryIDs.contains(entry.id) {
            let playTitle: LocalizedStringKey = model.playingEntryID == entry.id ? "Stop Playback" : "Play Recording"
            Button(playTitle) { togglePlayback(entry) }
            Button("Show in Finder") { reveal(entry) }
        }
        if !entry.text.isEmpty {
            Button("Copy Text") { dictation.copyHistoryEntry(entry) }
            Button("Add to Dictionary…") { addingToDictionary = entry }
        }
    }

    /// Asks first, wherever it is chosen.
    private func deleteAction(_ entry: DictationHistoryEntry) -> some View {
        Button("Delete…", role: .destructive) { askToDelete(entry) }
    }

    private func togglePlayback(_ entry: DictationHistoryEntry) {
        Task { await model.play(entry) }
    }

    private func reveal(_ entry: DictationHistoryEntry) {
        Task { await model.revealAudio(entry) }
    }

    private func askToDelete(_ entry: DictationHistoryEntry) {
        pendingDeletion = entry
        showingDeleteConfirmation = true
    }

    private func actionButtons(_ entry: DictationHistoryEntry) -> some View {
        HStack(spacing: SettingsChrome.rowContentSpacing) {
            let isPlaying = model.playingEntryID == entry.id
            historyAction(
                isPlaying ? "stop.fill" : "play.fill",
                help: isPlaying ? "Stop playback" : "Play recording"
            ) {
                togglePlayback(entry)
            }
            .disabled(!model.audioEntryIDs.contains(entry.id))
            // An entry that was not recognized can be tried again in Files:
            // drag the file there from Finder.
            historyAction("folder", help: "Show in Finder") {
                reveal(entry)
            }
            .disabled(!model.audioEntryIDs.contains(entry.id))
            historyAction("doc.on.doc", help: "Copy text") {
                dictation.copyHistoryEntry(entry)
            }
            .disabled(entry.text.isEmpty)
            historyAction("trash", color: .red, help: "Delete recording") {
                askToDelete(entry)
            }
            .disabled(model.isMutating)
        }
    }

    private func historyAction(
        _ symbol: String,
        color: Color = .secondary,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(
                    width: SettingsChrome.historyActionSize,
                    height: SettingsChrome.historyActionSize
                )
                .background(color.opacity(symbol == "trash" ? 0.12 : 0.06))
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.chipCornerRadius))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// "Nothing found" only answers a search; an archive with nothing in it
    /// says so instead of asking to search again.
    private var emptyState: some View {
        VStack(spacing: SettingsChrome.rowContentSpacing) {
            if let failure = model.readFailure {
                readFailure(failure)
            } else if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No dictations yet").font(.headline)
                    .accessibilityIdentifier("historyEmpty")
            } else {
                Text("Nothing found").font(.headline)
                    .accessibilityIdentifier("historyNothingFound")
                Text("Try another search")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Couldn't read is not the same as nothing there: said in the tab, with
    /// a way to read again, which also counts the archive again.
    private func readFailure(_ failure: String) -> some View {
        VStack(spacing: SettingsChrome.rowContentSpacing) {
            Text(failure)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { readRetry += 1 }
            .accessibilityIdentifier("historyRetry")
        }
    }

    private var daySections: [DictationHistoryDay] {
        var sections: [DictationHistoryDay] = []
        for entry in model.entries {
            let day = Calendar.current.startOfDay(for: entry.at)
            if sections.last?.date == day {
                let previous = sections.removeLast()
                sections.append(.init(date: day, entries: previous.entries + [entry]))
            } else {
                sections.append(.init(date: day, entries: [entry]))
            }
        }
        return sections
    }

    /// Without a search every entry matches, so the total is read here, on
    /// every render. A copy of it made by the refresh task was the total at the
    /// task's start and could overwrite a newer one: "0 of 1" under "1 dictation".
    private var resultCountText: String {
        let searching = !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let totalCount = model.summary?.count else {
            return StorageSettingsView.pendingCountText(failed: model.summaryFailed)
        }
        guard let matching = searching ? matchingCount : totalCount else {
            return StorageSettingsView.pendingCountText(failed: model.readFailure != nil)
        }
        return String(localized: "\(matching) of \(totalCount)")
    }

    private func refreshMatchingCount() async {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            let count = try await store.count(matching: query)
            guard !Task.isCancelled else { return }
            matchingCount = count
        } catch is CancellationError {
            // A newer search owns the visible count.
        } catch {
            // An outdated count (newer search or archive revision) stays silent.
            guard !Task.isCancelled else { return }
            // The number from an earlier count of this search is not this one's.
            matchingCount = nil
            model.reportReadFailure(String(localized: "Couldn’t count the results: \(error.localizedDescription)"))
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let shortDate = date.formatted(.dateTime.day().month(.wide))
        if calendar.isDateInToday(date) { return String(localized: "Today, \(shortDate)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(shortDate)") }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    private func durationText(_ duration: TimeInterval) -> String {
        String(localized: "\(max(0, Int(duration.rounded()))) s", comment: "Dictation length in seconds")
    }

    private func applicationName(for entry: DictationHistoryEntry) -> String {
        entry.targetApplicationName ?? entry.targetBundleID ?? String(localized: "Unknown app")
    }

    /// Every section is built with the window, so the history is read
    /// whichever is shown; its error waits for Dictations instead of covering
    /// another section, and once up it stays until answered.
    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { shownError != nil },
            set: { if !$0 { dismissError() } }
        )
    }

    private func showErrorIfShown() {
        guard isShown, shownError == nil, let message = model.errorMessage else { return }
        shownError = message
    }

    private func dismissError() {
        shownError = nil
        model.errorMessage = nil
    }
}
