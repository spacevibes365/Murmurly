import Foundation
import MCP

// `murmurly mcp`: the same four read-only operations as the CLI commands
// (`Commands.swift`), offered over stdio as MCP tools to AI agents that speak
// the protocol. stdout carries only the protocol; every diagnostic goes to
// stderr. Access, the period and the chosen meetings folder are settings read
// fresh on every `tools/call` (`perform` in `Commands.swift`), never cached
// for the life of this long-running process: a switch flipped in Settings
// takes effect on the very next call, with no restart.

/// Starts the server on stdio and returns only once it is done (stdin closed,
/// or a transport failure): the caller's `main.swift` is a synchronous
/// top-level script, so this function — not a detached, unawaited `Task` —
/// is what keeps the process alive for as long as the server runs.
func runMCPServer(environment: HelperEnvironment, version: String) async {
    let server = Server(
        name: "murmurly",
        version: version,
        instructions: HelperContract.Tools.untrustedNotice,
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        let tools = HelperContract.Tools.all.map { spec in
            Tool(
                name: spec.name,
                description: spec.description,
                inputSchema: decodeSchema(spec.inputSchemaJSON) ?? .object([:]),
                annotations: Tool.Annotations(
                    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false
                )
            )
        }
        return ListTools.Result(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        try await handleCallTool(params, environment: environment)
    }

    do {
        try await server.start(transport: StdioTransport())
    } catch {
        FileHandle.standardError.write(Data("murmurly mcp: \(error)\n".utf8))
        return
    }
    await server.waitUntilCompleted()
}

private func decodeSchema(_ json: String) -> Value? {
    try? JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

// MARK: - `tools/call`

#if DEBUG
private func mcpTimeoutSeconds() -> Double {
    HelperEnvironment.debugTimeoutSeconds() ?? 30
}
#else
private func mcpTimeoutSeconds() -> Double { 30 }
#endif

private func handleCallTool(_ params: CallTool.Parameters, environment: HelperEnvironment) async throws -> CallTool.Result {
    let knownCommand = HelperContract.Tools.commandName(forTool: params.name)
    // An unknown tool's own name is a caller-chosen string, never written to
    // the log whole — only that it was unknown.
    let logName = knownCommand != nil ? "mcp.\(params.name)" : "mcp.unknown"
    let commandName = knownCommand ?? params.name

    let request: HelperRequest
    do {
        request = try parseToolRequest(name: params.name, arguments: params.arguments ?? [:])
    } catch let failure as CommandFailure {
        AgentsLog.record(at: environment.logURL, command: logName, fields: "refused=\(failure.code.rawValue)")
        return errorResult(command: commandName, failure: failure)
    }

    let budget = ResponseBudget(maxBytes: max(0, environment.maxMCPResponseBytes - 1024), inJSONString: true)
    let outcome = await withAsyncTimeout(seconds: mcpTimeoutSeconds()) { () -> Result<CommandSuccess, CommandFailure> in
        do {
            return .success(try perform(request, environment: environment, budget: budget))
        } catch let failure as CommandFailure {
            return .failure(failure)
        } catch {
            return .failure(CommandFailure(code: .readError, message: "\(type(of: error))"))
        }
    }

    switch outcome {
    case .cancelled:
        // SDK 0.12.1 stays silent on the request only when the handler itself
        // throws `CancellationError`: any returned `Result` would still be
        // written to stdout as the answer.
        throw CancellationError()
    case .timedOut:
        let failure = CommandFailure(code: .notResponding, message: "timed out")
        AgentsLog.record(at: environment.logURL, command: logName, fields: "refused=\(failure.code.rawValue)")
        return errorResult(command: commandName, failure: failure)
    case .value(.success(let success)):
        AgentsLog.record(at: environment.logURL, command: logName, fields: success.logFields)
        return successResult(success.outcome)
    case .value(.failure(let failure)):
        AgentsLog.record(at: environment.logURL, command: logName, fields: "refused=\(failure.code.rawValue)")
        return errorResult(command: commandName, failure: failure)
    }
}

// MARK: - Arguments

/// `nil` only when `key` is absent; present with the wrong JSON type (an
/// `Int`, a `Bool`, `null`, …) is a usage error — the MCP SDK does not check
/// a call's arguments against its own `inputSchema`, so every type rule here
/// is this server's own to enforce.
private func stringArgument(_ arguments: [String: Value], _ key: String) throws -> String? {
    guard let value = arguments[key] else { return nil }
    guard case .string(let text) = value else {
        throw CommandFailure(code: .usage, message: "\(key) must be a string")
    }
    return text
}

/// `.double` covers both a fraction and a whole number too big for `Int`
/// (`JSONDecoder` only picks `.int` when the literal both parses as one and
/// fits): `Int(exactly:)` refuses both in one check, rather than `Int(_:)`,
/// which traps the process on an out-of-range value.
private func intArgument(_ arguments: [String: Value], _ key: String) throws -> Int? {
    guard let value = arguments[key] else { return nil }
    switch value {
    case .int(let number): return number
    case .double(let number):
        guard let whole = Int(exactly: number) else {
            throw CommandFailure(code: .usage, message: "\(key) must be a whole number")
        }
        return whole
    default:
        throw CommandFailure(code: .usage, message: "\(key) must be a whole number")
    }
}

private func boolArgument(_ arguments: [String: Value], _ key: String) throws -> Bool? {
    guard let value = arguments[key] else { return nil }
    guard case .bool(let flag) = value else {
        throw CommandFailure(code: .usage, message: "\(key) must be true or false")
    }
    return flag
}

private func dateArgument(_ arguments: [String: Value], _ key: String) throws -> Date? {
    guard let raw = try stringArgument(arguments, key) else { return nil }
    guard let date = HelperContract.parseFlagDate(raw) else {
        throw CommandFailure(code: .usage, message: "\(key) is not a valid date")
    }
    return date
}

/// The property names a tool's own JSON Schema allows, parsed from the same
/// `inputSchemaJSON` `tools/list` sends — one source of truth, so a key the
/// schema does not know is refused without a second, hand-kept list that
/// could drift from it. `nil` for a name that is not one of the four tools.
private func allowedArgumentKeys(forTool name: String) -> Set<String>? {
    guard let spec = HelperContract.Tools.all.first(where: { $0.name == name }),
          let data = spec.inputSchemaJSON.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let properties = object["properties"] as? [String: Any] else { return nil }
    return Set(properties.keys)
}

/// Turns one tool's JSON arguments into the same `HelperRequest` the CLI
/// builds from flags; every bound (meetings' `limit` 1…500, `count` 1…1000,
/// search's `limit` 1…100, `last` 1…200, `from` ≥ 1) is still enforced once,
/// inside the matching `runX` (`Commands.swift`) — never duplicated here.
private func parseToolRequest(name: String, arguments: [String: Value]) throws -> HelperRequest {
    if let allowed = allowedArgumentKeys(forTool: name),
       let unknownKey = arguments.keys.filter({ !allowed.contains($0) }).sorted().first {
        throw CommandFailure(code: .usage, message: "unknown argument: \(unknownKey)")
    }

    switch name {
    case HelperContract.Tools.listMeetings.name:
        var flags = MeetingsFlags()
        flags.since = try dateArgument(arguments, "since")
        flags.until = try dateArgument(arguments, "until")
        flags.starred = try boolArgument(arguments, "starred") ?? false
        flags.limit = try intArgument(arguments, "limit") ?? 50
        return .meetings(flags)

    case HelperContract.Tools.getTranscript.name:
        guard let id = try stringArgument(arguments, "id"), !id.isEmpty else {
            throw CommandFailure(code: .usage, message: "id is required")
        }
        var flags = TranscriptFlags(id: id)
        flags.from = try intArgument(arguments, "from") ?? 1
        flags.count = try intArgument(arguments, "count") ?? 200
        return .transcript(flags)

    case HelperContract.Tools.search.name:
        guard let text = try stringArgument(arguments, "text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandFailure(code: .usage, message: "text is required")
        }
        var flags = SearchFlags(text: text)
        switch try stringArgument(arguments, "sources") {
        case nil, "all": break
        case "meetings": flags.onlyMeetings = true
        case "dictations": flags.onlyDictations = true
        default: throw CommandFailure(code: .usage, message: "sources must be \"all\", \"meetings\" or \"dictations\"")
        }
        flags.since = try dateArgument(arguments, "since")
        flags.until = try dateArgument(arguments, "until")
        flags.limit = try intArgument(arguments, "limit") ?? 20
        return .search(flags)

    case HelperContract.Tools.recentDictations.name:
        var flags = DictationsFlags()
        flags.last = try intArgument(arguments, "last") ?? 20
        flags.since = try dateArgument(arguments, "since")
        return .dictations(flags)

    default:
        throw CommandFailure(code: .usage, message: "unknown tool: \(name)")
    }
}

// MARK: - Results

private func encodedText<T: Encodable>(_ value: T) -> String {
    (try? String(data: HelperContract.makeEncoder().encode(value), encoding: .utf8)) ?? "{}"
}

private func errorResult(command: String, failure: CommandFailure) -> CallTool.Result {
    let response = HelperContract.ErrorResponse(command: command, code: failure.code, message: failure.message)
    return CallTool.Result(content: [.text(text: encodedText(response), annotations: nil, _meta: nil)], isError: true)
}

private func successResult(_ outcome: CommandOutcome) -> CallTool.Result {
    let text: String
    switch outcome {
    case .meetings(let response): text = encodedText(response)
    case .transcript(let response): text = encodedText(response)
    case .search(let response): text = encodedText(response)
    case .dictations(let response): text = encodedText(response)
    }
    return CallTool.Result(
        content: [
            .text(text: HelperContract.Tools.untrustedNotice, annotations: nil, _meta: nil),
            .text(text: text, annotations: nil, _meta: nil),
        ],
        isError: false
    )
}
