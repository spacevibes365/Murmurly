# The Murmurly window: meetings, text, search, player, Save As

How the main window shows meetings. The rules that must not be broken are in `.claude/rules/main-window.md`,
`meeting-library.md` and `transcript-view.md`; this file is how the parts work and why.

| Part | Type | File |
|---|---|---|
| Window, sidebar, sections | `MainWindow`, `MainSection` | `Sources/MainWindow/MainWindow.swift` |
| List, card, sheets, the words for a status | `MeetingsView`, `MeetingNotices`, `MeetingText` | `Sources/MainWindow/MeetingsView.swift` |
| The model: reading, selection, status, search, Save As | `MeetingLibrary` | `Sources/MeetingRecorder/MeetingLibrary.swift` |
| Jump to a moment, notes on the card | `MeetingLibrary` (extension) | `Sources/MeetingRecorder/MeetingLibrary+OpenAndPlay.swift` |
| A transcript as shown, the rule for a match | `MeetingTranscript`, `MeetingSearch` | `Sources/Archive/MeetingText.swift` |
| The text view on the card | `TranscriptTextView`, `TranscriptNSTextView` | `Sources/MainWindow/TranscriptTextView.swift` |
| The two tracks played as one | `MeetingPlayer`, `MeetingTrack` | `Sources/MainWindow/MeetingPlayer.swift` |
| One meeting folder read from disk | `Archive.MeetingFolder` | `Sources/Archive/Meetings.swift` |

## The window and its sections

The scene is `Window(id: "main")` in `MurmurlyApp`, 1100 x 720 by default and never narrower than
`MainWindow.minWidth`: the 200 pt sidebar, a divider and `MeetingsView.minWidth` (the 330 pt list, a divider,
the card at 460 pt at least). The scene hands it the app's own `MeetingLibrary`, `FilesModel` and
`DictationCoordinator`, so nothing the window shows belongs to the window.

| `MainSection` | Layer (`mainContent.*`) | View |
|---|---|---|
| `meetings`, `starred` | `meetings` | `MeetingsView(onlyStarred:)`: one list, filtered for Starred; the card and the selection stay |
| `dictations` | `dictations` | `DictationHistoryView(isShown:)` |
| `dictionary` | `dictionary` | `DictionarySettingsView(section:)` |
| `files` | `files` | `ContentView` |

All four layers are built when the window opens and stay in a `ZStack`. `MainWindow.layer` hides the ones not
chosen with zero opacity, no hit testing and `accessibilityHidden`; it does not remove them and does not move
the keyboard focus. Each layer therefore keeps its state, a sheet or panel over it stays through a change of
section, and its `onAppear` runs once. Whatever must happen on a switch is given the section as a value
(`isShown`, `section`, `SettingsChrome.scrolling(trigger:)`) or watches `MeetingLibrary.section`.

The section is `MeetingLibrary.section`, in memory and kept while the window is closed: a menu command given
then sets it for the window's first appearance, and reopening shows the last one. `MeetingLibrary.open` always
sets `.meetings`. The sidebar is a plain `List` in an `HStack`, folded by a toolbar button into `@State`, so a
window opened anew shows it again.

`isCardShown` is "the window is open on Meetings or Starred". When it turns false: `syncPlayer` unloads the
player (the sound stops, the files close) and `startRefusal` refuses Play; a wish of the search to focus the
text (`searchFocus`) is dropped; the name field, the card, the search field and the transcript give up the
focus, and a name being typed is saved; the list's Command-Delete is refused (its other keys are not checked);
a save's outcome goes to `exportNotice` instead of the card. Refresh and Command-R are enabled only while it
is true. `MeetingNotices` stands above every section and shows three things until dismissed: `removalReport`,
`markNotice` and `exportNotice`.

## What a meeting is

`MeetingStorage.meetingFolders(in:)` lists a root: a folder named as recordings are, holding `metadata.json`
or one of the default track names. Storage counts with the same function. A root that is itself a link is
listed through its target (`rootChildNames`) and its meetings keep the link's spelling; a meeting folder that
is itself a link is not listed. A root proven absent is empty; one that cannot be reached or listed throws.

The window has three kinds of `Listing`: `local` (the app's own root), `chosen` (the meetings folder from
settings, nil when unset or spelled exactly as the local root) and `outside` (one listing per meeting opened
from the menu that lies in neither root; it is read on its own and kept until the window closes). A row's
identity is its canonical path, so a folder of one name in both roots is two rows, and `isInBothPlaces` says
so. `Meeting.identity` is the folder itself (`FolderIdentity`), nil when it could not be read.

## Reading

Each listing has a `Channel`: a serial queue by the listing's path plus what waits for it. `runNext` starts at
most one read and prefers the card's text, then the list, then a batch for the search. Marks writes and
deletion rechecks use the channel of the meeting's parent folder, which is the same channel for a meeting in a
root and a different one for an `outside` meeting.

`refresh()` raises `requestGeneration`, follows a changed meetings folder, clears `fresh` on every listing and
asks every listing again. It runs when the window opens, on Refresh or Try Again, and (through
`scheduleRefresh`, once per turn) when the queue publishes `lastOutcome`, `finishedJobs` or `movedTo`, the
meetings folder setting changes, the app becomes active, a volume is mounted or unmounted, a recording
session starts or ends, and after a deletion. Each time both roots are read whole.

One meeting's read (`readMeeting`) is `Archive.MeetingFolder.read(_:links: .follow)` (metadata, file names,
transcript versions, attempt records with their lines, marks) plus what only the window needs: `folderSize`
(every file counted; nil when part of the folder could not be read), `audio`, `manifest`, `audioRetention` and
`playback`.

| `Listing` field | Meaning |
|---|---|
| `state` | `.notRead`, `.read`, `.unavailable` (a chosen or outside folder that is not there; its meetings are not shown), `.failed(reason)` (the meetings shown are from before) |
| `fresh` | answered a read started for the latest `refresh()` of this opening |
| `reading` | a list read is under way |
| `notResponding` | that very read has lasted longer than 3 s (`notRespondingAfter`); list and text reads set it, a search batch does not |

A `notResponding` or `.unavailable` listing refuses a transcription and marks for its meetings with "The
meetings folder isn't available". A list answer lays the marks written since the read began over what it
found (`withWrittenMarks`, by `marksClock`), so a read never takes a newer write back.

Closing the window keeps the last snapshot, cancels the subscriptions, unloads the player, clears the search
query and its cached texts, drops the `outside` listings and deselects a meeting that was only there. A read
under way finishes and updates the snapshot without marking it fresh; requests made meanwhile wait and
everything is asked again at the next opening.

## A row's status

`status(of:)` gives a `Status` of three parts, and `MeetingText.status` turns it into the row's one line.

1. **Operation**, the first that applies: the recorder's session on this path (`starting`, `recording`,
   else `saving`); the session that just ended while its snapshot has no metadata yet (`saving`); a queue
   operation on the folder other than a move (the operation's name); the queue's active job on this path
   (`stepLabel`, the menu's words); a transcription waiting for this path (`queued`).
2. **Outcome**: an outcome the queue could not record (`unrecordedOutcomes`) first; else the last attempt by
   number: no record, nil; an unreadable record, `unknown`; `inProgress` with no work under way,
   `interrupted`; otherwise the record's result.
3. **Text**: `hasTranscript` is "at least one `transcript*.md`"; `brokenOff` is "readable, no metadata state,
   no operation"; `unreadable` is "the folder could not be listed".

| Shown | When |
|---|---|
| "Fully transcribed" | the last record says `complete` and there is a transcript |
| "Transcribed, completeness unknown" | there is a transcript, and no record, an unreadable one, or an outcome that says nothing |
| "Transcript cut short" / "without one track" / "with gaps" | the last record says `incomplete` |
| "Recording broke off" | no transcript and `brokenOff` |
| "Folder can't be read" | `unreadable`, whatever the records say |

Versions are the files `transcript.md` and `transcript N.md`, ordered by their number; the newest is the
highest number, and it is the one shown by default, searched and given to the helper. The completeness shown
on a row is the last attempt's by the record's own number, whichever file that attempt wrote.

## Selection

`select(_:)` takes one folder (its newest version, the text asked for, the player synced) or a set: with
several, `selection` is nil and the card offers the batch actions. A version picked by hand (`pick(version:)`)
stays picked across reads while the file is there and pauses the player, since the lines are another text's.
`open(_:transcript:)` is the menu's and the notepad's way in: Meetings, the search cleared, the version named;
called with the window closed it sets the selection at once and reads after the window opens.

When the queue moves a meeting, `follow` moves the selection to the new address if nothing is at the old local
path, and `address(of:)` answers the same question for `transcribe` and `openAndPlay`. After each list answer
`snapshotChanged` re-picks the version, and a fresh answer for the selected meeting's listing reads its text
again without blanking what is shown (`loadText(again:)`): Refresh shows a change made outside and retries a
failed read. As a search ends the list is made anew and scrolls to the card's meeting, or the first of several
selected, once a row is on screen.

## The transcript as shown

`MeetingTranscript.parse` accepts the app's own form only: a header down to the first line that is exactly
`---`, then every non-empty line matching `[m:ss] **label:** text` (or `[h:mm:ss]`). One line that does not
match, and the whole text has `lines == nil` and is shown as written; so is a file saved with CRLF line ends.

| `Timing` | From | Gives |
|---|---|---|
| `.exact` | the attempt record of this version, when the file's size and SHA-256 equal its fingerprint and it has one span per line (`timed(by:)`) | each line's span and source track: names, subtitles, the line lit while it is said |
| `.approximate` | the file's own timecodes | each line's start; the player bar says the times are approximate |
| `.untimed` | a text not in the app's form | nothing |

`layout` is the shown string and where its parts are: the header's first `# ` line as a title, the rest of the
header and the names note as notes, then `[time]  label: words` per line. `TranscriptTextView` draws it,
"Copy Text" copies its string, the search looks through `searchable` (the lines' words only; a text not in the
app's form whole). It is computed on every access and its cost grows with the text, so take it once per use.

`TranscriptTextView` replaces its text only when the identity (meeting, version, content) changes, so a redraw
keeps the scroll and the selection; the line being said and the matches are drawn over the text. Timecodes are
links that play from their line. Space plays and pauses while the text or the card has the focus.

`recordRefusal` is the reason a version has no names, exact times or subtitles: the meeting has no records at
all; the record's fingerprint differs from the file; or no record matches (which also covers a file that
matches its fingerprint but did not parse into one line per span).

### Names in the shown text

`shownTranscript(of:)` is `text.named(by: marks, call: call)`. With exact timing each line is named by index:
a microphone line takes the user's name for the microphone, else the call feed's pick for that line; a system
line takes the feed's pick (renamed through `callNames`), else the user's name for the system track; the
written label is the last fallback. `call` is the `CallFeed.Summary` read with the text; without a feed the
result is the two track names alone. Once named, `namesNote` adds a line after the header ("Names: ... is the
microphone, ... is the system audio", plus the people named from the call). The player's track buttons take
the names whatever the version (`trackLabels`).

The Names sheet has a field for the microphone, one for the system audio and, when the feed found people, one
per person ("People from the call"); a feed that never saw a tile shows "Names from the call: not found". The
button is off, with the reason, while `markRefusal` or `recordRefusal` says so. Save waits for the write
(`saveNames`): the fields are off meanwhile, and a refusal, late too, stays in the sheet with what was typed.
A name is one line and holds no `*`, which would end a Markdown label early; an empty one gives the label
back. Where the names are stored is in `reference/marks-and-notes.md`; how the call feed picks a name for a
line is in `reference/live-transcript-and-call-window.md`.

"Add to Dictionary..." (beside Copy Text, and first in the text's context menu) opens
`DictionaryEntrySheet(transcript:selected:)` with `Layout.dictionarySource`: the words of the line the
selection begins in, and everything selected as the spelling (nil when several stretches are selected).

## Search

`searchQuery` is the window's and is cleared when it closes. For a non-empty query each fresh listing reads
the newest transcript of its meetings in batches of 20 on its channel, behind the card's text and the list.
A text is cached by the folder itself (`searchTexts`) and counts only while the meeting's path, newest version
and modification date are the ones it was read for.

Matches are counted off the main actor (`countMatches`) over fresh listings; a listing being read again keeps
its last known matches. A match is `MeetingSearch`'s: case and the Russian letters yo and ye never tell words
apart, nothing else is folded. `SearchMatch` holds the count in the lines' words and whether the meeting's
shown title matches; either puts the meeting in the list. Stale work is dropped at three points: a batch
started under an earlier `listingRevisions` value (raised by each request and each answer) or another opening
of the window; a count that is not the latest `searchCount` or whose query changed; a new query, which clears
the last one's matches at once.

`SearchState` is what the search cannot vouch for: transcripts `waiting`, `failed` reads, `unreadable`
folders, `unknownFolders` (not read, away or failing), `updating`, `counting`. "No matches" is shown only when
it is `settled`. Return in the field (`searchSubmitted`) selects the first meeting found among both roots and
the outside ones, unless the card's own is one, and asks its text to take the focus at the first match. The
card shows which match of how many, with arrows, from the text's selection; Command-G and Shift-Command-G step
through them in `TranscriptNSTextView` while the find bar is closed.

## Listening

`MeetingPlayer` belongs to the library, which alone loads and unloads it (`syncPlayer`, after every change of
selection, snapshot, section or queue operations). It plays what `MeetingStorage.playback(in:)` names: per
track the `.m4a` once compression put it there, else the `.caf`. A folder already loaded stays loaded while
it is the same folder, so a compression that replaced a track does not cut the sound.

Loading: `load` raises the generation, counts the folder in `opening` and opens the tracks one after another
on a serial queue of the meeting's parent folder (`playerQueue`, apart from the list's channels). Before each
file it checks that the load was not let go of (`LoadTicket`), that the folder at the address is still the
same `FolderIdentity`, and that the track is a plain file (`MeetingStorage.entry`). `finishLoad` takes the
tracks only if the generation is still current; either way it lowers `opening`. `unload` and `release` raise
the generation and close the files in that turn.

Playing: every track is set to `resumeAt` and started at `deviceCurrentTime + 0.05` of the longest track; a
track shorter than the position stays quiet; one that will not start stops both. The timeline is the longest
file's length. Rates are 0.75 to 2. A timer checks every 0.25 s: a track's `failure` stops both with the
reason and closes the files; the longest track no longer playing is the end. `hold` pauses and keeps Play off
with a reason while the recorder is busy or a dictation is under way, loaded or not; the files stay open.

`MeetingTrack` is the seam. `Deck.live` gives `AudioPlayerTrack` (an `AVAudioPlayer` and its delegate) in the
app and refuses in any test process; the UI-test stand-ins are described in `reference/test-isolation.md`.

## Save As

`export(_:as:from:)` takes the shown text at the click and refuses a second save while one is under way
(`exporting`). Then the save panel as a sheet on the window it was asked from (`Saving.destination`), then the
write on `exportQueue`, atomically. Right before the write `destinationRefusal` walks the destination's
parents with links resolved and refuses any folder named as a meeting's, or the meeting's own folder by
identity. From the panel's answer to the end of the write `exporting.writing` is true, which is what
`quitLosses` and `AppUpdater.busy` read. The outcome goes to `exportOutcome` while the same meeting, folder
and version are on the shown card, else to `exportNotice`.

| Format | Content |
|---|---|
| Markdown | the file's text as read, unchanged, unless names took the labels' place: then the header, the names line, and each line rewritten with its name |
| Plain text | what Copy Text copies, ending in one line break |
| Subtitles (SRT) | one cue per line from the record's exact spans; refused by `subtitlesRefusal` without them or with a time `isSubtitleTime` rejects |

Markdown and plain text end with the meeting's notes when it has any: a heading ("## Notes" in Markdown),
then one line per note, `[m:ss] text`, a star for a moment, "(after the meeting)" for one without a time. The
heading, that phrase and the names line come from the string catalog, so they follow the interface language.
Subtitles carry no notes. The suggested name is the meeting's start to the minute from its folder's name, a
later version's number and the extension (`2026-10-15 10-31 Meeting 2.md`); it is never translated.

## Notes on the card, and jumping to a moment

The card lists the notepad's notes under the transcript, read only: `notepadNotes(of:)` gives the timed ones
by time (ties in the file's order), then the untimed. A note's time plays from `noteLead` (10 s) earlier,
never before 0, and is off until the player has loaded.

`openAndPlay(folder:at:)` is for a click on a time in the notepad. It returns a reason and does nothing while
the player is held, or when the meeting is in the snapshot and `audioRefusal` has any reason for it (an
operation on the folder, no audio left, an unreadable folder, an unavailable meetings folder). Otherwise it
opens the meeting at its address now, shows the main window through `MeetingLibrary.showMainWindow` (set by
the menu bar label) and polls every 50 ms, for `audioWait` (10 s) at most, until the player has loaded that
folder; it plays only if the meeting is still selected.

## Why it is this way

- **Serial queues, not the cooperative pool.** A read of a dead network volume blocks its thread for as long
  as the volume takes to fail. On a queue of its own it blocks one folder; in the pool it would starve
  unrelated tasks.
- **No `NavigationSplitView`.** AppKit keeps a split view's widths and folding in the app's preferences, and
  no hook was sure to come before its first write; a test copy would write into the owner's domain.
- **No `HSplitView` for the list and the card.** It sized its panes by their widest content and pushed the
  window's content past both edges.
- **Sheets and panels stay over a changed section.** SwiftUI runs the update that changes the section inside
  the window's layout; closing a panel or a question from it ran the sheet's close animation in a nested run
  loop there, which re-entered AppKit's update cycle and stopped the app (seen on macOS 26.5).
- **The list is made anew as a search starts or ends (`.id(searching)`).** Rows the search left out and
  brought back kept the table's own row height, with their time, source and state cut off.
- **`MeetingSearch.fold` replaces only the precomposed letters, literally.** A plain replacement compared
  with canonical equivalence and also took a yo written as ye plus a combining diaeresis; the folded text came
  out shorter than the shown one and a search past its end stopped the app.
- **Subtitle times are checked.** A record edited by hand may hold any number, and a time too large for an
  integer of milliseconds stopped the app.
- **Names go by the record's source, not by the label.** A file written under another interface language, or
  with one label for both tracks, could not be named by matching label text.
- **The player closes files before any operation.** A move or a deletion of a folder with open audio would
  leave the player on files that are gone, or keep a volume busy.
