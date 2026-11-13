---
paths:
  - "Sources/MurmurlyApp.swift"
  - "Sources/MenuBar/*.swift"
  - "Sources/AppLifecycle.swift"
  - "Sources/Logging.swift"
  - "Sources/Overlay/RecordingIndicator.swift"
  - "Sources/Overlay/IndicatorView.swift"
  - "Sources/Overlay/OverlayPlacement.swift"
  - "Tests/MurmurlyTests/AppWindowControllerTests.swift"
  - "Tests/MurmurlyTests/IndicatorTests.swift"
---

# App shell

Shell layer. `MurmurlyApp` builds the app's objects, `MenuBarLabel` starts them, the menu and
`AppWindowController` open the two windows, `RecordingIndicator` shows what a recording is doing.

- **Services start from `MenuBarLabel`'s `.task`, never from a window.** Dictation, the watchdog and the
  queue's launch scan live with every window closed. The same task wires quit (`AppDelegate.attach`,
  `fileLosses`, `meetingLosses`, `showMainWindow`): until it has run, quit answers `.terminateNow`, so
  whatever creates work stays behind it. `followAppearance(of:)` is its first call: Getting Started may open
  later in the same task.
- **Both `Window` scenes keep `.defaultLaunchBehavior(.suppressed)` and `.restorationBehavior(.disabled)`.** A
  launch at login must stay in the menu bar; the stage gate's cold launch checks it.
- **A panel is never a real window, and the indicator's never becomes key.** `AppWindowController.isRealWindow`
  leaves out every `NSPanel`: counted, the indicator would keep the Dock icon for a whole dictation. A key
  indicator (`NonKeyPanel` forbids it) would swallow the synthetic ⌘V, which goes to the key window.
- **Every `enterRegular()` is answered by `windowDidClose()` on every path.** The activation policy is kept by
  these paired calls, not derived from the windows; a path that skips the second leaves a Dock icon with no
  window. Sparkle's windows are not ours, so `AppUpdater` makes the call when its session ends.
- **Never `runModal`, never a nested modal run loop:** one hung quit, another the Files section.
  `chooseFolder` uses `begin`, and a test process opens no panel whatever it was told.
- **With the indicator off only failures and conflict flashes show** (`RecordingIndicator.visibleState`:
  `visualKind == .failure` or `isConflictFlash`). A message that must survive the switch has to be one of
  them; anything else is hidden without a word.
- **Durable states go through `setBase`, terminal ones through `finish` or `showFlash`.** A state without
  `autoHide` given to `showFlash` trips an assertion and is not shown.
- **"Settings…" stays the menu's third item from the end.** `MenuBarExtra` drops accessibility identifiers, so
  the UI tests find the item by that position.
- **Log lines hold paths, file names and counts, never dictated or spoken words.** The same text goes to the
  unified log as `privacy: .public`.

How it works: `reference/app-shell.md`. Quit and updates: `.claude/rules/quit-update.md`.
