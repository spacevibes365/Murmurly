# The meeting notepad

The window that shows the live transcript and the user's notes while a meeting is recorded, and stays on that
meeting after the stop. The rules that must not be broken are in `.claude/rules/notepad.md`. The live text
itself (audio ring, VAD, engine, the 5000-line limit) is in `reference/live-transcript-and-call-window.md`;
the `notes` format in `murmurly.json` and its writer are in `reference/marks-and-notes.md`.

| Part | Type | File (`Sources/Overlay/`) |
|---|---|---|
| The window and what it follows | `LiveTranscriptPanel`, `NotepadNSWindow` | `NotepadWindow.swift` |
| Header controls, a line's time | `NotepadStatusView`, `NotepadWindowControls`, `NotepadTimeButton` | `NotepadWindow.swift` |
| State of one notepad | `NotepadModel`, `NotepadMeeting`, `NotepadFeedItem` | `NotepadModel.swift` |
| Root view and its slots | `LiveTranscriptContentView` | `NotepadView.swift` |
| The feed, following the bottom, a line's text, Copy | `LiveLinesView`, `ScrollFollowReducer`, `LiveLineTextView`, `CopyLiveTextButton` | `LiveLinesView.swift` |
| Search | `NotepadSearchBar`, `NotepadSearchMonitor` | `NotepadSearchBar.swift` |
| Notes, moments, the shortcut | `NotepadNotes`, `NoteDraftController`, `MarkMomentHotkey`, `NoteRow` | `NotesInputView.swift` |

The types are named after both of the window's lives: `LiveTranscript*` for the panel it began as and
`Notepad*` for what it became. The settings keys keep the old prefix (`liveTranscript.panelFrame`,
`liveTranscript.keepOnTop`); `meeting.liveTranscript` turns the feature on.

## Who owns what

`MurmurlyApp` makes one `LiveTranscriptPanel` and, with `NotepadNotes.attach`, ties its `NotepadModel` to the
recorder and the library for the app's lifetime. The panel follows the recorder: `liveTranscriptModel`,
`state`, `currentSession` and `stoppedLiveTranscript` arrive combined in one sink, which keeps the latest of
each and calls `render()`. The library reaches the views through `MeetingRecorder.notepadLinks` (a weak
reference set by the menu bar label before `activate`) and the optional environment value `\.notepadLibrary`;
without it "Open in Murmurly" and a click on a time do nothing.

`NotepadModel` holds what the window shows: `meeting` (folder, identity, start, recording or not), `liveModel`
while recording, `keptLines` after the stop, `notes` with `pendingNoteIDs` and `noteFailures`, the line
selection, the search, and `isFollowingBottom`.

## What `render()` decides

| Recorder | Shown | `NotepadModel` |
|---|---|---|
| a live model and `state == .recording` | the recording | `liveModel` set, `meeting.isRecording == true` |
| otherwise, a `stoppedLiveTranscript` | the last meeting with live text | `liveModel` nil, `keptLines` and `meeting` from the snapshot |
| neither | nothing: `isShown` and `canReopen` false | unchanged |

The meeting is keyed by its folder's path (`MeetingKey`). A different key is a new meeting: `closedByUser` is
cleared and `resetForMeeting()` drops the kept lines, notes, selection, search and moment anchors, turns
following on and raises `meetingGeneration`. The same folder going from live to stopped is not a new meeting.

The window is on screen when the setting is on and the user has not closed it. `canReopen` (the menu's "Show
Live Transcript") is true whenever there is a meeting to show and the setting is on, hidden or merely covered.
Turning the setting off mid-recording hides the window at once; turning it on cannot make a recording that
started without a model grow one.

## The window

`NotepadNSWindow` is a titled, resizable `NSPanel` with a hidden title bar and buttons, at the normal level,
`hidesOnDeactivate` off, never main. It is dragged by a `WindowDragGesture` on its background layer.

| What happens | Activation | Ordering |
|---|---|---|
| It appears, or a new meeting begins while it is visible | none: the app in front stays in front | `orderFrontRegardless` |
| A click anywhere on it | macOS activates Murmurly | front and key, as any window; buttons and lines take the first click (`acceptsFirstMouse`) |
| "Show Live Transcript" in the menu (`show()`) | `NSApp.activate()` | `orderFrontRegardless`, `makeKey`; also undoes the user's close |
| "Edit Note" from the context menu (`requestKeyboard`) | `NSApp.activate()` | `orderFrontRegardless`, `makeKey`: a secondary click does not activate the app |
| Murmurly becomes active (`raiseOnActivation`) | already active | `orderFrontRegardless`, only if no modal window is up and no other window of the app below the status-bar level is visible; logged as `raised on activation` |

After a click on the notepad Murmurly is the front app, so a dictation started then has no paste target.

Keys: the window answers Command-X, C, V, A, Z, Shift-Command-Z and Command-W in `performKeyEquivalent`,
matching ANSI key codes and not the layout's characters, and sends the action to its first responder.
The close button and Command-W both reach `LiveTranscriptPanel.close()`: during a recording it hides the
window until the recording ends and does not bring it back at the stop; after the stop it closes it. The flag
is memory only.

Frame: at least 320 x 160, 380 x 240 by default. A move or resize made with the mouse is saved to
`liveTranscript.panelFrame` 180 ms after it stops; other frame changes are not saved. On showing, the stored
frame is fitted to the attached screens (`OverlayGeometry.fittedFrame`). The pin (`liveTranscript.keepOnTop`,
off by default) makes the window `.floating`, on every Space and over full-screen apps
(`.canJoinAllSpaces`, `.fullScreenAuxiliary`); unpinned it is `.normal` with `.fullScreenNone`.

## After the stop

`MeetingRecorder.beginStop` copies the live model's lines, the session's folder, identity and start into
`stoppedLiveTranscript` before the state leaves `.recording`, then updates its `outcome` (`saving`, `saved`
with or without a warning, `failed`). The 4-hour limit's stop and a failed stop take the same path. The
snapshot is replaced only by the next stop with live text.

The status label shows the live model's state while recording; afterwards the outcome, and for a saved
meeting the queue's step or "Waiting to be transcribed" when the queue's active or pending work is on this
meeting's present address. The controls show Stop (`MeetingRecorder.toggle()`) while recording and "Open in
Murmurly" after (`MeetingLibrary.open` at `queue.location(of:)`, then the main window). A line's or a note's
time (`NotepadTimeButton`) is a button once the notepad's meeting is not being recorded and the recorder is
not busy: it calls `MeetingLibrary.openAndPlay` at that second and shows a refusal in a popover.

## The feed

`LiveLinesView` is a `LazyVStack` of `NotepadFeedItem.merge`: the lines in the live model's order (an
unfinished line after every finished one), each note slotted in before the first line that starts after its
`t`, untimed notes last. The lines are the live model's while it exists, else `keptLines`. When the model has
dropped lines past its limit the feed opens with "Earlier lines are in the transcript after the meeting".

A line is its time button, a star per moment drawn on it, and `LiveLineTextView`: a read-only, selectable
TextKit 1 `NSTextView` with the speaker in bold, reported to accessibility as the static text
`liveTranscriptLine`. Each line has a text view of its own, so a selection never spans two lines. The view
paints its selection as a temporary layout attribute in the ordinary selection colour, key or not. Its
delegate writes `NotepadModel.lineSelection` (line id, the line's start, the range without the speaker's name,
the trimmed words) as the selection changes and clears it when the selection empties.

Updates reach a line as values (text, moments, its own selection); `Coordinator.apply` returns when they equal
what was applied. During a mouse drag `NSTextView` runs its own tracking loop inside `mouseDown`, so
`isSelectingWithMouse` defers the update, and at the mouse-up it is applied with the selection the drag made.

"Copy" puts every shown line on the ordinary clipboard as `[m:ss] Name: text`, the track's label standing in
for a line the call feed did not name.

## Following the bottom

`isFollowingBottom` says whether a change of the feed's item count scrolls to the bottom anchor. Every scroll
the feed starts itself (the first layout, a new item, Jump to bottom, the search's highlight) opens a
`ScrollFollowGeneration` with the value it intends. `ScrollFollowReducer.reduce` reads each geometry frame:

| Frame | Result |
|---|---|
| a generation is open, younger than 0.5 s, no gesture phase | its intended value; it closes after two consecutive frames that moved at most 24 pt, not before 0.2 s |
| no generation, no gesture phase, and the offset moved at most 24 pt or by what the content's and container's height change explains | unchanged |
| anything else | on if within 24 pt of the bottom (insets counted), else off |

Besides the reducer, three things write the flag: Jump to bottom turns it on, a new query with matches and
every search step turn it off, and a new meeting turns it on.

## Search

Command-F shows the bar, Command-G and Shift-Command-G step while it is shown, Esc hides it and clears the
query only from its own field. They come from a local key monitor (`NotepadSearchMonitor`) that handles
events for its own window while it is key, by key code. A match is a feed item whose text matches by
`MeetingSearch`: a line's words or a note's text, never the speaker or the time, and a moment drawn on a line
is not an item of its own. A new query starts at the first match; new lines keep the current match by its id.
The highlighted item is scrolled to the centre when the highlighted id changes.

## Notes

The field's time is read once, as the first character is typed (`NoteDraftStamp`), from
`MeetingRecorder.recordingSeconds()`, the tracks' own clock, and only while the notepad is on the recording.
It is kept until Return, through a stop too; emptying the field forgets it; a first character typed after the
stop gives no time, shown as "after the meeting". A new meeting in the notepad clears the draft.

Return appends the note to the feed and calls `MeetingLibrary.addNote` with the notepad meeting's identity and
folder. `NotepadNotes` then mirrors the library's `pendingNotes` and `noteFailures` into the model one turn
later, coalesced, because one call can clear and set a failure for the same id in a single turn.

| State of a note | Feed | Allowed |
|---|---|---|
| write pending | "Saving..." | nothing: edit and delete are off |
| written | plain | double-click or Edit Note (Return saves, Esc cancels, an emptied text deletes); Delete Note |
| add refused or failed | "Not saved: reason" | an edit is sent again as an add of the same id; a delete removes the row and the library's failure without a write |
| edit or delete failed | "Not saved: reason" | another edit or delete goes to the library again |

A delete removes the row only once the library has neither a pending write nor a failure for it. A failure
counts for a person's quit (`MeetingLibrary.quitLosses`) until the library clears it.

## Moments

A moment is a note of kind `moment`. It always belongs to the recording under way (`recorder.currentSession`
while `.recording`); the star button is enabled only while the notepad shows a recording, the shortcut works
whatever the notepad shows.

| Trigger | Time `t` | Text |
|---|---|---|
| star, words selected in a line of the shown recording | the line's start | the selected words, trimmed; the whole line if the selection covered only the speaker's name |
| star with nothing selected, or the shortcut (a selection is ignored) | the newest non-empty live line's start, if the live text still runs and that line ended at most 10 s before the recording's clock (`momentLineFreshness`) | that line's whole text |
| the same, with no such line (no lines, live text stopped or without a model, a pause, a lagging queue) | the recording's clock | none: shown as "Marked moment" |

When the notepad shows that recording the moment goes through the feed like a note; otherwise it is written
straight through the library and a refusal is only logged. A moment made from a line is drawn on the line: a
star beside the time (its menu: Remove Mark) and its words highlighted, the first match by `MeetingSearch`'s
rule, none if an unfinished line's text has changed since. It is tied to the line by id in memory
(`momentLineIDs`), else by `t` equal to the line's start; a moment whose line is gone is a row of its own.

The shortcut (`KeyboardShortcuts.Name.markMoment`, Option-Shift-M by default, set in Settings, Meetings) is
registered by `MarkMomentHotkey` when the recorder enters `.recording`, with the shortcut's value at that
moment, and released when it leaves; an isolated test process registers nothing.

## Why it is this way

- **An ordinary activating panel.** An `orderFrontRegardless` of an inactive app's window did not hold over
  some apps' windows, so a click must activate Murmurly as it would for any window. Showing without
  activation keeps the call app in front.
- **Raise on activation.** Mission Control's choice of the panel activates the app without raising the panel;
  the check for other visible windows keeps a folder panel, a sheet or the updater's window in front.
- **Keys by code.** The app is `.accessory` and has no main menu to send editing keys, and on a non-Latin
  layout the physical keys produce other characters, which a comparison by character would miss.
- **A local monitor for Find.** The main window's Find and Command-G belong to `TranscriptNSTextView`; a
  shared menu item or shortcut would race it.
- **`\.notepadLibrary`, not `@EnvironmentObject`.** A missing environment object stops the app; the library
  arrives later than the rest and the window must show without it.
- **Lines are `NSTextView`s.** Only an `NSTextView` reports a reliable selected range and a selection
  callback, which the star needs; the notepad is often not key while the call is in front, where AppKit would
  draw the selection pale, hence the view's own drawing.
- **Generations for following the bottom.** A flag "we are scrolling" cannot tell the frame that lands the
  feed's own scroll from a frame that merely looks the same, so each such scroll carries its intention until
  it settles.
- **The time at the first character.** A thought is typed after it was said; reading the clock at Return
  would place it later still, and a note finished after the stop would lose its time.
- **The freshness window of 10 s.** The live text lags a phrase by about 0.7 s, a line still being spoken
  keeps its end moving, and a reaction takes a few seconds.
- **The shortcut ignores a selection.** It is pressed from the call; a selection left in the feed may be
  stale.
