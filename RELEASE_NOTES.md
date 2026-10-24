# Murmurly 0.3

This release is about pasting and keys: dictation leaves your clipboard as you
left it, skips password fields, and can be held, pasted again or copied
again, or cancelled with Esc without losing the text. A personal dictionary
entry can also be a snippet, said whole to paste a prepared text, and a
dictation can be recognized again from its saved audio.

## What's new

- **Your clipboard stays yours.** After a dictation is pasted, the clipboard
  you had before comes back, but only on this Mac: what you copied on your
  iPhone is not overwritten. Clipboard histories that honor the transient
  marks on a dictation skip it.
- **Password fields.** A dictation is neither pasted nor put on the clipboard
  in a field macOS itself marks as a password field; the banner says where
  the text is instead.
- **Paste automatically.** A new switch in **Settings → Dictation → Pasting**.
  Turned off, dictations go to **Dictations** only, and you paste the last one
  with the shortcut below.
- **Paste or copy the last dictation.** ⌃⌘V pastes the last dictation where
  your cursor is now, and ⌃⌘C puts it on the ordinary clipboard. Both
  shortcuts can be changed in **Settings → Dictation → Pasting**
  (**Paste last dictation**, **Copy last dictation**).
- **Hold to dictate.** A new **Trigger** in **Settings → Dictation → Hotkey**
  adds **Hold**, next to **Press** and **Double press**: hold the shortcut
  while you speak and release it to paste. Releasing it in under half a
  second drops the recording instead of pasting it.
- **Esc keeps the text, skips the paste.** Pressing Esc while you dictate, or
  while the dictation is being recognized, stops it and saves it to
  **Dictations** without pasting it; a notice says where it is and names the
  shortcut to paste it later.
- **Snippets.** A personal dictionary entry can now be a **Snippet**
  (**Dictionary → Add… → Kind → Snippet**, with **Say** and **Text** fields):
  say one of its phrases, and nothing else, to paste the prepared text
  instead of what was recognized. Snippets apply to dictation only.
- **Recognize Again.** Control-click a dictation with audio in **Dictations**
  to recognize it again with the current engine, language and dictionary.
- Quitting while a **Recognize Again** is still recognizing now warns and
  stops it on a repeated quit, rather than losing it silently; quitting once
  it is saving, or once a ⌃⌘V paste is restoring the clipboard, waits for
  that to finish. Installing an update is refused while either is under way
  and installs at the next quit instead.

## Fixed

- Quitting while a dictation's own paste is restoring the clipboard now waits
  for that to finish; installing an update is refused while it is under way
  and installs at the next quit instead.
- A size of zero (model downloads, Storage) now shows "0 bytes" instead of
  the rounded word "Zero KB".
- Searching for a language in **Settings → Dictation** now shows the matches
  as buttons right under the search field, one click away, when there are six
  or fewer; with more matches, the search still narrows the menu as before.
- The **Transcribe** button in the Files tab no longer shrinks for a long
  file name; the file name shrinks instead.

## Known limitations

- Esc is a global shortcut and does not reach the app where macOS turns on
  Secure Keyboard Entry (for example, Terminal with that setting on, or some
  password managers), so it does not cancel a dictation there. This is
  separate from the password-field check above, which still applies.
- Because the clipboard is restored on this Mac only, something you copied on
  this Mac before a dictation may not reach your other devices afterward.
  This is intentional: restoring it the usual way would make Universal
  Clipboard hand your other devices the old contents as the newest copy.
- A personal dictionary with a snippet is saved in a newer format that
  Murmurly 0.2 does not apply; clear the dictionary before going back to 0.2.

## Requirements

- A Mac with Apple silicon.
- macOS 15 Sequoia or later.

Known limitations are listed in the
[README](https://github.com/spacevibes365/Murmurly#known-limitations).
