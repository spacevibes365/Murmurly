---
paths:
  - "Sources/MainWindow/MainWindow.swift"
  - "Sources/MainWindow/MeetingsView.swift"
  - "Tests/MurmurlyUITests/MainWindowSectionTests.swift"
  - "Tests/MurmurlyUITests/MeetingsWindowTests.swift"
---

# Main window

Feature layer. `MainWindow` is the sidebar and five sections (`MainSection`); `MeetingsView` is the meetings'
list and card. The state lives in `MeetingLibrary`, the views only show it.

- **Every section is a layer built with the window and only hidden** (`MainWindow.layer`). Its `onAppear`
  runs once, when the window opens: what must happen on a switch watches `MeetingLibrary.section` (or
  `isCardShown`), never an appearance, and never Settings' tab.
- **Nothing closes a sheet, a panel or a question from the update that changes the section or the
  selection.** They stay up until their own buttons answer them. Closing one from that update ran its close
  animation in a nested run loop inside the window's layout and stopped the app. Such an update may only
  drop a `FocusState`.
- **No `NavigationSplitView`, no `HSplitView`.** A split view keeps its layout in the app's preferences (the
  owner's, even for a test copy), and `HSplitView` pushed the content past the window's edges. The sidebar is
  a plain stack folded by `@State`.
- **`MainWindow.minWidth` is the sum of its parts** (sidebar, divider, `MeetingsView.minWidth`). A wider
  layer or a new fixed column goes into that sum, or the content leaves the window.
- **An action that lands later is addressed by the folder itself, taken at the click:** a name typed
  (`TitleEdit`), the Names sheet (`NamesEdit`), a deletion's plan, Transcribe Again's folder. Reading
  `library.selection` when it lands writes into whatever is selected by then.
- **The hidden card gives up the keys.** On `isCardShown == false` the name field (its text is saved), the
  card, the search field and the transcript drop the focus, and the list's Command-Delete is refused. A new
  key handler on the meetings checks `isCardShown` too.
- **`MeetingRow` and `MeetingCard` keep `@EnvironmentObject`s they never name** (`meetingTranscripts` in
  both, `recorder` in the row). They are the subscription that redraws a row's status: the library reads the
  queue and the recorder without forwarding their changes.
- **`MainWindow` pairs `windowOpened()` with `windowClosed()`,** once per opening: reads, the player and the
  search all hang on it.
- **Never branch on displayed text.** `MeetingText` is the words for `MeetingLibrary.Status`; decide from the
  status, show through `MeetingText`.
- **Panels go through `FilesModel.present` on the card's `WindowAnchor`,** read at the click.

How it works: `reference/meetings-window.md`.
