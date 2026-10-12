import Foundation
import KeyboardShortcuts
import SwiftUI

enum IndicatorState: Equatable, Sendable {
    enum VisualKind: Equatable, Sendable {
        case amberBars
        case blueBars
        case recording
        case success
        case failure
        case notice
    }

    case loadingModel
    case waitingEngine
    case finishingRecording
    case recognizing
    /// `endsAt`: when the length limit stops it.
    case recordingDictation(startedAt: Date, endsAt: Date)
    case recordingMeeting(startedAt: Date, automatic: Bool)
    case savingMeeting
    case inserted(characterCount: Int)
    case meetingSaved
    case meetingSavedSuspect
    case meetingSavedPartially
    case noSpeech
    case clipboardFallback
    case clipboardFailed
    case injectionFailed
    case microphoneTimedOut
    case microphoneAccessUndetermined
    case microphoneAccessDenied
    case meetingMicrophoneAccessDenied
    case busyWithDictation
    case busyWithMeeting
    case dictationFailure(message: String)
    case meetingFailure(message: String)

    var visualKind: VisualKind {
        switch self {
        case .loadingModel, .waitingEngine:
            return .amberBars
        case .finishingRecording, .recognizing, .savingMeeting:
            return .blueBars
        case .recordingDictation, .recordingMeeting:
            return .recording
        case .inserted, .meetingSaved:
            return .success
        case .meetingSavedSuspect, .meetingSavedPartially, .clipboardFailed,
             .injectionFailed, .microphoneTimedOut, .microphoneAccessUndetermined,
             .microphoneAccessDenied, .meetingMicrophoneAccessDenied,
             .dictationFailure, .meetingFailure:
            return .failure
        case .noSpeech, .clipboardFallback, .busyWithDictation, .busyWithMeeting:
            return .notice
        }
    }

    var autoHide: TimeInterval? {
        switch self {
        case .loadingModel, .waitingEngine, .finishingRecording, .recognizing,
             .recordingDictation, .recordingMeeting, .savingMeeting:
            return nil
        case .inserted, .noSpeech:
            return 1.5
        case .busyWithDictation, .busyWithMeeting:
            return 2.5
        case .meetingMicrophoneAccessDenied, .clipboardFallback, .clipboardFailed,
             .injectionFailed, .microphoneTimedOut, .dictationFailure:
            return 3
        case .microphoneAccessUndetermined, .microphoneAccessDenied:
            return 3.5
        case .meetingSaved:
            return 4
        case .meetingSavedPartially, .meetingFailure:
            return 5
        case .meetingSavedSuspect:
            return 6
        }
    }

    var isConflictFlash: Bool {
        switch self {
        case .busyWithDictation, .busyWithMeeting: true
        default: false
        }
    }

    var needsTimelineUpdates: Bool {
        switch visualKind {
        case .amberBars, .blueBars, .recording: true
        case .success, .failure, .notice: false
        }
    }

    /// Read on every render: the person may change or clear the shortcut
    /// while the banner is up.
    @MainActor
    var meetingExplanation: String? {
        guard case let .recordingMeeting(_, automatic) = self, automatic else { return nil }
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .meeting)?.description else {
            return String(localized: "Looks like a meeting · stop it from the “M” menu")
        }
        return String(localized: "Looks like a meeting · \(shortcut) stops this recording")
    }
}

struct IndicatorView: View {
    let state: IndicatorState?
    let levelMeter: MicrophoneLevelMeter?
    private let levelHistory: IndicatorLevelHistory

    init(state: IndicatorState?, levelMeter: MicrophoneLevelMeter?) {
        self.state = state
        self.levelMeter = levelMeter
        levelHistory = IndicatorLevelHistory()
    }

    @ViewBuilder
    var body: some View {
        if let state {
            if state.needsTimelineUpdates {
                TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
                    pill(for: state, at: context.date)
                }
            } else {
                pill(for: state, at: Date())
            }
        }
    }

    @ViewBuilder
    private func pill(for state: IndicatorState, at now: Date) -> some View {
        HStack(spacing: 9) {
            glyph(for: state, at: now)
            label(for: state, at: now)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255).opacity(0.95))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(borderColor(for: state), lineWidth: 0.5)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func glyph(for state: IndicatorState, at now: Date) -> some View {
        switch state.visualKind {
        case .amberBars:
            equalizer(
                heights: [5, 5, 5, 5],
                color: Color(red: 1, green: 159 / 255, blue: 10 / 255),
                opacities: [0.9, 0.6, 0.4, 0.25],
                alignment: .center,
                pulse: pulse(at: now)
            )
            .frame(width: 16, height: 14)
        case .blueBars:
            equalizer(
                heights: [8, 8, 8, 8],
                color: Color(red: 10 / 255, green: 132 / 255, blue: 1),
                opacities: [0.9, 0.6, 0.4, 0.25],
                alignment: .center,
                pulse: pulse(at: now)
            )
            .frame(width: 16, height: 14)
        case .recording:
            equalizer(
                heights: levelHistory.heights(for: state, meter: levelMeter, at: now),
                color: Color(red: 1, green: 69 / 255, blue: 58 / 255),
                opacities: [1, 1, 1, 1],
                alignment: .bottom,
                pulse: 1
            )
            .frame(width: 16, height: 14)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255))
        case .failure:
            Circle()
                .fill(Color(red: 1, green: 69 / 255, blue: 58 / 255))
                .frame(width: 8, height: 8)
        case .notice:
            Circle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }

    private func equalizer(
        heights: [CGFloat],
        color: Color,
        opacities: [Double],
        alignment: VerticalAlignment,
        pulse: Double
    ) -> some View {
        HStack(alignment: alignment, spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(opacities[index] * pulse))
                    .frame(width: 2.5, height: heights[index])
            }
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private func label(for state: IndicatorState, at now: Date) -> some View {
        if case let .recordingDictation(startedAt, endsAt) = state {
            timerLabel(
                Self.dictationTimerText(startedAt: startedAt, endsAt: endsAt, now: now),
                slotCharacterCount: 4
            )
        } else if case let .recordingMeeting(startedAt, automatic) = state {
            if automatic {
                HStack(spacing: 8) {
                    Text(state.meetingExplanation ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                    timerLabel(
                        Self.elapsedText(from: startedAt, to: now, includesHours: true),
                        slotCharacterCount: 7
                    )
                }
            } else {
                timerLabel(
                    Self.elapsedText(from: startedAt, to: now, includesHours: true),
                    slotCharacterCount: 7
                )
            }
        } else {
            Text(labelText(for: state))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white)
        }
    }

    private func timerLabel(_ text: String, slotCharacterCount: Int) -> some View {
        IndicatorTimerLabel(text: text, slotCharacterCount: slotCharacterCount)
    }

    private func labelText(for state: IndicatorState) -> String {
        switch state {
        case .loadingModel: String(localized: "Preparing the model")
        case .waitingEngine: String(localized: "Waiting for the engine")
        case .finishingRecording: String(localized: "Finishing the recording")
        case .recognizing: String(localized: "Recognizing")
        case .savingMeeting: String(localized: "Saving the meeting recording")
        case let .inserted(characterCount): String(localized: "Pasted · \(characterCount)")
        case .meetingSaved: String(localized: "Meeting saved")
        case .meetingSavedSuspect: String(localized: "Meeting saved with a warning — details in the “M” menu")
        case .meetingSavedPartially: String(localized: "Recording only partly saved — open it from the menu")
        case .noSpeech: String(localized: "No speech detected")
        case .clipboardFallback: String(localized: "On the clipboard — press ⌘V")
        case .clipboardFailed: String(localized: "Couldn’t copy — the text is in the history")
        case .injectionFailed: String(localized: "Couldn’t paste — the text is in the history")
        case .microphoneTimedOut: String(localized: "The microphone didn’t respond — try again")
        case .microphoneAccessUndetermined: String(localized: "Access needed — “M” menu → “Allow…”")
        case .microphoneAccessDenied: String(localized: "No access — “M” menu → System Settings")
        case .meetingMicrophoneAccessDenied: String(localized: "First allow the microphone in the “M” menu")
        case .busyWithDictation: String(localized: "Dictation in progress — finish it first")
        case .busyWithMeeting: String(localized: "Meeting recording in progress — finish it first")
        case let .dictationFailure(message), let .meetingFailure(message): message
        case .recordingDictation, .recordingMeeting: ""
        }
    }

    private func borderColor(for state: IndicatorState) -> Color {
        state.visualKind == .failure
            ? Color(red: 1, green: 69 / 255, blue: 58 / 255).opacity(0.5)
            : Color.white.opacity(0.14)
    }

    private func pulse(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
        return 0.675 + 0.325 * cos(phase * 2 * .pi)
    }

    /// Elapsed time; in the last half minute before the limit, what is left,
    /// so the stop does not come as a surprise.
    static func dictationTimerText(startedAt: Date, endsAt: Date, now: Date) -> String {
        let left = endsAt.timeIntervalSince(now)
        guard left <= 30 else { return elapsedText(from: startedAt, to: now, includesHours: false) }
        let seconds = max(0, Int(left.rounded(.up)))
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(localized: "Stops in \(time)")
    }

    static func elapsedText(from startedAt: Date, to now: Date, includesHours: Bool) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60
        if includesHours, hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", elapsed / 60, seconds)
    }
}

struct IndicatorTimerLabel: View {
    let text: String
    let slotCharacterCount: Int

    var body: some View {
        ZStack(alignment: .leading) {
            Text(String(repeating: "0", count: slotCharacterCount))
                .hidden()
            Text(text)
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(Color.white)
    }
}

final class IndicatorLevelHistory {
    private var heights = Array(
        repeating: MicrophoneLevelMeter.minimumHeight,
        count: 4
    )
    private var sampledAt: Date?

    func heights(
        for state: IndicatorState,
        meter: MicrophoneLevelMeter?,
        at date: Date
    ) -> [CGFloat] {
        guard case .recordingDictation = state else { return [6, 13, 9, 4] }
        guard let meter else { return heights }
        guard sampledAt != date else { return heights }
        sampledAt = date
        heights.removeFirst()
        heights.append(MicrophoneLevelMeter.normalizedHeight(for: meter.takeLevel()))
        return heights
    }
}
