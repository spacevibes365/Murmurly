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
}
