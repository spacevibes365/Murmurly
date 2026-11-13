---
paths:
  - "Sources/Dictation/HotkeyManager.swift"
  - "Sources/Dictation/HotkeyActivation.swift"
  - "Tests/MurmurlyTests/Hotkey*Tests.swift"
  - "Tests/MurmurlyTests/HoldToTalkTests.swift"
  - "Tests/MurmurlyTests/EscapeCancelTests.swift"
---

# Hotkeys

Services layer. `HotkeyManager` holds the shortcut names, the dictation activation (press, hold, double-press of a
modifier) and the Esc and mark-moment listeners; `HotkeyActivation.swift` holds the double-press reducer.

- **A test copy takes no shortcut.** `installsSystemHandlers` and the static registrations follow
  `TestIsolation.isEnabled`, and every `KeyboardShortcuts.Name` declares `initial: nil` there: the library writes an
  initial shortcut into `UserDefaults.standard` the first time a name is touched.
- **Never rename a name's string** (`"dictate"`, `"meeting"`, …): it is the `UserDefaults` key of the user's shortcut.
- **Remove before registering.** `apply` calls `tearDownDictationRegistration()` first: KeyboardShortcuts appends
  handlers, and a second `onKeyDown(for: .dictate)` would fire twice per press.
- **Handlers by name are one static registry.** A `HotkeyManager` that is released removes the `.dictate` handler for
  the whole process, whoever installed it; the app's two instances live until quit.
- **A registered Esc is taken from every app.** `listenForEscape` opens exactly the set it is given and closes the
  rest; the caller passes the empty set the moment Esc can change nothing.
- **A listener is its task.** Cancelling the task that iterates the stream is what unregisters the hotkey, on the next
  main-actor turn; keep no separate "listening" flag that could drift from the handle.
- **Compare key codes, never characters**: layouts change characters, and left and right ⌘ share one flag.
- **Double-press counts only complete, unmodified taps.** A key, a mouse button or live scrolling with the modifier
  down makes a chord; scroll momentum is ignored; the reducer is reset when dictation becomes idle and while a
  shortcut recorder is active.
- **Two private details of KeyboardShortcuts 3.0.1 are relied on:** the notification
  `KeyboardShortcuts_recorderActiveStatusDidChange`, and `RecorderCocoa` being a field whose editor is the first
  responder. Check both by hand when the pin in `project.yml` changes: only the second has a test
  (`testRecorderActivityUsesFieldEditorInsteadOfStoredFlag`), and no test fails on the notification's name.
- **No trust check and no prompt here.** The manager never reads Accessibility, and the dictation shortcut stays
  registered in every activation as the way in when the monitors get nothing.

How it works: `reference/dictation.md` (Activation, Esc).
