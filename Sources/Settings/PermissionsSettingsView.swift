import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var meeting: MeetingRecorder
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var models: ModelDownloader
    @EnvironmentObject private var dictation: DictationCoordinator
    @State private var isCheckingSystemAudio = false
    var gettingStarted = false

    var body: some View {
        VStack(spacing: SettingsChrome.groupSpacing) {
            // Getting Started numbers its cards as the README numbers its
            // steps. Only the model's step can be marked done: each permission
            // shows its own mark, and the rest are choices or a try, not tasks.
            if gettingStarted {
                // First: without a model neither dictation nor transcripts work.
                SettingsGroup(
                    "Recognition model",
                    step: 1,
                    done: ModelRow.isReady(settings.dictationEngine, models: models, dictation: dictation)
                ) { ModelRow() }
            }
            SettingsGroup("Permissions", step: gettingStarted ? 2 : nil) {
                permissionRow("Microphone", subtitle: "Without it, neither dictation nor meeting recording works", mark: permissions.micGranted ? .granted : .missing) { microphoneControl }
                divider
                permissionRow("Accessibility", subtitle: "Without it, text is not pasted by itself but stays on the clipboard — press ⌘V", mark: permissions.axTrusted ? .granted : .missing) { accessibilityControl }
                divider
                permissionRow("System audio recording", subtitle: "Recording the other voices needs a macOS permission. It is asked for at the first meeting recording", mark: systemAudioMark) { systemAudioControl }
            }
            if gettingStarted {
                SettingsGroup("Try dictation", step: 3) {
                    tryDictationRow
                }
                MeetingsSettingsView(automaticOnly: true, step: 4)
                // Last, next to automatic recording: both are on from the first
                // launch, and macOS's "Login Item Added" notice should find its
                // switch where the person is already looking.
                loginItemGroup
            } else {
                loginItemGroup
                SettingsGroup("Appearance") {
                    SettingsRow("Theme") {
                        Picker("", selection: $settings.appearance) {
                            Text("Match System").tag(AppAppearance.system)
                            Text("Light").tag(AppAppearance.light)
                            Text("Dark").tag(AppAppearance.dark)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("appearancePicker")
                    }
                }
                SettingsGroup("Updates") {
                    SettingsRow("Check automatically", subtitle: updatesStatus) {
                        Toggle("", isOn: $updater.automaticallyChecksForUpdates).labelsHidden()
                            .disabled(!updater.isRunning)
                    }
                    divider
                    SettingsRow(
                        "Version \(appVersion)",
                        subtitle: updater.installsAtQuit ? "The update will be installed when you quit the app" : nil
                    ) {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
                HStack(alignment: .top) {
                    Text("Microphone and Accessibility are checked every 3 seconds while something is missing. “Check…” for system audio only shows that macOS lets the app create an audio source; it does not confirm the permission to record.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Log in Finder") { AppLog.revealInFinder() }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
                .padding(.horizontal, SettingsChrome.groupTitleLeadingPadding)
            }
        }
    }

    /// A permission is granted or missing; the system audio check is neither,
    /// so it gets a neutral mark unless the check itself failed.
    private enum PermissionMark {
        case granted, missing, neutral

        var symbol: String {
            switch self {
            case .granted: "checkmark.circle.fill"
            case .missing: "exclamationmark.circle.fill"
            case .neutral: "circle.dashed"
            }
        }

        var color: Color {
            switch self {
            case .granted: .green
            case .missing: .orange
            case .neutral: .secondary
            }
        }
    }

    /// The gesture that really starts dictation: holding the shortcut in hold
    /// mode, the double press when it is chosen and usable, otherwise a press
    /// of the shortcut.
    @ViewBuilder private var tryDictationRow: some View {
        let doublePress = settings.hotkeyActivation == .doubleModifier && permissions.axTrusted
        let hint = dictationGestureHint(
            activation: settings.hotkeyActivation,
            modifier: settings.doubleTapModifier,
            shortcutDescription: settings.dictationShortcutDescription,
            doubleModifierAvailable: permissions.axTrusted
        )
        if settings.hotkeyActivation == .hold, let shortcut = settings.dictationShortcutDescription {
            SettingsRow(
                "Hold \(shortcut)",
                subtitle: "Open a text field, hold the keys and say a phrase, then release them. Without Accessibility, paste the text with ⌘V."
            ) { EmptyView() }
        } else if doublePress || settings.dictationShortcutDescription != nil {
            SettingsRow(
                "Press \(hint.start)",
                subtitle: "Open a text field, say a phrase, then press \(hint.stop) to finish. Without Accessibility, paste the text with ⌘V."
            ) { EmptyView() }
        } else {
            SettingsRow("Set a shortcut in the Dictation tab") { EmptyView() }
        }
    }

    private var systemAudioMark: PermissionMark {
        settings.systemAudioCheck?.succeeded == false ? .missing : .neutral
    }

    private func permissionRow<Control: View>(
        _ title: LocalizedStringKey, subtitle: LocalizedStringKey, mark: PermissionMark,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: SettingsChrome.compactSpacing) {
            Image(systemName: mark.symbol)
                .font(.system(size: SettingsChrome.permissionSymbolSize))
                .foregroundStyle(mark.color)
            VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }

    @ViewBuilder private var microphoneControl: some View {
        switch permissions.micStatus {
        case .authorized:
            Text("Granted").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("microphonePermissionGranted")
        case .notDetermined:
            Button("Grant…") { Task { await permissions.requestMicrophone() } }
        case .denied, .restricted:
            Button("Open System Settings…") { permissions.openMicrophoneSettings() }
        @unknown default:
            Button("Open System Settings…") { permissions.openMicrophoneSettings() }
        }
    }

    @ViewBuilder private var accessibilityControl: some View {
        if permissions.axTrusted {
            Text("Granted").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("accessibilityPermissionGranted")
        } else {
            Button("Grant…") { permissions.requestOrOpenAccessibility() }
                .accessibilityIdentifier("accessibilityPermissionAction")
        }
    }

    private var systemAudioControl: some View {
        VStack(alignment: .trailing, spacing: SettingsChrome.rowContentSpacing) {
            Text(systemAudioStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("systemAudioCheckStatus")
            Button(isCheckingSystemAudio ? "Checking…" : "Check…") {
                Task { await checkSystemAudio() }
            }
            .disabled(isCheckingSystemAudio || meeting.isBusy)
            .accessibilityIdentifier("checkSystemAudioButton")
        }
    }

    private var systemAudioStatus: String {
        if meeting.isBusy { return String(localized: "Can’t check while recording") }
        guard let check = settings.systemAudioCheck else { return String(localized: "Not checked") }
        let date = check.at.formatted(date: .abbreviated, time: .shortened)
        return check.succeeded
            ? String(localized: "Audio source created · \(date)")
            : String(localized: "Couldn’t create an audio source · \(date)")
    }

    private var loginItemGroup: some View {
        SettingsGroup("Startup", step: gettingStarted ? 5 : nil) {
            SettingsRow("Open at login", subtitle: loginItemStatus) {
                Toggle("", isOn: launchAtLogin).labelsHidden()
                    .accessibilityIdentifier("launchAtLoginToggle")
            }
            if loginItem.serviceStatus == .requiresApproval {
                divider
                Button("Open Login Items…") { loginItem.openSystemSettings() }
                    .padding(SettingsChrome.rowHorizontalPadding)
            }
        }
        // Back from System Settings: show what the person decided there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refreshStatus()
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { settings.launchAtLogin }, set: {
            settings.launchAtLogin = $0
            loginItem.reconcile(desired: $0)
        })
    }

    private var loginItemStatus: LocalizedStringKey {
        if !loginItem.isInstalledBundle { return "Install the app first; this build is temporary" }
        if let error = loginItem.errorMessage { return "Error: \(error)" }
        return switch loginItem.serviceStatus {
        case .notRegistered: "Actual status: off"
        case .enabled: "Actual status: on"
        case .requiresApproval: "Actual status: needs macOS approval"
        case .notFound: "Actual status: service not found"
        case nil: "Actual status: not checked"
        }
    }

    private var updatesStatus: LocalizedStringKey {
        switch updater.state {
        case .running:
            updater.automaticallyChecksForUpdates ? "Once a day" : "Off: only when you click the button below"
        case .failed(let reason):
            "Couldn’t start update checks: \(reason)"
        case .noKey:
            "Updates are off in this build: no key to check their signature"
        case .testCopy:
            "Updates are off in a test copy"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func checkSystemAudio() async {
        guard !meeting.isBusy, !isCheckingSystemAudio else { return }
        isCheckingSystemAudio = true
        let succeeded = await Task.detached(priority: .userInitiated) {
            SystemAudioCapture.canCreateProcessTap()
        }.value
        settings.systemAudioCheck = SystemAudioCheck(succeeded: succeeded, at: Date())
        isCheckingSystemAudio = false
    }

    private var divider: some View {
        Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
    }
}
