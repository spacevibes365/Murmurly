---
paths:
  - "Sources/AppLifecycle.swift"
  - "Sources/AppUpdater.swift"
  - "Tests/MurmurlyTests/GracefulQuitTests.swift"
  - "Tests/MurmurlyTests/AppUpdaterTests.swift"
  - "Tests/MurmurlyUITests/QuitProbeTests.swift"
---

# Quit and updates

Shell layer. Every quit path ends in `AppDelegate.applicationShouldTerminate`; `AppUpdater` is the only code
that talks to Sparkle and decides whether a relaunch may happen now.

- **Never `.terminateLater`.** AppKit would wait in a nested modal run loop inside `terminate`; called from a
  main-queue block (a main-actor task, the SIGTERM source) that loop cannot drain the main queue, and quit
  hangs forever.
- **Quit with unfinished work runs in two phases.** The first request gets `.terminateCancel`, the work ends
  in the normal event loop, and the app calls `NSApp.terminate` again only after a confirmed save
  (`terminationConfirmed`). At the deadline quit is refused, never forced, and the deadline's task does not
  join the work: a start or stop stuck in Core Audio must not hold the answer.
- **Quit never waits for a model.** A dictation's recognition is cancelled and its raw CAF is saved
  (`recognition_skipped`); only a save or a paste already begun is waited for.
- **Nothing starts after quit is accepted.** Whatever can begin work checks `isTerminating`; a quit-time claim
  (`claimForTermination`) is made in the same main-actor turn, before the termination task exists.
- **Never drop `pendingSaves` or `unconfirmedRecording` to let a quit through.** They block the next quit on
  purpose; the user's way out is "Remove" and "Allow Quitting Without Confirmation" in the menu.
- **Only a person's quit warns.** `route(quitReason:signalled:)` sends logout, restart, shutdown and SIGTERM
  past the warning: they log the loss and go on. Sparkle's quit carries no reason and is a person's quit.
- **Work that nothing redoes must be named to both sides.** For quit: a `QuitLoss` (through `quitLosses()`,
  `FilesModel.quitLosses` or `MeetingLibrary.quitLosses`) or `hasUnfinishedWork`. For updates:
  `AppUpdater.busy`. One without the other lets an update, or a quit, cut the work short.
- **`busy` reads the `@Published` streams, never the objects.** `@Published` sends the new value before the
  property changes, so a read of the object inside the sink is the old state.
- **Work that never ends by itself stays out of `busy`.** It would hold the update until the user acts;
  Files' unsaved text is left to the quit warning for that reason.
- **Refuse the relaunch, never postpone it.** `updaterShouldRelaunchApplication` returns `relaunchNow()`;
  postponing leaves Sparkle's "Ready to Install" window on screen, unclosable, for the whole call.
- **Sparkle is started by `AppUpdater`, not by its controller** (`startingUpdater: false`): the controller
  would show a failure through a modal alert. No test process and no build without `SUPublicEDKey` creates it.

What each kind of work gets from quit and from an update: `reference/quit-and-update.md`.
