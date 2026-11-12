import CoreGraphics
import XCTest

/// `-LiveTranscriptProbeManyLines` (on top of `-LiveTranscriptProbe`) adds 80
/// made-up filler lines ahead of the usual five, so the feed has enough rows
/// to scroll through before reaching the newest ones.
@MainActor
final class NotepadFeedUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-LiveTranscriptProbe", "-LiveTranscriptProbeManyLines"]
            + AppLanguage.launchArguments
        app.launch()
        return app
    }

    func testScrollingAwayShowsJumpToBottomAndItReturnsToTheNewestLine() {
        let app = launch()
        defer { app.terminate() }

        let feed = app.scrollViews["notepadFeedScrollView"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the notepad's feed did not appear")

        let lines = app.staticTexts.matching(identifier: "liveTranscriptLine")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5))
        let newest = lines.matching(NSPredicate(format: "value CONTAINS %@", "Next, the menu item."))
        XCTAssertTrue(newest.firstMatch.waitForExistence(timeout: 5), "the newest line did not show at the bottom")

        // Still following the bottom: the button is not there to begin with.
        XCTAssertFalse(app.buttons["notepadJumpToBottomButton"].exists)

        feed.scroll(byDeltaX: 0, deltaY: 4_000)

        let jumpToBottom = app.buttons["notepadJumpToBottomButton"]
        XCTAssertTrue(jumpToBottom.waitForExistence(timeout: 5), "scrolling away from the bottom must show \"Jump to bottom\"")

        jumpToBottom.click()

        XCTAssertTrue(
            jumpToBottom.waitForNonExistence(timeout: 5),
            "\"Jump to bottom\" must hide itself once the feed is back at the bottom"
        )
        XCTAssertTrue(newest.firstMatch.waitForExistence(timeout: 5), "the newest line must be back on screen")
    }

    /// Searching for a line that happens to be the very last one scrolls to
    /// it, landing within the bottom tolerance — that must not turn
    /// following back on, so "Jump to bottom" stays shown.
    func testSearchingTheLastLineDoesNotTurnFollowingBackOn() throws {
        let app = launch()
        defer { app.terminate() }

        let state = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the live-transcript panel did not appear")
        app.textFields["notepadNoteField"].click()

        guard let f = physicalCharacter(of: 3), f == "f" else {
            throw XCTSkip("⌘F through typeKey depends on the keyboard layout")
        }
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["notepadSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F did not show the search field")

        field.typeText("Next, the menu item.")

        let jumpToBottom = app.buttons["notepadJumpToBottomButton"]
        XCTAssertTrue(
            jumpToBottom.waitForExistence(timeout: 2),
            "scrolling to a highlight near the bottom must not turn following back on"
        )
        // The window above only proves the button showed up at some point;
        // give the scroll's own animation a moment to finish settling, then
        // confirm it did not quietly flip following back on and hide it.
        XCTAssertTrue(jumpToBottom.exists, "\"Jump to bottom\" must stay shown once the scroll settles")
    }

    /// Finding 4: closing the search bar after it scrolled
    /// to a highlight near the bottom changes the scroll view's own
    /// container height — on the buggy code that resize alone, with no
    /// generation open by then, read as the user arriving at the bottom and
    /// turned following back on, hiding "Jump to bottom" and losing the
    /// scrolled-away position.
    func testClosingSearchAfterHighlightingNearTheBottomKeepsJumpToBottomShown() throws {
        let app = launch()
        defer { app.terminate() }

        let feed = app.scrollViews["notepadFeedScrollView"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the notepad's feed did not appear")
        feed.scroll(byDeltaX: 0, deltaY: 4_000)

        let jumpToBottom = app.buttons["notepadJumpToBottomButton"]
        XCTAssertTrue(jumpToBottom.waitForExistence(timeout: 5), "scrolling away from the bottom must show \"Jump to bottom\"")

        guard let f = physicalCharacter(of: 3), f == "f" else {
            throw XCTSkip("⌘F through typeKey depends on the keyboard layout")
        }
        app.textFields["notepadNoteField"].click()
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["notepadSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F did not show the search field")
        field.typeText("Next, the menu item.")
        XCTAssertTrue(jumpToBottom.waitForExistence(timeout: 2), "the search's own scroll to a highlight near the bottom must not hide the button")

        // Let the search's own scroll settle before closing it.
        Thread.sleep(forTimeInterval: 1)
        app.buttons["notepadSearchClose"].click()

        // The search bar's removal changes the feed's container height; give
        // that resize a moment to be reported, then confirm it did not
        // quietly turn following back on.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(
            jumpToBottom.waitForNonExistence(timeout: 1),
            "closing the search bar must not turn following back on by itself"
        )
        let lines = app.staticTexts.matching(identifier: "liveTranscriptLine")
        XCTAssertTrue(lines.firstMatch.exists, "the scrolled-away line must still be visible")
    }

    /// Finding 6: once "Jump to bottom" lands the feed and
    /// clears its own generation, a later real scroll away must show the
    /// button again promptly — on the buggy code a stuck flag (never
    /// cleared because the landing frame arrived after a stale completion
    /// had already run) kept the button from ever coming back.
    func testJumpToBottomDoesNotGetStuckAfterLanding() {
        let app = launch()
        defer { app.terminate() }

        let feed = app.scrollViews["notepadFeedScrollView"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the notepad's feed did not appear")
        feed.scroll(byDeltaX: 0, deltaY: 4_000)

        let jumpToBottom = app.buttons["notepadJumpToBottomButton"]
        XCTAssertTrue(jumpToBottom.waitForExistence(timeout: 5), "scrolling away from the bottom must show \"Jump to bottom\"")
        jumpToBottom.click()

        // Poll for a full second: the button must not reappear while the
        // landing scroll is still settling, nor stay stuck hidden by a
        // generation that never closes.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            XCTAssertFalse(jumpToBottom.exists, "\"Jump to bottom\" must stay hidden right after landing at the bottom")
            Thread.sleep(forTimeInterval: 0.05)
        }

        feed.scroll(byDeltaX: 0, deltaY: 4_000)
        XCTAssertTrue(
            jumpToBottom.waitForExistence(timeout: 2),
            "a later real scroll away from the bottom must show \"Jump to bottom\" again, not stay stuck"
        )
    }

    /// What the key at this physical place types in the active layout, as
    /// `NotepadSearchUITests.physicalCharacter(of:)`.
    private func physicalCharacter(of virtualKey: CGKeyCode) -> String? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) else { return nil }
        var count = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        return String(utf16CodeUnits: characters, count: count)
    }
}
