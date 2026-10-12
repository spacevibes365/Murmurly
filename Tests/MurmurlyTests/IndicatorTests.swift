import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI
import XCTest
@testable import Murmurly

@MainActor
final class IndicatorTests: XCTestCase {
    private func indicator() -> RecordingIndicator {
        RecordingIndicator(renderingEnabled: false)
    }

    func testAutoHideTableCoversEveryIndicatorState() {
        let now = Date()
        let table: [(IndicatorState, TimeInterval?)] = [
            (.loadingModel, nil),
            (.waitingEngine, nil),
            (.finishingRecording, nil),
            (.recognizing, nil),
            (.recordingDictation(startedAt: now, endsAt: now + 300), nil),
            (.recordingMeeting(startedAt: now, automatic: false), nil),
            (.savingMeeting, nil),
            (.inserted(characterCount: 312), 1.5),
            (.meetingSaved, 4),
            (.meetingSavedSuspect, 6),
            (.meetingSavedPartially, 5),
            (.noSpeech, 1.5),
            (.clipboardFallback, 3),
            (.clipboardFailed, 3),
            (.injectionFailed, 3),
            (.microphoneTimedOut, 3),
            (.microphoneAccessUndetermined, 3.5),
            (.microphoneAccessDenied, 3.5),
            (.meetingMicrophoneAccessDenied, 3),
            (.busyWithDictation, 2.5),
            (.busyWithMeeting, 2.5),
            (.dictationFailure(message: "dictation"), 3),
            (.meetingFailure(message: "meeting"), 5),
        ]

        for (state, expected) in table {
            XCTAssertEqual(state.autoHide, expected, "Unexpected delay for \(state)")
        }
    }

    func testVisualKindTableCoversEveryIndicatorState() {
        let now = Date()
        let table: [(IndicatorState, IndicatorState.VisualKind)] = [
            (.loadingModel, .amberBars),
            (.waitingEngine, .amberBars),
            (.finishingRecording, .blueBars),
            (.recognizing, .blueBars),
            (.recordingDictation(startedAt: now, endsAt: now + 300), .recording),
            (.recordingMeeting(startedAt: now, automatic: false), .recording),
            (.savingMeeting, .blueBars),
            (.inserted(characterCount: 1), .success),
            (.meetingSaved, .success),
            (.meetingSavedSuspect, .failure),
            (.meetingSavedPartially, .failure),
            (.noSpeech, .notice),
            (.clipboardFallback, .notice),
            (.clipboardFailed, .failure),
            (.injectionFailed, .failure),
            (.microphoneTimedOut, .failure),
            (.microphoneAccessUndetermined, .failure),
            (.microphoneAccessDenied, .failure),
            (.meetingMicrophoneAccessDenied, .failure),
            (.busyWithDictation, .notice),
            (.busyWithMeeting, .notice),
            (.dictationFailure(message: "dictation"), .failure),
            (.meetingFailure(message: "meeting"), .failure),
        ]

        for (state, expected) in table {
            XCTAssertEqual(state.visualKind, expected, "Unexpected visual kind for \(state)")
        }
    }

    func testElapsedTimerFormatsDictationAndMeetingHourBoundary() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(
            IndicatorView.elapsedText(
                from: start, to: start.addingTimeInterval(14), includesHours: false
            ),
            "0:14"
        )
        XCTAssertEqual(
            IndicatorView.elapsedText(
                from: start, to: start.addingTimeInterval(3_599), includesHours: true
            ),
            "59:59"
        )
        XCTAssertEqual(
            IndicatorView.elapsedText(
                from: start, to: start.addingTimeInterval(3_600), includesHours: true
            ),
            "1:00:00"
        )
        XCTAssertEqual(
            IndicatorView.elapsedText(
                from: start, to: start.addingTimeInterval(3_753), includesHours: true
            ),
            "1:02:33"
        )
    }

    /// Elapsed time until the last half minute, then what is left.
    func testDictationTimerCountsDownTheLastHalfMinute() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = start + 300
        let table: [(TimeInterval, String)] = [
            (0, "0:00"),
            (269, "4:29"),
            (269.9, "4:29"),
            (270, "Stops in 0:30"),
            (275.5, "Stops in 0:25"),
            (299.2, "Stops in 0:01"),
            (300, "Stops in 0:00"),
            (310, "Stops in 0:00"),
        ]
        for (offset, expected) in table {
            XCTAssertEqual(
                IndicatorView.dictationTimerText(startedAt: start, endsAt: end, now: start + offset),
                expected,
                "at \(offset) s"
            )
        }
    }

    func testTimerSlotsReserveWidthAcrossDigitBoundaries() {
        let dictationWidth = timerSlotWidth(text: "0:14", characterCount: 4)
        XCTAssertEqual(
            dictationWidth,
            timerSlotWidth(text: "5:00", characterCount: 4),
            accuracy: 0.01
        )

        let meetingWidth = timerSlotWidth(text: "9:59", characterCount: 7)
        XCTAssertEqual(
            meetingWidth,
            timerSlotWidth(text: "10:00", characterCount: 7),
            accuracy: 0.01
        )
        XCTAssertEqual(
            meetingWidth,
            timerSlotWidth(text: "1:00:00", characterCount: 7),
            accuracy: 0.01
        )
        XCTAssertGreaterThan(meetingWidth, dictationWidth)
    }

    func testNewBaseCancelsTerminalFlash() {
        let indicator = indicator()
        let oldGeneration = indicator.showFlash(.inserted(characterCount: 12))

        indicator.setBase(.loadingModel)

        XCTAssertEqual(indicator.presentedState, .loadingModel)
        indicator.expireFlash(generation: oldGeneration)
        XCTAssertEqual(indicator.presentedState, .loadingModel)
    }

    func testBaseUpdatePreservesConflictFlash() {
        let indicator = indicator()
        indicator.setBase(.recordingDictation(startedAt: Date(), endsAt: Date() + 300))
        indicator.showFlash(.busyWithMeeting)

        indicator.setBase(.finishingRecording)

        XCTAssertEqual(indicator.presentedState, .busyWithMeeting)
    }

    func testTerminalStateClearsBaseBeforeFlashing() {
        let indicator = indicator()
        indicator.setBase(.savingMeeting)

        let generation = indicator.finish(with: .meetingSaved)

        XCTAssertEqual(indicator.presentedState, .meetingSaved)
        indicator.expireFlash(generation: generation)
        XCTAssertNil(indicator.presentedState)
    }

    func testStaleFlashDeadlineCannotExpireNewerFlash() {
        let indicator = indicator()
        let staleGeneration = indicator.showFlash(.clipboardFallback)
        indicator.showFlash(.clipboardFailed)

        indicator.expireFlash(generation: staleGeneration)

        XCTAssertEqual(indicator.presentedState, .clipboardFailed)
    }

    func testLatestBaseReturnsAfterConflictFlashExpires() {
        let indicator = indicator()
        indicator.setBase(.loadingModel)
        let generation = indicator.showFlash(.busyWithMeeting)
        indicator.setBase(.waitingEngine)

        indicator.expireFlash(generation: generation)

        XCTAssertEqual(indicator.presentedState, .waitingEngine)
    }

    func testClearedBaseLeavesNothingAfterConflictFlashExpires() {
        let indicator = indicator()
        indicator.setBase(.recordingMeeting(startedAt: Date(), automatic: false))
        let generation = indicator.showFlash(.busyWithDictation)
        indicator.clearBase()

        indicator.expireFlash(generation: generation)

        XCTAssertNil(indicator.presentedState)
    }

    func testTimelineRunsOnlyForStatesThatMove() {
        let now = Date()
        let moving: [IndicatorState] = [
            .loadingModel,
            .waitingEngine,
            .finishingRecording,
            .recognizing,
            .recordingDictation(startedAt: now, endsAt: now + 300),
            .recordingMeeting(startedAt: now, automatic: false),
            .savingMeeting,
        ]
        let staticStates: [IndicatorState] = [
            .inserted(characterCount: 1),
            .meetingSaved,
            .meetingSavedSuspect,
            .meetingSavedPartially,
            .noSpeech,
            .clipboardFallback,
            .clipboardFailed,
            .injectionFailed,
            .microphoneTimedOut,
            .microphoneAccessUndetermined,
            .microphoneAccessDenied,
            .meetingMicrophoneAccessDenied,
            .busyWithDictation,
            .busyWithMeeting,
            .dictationFailure(message: "failure"),
            .meetingFailure(message: "failure"),
        ]

        XCTAssertTrue(moving.allSatisfy(\.needsTimelineUpdates))
        XCTAssertTrue(staticStates.allSatisfy { !$0.needsTimelineUpdates })
    }

    func testMeetingUsesStaticBarsWithoutConsumingDictationLevel() {
        let meter = MicrophoneLevelMeter()
        meter.record(level: 0.5)
        let history = IndicatorLevelHistory()

        XCTAssertEqual(
            history.heights(
                for: .recordingMeeting(startedAt: Date(), automatic: true),
                meter: meter,
                at: Date()
            ),
            [6, 13, 9, 4]
        )
        XCTAssertEqual(meter.takeLevel(), 0.5)
    }

    func testOverlaySettingHidesWorkButNeverFailureAndRestoresOriginalStart() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.IndicatorLiveSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let indicator = RecordingIndicator(
            settings: settings,
            levelMeter: MicrophoneLevelMeter(),
            renderingEnabled: false
        )
        let startedAt = Date(timeIntervalSinceReferenceDate: 321)
        let recording = IndicatorState.recordingDictation(startedAt: startedAt, endsAt: startedAt + 300)

        indicator.setBase(recording)
        settings.overlayEnabled = false
        XCTAssertNil(indicator.visibleState)
        XCTAssertEqual(indicator.presentedState, recording)

        settings.overlayEnabled = true
        XCTAssertEqual(indicator.visibleState, recording)

        settings.overlayEnabled = false
        indicator.finish(with: .microphoneTimedOut)
        XCTAssertEqual(indicator.visibleState, .microphoneTimedOut)
    }

    /// With the indicator off, a refused action still says why; other
    /// notices stay hidden as chosen.
    func testIndicatorOffStillShowsWhyAnActionWasRefused() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.IndicatorRefusal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.overlayEnabled = false
        let indicator = RecordingIndicator(
            settings: settings,
            levelMeter: MicrophoneLevelMeter(),
            renderingEnabled: false
        )

        indicator.showFlash(.busyWithMeeting)
        XCTAssertEqual(indicator.visibleState, .busyWithMeeting)
        indicator.showFlash(.busyWithDictation)
        XCTAssertEqual(indicator.visibleState, .busyWithDictation)
        indicator.showFlash(.noSpeech)
        XCTAssertNil(indicator.visibleState)
    }

    func testResetPlacementUpdatesLiveIndicatorState() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.IndicatorReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.overlayPlacement = OverlayPlacement(
            displayID: UInt32.max,
            fractionX: 0.2,
            fractionY: 0.8
        )
        let indicator = RecordingIndicator(
            settings: settings,
            levelMeter: MicrophoneLevelMeter(),
            renderingEnabled: false
        )

        settings.overlayPlacement = nil

        XCTAssertNil(settings.overlayPlacement)
        XCTAssertEqual(indicator.compactPositionText, "Position: default")
    }

    /// The automatic-recording banner names the shortcut the person actually
    /// has, and points to the menu once there is none.
    func testAutomaticMeetingBannerNamesTheShortcutThatIsSet() throws {
        let automatic = IndicatorState.recordingMeeting(startedAt: Date(), automatic: true)
        let custom = KeyboardShortcuts.Shortcut(.m, modifiers: [.control, .command])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))

        try withMeetingShortcut(stored) {
            let text = try XCTUnwrap(automatic.meetingExplanation)
            XCTAssertTrue(text.contains(custom.description), text)
            XCTAssertFalse(text.contains("⌥⇧R"), text)
        }
        // Cleared in the recorder: KeyboardShortcuts then stores false.
        try withMeetingShortcut(false) {
            let text = try XCTUnwrap(automatic.meetingExplanation)
            XCTAssertFalse(text.contains("⌥⇧R"), text)
            XCTAssertTrue(text.contains("“M” menu"), text)
        }
        XCTAssertNil(IndicatorState.recordingMeeting(startedAt: Date(), automatic: false).meetingExplanation)
    }

    /// A Core Audio error made the menu bar menu ~670 px wide. A long line
    /// is cut in the middle, keeping what failed and the error code; a short
    /// one stays whole.
    func testLongErrorLineInTheMenuKeepsItsStartAndItsCode() {
        let line = "Meeting recording failed: Core Audio couldn’t match the formats of the combined device: "
            + "Core Audio 'unop' (1970171760)"

        let shown = DictationMenuView.menuLine(line)

        XCTAssertLessThanOrEqual(shown.count, 72, shown)
        XCTAssertTrue(shown.hasPrefix("Meeting recording failed: "), shown)
        XCTAssertTrue(shown.hasSuffix("'unop' (1970171760)"), shown)
        XCTAssertTrue(shown.contains("…"), shown)
        XCTAssertEqual(DictationMenuView.menuLine("Meeting: ready"), "Meeting: ready")
    }

    /// KeyboardShortcuts reads only the standard domain, which for the test
    /// host is the app's own, live one. The value goes into this process's
    /// argument domain instead: it is read first and never written to disk.
    private func withMeetingShortcut(_ value: Any, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overridden = original
        overridden["KeyboardShortcuts_meeting"] = value
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        try body()
    }

    private func timerSlotWidth(text: String, characterCount: Int) -> CGFloat {
        let view = NSHostingView(
            rootView: IndicatorTimerLabel(
                text: text,
                slotCharacterCount: characterCount
            )
        )
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.width
    }
}
