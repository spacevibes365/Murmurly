import Foundation

/// A test copy of the app (the unit-test host, every UI-test launch) must not
/// act on the user's machine: no global hotkeys, no watching real processes
/// for meetings, no writes into the user's archives, log or preferences, no
/// launch-time permission prompt. The stage-gate scheme sets
/// `MURMURLY_PRODUCTION_SERVICES=1`, so its production cold launch runs the
/// app as shipped. A UI test's launch is isolated whatever its environment:
/// it clicks through the app, and one click (the audio rule's Continue)
/// would otherwise set the owner's settings and act on their meetings.
enum TestIsolation {
    /// Any test launch: no launch-time prompt, model warm-up, recent history
    /// preload or login item.
    static let isTestProcess = classify(processInfo: .processInfo).testProcess
    /// A test launch without the stage gate's opt-out. Never true in Release,
    /// so a shipped build cannot send its archives to a temporary folder.
    static let isEnabled = classify(processInfo: .processInfo).isolated

    private static let launchID = UUID().uuidString
    /// Stands in for the archive and log folders of an isolated process.
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Murmurly-test-\(launchID)", isDirectory: true)
    /// This process's own preferences domain while isolated. An absolute path
    /// keeps the file inside `root` (`settings.plist`) instead of leaving one
    /// more domain in ~/Library/Preferences for every test launch.
    static let settingsSuiteName = root.appendingPathComponent("settings").path

    static func settingsDefaults() -> UserDefaults {
        settingsDefaults(isolated: isEnabled, standard: .standard, suiteName: settingsSuiteName)
    }

    /// `standard` (the app's own domain: the owner's, on their Mac) only for
    /// a launch that is not isolated.
    static func settingsDefaults(isolated: Bool, standard: UserDefaults, suiteName: String) -> UserDefaults {
        guard isolated else { return standard }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create the isolated settings suite")
        }
        return defaults
    }

    static func classify(
        arguments: [String], environment: [String: String]
    ) -> (testProcess: Bool, isolated: Bool) {
        let uiLaunch = arguments.contains("-UITesting") || arguments.contains("-UITestSettingsStore")
        let testProcess = uiLaunch || environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        // The opt-out is the stage gate's, whose tests run inside the app it
        // launched; an environment that reached a UI test's copy from
        // anywhere else opts nothing out.
        let isolated = uiLaunch || testProcess && environment["MURMURLY_PRODUCTION_SERVICES"] != "1"
        #else
        let isolated = false
        #endif
        return (testProcess, isolated)
    }

    static func classify(processInfo: ProcessInfo) -> (testProcess: Bool, isolated: Bool) {
        classify(arguments: processInfo.arguments, environment: processInfo.environment)
    }
}
