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
            // A UI test's copy is isolated whatever reached its environment.
            ("UI testing ignores the opt-out", ["Murmurly", "-UITesting", "-UITestSettingsStore"],
             ["MURMURLY_PRODUCTION_SERVICES": "1"], true, true),
            ("UI settings store ignores the opt-out", ["Murmurly", "-UITestSettingsStore"],
             ["MURMURLY_PRODUCTION_SERVICES": "1"], true, true),
            ("UI testing in a host with the opt-out", ["Murmurly", "-UITesting"], with("1"), true, true),
        ]
        for item in cases {
            let result = TestIsolation.classify(arguments: item.arguments, environment: item.environment)
            XCTAssertEqual(result.testProcess, item.testProcess, item.name)
            XCTAssertEqual(result.isolated, item.isolated, item.name)
        }
    }

    /// A UI test's launch with the stage gate's opt-out in its environment,
    /// as configured: the audio rule's Continue and a chosen meetings folder
    /// go to its own settings, never the owner's domain (a control domain
    /// stands in for it), and its meetings are the seeded or its own, never
    /// the owner's (a control root). The stage gate's hosted tests keep the
    /// owner's, as before.
    func testAUILaunchWithTheOptOutLeavesTheOwnersSettingsAndMeetingsAlone() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let ownerDomain = "io.github.spacevibes365.MurmurlyTests.Owner.\(UUID().uuidString)"
        let owner = try XCTUnwrap(UserDefaults(suiteName: ownerDomain))
        defer { owner.removePersistentDomain(forName: ownerDomain) }
        let ownersMeetings = base.appendingPathComponent("Owner/Meetings", isDirectory: true)
        let seeded = base.appendingPathComponent("Seeded", isDirectory: true)
        let isolatedRoot = base.appendingPathComponent("Isolated", isDirectory: true)
        let optOut = ["MURMURLY_PRODUCTION_SERVICES": "1"]

        let launches = [
            ["Murmurly", "-UITesting", "-UITestSettingsStore", "-MeetingsProbeRoot", seeded.path],
            ["Murmurly", "-UITestSettingsStore"],
        ]
        for (index, arguments) in launches.enumerated() {
            let launch = TestIsolation.classify(arguments: arguments, environment: optOut)
            let defaults = TestIsolation.settingsDefaults(
                isolated: launch.isolated, standard: owner, suiteName: base.appendingPathComponent("settings-\(index)").path
            )
            let settings = SettingsStore(defaults: defaults)
            settings.meetingAudioRetention = .month
            settings.meetingsFolderPath = base.path
            XCTAssertTrue(
                owner.persistentDomain(forName: ownerDomain)?.isEmpty ?? true,
                "\(arguments): the UI launch wrote the owner's settings"
            )
            XCTAssertEqual(defaults.integer(forKey: "meeting.audioRetentionDays"), 30)
            let meetings = RecordingsStore.meetingsRoot(
                arguments: arguments, isolated: launch.isolated, isolatedRoot: isolatedRoot, owners: ownersMeetings
            )
            XCTAssertNotEqual(meetings.standardizedFileURL.path, ownersMeetings.standardizedFileURL.path,
                              "\(arguments): the UI launch works on the owner's meetings")
        }

        let gate = TestIsolation.classify(
            arguments: ["Murmurly"], environment: optOut.merging(["XCTestConfigurationFilePath": "/tmp/gate"]) { $1 }
        )
        XCTAssertTrue(
            TestIsolation.settingsDefaults(isolated: gate.isolated, standard: owner, suiteName: base.appendingPathComponent("gate").path)
                === owner,
            "the stage gate lost its production settings"
        )
        XCTAssertEqual(
            RecordingsStore.meetingsRoot(arguments: ["Murmurly"], isolated: gate.isolated, isolatedRoot: isolatedRoot, owners: ownersMeetings),
            ownersMeetings
        )
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
        let target: SettingsTab = settings.settingsTab == .permissions ? .storage : .permissions

        settings.settingsTab = target

        XCTAssertEqual(isolated.string(forKey: key), target.rawValue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), standardBefore)
        isolated.synchronize()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TestIsolation.root.appendingPathComponent("settings.plist").path
        ), "the isolated copy's settings are not in its temporary folder")
    }
}
