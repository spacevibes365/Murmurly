import AppKit
import SwiftUI

/// What an agent (`a2`, the `murmurly` helper) may read: the "Meetings" and
/// "Dictations" switches gate `agents.meetings` / `agents.dictations`, and
/// the period gates `agents.periodDays` — the same keys the helper reads
/// fresh on every call (`HelperContract.SettingsKey`). This view only writes
/// the switches and the period; it never runs the helper and never touches a
/// real archive.
struct AgentsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var connections = AgentConnections.live()

    var body: some View {
        VStack(spacing: SettingsChrome.groupSpacing) {
            SettingsGroup("What agents can read") {
                SettingsRow("Meetings", subtitle: "Transcripts and meeting titles") {
                    Toggle("", isOn: $settings.agentsMeetings)
                        .labelsHidden()
                        .accessibilityIdentifier("agentsMeetingsToggle")
                }
                divider
                SettingsRow("Dictations", subtitle: "Dictation text, without audio") {
                    Toggle("", isOn: $settings.agentsDictations)
                        .labelsHidden()
                        .accessibilityIdentifier("agentsDictationsToggle")
                }
                divider
                SettingsRow("Period") {
                    Picker("", selection: $settings.agentsPeriodDays) {
                        Text("All history").tag(0)
                        Text("Last 30 days").tag(30)
                        Text("Last 90 days").tag(90)
                        Text("Last 365 days").tag(365)
                    }
                    .labelsHidden()
                    .frame(minWidth: SettingsChrome.popupMinWidth)
                    .accessibilityIdentifier("agentsPeriodPicker")
                }
            }
            Text("Murmurly doesn’t send your meetings or dictations anywhere. An agent you allow sends what it reads to its own cloud model. These switches are your consent, not a lock: any program running under your account can read the files directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agentsConsentNote")

            SettingsGroup("Connect") {
                SettingsRow("Claude Code") { clientControl(for: .claudeCode) }
                divider
                SettingsRow("Codex") { clientControl(for: .codex) }
                divider
                SettingsRow("Command in Terminal") { terminalControl }
            }
            if let terminalInstallError = connections.terminalInstallError {
                Text(terminalInstallError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(connectNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { connections.refreshTerminalLinkStatus() }
        .onChange(of: settings.settingsTab) { _, tab in
            if tab == .agents { connections.refreshTerminalLinkStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connections.refreshTerminalLinkStatus()
        }
    }

    @ViewBuilder private func clientControl(for kind: AgentClientKind) -> some View {
        let status = connections.status(for: kind)
        VStack(alignment: .trailing, spacing: SettingsChrome.compactSpacing) {
            Text(statusText(status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220, alignment: .trailing)
                .accessibilityIdentifier(statusIdentifier(for: kind))
            HStack(spacing: SettingsChrome.compactSpacing) {
                if showsCopyCommandButton(status) {
                    Button("Copy Command") { connections.copyConnectCommand(for: kind) }
                        .accessibilityIdentifier(copyIdentifier(for: kind))
                }
                if status == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(connectButtonTitle(for: kind, status: status)) {
                        Task { await connections.connect(kind) }
                    }
                    .disabled(connectDisabled(for: kind))
                    .accessibilityIdentifier(connectIdentifier(for: kind))
                }
            }
        }
    }

    @ViewBuilder private var terminalControl: some View {
        VStack(alignment: .trailing, spacing: SettingsChrome.compactSpacing) {
            Text(terminalStatusText(connections.terminalLinkStatus))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220, alignment: .trailing)
                .accessibilityIdentifier("agentsTerminalStatus")
            HStack(spacing: SettingsChrome.compactSpacing) {
                if showsCopyTerminalCommandButton {
                    Button("Copy Command") { connections.copyTerminalCommand() }
                        .accessibilityIdentifier("agentsCopyTerminalCommandButton")
                }
                if connections.isInstallingTerminalCommand {
                    ProgressView().controlSize(.small)
                } else {
                    Button(terminalButtonTitle) {
                        Task { await connections.installTerminalCommand() }
                    }
                    .disabled(terminalButtonDisabled)
                    .accessibilityIdentifier("agentsInstallCommandButton")
                }
            }
        }
    }

    // MARK: - Text and gating, by status

    private func statusText(_ status: AgentConnections.ClientStatus) -> LocalizedStringKey {
        switch status {
        case .notConnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .outdated: return "Out of date: Murmurly has moved or was updated"
        case .clientNotFound:
            return "Not found in the usual places. Install it, or copy the command and run it in Terminal."
        case .verificationFailed:
            return "The command ran, but the check didn’t find Murmurly among the servers."
        case .timedOut: return "Took too long and was stopped."
        case .failed(let reason): return "Couldn’t connect: \(reason)"
        }
    }

    private func connectButtonTitle(for kind: AgentClientKind, status: AgentConnections.ClientStatus) -> LocalizedStringKey {
        if case .outdated = status { return "Update Connection" }
        switch kind {
        case .claudeCode: return "Connect to Claude Code"
        case .codex: return "Connect to Codex"
        }
    }

    private func connectDisabled(for kind: AgentClientKind) -> Bool {
        !connections.isInstalledCopy || connections.helperPath == nil || connections.status(for: kind) == .connecting
    }

    private func showsCopyCommandButton(_ status: AgentConnections.ClientStatus) -> Bool {
        switch status {
        case .clientNotFound, .timedOut, .verificationFailed, .failed: return true
        case .notConnected, .connecting, .connected, .outdated: return false
        }
    }

    private func statusIdentifier(for kind: AgentClientKind) -> String {
        kind == .claudeCode ? "agentsClaudeStatus" : "agentsCodexStatus"
    }

    private func connectIdentifier(for kind: AgentClientKind) -> String {
        kind == .claudeCode ? "agentsConnectClaudeButton" : "agentsConnectCodexButton"
    }

    private func copyIdentifier(for kind: AgentClientKind) -> String {
        kind == .claudeCode ? "agentsCopyClaudeCommandButton" : "agentsCopyCodexCommandButton"
    }

    private func terminalStatusText(_ status: TerminalLinkStatus) -> LocalizedStringKey {
        switch status {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed: murmurly works in any new terminal window"
        case .outdated: return "Out of date: points to another copy of Murmurly"
        case .foreign:
            return "Another file is already at /usr/local/bin/murmurly. Murmurly leaves it alone: remove or rename it, then try again."
        case .unreadable(let reason): return "Can’t read /usr/local/bin/murmurly: \(reason)"
        }
    }

    private var terminalButtonTitle: LocalizedStringKey {
        if case .outdated = connections.terminalLinkStatus { return "Update Command" }
        return "Install Command in Terminal"
    }

    private var terminalButtonDisabled: Bool {
        guard connections.isInstalledCopy, connections.helperPath != nil, !connections.isInstallingTerminalCommand
        else { return true }
        switch connections.terminalLinkStatus {
        case .installed, .foreign, .unreadable: return true
        case .notInstalled, .outdated: return false
        }
    }

    private var showsCopyTerminalCommandButton: Bool {
        TerminalCommandInstaller.showsCopyCommand(
            status: connections.terminalLinkStatus,
            hasInstallError: connections.terminalInstallError != nil
        )
    }

    private var connectNote: LocalizedStringKey {
        guard connections.isInstalledCopy else {
            return "Move Murmurly to Applications to connect agents: the connection points to this copy of the app."
        }
        guard connections.helperPath != nil else {
            return "Murmurly’s command-line helper is missing from this copy of the app."
        }
        return "Claude Code and Codex start murmurly from this copy of Murmurly. If you move the app, update the connection."
    }

    private var divider: some View {
        Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
    }
}
