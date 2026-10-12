import SwiftUI
import AVFoundation

/// The menu-bar item's label: letter "M". Red + dot only when the required
/// microphone permission is missing. Accessibility is an optional auto-paste
/// enhancement; clipboard delivery remains functional without it.
/// Its `.task` registers the dictation hotkey at launch — the label renders at launch,
/// so the hotkeys are live even if no window is ever opened.
struct MenuBarLabel: View {
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject var meeting: MeetingRecorder
    @ObservedObject var permissions: PermissionManager
    let settings: SettingsStore
    let loginItem: LoginItemManager
    let files: FilesModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 1) {
            Text(verbatim: "M").bold()
                .foregroundStyle(permissions.needsAttention ? Color.red : Color.primary)
            if meeting.state == .recording {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            } else if permissions.needsAttention {
                Circle().fill(Color.red).frame(width: 5, height: 5)   // permission warning
            }
        }
        .task {
            // First: Getting Started may open below, and should open in the chosen look.
            appDelegate.followAppearance(of: settings)
            permissions.activate()
            dictation.activate(settings: settings, permissions: permissions)
            meeting.activate(
                settings: settings,
                permissions: permissions,
                dictation: dictation,
                showGettingStarted: {
                    settings.settingsTab = .gettingStarted
                    AppWindowController.enterRegular()
                    openWindow(id: "settings")
                }
            )
            loginItem.activate(desired: settings.launchAtLogin)
            appDelegate.attach(dictation: dictation, meeting: meeting, settings: settings)
            appDelegate.fileLosses = { files.quitLosses }
        }
    }
}

/// The dropdown shown when the menu-bar item is clicked.
struct DictationMenuView: View {
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject var meeting: MeetingRecorder
    @ObservedObject var meetingTranscripts: MeetingTranscriptionQueue
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var models: ModelDownloader
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        modelItems
        dictationStateLabel
        Picker("Dictation Engine", selection: $settings.dictationEngine) {
            ForEach(DictationEngine.allCases, id: \.self) { engine in
                Text(engine.title).tag(engine)
            }
        }
        // A hundred Whisper languages do not fit a menu: Auto, the current
        // choice, and the full list with search in Settings.
        Menu("Dictation Language") {
            Picker("Dictation Language", selection: $settings.pickedLanguage) {
                Text("Auto").tag("auto")
                if let current = settings.dictationEngine.languageChoices
                    .first(where: { $0.code == settings.pickedLanguage }) {
                    Text(current.name).tag(current.code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("More Languages…") {
                settings.settingsTab = .dictation
                openSettingsWindow()
            }
        }
        Menu("Dictation History") {
            if dictation.recentDictations.isEmpty {
                Text("No dictations yet")
            } else {
                ForEach(dictation.recentDictations) { entry in
                    Button(historyLabel(for: entry)) {
                        dictation.copyHistoryEntry(entry)
                    }
                    .disabled(entry.text.isEmpty)
                }
            }
            Divider()
            Button("Open Full History…") {
                settings.settingsTab = .history
                openSettingsWindow()
            }
        }
        if !dictation.unsavedDictations.isEmpty {
            Menu("Unsaved Dictations (\(dictation.unsavedDictations.count))") {
                Text("Available until you quit the app")
                if !dictation.quitBlockingIDs.isEmpty {
                    Text("“quit postponed”: saving is retried at the next quit")
                    Text("“Remove” on such a dictation lets you quit without saving it")
                }
                Divider()
                ForEach(dictation.unsavedDictations) { item in
                    Menu(unsavedLabel(for: item)) {
                        Button("Copy") { dictation.copyUnsavedDictation(item) }
                            .disabled(item.text.isEmpty)
                        Button("Show Audio in Finder") {
                            dictation.revealUnsavedDictationAudio(item)
                        }
                        .disabled(!FileManager.default.fileExists(atPath: item.sourceAudio.path))
                        Button("Remove") { dictation.removeUnsavedDictation(id: item.id) }
                    }
                }
            }
        }

        Divider()
        meetingStateLabel
        if let hint = meeting.state.failureHint {
            Text(hint)
        }
        Toggle("Record Meetings Automatically", isOn: $settings.autoRecordMeetings)
            .accessibilityIdentifier("menuAutoRecordMeetingsToggle")
        if let bundleID = meeting.automaticRecordingBundleID,
           !settings.meetingExcludedBundleIDs.contains(bundleID) {
            Button("Exclude \(MeetingsSettingsView.applicationName(bundleID)) from Auto-Recording") {
                settings.meetingExcludedBundleIDs.insert(bundleID)
            }
        }
        Button { meeting.toggle() } label: { meetingButtonLabel }
            .disabled(meetingButtonDisabled)
            .accessibilityIdentifier("meetingRecorderButton")
        if meeting.lastRecordingDirectory != nil {
            Button("Show Last Recording…") { meeting.revealLastRecording() }
        }
        Button("Show Meetings Folder") { showMeetingsFolder() }
        if let warning = meeting.recordingWarning {
            Menu {
                ForEach(Array(warning.issues.enumerated()), id: \.offset) { item in
                    Text(item.element)
                }
                Divider()
                Button("Show Meeting Folder…") { meeting.revealWarnedRecording() }
                Button("Hide Warning") { meeting.dismissRecordingWarning() }
            } label: {
                // The folder name already ends with " Meeting" and is never
                // translated.
                Label(warning.directory.lastPathComponent, systemImage: "exclamationmark.triangle.fill")
            }
        }
        if let unconfirmed = meeting.unconfirmedRecording {
            Text("Quit postponed: the meeting is not confirmed saved")
            Text(Self.menuLine(unconfirmed.reason))
            if unconfirmed.directory != nil {
                Button("Show Meeting Folder…") { meeting.revealUnconfirmedRecording() }
            }
            Button("Allow Quitting Without Confirmation") { meeting.releaseUnconfirmedRecording() }
        }
        meetingTranscriptItems

        if permissions.needsAttention || !permissions.axTrusted {
            Divider()
            if !permissions.micGranted {
                // .notDetermined → trigger the system prompt from this explicit click
                // (the reliable way to restore a never-asked/reset grant). .denied or
                // .restricted can't be re-prompted → send the user to Settings.
                if permissions.micStatus == .notDetermined {
                    Button {
                        // TCC won't reliably present a consent alert while the
                        // transient menu-bar popup is closing. Open a real window,
                        // wait until it becomes foreground, then request access.
                        openSettingsWindow()
                        Task { @MainActor in
                            await AppWindowController.waitUntilPermissionPromptCanBePresented()
                            await permissions.requestMicrophone()
                        }
                    } label: {
                        Label("Allow Microphone Access…", systemImage: "mic.fill")
                    }
                } else {
                    Button { permissions.openMicrophoneSettings() } label: {
                        Label("Microphone Access — Open System Settings…", systemImage: "exclamationmark.triangle.fill")
                    }
                }
            }
            if !permissions.axTrusted {
                Button(
                    permissions.accessibilityPromptAttempted
                        ? "Auto-Paste — Open System Settings…"
                        : "Auto-Paste — Request Access…"
                ) {
                    permissions.requestOrOpenAccessibility()
                }
                .accessibilityIdentifier("menuAccessibilityPermissionAction")
            }
        }

        Divider()
        Button("Transcribe a File…") {
            settings.settingsTab = .files
            openSettingsWindow()
        }
        if updater.installsAtQuit {
            Text("The update will be installed when you quit the app")
        }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        // Settings… stays third from the end: MenuBarExtra drops accessibility
        // identifiers, so the UI tests find it by that position.
        Button("Settings…") {
            openSettingsWindow()
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    /// On top while there is a model to get: nothing works without one.
    @ViewBuilder private var modelItems: some View {
        let engine = settings.dictationEngine
        let missing = models.missing(engine)
        if let download = models.download {
            Text("Downloading model \(download.engine.modelName): \(download.progressText)")
            Button("Cancel Download") { models.cancel() }
            Divider()
        } else if !missing.isEmpty {
            let size = ModelDownloader.sizeText(missing.reduce(0) { $0 + $1.bytes })
            Button("Download Model \(engine.modelName) (\(size))…") {
                models.start(engine)
                settings.settingsTab = .dictation
                openSettingsWindow()
            }
            Divider()
        }
    }

    @ViewBuilder private var meetingTranscriptItems: some View {
        if let status = meetingTranscripts.statusLabel {
            Text(status)
            if meetingTranscripts.isTranscribing {
                Button("Stop Transcription") { meetingTranscripts.cancelCurrent() }
            }
        }
        Button("Transcribe Meeting…") { meetingTranscripts.chooseFolder() }
        switch meetingTranscripts.lastOutcome {
        case .saved?:
            Button("Show Transcript") { meetingTranscripts.revealOutcome() }
        case .noSpeech(let folder)?:
            Text("Meeting \(folder.lastPathComponent): no speech found")
        case .cutShort(let transcript, let reason)?:
            Menu {
                Text(reason)
                Divider()
                Button("Show Transcript") { meetingTranscripts.revealOutcome() }
                Button("Hide Warning") { meetingTranscripts.dismissOutcome() }
            } label: {
                Label(
                    "Transcript of \(transcript.deletingLastPathComponent().lastPathComponent) Was Cut Short",
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
        case .failed(let folder, let reason)?:
            Menu {
                Text(reason)
                Divider()
                Button("Show Meeting Folder…") { meetingTranscripts.revealOutcome() }
                Button("Hide Warning") { meetingTranscripts.dismissOutcome() }
            } label: {
                Label("Transcription of \(folder.lastPathComponent) Failed", systemImage: "exclamationmark.triangle.fill")
            }
        case .cancelled?, nil:
            EmptyView()
        }
    }

    /// The chosen folder only when it is reachable: a network share is
    /// checked off the main actor, and an unreachable one sends the person to
    /// Storage, which says why, instead of opening something else.
    private func showMeetingsFolder() {
        guard let path = settings.meetingsFolderPath else {
            let root = RecordingsStore.meetingsRoot()
            // Before the first recording the local folder does not exist yet.
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        Task {
            let available = await Task.detached { MeetingStorage.isAvailable(folder) }.value
            if available {
                NSWorkspace.shared.open(folder)
            } else {
                settings.settingsTab = .storage
                openSettingsWindow()
            }
        }
    }

    private func openSettingsWindow() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")

            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first {
                    $0.identifier?.rawValue == "settings"
                }?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// A symbol goes through `Label`, which the menu shows as the item's
    /// image; an `Image` inside `Text` would land in the title instead.
    @ViewBuilder private var dictationStateLabel: some View {
        switch dictation.state {
        case .idle: Text(idleLabel)
        case .starting: Text("Dictation: starting…")
        case .recording:
            Label(
                String(localized: "Dictation: recording… (\(gestureHint.stop) to stop)"),
                systemImage: "record.circle.fill"
            )
        case .transcribing: Label("Dictation: recognizing…", systemImage: "hourglass")
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

    /// The engine is not named here: the picker below shows it.
    private var idleLabel: String {
        let readiness = DictationCoordinator.readiness(
            modelDownloaded: models.isReady(settings.dictationEngine),
            microphoneGranted: permissions.micGranted,
            modelState: dictation.modelState,
            modelFailure: dictation.modelFailure
        )
        switch readiness {
        case .needsModel: return String(localized: "Dictation: download a model first")
        case .modelFailed: return String(localized: "Dictation: the model couldn’t be prepared — see Settings")
        case .needsMicrophone: return String(localized: "Dictation: microphone access needed")
        case .preparing: return String(localized: "Dictation: preparing the model…")
        case .waitingForEngine: return String(localized: "Dictation: waiting for the engine…")
        case .notPrepared:
            return String(localized: "Dictation: model not prepared yet — the first dictation takes longer")
        case .ready where dictation.lastDictationHitLimit:
            return String(localized: "Dictation: the last one stopped at 5 minutes — start a new one")
        case .ready: return String(localized: "Dictation: ready — \(gestureHint.start)")
        }
    }

    private func historyLabel(for entry: DictationHistoryEntry) -> String {
        let timestamp = entry.at.formatted(date: .abbreviated, time: .shortened)
        let application = entry.targetApplicationName ?? entry.targetBundleID ?? String(localized: "Unknown app")
        let oneLine = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let empty = entry.recognitionSkipped == true ? String(localized: "— not recognized: the app was quitting —")
            : entry.recognitionFailed == true ? String(localized: "— not recognized —")
            : String(localized: "— no speech recognized —")
        let preview = oneLine.isEmpty ? empty : String(oneLine.prefix(72))
        let mark = entry.interrupted == true ? String(localized: "interrupted · ") : ""
        return "\(timestamp) · \(application) · \(mark)\(preview)"
    }

    private func unsavedLabel(for item: DictationCoordinator.UnsavedDictation) -> String {
        let timestamp = item.at.formatted(date: .abbreviated, time: .shortened)
        let oneLine = item.text.replacingOccurrences(of: "\n", with: " ")
        let preview = oneLine.isEmpty ? String(localized: "— no text —") : String(oneLine.prefix(72))
        let mark = dictation.quitBlockingIDs.contains(item.id) ? String(localized: "quit postponed · ") : ""
        return "\(timestamp) · \(mark)\(preview)"
    }

    /// A menu is as wide as its longest line, and a system error can run to a
    /// hundred characters ("… Core Audio 'unop' (1970171760)"): such a line is
    /// cut in the middle, keeping what failed at the start and the code at the
    /// end. The whole text is in the log.
    static func menuLine(_ line: String, limit: Int = 72) -> String {
        guard line.count > limit else { return line }
        let head = (limit - 1) / 2
        return String(line.prefix(head)) + "…" + String(line.suffix(limit - 1 - head))
    }

    @ViewBuilder private var meetingStateLabel: some View {
        switch meeting.state {
        case .idle: Text("Meeting: ready")
        case .starting: Text("Meeting: requesting system audio…")
        case .recording:
            Label("Meeting: recording system audio + microphone", systemImage: "record.circle.fill")
        case .stopping: Text("Meeting: saving…")
        case let .failed(message, _):
            Label(
                Self.menuLine(String(localized: "Meeting recording failed: \(message)")),
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    /// The shortcut is appended to the translated title, never to the key.
    @ViewBuilder private var meetingButtonLabel: some View {
        switch meeting.state {
        case .recording:
            Label(String(localized: "Stop Recording Meeting") + meetingShortcutSuffix, systemImage: "stop.fill")
        case .idle, .failed:
            Label(String(localized: "Record Meeting") + meetingShortcutSuffix, systemImage: "record.circle")
        case .starting: Text("Starting Recording…")
        case .stopping: Text("Saving Recording…")
        }
    }

    private var meetingShortcutSuffix: String {
        settings.meetingShortcutDescription.map { "  \($0)" } ?? ""
    }

    private var meetingButtonDisabled: Bool {
        switch meeting.state {
        case .idle, .failed, .recording: return false
        case .starting, .stopping: return true
        }
    }

}
