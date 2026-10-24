import Foundation
import KeyboardShortcuts
import XCTest
@testable import Murmurly

/// Test isolation at the real system boundaries, inside the unit-test host. The host is a
/// test copy of the app, so it must leave the user's hotkeys, processes,
/// archives, log and preferences alone. Only API that exists before the fix,
/// plus the DEBUG registration counter, so the same file runs on both trees,
/// plus the last-dictation registration.
@MainActor
final class TestIsolationTests: XCTestCase {
    func testTestHostRegistersNoGlobalHotkeys() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.Isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.hotkeyActivation = .doubleModifier
        let before = HotkeyManager.systemRegistrationsForTesting

        // The test itself asks for every registration, so the result does not
        // depend on when the host's own launch activation ran.
        let manager = HotkeyManager()
        manager.activate(settings: settings, onToggle: {}, isRecording: { false })
        HotkeyManager.registerMeeting {}
        HotkeyManager.registerLastDictation(onPasteDown: {}, onPasteUp: {}, onCopy: {})

        XCTAssertEqual(
            HotkeyManager.systemRegistrationsForTesting - before, 0,
            "the test copy registered global hotkeys or monitors"
        )
        withExtendedLifetime(manager) {}
    }

    func testTestHostDoesNotReadRealProcesses() {
        XCTAssertNil(
            MeetingWatchdog.readSystemSnapshot(),
            "the test copy reads real CoreAudio processes"
        )
    }

    func testTestHostArchivesStayOutOfTheUsersLibrary() {
        let owner = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmurly", isDirectory: true)
        // `DictationHistoryStore.shared` is built with `defaultRoot()`.
        for root in [DictationHistoryStore.defaultRoot(), RecordingsStore.meetingsRoot()] {
            XCTAssertFalse(isInside(root, owner), "the test copy's archive is in the owner's folder: \(root.path)")
        }
    }

    func testTestHostLogStaysOutOfTheUsersLogs() {
        let owner = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Murmurly", isDirectory: true)
        XCTAssertFalse(
            isInside(AppLog.fileURL, owner),
            "the test copy writes to the owner's log: \(AppLog.fileURL.path)"
        )
    }

    func testOurShortcutNamesSeedNothingInATestHost() {
        // KeyboardShortcuts writes an initial combination into the standard
        // domain the first time a name that has one is touched.
        XCTAssertNil(KeyboardShortcuts.Name.dictate.initialShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.meeting.initialShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.pasteLastDictation.initialShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.copyLastDictation.initialShortcut)
    }

    func testInjectedSnapshotStillDrivesTheWatchdog() {
        var triggers: [String] = []
        let watchdog = MeetingWatchdog(
            snapshotSource: {
                [MeetingWatchdog.ProcessSnapshot(pid: 42, bundleID: "company.call", isRunningInput: true)]
            },
            recorderState: { .idle },
            requestStart: { trigger in
                triggers.append(trigger)
                return true
            },
            requestStop: {}
        )
        watchdog.tick()
        XCTAssertEqual(triggers, ["company.call"])
    }

    private func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }
}
