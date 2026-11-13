# Dictation archive

Where dictations are kept, the format of the index, and the only ways it changes. Rules that must not be broken are
in `.claude/rules/dictation-archive.md`. How a dictation gets here is in `reference/dictation.md`.

## Parts

| Type | File | What it owns |
|---|---|---|
| `DictationHistoryEntry` | `Sources/Archive/Dictations.swift` | one line of the index, its coders, the backward reader; shared with the agents' helper |
| `DictationHistoryStore` | `Sources/Dictation/DictationHistoryStore.swift` | the actor: root, append, the change notification |
| — reading | `Sources/Dictation/DictationHistoryStore+Read.swift` | pages, counts, resolving `audio_path` |
| — changing | `Sources/Dictation/DictationHistoryStore+Mutation.swift` | delete, Clear All, `replaceRecognition`, `ownedFiles`, `rewriteHistory` |
| — audio | `Sources/Dictation/DictationAudioArchive.swift` | `saveDictation`, the ALAC encoder, the range check |
| `DictationHistoryChanges` | `Sources/Dictation/DictationHistoryChanges.swift` | a main-actor counter of one store's changes |
| `DictationHistoryViewModel`, `DictationHistoryView` | `Sources/Dictation/` | the Dictations section of the main window |

The app has one store, `DictationHistoryStore.shared`, and it is the only writer: the helper only reads. Nothing
locks the file against a second process.

## On disk

```
~/Library/Application Support/Murmurly/Dictations/      0700
    history.jsonl                                        0600
    2026/                                                0700
        10/                                              0700
            3f2a….m4a   or   3f2a….caf                   0600
    .history-<UUID>.tmp      only during a rewrite
```

The year and month of an audio file's folder are those of the dictation's start in UTC; the file is named by the
entry's id in lower case. `audio_path` holds the path relative to the root (`2026/10/3f2a….m4a`), or is empty when
no audio was kept. There are no absolute paths, bookmarks or device ids in the index, so moving the whole folder to
another Mac or disk is enough.

## A line of `history.jsonl`

One JSON object per line, keys sorted, written by `DictationHistoryEntry.makeEncoder()`.

| Key | Value |
|---|---|
| `schema_version` | `1`. Written; readers do not look at it |
| `id` | UUID |
| `source` | `"dictation"` |
| `at` | the start of the recording: ISO 8601, UTC, with fractional seconds (`2026-10-15T10:31:00.000Z`) |
| `duration_seconds` | length of the audio as read from the source file; 0 when unknown |
| `selected_language` | the language setting at the start (`"auto"` or a code) |
| `actual_language` | what the engine reported |
| `engine` | the engine's raw name; optional |
| `target_bundle_id`, `target_app_name` | the app the text was meant for; optional |
| `audio_path` | relative path, or `""` |
| `text` | the text after the personal dictionary, trimmed |
| `raw_text` | the text as recognized; present only when the dictionary changed it |
| `interrupted` | `true` only for a recording cut off by a capture failure |
| `recognition_failed` | `true` only when recognition failed |
| `recognition_skipped` | `true` only when quit saved the audio without waiting for recognition |

Optional keys are left out when unset, so a line without them is byte for byte what it was before they existed.
The three marks are never written as `false`. `/` in `audio_path` is written `\/`, as `JSONEncoder` does by default.

A line counts as malformed when it does not decode: a required key missing, another type, or an `at` without
fractional seconds. Readers skip it and log "skipping malformed JSONL line"; rewrites copy it through unchanged.
A last line without a trailing newline is read like any other.

## Reading

- `page(before:limit:matching:)` reads backward from a byte offset in 64 KiB blocks (`scanBackward`), newest first,
  and returns a cursor — the offset where its last line starts — so the next page never rescans what was returned.
  `recent(limit:)` is its first page. A history file that does not exist is an empty history, not an error.
- `historySummary()` and `count(matching:)` read the whole file forward and decode every line.
- Search matches `text` only, ignoring case (`localizedCaseInsensitiveContains`); the Russian letters yo and ye
  stay distinct here, unlike in the meetings' search. Copy uses `text` too.
- `resolvedAudioURL(relativePath:)` resolves links and accepts only a `.caf` or `.m4a` inside the root;
  `audioURL(for:)` also requires a regular file.

## Writing

Every writer is a synchronous method of the actor, so none can interleave with another.

| Operation | What it does to the index | And to the audio |
|---|---|---|
| `append` (inside `saveDictation`, `indexArchivedDictation`) | adds one line with `O_APPEND`; if the file does not end in a newline, writes one first | — |
| `delete(id:)` | rewrites without that line | then removes the file `audio_path` resolves to, and its folders if left empty |
| `clearAll()` | rewrites to an empty file | then removes the archive's own files and its empty folders |
| `replaceRecognition(id:…)` | rewrites with that one line re-encoded | untouched |

`rewriteHistory` writes a temporary `.history-<UUID>.tmp` in the root (`O_EXCL`, `0600`), copies the lines,
`fsync`s it, renames it over the index and `fsync`s the folder. A failure before the rename removes the temporary
file and leaves the index as it was. A process that dies in between leaves the temporary file, which no reader
takes for the index and Clear All removes. Replacing a line whose id is not there stops before the rename: the
index keeps its bytes, inode and modification time.

An append is not followed by `fsync`.

## Saving a dictation

`saveDictation(from:id:at:preserveSource:saveAudio:makeEntry:)` archives the audio and appends the line in one
actor turn, with no `await` inside.

| `preserveSource` | `saveAudio` | Audio in the archive | Used for |
|---|---|---|---|
| false | false | none; `audio_path` is `""` | text recognized, audio saving off |
| false | true | m4a (ALAC); the source CAF copied instead if encoding fails | audio saving on, or an empty result |
| true | either | the source CAF, byte for byte | a cut-off recording, a failed recognition, a save at quit |

Saving dictation audio (`dictation.saveAudio`) is off by default. Whatever the switch says, audio is kept for a
cut-off recording, a failed recognition, an empty result and a quit that did not wait for recognition.

The store never deletes the source: the coordinator removes the temporary CAF only after the save answered. If the
append fails after the audio was archived, the copy stays and the error is `IndexWriteFailed`, carrying the path
and duration; the quit-time retry then calls `indexArchivedDictation`, which writes only the line and throws
`ArchivedAudioMissing` if the copy is gone.

## Audio format

Saved audio is m4a with mono 24-bit ALAC at the microphone's own sample rate. The format id is named in one place,
`DictationHistoryStore.dictationArchiveFormatID`; the bit depth, container and channel count are in the body of
`encodeAppleLossless(from:to:gain:channels:)`. That function is `nonisolated static` and is also what meeting
compression calls, with its own channel count and gain; dictations use the defaults, one channel and no gain, so a
source with several channels is archived as its first one.

Before each block reaches the encoder, `requireLosslessRange` checks every sample of every channel: the buffer must
be Float32, and each sample finite and within `[-1, 1]`. Anything else throws, the m4a is removed and the source CAF
is copied byte for byte instead. `archiveAudio` takes the encoding for done when the m4a is not empty.

## Deleting one entry

`delete(id:)` removes the line first and then the audio at the line's `audio_path` — any `.caf` or `.m4a` inside
the root that the path resolves to. The file is removed for good, not moved to the Trash, and month and year
folders left empty are removed after it. The change is announced even if removing the audio throws; the line is
gone by then and the file stays on disk.

## Clear All

`clearAll()` lists the archive's own files first, then empties the index, then deletes those files, then removes
month and year folders with `rmdir`, which succeeds only on an empty folder.

`ownedFiles(in:)` decides ownership by path and name, not by the file's origin:

- `<yyyy>/<MM>/<UUID>.caf` or `.m4a`, where the year is four ASCII digits and the month `01`–`12`;
- `.history-<UUID>.tmp` in the root.

Anything else stays: a meeting moved there under an earlier setting, a note, any other file. Year and month folders
that are links are not followed, and a file that is a link is not taken. A folder that cannot be listed makes the
clear fail before anything changes.

`contentToClear(in:)` gives Storage the size of the index plus those files, and says whether there is anything to
clear. The Dictations section keeps Clear All enabled while the index has lines or the archive has a file of its
own (`DictationHistoryViewModel.Summary.hasFiles`), so a clear that failed halfway can be finished.

## Recognize Again

A row with audio offers Recognize Again (`DictationCoordinator.recognizeAgain`). It recognizes the saved audio with
the dictation's engine, language and dictionary as they are at the click, and then calls `replaceRecognition`:

- replaced in that line: `text`, `raw_text`, `actual_language`, `engine`; `recognition_failed` and
  `recognition_skipped` are lifted;
- kept: the audio, `at`, `duration_seconds`, the target, `selected_language`, `interrupted`;
- every other line is copied byte for byte, an unreadable one included. The replaced line itself is encoded again
  from the decoded entry, so a key this version does not know would not survive in it.

An entry deleted or cleared meanwhile is left alone and the index untouched. An empty result or an error leaves the
line as it was and shows as the section's error.

It runs one at a time (`recognizingAgainID`) and is refused while a dictation is under way, while another one runs,
once quit has begun, and without the model. It moves neither the indicator nor `modelState` / `modelFailure`. It
does not keep a dictation from starting: that one waits its turn at the engine cache. While a live transcript holds
another engine, it waits for the meeting to stop. Snippets apply, as it uses the dictation's replacer. How quit and
updates treat it is in `reference/quit-and-update.md`.

## Change notification and consumers

After every completed change of the index the store posts `dictationHistoryDidChange` with itself as the `object`:
a line appended, an entry deleted, a recognition replaced, the history cleared — also when removing the audio then
failed. `delete` posts it even when no line had that id; `replaceRecognition` only when a line was replaced.

Each consumer keeps a `DictationHistoryChanges` for that store, created before its first read so that no change
between the read and the subscription is missed, and reads again when `revision` moves:

| Consumer | Reads |
|---|---|
| the menu's recent dictations (`DictationCoordinator.refreshRecentDictations`) | `recent(limit: 10)`; the list is replaced, a newer refresh wins over an older one |
| the Dictations list and search | the first page again, and the count for the search |
| the Dictations summary (`refreshSummary`) | `historySummary()` and `contentToClear`; an older count never overwrites a newer one |
| Settings statistics | `historySummary()` |
| ⌃⌘V / ⌃⌘C | no subscription: `recent(limit: 1)` at the press |

## The Dictations section

`DictationHistoryViewModel` loads pages of 100. Any change of the store, a new search (after 250 ms) or Try Again
starts from the first page again. A failed read or count shows in the section with Try Again (`readFailure`);
alerts are only for actions (delete, clear, play), wait for the section to be on screen and stay until OK.

Playback is an `AVAudioPlayer` of the section's own. It stops when the section is hidden or disappears, when its
entry is deleted and on Clear All. The start of a dictation or of a meeting recording does not stop it.

## Why it is this way

- **JSONL with relative paths** is an open format for ordinary scripts, and makes a move to another Mac or disk a
  matter of moving one folder, with no index to rewrite.
- **Lossless audio** so that a saved dictation can be listened to without artifacts. Recognition alone would
  tolerate compressed audio; the larger archive is the accepted cost.
- **The range check before ALAC:** 24-bit ALAC holds only `[-1, 1]` and would clip anything beyond silently, so such
  a recording is kept as the CAF it came in.
- **The source CAF for a damaged recording:** the file a failed decode could not read is the evidence; converting a
  fragment could degrade it further.
- **Ownership by name:** a name is an agreement, not proof, so Clear All takes nothing that does not match exactly,
  and other files that ended up in the folder survive it.
- **Audio first on a save, the index first on a delete:** either order of failure leaves a file without a line,
  never a line pointing at a file the app removed.
- **A snapshot, not a patch:** every consumer re-reads on the store's signal, so the menu, the list and the counts
  cannot drift from the file.
- **Not covered:** a crash, SIGKILL or power loss between the audio and its line, or right after an append.
