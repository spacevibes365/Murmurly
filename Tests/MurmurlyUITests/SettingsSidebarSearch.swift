import XCTest

extension XCUIApplication {
    /// False, after failing the test, when the settings sidebar search already
    /// holds text: every section is then filtered out and whatever the test
    /// checks next proves nothing. The field is never cleared here, so outside
    /// interference stays visible instead of being hidden.
    @MainActor
    func settingsSidebarSearchIsEmpty(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let search = textFields["settingsSidebarSearch"]
        guard search.waitForExistence(timeout: 5) else {
            XCTFail("The settings section search field did not appear", file: file, line: line)
            return false
        }
        let value = search.value as? String ?? ""
        guard value.isEmpty || value == search.placeholderValue else {
            XCTFail(
                "The settings section search holds stray text “\(value)”: "
                    + "the tabs are hidden, the check proves nothing",
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    /// The main window from the menu bar's Open Murmurly, on `section`: its
    /// sidebar row is `mainSection.<section>`, its content
    /// `mainContent.<section>`. False, after failing the test, when it did
    /// not show.
    @MainActor
    func openMainSection(_ section: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let statusItem = statusItems.firstMatch
        guard statusItem.waitForExistence(timeout: 5) else {
            XCTFail("the Murmurly item did not appear in the menu bar", file: file, line: line)
            return false
        }
        statusItem.click()
        let item = statusItem.menus.firstMatch.menuItems[AppLanguage.text("Open Murmurly")]
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("the menu has no Open Murmurly", file: file, line: line)
            return false
        }
        item.click()
        return showMainSection(section, file: file, line: line)
    }

    /// The section chosen in the main window's sidebar; false, after failing
    /// the test, when it did not show.
    @MainActor
    func showMainSection(_ section: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let window = windows["main"]
        guard window.waitForExistence(timeout: 10) else {
            XCTFail("no main window", file: file, line: line)
            return false
        }
        let row = window.descendants(matching: .any)["mainSection.\(section)"]
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("the sidebar has no \(section)", file: file, line: line)
            return false
        }
        row.click()
        // Starred shows the meetings' own list.
        let content = section == "starred" ? "meetings" : section
        guard window.descendants(matching: .any)["mainContent.\(content)"].waitForExistence(timeout: 5) else {
            XCTFail("the \(section) section did not show", file: file, line: line)
            return false
        }
        return true
    }

    /// The menu bar item's "Transcribe a File…": the section changes from
    /// outside the window, with whatever sheet is up on it. False, after
    /// failing the test, when the Files section did not show: a check after
    /// it would prove nothing.
    @MainActor
    func transcribeAFileFromMenuBar(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let statusItem = statusItems.firstMatch
        guard statusItem.waitForExistence(timeout: 5) else {
            XCTFail("the Murmurly item did not appear in the menu bar", file: file, line: line)
            return false
        }
        statusItem.click()
        let item = statusItem.menus.firstMatch.menuItems[AppLanguage.text("Transcribe a File…")]
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("the menu has no Transcribe a File…", file: file, line: line)
            return false
        }
        item.click()
        guard windows["main"].descendants(matching: .any)["mainContent.files"].waitForExistence(timeout: 5) else {
            XCTFail("the Files section did not show", file: file, line: line)
            return false
        }
        return true
    }
}
