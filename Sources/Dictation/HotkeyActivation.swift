import AppKit
import Carbon.HIToolbox

enum HotkeyActivation: String, CaseIterable, Sendable {
    case press
    case hold
    case doubleModifier

    var explanation: String {
        switch self {
        case .press:
            String(localized: "Press to record, press again to paste.")
        case .hold:
            String(localized: "Hold the shortcut while you speak; release it to paste.")
        case .doubleModifier:
            String(localized: "Two quick presses start recording, one stops it. Ordinary shortcuts stay free.")
        }
    }
}

enum TapModifier: String, CaseIterable, Sendable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption

    var title: String {
        switch self {
        case .rightCommand: String(localized: "Right ⌘")
        case .leftCommand: String(localized: "Left ⌘")
        case .rightOption: String(localized: "Right ⌥")
        case .leftOption: String(localized: "Left ⌥")
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightCommand: UInt16(kVK_RightCommand)
        case .leftCommand: UInt16(kVK_Command)
        case .rightOption: UInt16(kVK_RightOption)
        case .leftOption: UInt16(kVK_Option)
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand, .leftCommand: .command
        case .rightOption, .leftOption: .option
        }
    }

    init?(keyCode: UInt16) {
        guard let modifier = Self.allCases.first(where: { $0.keyCode == keyCode }) else {
            return nil
        }
        self = modifier
    }
}

struct DictationGestureHint: Equatable, Sendable {
    let start: String
    let stop: String
}

func dictationGestureHint(
    activation: HotkeyActivation,
    modifier: TapModifier,
    shortcutDescription: String?,
    doubleModifierAvailable: Bool
) -> DictationGestureHint {
    if activation == .doubleModifier, doubleModifierAvailable {
        return DictationGestureHint(start: "2× \(modifier.title)", stop: modifier.title)
    }

    if activation == .hold, let shortcutDescription {
        return DictationGestureHint(
            start: String(localized: "Hold \(shortcutDescription)"),
            stop: String(localized: "Release \(shortcutDescription)")
        )
    }

    let shortcut = shortcutDescription
        ?? (doubleModifierAvailable ? String(localized: "Not set") : String(localized: "No gesture available"))
    return DictationGestureHint(start: shortcut, stop: shortcut)
}

enum DoubleModifierEvent: Equatable, Sendable {
    case modifierChanged(
        TapModifier,
        isDown: Bool,
        otherModifiersDown: Bool,
        timestamp: TimeInterval
    )
    case otherModifierChanged(selectedModifierDown: Bool)
    case keyDown(selectedModifierDown: Bool)
}

enum DoubleModifierResult: Equatable, Sendable {
    case tapCompleted(completesDoubleTap: Bool)
}

struct DoubleModifierReducer: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case idle
        case pressed(firstDownAt: TimeInterval, isSecondTap: Bool)
        case waiting(firstDownAt: TimeInterval)
        case blockedUntilRelease

        var isPressed: Bool {
            if case .pressed = self { return true }
            return false
        }
    }

    let modifier: TapModifier
    let threshold: TimeInterval
    private var state: State = .idle

    init(modifier: TapModifier, thresholdMilliseconds: Int) {
        self.modifier = modifier
        threshold = Double(thresholdMilliseconds) / 1_000
    }

    mutating func reset() {
        state = .idle
    }

    /// Reports only complete, unmodified taps. Waiting for key-up keeps a press
    /// that grows into a chord from being interpreted as a tap.
    mutating func handle(_ event: DoubleModifierEvent) -> DoubleModifierResult? {
        switch event {
        case .otherModifierChanged(let selectedModifierDown):
            state = selectedModifierDown && state.isPressed ? .blockedUntilRelease : .idle
            return nil

        case .keyDown(let selectedModifierDown):
            guard selectedModifierDown else { return nil }
            switch state {
            case .pressed:
                state = .blockedUntilRelease
            case .waiting:
                state = .idle
            case .idle, .blockedUntilRelease:
                break
            }
            return nil

        case .modifierChanged(
            let changedModifier,
            let isDown,
            let otherModifiersDown,
            let timestamp
        ):
            guard changedModifier == modifier else {
                state = .idle
                return nil
            }

            if otherModifiersDown {
                state = isDown ? .blockedUntilRelease : .idle
                return nil
            }

            if isDown {
                switch state {
                case .idle, .blockedUntilRelease:
                    state = .pressed(firstDownAt: timestamp, isSecondTap: false)
                case .waiting(let firstDownAt):
                    let interval = timestamp - firstDownAt
                    state = .pressed(
                        firstDownAt: timestamp,
                        isSecondTap: interval >= 0 && interval <= threshold
                    )
                case .pressed:
                    break
                }
                return nil
            }

            switch state {
            case .pressed(let firstDownAt, let isSecondTap):
                state = isSecondTap ? .idle : .waiting(firstDownAt: firstDownAt)
                return .tapCompleted(completesDoubleTap: isSecondTap)
            case .blockedUntilRelease:
                state = .idle
            case .idle, .waiting:
                break
            }
            return nil
        }
    }
}
