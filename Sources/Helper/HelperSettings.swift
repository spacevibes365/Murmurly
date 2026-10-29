import Foundation

/// Where the helper reads its roots, its settings and its log from. In
/// Release there is exactly one answer (`standard`); in DEBUG, four
/// environment variables can replace all of it at once for a test, never
/// only some of them — a process missing one of the four always falls
/// through to `standard` would read the owner's own archive, which no test
/// may ever touch.
struct HelperEnvironment: Sendable {
    enum SettingsSource: Sendable {
        case domain(String)
        case file(URL)
    }

    let meetingsRoot: URL
    let dictationsRoot: URL
    let settingsSource: SettingsSource
    let logURL: URL
    /// `HelperContract.maxResponseBytes` in Release and, absent an override,
    /// in DEBUG too; a DEBUG-only `MURMURLY_HELPER_MAX_BYTES` can shrink it
    /// for a test that needs to exercise truncation without building a
    /// megabyte of fixture data. It is independent of the four roots/
    /// settings/log overrides — optional on its own, never part of their
    /// all-or-nothing rule. The CLI's own limit; `murmurly mcp` uses
    /// `maxMCPResponseBytes` below instead.
    let maxResponseBytes: Int
    /// `HelperContract.maxMCPResponseBytes` in Release and, absent an
    /// override, in DEBUG too. The same `MURMURLY_HELPER_MAX_BYTES` override
    /// that shrinks `maxResponseBytes` shrinks this one too (to the same
    /// value): a test asking for a small limit means a small limit for
    /// whichever caller it is exercising, CLI or MCP, never only one of them.
    let maxMCPResponseBytes: Int

    private static let overrideKeys = [
        "MURMURLY_HELPER_MEETINGS_ROOT",
        "MURMURLY_HELPER_DICTATIONS_ROOT",
        "MURMURLY_HELPER_SETTINGS",
        "MURMURLY_HELPER_LOG",
    ]
    private static let maxBytesOverrideKey = "MURMURLY_HELPER_MAX_BYTES"

    static func standard() -> HelperEnvironment {
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("Murmurly", isDirectory: true)
        let logs = (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library"))
            .appendingPathComponent("Logs/Murmurly", isDirectory: true)
        return HelperEnvironment(
            meetingsRoot: support.appendingPathComponent("Meetings", isDirectory: true),
            dictationsRoot: support.appendingPathComponent("Dictations", isDirectory: true),
            settingsSource: .domain(HelperContract.appDomain),
            logURL: logs.appendingPathComponent("agents.log"),
            maxResponseBytes: HelperContract.maxResponseBytes,
            maxMCPResponseBytes: HelperContract.maxMCPResponseBytes
        )
    }

    #if DEBUG
    /// Nil absent a positive override: each caller then falls back to its
    /// own default (the CLI's megabyte, or the MCP server's 64 KiB).
    private static func maxBytesOverride(_ environment: [String: String]) -> Int? {
        guard let raw = environment[maxBytesOverrideKey], let value = Int(raw), value > 0 else { return nil }
        return value
    }
    #endif

    /// Nil only for a partial set of the four root/settings/log overrides:
    /// all four, or none, never one to three. The caller treats `nil` as a
    /// usage error, before any settings or archive read.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperEnvironment? {
        #if DEBUG
        let present = overrideKeys.filter { environment[$0]?.isEmpty == false }
        if present.isEmpty {
            let base = standard()
            return HelperEnvironment(
                meetingsRoot: base.meetingsRoot, dictationsRoot: base.dictationsRoot,
                settingsSource: base.settingsSource, logURL: base.logURL,
                maxResponseBytes: maxBytesOverride(environment) ?? HelperContract.maxResponseBytes,
                maxMCPResponseBytes: maxBytesOverride(environment) ?? HelperContract.maxMCPResponseBytes
            )
        }
        guard present.count == overrideKeys.count,
              let meetings = environment[overrideKeys[0]],
              let dictations = environment[overrideKeys[1]],
              let settings = environment[overrideKeys[2]],
              let log = environment[overrideKeys[3]]
        else { return nil }
        return HelperEnvironment(
            meetingsRoot: URL(fileURLWithPath: meetings, isDirectory: true),
            dictationsRoot: URL(fileURLWithPath: dictations, isDirectory: true),
            settingsSource: .file(URL(fileURLWithPath: settings)),
            logURL: URL(fileURLWithPath: log),
            maxResponseBytes: maxBytesOverride(environment) ?? HelperContract.maxResponseBytes,
            maxMCPResponseBytes: maxBytesOverride(environment) ?? HelperContract.maxMCPResponseBytes
        )
        #else
        return standard()
        #endif
    }

    #if DEBUG
    /// While this names a path that exists, `perform` (`Commands.swift`)
    /// waits before touching settings or the archive: a stand-in for a hung
    /// network volume, so a test can exercise the MCP server's timeout and
    /// cancellation without an actual slow folder.
    static func debugHoldPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["MURMURLY_HELPER_HOLD"]
    }

    /// While this names a path that exists, `listMeetings` (`Commands.swift`)
    /// waits before reading the local meetings root — only the local root,
    /// so a test can hold it slow while the chosen root (under its own, much
    /// shorter timeout) answers normally, and check that the chosen root's
    /// meetings still come back rather than both roots being lost to one
    /// shared budget.
    static func debugHoldLocalPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["MURMURLY_HELPER_HOLD_LOCAL"]
    }

    /// While this names a path that exists, `requireStillAllowed`
    /// (`Commands.swift`) marks `<path>.reached` and then waits for `<path>`
    /// itself to be removed, right before its own fresh settings read: a test
    /// can act (change settings, then release the hold) while a call is
    /// paused at the very point whose whole purpose is to see that change.
    static func debugHoldAnswerPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["MURMURLY_HELPER_HOLD_ANSWER"]
    }

    /// While this names a path that exists, `readChosenRoot` (`Commands.swift`)
    /// waits before reading the chosen root — set before entering its own 5 s
    /// timeout, so a test can hold a read there and check that a second call,
    /// made while the first is still held, answers `notResponding` at once
    /// instead of starting a second hung read of its own.
    static func debugHoldChosenPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["MURMURLY_HELPER_HOLD_CHOSEN"]
    }

    /// A DEBUG-only override for the MCP server's per-`tools/call` timeout
    /// (seconds); absent or not a positive number leaves the 30 s default.
    static func debugTimeoutSeconds(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        guard let raw = environment["MURMURLY_HELPER_TIMEOUT"], let value = Double(raw), value > 0 else { return nil }
        return value
    }
    #endif
}

/// The agent-facing settings: whether each source is turned on, the period
/// and the chosen meetings folder, read fresh on every call (never cached):
/// a change to `meeting.storageFolder` or the switches must be seen by the
/// very next call, and the access check right before printing must see a
/// switch turned off between the start of the call and its end.
struct HelperSettings: Sendable {
    let meetingsEnabled: Bool
    let dictationsEnabled: Bool
    /// `0` means the whole history.
    let periodDays: Int
    let chosenMeetingsFolder: URL?

    enum LoadError: Error {
        /// `agents.periodDays` is set but is not a non-negative whole number.
        case periodDaysUnreadable
    }

    static func load(from source: HelperEnvironment.SettingsSource) throws -> HelperSettings {
        let reader = Reader(source: source)
        guard let periodDays = try reader.periodDays() else {
            throw LoadError.periodDaysUnreadable
        }
        let folderPath = reader.string(HelperContract.SettingsKey.meetingsFolder)
        let chosen = (folderPath?.isEmpty == false) ? URL(fileURLWithPath: folderPath!, isDirectory: true) : nil
        return HelperSettings(
            meetingsEnabled: reader.bool(HelperContract.SettingsKey.agentsMeetings),
            dictationsEnabled: reader.bool(HelperContract.SettingsKey.agentsDictations),
            periodDays: periodDays,
            chosenMeetingsFolder: chosen
        )
    }

    /// One place that reads a raw value from either source, so the domain
    /// and the DEBUG file agree on every key's type rules.
    private struct Reader {
        let source: HelperEnvironment.SettingsSource

        func raw(_ key: String) -> Any? {
            switch source {
            case .domain(let domain):
                CFPreferencesAppSynchronize(domain as CFString)
                return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
            case .file(let url):
                return NSDictionary(contentsOf: url)?[key]
            }
        }

        func bool(_ key: String) -> Bool {
            guard let value = raw(key) as? NSNumber, HelperContract.isBooleanNumber(value) else { return false }
            return value.boolValue
        }

        func string(_ key: String) -> String? {
            raw(key) as? String
        }

        /// The one rule in `HelperContract.periodDays(fromStored:)`, applied
        /// to this process's own raw read.
        func periodDays() throws -> Int? {
            HelperContract.periodDays(fromStored: raw(HelperContract.SettingsKey.periodDays))
        }
    }
}
