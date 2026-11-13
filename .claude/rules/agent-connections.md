---
paths:
  - "Sources/Settings/AgentConnections.swift"
  - "Sources/Settings/AgentsSettingsView.swift"
  - "Tests/MurmurlyTests/AgentConnectionTests.swift"
---

# Settings → Agents, connecting clients

Feature layer. The tab that grants agents access and registers the `murmurly` helper with Claude Code, Codex
and Terminal. It is the only code in the app that starts other programs and asks for an administrator.

- **No shell.** A client runs as `Process` with an executable URL and an argument array (`ProcessRunner`,
  the one place `Process()` is created). A path with a quote or `$()` in it must stay one argument.
- **Paths never enter script text.** The single shell use is `do shell script` inside osascript; the helper,
  the link, its folder and the prompt are `argv` items joined with `quoted form of`
  (`TerminalCommandInstaller.arguments`). The privileged line calls `/bin/mkdir` and `/bin/ln` by absolute
  path.
- **Only an installed copy connects** (`isInstalledCopy`, the list of
  `LoginItemManager.defaultInstalledBundlePaths`): a path into a build folder or a mounted image would
  vanish under the client.
- **The path handed out is the running copy's `Contents/Helpers/murmurly`**, and it is saved
  (`agents.claudeCode.helperPath`, `agents.codex.helperPath`) only after `mcp get` named it. "Connected"
  means that saved path equals this copy's helper; the client is not asked again.
- **Remove, add, verify, in that order**: both clients refuse `add` on a taken name. Once `remove` has run,
  an `add` that fails or times out clears the saved path, as the earlier registration may be gone.
- **`/usr/local/bin/murmurly` is replaced only when it is nothing or this app's own link.** A `.foreign`
  or `.unreadable` address is left alone and gets no "Copy Command"; the privileged script itself exits
  with `foreignFileExitCode` on anything there that is not a symbolic link, so a file that appears while
  the password prompt is up survives.
- **Trust the disk, not the outcome.** After any install attempt the address is read again with
  `linkStatus` (`lstat`, so a dangling link to a removed copy is still ours).
- **Views build the model with `AgentConnections.live()`.** In a test process it finds no client, runs
  nothing, installs nothing and leaves the clipboard alone; passing `ProcessRunner.live` by hand would
  skip that.
- **The access keys are the helper's.** `agents.meetings`, `agents.dictations` and `agents.periodDays`
  come from `HelperContract.SettingsKey`, and the period is read through
  `HelperContract.periodDays(fromStored:)`, so the tab and the helper mean the same value.

How it works: `reference/agents-helper.md` (Connecting clients).
