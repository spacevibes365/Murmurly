# The agents' helper (`murmurly`) and Settings → Agents

How scripts and AI agents read the user's meetings and dictations, and how the app registers the helper with
them. Rules: `.claude/rules/agents-helper.md`, `.claude/rules/agent-connections.md`.

## What it is

`murmurly` is a separate command-line program (target `MurmurlyHelper`, bundle identifier
`io.github.spacevibes365.Murmurly.helper`), embedded in the app at `Contents/Helpers/murmurly`. Its entry point
is `Sources/Helper/`, which the app target leaves out; the read layer it shares with the app is
`Sources/Archive/`, compiled into both. It links the MCP swift-sdk (pinned in `project.yml`) and none of the
speech, update or hotkey packages, so an agent's call loads none of them.

| File | Holds |
|---|---|
| `Sources/Helper/main.swift` | argument parsing, the text and `--json` printers, the 30 s limit of a command |
| `Sources/Helper/Commands.swift` | `perform`, the access checks, the chosen folder's gate and limit, the four `runX` |
| `Sources/Helper/MCPServer.swift` | `murmurly mcp`: the stdio server and its `tools/call` handler |
| `Sources/Helper/HelperSettings.swift` | `HelperEnvironment` (roots, settings source, log, limits), `HelperSettings` |
| `Sources/Helper/AgentsLog.swift` | the helper's own log |
| `Sources/Archive/HelperContract.swift` | every response and error shape, the settings keys, ids, the MCP tool specs |

The helper only reads. The one file it writes is its log.

## Commands

```
murmurly --version
murmurly meetings   [--since D] [--until D] [--starred] [--limit N] [--json]
murmurly transcript <id> [--from N] [--count N] [--json]
murmurly search <text> [--meetings|--dictations] [--since D] [--until D] [--limit N] [--json]
murmurly dictations [--last N] [--since D] [--json]
murmurly mcp
```

| Command | MCP tool | Bounds (checked once, in `runX`) | Paging |
|---|---|---|---|
| `meetings` | `list_meetings` | `limit` 1…500, default 50 | `hasMore`, `nextUntil` → pass as `until` |
| `transcript` | `get_transcript` | `from` ≥ 1, `count` 1…1000, default 200 | `hasMore`, `nextFrom` |
| `search` | `search` | `limit` 1…100, default 20 | none: narrow and call again |
| `dictations` | `recent_dictations` | `last` 1…200, default 20 | none: narrow with `since` |

A date is `YYYY-MM-DD` (midnight in the helper's time zone) or a full ISO 8601 timestamp; `since` is inclusive,
`until` exclusive. Dates in answers are ISO 8601 with the local offset, never UTC `Z`.

Both callers build one `HelperRequest` and call `perform(_:environment:budget:)`, so the command line and an
agent never disagree. Without `--json` a command prints tab-separated lines to stdout and everything a plain
list would hide (`roots`, `unread`, `denied`, skipped history lines, "more matches") as `note:` lines on
stderr. The text output does not escape tabs or line breaks inside a dictation or a note; `--json` and MCP do.

## What each call does

`perform` reads the settings, runs the command, then measures the finished answer.

- **`meetings`** lists both roots (attempt records read without their `lines`), keeps the meetings whose start
  is inside the period, newest first. A page never ends inside one second: meetings that share a second are
  shown together even past `limit`, so `nextUntil` (exclusive) can never drop one. Each item carries `state`
  and `issues` from `metadata.json`, `metadataError`, `starred`, `readable`, the number of transcripts,
  `latestTranscript`, `lastAttempt` and `completeness`. With `--starred`, a meeting whose `murmurly.json`
  cannot be read goes to `unread` (`marksUnreadable`): a star that cannot be proven is not a missing star.
- **`transcript <id>`** finds the one folder by its id (`Archive.meeting`), without a listing, and reads the
  transcript file with the highest number. `format` is `lines` when the file parses as the app writes it
  (`n`, `start`, `timecode`, `speaker`, `text`; speakers are the user's names and the call window's where the
  attempt record still matches the file), `text` when it does not (the file line by line, header included, no
  times), `none` before a transcript exists. The notepad's notes come with every page (`notes`: `t` or null,
  `kind`, `text`, in the file's order), take at most half the size limit (`notesTruncated`, no next page) and
  are given even without a transcript; then `version` is absent and there are no lines. A meeting with
  neither is `notFound`. An unreadable `murmurly.json` is `notesError: marksUnreadable` beside the transcript,
  and a read error without one.
- **`search`** looks through the newest transcript of each meeting in the period and through the dictation
  history. A transcript is fully read only if a quick check of the raw file finds the query
  (`Archive.quickCheckApplies` says when that check is safe). Matches are counted in the lines' own words,
  never the time, the label or the header; a file not in the app's form is searched line by line. Notes and
  titles are not searched. `limit` applies to meeting hits and to dictation hits separately. Meetings fold
  case and the Russian letters yo and ye (`MeetingSearch`); dictations fold case only
  (`DictationHistoryEntry.contains`), as the window's two searches do. Without `--meetings` or
  `--dictations`, a source whose switch is off is listed in `denied` and the other is still searched.
- **`dictations`** reads `history.jsonl` backward, newest first: `id`, `at`, `duration`, `text`, `status`
  (`ok`, `interrupted`, `recognitionSkipped`, `recognitionFailed`). Audio paths are never given. Lines that do
  not decode are counted in `skippedLines`.

### Completeness

| Field | Says |
|---|---|
| `lastAttempt` | the last attempt record by number: `none`, `inProgress`, `complete`, `incomplete`, `noSpeech`, `failed`, `unreadable` |
| `completeness` in `meetings` | `complete` or `incomplete` only when that last record names the newest transcript file; `none` without a transcript; else `unknown` |
| `completeness` in `transcript` | the same, and `complete` becomes `unknown` when the file no longer matches the record's size and SHA-256 |

The list does not read transcript files, so its answer is the cheaper one; `transcript` proves it against the
file in hand.

## The contract (`HelperContract`)

**Meeting id.** `local:` or `chosen:`, then the folder's date and time with `_` for the space and without
` Meeting`: `local:2026-03-04_10-20-30`, `chosen:2026-03-04_10-20-30-2`. `parseMeetingID` only checks the form;
`Archive.meeting` then requires that exact name, byte for byte, in the root's own listing (APFS ignores case,
the listing does not). The root is part of the id, so an id changes when the queue moves the meeting to the
chosen folder. One folder reached through both roots is one meeting, the local root's.

**Errors.** `{"schema":1,"command":…,"error":{"code":…,"message":…}}`; with `--json` on stdout, otherwise the
message on stderr.

| Exit | Code | When |
|---|---|---|
| 0 | | an answer, a partial one included (see `roots`, `unread`) |
| 2 | `usage` | a bad flag or bound; a partial set of test overrides |
| 3 | `accessDenied` | the source is switched off; the period is unreadable or changed during the call |
| 4 | `notFound` | no such meeting in the period; no transcript and no notes |
| 5 | `readError` | a folder or file cannot be read, or is a link; the answer is still too large |
| 6 | `notResponding` | the call passed 30 s; the chosen folder did not answer (`transcript chosen:…`) |

**Roots and unread.** `roots.local` / `roots.chosen` are `read`, `notSet`, `unavailable`, `readError` or
`notResponding`. `unread` names what was skipped by reason: `link`, `readError`, `marksUnreadable`. A folder
that cannot be read is listed with `readable: false`.

**Size.** An answer is at most 1 MiB on the command line (`maxResponseBytes`) and 64 KiB over MCP
(`maxMCPResponseBytes`, measured as the JSON string it travels in, less 1 KiB for the envelope). `fitItems`
drops items from the end and sets `truncated`; if not even one item fits, that item's text is cut. `unread`
is never shrunk, so `perform` measures the finished answer once more and refuses one over the limit with a
read error that asks to narrow the call.

## Access

Four keys in the app's preferences domain (`HelperContract.appDomain`); the three `agents.*` ones are written
by Settings → Agents, the folder by Settings → Storage:

| Key | Type | Meaning |
|---|---|---|
| `agents.meetings` | Bool | meetings may be read; anything that is not a plain boolean is off |
| `agents.dictations` | Bool | dictations may be read; the same rule |
| `agents.periodDays` | Int ≥ 0 | 0 or absent is all history; anything else that is not a non-negative whole number refuses every call |
| `meeting.storageFolder` | String | the chosen meetings folder; empty or absent means only the local one |

The domain is synchronized and read at the start of every call, so a switch flipped in Settings is seen by the
next call of a running `murmurly mcp`. Before a successful answer is returned, `requireStillAllowed` reads the
settings again: a source this call used that is now off, or a changed period, refuses the call as if access
had been off from the start. Refusals that end a call earlier (`notFound`, a read error) are returned without
that second read.

The period is `now − periodDays × 86 400 s`, taken once at the start of the call; `--since` and `--until` only
narrow it. A meeting is placed by its start (`startedAt` in `metadata.json`, else the time in its folder's
name, read in the helper's time zone), a dictation by `at`. A linked meeting folder outside the period is
`notFound`, like any folder that is not there.

The domain name is a literal: a fork with another bundle identifier changes `HelperContract.appDomain` too.

## Links, slow folders and time limits

- Every read uses `Archive.Links.refuse`: files are opened with `O_NOFOLLOW`, and a meeting folder that is
  itself a link is never opened (`unread`, reason `link`). A root that is itself a link (the local root, the
  chosen folder, `Dictations/`) is read through its target; the refusal is about meeting folders and files.
- A whole command is cut at 30 s (`withTimeout`; in MCP `withAsyncTimeout`, which also ends on cancellation).
  The worker thread is left running; the command-line process exits right after.
- The local root is read without a limit of its own.
- The chosen folder's listing, and the lookup of one meeting in it, run in `readChosenRoot`: 5 s, the
  availability check (`MeetingStorage.isAvailable`) included. Past it, `roots.chosen` is `notResponding` and
  the local meetings are still in the answer.
- `ChosenRootGate` lets one such read run per process. Until it ends, whether it is hung or merely still
  running, any other call made meanwhile answers `notResponding` for the chosen folder at once instead of
  starting a second read.
- Transcript, attempt-record and call-feed files of a meeting in the chosen folder are read after the listing,
  outside the 5 s and the gate, under the 30 s limit only.

## MCP (`murmurly mcp`)

A stdio server named `murmurly`: stdout carries only the protocol, diagnostics go to stderr, and it ends with
code 0 when stdin closes. `tools/list` gives the four `HelperContract.Tools` specs, each marked read-only and
idempotent. The SDK does not check arguments against the schema, so the server does: wrong types and unknown
keys are `usage` errors, and a number that is not a whole `Int` is refused rather than converted.

A successful `tools/call` returns two text blocks: `Tools.untrustedNotice`, then the JSON answer. A refusal
returns one block, the error JSON, with `isError`; it carries no archive text. A cancelled call returns
nothing. The notice is also the server's `instructions` and the end of every tool description, and `--json`
adds it as a `notice` field.

## The log

`~/Library/Logs/Murmurly/agents.log`, mode 0600 in a 0700 folder: one line per call, `<time> <command>
<fields>`. The command is `meetings`, or `mcp.list_meetings`, or `mcp.unknown` for a tool name the server does
not know. The fields are counts, a meeting id, `sources=` and `refused=<code>`; never the query, a title, text
or a path. Writers take `agents.log.lock` (`flock`), as several helpers may run at once. Lines older than 30
days are dropped at the next write. A cancelled MCP call and a call with a partial set of test overrides are
not logged; a log that cannot be opened does not fail the call. The app does not read this file.

## Connecting clients (Settings → Agents)

`AgentsSettingsView` holds the two switches, the period (All history, 30, 90, 365 days; a stored value outside
that list shows nothing chosen) and Connect. `AgentConnections` is a `@StateObject` of the tab; quit and
updates do not wait for a connection under way.

**Claude Code and Codex.** `AgentLocator` looks for `claude` / `codex` in the usual install places (home-relative
ones, Homebrew, `/usr/local/bin`, npm, bun, volta, nvm newest first), then in the process's own `PATH`. The
client runs with its own folder first in `PATH`, then that folder's resolved target, then the usual places;
the working directory is the home folder. Three steps, each a `Process` with an argument array:

| Step | Claude Code | Codex | Limit |
|---|---|---|---|
| remove | `mcp remove --scope user murmurly` | `mcp remove murmurly` | 30 s; the exit code is not read |
| add | `mcp add --scope user murmurly -- <helper> mcp` | `mcp add murmurly -- <helper> mcp` | 30 s |
| check | `mcp get murmurly`: the output contains the helper's path | `mcp get murmurly --json`: some string in it equals the path | 60 s |

On success the path is saved (`agents.claudeCode.helperPath`, `agents.codex.helperPath`). At the next opening
the status comes from that saved value alone: equal to this copy's helper is "Connected", another path is "Out
of date", none is "Not connected". A failed or timed-out `add` clears it. A failure shows the last non-empty
line of the client's stderr. A client that was not found offers "Copy Command", the same remove-then-add as one
shell line with the path single-quoted.

Only a copy at `~/Applications/<name>.app` or `/Applications/<name>.app` connects; any other shows why and
keeps the buttons off, as does a bundle without an executable helper.

**Command in Terminal.** `/usr/local/bin/murmurly` is a symbolic link to the running copy's helper.
`TerminalCommandInstaller.linkStatus` reads the address with `lstat`:

| Status | Address holds | Install |
|---|---|---|
| `notInstalled` | nothing | offered |
| `installed` | a link to this copy's helper | nothing to do, no password asked |
| `outdated` | a link ending in `.app/Contents/Helpers/murmurly` elsewhere | offered ("update") |
| `foreign` | any other link, a file, a folder | refused, no command offered |
| `unreadable` | cannot be told | refused, no command offered |

Installing runs `/usr/bin/osascript` (300 s) with three fixed `-e` lines and four arguments. Its privileged
shell line makes the folder, exits with 17 if the address holds something that is not a symbolic link, and
otherwise runs `/bin/ln -sfh`; a link found there at that moment is replaced. `(-128)` in the output is a
cancelled prompt, which offers "Copy Command" (a `sudo` line with the same not-a-link check). After every
outcome the address is read again, and it is read when the tab is chosen and when the app becomes active.

In a test process `AgentConnections.live()` finds no client, runs nothing and keeps its link inside the
isolated root.

## Why it is this way

- **`Contents/Helpers`, not `Contents/MacOS`.** On a case-insensitive volume `murmurly` and the app's own
  `Murmurly` would be one name.
- **The switches are consent, not a lock.** Any program running under the same account can read the files
  directly, and whoever sets the helper's environment is such a program. For the same reason a meeting folder
  swapped for a link between its check and its read is not guarded against.
- **A second settings read at the end.** A long call must not hand over text the owner switched off while it
  was being gathered; a period changed meanwhile is refused rather than silently re-applied to an answer built
  for the old one.
- **One read of the chosen folder at a time.** A timeout only stops waiting, not the blocked thread; without
  the gate every call to a hung network volume would leave one more thread behind.
- **64 KiB over MCP.** An agent's context is far smaller than a megabyte, and a client may cut a tool result
  before the model sees it; pages keep that from happening silently.
- **The helper's own log.** The app's `AppLog` writes with a bare seek and write, safe for one process;
  several helpers can run at once.
- **A GUI app's `PATH` is short**, hence the search in install places; an npm-installed client is a `node`
  script that needs `node` beside it, hence the client's folder first in the child's `PATH`.
- **Speed.** A listing skips the records' `lines`, `transcript` skips the listing, and a search parses only
  files that contain the query.
