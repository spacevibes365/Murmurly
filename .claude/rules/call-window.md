---
paths:
  - "Sources/MeetingRecorder/MeetingPageReader.swift"
  - "Sources/Permissions/AccessibilityAuthorization.swift"
  - "Tests/MurmurlyTests/MeetingPageReaderTests.swift"
---

# Call window reader

Feature layer. `MeetingPageReader` reads who is in the call and who is highlighted from the call's window through
Accessibility; `AXPageNode` is its live node.

- **Read only.** No `AXUIElementSetAttributeValue`, no `AXUIElementPerformAction`; the only setter is
  `AXUIElementSetMessagingTimeout` on our own handle. A failed read is `nil` or empty, never thrown.
- **Never raise a permission prompt.** `readLive` answers `.notFound` in a test process and without
  `AccessibilityAuthorization.isTrusted`, before any `AXUIElement` call.
- **All Accessibility work runs on `readQueue`,** never the main actor or the cooperative pool, and every element
  gets a 0.25 s messaging timeout before its first question (`AXPageNode.init`, `isWindowElement`): a hung browser
  may hold that one queue, nothing else.
- **Enter every node through `Budget.enter` before reading anything off it** (5000 nodes, depth 40, 5 s).
- **Ask only the app that holds the microphone** (`mainApp(ofHolder:)`), and after the pin only the pinned app.
  A row whose program is not a holder is never tried, so it can neither spend the budget nor lend its tab.
- **A half-read grid reports no names.** When the budget ends inside a candidate, `read` keeps `found` and drops
  everything else: a name or a highlight from a partial read may belong to another tile.
- **Never guess between meetings.** No confirmed area, several of them, or one without an identity read nothing;
  never compare `Meeting?` values as optionals, which makes two unknown meetings equal.
- **`deferred` is not `notFound`.** A hidden-window scan that was skipped or cut short says nothing, and the
  watcher must not write "page gone" over it.
- **The pin is fixed by the first confirmed find and never changes** until the recording ends; only its
  `remoteWindow` is updated.
- **Private symbols come only through `dlsym` and stay optional.** Without them the scan answers `.unavailable`
  and the reader works from the public window list.
- **The reader logs nothing, and only names, flags and the service id reach the feed file.** A page's address
  stays in memory (`Pin`); it goes neither to the feed file nor to the log.
- **Match an address by host boundary and path prefix,** never by substring; the query and fragment are not
  looked at, except the keys a row names in `meetingQueryKeys`.
- **A service is a row in `services`;** `unconfirmedServices` rows are never read by `readLive`. A row's `id` is
  the feed's `service` and the key of `CallFeed.highlightLeads`, so two rows of one service share it.

How it works: `reference/live-transcript-and-call-window.md`.
