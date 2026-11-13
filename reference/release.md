# Installing a local build and making a release

What `scripts/install.sh` and `scripts/release.sh` do, step by step, and how updates reach installed copies.
Rule: `.claude/rules/release.md`. Build constraints (warnings as errors, signing variables, entitlements) are
in the root `CLAUDE.md`.

## The pieces

| File | Role |
|---|---|
| `project.yml` | the generated Xcode project: targets, pinned packages, versions, schemes |
| `Signing.xcconfig` | `MURMURLY_CODE_SIGN_IDENTITY` (ad-hoc by default) and the three `MURMURLY_SU_*` values; includes the git-ignored `Local.xcconfig` |
| `Murmurly.entitlements` | audio input, and `disable-library-validation` for builds without a Team ID |
| `Murmurly-Info.plist` | `SUFeedURL`, `SUPublicEDKey`, `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, the daily check |
| `scripts/install.sh` | a Release copy of this checkout into `~/Applications` |
| `scripts/release.sh` | the DMG and the appcast |
| `scripts/dmg/background.tiff` | the picture of the image's Finder window, 1x and 2x |
| `scripts/make-icon.swift` | draws the app icon; run by hand, nothing calls it |
| `RELEASE_NOTES.md` | becomes the "what's new" text of the update window |
| `.github/workflows/ci.yml` | the unit suite on every push to `main` and every pull request |

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set once, in `project.yml`.

## `scripts/install.sh`

Builds the Release configuration into `.build/install-derived-data` with the signing `Signing.xcconfig` and
`Local.xcconfig` give, then replaces `~/Applications/<name>.app`.

1. Refuses if a copy is in `/Applications`: two installed copies would fight over the shortcuts, the
   watchdog, the archive and the login item.
2. Copies the bundle to a staging folder beside the target and verifies it: `codesign --verify --deep
   --strict`, the expected signature (ad-hoc, or the named authority) and the bundle identifier.
3. Sends SIGTERM to every process whose executable is the installed copy's main binary and waits up to 30 s.
   The app turns the signal into its ordinary quit; that route does not wait for a person, so work nothing
   redoes (a queued transcription, a Files run) is only logged as lost. If a process is still alive, nothing
   is replaced and the script fails. It never sends SIGKILL.
4. Moves the previous bundle into the staging folder, moves the new one into place, verifies it again. A
   failure up to here puts the previous bundle back; the script does not start it again.
5. Launches the new copy and waits up to 10 s for its process. From here nothing is rolled back; if the start
   is not confirmed, the previous bundle stays in the staging folder.
6. Reports the CDHash and whether there is a Team ID, since macOS ties privacy grants to them.

Processes of the embedded helper (`Contents/Helpers/murmurly mcp`, started by an agent) are not looked for.

## `scripts/release.sh`

```sh
scripts/release.sh                                  # ad-hoc: <name>-<version>-arm64-unsigned.dmg
DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=<profile> scripts/release.sh
scripts/release.sh --check-dmg <image.dmg>          # only the search for home paths
```

Output goes to `.build/release/` of the checkout it was started in. Needs XcodeGen, Xcode's command-line tools
and Python 3.10 or newer.

1. **Clone.** Refuses uncommitted changes to tracked files (untracked files are simply not in the clone).
   Clones the committed HEAD to `/private/tmp/murmurly-src-<commit>`, runs itself there, and removes the clone
   afterwards. The build folder is `/private/tmp/murmurly-release-<commit>`, erased first, so packages are
   resolved again for every release.
2. **Build.** `xcodegen generate`, then the Release configuration. Without `DEVELOPER_ID` the identity is
   forced to ad-hoc, even when `Local.xcconfig` names a personal certificate; with it, the identity is the
   Developer ID and every signature gets a secure timestamp.
3. **Key check.** A non-empty `SUPublicEDKey` in the built `Info.plist` must decode to 32 bytes.
4. **Re-sign (Developer ID only), inside out.** Sparkle's `Installer.xpc`, `Downloader.xpc` (keeping its
   entitlements), `Autoupdate`, `Updater.app`, the framework; then the helper with the hardened runtime,
   keeping its identifier; then the app with `disable-library-validation` removed from its entitlements.
5. **Checks on the bundle.** No executable Mach-O file carries `get-task-allow`; an unreadable signature
   stops the release. With Developer ID: library validation is on in the app, and the helper has the app's
   Team ID and the hardened runtime. The helper exists and is executable; `codesign --verify --deep --strict`
   passes; the main binary is `arm64` only.
6. **Image.** dmgbuild (with ds-store and mac-alias, all three pinned by exact version, installed into a
   throwaway virtual environment) writes a compressed HFS+ image: the app on the left, a link to
   `/Applications` on the right, 128 pt icons, the background picture. `hdiutil verify` must pass; a failed
   image is rebuilt, up to three times.
7. **Home paths.** `check_image_paths` mounts the image read-only and counts, in every regular file, the
   occurrences of the folder that holds the home folders (`dirname "$HOME"` with a slash). Any hit stops the
   release and lists the files.
8. **Notarize (Developer ID only).** Sign the image, `notarytool submit --wait`, require `Accepted`, staple,
   `stapler validate`, `spctl --assess`, then search for home paths once more.
9. **Appcast.** See below.
10. Prints the image's SHA-256, `Release ready: <image>` and one line about the appcast.

The previous image of the same name is removed before the new one is built, and the image is written under its
final name from the start: after a failed run, what lies in `.build/release/` under the release's name may be
an image that did not pass every step. Go by the exit code.

## Updates: the feed and the keys

`AppUpdater` reads the feed URL and the public EdDSA key from `Info.plist`, which takes them from
`Signing.xcconfig`:

| Variable | Is |
|---|---|
| `MURMURLY_SU_FEED_URL` | the `appcast.xml` of the latest GitHub release |
| `MURMURLY_SU_DOWNLOAD_BASE` | the release download URL up to `…/download/v`; the script appends `<version>/` and the image's name |
| `MURMURLY_SU_PUBLIC_KEY` | the public half of the EdDSA key; empty means the updater is never created |

A fork sets its own three values. `//` starts a comment in an xcconfig, hence `https:/$()/…`.

The appcast step runs last, on the final image: stapling changes the DMG, and Sparkle checks its exact bytes.
`generate_appcast` (from Sparkle's tools in the build folder's `SourcePackages/artifacts`) gets a folder with
this image alone and no earlier appcast, so the feed offers exactly this version; `RELEASE_NOTES.md`, copied
beside the image under its name, is embedded. The private key comes from the login keychain, or from a file
named by `SPARKLE_PRIVATE_KEY_FILE` (for a machine whose keychain stays locked). The result counts only if it
holds both a `sparkle:edSignature` and the feed's own signature (the app has `SURequireSignedFeed`);
otherwise the file is removed.

Without a public key, without Sparkle's tools or without a matching private key the script still ends with
exit code 0 and `Release ready`, and the last line says `No appcast: …`. The earlier `appcast.xml` is already
gone by then. Read that line before publishing.

Creating the key, once per project: run the script once so SwiftPM fetches Sparkle's tools, run
`generate_keys` (it stores the private key in the login keychain and prints the public one), put the public
one into `Signing.xcconfig`, and export the private one with `generate_keys -x <file>` to keep offline and out
of git. Without it no update reaches ad-hoc-signed copies.

## Publishing, by hand

The scripts check none of this:

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Sparkle compares the build
   number, and the app asks for Accessibility again at the first launch of a new `CFBundleVersion`.
2. Rewrite `RELEASE_NOTES.md` for the version; commit.
3. Run `scripts/release.sh` with Developer ID and the notary profile; check the exit code and the appcast
   line.
4. Create the GitHub release tagged `v<MARKETING_VERSION>` and upload the DMG and `appcast.xml`: the feed URL
   reads the appcast of the latest release, and the appcast links the DMG by that tag.

## What is pinned

| Thing | How |
|---|---|
| WhisperKit, KeyboardShortcuts, FluidAudio, Sparkle, WebRTCAEC3, the MCP swift-sdk | `exactVersion` in `project.yml` |
| Their own dependencies | by those packages' manifests; `Package.resolved` is not tracked |
| dmgbuild, ds-store, mac-alias | exact versions in `release.sh` |
| Speech models | Hugging Face revisions in `ModelDownloader` |

`THIRD_PARTY_NOTICES.md` lists the packages and models with their versions and travels inside the bundle;
update it with every pin.

## CI

`.github/workflows/ci.yml` runs on `macos-26`: `xcodegen generate`, then the `Murmurly` scheme with
`-only-testing:MurmurlyTests`, ad-hoc signed, Debug. It fails unless the log has a line `Executed N tests,
with 0 failures` with N above zero. It does not run UI tests (a hosted runner has neither focus nor privacy
grants), does not build the `MurmurlyStageGate` scheme and does not build Release; code that compiles only in
Debug is first seen by `install.sh` or `release.sh`.

## Why it is this way

- **A clone in `/private/tmp`.** A binary keeps the paths it was compiled at (Swift's `#file` in the packages,
  the debug map of every object file). Version 0.2 carried 721 paths into its builder's home folder; a
  `/private/tmp` path names no one.
- **The whole image is searched**, the `.DS_Store` and the picture included: a `.DS_Store` written from a home
  folder can point into it too.
- **The Finder window is written by dmgbuild for the very volume it creates.** The picture is found through an
  alias in `.DS_Store` that names the volume; a `.DS_Store` copied from another image left the window without
  its picture on another Mac. dmgbuild also writes a bookmark beside the alias; Finder on macOS 26.5 did not
  resolve it and drew no picture, so the settings turn the bookmark off. The picture is light: Finder draws a
  window with a picture in the light appearance even in Dark Mode.
- **Three attempts at the image.** `hdiutil` occasionally records an empty chunk past the end of the data fork
  and then rejects its own image; it does not reproduce on demand, so a broken image is rebuilt and only a
  verified one goes on.
- **`disable-library-validation`.** An ad-hoc or self-signed build has no Team ID, so library validation
  refuses the embedded `Sparkle.framework` and the app dies at launch. A Developer ID build has one Team ID
  throughout and must keep validation on.
- **Hardened Runtime off in Debug.** XCTest injects libraries, and without a Team ID validation cannot accept
  them.
- **`get-task-allow`.** Xcode can inject it into an ordinary build; it permits debugger attachment and code
  injection, and notarization refuses it.
- **The helper is signed on its own.** An agent or a terminal launches it directly, so it carries its own
  hardened runtime and timestamp.
- **`install.sh` never kills.** The running executable must keep its bundle until it exits, and a recording
  must be saved first; a timeout leaves the installed app and its privacy identity untouched.
- **`~/Applications` for a source build** needs no administrator; a downloaded image goes to `/Applications`.
  Both count as installed.
