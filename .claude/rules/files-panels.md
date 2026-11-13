---
paths:
  - "Sources/ContentView.swift"
  - "Sources/FileProbe.swift"
  - "Tests/MurmurlyUITests/FileSelectionProbeTests.swift"
  - "Tests/MurmurlyTests/AppWindowControllerTests.swift"
---

# Files section and the app's panels

Feature layer (`FilesModel`, the view `ContentView`) with a shared service inside it: the open and save panels.

- **The run's state lives in `FilesModel`, owned by the app.** The view keeps none of it, so closing the window
  neither stops a run nor loses its text. One run at a time; only the Cancel button stops it.
- **Never drop unsaved text unasked.** `hasUnsavedText` is the one definition for the note, the replace question and
  the quit warning; copying is not saving. A new file or run over it only sets `pendingReplacement`.
- **An answer counts only for what it was given for.** `replace(with:)` acts only on the revision the user was asked
  about, "Save .md…" replaces only after the write succeeded, and a save vouches only for the revision it was taken
  from. A drop answered after a newer selection or a started run touches nothing (`selectionToken`).
- **A run that cannot start drops nothing.** The model check (`readyTranscription`) comes before the question and
  again before the shown text is cleared; its reason goes over the text.
- **The choice is the run's own from `start()`.** `FilesModel.choice` is in memory only and never written to the
  settings; the run carries it through the question and the save panel (`Replacement.Action.rerun`).
- **A result that arrived before the cancel is kept**; the user's cancel is a `CancellationError`, never a kept
  partial result. `fileCutShort` and `incompleteFile` keep their lines under a note, as unsaved text.
- **Nothing is created or deleted next to the user's file**: the folder is theirs; work files go to a temporary one.
- **After a run with a choice, hand the engine back** (`returnDictationEngine`), whatever its end, once the result
  is shown: the run may have left its own engine in the cache.
- **Only `isTranscribing` holds an update** (`AppUpdater.busy`). Unsaved text never ends by itself; it is a quit
  loss (`quitLosses`) instead.
- **No keyboard shortcuts in the section's view**: it stays mounted, hidden, under other sections and would fire.
- **Every open and save panel of a window goes through `FilesModel.present(_:on:as:)`**: a sheet on the window read
  at the click (`WindowAnchor.window`, before anything waits), never the key window. An owner gone by then cancels
  the choice, with no panel anywhere.
- **Never `runModal`.** A nested modal loop hung quit and this section. The folder panel without a window
  (`AppWindowController.chooseFolder`) uses `begin`.
- **A test process never opens a panel, whatever it was told.** The rule is chosen inside (`panelBackend`,
  `folderPanels`); callers hand in only AppKit's last call (`sheet`, `begin`).

How it works: `reference/files.md`.
