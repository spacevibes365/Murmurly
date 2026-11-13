---
paths:
  - "Tests/**"
  - "Sources/TestIsolation.swift"
  - "Sources/*Probe.swift"
  - "Sources/SystemAudioCheckSeed.swift"
---

# Tests and test isolation

Cross-cutting. Unit tests run inside a Debug copy of the app itself; every UI test launches another copy.
Both run on a machine with someone's real archive, shortcuts and clipboard on it.

- **A test process must not act on the user's machine.** `TestIsolation` moves the settings, both archives
  and the log to a temporary root and keeps global shortcuts, event monitors and the Core Audio process
  list off. New code that reaches a shared resource asks `TestIsolation` or takes a seam; it never assumes
  "tests won't get here".
- **Constructor defaults are the real thing.** The microphone, the clipboard and ⌘V, sounds, the system
  tap, the models folder and Finder are closed only by what the test passes in (`deliveryOverride`,
  `feedbackPlayer`, `beepPlayer`, a `MicCapturing` fake, `ModelDownloader(root:)`). A coordinator or
  recorder built with defaults and driven to the end types into the app in front.
- **A seam is a parameter with a `.live` default**, decided by a pure function of `testProcess:` and the
  arguments (`Deck.live`, `Removal.backend`, `FilesModel.panelBackend`, `AgentConnections.live()`), not a
  new `#if DEBUG` branch in the middle of shipped logic. A probe (`Sources/*Probe.swift`) holds no product
  logic: it only stands in for the outside world.
- **Never write the app's own preferences domain from a test.** KeyboardShortcuts reads only
  `UserDefaults.standard`, the live domain for the unit-test host: set a shortcut only in the volatile
  argument domain (`IndicatorTests.withMeetingShortcut`). Give `SettingsStore` a suite of its own and
  remove it afterwards.
- **A UI test passes `-UITestSettingsStore`** (isolated whatever the environment says), finds elements by
  `accessibilityIdentifier`, and does not press Download, Grant…, Check… or Show in Finder: those are real.
- **Read `Executed N tests`, not the exit code.** A wrong `-only-testing` path exits 0 with
  `Executed 0 tests`; a file name is not a class name.
- **A fix comes with a test that fails without it.** Run it against the code with the defect once. If no
  test can show the defect, say so and describe the check by hand.
- **Every wait has a deadline and a way out.** Poll a condition up to a limit and cancel what you started;
  awaiting a `Task.value` that may never finish hangs the whole run. "Sleep, then assert nothing happened"
  proves little.
- **A failure is not a skip.** `XCTSkip` is for a machine that cannot run the check (keyboard layout, no
  Russian language data, missing fixture), with the reason in its text.
- **Tests run in English.** Both schemes pass `-AppleLanguages (en)` and `-AppleLocale en_US`; a UI test
  takes its launch language from `AppLanguage` and never compares with a hard-coded translated string.
- **Test at the seams** where two parts meet (settings → coordinator, recorder → watchdog, tab → helper),
  not only inside the part just written.
- **Traps.** `typeKey`/`typeText` go through the active keyboard layout, so shortcut tests skip themselves
  on a non-Latin one: after touching scenes or commands, run the UI tests once on a Latin layout. Tests of
  Russian word forms skip without macOS's Russian data (`MacOSRussianWordForms`). `Timed out while
  enabling automation mode` with no `Executed` line is a hung `testmanagerd`: `kill -9` it.
- **The stage gate is another scheme and another `-derivedDataPath`.** The `Murmurly` scheme does not
  compile `MurmurlyStageGateTests`; after touching what the gate uses, run its `build-for-testing`.

Probes, launch arguments and what is isolated: `reference/test-isolation.md`.
