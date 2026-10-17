import CoreGraphics
import XCTest

@MainActor
final class MurmurlyUITests: XCTestCase {
    func testColdLaunchSettingsFromMenuBar() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }

        XCTAssertEqual(app.windows.count, 0, "Production launch must stay menu-bar-only")
        openSettingsFromMenuBar(in: app)

        let content = app.descendants(matching: .any)["settingsWindowContent"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows.firstMatch.isHittable)
    }

    func testCommandCommaOpensSettingsWithoutExistingWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }

        XCTAssertEqual(app.windows.count, 0, "Production launch must stay menu-bar-only")
        app.activate()
        let commaCharacter = physicalCommaCharacter()
        try XCTSkipUnless(
            commaCharacter == ",",
            "The ⌘, check through typeKey depends on the keyboard layout: the physical key "
                + "kVK_ANSI_Comma gives "
                + "\(commaCharacter.map { "“\($0)”" } ?? "an unknown character"), "
                + "not a comma"
        )
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(
            app.descendants(matching: .any)["settingsWindowContent"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The app has no help book, so the standard Help item would only say
    /// "Help isn't available". Found by its action, in any language.
    func testHelpMenuOffersNoHelpBookItem() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }
        app.activate()
        let items = app.menuBars.firstMatch.menuBarItems
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "no main menu")
        // Help is the last menu; without its item SwiftUI may drop it, and the
        // last one is then Window — either way no item may show the help book.
        let last = items.element(boundBy: items.count - 1)
        last.click()
        XCTAssertTrue(last.menus.firstMatch.waitForExistence(timeout: 5), "the menu did not open — the check proves nothing")
        XCTAssertFalse(app.menuItems["showHelp:"].exists, "Help offers a help book the app does not have")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsContainsExclusivePersistentTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }

        XCTAssertEqual(app.windows.count, 0, "UI testing must also start without a window")
        openSettingsFromMenuBar(in: app)

        let windowContent = app.descendants(matching: .any)["settingsWindowContent"]
        XCTAssertTrue(windowContent.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
        guard app.settingsSidebarSearchIsEmpty() else { return }

        let tabs = ["gettingStarted", "dictation", "meetings", "storage", "permissions"]
        for gone in ["dictionary", "history", "files"] {
            XCTAssertFalse(app.buttons["settingsTab.\(gone)"].exists, "Settings still has the \(gone) tab")
        }
        for tab in tabs {
            let button = app.buttons["settingsTab.\(tab)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.click()

            let selected = app.descendants(matching: .any)["settingsContent.\(tab)"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            for hiddenTab in tabs where hiddenTab != tab {
                XCTAssertFalse(
                    app.descendants(matching: .any)["settingsContent.\(hiddenTab)"].exists,
                    "Inactive tab leaked into the accessibility tree"
                )
            }

            switch tab {
            case "gettingStarted":
                XCTAssertTrue(app.descendants(matching: .any)["autoRecordMeetingsToggle"].exists)
            case "dictation":
                XCTAssertTrue(
                    app.descendants(matching: .any)["dictationLanguagePicker"]
                        .waitForExistence(timeout: 5)
                )
            case "permissions":
                XCTAssertTrue(
                    app.buttons["checkSystemAudioButton"].waitForExistence(timeout: 5)
                )
                XCTAssertTrue(
                    app.descendants(matching: .any)["launchAtLoginToggle"]
                        .waitForExistence(timeout: 5)
                )
            default:
                break
            }
        }
    }

    /// The main window's sections are built with it and only hidden: only
    /// the shown one is in the accessibility tree, and the history's search
    /// typed there is still there after another section.
    func testMainWindowContainsExclusivePersistentSections() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }
        guard app.openMainSection("meetings") else { return }
        let window = app.windows["main"]
        // Meetings and Starred share one list.
        let contents = ["meetings", "dictations", "dictionary", "files"]
        for (section, content) in [("meetings", "meetings"), ("starred", "meetings"), ("dictations", "dictations"),
                                   ("dictionary", "dictionary"), ("files", "files")] {
            let row = window.descendants(matching: .any)["mainSection.\(section)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), section)
            row.click()
            XCTAssertTrue(window.descendants(matching: .any)["mainContent.\(content)"].waitForExistence(timeout: 5), section)
            for hidden in contents where hidden != content {
                XCTAssertFalse(
                    window.descendants(matching: .any)["mainContent.\(hidden)"].exists,
                    "a hidden section leaked into the accessibility tree on \(section)"
                )
            }
            switch section {
            case "files":
                XCTAssertTrue(window.descendants(matching: .any)["fileDropZonePrompt"].waitForExistence(timeout: 5))
            case "dictionary":
                XCTAssertTrue(window.buttons["dictionaryAdd"].waitForExistence(timeout: 5))
            case "dictations":
                XCTAssertTrue(window.textFields["historySearchField"].waitForExistence(timeout: 5))
            default:
                XCTAssertTrue(window.descendants(matching: .any)["meetingList"].waitForExistence(timeout: 5))
            }
        }

        guard app.showMainSection("dictations") else { return }
        let search = window.textFields["historySearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        let searchQuery = "12345"
        search.typeText(searchQuery)
        guard app.showMainSection("files") else { return }
        XCTAssertFalse(search.exists)
        guard app.showMainSection("dictations") else { return }
        XCTAssertEqual(window.textFields["historySearchField"].value as? String, searchQuery)
    }

    /// What VoiceOver says for the dictionary's switches and the entry
    /// sheet's fields: their visible titles stand beside them, not in them.
    func testDictionaryControlsHaveSpokenNames() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }

        guard app.openMainSection("dictionary") else { return }
        for (identifier, name) in [
            ("dictionaryInDictation", "Dictation"),
            ("dictionaryInMeetings", "Meetings"),
            ("dictionaryInFiles", "Files"),
        ] {
            let control = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 5), identifier)
            XCTAssertEqual(control.label, AppLanguage.text(name), identifier)
        }

        let add = app.buttons["dictionaryAdd"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        for (identifier, name) in [
            ("dictionaryHeardField", "Heard as"),
            ("dictionaryWrittenField", "Write as"),
            ("dictionaryExampleField", "Try it"),
        ] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5), identifier)
            XCTAssertEqual(field.label, AppLanguage.text(name), identifier)
        }
        app.buttons["dictionaryCancel"].click()
        XCTAssertTrue(app.textFields["dictionaryHeardField"].waitForNonExistence(timeout: 5), "the sheet stayed")
    }

    /// A test copy must leave the app's shortcut preferences exactly as they
    /// were, absence included. Showing Settings reads the dictation shortcut
    /// and builds its recorder, which is where KeyboardShortcuts would seed an
    /// initial combination into a domain that has none.
    func testTestLaunchKeepsShortcutPreferences() {
        let keys = ["KeyboardShortcuts_dictate", "KeyboardShortcuts_meeting"]
        let before = shortcutPreferences(keys)
        print("shortcut preferences before: \(before)")
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        openSettingsFromMenuBar(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsContent.dictation"].waitForExistence(timeout: 5)
        )
        app.terminate()

        // cfprefsd writes to disk asynchronously: give a seeded value time to
        // land, as long as every check of the owner's domain does.
        var after = shortcutPreferences(keys)
        let deadline = Date().addingTimeInterval(5)
        while after == before, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            after = shortcutPreferences(keys)
        }
        print("shortcut preferences after: \(after)")
        XCTAssertEqual(after, before, "the test copy changed the shortcuts in the app's domain")
    }

    /// Files once put its buttons into a window toolbar: on that tab alone
    /// the window grew and the title and the sidebar moved down. Files is
    /// the main window's now; every tab of Settings keeps the window, the
    /// title's place and the sidebar, there and back, with no toolbar. The
    /// title is compared by origin only: its width is the tab's name.
    func testSettingsTabsKeepTheWindowAndItsChrome() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + AppLanguage.launchArguments
        app.launch()
        defer { app.terminate() }
        openSettingsFromMenuBar(in: app)
        let window = app.windows.firstMatch
        let title = app.descendants(matching: .any)["settingsWindowContent"]
        let search = app.textFields["settingsSidebarSearch"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        guard app.settingsSidebarSearchIsEmpty() else { return }

        func show(_ tab: String) -> (window: CGRect, title: CGPoint, search: CGRect)? {
            let button = app.buttons["settingsTab.\(tab)"]
            guard button.waitForExistence(timeout: 5) else {
                XCTFail("no \(tab) tab")
                return nil
            }
            button.click()
            guard app.descendants(matching: .any)["settingsContent.\(tab)"].waitForExistence(timeout: 5) else {
                XCTFail("the \(tab) tab did not open")
                return nil
            }
            // A resize follows the switch: read once the window holds still.
            var frame = window.frame
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.2)
                let next = window.frame
                if next == frame { break }
                frame = next
            }
            XCTAssertEqual(window.toolbars.count, 0, "REGRESSION: a toolbar on \(tab)")
            return (frame, title.frame.origin, search.frame)
        }

        guard let start = show("dictation") else { return }
        for tab in ["storage", "dictation", "permissions", "storage", "dictation"] {
            guard let now = show(tab) else { return }
            let place = "\(tab) after dictation"
            XCTAssertEqual(now.window.minX, start.window.minX, accuracy: 1, "REGRESSION: the window moved on \(place)")
            XCTAssertEqual(now.window.minY, start.window.minY, accuracy: 1, "REGRESSION: the window moved on \(place)")
            XCTAssertEqual(now.window.width, start.window.width, accuracy: 1, "REGRESSION: the window resized on \(place)")
            XCTAssertEqual(now.window.height, start.window.height, accuracy: 1, "REGRESSION: the window resized on \(place)")
            XCTAssertEqual(now.title.x, start.title.x, accuracy: 1, "REGRESSION: the title moved on \(place)")
            XCTAssertEqual(now.title.y, start.title.y, accuracy: 1, "REGRESSION: the title moved on \(place)")
            XCTAssertEqual(now.search.minX, start.search.minX, accuracy: 1, "REGRESSION: the sidebar moved on \(place)")
            XCTAssertEqual(now.search.minY, start.search.minY, accuracy: 1, "REGRESSION: the sidebar moved on \(place)")
            XCTAssertEqual(now.search.width, start.search.width, accuracy: 1, "REGRESSION: the sidebar changed on \(place)")
            XCTAssertEqual(now.search.height, start.search.height, accuracy: 1, "REGRESSION: the sidebar changed on \(place)")
        }
    }

    /// The UI runner is sandboxed, so CFPreferences would read its own
    /// container. It may read any file, so the app's domain is read from disk
    /// under the real home folder.
    private func shortcutPreferences(_ keys: [String]) -> [String: String] {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else {
            XCTFail("could not find the home folder")
            return [:]
        }
        let url = URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Preferences/io.github.spacevibes365.Murmurly.plist")
        var plist: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any] else {
                XCTFail("the app's domain exists but cannot be read: \(url.path)")
                return [:]
            }
            plist = decoded
        }
        var values: [String: String] = [:]
        for key in keys {
            values[key] = plist[key].map { String(describing: $0) } ?? "<none>"
        }
        return values
    }

    private func openSettingsFromMenuBar(in app: XCUIApplication) {
        let statusItem = app.statusItems.firstMatch
        guard statusItem.waitForExistence(timeout: 5) else {
            XCTFail("The Murmurly item did not appear in the menu bar")
            return
        }
        statusItem.click()

        // MenuBarExtra drops SwiftUI accessibility identifiers and exposes every
        // action as `menuAction:`. The only stable nonlocalized anchor available
        // is the trailing Settings, separator, Exit structure.
        let menuItems = statusItem.menus.firstMatch.children(matching: .menuItem)
        guard menuItems.count >= 3 else {
            XCTFail("The Murmurly menu has too few items")
            return
        }
        let settingsItem = menuItems.element(boundBy: menuItems.count - 3)
        guard settingsItem.exists else {
            XCTFail("The Settings item was not found in the Murmurly menu")
            return
        }
        settingsItem.click()
    }

    private func physicalCommaCharacter() -> String? {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 43, // kVK_ANSI_Comma
            keyDown: true
        ) else { return nil }
        var characterCount = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &characterCount,
            unicodeString: &characters
        )
        return String(utf16CodeUnits: characters, count: characterCount)
    }
}
