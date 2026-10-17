#!/bin/bash

# Builds a Release DMG for distribution: the app plus an Applications shortcut.
#
#   scripts/release.sh
#       Ad-hoc signed. The file name says "unsigned": Gatekeeper will ask the
#       user to allow the app in System Settings → Privacy & Security.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
#       Signed with Developer ID, notarized and stapled. Any failure stops the
#       release; it never silently falls back to an unsigned DMG.
#       Create the profile once with `xcrun notarytool store-credentials`.
#
# Automatic updates (Sparkle). When the app carries a public EdDSA key, the
# DMG is also signed with its private half from the login keychain, and
# .build/release/appcast.xml offers it to installed copies. Upload both files
# to the GitHub release tagged v<MARKETING_VERSION>: SUFeedURL reads the
# appcast of the latest release, and the appcast links the DMG by that tag
# (MURMURLY_SU_DOWNLOAD_BASE in Signing.xcconfig), so a newer release
# published meanwhile cannot break a download. Sparkle compares
# CURRENT_PROJECT_VERSION (project.yml), so raise it for every release.
# RELEASE_NOTES.md in the project root, if present, becomes the "what's new"
# text of the update window (Markdown).
#
# The key, once per project, by whoever publishes the releases:
#   1. Run this script once: SwiftPM puts Sparkle's tools into
#      .build/release-derived-data/SourcePackages/artifacts/sparkle/Sparkle/bin/
#   2. `generate_keys` creates the private key in the login keychain and prints
#      the public one. Put it into Signing.xcconfig:
#          MURMURLY_SU_PUBLIC_KEY = <the printed key>
#      The first release then asks once to let generate_appcast use the key.
#   3. `generate_keys -x <file>` exports the private key. Keep that file
#      offline and out of git: without the key no update reaches copies signed
#      ad-hoc, they would have to be reinstalled by hand (Developer ID builds
#      can move to a new key, see Sparkle's "rotating signing keys").
#      On another Mac, `generate_keys -f <file>` puts it into the keychain.
# SPARKLE_PRIVATE_KEY_FILE=<file> signs with an exported key instead of the
# keychain, e.g. on a build machine whose keychain stays locked.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
project_file="$project_root/Murmurly.xcodeproj"
derived_data="$project_root/.build/release-derived-data"
output_dir="$project_root/.build/release"

fail() {
    echo "release: $*" >&2
    exit 1
}

developer_id="${DEVELOPER_ID:-}"
notary_profile="${NOTARY_PROFILE:-}"
if [[ -n "$developer_id" && -z "$notary_profile" ]]; then
    fail "DEVELOPER_ID is set but NOTARY_PROFILE is not; a Developer ID release must be notarized"
fi

cd "$project_root"
xcodegen generate

# Without DEVELOPER_ID the release is ad-hoc even when Local.xcconfig names a
# personal certificate: that certificate is meant for local installs only.
signing_overrides=("MURMURLY_CODE_SIGN_IDENTITY=-")
if [[ -n "$developer_id" ]]; then
    # Notarization requires a secure timestamp; Release already has the hardened runtime.
    signing_overrides=(
        "MURMURLY_CODE_SIGN_IDENTITY=$developer_id"
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
fi

echo "Building the Release configuration…"
rm -rf "$derived_data"
xcodebuild \
    -project "$project_file" \
    -scheme Murmurly \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -destination 'platform=macOS,arch=arm64' \
    "${signing_overrides[@]}" \
    build

build_settings_json="$(
    xcodebuild \
        -project "$project_file" \
        -scheme Murmurly \
        -configuration Release \
        -derivedDataPath "$derived_data" \
        -destination 'platform=macOS,arch=arm64' \
        "${signing_overrides[@]}" \
        -showBuildSettings -json
)"
build_setting() {
    printf '%s' "$build_settings_json" | plutil -extract "0.buildSettings.$1" raw -o - -
}
app="$(build_setting TARGET_BUILD_DIR)/$(build_setting FULL_PRODUCT_NAME)"
product_name="$(build_setting PRODUCT_NAME)"
version="$(build_setting MARKETING_VERSION)"
[[ -d "$app" ]] || fail "build product not found: $app"
public_key="$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
# A malformed key turns the updater off in every copy of this release for
# good: nothing could ever update it.
if [[ -n "$public_key" && "$(printf '%s' "$public_key" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')" != 32 ]]; then
    fail "SUPublicEDKey is not a 32-byte Ed25519 key: '$public_key' (an unescaped // in Signing.xcconfig cuts it short)"
fi

if [[ -n "$developer_id" ]]; then
    # Xcode re-signs Sparkle.framework when it embeds it, but not the helpers
    # inside it, which SwiftPM delivers ad-hoc signed and notarization rejects.
    # Inside out, as Sparkle documents: each seal covers what is nested in it,
    # so the framework and then the app are signed again after the helpers.
    sparkle="$app/Contents/Frameworks/Sparkle.framework"
    sign=(codesign --force --sign "$developer_id" --timestamp --options runtime)
    "${sign[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
    "${sign[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    "${sign[@]}" "$sparkle/Versions/B/Autoupdate"
    "${sign[@]}" "$sparkle/Versions/B/Updater.app"
    "${sign[@]}" "$sparkle"
    # Only builds without a Team ID need library validation off to load
    # Sparkle. Here Sparkle carries the same Team ID, and code loaded into an
    # app with microphone and Accessibility grants inherits them.
    entitlements="$(mktemp "${TMPDIR:-/tmp}/entitlements.XXXXXX")"
    codesign -d --entitlements - --xml "$app" > "$entitlements"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.cs.disable-library-validation" "$entitlements" 2>/dev/null || true
    "${sign[@]}" --entitlements "$entitlements" --preserve-metadata=requirements,flags "$app"
    rm -f "$entitlements"
fi

# What the signed code may carry, checked in every Mach-O file of the bundle:
# no get-task-allow, which permits debugger attachment and code injection,
# which Xcode can inject into an ordinary build (see project.yml, Release) and
# which notarization refuses; and in a Developer ID build, library validation
# on in the app itself. A signature that cannot be read stops the release.
while IFS= read -r -d '' code; do
    [[ "$(file -b "$code")" == Mach-O* ]] || continue
    signed="$(codesign -d --entitlements - --xml "$code" 2>/dev/null)" \
        || fail "could not read the signature of $code"
    [[ "$signed" != *"<key>com.apple.security.get-task-allow</key>"* ]] \
        || fail "$code must not let a debugger attach (get-task-allow)"
done < <(find "$app" -type f -perm +111 -print0)
if [[ -n "$developer_id" ]]; then
    signed="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)" \
        || fail "could not read the signature of $app"
    [[ "$signed" != *"<key>com.apple.security.cs.disable-library-validation</key>"* ]] \
        || fail "a Developer ID build must keep library validation on"
fi

codesign --verify --deep --strict "$app" || fail "the app signature failed strict verification"
architectures="$(lipo -archs "$app/Contents/MacOS/$(build_setting EXECUTABLE_NAME)")"
[[ "$architectures" == "arm64" ]] || fail "expected an arm64-only binary, got: $architectures"

if [[ -n "$developer_id" ]]; then
    dmg_name="$product_name-$version-arm64.dmg"
else
    dmg_name="$product_name-$version-arm64-unsigned.dmg"
fi
mkdir -p "$output_dir"
dmg="$output_dir/$dmg_name"
rm -f "$dmg"

staging="$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX")"
trap 'status=$?; rm -rf "$staging"; exit "$status"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"
# The window Finder opens: 128 pt icons, the app on the left, a grey arrow and
# Applications on the right. DS_Store was written once by dmgbuild 1.6.5, so the
# release needs nothing beyond hdiutil; background.tiff is 1x + 2x
# (tiffutil -cathidpicheck) and light, because Finder draws a window with a
# picture in the light appearance even in Dark Mode. DS_Store finds the picture
# by the volume name "Murmurly" and /.background.tiff, and the icons by the
# names Murmurly.app and Applications: change one and Finder silently shows its
# plain default window instead.
cp "$project_root/scripts/dmg/DS_Store" "$staging/.DS_Store"
cp "$project_root/scripts/dmg/background.tiff" "$staging/.background.tiff"

# hdiutil occasionally records an empty chunk at an offset past the end of the
# data fork; its own validator then rejects the whole image ("chunk data starts
# beyond end of data fork", seen 2026-10-08 on macOS 26.5). Why it happens is not
# known and it does not reproduce on demand, so a broken image is rebuilt from
# scratch and only a verified one is ever released.
echo "Creating ${dmg_name}…"
for attempt in 1 2 3; do
    rm -f "$dmg"
    hdiutil create \
        -volname "$product_name" \
        -srcfolder "$staging" \
        -fs HFS+ \
        -format UDZO \
        "$dmg"
    if hdiutil verify "$dmg"; then
        break
    fi
    echo "release: attempt $attempt produced an image that failed verification" >&2
    [[ $attempt -lt 3 ]] || fail "the disk image failed verification three times"
done

if [[ -n "$developer_id" ]]; then
    codesign --sign "$developer_id" --timestamp "$dmg"

    echo "Submitting for notarization (this can take several minutes)…"
    notary_result="$(
        xcrun notarytool submit "$dmg" \
            --keychain-profile "$notary_profile" \
            --wait \
            --output-format json
    )" || fail "notarytool submission failed: $notary_result"
    notary_status="$(printf '%s' "$notary_result" | plutil -extract status raw -o - -)"
    if [[ "$notary_status" != "Accepted" ]]; then
        submission_id="$(printf '%s' "$notary_result" | plutil -extract id raw -o - - || true)"
        fail "notarization status is '$notary_status'; see: xcrun notarytool log $submission_id --keychain-profile $notary_profile"
    fi

    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi

# Signed only now: stapling changes the DMG, and Sparkle checks the exact bytes.
appcast="$output_dir/appcast.xml"
rm -f "$appcast"
sparkle_tools="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ -z "$public_key" ]]; then
    appcast_result="No appcast: the app has no SUPublicEDKey, so updates are off in this build (see the top of this script)."
elif [[ ! -x "$sparkle_tools/generate_appcast" ]]; then
    appcast_result="No appcast: Sparkle's tools are not in $sparkle_tools."
else
    download_base="$(build_setting MURMURLY_SU_DOWNLOAD_BASE)$version/"
    # generate_appcast describes every archive in its folder and keeps what an
    # existing appcast lists, so it gets a folder with this DMG alone and no
    # previous appcast: the feed offers exactly this version.
    archives="$staging/appcast"
    mkdir "$archives"
    cp "$dmg" "$archives/"
    # Notes named after the archive are embedded into its entry.
    if [[ -f "$project_root/RELEASE_NOTES.md" ]]; then
        cp "$project_root/RELEASE_NOTES.md" "$archives/${dmg_name%.dmg}.md"
    fi
    appcast_args=(--download-url-prefix "$download_base" --embed-release-notes -o "$appcast")
    if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
        appcast_args+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
    fi
    # It only warns and writes an unsigned entry when the private key does not
    # match SUPublicEDKey; Sparkle would reject such an update, so it counts as
    # a failure. The feed itself is signed because the app has SURequireSignedFeed.
    if "$sparkle_tools/generate_appcast" "${appcast_args[@]}" "$archives" \
        && grep -q 'sparkle:edSignature=' "$appcast" \
        && grep -q '<!-- sparkle-signatures:' "$appcast"; then
        appcast_result="Appcast ready: $appcast"
    else
        rm -f "$appcast"
        appcast_result="No appcast: the DMG could not be signed for updates. The private key (login keychain or SPARKLE_PRIVATE_KEY_FILE) must exist and match SUPublicEDKey; see the top of this script."
    fi
fi

shasum -a 256 "$dmg"
echo "Release ready: $dmg"
echo "$appcast_result"
