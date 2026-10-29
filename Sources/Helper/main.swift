import Darwin
import Foundation
import MCP

// `murmurly` lives inside the app at Contents/Helpers/murmurly and reads the
// user's meetings and dictations for scripts and AI agents, never writing
// them. Its four commands sit on top of the shared Archive layer
// (`Sources/Archive/`); `murmurly mcp` (`MCPServer.swift`) wraps the same four
// as MCP tools over stdio.

// MARK: - Argument parsing

private struct ParsedArgs {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

/// Nil for an unknown flag or a value flag with nothing after it: both are
/// `usage` errors to the caller.
private func parseArgs(_ args: [String], valueFlags: Set<String>, boolFlags: Set<String>) -> ParsedArgs? {
    var result = ParsedArgs()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        guard arg.hasPrefix("--") else {
            result.positional.append(arg)
            continue
        }
        let name = String(arg.dropFirst(2))
        if boolFlags.contains(name) {
            result.flags.insert(name)
        } else if valueFlags.contains(name) {
            guard let value = iterator.next() else { return nil }
            result.values[name] = value
        } else {
            return nil
        }
    }
    return result
}

private func dateFlag(_ parsed: ParsedArgs, _ name: String) throws -> Date? {
    guard let raw = parsed.values[name] else { return nil }
    guard let date = HelperContract.parseFlagDate(raw) else {
        throw CommandFailure(code: .usage, message: "--\(name) is not a valid date")
    }
    return date
}

private func intFlag(_ parsed: ParsedArgs, _ name: String, default defaultValue: Int) throws -> Int {
    guard let raw = parsed.values[name] else { return defaultValue }
    guard let value = Int(raw) else { throw CommandFailure(code: .usage, message: "--\(name) is not a whole number") }
    return value
}

// MARK: - Printing

/// Everything a plain-text answer would otherwise hide, on stderr, never
/// stdout: whatever `--json` already names in `roots`/`unread`/`denied`/
/// `skippedLines`/`hasMore`, so a script reading stdout as lines still sees
/// that something was not read, rather than taking a short list for the
/// whole truth. Never a path: only an id, a root's own name and a reason.
private func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

private func noteRoots(_ roots: HelperContract.Roots) {
    if roots.local != .read, roots.local != .notSet {
        note("note: local meetings folder: \(roots.local.rawValue)")
    }
    if roots.chosen != .read, roots.chosen != .notSet {
        note("note: chosen meetings folder: \(roots.chosen.rawValue)")
    }
}

private func noteUnread(_ unread: [HelperContract.Unread]) {
    for item in unread {
        if let id = item.id {
            note("note: not read: \(id) (\(item.reason))")
        } else {
            note("note: not read: an item in \(item.root) (\(item.reason))")
        }
    }
}

private func noteDenied(_ denied: [String]) {
    for source in denied {
        note("note: not searched: \(source) (access is off)")
    }
}

private func noteSkippedLines(_ count: Int) {
    guard count > 0 else { return }
    note("note: \(count) unreadable history line(s) skipped")
}

private func noteMoreMatches(_ hasMore: Bool) {
    guard hasMore else { return }
    note("note: more matches than shown: raise --limit or narrow with --since/--until")
}

private func printTranscriptText(_ response: HelperContract.TranscriptResponse) {
    for line in response.lines {
        if let timecode = line.timecode, let speaker = line.speaker {
            print("[\(timecode)] \(speaker): \(line.text)")
        } else {
            print(line.text)
        }
    }
    print("-- version \(response.version.number), \(response.completeness) --")
    if response.truncated, let nextFrom = response.nextFrom {
        print("-- truncated, response size limit: continue with --from \(nextFrom) --")
    } else if let nextFrom = response.nextFrom {
        print("-- more: --from \(nextFrom) --")
    } else if response.truncated {
        print("-- truncated, response size limit --")
    }
}

private func printMeetingsText(_ response: HelperContract.MeetingsResponse) {
    for item in response.meetings {
        let started = item.startedAt.map(HelperContract.string(from:)) ?? "?"
        print("\(item.id)\t\(started)\t\(item.title ?? "")\t\(item.completeness)")
    }
    if response.truncated, let nextUntil = response.nextUntil {
        print("-- truncated, response size limit: continue with --until \(HelperContract.string(from: nextUntil)) --")
    } else if let nextUntil = response.nextUntil {
        print("-- more: --until \(HelperContract.string(from: nextUntil)) --")
    } else if response.truncated {
        print("-- truncated, response size limit: narrow with --since/--until or --starred --")
    } else if response.hasMore {
        print("-- more: raise --limit or narrow with --since/--until or --starred --")
    }
    noteRoots(response.roots)
    noteUnread(response.unread)
}

private func printSearchText(_ response: HelperContract.SearchResponse) {
    for hit in response.meetings {
        print("\(hit.meetingId)\tline \(hit.line)\t\(hit.snippet)")
    }
    for hit in response.dictations {
        print("\(hit.id)\t\(HelperContract.string(from: hit.at))\t\(hit.snippet)")
    }
    if response.truncated {
        print("-- truncated, response size limit: narrow with --limit, --since or --until --")
    }
    noteRoots(response.roots)
    noteUnread(response.unread)
    noteDenied(response.denied)
    noteSkippedLines(response.skippedLines)
    noteMoreMatches(response.hasMore)
}

private func printDictationsText(_ response: HelperContract.DictationsResponse) {
    for item in response.dictations {
        print("\(item.id)\t\(HelperContract.string(from: item.at))\t\(item.status)\t\(item.text)")
    }
    if response.truncated {
        print("-- truncated, response size limit: narrow with --last or --since --")
    }
    noteSkippedLines(response.skippedLines)
}

/// `--json`'s own field for the same notice `murmurly mcp` sends as a
/// separate content block: a second keyed container on the same encoder
/// merges into the first rather than replacing it, so every other field
/// still encodes exactly as `makeEncoder()` would write it alone.
private struct WithNotice<Response: Encodable>: Encodable {
    let response: Response
    private enum CodingKeys: String, CodingKey { case notice }
    func encode(to encoder: Encoder) throws {
        try response.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HelperContract.Tools.untrustedNotice, forKey: .notice)
    }
}

private func printJSONOrText<T: Encodable>(_ value: T, json: Bool, textPrinter: (T) -> Void) {
    if json {
        let encoder = HelperContract.makeEncoder()
        if let data = try? encoder.encode(WithNotice(response: value)), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } else {
        // Before any other stderr note, the same reminder `murmurly mcp`
        // sends as its own content block: only a successful answer carries
        // it, never a refusal.
        note("note: " + HelperContract.Tools.untrustedNotice)
        textPrinter(value)
    }
}

private func fail(code: HelperContract.ErrorCode, message: String, json: Bool, command: String, logURL: URL?) -> Never {
    if json {
        let response = HelperContract.ErrorResponse(command: command, code: code, message: message)
        if let data = try? HelperContract.makeEncoder().encode(response), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    if let logURL {
        AgentsLog.record(at: logURL, command: command, fields: "refused=\(code.rawValue)")
    }
    exit(HelperContract.exitCode(for: code))
}

// MARK: - Dispatch

/// Parses a command's own flags into the one `HelperRequest` shape
/// `perform` (`Commands.swift`) takes, shared with the MCP server's JSON
/// argument parsing.
private func parseRequest(command: String, args: [String]) throws -> HelperRequest {
    switch command {
    case "meetings":
        guard let parsed = parseArgs(args, valueFlags: ["since", "until", "limit"], boolFlags: ["starred", "json"]),
              parsed.positional.isEmpty else {
            throw CommandFailure(
                code: .usage, message: "usage: murmurly meetings [--since D] [--until D] [--starred] [--limit N] [--json]"
            )
        }
        var flags = MeetingsFlags()
        flags.since = try dateFlag(parsed, "since")
        flags.until = try dateFlag(parsed, "until")
        flags.starred = parsed.flags.contains("starred")
        flags.limit = try intFlag(parsed, "limit", default: 50)
        return .meetings(flags)

    case "transcript":
        guard let parsed = parseArgs(args, valueFlags: ["from", "count"], boolFlags: ["json"]),
              parsed.positional.count == 1 else {
            throw CommandFailure(code: .usage, message: "usage: murmurly transcript <id> [--from N] [--count N] [--json]")
        }
        var flags = TranscriptFlags(id: parsed.positional[0])
        flags.from = try intFlag(parsed, "from", default: 1)
        flags.count = try intFlag(parsed, "count", default: 200)
        return .transcript(flags)

    case "search":
        guard let parsed = parseArgs(args, valueFlags: ["since", "until", "limit"], boolFlags: ["meetings", "dictations", "json"]) else {
            throw CommandFailure(
                code: .usage,
                message: "usage: murmurly search <text> [--meetings|--dictations] [--since D] [--until D] [--limit N] [--json]"
            )
        }
        var flags = SearchFlags(text: parsed.positional.joined(separator: " "))
        flags.onlyMeetings = parsed.flags.contains("meetings")
        flags.onlyDictations = parsed.flags.contains("dictations")
        flags.since = try dateFlag(parsed, "since")
        flags.until = try dateFlag(parsed, "until")
        flags.limit = try intFlag(parsed, "limit", default: 20)
        return .search(flags)

    case "dictations":
        guard let parsed = parseArgs(args, valueFlags: ["last", "since"], boolFlags: ["json"]), parsed.positional.isEmpty else {
            throw CommandFailure(code: .usage, message: "usage: murmurly dictations [--last N] [--since D] [--json]")
        }
        var flags = DictationsFlags()
        flags.last = try intFlag(parsed, "last", default: 20)
        flags.since = try dateFlag(parsed, "since")
        return .dictations(flags)

    default:
        throw CommandFailure(code: .usage, message: "unknown command: \(command)")
    }
}

private func run(command: String, args: [String]) -> Never {
    let wantsJSON = args.contains("--json")
    guard let environment = HelperEnvironment.resolve() else {
        fail(code: .usage, message: "set all four MURMURLY_HELPER_* overrides, or none", json: wantsJSON, command: command, logURL: nil)
    }

    // `--json`'s own budget leaves room for the `notice` field `WithNotice`
    // adds on top of the plain response `perform` measures against.
    let noticeOverhead = wantsJSON ? HelperContract.encodedSize(["notice": HelperContract.Tools.untrustedNotice]) : 0
    let outcome: Result<CommandSuccess, CommandFailure>? = withTimeout(seconds: 30) {
        do {
            let request = try parseRequest(command: command, args: args)
            let budget = ResponseBudget(maxBytes: max(0, environment.maxResponseBytes - noticeOverhead), inJSONString: false)
            let success = try perform(request, environment: environment, budget: budget)
            return .success(success)
        } catch let failure as CommandFailure {
            return .failure(failure)
        } catch {
            return .failure(CommandFailure(code: .readError, message: "\(type(of: error))"))
        }
    }

    switch outcome {
    case .none:
        fail(code: .notResponding, message: "timed out", json: wantsJSON, command: command, logURL: environment.logURL)
    case .some(.failure(let failure)):
        fail(code: failure.code, message: failure.message, json: wantsJSON, command: command, logURL: environment.logURL)
    case .some(.success(let success)):
        switch success.outcome {
        case .meetings(let response): printJSONOrText(response, json: wantsJSON, textPrinter: printMeetingsText)
        case .transcript(let response): printJSONOrText(response, json: wantsJSON, textPrinter: printTranscriptText)
        case .search(let response): printJSONOrText(response, json: wantsJSON, textPrinter: printSearchText)
        case .dictations(let response): printJSONOrText(response, json: wantsJSON, textPrinter: printDictationsText)
        }
        AgentsLog.record(at: environment.logURL, command: command, fields: success.logFields)
        exit(0)
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

switch arguments.first {
case nil:
    print("""
    murmurly \(version)
    Reads Murmurly's meetings and dictations for scripts and AI agents.
    Usage: murmurly --version
           murmurly meetings [--since D] [--until D] [--starred] [--limit N] [--json]
           murmurly transcript <id> [--from N] [--count N] [--json]
           murmurly search <text> [--meetings|--dictations] [--since D] [--until D] [--limit N] [--json]
           murmurly dictations [--last N] [--since D] [--json]
           murmurly mcp
    """)
case "--version", "version":
    print("murmurly \(version)")
case "meetings", "transcript", "search", "dictations":
    run(command: arguments[0], args: Array(arguments.dropFirst()))
case "mcp":
    guard let environment = HelperEnvironment.resolve() else {
        FileHandle.standardError.write(Data("set all four MURMURLY_HELPER_* overrides, or none\n".utf8))
        exit(2)
    }
    await runMCPServer(environment: environment, version: version)
    exit(0)
default:
    FileHandle.standardError.write(Data("unknown command: \(arguments[0])\n".utf8))
    exit(2)
}
