# Murmurly 0.4

This release lets AI agents such as Claude Code read your meeting
transcripts and dictations, when you allow it: ask an agent what was decided
in yesterday's call, or find something you dictated last week.

## What's new

- **Settings → Agents.** Two switches, **Meetings** (transcripts and meeting
  titles) and **Dictations** (dictation text, without audio), and a
  **Period**: all history or the last 30, 90 or 365 days. Both switches are
  off until you turn them on.
- **Connect an agent.** One click adds Murmurly to the settings of Claude Code
  or another supported agent; start a new session of the agent afterwards. If
  the program is not found, **Copy Command** gives you the command to run
  yourself. If you move Murmurly, the row says the connection is out of date
  and offers to update it.
- **A `murmurly` command in Terminal.** **Install Command in Terminal** asks
  for an administrator password once; then `murmurly meetings`,
  `murmurly transcript`, `murmurly search` and `murmurly dictations` work in
  any new terminal window, with `--json` for scripts.
- **Read-only, in portions.** Agents can only read, never change anything, and
  get answers in portions (50 meetings, 200 transcript lines, 20 search results
  from each source at a time) so their memory is not flooded. Every request is logged, without its
  text, to `~/Library/Logs/Murmurly/agents.log`.
- The interface of the new tab is translated into all 12 languages.

## Fixed

- The Murmurly window and **Settings → Storage** now show the meetings in a
  chosen meetings folder that is a symbolic link to another folder.

## Known limitations

- An agent you allow sends what it reads to its own cloud model, under that
  company's terms. Murmurly itself sends nothing.
- The switches are your consent, not a lock: any program running under your
  account can read Murmurly's files directly.
- Connecting works only for a copy of Murmurly in the Applications folder.
- A search, or the list of dictations, has no next portion: narrow it by date.

## Requirements

- A Mac with Apple silicon.
- macOS 15 Sequoia or later.

Known limitations are listed in the
[README](https://github.com/spacevibes365/Murmurly#known-limitations).
