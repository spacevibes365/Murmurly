import Foundation
import XCTest
@testable import Murmurly

@MainActor
final class TestIsolationNewAPITests: XCTestCase {
    func testClassifiesLaunches() {
        let host = ["XCTestConfigurationFilePath": "/tmp/host.xctestconfiguration"]
        func with(_ value: String) -> [String: String] {
            host.merging(["MURMURLY_PRODUCTION_SERVICES": value]) { $1 }
        }
        let cases: [(name: String, arguments: [String], environment: [String: String],
                     testProcess: Bool, isolated: Bool)] = [
            ("production launch", ["Murmurly"], [:], false, false),
            ("UI settings store alone is a test launch", ["Murmurly", "-UITestSettingsStore"], [:], true, true),
            ("UI testing", ["Murmurly", "-UITesting"], [:], true, true),
            ("UI testing with its settings store", ["Murmurly", "-UITesting", "-UITestSettingsStore"], [:],
             true, true),
            ("unit-test host", ["Murmurly"], host, true, true),
            ("stage gate keeps real services", ["Murmurly"], with("1"), true, false),
            ("only the exact opt-out value counts", ["Murmurly"], with("0"), true, true),
        ]
        for item in cases {
            let result = TestIsolation.classify(arguments: item.arguments, environment: item.environment)
            XCTAssertEqual(result.testProcess, item.testProcess, item.name)
            XCTAssertEqual(result.isolated, item.isolated, item.name)
        }
    }

    func testIsolatedStorageSharesOneTemporaryRoot() {
        XCTAssertTrue(TestIsolation.isEnabled)
        let root = TestIsolation.root
        XCTAssertEqual(DictationHistoryStore.defaultRoot(), root.appendingPathComponent("Dictations", isDirectory: true))
        XCTAssertEqual(RecordingsStore.meetingsRoot(), root.appendingPathComponent("Meetings", isDirectory: true))
        XCTAssertEqual(AppLog.fileURL, root.appendingPathComponent("murmurly.log"))
        XCTAssertTrue(
            root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        )
    }

    func testDefaultSettingsWriteToTheProcessSuiteNotTheStandardDomain() throws {
        let key = "ui.settingsTab"
        let isolated = try XCTUnwrap(UserDefaults(suiteName: TestIsolation.settingsSuiteName))
        let standardBefore = UserDefaults.standard.string(forKey: key)
        let settings = SettingsStore()
        let target: SettingsTab = settings.settingsTab == .files ? .storage : .files

        settings.settingsTab = target

        XCTAssertEqual(isolated.string(forKey: key), target.rawValue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), standardBefore)
        isolated.synchronize()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TestIsolation.root.appendingPathComponent("settings.plist").path
        ), "the isolated copy's settings are not in its temporary folder")
    }
}
