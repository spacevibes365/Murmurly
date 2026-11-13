---
paths:
  - "Sources/Overlay/Notepad*.swift"
  - "Sources/Overlay/LiveLinesView.swift"
  - "Sources/Overlay/NotesInputView.swift"
  - "Tests/**/Notepad*Tests.swift"
  - "Tests/**/NotesInput*Tests.swift"
  - "Tests/**/LiveTranscriptPanel*Tests.swift"
  - "Tests/MurmurlyTests/LiveLinesViewTests.swift"
---

# Meeting notepad

Feature layer. The window with the live transcript and the user's notes during a meeting, kept on that
meeting after the stop. `LiveTranscriptPanel` owns the window, `NotepadModel` holds what it shows.

- **Never a real window.** `NotepadNSWindow` is an `NSPanel` that cannot become main; if it counted for
  `AppWindowController.isRealWindow` the app would keep a Dock icon for the whole recording.
- **A click activates as on any app's window; showing by itself does not.** No `.nonactivatingPanel`, no
  `becomesKeyOnlyIfNeeded`, no raise of our own on mouse-down. Appearing, or a new meeting, is
  `orderFrontRegardless` without `NSApp.activate()`, so the call stays in front.
- **No menu sends its keys.** The app stays `.accessory`, so the window maps the editing keys and Command-W
  itself, and the search's keys come from a local monitor bound to this window while it is key: a menu item or
  `.keyboardShortcut` for Find would race the main window's, which belongs to `TranscriptNSTextView`.
- **No stored flag shows it.** `render()` computes visibility from the values its sinks were handed (never
  read off the recorder inside a sink: `@Published` sends in `willSet`), the setting and the in-memory
  `closedByUser`. Only the frame and the pin are kept in settings.
- **A new meeting is a new folder** (`MeetingKey`), never the same folder going from live to stopped: only a
  new one resets the notes, the search and the user's close. `MeetingRecorder.beginStop` fills
  `stoppedLiveTranscript` before `.stopping`, so the lines outlive the live model.
- **The notepad keeps the meeting's own folder and identity after the queue moves it.** Notes go to the marks
  writer with those (it follows the move); only showing and opening go through `queue.location(of:)`.
- **Notes are written only through `MeetingLibrary`** (`addNote`, `editNote`, `deleteNote`): one writer per
  folder. A note goes to `NotepadModel.meeting`; a moment goes to `recorder.currentSession`, whatever the
  notepad shows.
- **No second write for a note while one is pending** (`pendingNoteIDs`): edit and delete refuse without
  calling the library, and a written note's row goes only once the library settled its delete without failure.
- **A note's time is read at its first character,** only while the notepad is on the recording; a new meeting
  (`meetingGeneration`) drops the draft, so a note never takes another recording's time or folder.
- **A feed line's text view gets values and does nothing when they are equal;** while the mouse drags a
  selection in it, updates wait for the mouse-up, and its own changes are fenced by `isApplyingUpdate`.
- **`ScrollFollowReducer` alone reads the scroll's frames for following the bottom;** every scroll the feed starts opens a
  `ScrollFollowGeneration` first, or its landing frame is read as the user's scroll.
- **The Mark Moment shortcut is registered only while `.recording`,** never in an isolated test process: a
  registered shortcut is taken from every app.

How it works: `reference/notepad.md`.
