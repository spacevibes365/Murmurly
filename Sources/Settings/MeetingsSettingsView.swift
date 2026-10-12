import AppKit
import KeyboardShortcuts
import SwiftUI

struct MeetingsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    var automaticOnly = false
    /// Its number among the Getting Started steps.
    var step: Int?

    var body: some View {
        VStack(spacing: SettingsChrome.groupSpacing) {
            automaticRecording
            if !automaticOnly {
                SettingsGroup("Hotkey") {
                    SettingsRow("Start or stop recording a meeting") {
                        KeyboardShortcuts.Recorder(for: .meeting) { _ in
                            settings.objectWillChange.send()
                        }
                        .accessibilityIdentifier("meetingShortcutRecorder")
                    }
                }
                SettingsGroup("Auto-recording exclusions") {
                    if settings.meetingExcludedBundleIDs.isEmpty {
                        SettingsRow("No exclusions", subtitle: "Add an app from the menu while it is being auto-recorded") {
                            EmptyView()
                        }
                    }
                    ForEach(settings.meetingExcludedBundleIDs.sorted(), id: \.self) { bundleID in
                        SettingsRow("\(Self.applicationName(bundleID))", subtitle: "\(bundleID)") {
                            Button("Remove") { settings.meetingExcludedBundleIDs.remove(bundleID) }
                        }
                    }
                }
                SettingsGroup("After a recording stops") {
                    MeetingRadioRow(
                        title: "Nothing — just keep the audio",
                        selected: settings.meetingAfterStop == .nothing
                    ) { settings.meetingAfterStop = .nothing }
                    .accessibilityIdentifier("meetingAfterStopNothing")
                    Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
                    MeetingRadioRow(
                        title: "Transcribe",
                        subtitle: "transcript.md appears in the recording’s folder; dictation keeps working meanwhile",
                        selected: settings.meetingAfterStop == .transcribe
                    ) { settings.meetingAfterStop = .transcribe }
                    .accessibilityIdentifier("meetingAfterStopTranscribe")
                }
            }
        }
    }

    // Reused by Getting Started so the warning and the switch cannot diverge.
    private var automaticRecording: some View {
        SettingsGroup("Automatic recording", step: step) {
            SettingsRow("Record meetings automatically") {
                Toggle("", isOn: $settings.autoRecordMeetings)
                    .labelsHidden()
                    .accessibilityIdentifier("autoRecordMeetingsToggle")
            }
            Text("Recording starts when another app takes the microphone. Your microphone and all system audio are saved, including the sound of excluded apps. Many countries require the participants’ consent — tell them before recording.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
            if !automaticOnly {
                Group {
                    Text("An automatic recording stops 30 seconds after no other app is using the microphone, and after 4 hours at the latest. A recording you start yourself has no limit.")
                    Text("macOS asks for permission to record system audio the first time. If a recording doesn’t start, the “M” menu says why — start it with Record Meeting.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                .padding(.top, SettingsChrome.compactSpacing)
            }
            Text("Recordings: \(settings.meetingsFolderPath ?? RecordingsStore.meetingsRoot().path)")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                .padding(.vertical, SettingsChrome.rowVerticalPadding)
        }
    }

    static func applicationName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // A daemon or an extension has no app to name; its bundle ID alone
            // reads like a typo, so at least say it is part of macOS.
            return bundleID.hasPrefix("com.apple.")
                ? String(localized: "macOS process \(bundleID)") : bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

private struct MeetingRadioRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsChrome.compactSpacing) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }
}
