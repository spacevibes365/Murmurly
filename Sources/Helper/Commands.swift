import Foundation

/// A refusal on the way to an answer: carries the exit code and the message
/// `main.swift` prints, never a path (`Archive.ReadError`'s own
/// `localizedDescription` does, so it is never forwarded as it is).
struct CommandFailure: Error, Sendable {
    let code: HelperContract.ErrorCode
    let message: String
}

enum Need {
    case meetings
    case dictations
}

/// The one function both the start of a command and the moment right before
/// it prints call: a switch turned off between the two must refuse the
/// second time too, never only the first.
func requireAccess(_ need: Need, settings: HelperSettings) throws {
    switch need {
    case .meetings:
        guard settings.meetingsEnabled else {
            throw CommandFailure(code: .accessDenied, message: "agents.meetings is off")
        }
    case .dictations:
        guard settings.dictationsEnabled else {
            throw CommandFailure(code: .accessDenied, message: "agents.dictations is off")
        }
    }
}

/// A fresh read of the settings, for the access check right before printing.
func reloadSettings(_ environment: HelperEnvironment) throws -> HelperSettings {
    do {
        return try HelperSettings.load(from: environment.settingsSource)
    } catch {
        throw CommandFailure(code: .accessDenied, message: "agents.periodDays is not readable")
    }
}

#if DEBUG
/// `waitForDebugHold` below, and `requireStillAllowed`'s own hold, share this:
/// polled every 50 ms, capped at 60 s, so a cancelled or timed-out call never
/// leaves a thread waiting forever.
private func waitForDebugHold(path: String?) {
    guard let path, !path.isEmpty else { return }
    let deadline = Date().addingTimeInterval(60)
    while FileManager.default.fileExists(atPath: path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
}
#endif

/// The one place every command's own final check runs through: a fresh
/// settings read, right before printing, that refuses the call — exactly as
/// if access had been off from the start — when any access this call relies
/// on (`needs`; empty for none to check) was turned off, or the period itself
/// changed, while the call was answering. For a mixed search, `needs` names
/// every source that actually entered the search (never one already refused
/// at the start, which is not in the answer anyway), so either source turned
/// off mid-call refuses the whole answer, the same as a single-source call
/// would. A changed period is never silently re-applied: the response was
/// already built against the window at the start of the call, so the only
/// honest answer left is a refusal, the same one an access switch flipped off
/// would give.
func requireStillAllowed(_ needs: [Need], since settings: HelperSettings, environment: HelperEnvironment) throws {
    #if DEBUG
    if let path = HelperEnvironment.debugHoldAnswerPath(), !path.isEmpty {
        FileManager.default.createFile(atPath: path + ".reached", contents: nil)
        waitForDebugHold(path: path)
    }
    #endif
    let fresh = try reloadSettings(environment)
    for need in needs {
        try requireAccess(need, settings: fresh)
    }
    guard fresh.periodDays == settings.periodDays else {
        throw CommandFailure(code: .accessDenied, message: "agents.periodDays changed during the call")
    }
}

// MARK: - A request shared by the CLI and the MCP server

/// What the CLI's argument parser and the MCP server's JSON argument parser
/// both build, so `perform` is the one place that reloads settings and calls
/// a `runX` function — never duplicated per caller.
enum HelperRequest: Sendable {
    case meetings(MeetingsFlags)
    case transcript(TranscriptFlags)
    case search(SearchFlags)
    case dictations(DictationsFlags)

    /// The a2 command verb: what `ErrorResponse.command` and a successful
    /// response's own `command` field already say, in both the CLI and the
    /// MCP server. The MCP tool's own name (`list_meetings`, …) never appears
    /// here; it belongs to MCP's `tools/call` and the log line alone.
    var command: String {
        switch self {
        case .meetings: "meetings"
        case .transcript: "transcript"
        case .search: "search"
        case .dictations: "dictations"
        }
    }
}

/// What a command produced: the typed response and the (already text-only,
/// path-free) fields for the log line. Shared by the CLI's printer and the
/// MCP server's `tools/call` result.
enum CommandOutcome: Sendable {
    case meetings(HelperContract.MeetingsResponse)
    case transcript(HelperContract.TranscriptResponse)
    case search(HelperContract.SearchResponse)
    case dictations(HelperContract.DictationsResponse)
}

struct CommandSuccess: Sendable {
    let outcome: CommandOutcome
    let logFields: String
}

/// The limit `fitItems` measures against: a plain JSON response for the CLI,
/// or — for the MCP server — a JSON response that is itself re-encoded as one
/// JSON string inside `tools/call`'s `content` (every quote and backslash
/// doubles), which costs more than the same bytes on their own. `maxBytes` is
/// already net of the envelope's own cost; the caller picks it.
struct ResponseBudget: Sendable {
    let maxBytes: Int
    let inJSONString: Bool

    func encodedSize<T: Encodable>(_ value: T) -> Int {
        guard let data = try? HelperContract.makeEncoder().encode(value) else { return Int.max }
        guard inJSONString else { return data.count }
        guard let text = String(data: data, encoding: .utf8),
              let wrapped = try? JSONEncoder().encode(text) else { return Int.max }
        return wrapped.count
    }
}

/// The exact size `fitItems` would have measured, for whichever response
/// `perform` ends up with: the one place that can compare the finished answer
/// against `budget` regardless of which `runX` built it.
private func encodedOutcomeSize(_ outcome: CommandOutcome, budget: ResponseBudget) -> Int {
    switch outcome {
    case .meetings(let response): return budget.encodedSize(response)
    case .transcript(let response): return budget.encodedSize(response)
    case .search(let response): return budget.encodedSize(response)
    case .dictations(let response): return budget.encodedSize(response)
    }
}

/// The one function both the CLI and the MCP server call to actually run a
/// request: reloads settings fresh (so a switch flipped between calls is seen
/// by the very next one, never only after a restart) and dispatches to the
/// matching `runX`.
func perform(_ request: HelperRequest, environment: HelperEnvironment, budget: ResponseBudget) throws -> CommandSuccess {
    #if DEBUG
    // `MURMURLY_HELPER_HOLD`: a stand-in for a hung network volume, called
    // before settings or the archive are touched at all.
    waitForDebugHold(path: HelperEnvironment.debugHoldPath())
    #endif
    let settings = try reloadSettings(environment)
    let success: CommandSuccess
    switch request {
    case .meetings(let flags):
        let response = try runMeetings(environment: environment, settings: settings, flags: flags, budget: budget)
        success = CommandSuccess(outcome: .meetings(response), logFields: "count=\(response.meetings.count)")
    case .transcript(let flags):
        let response = try runTranscript(environment: environment, settings: settings, flags: flags, budget: budget)
        success = CommandSuccess(
            outcome: .transcript(response),
            logFields: "id=\(response.id) from=\(response.from) count=\(response.lines.count)"
        )
    case .search(let flags):
        let response = try runSearch(environment: environment, settings: settings, flags: flags, budget: budget)
        let sources = flags.onlyMeetings ? "meetings" : (flags.onlyDictations ? "dictations" : "meetings,dictations")
        success = CommandSuccess(
            outcome: .search(response),
            logFields: "sources=\(sources) meetings=\(response.meetings.count) dictations=\(response.dictations.count)"
        )
    case .dictations(let flags):
        let response = try runDictations(environment: environment, settings: settings, flags: flags, budget: budget)
        success = CommandSuccess(outcome: .dictations(response), logFields: "count=\(response.dictations.count)")
    }

    // The last safeguard: `fitItems` shrinks the items a `runX` controls, but
    // `unread` (broken links, unreadable folders) is never shrunk and can on
    // its own push the finished answer past the limit. Measured against the
    // very response about to be sent, never an estimate.
    guard encodedOutcomeSize(success.outcome, budget: budget) <= budget.maxBytes else {
        throw CommandFailure(code: .readError, message: "the answer is too large; narrow it with since/until/limit")
    }
    return success
}

// MARK: - An async, cancellation-aware timeout, for the MCP server

/// `withTimeout`'s outcome, kept distinct from a plain `nil` so the caller can
/// tell a cancelled `tools/call` (answer with nothing — SDK 0.12.1 only stays
/// silent on a thrown `CancellationError`) apart from one that merely ran out
/// of time (answer `notResponding`).
enum AsyncTimeoutOutcome<T: Sendable>: Sendable {
    case value(T)
    case timedOut
    case cancelled
}

/// `withAsyncTimeout`'s one-time resume flag under a lock, pulled out to file
/// scope: a generic function cannot nest a type of its own.
private final class AsyncTimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AsyncTimeoutOutcome<T>, Never>?
    private var resumed = false
    private var pending: AsyncTimeoutOutcome<T>?

    func setContinuation(_ continuation: CheckedContinuation<AsyncTimeoutOutcome<T>, Never>) {
        lock.lock()
        if resumed {
            let outcome = pending ?? .cancelled
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resumeOnce(_ outcome: AsyncTimeoutOutcome<T>) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        pending = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

/// Runs `work` on its own thread, same as `withTimeout` below, but as an
/// `async` function that resumes early — as `.cancelled` — when the calling
/// `Task` is cancelled (the MCP server cancels a handler's `Task` on
/// `notifications/cancelled`). Only one of the three sources (the worker
/// finishing, the deadline, cancellation) may resume the continuation; a
/// one-time flag under a lock decides which, so a late arrival is silently
/// dropped instead of resuming twice. A timed-out or cancelled worker is left
/// running; its result, if it ever finishes, is discarded.
func withAsyncTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () -> T) async -> AsyncTimeoutOutcome<T> {
    let state = AsyncTimeoutState<T>()
    return await withTaskCancellationHandler(
        operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<AsyncTimeoutOutcome<T>, Never>) in
                state.setContinuation(continuation)
                let thread = Thread {
                    let value = work()
                    state.resumeOnce(.value(value))
                }
                thread.start()
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    state.resumeOnce(.timedOut)
                }
            }
        },
        onCancel: {
            state.resumeOnce(.cancelled)
        }
    )
}

// MARK: - A cross-thread result, for the timeout below

/// `DispatchSemaphore` lets the main thread wait for a worker without being
/// `Sendable` itself across the boundary; the worker's own result still needs
/// a box to cross back. `nonisolated(unsafe)` is not used: a lock makes the
/// box provably safe instead of merely promising it.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    func set(_ value: T) {
        lock.lock()
        storage = value
        lock.unlock()
    }
    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Runs `work` on its own thread and waits up to `seconds`; nil means it did
/// not finish in time — the caller treats that as `notResponding`. A timed
/// out worker is left running: the exit right after this call ends the
/// process regardless of it.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () -> T) -> T? {
    let box = Box<T>()
    let semaphore = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.set(work())
        semaphore.signal()
    }
    thread.start()
    guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
    return box.get()
}

// MARK: - One in-flight read of the chosen root, per process

/// A one-time flag under a lock, same shape as `AsyncTimeoutState` above: a
/// bare `var` captured by `withTimeout`'s `@Sendable` closure does not
/// compile under Swift 6's strict concurrency.
private final class ChosenRootGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    /// `true` only if no other read of the chosen root is in flight — and
    /// marks one as started. The caller that gets `false` must not start a
    /// second one on top of it; it answers `notResponding` at once instead.
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    /// Called by the worker itself when it is actually done — never by the
    /// timeout, which only stops waiting, not the worker: a thread left
    /// running past its deadline must keep the gate closed, so the very next
    /// call also answers `notResponding` rather than piling a second hung
    /// read on top of the first.
    func end() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}

private let chosenRootGate = ChosenRootGate()

enum ChosenRootOutcome<T: Sendable>: Sendable {
    case unavailable
    case notResponding
    case value(T)
}

/// The one place that reads anything from the chosen meetings folder: a
/// network volume that hangs must neither hold up the local meetings (the 5 s
/// limit covers the availability check too, not just the read after it) nor
/// leave a second call waiting behind the first (`ChosenRootGate`, above). A
/// read already in flight makes every later call answer `notResponding` for
/// the chosen root at once, until the one actually running finishes — by
/// success, by finding the volume gone, or by failing to read it.
func readChosenRoot<T: Sendable>(_ chosen: URL, seconds: Double = 5, read: @escaping @Sendable () -> T) -> ChosenRootOutcome<T> {
    guard chosenRootGate.begin() else { return .notResponding }
    let probe: @Sendable () -> ChosenRootOutcome<T> = {
        defer { chosenRootGate.end() }
        #if DEBUG
        waitForDebugHold(path: HelperEnvironment.debugHoldChosenPath())
        #endif
        guard MeetingStorage.isAvailable(chosen) else { return .unavailable }
        return .value(read())
    }
    guard let result = withTimeout(seconds: seconds, probe) else { return .notResponding }
    return result
}

// MARK: - Meetings listing with a timed-out chosen folder

func rootStatus(_ state: Archive.RootState) -> HelperContract.RootStatus {
    switch state {
    case .read: .read
    case .unavailable: .unavailable
    case .failed: .readError
    }
}

/// The local root, read on its own with no time limit (it is this Mac's own
/// folder; a hang there is not a case this helper guards against), and —
/// when set — the chosen root, probed on its own with a 5 s limit so a slow
/// or hanging network folder never holds back the local meetings: past the
/// limit, `chosen` is reported `notResponding` and left out of the listing
/// entirely, the local meetings still in the answer. Earlier, both roots
/// shared one 5 s budget: a slow local root (nothing to do with the chosen
/// one at all) made the chosen root time out too, every time.
func listMeetings(environment: HelperEnvironment, settings: HelperSettings) -> (Archive.Listing, HelperContract.RootStatus) {
    #if DEBUG
    waitForDebugHold(path: HelperEnvironment.debugHoldLocalPath())
    #endif
    let localRead = Archive.readRoot(environment.meetingsRoot, as: .local, links: .refuse, records: .summary)
    guard let chosen = settings.chosenMeetingsFolder else {
        return (Archive.combine(local: localRead, chosen: nil), .notSet)
    }
    switch readChosenRoot(chosen, read: { Archive.readRoot(chosen, as: .chosen, links: .refuse, records: .summary) }) {
    case .unavailable:
        return (Archive.combine(local: localRead, chosen: nil), .unavailable)
    case .notResponding:
        return (Archive.combine(local: localRead, chosen: nil), .notResponding)
    case .value(let chosenRead):
        return (Archive.combine(local: localRead, chosen: chosenRead), rootStatus(chosenRead.state))
    }
}

/// Whether a link skipped in a root during the latest listing belongs to
/// `local` or `chosen`, by its parent folder; `link` for any such skip,
/// `readError` for anything else `MeetingStorage` could name. A skip outside
/// `period`'s own window (by the date in its folder name) is never raised at
/// all — a skipped folder has no other facts to show it by; one whose name
/// carries no date is still raised, with `id: nil`, rather than silently
/// dropped or wrongly admitted into the period.
func unreadFromSkipped(_ skipped: [Archive.SkippedFolder], local: URL, chosen: URL?, period: HelperContract.Period) -> [HelperContract.Unread] {
    let chosenCanonical = chosen.map(Archive.canonical)
    let hasWindow = period.from != nil || period.until != nil
    var result: [HelperContract.Unread] = []
    for item in skipped {
        let parent = Archive.canonical(item.url.deletingLastPathComponent())
        let root: Archive.Root = (chosenCanonical != nil && parent == chosenCanonical) ? .chosen : .local
        let reason = item.reason.localizedCaseInsensitiveContains("link") ? "link" : "readError"
        let name = item.url.lastPathComponent
        guard hasWindow else {
            result.append(HelperContract.Unread(
                id: HelperContract.meetingID(root: root, folderName: name), root: HelperContract.rootName(root), reason: reason
            ))
            continue
        }
        let date = MeetingStorage.date(fromFolderName: name)
        if let date, !inPeriod(date, period: period) { continue }
        let id = date != nil ? HelperContract.meetingID(root: root, folderName: name) : nil
        result.append(HelperContract.Unread(id: id, root: HelperContract.rootName(root), reason: reason))
    }
    return result
}

/// Whether `date` falls in `period`: no window at all admits everything, a
/// window with no `startedAt` to compare admits nothing.
func inPeriod(_ date: Date?, period: HelperContract.Period) -> Bool {
    guard period.from != nil || period.until != nil else { return true }
    guard let date else { return false }
    if let from = period.from, date < from { return false }
    if let until = period.until, date >= until { return false }
    return true
}

// MARK: - Snippets

/// A meeting's snippet: up to 80 characters either side of the match, never
/// past the line's own body (never its time, label or the header).
func meetingSnippet(string: NSString, matchRange: NSRange, bodyRange: NSRange, context: Int = 80) -> String {
    let start = max(bodyRange.location, matchRange.location - context)
    let end = min(NSMaxRange(bodyRange), NSMaxRange(matchRange) + context)
    guard start >= 0, end <= string.length, start <= end else { return string.substring(with: bodyRange) }
    var text = string.substring(with: NSRange(location: start, length: end - start))
    if start > bodyRange.location { text = "…" + text }
    if end < NSMaxRange(bodyRange) { text += "…" }
    return text
}

/// A dictation's snippet, by the same comparison as the window's dictation
/// search (`DictationHistoryEntry.matches`, case-insensitive, ё and е kept
/// apart) — never `MeetingSearch`'s rule, which folds them.
func dictationSnippet(text: String, needle: String, context: Int = 80) -> String {
    let string = text as NSString
    let range = string.range(of: needle, options: .caseInsensitive)
    guard range.location != NSNotFound else { return text }
    let start = max(0, range.location - context)
    let end = min(string.length, NSMaxRange(range) + context)
    var snippet = string.substring(with: NSRange(location: start, length: end - start))
    if start > 0 { snippet = "…" + snippet }
    if end < string.length { snippet += "…" }
    return snippet
}

// MARK: - `meetings`

struct MeetingsFlags {
    var since: Date?
    var until: Date?
    var starred = false
    var limit = 50
}

/// Whether `a` and `b` fall in the same whole second, by floor: meetings'
/// `startedAt` always comes from a folder name with second resolution, never
/// fractional, so this is the exact granularity a split between two of them
/// would happen at. Two meetings with no date at all count as the same
/// (never split a run of undated meetings at an arbitrary point either); one
/// dated and one not are never the same.
private func sameWholeSecond(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let left?, let right?): return left.timeIntervalSince1970.rounded(.down) == right.timeIntervalSince1970.rounded(.down)
    default: return false
    }
}

func runMeetings(
    environment: HelperEnvironment, settings: HelperSettings, flags: MeetingsFlags, budget: ResponseBudget
) throws -> HelperContract.MeetingsResponse {
    try requireAccess(.meetings, settings: settings)
    guard (1...500).contains(flags.limit) else { throw CommandFailure(code: .usage, message: "--limit must be between 1 and 500") }
    let period = HelperContract.effectivePeriod(now: Date(), periodDays: settings.periodDays, since: flags.since, until: flags.until)

    let (listing, chosenStatus) = listMeetings(environment: environment, settings: settings)
    let roots = HelperContract.Roots(local: rootStatus(listing.local), chosen: chosenStatus)

    var items: [HelperContract.MeetingItem] = []
    var unread = unreadFromSkipped(
        listing.skipped, local: environment.meetingsRoot, chosen: settings.chosenMeetingsFolder, period: period
    )
    for meeting in listing.meetings {
        guard inPeriod(meeting.folder.startedAt, period: period) else { continue }
        guard let id = HelperContract.meetingID(root: meeting.root, folderName: meeting.folder.directory.lastPathComponent) else { continue }
        if flags.starred {
            // Whether this meeting qualifies is unknown, never guessed as
            // "not starred": a star the file cannot prove is not a missing
            // star.
            guard meeting.readable, meeting.folder.marks.marks != nil else {
                let reason = meeting.readable ? HelperContract.Unread.marksUnreadable : "readError"
                unread.append(HelperContract.Unread(id: id, root: HelperContract.rootName(meeting.root), reason: reason))
                continue
            }
            guard meeting.starred else { continue }
        }
        items.append(HelperContract.MeetingItem(
            id: id,
            root: HelperContract.rootName(meeting.root),
            title: meeting.title,
            startedAt: meeting.folder.startedAt,
            duration: meeting.folder.duration,
            state: meeting.folder.state,
            metadataError: meeting.folder.metadataError,
            issues: meeting.folder.issues,
            starred: meeting.starred,
            readable: meeting.readable,
            transcripts: meeting.folder.versions.count,
            latestTranscript: meeting.latest.map { HelperContract.Version(number: $0.number, modified: $0.modified) },
            lastAttempt: HelperContract.lastAttemptName(meeting.completeness),
            completeness: HelperContract.completeness(meeting)
        ))
    }

    // Newest first already (`Archive.combine`'s own sort). `--limit` cuts
    // the page, extended so it never splits one second's meetings between
    // what's shown and what's held back: a few extra same-second meetings
    // past `limit` are shown rather than split (the limit is soft for them).
    var limitCutIndex = min(flags.limit, items.count)
    while limitCutIndex < items.count, sameWholeSecond(items[limitCutIndex - 1].startedAt, items[limitCutIndex].startedAt) {
        limitCutIndex += 1
    }
    let limitPage = Array(items.prefix(limitCutIndex))

    // Every index inside `limitPage` where cutting is safe: the end of the
    // page itself, and the end of every run of same-second meetings. Cutting
    // anywhere else would split such a run between this page and
    // `nextUntil`, which `--until` (exclusive) could never recover without
    // dropping part of it.
    var boundaries: [Int] = []
    if !limitPage.isEmpty {
        for i in 1...limitPage.count where i == limitPage.count || !sameWholeSecond(limitPage[i - 1].startedAt, limitPage[i].startedAt) {
            boundaries.append(i)
        }
    }

    // The exact response for showing the first `count` of `limitPage`: what
    // is measured here is what is sent, so the byte budget this picks by is
    // never off by the size of a field filled in only afterwards.
    func candidateResponse(count: Int) -> HelperContract.MeetingsResponse {
        let prefix = Array(limitPage.prefix(count))
        let hasMore = prefix.count < items.count
        let truncated = count < limitPage.count
        return HelperContract.MeetingsResponse(
            schema: HelperContract.schemaVersion, command: "meetings", period: period, roots: roots,
            meetings: prefix, unread: unread, hasMore: hasMore, nextUntil: hasMore ? prefix.last?.startedAt : nil,
            truncated: truncated
        )
    }

    let finalResponse: HelperContract.MeetingsResponse
    if let bestBoundary = boundaries.reversed().first(where: { budget.encodedSize(candidateResponse(count: $0)) <= budget.maxBytes }) {
        finalResponse = candidateResponse(count: bestBoundary)
    } else {
        // No boundary is safe — even the very first run of same-second
        // meetings alone exceeds the byte limit. Keep the byte-fit page as
        // it is, some of that run shown and the rest not, and give no cursor
        // at all: any boundary inside that one second would still drop
        // whichever sibling landed on the far side.
        let firstGroupEnd = boundaries.first ?? 0
        let firstGroup = Array(limitPage.prefix(firstGroupEnd))
        let (fitGroup, groupTruncated) = HelperContract.fitItems(
            firstGroup, maxBytes: budget.maxBytes,
            encodedSize: { prefix in
                budget.encodedSize(HelperContract.MeetingsResponse(
                    schema: HelperContract.schemaVersion, command: "meetings", period: period, roots: roots,
                    meetings: prefix, unread: unread, hasMore: true, nextUntil: nil, truncated: true
                ))
            },
            shrinkText: { item, limit in
                var copy = item
                if let title = copy.title, title.count > limit { copy.title = String(title.prefix(limit)) }
                return copy
            }
        )
        finalResponse = HelperContract.MeetingsResponse(
            schema: HelperContract.schemaVersion, command: "meetings", period: period, roots: roots,
            meetings: fitGroup, unread: unread, hasMore: fitGroup.count < items.count, nextUntil: nil,
            truncated: groupTruncated
        )
    }

    try requireStillAllowed([.meetings], since: settings, environment: environment)

    return finalResponse
}

// MARK: - `transcript`

/// A meeting's own folder being a link: disclosed (`readError`, naming the
/// reason) only inside `period`'s window, exactly as `unreadFromSkipped`
/// already discloses a link found while listing — outside it, the same
/// silent `notFound` as any other meeting that is simply not there.
private func linkOrNotFoundFailure(folderName: String, period: HelperContract.Period) -> CommandFailure {
    guard inPeriod(MeetingStorage.date(fromFolderName: folderName), period: period) else {
        return CommandFailure(code: .notFound, message: "no such meeting")
    }
    return CommandFailure(code: .readError, message: "the meeting's folder is a link")
}

struct TranscriptFlags {
    var id: String
    var from = 1
    var count = 200
}

func runTranscript(
    environment: HelperEnvironment, settings: HelperSettings, flags: TranscriptFlags, budget: ResponseBudget
) throws -> HelperContract.TranscriptResponse {
    try requireAccess(.meetings, settings: settings)
    guard flags.from >= 1 else { throw CommandFailure(code: .usage, message: "--from must be at least 1") }
    guard (1...1000).contains(flags.count) else { throw CommandFailure(code: .usage, message: "--count must be between 1 and 1000") }

    let period = HelperContract.effectivePeriod(now: Date(), periodDays: settings.periodDays, since: nil, until: nil)
    guard let parsed = HelperContract.parseMeetingID(flags.id) else {
        throw CommandFailure(code: .notFound, message: "no such meeting")
    }

    // One folder, found directly by its id — never the whole listing, which
    // `meetings`/`search` need but a single transcript does not.
    let meeting: Archive.Meeting?
    switch parsed.root {
    case .local:
        do {
            meeting = try Archive.meeting(
                root: .local, folderName: parsed.folderName, local: environment.meetingsRoot, chosen: nil, records: .full
            )
        } catch Archive.ReadError.link {
            throw linkOrNotFoundFailure(folderName: parsed.folderName, period: period)
        } catch {
            throw CommandFailure(code: .readError, message: "the local meetings folder can't be read")
        }
    case .chosen:
        guard let chosenFolder = settings.chosenMeetingsFolder else {
            throw CommandFailure(code: .notFound, message: "no such meeting")
        }
        // `withTimeout` cannot propagate a throw across the thread hop, so
        // the probe folds its own success/failure/link/not-found into one result.
        enum Probe: Sendable {
            case found(Archive.Meeting?)
            case link
            case failed
        }
        let outcome = readChosenRoot(chosenFolder) { () -> Probe in
            do {
                return .found(try Archive.meeting(
                    root: .chosen, folderName: parsed.folderName, local: environment.meetingsRoot, chosen: chosenFolder, records: .full
                ))
            } catch Archive.ReadError.link {
                return .link
            } catch {
                return .failed
            }
        }
        switch outcome {
        case .unavailable:
            throw CommandFailure(code: .readError, message: "the chosen meetings folder can't be read")
        case .notResponding:
            throw CommandFailure(code: .notResponding, message: "the chosen meetings folder is not responding")
        case .value(.found(let found)):
            meeting = found
        case .value(.link):
            throw linkOrNotFoundFailure(folderName: parsed.folderName, period: period)
        case .value(.failed):
            throw CommandFailure(code: .readError, message: "the chosen meetings folder can't be read")
        }
    }

    guard let meeting, inPeriod(meeting.folder.startedAt, period: period) else {
        throw CommandFailure(code: .notFound, message: "no such meeting")
    }
    guard meeting.readable else {
        throw CommandFailure(code: .readError, message: "can't read the meeting's folder")
    }
    guard let latest = meeting.latest else {
        throw CommandFailure(code: .notFound, message: "no transcript")
    }

    let transcript: MeetingTranscript
    do {
        guard let read = try Archive.transcript(of: meeting, links: .refuse) else {
            throw CommandFailure(code: .notFound, message: "no transcript")
        }
        transcript = read
    } catch let failure as CommandFailure {
        throw failure
    } catch {
        throw CommandFailure(code: .readError, message: "can't read \(latest.name)")
    }

    let format: String
    let allLines: [HelperContract.TranscriptLine]
    if let lines = transcript.lines {
        format = "lines"
        let starts = transcript.timing.starts
        allLines = lines.enumerated().map { index, line in
            HelperContract.TranscriptLine(
                n: index + 1, start: starts.indices.contains(index) ? starts[index] : nil,
                timecode: line.timecode, speaker: line.speaker, text: line.text
            )
        }
    } else {
        format = "text"
        var rawLines = transcript.raw.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        allLines = rawLines.enumerated().map { index, text in
            HelperContract.TranscriptLine(n: index + 1, start: nil, timecode: nil, speaker: nil, text: text)
        }
    }

    let totalLines = allLines.count
    let startIndex = flags.from - 1
    let page: [HelperContract.TranscriptLine]
    if startIndex >= totalLines {
        page = []
    } else {
        let endIndex = min(totalLines, startIndex + flags.count)
        page = Array(allLines[startIndex..<endIndex])
    }
    let pageHasMore = startIndex < totalLines && (startIndex + page.count) < totalLines

    let version = HelperContract.Version(number: latest.number, modified: latest.modified)
    let completeness = HelperContract.completeness(meeting, transcript: transcript)
    let (finalPage, sizeTruncated) = HelperContract.fitItems(
        page, maxBytes: budget.maxBytes,
        encodedSize: { prefix in
            budget.encodedSize(HelperContract.TranscriptResponse(
                schema: HelperContract.schemaVersion, command: "transcript", id: flags.id, version: version,
                completeness: completeness, format: format, totalLines: totalLines, from: flags.from,
                lines: prefix, hasMore: true, nextFrom: startIndex + prefix.count + 1, truncated: true
            ))
        },
        shrinkText: { line, limit in
            var copy = line
            if copy.text.count > limit { copy.text = String(copy.text.prefix(limit)) }
            return copy
        }
    )
    let truncated = sizeTruncated
    // Dropping whole lines always leaves more to fetch; shrinking the one
    // surviving line's own text does not, unless the page already had more
    // beyond it (`pageHasMore`).
    let itemsDropped = finalPage.count < page.count
    let hasMore = pageHasMore || itemsDropped
    let nextFrom = hasMore ? startIndex + finalPage.count + 1 : nil

    try requireStillAllowed([.meetings], since: settings, environment: environment)

    return HelperContract.TranscriptResponse(
        schema: HelperContract.schemaVersion, command: "transcript", id: flags.id, version: version,
        completeness: completeness, format: format, totalLines: totalLines,
        from: flags.from, lines: finalPage, hasMore: hasMore, nextFrom: nextFrom, truncated: truncated
    )
}

// MARK: - `search`

struct SearchFlags {
    var text: String
    var onlyMeetings = false
    var onlyDictations = false
    var since: Date?
    var until: Date?
    var limit = 20
}

func runSearch(
    environment: HelperEnvironment, settings: HelperSettings, flags: SearchFlags, budget: ResponseBudget
) throws -> HelperContract.SearchResponse {
    let trimmed = flags.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CommandFailure(code: .usage, message: "search text must not be empty") }
    guard (1...100).contains(flags.limit) else { throw CommandFailure(code: .usage, message: "--limit must be between 1 and 100") }
    guard !(flags.onlyMeetings && flags.onlyDictations) else {
        throw CommandFailure(code: .usage, message: "choose at most one of --meetings/--dictations")
    }

    let includeMeetings: Bool
    let includeDictations: Bool
    var denied: [String] = []
    if flags.onlyMeetings {
        try requireAccess(.meetings, settings: settings)
        includeMeetings = true
        includeDictations = false
    } else if flags.onlyDictations {
        try requireAccess(.dictations, settings: settings)
        includeMeetings = false
        includeDictations = true
    } else {
        includeMeetings = settings.meetingsEnabled
        includeDictations = settings.dictationsEnabled
        if !includeMeetings { denied.append("meetings") }
        if !includeDictations { denied.append("dictations") }
        guard includeMeetings || includeDictations else {
            throw CommandFailure(code: .accessDenied, message: "agents.meetings and agents.dictations are both off")
        }
    }

    let period = HelperContract.effectivePeriod(now: Date(), periodDays: settings.periodDays, since: flags.since, until: flags.until)

    var meetingHits: [HelperContract.MeetingHit] = []
    var unread: [HelperContract.Unread] = []
    var roots = HelperContract.Roots(local: .notSet, chosen: .notSet)
    var meetingsHasMore = false

    if includeMeetings {
        let (listing, chosenStatus) = listMeetings(environment: environment, settings: settings)
        roots = HelperContract.Roots(local: rootStatus(listing.local), chosen: chosenStatus)
        unread += unreadFromSkipped(
            listing.skipped, local: environment.meetingsRoot, chosen: settings.chosenMeetingsFolder, period: period
        )

        /// One meeting's own outcome, built inside `autoreleasepool` below so
        /// a long run never keeps thousands of transcripts' worth of
        /// Foundation objects alive until the whole search ends; `continue`/
        /// `break meetingLoop` cannot reach into a closure, so the loop acts
        /// on this plain value once the pool has drained.
        struct MeetingStep {
            var unreadReason: String?
            var hits: [HelperContract.MeetingHit] = []
            /// Stopped early because `flags.limit` was reached while this
            /// meeting still had more candidate lines: the loop must stop
            /// here too, same as the limit being hit used to break it
            /// mid-meeting before this was pulled into its own function.
            var cappedEarly = false
        }

        meetingLoop: for meeting in listing.meetings {
            guard inPeriod(meeting.folder.startedAt, period: period) else { continue }
            guard let id = HelperContract.meetingID(root: meeting.root, folderName: meeting.folder.directory.lastPathComponent) else { continue }
            guard meeting.readable else {
                unread.append(HelperContract.Unread(id: id, root: HelperContract.rootName(meeting.root), reason: "readError"))
                continue
            }
            guard meeting.latest != nil else { continue }

            let remaining = flags.limit - meetingHits.count
            let step: MeetingStep = autoreleasepool {
                var step = MeetingStep()
                let transcript: MeetingTranscript?
                do {
                    transcript = try Archive.transcript(of: meeting, links: .refuse, containing: trimmed)
                } catch let error as Archive.ReadError {
                    step.unreadReason = { if case .link = error { return "link" } else { return "readError" } }()
                    return step
                } catch {
                    step.unreadReason = "readError"
                    return step
                }
                guard let transcript else { return step }

                if let lines = transcript.lines {
                    let layout = transcript.layout
                    let folded = MeetingSearch.fold(layout.string) as NSString
                    let starts = transcript.timing.starts
                    for (index, layoutLine) in layout.lines.enumerated() {
                        guard let first = MeetingSearch.ranges(of: trimmed, inFolded: folded, within: [layoutLine.body]).first else { continue }
                        guard step.hits.count < remaining else {
                            step.cappedEarly = true
                            break
                        }
                        step.hits.append(HelperContract.MeetingHit(
                            meetingId: id, title: meeting.title, startedAt: meeting.folder.startedAt,
                            line: index + 1, start: starts.indices.contains(index) ? starts[index] : nil,
                            timecode: lines.indices.contains(index) ? lines[index].timecode : nil,
                            speaker: lines.indices.contains(index) ? lines[index].speaker : nil,
                            snippet: meetingSnippet(string: layout.string as NSString, matchRange: first, bodyRange: layoutLine.body)
                        ))
                    }
                } else {
                    // A text not in the app's own form: searched line by
                    // line, by the same file-line number `transcript`'s own
                    // `format: "text"` gives each line — never the window's
                    // rule, which searches the whole text as one block and
                    // so also finds a query that straddles a line break,
                    // which this never will.
                    let raw = transcript.raw as NSString
                    let folded = MeetingSearch.fold(transcript.raw) as NSString
                    var rawLines = transcript.raw.components(separatedBy: "\n")
                    if rawLines.last == "" { rawLines.removeLast() }
                    var cursor = 0
                    for (index, text) in rawLines.enumerated() {
                        let lineRange = NSRange(location: cursor, length: (text as NSString).length)
                        cursor += lineRange.length + 1
                        guard let first = MeetingSearch.ranges(of: trimmed, inFolded: folded, within: [lineRange]).first else { continue }
                        guard step.hits.count < remaining else {
                            step.cappedEarly = true
                            break
                        }
                        step.hits.append(HelperContract.MeetingHit(
                            meetingId: id, title: meeting.title, startedAt: meeting.folder.startedAt,
                            line: index + 1, start: nil, timecode: nil, speaker: nil,
                            snippet: meetingSnippet(string: raw, matchRange: first, bodyRange: lineRange)
                        ))
                    }
                }
                return step
            }

            if let reason = step.unreadReason {
                unread.append(HelperContract.Unread(id: id, root: HelperContract.rootName(meeting.root), reason: reason))
                continue
            }
            meetingHits.append(contentsOf: step.hits)
            if step.cappedEarly {
                meetingsHasMore = true
                break meetingLoop
            }
        }
    }

    var dictationHits: [HelperContract.DictationHit] = []
    var skippedLines = 0
    var dictationsHasMore = false
    if includeDictations {
        let needle = DictationHistoryEntry.searchNeedle(trimmed) ?? trimmed
        let result: Archive.DictationsRead
        do {
            result = try Archive.dictationsRead(
                root: environment.dictationsRoot, limit: flags.limit + 1, matching: trimmed,
                from: period.from, to: period.until, links: .refuse
            )
        } catch {
            // A broken `history.jsonl` refuses the whole search: never a
            // silent empty `dictations` sitting next to real meeting hits.
            throw CommandFailure(code: .readError, message: "can't read \(DictationHistoryEntry.historyFileName)")
        }
        skippedLines = result.malformedLines
        var entries = result.entries
        if entries.count > flags.limit {
            dictationsHasMore = true
            entries = Array(entries.prefix(flags.limit))
        }
        dictationHits = entries.map { entry in
            HelperContract.DictationHit(
                id: entry.id, at: entry.at, status: HelperContract.dictationStatus(entry),
                snippet: dictationSnippet(text: entry.text, needle: needle)
            )
        }
    }

    var needs: [Need] = []
    if includeMeetings { needs.append(.meetings) }
    if includeDictations { needs.append(.dictations) }
    try requireStillAllowed(needs, since: settings, environment: environment)

    let combinedHasMore = meetingsHasMore || dictationsHasMore
    func buildSearch(meetings: [HelperContract.MeetingHit], dictations: [HelperContract.DictationHit]) -> HelperContract.SearchResponse {
        HelperContract.SearchResponse(
            schema: HelperContract.schemaVersion, command: "search", period: period, roots: roots,
            meetings: meetings, dictations: dictations, hasMore: combinedHasMore,
            unread: unread, denied: denied, skippedLines: skippedLines, truncated: true
        )
    }
    func shrinkSnippet<Hit>(_ hit: Hit, limit: Int, snippet: (Hit) -> String, setSnippet: (inout Hit, String) -> Void) -> Hit {
        var copy = hit
        let text = snippet(hit)
        if text.count > limit { setSnippet(&copy, String(text.prefix(limit))) }
        return copy
    }

    var finalMeetingHits = meetingHits
    var finalDictationHits = dictationHits
    var sizeTruncated = false
    if budget.encodedSize(buildSearch(meetings: finalMeetingHits, dictations: finalDictationHits)) > budget.maxBytes {
        sizeTruncated = true
        let (trimmedDictations, _) = HelperContract.fitItems(
            finalDictationHits, maxBytes: budget.maxBytes,
            encodedSize: { prefix in budget.encodedSize(buildSearch(meetings: finalMeetingHits, dictations: prefix)) },
            shrinkText: { hit, limit in shrinkSnippet(hit, limit: limit, snippet: { $0.snippet }, setSnippet: { $0.snippet = $1 }) }
        )
        finalDictationHits = trimmedDictations
        if budget.encodedSize(buildSearch(meetings: finalMeetingHits, dictations: finalDictationHits)) > budget.maxBytes {
            let (trimmedMeetings, _) = HelperContract.fitItems(
                finalMeetingHits, maxBytes: budget.maxBytes,
                encodedSize: { prefix in budget.encodedSize(buildSearch(meetings: prefix, dictations: finalDictationHits)) },
                shrinkText: { hit, limit in shrinkSnippet(hit, limit: limit, snippet: { $0.snippet }, setSnippet: { $0.snippet = $1 }) }
            )
            finalMeetingHits = trimmedMeetings
        }
    }

    return HelperContract.SearchResponse(
        schema: HelperContract.schemaVersion, command: "search", period: period, roots: roots,
        meetings: finalMeetingHits, dictations: finalDictationHits, hasMore: combinedHasMore || sizeTruncated,
        unread: unread, denied: denied, skippedLines: skippedLines, truncated: sizeTruncated
    )
}

// MARK: - `dictations`

struct DictationsFlags {
    var last = 20
    var since: Date?
}

func runDictations(
    environment: HelperEnvironment, settings: HelperSettings, flags: DictationsFlags, budget: ResponseBudget
) throws -> HelperContract.DictationsResponse {
    try requireAccess(.dictations, settings: settings)
    guard (1...200).contains(flags.last) else { throw CommandFailure(code: .usage, message: "--last must be between 1 and 200") }

    let period = HelperContract.effectivePeriod(now: Date(), periodDays: settings.periodDays, since: flags.since, until: nil)

    let result: Archive.DictationsRead
    do {
        result = try Archive.dictationsRead(
            root: environment.dictationsRoot, limit: flags.last, matching: nil,
            from: period.from, to: period.until, links: .refuse
        )
    } catch {
        throw CommandFailure(code: .readError, message: "can't read \(DictationHistoryEntry.historyFileName)")
    }

    let items = result.entries.map { entry in
        HelperContract.DictationItem(id: entry.id, at: entry.at, duration: entry.duration, text: entry.text, status: HelperContract.dictationStatus(entry))
    }
    let skippedLines = result.malformedLines

    let (finalItems, truncated) = HelperContract.fitItems(
        items, maxBytes: budget.maxBytes,
        encodedSize: { prefix in
            budget.encodedSize(HelperContract.DictationsResponse(
                schema: HelperContract.schemaVersion, command: "dictations", period: period,
                dictations: prefix, skippedLines: skippedLines, truncated: true
            ))
        },
        shrinkText: { item, limit in
            var copy = item
            if copy.text.count > limit { copy.text = String(copy.text.prefix(limit)) }
            return copy
        }
    )

    try requireStillAllowed([.dictations], since: settings, environment: environment)

    return HelperContract.DictationsResponse(
        schema: HelperContract.schemaVersion, command: "dictations", period: period,
        dictations: finalItems, skippedLines: skippedLines, truncated: truncated
    )
}
