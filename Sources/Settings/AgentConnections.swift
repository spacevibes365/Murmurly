import AppKit
import Darwin
import Foundation

/// Connecting agents (`AgentConnections`, Settings → Agents). "Connect to
/// Claude Code" / "Connect to Codex" run the client found in the usual
/// install places (a GUI app's `PATH` is short) with argument arrays, no
/// shell: `mcp remove murmurly`, then `mcp add … murmurly -- <helper> mcp`
/// (Claude with `--scope user`), then `mcp get` must name the helper's path.
/// The path that passed is kept (`agents.claudeCode.helperPath`,
/// `agents.codex.helperPath`); a saved path that no longer matches the
/// running copy's helper is "out of date". Only an installed copy connects.
/// "Install Command in Terminal" links `/usr/local/bin/murmurly` to the
/// running copy's helper through osascript's administrator prompt. A test
/// process finds no client and runs nothing (`live()` below).

// MARK: - Running a client's CLI, no shell

enum RunResult: Equatable, Sendable {
    case exited(status: Int32, stdout: String, stderr: String)
    case timedOut
    case failedToLaunch(String)
}

typealias Runner = @Sendable (
    _ executable: URL,
    _ arguments: [String],
    _ environment: [String: String],
    _ directory: URL,
    _ timeout: Duration
) async -> RunResult

extension Duration {
    fileprivate var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Everything about one launch that is not `Sendable` on its own (`Process`,
/// its two `Pipe`s) lives behind this lock-guarded wrapper, so a `@Sendable`
/// closure can capture the wrapper without ever capturing them directly:
/// every access happens through a method on an already-`@unchecked
/// Sendable` type, not through a captured variable of their own type.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<RunResult, Never>?
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutBox = DataBox()
    private let stderrBox = DataBox()
    private let readGroup = DispatchGroup()

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func setContinuation(_ continuation: CheckedContinuation<RunResult, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resumeOnce(_ result: RunResult) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func terminateIfRunning() {
        if process.isRunning { process.terminate() }
    }

    func killIfStillRunning() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Drains both pipes on their own threads, so a child past 64 KB of
    /// output never deadlocks against a parent waiting for it to exit
    /// before reading.
    func startDrainingPipes() {
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
    }

    func closeWritingEnds() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }

    func startAndObserveTermination() {
        process.terminationHandler = { [self] exited in
            let status = exited.terminationStatus
            readGroup.notify(queue: .global(qos: .utility)) { [self] in
                let stdout = String(data: stdoutBox.get(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.get(), encoding: .utf8) ?? ""
                resumeOnce(.exited(status: status, stdout: stdout, stderr: stderr))
            }
        }
        do {
            try process.run()
        } catch {
            closeWritingEnds()
            resumeOnce(.failedToLaunch(error.localizedDescription))
        }
    }
}

/// Collects a pipe's output on a background thread; `Pipe`/`FileHandle` are
/// not `Sendable`, so only this lock-guarded box crosses a closure.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ value: Data) {
        lock.lock()
        storage = value
        lock.unlock()
    }
    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum ProcessRunner {
    /// `Process` with an executable URL and an argument array — never
    /// `/bin/sh`.
    static let live: Runner = { executable, arguments, environment, directory, timeout in
        await run(executable: executable, arguments: arguments, environment: environment, directory: directory, timeout: timeout)
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        timeout: Duration
    ) async -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failedToLaunch("\(executable.path) is not executable")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let running = RunningProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        running.startDrainingPipes()

        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
                    running.setContinuation(continuation)
                    running.startAndObserveTermination()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) {
                        running.terminateIfRunning()
                        running.resumeOnce(.timedOut)
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                            running.killIfStillRunning()
                        }
                    }
                }
            },
            onCancel: {
                running.terminateIfRunning()
                running.resumeOnce(.timedOut)
            }
        )
    }
}

private func lastNonEmptyLine(_ text: String) -> String? {
    text.split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .last { !$0.isEmpty }
}

private func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - The clients

enum AgentClientKind: Sendable, CaseIterable, Equatable {
    case claudeCode
    case codex
}

enum AgentMCPTimeouts {
    static let removeAndAdd: Duration = .seconds(30)
    /// Claude's `mcp get` starts the server to check it; Codex's prints a
    /// stored config, but the same budget covers either.
    static let check: Duration = .seconds(60)
}

/// The exact argument arrays, from `claude mcp add --help` / `codex mcp add
/// --help` (neither takes a shell string): remove the old registration
/// before adding (both clients refuse `add` on a name that already exists),
/// then `get` must name the helper's own path.
enum AgentMCPCommand {
    static func remove(for kind: AgentClientKind) -> [String] {
        switch kind {
        case .claudeCode: return ["mcp", "remove", "--scope", "user", "murmurly"]
        case .codex: return ["mcp", "remove", "murmurly"]
        }
    }

    static func add(for kind: AgentClientKind, helperPath: String) -> [String] {
        switch kind {
        case .claudeCode: return ["mcp", "add", "--scope", "user", "murmurly", "--", helperPath, "mcp"]
        case .codex: return ["mcp", "add", "murmurly", "--", helperPath, "mcp"]
        }
    }

    static func get(for kind: AgentClientKind) -> [String] {
        switch kind {
        case .claudeCode: return ["mcp", "get", "murmurly"]
        case .codex: return ["mcp", "get", "murmurly", "--json"]
        }
    }

    /// The one-line command for "Copy Command", for a client that was not
    /// found: the same remove-then-add the live flow runs (`connect` above),
    /// so pasting it never ends in `add`'s "already exists" for a server
    /// registered earlier by hand or by a previous connect.
    static func addCommandLine(for kind: AgentClientKind, helperPath: String) -> String {
        let quoted = shellSingleQuoted(helperPath)
        switch kind {
        case .claudeCode: return "claude mcp remove --scope user murmurly; claude mcp add --scope user murmurly -- \(quoted) mcp"
        case .codex: return "codex mcp remove murmurly; codex mcp add murmurly -- \(quoted) mcp"
        }
    }

    /// Claude's `get` is free text; the helper's own path is the one
    /// stable thing to search for. Codex's `--json` is parsed and searched
    /// recursively, so a change to the schema around that one string value
    /// does not break the check.
    static func verified(for kind: AgentClientKind, helperPath: String, stdout: String) -> Bool {
        switch kind {
        case .claudeCode:
            return stdout.contains(helperPath)
        case .codex:
            guard let data = stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return false }
            return jsonContainsString(json, equalTo: helperPath)
        }
    }

    private static func jsonContainsString(_ value: Any, equalTo target: String) -> Bool {
        if let string = value as? String { return string == target }
        if let array = value as? [Any] { return array.contains { jsonContainsString($0, equalTo: target) } }
        if let dict = value as? [String: Any] { return dict.values.contains { jsonContainsString($0, equalTo: target) } }
        return false
    }
}

/// Where a GUI app's short `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) does not
/// reach: the usual install locations for each client, home-relative paths
/// first, then the running process's own `PATH`. Pure and testable with a
/// fake home and a fake executability check.
enum AgentLocator {
    static func candidatePaths(for kind: AgentClientKind, home: URL) -> [String] {
        let h = home.path
        switch kind {
        case .claudeCode:
            return [
                "\(h)/.local/bin/claude",
                "\(h)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(h)/.npm-global/bin/claude",
                "\(h)/.bun/bin/claude",
                "\(h)/.volta/bin/claude",
            ] + nvmCandidates(home: home, binary: "claude")
        case .codex:
            return [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(h)/.local/bin/codex",
                "\(h)/.npm-global/bin/codex",
                "\(h)/.bun/bin/codex",
                "\(h)/.volta/bin/codex",
            ] + nvmCandidates(home: home, binary: "codex")
        }
    }

    /// `~/.nvm/versions/node/<version>/bin/<binary>`, newest version first:
    /// nvm's node ships this binary beside its own `node`, and an older
    /// version installed earlier must not shadow a newer one.
    private static func nvmCandidates(home: URL, binary: String) -> [String] {
        let versionsDir = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: versionsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .sorted { versionIsGreater(numericVersion($0.lastPathComponent), numericVersion($1.lastPathComponent)) }
            .map { $0.appendingPathComponent("bin/\(binary)").path }
    }

    private static func numericVersion(_ name: String) -> [Int] {
        var trimmed = Substring(name)
        if trimmed.first == "v" { trimmed = trimmed.dropFirst() }
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// `[Int]` has no `Comparable` conformance of its own: compares
    /// component by component, treating a missing trailing component as 0
    /// (`v9` vs `v9.0.1`).
    private static func versionIsGreater(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func locate(
        kind: AgentClientKind,
        home: URL,
        processPath: String,
        isExecutableFile: (String) -> Bool
    ) -> String? {
        let binaryName = kind == .claudeCode ? "claude" : "codex"
        let fromProcessPath = processPath
            .split(separator: ":")
            .map { "\($0)/\(binaryName)" }
        for candidate in candidatePaths(for: kind, home: home) + fromProcessPath where isExecutableFile(candidate) {
            return candidate
        }
        return nil
    }

    /// The child's own `PATH`: the found program's folder first (an npm
    /// install's `claude`/`codex` is a `node` script that needs `node`
    /// beside it), then that folder's resolved target (nvm keeps `node`
    /// next to the real file, not the version symlink), then the usual
    /// places, so the client's own subprocesses still find common tools.
    static func childEnvironment(appEnvironment: [String: String], foundExecutablePath: String, home: URL) -> [String: String] {
        var environment = appEnvironment
        let programFolder = URL(fileURLWithPath: foundExecutablePath).deletingLastPathComponent().path
        let realFolder = URL(fileURLWithPath: foundExecutablePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .path
        var folders = [programFolder]
        if realFolder != programFolder { folders.append(realFolder) }
        folders += [
            "\(home.path)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        environment["PATH"] = folders.joined(separator: ":")
        environment["HOME"] = home.path
        return environment
    }
}

// MARK: - Installing the command in Terminal

enum TerminalLinkStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// A link this app made, to a copy that is no longer the running one.
    case outdated(target: String)
    /// Anything else at the address: another link, or a plain file/folder.
    case foreign
    case unreadable(String)
}

enum InstallOutcome: Equatable, Sendable {
    case done
    case cancelled
    case failed(String)
    case timedOut
}

typealias Installer = @Sendable (_ helper: String, _ link: URL, _ prompt: String) async -> InstallOutcome

enum TerminalCommandInstaller {
    /// `lstat`, never `stat`: a broken link to a removed copy is still our
    /// own link, told apart by the path it names, not by whether that path
    /// exists.
    static func linkStatus(linkURL: URL, helperPath: String) -> TerminalLinkStatus {
        var info = stat()
        guard lstat(linkURL.path, &info) == 0 else {
            let code = errno
            return code == ENOENT ? .notInstalled : .unreadable(String(cString: strerror(code)))
        }
        guard info.st_mode & S_IFMT == S_IFLNK else { return .foreign }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return .unreadable("the link's target could not be read")
        }
        let resolved = destination.hasPrefix("/")
            ? destination
            : linkURL.deletingLastPathComponent().appendingPathComponent(destination).path
        if resolved == helperPath { return .installed }
        if resolved.hasSuffix(".app/Contents/Helpers/murmurly") { return .outdated(target: resolved) }
        return .foreign
    }

    /// The exit code the privileged script and the copied command both use
    /// when a file that is not a symbolic link is already at the install
    /// path — never replaced, whatever it is. A plain shell number, not an
    /// `InstallOutcome` case: the model never trusts this code on its own,
    /// only a fresh `linkStatus` read of the address, so a test cannot pass
    /// by stubbing a case the old code could never produce.
    static let foreignFileExitCode: Int32 = 17

    /// The exact osascript invocation: three `-e` statements, then the
    /// helper, the link, its parent folder and the prompt as plain
    /// arguments — never interpolated into the script text, so a path
    /// holding a quote cannot inject anything. `quoted form of` inside the
    /// script does the only shell-quoting that happens here. Before linking,
    /// the shell itself checks that the address holds nothing, or already a
    /// symbolic link: a plain file that appeared there — even one that
    /// appeared only while the password prompt was up — is left alone,
    /// `ln -sfh` never reached.
    static func arguments(helper: String, link: URL, prompt: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "do shell script \"/bin/mkdir -p \" & quoted form of (item 3 of argv) & " +
                "\" && if [ -e \" & quoted form of (item 2 of argv) & \" ] && [ ! -L \" & quoted form of (item 2 of argv) & " +
                "\" ]; then exit \(foreignFileExitCode); fi && /bin/ln -sfh \" & quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) " +
                "with prompt (item 4 of argv) with administrator privileges",
            "-e", "end run",
            helper, link.path, link.deletingLastPathComponent().path, prompt,
        ]
    }

    static let live: Installer = { helper, link, prompt in
        let result = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: arguments(helper: helper, link: link, prompt: prompt),
            environment: ProcessInfo.processInfo.environment,
            directory: FileManager.default.temporaryDirectory,
            timeout: .seconds(300)
        )
        switch result {
        case .timedOut: return .timedOut
        case .failedToLaunch(let reason): return .failed(reason)
        case .exited(let status, let stdout, let stderr):
            if status == 0 { return .done }
            if stderr.contains("(-128)") || stdout.contains("(-128)") { return .cancelled }
            return .failed(lastNonEmptyLine(stderr) ?? lastNonEmptyLine(stdout) ?? "osascript exited \(status)")
        }
    }

    /// Offered when the password prompt is refused, or there is no
    /// `osascript` outcome at all yet: the same link, run by hand — the same
    /// non-link check as the privileged script, so a file that appeared at
    /// the address since the screen was last read is never replaced by
    /// running this command either.
    static func terminalCommandLine(helperPath: String) -> String {
        let link = "/usr/local/bin/murmurly"
        return "sudo mkdir -p /usr/local/bin && " +
            "if [ -e \(link) ] && [ ! -L \(link) ]; then " +
            "echo 'murmurly: \(link) is not a link; left as it is' >&2; " +
            "else sudo ln -sfh \(shellSingleQuoted(helperPath)) \(link); fi"
    }

    /// Whether to show "Copy Command" for the Terminal link. Never for
    /// `.foreign` or `.unreadable`: the copied command ends in `ln -sfh`,
    /// which replaces whatever is at the address, and the screen just told
    /// the user Murmurly leaves that file alone. After a refused password
    /// prompt, an error or a timed-out install (`hasInstallError`), the
    /// preceding read already ruled those two out, so copying is safe.
    static func showsCopyCommand(status: TerminalLinkStatus, hasInstallError: Bool) -> Bool {
        switch status {
        case .foreign, .unreadable: return false
        case .notInstalled, .installed, .outdated: return hasInstallError
        }
    }
}

// MARK: - The model

@MainActor
final class AgentConnections: ObservableObject {
    enum ClientStatus: Equatable, Sendable {
        case notConnected
        case connecting
        case connected
        /// The saved path no longer matches this copy's helper: the app
        /// moved, or was updated to a copy at another address.
        case outdated(savedHelperPath: String)
        case clientNotFound
        case verificationFailed
        case timedOut
        case failed(String)
    }

    @Published private(set) var claudeStatus: ClientStatus
    @Published private(set) var codexStatus: ClientStatus
    @Published private(set) var terminalLinkStatus: TerminalLinkStatus
    @Published private(set) var isInstallingTerminalCommand = false
    @Published private(set) var terminalInstallError: String?

    /// `nil` when this copy of the app has no helper to offer (missing or
    /// not executable): every button stays off.
    let helperPath: String?
    /// Only an installed copy connects agents: a build in DerivedData or a
    /// mounted DMG would hand out a path that disappears with the build
    /// folder or the volume.
    let isInstalledCopy: Bool

    private let defaults: UserDefaults
    private let home: URL
    private let locate: (AgentClientKind) -> String?
    private let run: Runner
    private let install: Installer
    private let linkURL: URL
    private let copy: (String) -> Void

    init(
        defaults: UserDefaults = TestIsolation.settingsDefaults(),
        bundleURL: URL = Bundle.main.bundleURL,
        installedBundlePaths: [String]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        locate: @escaping (AgentClientKind) -> String?,
        run: @escaping Runner,
        install: @escaping Installer,
        linkURL: URL = URL(fileURLWithPath: "/usr/local/bin/murmurly"),
        copy: @escaping (String) -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    ) {
        self.defaults = defaults
        self.home = home
        self.locate = locate
        self.run = run
        self.install = install
        self.linkURL = linkURL
        self.copy = copy

        let normalizedCurrent = Self.normalizedPath(bundleURL.path)
        let installed = (installedBundlePaths
            ?? LoginItemManager.defaultInstalledBundlePaths(appName: bundleURL.lastPathComponent))
            .map(Self.normalizedPath)
        isInstalledCopy = installed.contains(normalizedCurrent)

        let helperURL = Self.helperURL(bundleURL: bundleURL)
        helperPath = FileManager.default.isExecutableFile(atPath: helperURL.path) ? helperURL.path : nil

        claudeStatus = Self.initialStatus(
            saved: defaults.string(forKey: Self.key(for: .claudeCode)), helperPath: helperPath
        )
        codexStatus = Self.initialStatus(
            saved: defaults.string(forKey: Self.key(for: .codex)), helperPath: helperPath
        )
        terminalLinkStatus = helperPath.map { TerminalCommandInstaller.linkStatus(linkURL: linkURL, helperPath: $0) }
            ?? .notInstalled
    }

    static func helperURL(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/murmurly")
    }

    static func live() -> AgentConnections {
        guard !TestIsolation.isTestProcess else {
            return AgentConnections(
                defaults: TestIsolation.settingsDefaults(),
                bundleURL: Bundle.main.bundleURL,
                installedBundlePaths: [],
                home: TestIsolation.root,
                locate: { _ in nil },
                run: { _, _, _, _, _ in .failedToLaunch("disabled in a test process") },
                install: { _, _, _ in .failed("disabled in a test process") },
                linkURL: TestIsolation.root.appendingPathComponent("usr-local-bin-murmurly"),
                copy: { _ in }
            )
        }
        let bundleURL = Bundle.main.bundleURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentConnections(
            bundleURL: bundleURL,
            home: home,
            locate: { kind in
                AgentLocator.locate(
                    kind: kind,
                    home: home,
                    processPath: ProcessInfo.processInfo.environment["PATH"] ?? "",
                    isExecutableFile: FileManager.default.isExecutableFile
                )
            },
            run: ProcessRunner.live,
            install: TerminalCommandInstaller.live
        )
    }

    // MARK: - Status for a client

    func status(for kind: AgentClientKind) -> ClientStatus {
        switch kind {
        case .claudeCode: return claudeStatus
        case .codex: return codexStatus
        }
    }

    private func setStatus(_ status: ClientStatus, for kind: AgentClientKind) {
        switch kind {
        case .claudeCode: claudeStatus = status
        case .codex: codexStatus = status
        }
    }

    /// Remove, then add with this copy's helper, then verify — so a stale
    /// entry (no entry, or one with an old copy's path) always ends in
    /// exactly one entry naming the running copy, in one call.
    func connect(_ kind: AgentClientKind) async {
        guard isInstalledCopy, let helperPath, status(for: kind) != .connecting else { return }
        setStatus(.connecting, for: kind)

        guard let executablePath = locate(kind) else {
            setStatus(.clientNotFound, for: kind)
            return
        }
        let executableURL = URL(fileURLWithPath: executablePath)
        let environment = AgentLocator.childEnvironment(
            appEnvironment: ProcessInfo.processInfo.environment,
            foundExecutablePath: executablePath,
            home: home
        )
        AppLog.info("agents", "\(kind) connect: using \(executablePath)")

        let removeResult = await run(
            executableURL, AgentMCPCommand.remove(for: kind), environment, home, AgentMCPTimeouts.removeAndAdd
        )
        switch removeResult {
        case .timedOut:
            setStatus(.timedOut, for: kind)
            return
        case .failedToLaunch(let reason):
            setStatus(.failed(reason), for: kind)
            return
        case .exited:
            break // the exit code is not checked: no prior server is a normal outcome.
        }

        let addResult = await run(
            executableURL, AgentMCPCommand.add(for: kind, helperPath: helperPath), environment, home,
            AgentMCPTimeouts.removeAndAdd
        )
        switch addResult {
        case .timedOut:
            // `remove` already completed; the server is gone, and `add` never
            // confirmed a new one, so the old saved path is stale either way.
            clearSavedHelperPath(for: kind)
            setStatus(.timedOut, for: kind)
            return
        case .failedToLaunch(let reason):
            clearSavedHelperPath(for: kind)
            setStatus(.failed(reason), for: kind)
            return
        case .exited(let status, let stdout, let stderr) where status != 0:
            // `remove` ran; the server is gone either way, successful add or not.
            clearSavedHelperPath(for: kind)
            setStatus(.failed(lastNonEmptyLine(stderr) ?? lastNonEmptyLine(stdout) ?? "exit \(status)"), for: kind)
            return
        case .exited:
            break
        }

        let getResult = await run(
            executableURL, AgentMCPCommand.get(for: kind), environment, home, AgentMCPTimeouts.check
        )
        switch getResult {
        case .timedOut:
            setStatus(.timedOut, for: kind)
            return
        case .failedToLaunch(let reason):
            setStatus(.failed(reason), for: kind)
            return
        case .exited(let status, let stdout, _):
            guard status == 0, AgentMCPCommand.verified(for: kind, helperPath: helperPath, stdout: stdout) else {
                setStatus(.verificationFailed, for: kind)
                return
            }
            saveHelperPath(helperPath, for: kind)
            setStatus(.connected, for: kind)
            AppLog.info("agents", "\(kind) connected: \(helperPath)")
        }
    }

    func copyConnectCommand(for kind: AgentClientKind) {
        guard let helperPath else { return }
        copy(AgentMCPCommand.addCommandLine(for: kind, helperPath: helperPath))
    }

    // MARK: - The Terminal command

    func refreshTerminalLinkStatus() {
        guard let helperPath else { return }
        terminalLinkStatus = TerminalCommandInstaller.linkStatus(linkURL: linkURL, helperPath: helperPath)
        // An earlier install's error (a cancelled prompt, a failure) no
        // longer applies once the link is found installed — including when
        // the user ran the copied command themselves instead of retrying.
        if terminalLinkStatus == .installed { terminalInstallError = nil }
    }

    func installTerminalCommand() async {
        guard isInstalledCopy, let helperPath, !isInstallingTerminalCommand else { return }
        let current = TerminalCommandInstaller.linkStatus(linkURL: linkURL, helperPath: helperPath)
        terminalLinkStatus = current
        switch current {
        case .foreign, .unreadable:
            return // a file this app did not create is never replaced.
        case .installed:
            terminalInstallError = nil // a fresh read already found it installed: no password prompt for nothing.
            return
        case .notInstalled, .outdated:
            break
        }

        isInstallingTerminalCommand = true
        terminalInstallError = nil
        let prompt = String(localized: "Murmurly wants to install the murmurly command in /usr/local/bin.")
        let outcome = await install(helperPath, linkURL, prompt)
        isInstallingTerminalCommand = false

        switch outcome {
        case .done:
            terminalLinkStatus = TerminalCommandInstaller.linkStatus(linkURL: linkURL, helperPath: helperPath)
            return
        case .cancelled:
            terminalInstallError = String(localized: "Cancelled. You can copy the command and run it in Terminal.")
        case .failed(let reason):
            terminalInstallError = String(localized: "Couldn’t install: \(reason)")
        case .timedOut:
            terminalInstallError = String(localized: "Took too long and was stopped.")
        }

        // Whatever the outcome's own reason, the address on disk is the
        // honest answer: a plain file may have appeared there — even only
        // while the password prompt was up — and the privileged script's own
        // check (above) already refused to replace it. That is never shown
        // as an error: the screen already explains a foreign file is left
        // alone.
        let after = TerminalCommandInstaller.linkStatus(linkURL: linkURL, helperPath: helperPath)
        if after == .foreign {
            terminalLinkStatus = .foreign
            terminalInstallError = nil
        }
    }

    func copyTerminalCommand() {
        guard let helperPath else { return }
        copy(TerminalCommandInstaller.terminalCommandLine(helperPath: helperPath))
    }

    // MARK: - Private

    private static func key(for kind: AgentClientKind) -> String {
        switch kind {
        case .claudeCode: return "agents.claudeCode.helperPath"
        case .codex: return "agents.codex.helperPath"
        }
    }

    private func saveHelperPath(_ path: String, for kind: AgentClientKind) {
        defaults.set(path, forKey: Self.key(for: kind))
    }

    private func clearSavedHelperPath(for kind: AgentClientKind) {
        defaults.removeObject(forKey: Self.key(for: kind))
    }

    private static func initialStatus(saved: String?, helperPath: String?) -> ClientStatus {
        guard let saved else { return .notConnected }
        guard let helperPath, saved == helperPath else { return .outdated(savedHelperPath: saved) }
        return .connected
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
