# Personal dictionary and snippets

How the user's replacements and snippets are stored, checked, moved between Macs and applied to recognized text.
Rules that must not be broken are in `.claude/rules/dictionary.md`.

## Parts

| Type | File | What it owns |
|---|---|---|
| `DictionaryEntry` | `Sources/PersonalDictionary.swift` | one entry, its coding, what makes it acceptable (`problem`) |
| `DictionarySnapshot` | `Sources/PersonalDictionary.swift` | the dictionary as one job sees it |
| `DictionaryReplacer` | `Sources/PersonalDictionary.swift` | the dictionary prepared for one job; the replacement itself |
| `SettingsStore` (dictionary part) | `Sources/SettingsStore.swift` | the stored document, save, clear, export, import |
| `DictionarySettingsView` | `Sources/Settings/DictionarySettingsView.swift` | the Dictionary section of the main window |
| `DictionaryEntrySheet` | the same file | the one sheet that adds and edits entries |

## Entry and document

An entry is a list of spellings an engine writes (`heard`) and how to write it instead (`written`), with its own
switch (`enabled`), a stable `id` and a `kind`: a replacement, or a snippet. For a snippet `heard` holds its
trigger phrases and `written` its text.

The dictionary is one JSON document — a version and the entries — stored whole in the settings under
`dictionary.entries` and written by the same encoder into an exported file (`SettingsStore.encodedDictionary`:
indented, keys sorted, slashes not escaped):

```json
{
  "entries" : [
    {
      "enabled" : true,
      "heard" : [
        "cloud code",
        "clod code"
      ],
      "id" : "5B1F0C5E-6C0B-4B0E-9E57-0B6C3E1D2A10",
      "written" : "Claude Code"
    }
  ],
  "version" : 1
}
```

`kind` is written only for a snippet (`"kind" : "snippet"`); an entry without it is a replacement.

### Versions

| Version | Written when | Read |
|---|---|---|
| 1 | the dictionary holds no snippet — byte for byte the original document | yes |
| 2 | it holds at least one snippet, switched on or off; adds `kind` | yes |
| any other | never | no: the document is kept as it is |

An entry of an unknown `kind` makes the document unreadable too. Murmurly 0.2 reads version 1 only, so after going
back to it a dictionary with a snippet applies nothing until it is cleared. `kind` is read from an entry whatever
the document's version says.

Keys this version does not know, in the document or in an entry, do not survive the next save: the document is
decoded into `DictionaryEntry` values and encoded again whole. That is why `kind` came with a new version.

### In the settings

`SettingsStore.dictionary` is published and changes only through `saveDictionary(_:)`, which sets the data first
and publishes after, so a failed encoding leaves the stored data, the published entries and the next job's snapshot
as they were. Three switches, `dictionary.inDictation`, `dictionary.inMeetings` and `dictionary.inFiles`, are on
until turned off. Nothing writes a dictionary on its own: a first launch leaves the key absent.

A key that is there but does not read as a document of version 1 or 2 — damaged, or written by a newer app before
going back to an older one — sets `dictionaryUnreadable`. The stored bytes stay; jobs run without replacements;
`saveDictionary` and the export refuse; the section and the sheet edit nothing until an explicit "Clear
Dictionary…" (`clearDictionary()`, the only code that removes the key).

## What an entry must satisfy

`DictionaryEntry.problem(besides:)` is the one check, for the sheet and for every entry of an imported file.

| Problem | When |
|---|---|
| `.noHeard` | no spelling at all |
| `.emptyVariant` | an empty spelling between commas |
| `.noWritten` | `written` is empty or only spaces and line breaks (removing words is not offered) |
| `.lineBreak` | a spelling spans two lines |
| `.punctuation` | a spelling holds anything but letters, digits, spaces and hyphens |
| `.tooShort` | a spelling has fewer than two letters or digits |
| `.repeated` | the same spelling twice in this entry's list |
| `.duplicate` | an enabled entry's spelling is already taken by another enabled entry |

Spellings are compared by `key`: split into words and folded as the replacer does, so two spellings that differ
only in case, in a hyphen or in spacing are one. An entry's own list is checked even while it is switched off;
switched off, it conflicts with no other entry. Two entries whose spellings differ but share a word form are not
caught here; the replacer's order decides between them.

Of `written` the check asks only that it is not empty. A snippet's phrases follow a spelling's rules, a phrase of
any other enabled entry included.

## Export and import

**Export…** writes the document as the settings hold it, atomically and in a detached task, through a save panel
presented with `FilesModel.present`. From its panel to the end of its write, failed or not, both Export and Import
are held, so two writes never race to one file. The file is open to editing by hand, but every entry needs its `id`
and `enabled`.

**Import…** goes in steps (`ImportStep`):

1. `.choosing` — the open panel.
2. `.reading` — the file is read and checked in a detached task (`importedDictionary(at:)`).
3. `.asking` — only for a file that passed, and only if the dictionary is not empty: Add or Replace.

`importedDictionary(from:)` refuses the file whole, naming the entry by its number, unless it is a dictionary this
app could have saved itself: a version it reads, at least one entry, each id once, every entry acceptable by
`problem(besides:)` next to the ones before it, switched-off entries included.

`importDictionary(_:replacing:)` is synchronous, starts from the dictionary as it is at the answer and saves once:

- **Replace** takes the file as it is.
- **Add** keeps every entry of the user's. The same id is skipped — counted as "already there" when identical and
  as "kept as you changed it" otherwise, so an old file never undoes a later edit or switch. A new entry whose
  spelling an enabled entry already has comes in switched off.
- Into an empty dictionary the file is added without a question.

While an import is under way (`locked`) the section edits nothing. Any change of the main window's section while
the file is being read drops that import (`importAttempt`), the Dictionary section having been hidden all along
included: nothing of it is on screen yet. A panel or a question already up stays over the new section and its answer
counts. Settings' tabs belong to another window and change nothing.

Where the dictionary applies and the language are not part of the file; they stay the receiving Mac's.

## The entry sheet

`DictionaryEntrySheet` is opened from three places:

| From | Initializer | Starts with |
|---|---|---|
| the Dictionary section (Add…, Edit) | `init(entry:example:)` | the entry; the only place that offers the kind picker |
| a row in Dictations ("Add to Dictionary…") | `init(dictation:openDictionary:)` | the dictation as recognized (`raw_text`, else `text`) in a copy to select in |
| a meeting's transcript | `init(transcript:selected:openDictionary:)` | the line's words, and the selection as the spelling |

"Use Selection" takes the selected stretch as one spelling (`DictionaryEntry.variant(fromSelection:)`) and refuses
a comma, other punctuation or a line break instead of splitting or cutting it. The clipboard is not used, and the
history line or transcript the text came from is never touched.

The kind picker is fixed once the entry exists. A snippet gets a multi-line text, kept exactly as typed, and no
preview; a replacement's written form is trimmed. An entry made from Dictations or a transcript is always a
replacement.

The preview ("Try it") runs the real replacer, without snippets, over the whole dictionary with the draft in its
place and switched on, and starts again when any input changes — the language included, which can change from the
menu bar while the sheet is open.

While the dictionary is unreadable the sheet takes no entry and offers the way to the Dictionary section
(`openDictionary`). A change of section leaves the sheet up with its draft until Cancel or Save.

## Snapshots: which dictionary a job sees

`SettingsStore.dictionarySnapshot` is cheap and read on the main actor: the entries, the three switches and
`matchesWordForms`. Word forms are prepared later, by the job, off the main actor.

| Job | Snapshot taken | Use | Where the replacement runs |
|---|---|---|---|
| Dictation | with `recordingSnapshot`, as recording starts | `.dictation` | right after the engine's segments are joined, before the trim, the history and the paste |
| Recognize Again | at the click | `.dictation` | the same path |
| Meeting transcription | as the job starts, before its speech model loads (`MeetingTranscriber.dictionary`) | `.meetings` | `MeetingTranscriber.finished`, on each final line |
| Live transcript | as the recording starts | `.meetings` | on each shown line |
| File | as the run starts | `.files` | `MeetingTranscriber.finished` |

An edit applies to the next job. A written transcript or history line is never redone; the history keeps the
recognized text in `raw_text` only when the dictionary changed it.

For meetings and files the replacement comes after echo removal, which counts words and must see them as
recognized, and after merging, so a phrase split between two chunks of one speaker is found. A whole meeting, one
cut short, a file and its cut-short results all take that one step. A dictation that was not recognized and is tried
again by dragging its audio into Files is a file: the Files switch and the Files choice of engine apply, and no
snippet does.

A meeting or a file with its own choice of engine and language keeps the settings' entries and switches, and
answers `matchesWordForms` by its choice.

## The replacer

`DictionaryReplacer` makes one pass, left to right, over the words of a finished text.

- **Words** are what `NLTokenizer` finds, split again at hyphens — in the spellings and in the text alike, so a
  one-word spelling also matches one part of a hyphenated compound.
- **Folding** (`folded`): lower case, and the Russian letters yo and ye count as one. Nothing else is folded.
- **A spelling of several words** matches words that stand apart by spaces or by exactly one hyphen; a full stop, a
  comma or a line break ends the phrase.
- **Which rule wins** at a position: more words first, then more letters, then an exact spelling before a word
  form, then the dictionary's order.
- **The result** is the text's own slices with the written form inserted literally; nothing between replaced words
  changes, and the pass never reads its own output.
- **A rule leaves its own written form alone** where it already stands as whole words (compared literally, case
  included): the rule that would turn the first word of "Claude Code" into "Claude Code" again is passed over
  there, and other rules still apply.

`replacing(in: [String])` shares one tagger across a batch — a meeting's lines are one job — and returns the number
of replacements. Logs get that number, never the words.

## Word forms

A spelling can also match by dictionary form, so that one entry covers a Russian word's cases.

- The form is macOS's `NLTagger` lemma, asked for one lower-case word at a time with the language set to Russian.
- It counts only for a spelling written wholly in Cyrillic whose written form has no Cyrillic at all.
- It counts only when the job's language is Auto, Russian or a code the engine does not know
  (`DictionarySnapshot.matchesWordForms(engine:language:)`, the same answer the engine request gets).
- Forms are prepared once per job, off the main actor.

Limits: words macOS does not know get no form (most loanwords — the forms needed are added as more spellings);
a form also joins singular with plural and homonyms; the result depends on the macOS version and on macOS having
its Russian language data; languages written without spaces are not covered.

## Snippets

A snippet (`DictionaryEntry.Kind.snippet`) turns a whole dictation into a prepared text. When the dictation's
words, folded as spellings are and with punctuation aside, equal one of the snippet's phrases, the result is the
snippet's text as written, line breaks included, and no replacement touches it. Inside a longer dictation a snippet
does nothing, and word forms never count for it.

- Dictation only: `replacer(for: .dictation)` alone passes `includeSnippets`, so Recognize Again applies them too,
  and meetings, the live transcript, Files and the sheet's preview never do.
- The text is stored as typed, but the coordinator trims a dictation's edges, so leading and trailing spaces and
  line breaks are not pasted.
- A snippet with no text is skipped rather than erase a dictation.
- A matched snippet counts as one replacement.

## Why it is this way

- **Saved whole, never patched:** one document with one writer makes "set the data, then publish" atomic for every
  job's snapshot.
- **An unreadable document is kept:** it may belong to a newer app, and overwriting it would cost the user their
  dictionary; an explicit clear is the only way out.
- **Version 1 while there is no snippet:** an older app keeps reading a dictionary that uses nothing new.
- **The id says where an entry came from, not which copy is newer,** so importing an old file cannot undo later
  edits.
- **Nothing is closed from the section's change handler:** SwiftUI runs that update inside the window's layout, and
  closing a panel or a question from it ran the close animation in a nested run loop there, which re-entered
  AppKit's update cycle and crashed.
- **The language is set for the tagger, not detected:** detection takes a short dictation for another language, and
  a whole sentence tagged at once gives a capitalised word a different form.
- **No removing of words:** an empty written form would leave a meeting line empty and drop it from the transcript.
- **One letter is too short:** a single-letter spelling would replace a word in every sentence.
- **Replacement after echo removal:** echo removal compares the words of the two tracks and must see them as the
  engine wrote them.
