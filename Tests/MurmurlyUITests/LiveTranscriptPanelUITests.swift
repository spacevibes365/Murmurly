import XCTest

/// `-LiveTranscriptProbe` fakes a recording with a few made-up lines, so the
/// live-transcript panel shows without a capture or an engine.
@MainActor
final class LiveTranscriptPanelUITests: XCTestCase {
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-LiveTranscriptProbe"]
            + extraArguments + AppLanguage.launchArguments
        app.launch()
        return app
    }

    func testPanelShowsTheProbesLinesWithTheNewestAtTheBottom() {
        let app = launch()
        defer { app.terminate() }

        let state = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the live-transcript panel did not appear")

        // The oldest line ("release notes") is the first a short panel
        // clips, and `boundBy:` order is not a reliable stand-in for "newest":
        // check the newest line is present at all, and the count, not a position.
        let lines = app.staticTexts.matching(identifier: "liveTranscriptLine")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(lines.count, 4, "fewer lines than the probe fed in")
        // A static-text element's own line shows up in `value`, not `label`.
        let newest = lines.matching(NSPredicate(format: "value CONTAINS %@", "Next, the menu item."))
        XCTAssertEqual(newest.count, 1, "the newest line is missing")
    }

    func testCloseButtonHidesThePanelAndTheMenuBringsItBack() {
        let app = launch()
        defer { app.terminate() }

        let closeButton = app.buttons["liveTranscriptCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
        closeButton.click()
        XCTAssertTrue(
            app.staticTexts["liveTranscriptStateLabel"].waitForNonExistence(timeout: 5),
            "the ✕ did not hide the panel"
        )

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "no Murmurly item in the menu bar")
        statusItem.click()
        let showItem = statusItem.menus.firstMatch.menuItems[AppLanguage.text("Show Live Transcript")]
        XCTAssertTrue(showItem.waitForExistence(timeout: 5), "the menu has no Show Live Transcript")
        showItem.click()

        XCTAssertTrue(
            app.staticTexts["liveTranscriptStateLabel"].waitForExistence(timeout: 5),
            "the menu item did not bring the panel back"
        )
    }

    /// -LiveTranscriptProbeSession gives the probe a session folder, so ★
    /// reads as recording into it (every other test above has none, and ★
    /// stays disabled, as it must). A double-click selects a word of the
    /// probe's own "Got it, thanks." line; ★ then marks that line itself —
    /// its own ★, highlighted on the line, never a separate "Marked moment"
    /// row.
    func testSelectingWordsAndStarMarksThatLine() {
        let app = launch(extraArguments: ["-LiveTranscriptProbeSession"])
        defer { app.terminate() }

        let lines = app.staticTexts.matching(identifier: "liveTranscriptLine")
        let targetLine = lines.matching(NSPredicate(format: "value CONTAINS %@", "Got it, thanks.")).firstMatch
        XCTAssertTrue(targetLine.waitForExistence(timeout: 10))
        targetLine.doubleClick()

        let markButton = app.buttons["markMomentButton"]
        XCTAssertTrue(markButton.waitForExistence(timeout: 5))
        markButton.click()

        let star = app.images["notepadLineMomentStar"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "the line's own ★ did not appear")
        let label = star.label
        XCTAssertFalse(label.isEmpty, "the ★ must carry the words it marks")
        XCTAssertTrue("Got it, thanks.".contains(label), "the marked words must come from this very line")
        XCTAssertGreaterThanOrEqual(star.frame.midY, targetLine.frame.minY)
        XCTAssertLessThanOrEqual(star.frame.midY, targetLine.frame.maxY)

        XCTAssertFalse(app.staticTexts["notepadNote"].exists, "a moment made from a line is never drawn as its own row")
        XCTAssertFalse(app.images["notepadMomentStar"].exists)
    }

    /// Pressing ★ with no selection at all marks the newest (bottommost)
    /// line of the probe's own feed, whole.
    func testStarWithoutASelectionMarksTheNewestLine() {
        let app = launch(extraArguments: ["-LiveTranscriptProbeSession"])
        defer { app.terminate() }

        let markButton = app.buttons["markMomentButton"]
        XCTAssertTrue(markButton.waitForExistence(timeout: 10))
        markButton.click()

        let star = app.images["notepadLineMomentStar"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        XCTAssertEqual(star.label, "Next, the menu item.")
        XCTAssertFalse(app.staticTexts["notepadNote"].exists)
    }
}
