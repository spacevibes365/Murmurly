import XCTest
import Darwin
@testable import Murmurly

/// `/var` is a symlink to `/private/var`, so a URL made from
/// `FileManager.default.temporaryDirectory` and the physical path
/// `FileManager.default.contentsOfDirectory(at:)` actually lists differ in
/// that one component; `URL.resolvingSymlinksInPath()` special-cases `/var`
/// and leaves it unresolved, so only `realpath(3)` gives a path comparable
/// to what directory listing returns.
private func canonicalPath(_ url: URL) -> String {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url.path }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// `AgentConnections` runs `claude`/`codex` as `Process` with argument
/// arrays, never a shell, and never touches a real client in a test
/// process. Every fake below only records calls and returns canned
/// `RunResult`s; none launches anything. Paths are made-up, inside
/// `FileManager.default.temporaryDirectory` — never a literal home folder path.
@MainActor
final class AgentConnectionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-connections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A made-up installed copy, with an executable helper

    private func makeInstalledBundle(named name: String = "Murmurly.app") throws -> URL {
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        let helperURL = AgentConnections.helperURL(bundleURL: bundleURL)
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        return bundleURL
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "agent-connections-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeConnections(
        bundleURL: URL,
        installedBundlePaths: [String]? = nil,
        home: URL? = nil,
        locate: @escaping (AgentClientKind) -> String? = { _ in nil },
        run: @escaping Runner = { _, _, _, _, _ in .exited(status: 0, stdout: "", stderr: "") },
        install: @escaping Installer = { _, _, _ in .failed("not used") },
        linkURL: URL? = nil,
        copy: @escaping (String) -> Void = { _ in }
    ) -> AgentConnections {
        AgentConnections(
            defaults: makeDefaults(),
            bundleURL: bundleURL,
            installedBundlePaths: installedBundlePaths ?? [bundleURL.path],
            home: home ?? root.appendingPathComponent("home", isDirectory: true),
            locate: locate,
            run: run,
            install: install,
            linkURL: linkURL ?? root.appendingPathComponent("usr-local-bin-murmurly"),
            copy: copy
        )
    }

    // MARK: - A fake client: remembers one registration by name, like `claude`/`codex` would

    private actor FakeClient {
        struct Call: Equatable {
            let executable: URL
            let arguments: [String]
        }

        private(set) var calls: [Call] = []
        private var registeredHelperPath: String?
        private let kind: AgentClientKind

        init(kind: AgentClientKind, registeredHelperPath: String? = nil) {
            self.kind = kind
            self.registeredHelperPath = registeredHelperPath
        }

        func entryCount() -> Int { registeredHelperPath == nil ? 0 : 1 }
        func currentPath() -> String? { registeredHelperPath }

        func run(
            executable: URL, arguments: [String], environment: [String: String], directory: URL, timeout: Duration
        ) async -> RunResult {
            calls.append(Call(executable: executable, arguments: arguments))
            guard arguments.count > 1 else { return .exited(status: 1, stdout: "", stderr: "bad arguments") }
            switch arguments[1] {
            case "remove":
                if let removed = registeredHelperPath {
                    registeredHelperPath = nil
                    return .exited(status: 0, stdout: "Removed murmurly (was \(removed))", stderr: "")
                }
                return .exited(status: 1, stdout: "", stderr: "No MCP server found with name: murmurly")
            case "add":
                guard let separator = arguments.firstIndex(of: "--"), arguments.count > separator + 1 else {
                    return .exited(status: 1, stdout: "", stderr: "missing --")
                }
                if registeredHelperPath != nil {
                    return .exited(status: 1, stdout: "", stderr: "A server named murmurly already exists")
                }
                registeredHelperPath = arguments[separator + 1]
                return .exited(status: 0, stdout: "Added murmurly", stderr: "")
            case "get":
                guard let path = registeredHelperPath else {
                    return .exited(status: 1, stdout: "", stderr: "No MCP server found with name: murmurly")
                }
                switch kind {
                case .claudeCode:
                    return .exited(status: 0, stdout: "murmurly: \(path) mcp  - ✓ Connected", stderr: "")
                case .codex:
                    let json = "{\"mcpServers\":{\"murmurly\":{\"command\":\"\(path)\",\"args\":[\"mcp\"]}}}"
                    return .exited(status: 0, stdout: json, stderr: "")
                }
            default:
                return .exited(status: 1, stdout: "", stderr: "unknown subcommand")
            }
        }
    }

    // MARK: - A runner that plays back a fixed script of results, in order

    private actor ScriptedRunner {
        private(set) var calls: [[String]] = []
        private var script: [RunResult]
        init(_ script: [RunResult]) { self.script = script }
        func run(
            executable: URL, arguments: [String], environment: [String: String], directory: URL, timeout: Duration
        ) async -> RunResult {
            calls.append(arguments)
            guard !script.isEmpty else { return .exited(status: 0, stdout: "", stderr: "") }
            return script.removeFirst()
        }
    }

    // MARK: - A collecting fake for `copy`

    private final class CopyBox {
        private(set) var texts: [String] = []
        func copy(_ text: String) { texts.append(text) }
    }

    /// `run`/`install` are `@Sendable`: a closure of that type may not
    /// capture a mutable local variable, so a flag set from inside one
    /// goes through this lock-guarded box instead.
    private final class CallFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: - 1-4: the full remove/add/get flow

    func testClaudeConnectRunsRemoveAddGetAsArgumentArrays() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let client = FakeClient(kind: .claudeCode)
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await client.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) }
        )

        await connections.connect(.claudeCode)

        let calls = await client.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].executable.path, "/opt/homebrew/bin/claude")
        XCTAssertEqual(calls[0].arguments, ["mcp", "remove", "--scope", "user", "murmurly"])
        XCTAssertEqual(calls[1].arguments, ["mcp", "add", "--scope", "user", "murmurly", "--", helperPath, "mcp"])
        XCTAssertEqual(calls[2].arguments, ["mcp", "get", "murmurly"])
        for call in calls {
            XCTAssertNotEqual(call.executable.path, "/bin/sh")
            XCTAssertNotEqual(call.executable.path, "/bin/zsh")
        }
        XCTAssertEqual(connections.status(for: .claudeCode), .connected)
    }

    func testCodexConnectRunsRemoveAddGetJSON() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let client = FakeClient(kind: .codex)
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in "/opt/homebrew/bin/codex" },
            run: { exe, args, env, dir, timeout in await client.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) }
        )

        await connections.connect(.codex)

        let calls = await client.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].arguments, ["mcp", "remove", "murmurly"])
        XCTAssertEqual(calls[1].arguments, ["mcp", "add", "murmurly", "--", helperPath, "mcp"])
        XCTAssertEqual(calls[2].arguments, ["mcp", "get", "murmurly", "--json"])
        XCTAssertEqual(connections.status(for: .codex), .connected)
    }

    func testExistingServerWithOldCopyPathIsReplacedNotDuplicated() async throws {
        let bundleURL = try makeInstalledBundle()
        let client = FakeClient(kind: .claudeCode, registeredHelperPath: "/some/old/copy/Contents/Helpers/murmurly")
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await client.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) }
        )

        await connections.connect(.claudeCode)

        let entryCount = await client.entryCount()
        let currentPath = await client.currentPath()
        XCTAssertEqual(entryCount, 1)
        XCTAssertEqual(currentPath, AgentConnections.helperURL(bundleURL: bundleURL).path)
        XCTAssertEqual(connections.status(for: .claudeCode), .connected)
    }

    func testSecondConnectLeavesOneEntry() async throws {
        let bundleURL = try makeInstalledBundle()
        let client = FakeClient(kind: .claudeCode)
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await client.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) }
        )

        await connections.connect(.claudeCode)
        await connections.connect(.claudeCode)

        let entryCount = await client.entryCount()
        XCTAssertEqual(entryCount, 1)
        XCTAssertEqual(connections.status(for: .claudeCode), .connected)
    }

    // MARK: - 5-6: timeout and verification failure

    func testTimeoutOnAddStopsAndReports() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let runner = ScriptedRunner([
            .exited(status: 1, stdout: "", stderr: "No MCP server found with name: murmurly"), // remove
            .timedOut, // add
        ])
        let copyBox = CopyBox()
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await runner.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) },
            copy: { copyBox.copy($0) }
        )

        await connections.connect(.claudeCode)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2, "the verify step must not run after a timed-out add")
        XCTAssertEqual(connections.status(for: .claudeCode), .timedOut)

        connections.copyConnectCommand(for: .claudeCode)
        XCTAssertEqual(
            copyBox.texts,
            ["claude mcp remove --scope user murmurly; claude mcp add --scope user murmurly -- '\(helperPath)' mcp"]
        )
    }

    func testVerificationWithoutHelperPathIsAFailure() async throws {
        let bundleURL = try makeInstalledBundle()
        let runner = ScriptedRunner([
            .exited(status: 1, stdout: "", stderr: "No MCP server found with name: murmurly"), // remove
            .exited(status: 0, stdout: "Added murmurly", stderr: ""), // add
            .exited(status: 0, stdout: "murmurly: node mcp  - ✓ Connected", stderr: ""), // get, no helper path in it
        ])
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await runner.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) }
        )

        await connections.connect(.claudeCode)

        XCTAssertEqual(connections.status(for: .claudeCode), .verificationFailed)
    }

    // MARK: - 7: not found offers "Copy Command" and runs nothing

    func testNotFoundOffersCopyCommandAndRunsNothing() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let runnerCalled = CallFlag()
        let copyBox = CopyBox()
        let connections = makeConnections(
            bundleURL: bundleURL,
            locate: { _ in nil },
            run: { _, _, _, _, _ in runnerCalled.set(); return .exited(status: 0, stdout: "", stderr: "") },
            copy: { copyBox.copy($0) }
        )

        await connections.connect(.claudeCode)
        XCTAssertEqual(connections.status(for: .claudeCode), .clientNotFound)
        XCTAssertFalse(runnerCalled.get())

        connections.copyConnectCommand(for: .claudeCode)
        XCTAssertEqual(
            copyBox.texts,
            ["claude mcp remove --scope user murmurly; claude mcp add --scope user murmurly -- '\(helperPath)' mcp"]
        )

        await connections.connect(.codex)
        connections.copyConnectCommand(for: .codex)
        XCTAssertEqual(copyBox.texts.last, "codex mcp remove murmurly; codex mcp add murmurly -- '\(helperPath)' mcp")
    }

    // MARK: - 8: the locator

    func testLocatorFindsUsualPlacesAndSkipsNonExecutable() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let nonExecutable = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: nonExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not executable".write(to: nonExecutable, atomically: true, encoding: .utf8)

        let oldVersion = home.appendingPathComponent(".nvm/versions/node/v9.0.0/bin/claude")
        let newVersion = home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin/claude")
        for url in [oldVersion, newVersion] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        // Scoped to `home`: a candidate outside it (e.g. a real `/opt/homebrew/bin/claude`
        // on the Mac actually running this test) must never count as found.
        let homeCanonical = canonicalPath(home)
        let found = AgentLocator.locate(
            kind: .claudeCode, home: home, processPath: "",
            isExecutableFile: { canonicalPath(URL(fileURLWithPath: $0)).hasPrefix(homeCanonical) && FileManager.default.isExecutableFile(atPath: $0) }
        )
        // `nvmCandidates` builds its paths from `contentsOfDirectory`, which returns
        // the physical form (`/private/var/…`), not the `/var/…` form `newVersion` was
        // built with, so the expectation goes through the same canonicalization.
        XCTAssertEqual(found, canonicalPath(newVersion), "the newer nvm version must win over v9")
    }

    // MARK: - 9: the child's PATH

    func testChildPathStartsWithTheProgramsFolder() throws {
        let found = "/opt/homebrew/bin/claude"
        let home = root.appendingPathComponent("home", isDirectory: true)
        let environment = AgentLocator.childEnvironment(appEnvironment: [:], foundExecutablePath: found, home: home)
        let path = try XCTUnwrap(environment["PATH"])
        let folders = path.split(separator: ":").map(String.init)
        XCTAssertEqual(folders.first, "/opt/homebrew/bin")
        XCTAssertTrue(folders.contains("/opt/homebrew/bin"))
    }

    // MARK: - 10: the running copy's own helper

    func testHelperPathIsTheRunningCopy() throws {
        let bundleURL = Bundle.main.bundleURL
        let helperURL = AgentConnections.helperURL(bundleURL: bundleURL)
        XCTAssertEqual(helperURL.path, bundleURL.appendingPathComponent("Contents/Helpers/murmurly").path)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw XCTSkip("the murmurly helper is not embedded in this build")
        }
    }

    // MARK: - 11: a moved app shows "outdated"; connecting fixes it

    func testMovedAppShowsOutdatedAndUpdateFixesIt() async throws {
        let oldBundleURL = root.appendingPathComponent("Applications/Murmurly.app", isDirectory: true)
        let oldHelperURL = AgentConnections.helperURL(bundleURL: oldBundleURL)
        try FileManager.default.createDirectory(at: oldHelperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: oldHelperURL, atomically: true, encoding: .utf8)

        let newBundleURL = try makeInstalledBundle(named: "NewMurmurly.app")
        let defaults = makeDefaults()
        defaults.set(oldHelperURL.path, forKey: "agents.claudeCode.helperPath")

        let client = FakeClient(kind: .claudeCode, registeredHelperPath: oldHelperURL.path)
        let connections = AgentConnections(
            defaults: defaults,
            bundleURL: newBundleURL,
            installedBundlePaths: [newBundleURL.path],
            home: root.appendingPathComponent("home", isDirectory: true),
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await client.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) },
            install: { _, _, _ in .failed("not used") },
            linkURL: root.appendingPathComponent("usr-local-bin-murmurly")
        )

        guard case .outdated(let saved) = connections.status(for: .claudeCode) else {
            return XCTFail("expected outdated, got \(connections.status(for: .claudeCode))")
        }
        XCTAssertEqual(saved, oldHelperURL.path)

        await connections.connect(.claudeCode)
        XCTAssertEqual(connections.status(for: .claudeCode), .connected)
        let currentPath = await client.currentPath()
        XCTAssertEqual(currentPath, AgentConnections.helperURL(bundleURL: newBundleURL).path)
    }

    // MARK: - 12: a copy outside Applications refuses to connect

    func testCopyOutsideApplicationsRefusesToConnect() async throws {
        let derivedDataBundle = root.appendingPathComponent("DerivedData/Build/Products/Debug/Murmurly.app", isDirectory: true)
        let helperURL = AgentConnections.helperURL(bundleURL: derivedDataBundle)
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let runnerCalled = CallFlag()
        let connections = makeConnections(
            bundleURL: derivedDataBundle,
            installedBundlePaths: [root.appendingPathComponent("Applications/Murmurly.app").path],
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { _, _, _, _, _ in runnerCalled.set(); return .exited(status: 0, stdout: "", stderr: "") }
        )

        XCTAssertFalse(connections.isInstalledCopy)
        await connections.connect(.claudeCode)
        XCTAssertFalse(runnerCalled.get())
        XCTAssertEqual(connections.status(for: .claudeCode), .notConnected)
    }

    // MARK: - 13: the terminal link's states

    func testTerminalLinkStates() throws {
        let helperPath = root.appendingPathComponent("Murmurly.app/Contents/Helpers/murmurly").path

        let missing = root.appendingPathComponent("missing")
        XCTAssertEqual(TerminalCommandInstaller.linkStatus(linkURL: missing, helperPath: helperPath), .notInstalled)

        let current = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: helperPath)
        XCTAssertEqual(TerminalCommandInstaller.linkStatus(linkURL: current, helperPath: helperPath), .installed)

        let old = root.appendingPathComponent("old")
        let oldTarget = root.appendingPathComponent("Old.app/Contents/Helpers/murmurly").path
        try FileManager.default.createSymbolicLink(atPath: old.path, withDestinationPath: oldTarget)
        XCTAssertEqual(TerminalCommandInstaller.linkStatus(linkURL: old, helperPath: helperPath), .outdated(target: oldTarget))

        let foreignLink = root.appendingPathComponent("foreignLink")
        try FileManager.default.createSymbolicLink(atPath: foreignLink.path, withDestinationPath: "/bin/ls")
        XCTAssertEqual(TerminalCommandInstaller.linkStatus(linkURL: foreignLink, helperPath: helperPath), .foreign)

        let plainFile = root.appendingPathComponent("plainFile")
        try "not a link".write(to: plainFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(TerminalCommandInstaller.linkStatus(linkURL: plainFile, helperPath: helperPath), .foreign)
    }

    // MARK: - 14-16: installing the Terminal command

    func testInstallRefusesForeignFileWithoutAsking() async throws {
        let bundleURL = try makeInstalledBundle()
        let linkURL = root.appendingPathComponent("foreignFile")
        try "someone else's file".write(to: linkURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: linkURL)

        let installCalled = CallFlag()
        let connections = makeConnections(
            bundleURL: bundleURL,
            install: { _, _, _ in installCalled.set(); return .done },
            linkURL: linkURL
        )

        await connections.installTerminalCommand()
        XCTAssertFalse(installCalled.get())
        XCTAssertEqual(connections.terminalLinkStatus, .foreign)
        let after = try Data(contentsOf: linkURL)
        XCTAssertEqual(before, after)
    }

    func testInstallUpdatesOutdatedLink() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let linkURL = root.appendingPathComponent("murmurly-link")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path, withDestinationPath: root.appendingPathComponent("Old.app/Contents/Helpers/murmurly").path
        )

        let connections = makeConnections(
            bundleURL: bundleURL,
            install: { helper, link, _ in
                try? FileManager.default.removeItem(at: link)
                try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper)
                return .done
            },
            linkURL: linkURL
        )

        await connections.installTerminalCommand()
        XCTAssertEqual(connections.terminalLinkStatus, .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), helperPath)
    }

    func testCancelledPasswordOffersCopyCommand() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let copyBox = CopyBox()
        let connections = makeConnections(
            bundleURL: bundleURL,
            install: { _, _, _ in .cancelled },
            linkURL: root.appendingPathComponent("murmurly-link"),
            copy: { copyBox.copy($0) }
        )

        await connections.installTerminalCommand()
        XCTAssertNotNil(connections.terminalInstallError)

        connections.copyTerminalCommand()
        XCTAssertEqual(copyBox.texts, [
            "sudo mkdir -p /usr/local/bin && if [ -e /usr/local/bin/murmurly ] && [ ! -L /usr/local/bin/murmurly ]; " +
            "then echo 'murmurly: /usr/local/bin/murmurly is not a link; left as it is' >&2; " +
            "else sudo ln -sfh '\(helperPath)' /usr/local/bin/murmurly; fi",
        ])
    }

    // MARK: - 17: the privileged install's arguments

    func testPrivilegedInstallPassesPathAsArgument() throws {
        let helper = "/Applications/Murmurly.app/Contents/Helpers/murmurly"
        let link = URL(fileURLWithPath: "/usr/local/bin/murmurly")
        let prompt = "Murmurly wants to install the murmurly command in /usr/local/bin."

        let arguments = TerminalCommandInstaller.arguments(helper: helper, link: link, prompt: prompt)

        let scriptArguments = Set(arguments.enumerated().filter { $0.offset % 2 == 1 && arguments[$0.offset - 1] == "-e" }.map { $0.element })
        for scriptText in scriptArguments {
            XCTAssertFalse(scriptText.contains(helper), "the helper path must never be interpolated into the script text")
        }
        XCTAssertTrue(arguments.contains(helper))
        XCTAssertTrue(arguments.contains(link.path))
        XCTAssertTrue(arguments.contains(link.deletingLastPathComponent().path))
        XCTAssertTrue(arguments.contains(prompt))
        XCTAssertEqual(Array(arguments.suffix(4)), [helper, link.path, link.deletingLastPathComponent().path, prompt])
    }

    /// The `-e` statement that runs the privileged shell command must check,
    /// before ever reaching `ln -sfh`, that the install address holds nothing
    /// or already a symbolic link — a file that appeared there only while the
    /// password prompt was up must not be replaced.
    func testPrivilegedInstallRefusesNonLinkBeforeLinking() throws {
        let helper = "/Applications/Murmurly.app/Contents/Helpers/murmurly"
        let link = URL(fileURLWithPath: "/usr/local/bin/murmurly")
        let prompt = "Murmurly wants to install the murmurly command in /usr/local/bin."

        let arguments = TerminalCommandInstaller.arguments(helper: helper, link: link, prompt: prompt)
        let script = try XCTUnwrap(arguments.first { $0.contains("do shell script") })

        let checkRange = try XCTUnwrap(script.range(of: "item 2 of argv"))
        let notLinkRange = try XCTUnwrap(script.range(of: "! -L"))
        // The literal exit code, never `TerminalCommandInstaller`'s own
        // constant: this test must fail to find the check at all on code
        // that predates it, not fail to build.
        let exitRange = try XCTUnwrap(script.range(of: "exit 17"))
        let linkRange = try XCTUnwrap(script.range(of: "ln -sfh"))
        XCTAssertLessThan(checkRange.lowerBound, linkRange.lowerBound, "the non-link check must run before `ln -sfh`")
        XCTAssertLessThan(notLinkRange.lowerBound, linkRange.lowerBound)
        XCTAssertLessThan(exitRange.lowerBound, linkRange.lowerBound)
        XCTAssertFalse(script.contains(helper), "the helper path must never be interpolated into the script text")
    }

    /// Same check, in the command offered for Terminal: it must also refuse a
    /// non-link at the address rather than run `ln -sfh` over it.
    func testCopiedTerminalCommandRefusesNonLink() throws {
        let helperPath = "/Applications/Murmurly.app/Contents/Helpers/murmurly"
        let command = TerminalCommandInstaller.terminalCommandLine(helperPath: helperPath)

        XCTAssertTrue(command.contains("/usr/local/bin/murmurly"))
        let notLinkRange = try XCTUnwrap(command.range(of: "! -L"))
        let linkRange = try XCTUnwrap(command.range(of: "ln -sfh"))
        XCTAssertLessThan(notLinkRange.lowerBound, linkRange.lowerBound, "the non-link check must run before `ln -sfh`")
    }

    /// A plain file appearing at the install address exactly while the
    /// password prompt is up — the installer's own stub plants it, standing
    /// in for the real osascript's privileged script refusing to replace it
    /// — must read back as `.foreign`, shown the same way as any other
    /// foreign file, never as an install error.
    func testFileAppearingDuringInstallIsForeignNotAnError() async throws {
        let bundleURL = try makeInstalledBundle()
        let linkURL = root.appendingPathComponent("murmurly-link")
        let foreignContents = Data("someone else's file".utf8)

        let connections = makeConnections(
            bundleURL: bundleURL,
            install: { _, link, _ in
                try? foreignContents.write(to: link)
                return .failed("ln: not a symbolic link")
            },
            linkURL: linkURL
        )

        await connections.installTerminalCommand()
        XCTAssertEqual(connections.terminalLinkStatus, .foreign)
        XCTAssertNil(connections.terminalInstallError)
        XCTAssertEqual(try Data(contentsOf: linkURL), foreignContents)
    }

    // MARK: - 18: the live process runner, no shell, with a timeout; and `live()` in a test process

    func testProcessRunnerUsesNoShellAndTimesOut() async throws {
        let printfResult = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s|", "a b", "; echo x"],
            environment: [:],
            directory: FileManager.default.temporaryDirectory,
            timeout: .seconds(5)
        )
        guard case .exited(let status, let stdout, _) = printfResult else {
            return XCTFail("expected printf to exit, got \(printfResult)")
        }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(stdout, "a b|; echo x|")

        let start = Date()
        let sleepResult = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: [:],
            directory: FileManager.default.temporaryDirectory,
            timeout: .milliseconds(300)
        )
        XCTAssertEqual(sleepResult, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        // `AgentConnections.live()` in this (test) process is never the installed
        // copy (`installedBundlePaths: []`), so `connect` leaves the status
        // untouched instead of reaching out to a real client, and the install
        // stays off.
        let liveConnections = AgentConnections.live()
        await liveConnections.connect(.claudeCode)
        XCTAssertEqual(liveConnections.status(for: .claudeCode), .notConnected)
        await liveConnections.installTerminalCommand()
        XCTAssertFalse(liveConnections.isInstallingTerminalCommand)
    }

    // MARK: - K1: a fresh read that already finds the link installed skips the installer

    func testInstallSkipsInstallerWhenFreshReadIsAlreadyInstalled() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let linkURL = root.appendingPathComponent("murmurly-link")
        let installCalled = CallFlag()
        let connections = makeConnections(
            bundleURL: bundleURL,
            install: { _, _, _ in installCalled.set(); return .done },
            linkURL: linkURL
        )
        // At construction the link did not exist yet, so the initial read is notInstalled.
        XCTAssertEqual(connections.terminalLinkStatus, .notInstalled)

        // Someone else made the link point at this copy's helper in the meantime.
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: helperPath)

        await connections.installTerminalCommand()
        XCTAssertFalse(installCalled.get(), "already installed: no privileged install call")
        XCTAssertEqual(connections.terminalLinkStatus, .installed)
    }

    /// A fresh `.installed` read — whether from `refreshTerminalLinkStatus()`
    /// or from `installTerminalCommand()`'s own early-out when the link
    /// already points at this copy's helper — clears an earlier install
    /// error (a cancelled password prompt, a failure): the error described a
    /// state that is no longer true, including when the user ran the copied
    /// command by hand instead of retrying the button.
    func testInstalledLinkClearsEarlierInstallError() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let linkURL = root.appendingPathComponent("murmurly-link")
        let connections = makeConnections(
            bundleURL: bundleURL,
            install: { _, _, _ in .cancelled },
            linkURL: linkURL
        )

        await connections.installTerminalCommand()
        XCTAssertNotNil(connections.terminalInstallError)

        // The user ran the copied command themselves: the link now points
        // at the running copy's helper, outside the app's own install flow.
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: helperPath)
        connections.refreshTerminalLinkStatus()
        XCTAssertEqual(connections.terminalLinkStatus, .installed)
        XCTAssertNil(connections.terminalInstallError)
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: connections.terminalLinkStatus, hasInstallError: false))

        // A second round: get the error again, then clear it by calling
        // `installTerminalCommand()` itself while the link is installed.
        try FileManager.default.removeItem(at: linkURL)
        await connections.installTerminalCommand()
        XCTAssertNotNil(connections.terminalInstallError)

        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: helperPath)
        await connections.installTerminalCommand()
        XCTAssertNil(connections.terminalInstallError)
    }

    // MARK: - K2: a timed-out or failed-to-launch `add` after a completed `remove` clears the saved path

    func testTimeoutOnAddAfterCompletedRemoveClearsSavedPath() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let defaults = makeDefaults()
        defaults.set(helperPath, forKey: "agents.claudeCode.helperPath")
        let runner = ScriptedRunner([
            .exited(status: 0, stdout: "Removed murmurly", stderr: ""), // remove: completed
            .timedOut, // add
        ])
        let connections = AgentConnections(
            defaults: defaults,
            bundleURL: bundleURL,
            installedBundlePaths: [bundleURL.path],
            home: root.appendingPathComponent("home", isDirectory: true),
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await runner.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) },
            install: { _, _, _ in .failed("not used") },
            linkURL: root.appendingPathComponent("usr-local-bin-murmurly")
        )
        XCTAssertEqual(connections.status(for: .claudeCode), .connected, "the saved path matches, so it starts out connected")

        await connections.connect(.claudeCode)

        XCTAssertEqual(connections.status(for: .claudeCode), .timedOut)
        XCTAssertNil(defaults.string(forKey: "agents.claudeCode.helperPath"), "remove already ran: the server is gone, so the old key must not survive")
    }

    func testFailedToLaunchOnAddAfterCompletedRemoveClearsSavedPath() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let defaults = makeDefaults()
        defaults.set(helperPath, forKey: "agents.codex.helperPath")
        let runner = ScriptedRunner([
            .exited(status: 1, stdout: "", stderr: "No MCP server found with name: murmurly"), // remove: completed, nothing to remove
            .failedToLaunch("fork failed"), // add
        ])
        let connections = AgentConnections(
            defaults: defaults,
            bundleURL: bundleURL,
            installedBundlePaths: [bundleURL.path],
            home: root.appendingPathComponent("home", isDirectory: true),
            locate: { _ in "/opt/homebrew/bin/codex" },
            run: { exe, args, env, dir, timeout in await runner.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) },
            install: { _, _, _ in .failed("not used") },
            linkURL: root.appendingPathComponent("usr-local-bin-murmurly")
        )
        XCTAssertEqual(connections.status(for: .codex), .connected)

        await connections.connect(.codex)

        guard case .failed = connections.status(for: .codex) else {
            return XCTFail("expected .failed, got \(connections.status(for: .codex))")
        }
        XCTAssertNil(defaults.string(forKey: "agents.codex.helperPath"))
    }

    // MARK: - K2 (neighbor, unchanged): `remove` itself timing out leaves the saved path alone

    func testTimeoutOnRemoveLeavesSavedPathUntouched() async throws {
        let bundleURL = try makeInstalledBundle()
        let helperPath = AgentConnections.helperURL(bundleURL: bundleURL).path
        let defaults = makeDefaults()
        defaults.set(helperPath, forKey: "agents.claudeCode.helperPath")
        let runner = ScriptedRunner([.timedOut]) // remove itself times out; add never runs
        let connections = AgentConnections(
            defaults: defaults,
            bundleURL: bundleURL,
            installedBundlePaths: [bundleURL.path],
            home: root.appendingPathComponent("home", isDirectory: true),
            locate: { _ in "/opt/homebrew/bin/claude" },
            run: { exe, args, env, dir, timeout in await runner.run(executable: exe, arguments: args, environment: env, directory: dir, timeout: timeout) },
            install: { _, _, _ in .failed("not used") },
            linkURL: root.appendingPathComponent("usr-local-bin-murmurly")
        )

        await connections.connect(.claudeCode)

        XCTAssertEqual(connections.status(for: .claudeCode), .timedOut)
        XCTAssertEqual(defaults.string(forKey: "agents.claudeCode.helperPath"), helperPath, "remove never completed: the old key must survive")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1, "add must not run after remove times out")
    }

    // MARK: - K3: "Copy Command" at the Terminal link is never offered for a foreign or unreadable file

    func testCopyCommandNeverOfferedForForeignOrUnreadableLink() {
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: .foreign, hasInstallError: false))
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: .foreign, hasInstallError: true))
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: .unreadable("denied"), hasInstallError: false))
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: .unreadable("denied"), hasInstallError: true))

        XCTAssertTrue(TerminalCommandInstaller.showsCopyCommand(status: .notInstalled, hasInstallError: true))
        XCTAssertTrue(TerminalCommandInstaller.showsCopyCommand(status: .outdated(target: "/old/path"), hasInstallError: true))
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: .notInstalled, hasInstallError: false))
        XCTAssertFalse(TerminalCommandInstaller.showsCopyCommand(status: .installed, hasInstallError: false))
    }
}
