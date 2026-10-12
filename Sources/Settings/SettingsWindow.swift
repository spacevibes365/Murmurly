import SwiftUI

struct SettingsWindow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var meetingTranscripts: MeetingTranscriptionQueue
    @EnvironmentObject private var models: ModelDownloader
    @State private var searchText = ""
    @State private var archiveSnapshot: ArchiveSnapshot?
    /// Why the last count failed, until a count succeeds; in memory only.
    @State private var archiveFailure: String?
    /// Bumped by Try Again and Move Now: part of the refresh's identity, so
    /// the same task runs again.
    @State private var archiveRetry = 0
    /// Created before the first snapshot read, so no archive change is missed.
    @StateObject private var historyChanges = DictationHistoryChanges(store: .shared)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: SettingsChrome.windowWidth, height: SettingsChrome.windowHeight)
        .background(SettingsWindowConfigurator())
        .onAppear {
            permissions.refresh()
            loginItem.reconcile(desired: settings.launchAtLogin)
        }
        // A newer revision cancels an outdated snapshot read; a finished
        // meeting job (a compression, a move), another folder or a retry
        // counts again.
        .task(id: ArchiveRefresh(
            history: historyChanges.revision,
            meetingJobs: meetingTranscripts.finishedJobs,
            meetingsFolder: settings.meetingsFolderPath,
            transcriptsFolder: settings.transcriptsFolderPath,
            retry: archiveRetry
        )) {
            await refreshArchiveSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheckChosenFolders()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            recheckChosenFolders()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            recheckChosenFolders()
        }
    }

    /// A chosen folder can come back or go away while the window stays open,
    /// with nothing else to count again: checked when the app comes back and
    /// when a disk comes or goes, so "Show in Finder" follows it.
    private func recheckChosenFolders() {
        guard settings.meetingsFolderPath != nil || settings.transcriptsFolderPath != nil else { return }
        archiveRetry += 1
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: SettingsChrome.sidebarTopInset)
            HStack(spacing: SettingsChrome.compactSpacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settingsSidebarSearch")
            }
            .padding(.horizontal, SettingsChrome.sidebarHorizontalPadding)
            .padding(.bottom, SettingsChrome.sidebarSearchBottomPadding)

            if visibleTabs.isEmpty {
                Text("Nothing found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, SettingsChrome.rowVerticalPadding)
            } else {
                VStack(spacing: SettingsChrome.sidebarItemSpacing) {
                    ForEach(visibleTabs, id: \.rawValue) { tab in
                        Button { settings.settingsTab = tab } label: {
                            sidebarRow(tab)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settingsTab.\(tab.rawValue)")
                    }
                }
                .padding(.horizontal, SettingsChrome.sidebarItemHorizontalPadding)
            }
            Spacer()
            Divider()
            HStack(spacing: SettingsChrome.compactSpacing) {
                SettingsStatusDot(color: footerColor)
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, SettingsChrome.footerHorizontalPadding)
            .padding(.vertical, SettingsChrome.footerVerticalPadding)
        }
        .frame(width: SettingsChrome.sidebarWidth)
        .background(.ultraThinMaterial)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tabMetadata(settings.settingsTab).title)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("settingsWindowContent")
                Spacer()
                Text(headerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SettingsChrome.headerHorizontalPadding)
            .frame(height: SettingsChrome.headerHeight)
            Divider()
            ZStack {
                tabLayer(.gettingStarted) {
                    standardContent { PermissionsSettingsView(gettingStarted: true) }
                }
                tabLayer(.dictation) {
                    standardContent {
                        DictationSettingsView()
                    }
                }
                tabLayer(.meetings) { standardContent { MeetingsSettingsView() } }
                tabLayer(.history) {
                    DictationHistoryView(
                        dictation: dictation,
                        totalCount: archiveSnapshot?.dictationCount,
                        countFailed: archiveFailure != nil,
                        archiveHasFiles: archiveSnapshot?.hasDictationFiles ?? false,
                        recount: {
                            archiveFailure = nil
                            archiveRetry += 1
                        }
                    )
                }
                tabLayer(.storage) {
                    standardContent {
                        StorageSettingsView(
                            snapshot: archiveSnapshot,
                            failure: archiveFailure,
                            recount: {
                                archiveFailure = nil
                                archiveRetry += 1
                            },
                            meetings: meetingTranscripts
                        )
                    }
                }
                tabLayer(.permissions) { standardContent { PermissionsSettingsView() } }
                tabLayer(.files) { ContentView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func standardContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(.top, SettingsChrome.contentTopPadding)
                .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
                .padding(.bottom, SettingsChrome.contentBottomPadding)
        }
        // A tab taller than the window shows its scroll bar for a moment, so
        // the cards below the edge are not taken for missing. Every tab is
        // built with the window and only hidden, so onAppear covers just the
        // window opening; a switch of tabs needs the trigger.
        .scrollIndicatorsFlash(onAppear: true)
        .scrollIndicatorsFlash(trigger: settings.settingsTab)
    }

    private func tabLayer<Content: View>(
        _ tab: SettingsTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let selected = settings.settingsTab == tab
        return content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settingsContent.\(tab.rawValue)")
            .accessibilityHidden(!selected)
            .zIndex(selected ? 1 : 0)
    }

    private var visibleTabs: [SettingsTab] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            let metadata = tabMetadata($0)
            return (metadata.title + " " + metadata.search)
                .localizedCaseInsensitiveContains(needle)
        }
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        HStack(spacing: SettingsChrome.compactSpacing) {
            Image(systemName: tabMetadata(tab).symbol)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: SettingsChrome.chipSize, height: SettingsChrome.chipSize)
                .background(tabMetadata(tab).color)
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.chipCornerRadius))
            Text(tabMetadata(tab).title)
            Spacer()
            if tab == .permissions,
               permissions.needsAttention || !permissions.axTrusted
                || settings.systemAudioCheck?.succeeded == false {
                Circle().fill(.orange)
                    .frame(
                        width: SettingsChrome.permissionAttentionSize,
                        height: SettingsChrome.permissionAttentionSize
                    )
            }
        }
        .padding(.horizontal, SettingsChrome.sidebarItemHorizontalPadding)
        .padding(.vertical, SettingsChrome.sidebarItemVerticalPadding)
        .background(settings.settingsTab == tab ? Color.primary.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.sidebarItemCornerRadius))
        .contentShape(
            RoundedRectangle(cornerRadius: SettingsChrome.sidebarItemCornerRadius)
        )
    }

    private var headerHint: String {
        switch settings.settingsTab {
        case .dictation:
            return "\(gestureHint.start) · \(languageName)"
        case .permissions:
            // The system audio check is not a permission status, so it is
            // not counted here; a failed check shows on its own row.
            let missing = (permissions.micGranted ? 0 : 1)
                + (permissions.axTrusted ? 0 : 1)
            return missing == 0 ? String(localized: "Main permissions granted") : String(localized: "\(missing) not granted")
        case .meetings:
            return String(localized: "\(settings.meetingExcludedBundleIDs.count) excluded")
        case .history:
            guard let archiveSnapshot else {
                return StorageSettingsView.pendingCountText(failed: archiveFailure != nil)
            }
            return String(localized: "\(archiveSnapshot.dictationCount) dictations")
        case .storage:
            return archiveSnapshot.map { StorageSettingsView.byteText($0.totalBytes) }
                ?? StorageSettingsView.pendingCountText(failed: archiveFailure != nil)
        case .files:
            // Files transcribes with the dictation engine and language.
            return "\(settings.dictationEngine.title) · \(languageName)"
        case .gettingStarted:
            return String(localized: "Speech is recognized on this Mac")
        }
    }

    /// A code the engine does not know shows as Auto, which is what the
    /// engine is then asked for.
    private var languageName: String {
        settings.dictationEngine.languageChoices
            .first { $0.code == settings.pickedLanguage }?.name ?? String(localized: "Auto")
    }

    /// The same answer the menu gives: "Ready" only once the model is ready.
    private var readiness: DictationCoordinator.Readiness {
        DictationCoordinator.readiness(
            modelDownloaded: models.isReady(settings.dictationEngine),
            microphoneGranted: permissions.micGranted,
            modelState: dictation.modelState,
            modelFailure: dictation.modelFailure
        )
    }

    private var footerText: String {
        switch dictation.state {
        case .starting: return String(localized: "Starting the microphone…")
        case .recording: return String(localized: "Recording · \(gestureHint.stop)")
        case .transcribing: return String(localized: "Recognizing…")
        case .idle:
            switch readiness {
            case .needsModel: return String(localized: "Model not downloaded")
            case .modelFailed: return String(localized: "Model couldn’t be prepared")
            case .needsMicrophone: return String(localized: "Microphone not allowed")
            case .preparing: return String(localized: "Preparing model…")
            case .waitingForEngine: return String(localized: "Waiting for engine…")
            case .notPrepared: return String(localized: "Model not prepared yet")
            case .ready: return String(localized: "Ready · \(gestureHint.start)")
            }
        }
    }

    private var gestureHint: DictationGestureHint {
        dictationGestureHint(
            activation: settings.hotkeyActivation,
            modifier: settings.doubleTapModifier,
            shortcutDescription: settings.dictationShortcutDescription,
            doubleModifierAvailable: permissions.axTrusted
        )
    }

    private var footerColor: Color {
        switch dictation.state {
        case .recording: return .red
        case .starting, .transcribing: return .orange
        case .idle:
            switch readiness {
            case .needsModel, .modelFailed, .needsMicrophone: return .red
            case .preparing, .waitingForEngine, .notPrepared: return .orange
            case .ready: return .green
            }
        }
    }

    /// The search words are translated with the title: the user searches in
    /// the language the window speaks.
    private func tabMetadata(
        _ tab: SettingsTab
    ) -> (title: String, search: String, symbol: String, color: Color) {
        switch tab {
        case .gettingStarted: (
            String(localized: "Getting Started"),
            String(localized: "start setup first launch", comment: "Search words for the Getting Started tab"),
            "checklist", .green
        )
        case .dictation: (
            String(localized: "Dictation"),
            String(localized: "hotkey recognition text feedback", comment: "Search words for the Dictation tab"),
            "mic.fill", .blue
        )
        case .meetings: (
            String(localized: "Meetings"),
            String(localized: "recording exclusions apps microphone", comment: "Search words for the Meetings tab"),
            "waveform.and.mic", .red
        )
        case .history: (
            String(localized: "History"),
            String(localized: "archive search dictations", comment: "Search words for the History tab"),
            "clock.arrow.circlepath", .orange
        )
        case .storage: (
            String(localized: "Storage"),
            String(localized: "space folder size move", comment: "Search words for the Storage tab"),
            "externaldrive.fill", .gray
        )
        case .permissions: (
            String(localized: "Permissions"),
            String(
                localized: "microphone accessibility system audio launch at login log updates version appearance theme light dark",
                comment: "Search words for the Permissions tab"
            ),
            "hand.raised.fill", .indigo
        )
        case .files: (
            String(localized: "Files"),
            String(localized: "audio video transcription transcript", comment: "Search words for the Files tab"),
            "waveform.badge.magnifyingglass", .purple
        )
        }
    }

    /// A failure stays on screen with the last figures until a count
    /// succeeds; a cancelled refresh changes neither.
    private func refreshArchiveSnapshot() async {
        let history: (count: Int, oldest: Date?)
        do {
            history = try await DictationHistoryStore.shared.historySummary()
        } catch is CancellationError {
            // Closing Settings cancels its read without changing the last snapshot.
            return
        } catch {
            AppLog.error("settings", "archive scan failed: \(error.localizedDescription)")
            guard !Task.isCancelled else { return }
            archiveFailure = error.localizedDescription
            return
        }
        let destinations = settings.meetingDestinations
        await ArchiveSnapshot.refresh(
            history: history,
            meetingsFolder: destinations.meetings,
            transcriptsFolder: destinations.transcripts,
            previous: archiveSnapshot
        ) { snapshot in
            archiveSnapshot = snapshot
            archiveFailure = nil
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWhenAttached(view)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let size = NSSize(
                width: SettingsChrome.windowWidth,
                height: SettingsChrome.windowHeight
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.contentMinSize = size
            window.contentMaxSize = size
            window.setContentSize(size)
        }
    }
}

/// What the storage snapshot depends on besides the files themselves.
private struct ArchiveRefresh: Equatable {
    let history: UInt64
    let meetingJobs: Int
    let meetingsFolder: String?
    let transcriptsFolder: String?
    let retry: Int
}
