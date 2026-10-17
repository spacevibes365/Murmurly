import AppKit
import KeyboardShortcuts
import SwiftUI

struct MeetingsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var meetingTranscripts: MeetingTranscriptionQueue
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
                audioRule
            }
        }
        .sheet(item: Binding(
            get: { automaticOnly ? nil : meetingTranscripts.audioQuestion },
            set: { if $0 == nil { meetingTranscripts.cancelAudioQuestion() } }
        )) { question in
            AudioRuleQuestion(question: question)
        }
    }

    /// Keep a meeting's audio, or delete it some days after its full
    /// transcription. A choice that deletes is asked about first, always;
    /// the setting changes only on yes.
    private var audioRule: some View {
        SettingsGroup("Meeting audio") {
            ForEach(MeetingAudioRetention.allCases, id: \.self) { choice in
                if choice != .keep { Divider().padding(.leading, SettingsChrome.dividerLeadingPadding) }
                MeetingRadioRow(
                    title: Self.title(of: choice),
                    selected: settings.meetingAudioRetention == choice
                ) {
                    guard choice != settings.meetingAudioRetention else { return }
                    meetingTranscripts.askAudioRetention(days: choice.rawValue)
                }
                .accessibilityIdentifier("meetingAudioRule.\(choice.rawValue)")
            }
            Group {
                if let days = meetingTranscripts.countingAudioRule {
                    Text("Counting what goes after \(days) days…")
                }
                Text("Only the audio of meetings transcribed in full goes, never a starred meeting’s, and for good, not to the Trash. Transcripts, names and stars stay.")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
            .padding(.vertical, SettingsChrome.rowVerticalPadding)
        }
    }

    private static func title(of choice: MeetingAudioRetention) -> LocalizedStringKey {
        switch choice {
        case .keep: "Keep"
        case .week: "Delete 7 days after a full transcription"
        case .month: "Delete 30 days after a full transcription"
        case .quarter: "Delete 90 days after a full transcription"
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
        return FileManager.default.displayName(atPath: outermostApplication(url).path)
    }

    /// A helper that holds the microphone lives inside its app's bundle
    /// (Arc's, Chrome's): the outermost `.app` on its path is the app the
    /// user knows.
    static func outermostApplication(_ url: URL) -> URL {
        var outermost = url
        var current = url
        while current.pathComponents.count > 1 {
            if current.pathExtension == "app" { outermost = current }
            current = current.deletingLastPathComponent()
        }
        return outermost
    }
}

/// What a rule that deletes would delete now, asked before it is set.
private struct AudioRuleQuestion: View {
    @EnvironmentObject private var meetingTranscripts: MeetingTranscriptionQueue
    let question: MeetingTranscriptionQueue.AudioQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.candidates.isEmpty
                ? String(localized: "Nothing goes now. From now on a meeting’s audio is deleted \(question.days) days after its full transcription. Turn this on?")
                : String(localized: "The audio of \(question.candidates.count) meetings goes now — for good, not to the Trash. Continue?"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !question.candidates.isEmpty {
                Text("Total: \(ByteCountFormatter.string(fromByteCount: question.bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
            if !question.complete {
                Label("Not every meeting could be counted now: those not counted go by this rule once they can be read.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { meetingTranscripts.answerAudioQuestion(question, accepted: false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("audioRuleCancel")
                Button("Continue") { meetingTranscripts.answerAudioQuestion(question, accepted: true) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("audioRuleContinue")
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioRuleQuestion")
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
