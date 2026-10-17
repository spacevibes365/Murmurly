# Murmurly 0.2

Your meetings now have a window of their own: Murmurly lists the recordings in
your meeting folders, shows their transcripts and plays them back. This release
also adds a personal dictionary, transcribes a meeting again with another
engine or language, and is the first one signed with a Developer ID and
notarized by Apple.

## What's new

- **The Murmurly window.** Choose **Open Murmurly** in the menu, or open the
  app again while it runs. Its sidebar holds **Meetings**, **Starred**,
  **Dictations**, **Dictionary** and **Files**. The dictation history (now
  **Dictations**) and **Files** have moved here from Settings, which now holds
  only settings.
- **Your meetings.** Meetings are listed by date with their length, the app
  that started the recording, how their transcription stands and their size.
  Select one to read its transcript, search it with ⌘F and copy it. Give a
  meeting a name of your own, and star it to find it under **Starred**.
- **Listen.** Play a meeting from any line of its transcript: both tracks
  together, at 0.75× to 2×, with your side or the others muted if you like.
- **Search All Meetings.** Find words in the names and newest transcripts of
  the meetings in your meeting folders.
- **Speakers' names and Save As.** Put names in place of "Me" and "Others", and
  save a transcript as Markdown, plain text or SRT subtitles.
- **Delete.** Move a meeting's audio, or the whole meeting, to the Trash, one or
  several at a time. If you like, Murmurly deletes the audio of fully
  transcribed meetings 7, 30 or 90 days after their first full transcription
  (**Settings → Meetings**); the transcripts stay.
- **Personal dictionary.** Tell Murmurly how to write the names and terms the
  engine gets wrong. It works in dictation, meeting transcripts and file
  transcripts, and each can be switched off. Make an entry with **Add to
  Dictionary…** from a dictation or a meeting's transcript, and move your
  dictionary to another Mac with **Export…** and **Import…**.
- **Transcribe a meeting again.** **Transcribe Meeting…** and **Transcribe
  Again…** let you choose the engine and language for that transcription only.
  Your settings stay as they are, and earlier transcripts are kept.
- **Files: engine and language.** Transcribe a file with another engine or
  language than dictation, and download that engine's model right there. By
  default, files use the dictation's engine and language.
- **Signed and notarized.** Murmurly is signed with a Developer ID and
  notarized by Apple: macOS asks once whether to open it, as with any app you
  download.

## Good to know

- **Updating from 0.1.** Murmurly 0.1 was not signed with a Developer ID, so
  you may need to grant the microphone, Accessibility and system audio
  permissions again. If dictation stops pasting or a meeting recording fails,
  check **Settings → Permissions** and **System Settings → Privacy & Security**.
  Later updates, signed with the same Developer ID, normally keep your
  permissions.
- **Older meetings.** Speakers' names, SRT subtitles and exact line times need
  the record Murmurly now keeps with each new transcript. For a meeting
  transcribed before 0.2, use **Transcribe Again…**.
- **Meeting audio is kept unless you choose otherwise.** Deleting old audio is
  off by default. When you turn it on, Murmurly first says how many meetings
  lose their audio right away. That audio is deleted for good, not moved to the
  Trash, and starred meetings keep theirs.
- **Automatic meeting recording is on by default.** In many countries,
  recording a conversation requires the consent of everyone in it, and Murmurly
  does not notify other participants. You can turn automatic recording off on
  the first screen or in Settings → Meetings.

## Requirements

- A Mac with Apple silicon.
- macOS 15 Sequoia or later.

Known limitations are listed in the
[README](https://github.com/spacevibes365/Murmurly#known-limitations).
