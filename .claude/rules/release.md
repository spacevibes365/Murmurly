---
paths:
  - "scripts/**"
  - "project.yml"
  - "Signing.xcconfig"
  - "Murmurly.entitlements"
  - "Murmurly-Info.plist"
  - ".github/**"
---

# Build settings, signing and the release scripts

Cross-cutting. `project.yml` generates the Xcode project; `scripts/release.sh` builds what users download and
what Sparkle installs over their copy.

- **A release is built from a fresh clone of the committed HEAD in `/private/tmp`**, its build folder there
  too. A binary keeps the paths it was compiled at, and a path in a home folder names its owner. Do not add
  a way to build the image from the working tree.
- **Every image is searched for home paths before it counts** (`check_image_paths`, again after stapling;
  `--check-dmg` runs it alone). A hit stops the release; never soften it to a warning.
- **No certificate name, team or key in `project.yml`.** Signing goes through
  `MURMURLY_CODE_SIGN_IDENTITY` (`Signing.xcconfig`, ad-hoc by default, overridden in the git-ignored
  `Local.xcconfig`). Secrets reach the scripts as a keychain profile name or a file path, never as text.
- **No `get-task-allow` in anything shipped.** Release sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for
  the app and the helper, and `release.sh` refuses a bundle whose Mach-O carries it: notarization does too.
- **`disable-library-validation` is for builds without a Team ID only.** `release.sh` removes it when it
  re-signs with Developer ID and fails if it is still there: code loaded into an app with microphone and
  Accessibility grants inherits them.
- **Re-sign inside out.** Sparkle's XPC services, `Autoupdate` and `Updater.app`, then the framework, then
  `Contents/Helpers/murmurly` (hardened runtime, the app's team), then the app. Those paths follow the
  pinned Sparkle; reread them when its version changes.
- **Never fall back.** With `DEVELOPER_ID` set, a missing `NOTARY_PROFILE`, a rejected notarization or a
  failed staple stops the script; an unsigned image is only ever built on purpose and says so in its name.
- **The appcast is generated last, from the verified image alone.** Stapling changes the DMG and Sparkle
  checks its exact bytes; `generate_appcast` gets a folder with this one image, and an entry without
  `sparkle:edSignature` and a signed feed is deleted, not published.
- **`//` starts a comment in an xcconfig.** URLs and a key containing it are written with `/$()/`; a
  truncated `SUPublicEDKey` turns updates off for good, and `release.sh` checks it is 32 bytes.
- **Sparkle compares `CURRENT_PROJECT_VERSION`.** A release raises it together with `MARKETING_VERSION`;
  the tag is `v<MARKETING_VERSION>`, which the appcast's download link names.
- **Every direct package is pinned with `exactVersion`**, and dmgbuild with its two libraries by exact
  version. `Package.resolved` is not tracked, so `project.yml` is the only pin.
- **Warnings are errors, Swift 6 with complete concurrency checking, `ARCHS = arm64`** in every target; a
  new target copies those settings.
- **`install.sh` never forces the running copy down**: SIGTERM, wait, and no replacement while its process
  lives. Never add SIGKILL.
- **CI must fail on zero tests**: keep `set -o pipefail` and the `Executed [1-9]… with 0 failures` check.

How a release is made: `reference/release.md`.
