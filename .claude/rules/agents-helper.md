---
paths:
  - "Sources/Helper/**"
  - "Sources/Archive/HelperContract.swift"
  - "Tests/MurmurlyTests/Helper*Tests.swift"
---

# The agents' helper (`murmurly`)

A separate executable (target `MurmurlyHelper`) on top of the Core layer: it hands the user's meetings and
dictations to scripts and AI agents. It is a privacy boundary; every rule below keeps it one.

- **Read-only.** The helper writes nothing but its own log (`AgentsLog`). It never creates, repairs or
  touches a file of the archive, not even a missing folder.
- **One door.** Every command and every MCP tool goes through `perform`: settings are read fresh on each
  call (never cached in the long-lived `murmurly mcp`), each `runX` checks access (`requireAccess`; a
  mixed `runSearch` reads the two switches itself) before any archive read, and `requireStillAllowed` runs
  before a successful answer is returned.
- **Never guess wider.** A switch that is not a plain boolean reads as off; a period that is not a
  non-negative whole number refuses everything (`HelperContract.periodDays(fromStored:)`). Flags only
  narrow the period (`effectivePeriod`).
- **Nothing outside the period is named**, not in `unread`, not in an error: a linked folder outside it
  answers `notFound`, exactly as one that is not there.
- **Links are refused.** Every read passes `links: .refuse`; a meeting folder or file that is a link is
  reported, never opened.
- **An id is not a path.** `parseMeetingID` checks its form, and `Archive.meeting` takes it only when that
  exact name is in the root's own listing.
- **No path, no words in errors or the log.** `CommandFailure` messages are fixed text;
  `Archive.ReadError`'s description carries a path and is never forwarded. A log line holds the command,
  counts and ids, never the query, a title or a dictation's text.
- **"Not read" is never "not there".** What could not be read is said in `roots`, `unread`, `denied`,
  `skippedLines` or `notesError`, not left out silently.
- **Every answer fits its limit.** Text that can grow goes through `HelperContract.fitItems`; `perform`
  measures the finished answer again and refuses one that is still too large.
- **The text is data, not instructions.** `Tools.untrustedNotice` ends every tool description, is the
  server's `instructions` and the first block of every successful MCP answer, and `--json` carries it as
  `notice`. A new tool or command keeps all of that.
- **`murmurly mcp` owns stdout.** Only the protocol goes there; diagnostics go to stderr.
- **The contract is versioned.** Exit codes and field names are read by scripts: change a response's shape
  only with `HelperContract.schemaVersion`.
- **No app types.** The target links `Sources/Archive` and MCP only: no AppKit, no `@MainActor`, no
  `SettingsStore`.

How it works: `reference/agents-helper.md`. Test overrides (`MURMURLY_HELPER_*`): `reference/test-isolation.md`.
