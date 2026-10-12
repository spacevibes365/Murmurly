#!/bin/bash

# Builds a Release copy from this checkout and installs it into ~/Applications,
# replacing the previous copy only after the running app has quit on its own.
#
# Signing comes from Signing.xcconfig: ad-hoc by default, or the certificate
# named in Local.xcconfig. The script verifies the bundle against whatever the
# build settings say, so it works the same for every clone.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
project_file="$project_root/Murmurly.xcodeproj"
derived_data="$project_root/.build/install-derived-data"
install_root="$HOME/Applications"
system_install_root="/Applications"

fail() {
    echo "install: $*" >&2
    exit 1
}

command_path() {
    command -v "$1" 2>/dev/null || fail "required tool not found: $1"
}

xcodegen_bin="$(command_path xcodegen)"
xcodebuild_bin="$(command_path xcodebuild)"
codesign_bin="$(command_path codesign)"
ditto_bin="$(command_path ditto)"
kill_bin="$(command_path kill)"
open_bin="$(command_path open)"
plutil_bin="$(command_path plutil)"
ps_bin="$(command_path ps)"

cd "$project_root"
"$xcodegen_bin" generate

echo "Building the Release configuration…"
"$xcodebuild_bin" \
    -project "$project_file" \
    -scheme Murmurly \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -destination 'platform=macOS,arch=arm64' \
    build

build_settings_json="$(
    "$xcodebuild_bin" \
        -project "$project_file" \
        -scheme Murmurly \
        -configuration Release \
        -derivedDataPath "$derived_data" \
        -destination 'platform=macOS,arch=arm64' \
        -showBuildSettings -json
)"
build_setting() {
    printf '%s' "$build_settings_json" | "$plutil_bin" -extract "0.buildSettings.$1" raw -o - -
}
target_build_dir="$(build_setting TARGET_BUILD_DIR)"
full_product_name="$(build_setting FULL_PRODUCT_NAME)"
expected_identifier="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
signing_identity="$(build_setting CODE_SIGN_IDENTITY)"
[[ -n "$target_build_dir" && -n "$full_product_name" && -n "$expected_identifier" && -n "$signing_identity" ]] \
    || fail "could not read the product path, bundle ID or signing identity from build settings"

source_app="$target_build_dir/$full_product_name"
[[ -d "$source_app" ]] || fail "build product not found: $source_app"

target_app="$install_root/$full_product_name"
target_executable="$target_app/Contents/MacOS/$(build_setting EXECUTABLE_NAME)"

# Two installed copies would fight over the hotkeys, the meeting watchdog and
# the archive, and each would re-register itself as the login item.
if [[ -e "$system_install_root/$full_product_name" ]]; then
    fail "another copy is installed at $system_install_root/$full_product_name; quit it and move it to the Trash first"
fi

mkdir -p "$install_root"
staging_root="$(mktemp -d "$install_root/.${full_product_name%.app}.install.XXXXXX")"
candidate_app="$staging_root/$full_product_name"
backup_app="$staging_root/previous.app"
had_previous=0
keep_staging=0

cleanup() {
    status=$?
    trap - EXIT
    if [[ $status -ne 0 && $had_previous -eq 1 && -e "$backup_app" ]]; then
        if [[ -e "$target_app" || -L "$target_app" ]]; then
            if ! rm -rf "$target_app"; then
                echo "install: rollback failed; the previous copy is kept at $backup_app" >&2
                exit "$status"
            fi
        fi
        if ! mv "$backup_app" "$target_app"; then
            echo "install: rollback failed; the previous copy is kept at $backup_app" >&2
            exit "$status"
        fi
        echo "install: the previous copy was restored" >&2
    fi
    if [[ $keep_staging -eq 1 && -e "$backup_app" ]]; then
        echo "install: the previous copy is kept at $backup_app" >&2
    else
        rm -rf "$staging_root"
    fi
    exit "$status"
}
trap cleanup EXIT

verify_bundle() {
    bundle="$1"
    if ! "$codesign_bin" --verify --deep --strict "$bundle"; then
        echo "install: the bundle signature failed strict verification" >&2
        return 1
    fi

    signature="$("$codesign_bin" -dv --verbose=4 "$bundle" 2>&1)"
    if [[ "$signing_identity" == "-" ]]; then
        if ! printf '%s\n' "$signature" | grep -Fqx "Signature=adhoc"; then
            echo "install: expected an ad-hoc signature" >&2
            return 1
        fi
    elif ! printf '%s\n' "$signature" | grep -Fqx "Authority=$signing_identity"; then
        echo "install: unexpected signing identity; expected '$signing_identity'" >&2
        return 1
    fi

    identifier="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$bundle/Contents/Info.plist"
    )"
    if [[ "$identifier" != "$expected_identifier" ]]; then
        echo "install: unexpected bundle ID: $identifier" >&2
        return 1
    fi
}

signature_field() {
    local bundle="$1"
    local key="$2"
    local signature
    local line

    signature="$("$codesign_bin" -dv --verbose=4 "$bundle" 2>&1)" || return 1
    while IFS= read -r line; do
        case "$line" in
            "$key="*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done <<< "$signature"
    return 1
}

report_privacy_grant_state() {
    local previous_cdhash="$1"
    local installed_cdhash="$2"
    local team_identifier="$3"

    if [[ "$team_identifier" != "not set" ]]; then
        echo "Privacy grants: TeamIdentifier=$team_identifier, CDHash=$installed_cdhash"
        return
    fi

    echo "Privacy grants: no TeamIdentifier; current CDHash=$installed_cdhash"
    if [[ -z "$previous_cdhash" ]]; then
        echo "Privacy grants: first install or unknown previous CDHash — the app checks its grants at launch."
    elif [[ "$previous_cdhash" != "$installed_cdhash" ]]; then
        echo "Privacy grants: CDHash changed ($previous_cdhash → $installed_cdhash); a previously enabled Accessibility grant may still point at the old binary."
    else
        echo "Privacy grants: CDHash unchanged; the app still checks the actual grant at launch."
    fi
    echo "The app asks for Accessibility itself when it is missing; the menu-bar menu and Settings offer it again."
    if [[ "$signing_identity" == "-" ]]; then
        echo "Ad-hoc signature: macOS asks for Microphone and Accessibility again after every rebuild."
        echo "A stable certificate named in Local.xcconfig (see Signing.xcconfig) keeps most grants; Accessibility may still need re-enabling after an update."
    fi
}

installed_process_pids() {
    local pid
    local executable

    # Do not use `ps | grep -q` here: with pipefail, grep may close the pipe
    # after a match and ps can then exit on SIGPIPE, turning a match into false.
    while read -r pid executable; do
        if [[ "$executable" == "$target_executable" ]]; then
            printf '%s\n' "$pid"
        fi
    done < <("$ps_bin" -axww -o pid= -o comm=)
}

pid_is_in_list() {
    local wanted="$1"
    local pids="$2"
    local pid

    while read -r pid; do
        [[ -n "$pid" && "$pid" == "$wanted" ]] && return 0
    done <<< "$pids"
    return 1
}

assert_installed_copy_is_stopped() {
    local running_pids
    running_pids="$(installed_process_pids)"
    [[ -z "$running_pids" ]] \
        || fail "the installed copy is still running (PID: ${running_pids//$'\n'/, }): it is finishing a recording or could not confirm it was saved (see its menu-bar menu); the bundle was not replaced"
}

stop_installed_copy() {
    local running_pids="$1"
    local pid

    [[ -n "$running_pids" ]] || return 0

    echo "Quitting the installed copy (PID: ${running_pids//$'\n'/, })…"
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        # The app turns SIGTERM into its ordinary quit: active recordings are
        # saved first, and quit is refused if that cannot be confirmed. Never
        # escalate to SIGKILL.
        "$kill_bin" -TERM "$pid" 2>/dev/null || true
    done <<< "$running_pids"

    # 30 s: the app's own deadline for saving recordings is 20 s.
    for _ in {1..120}; do
        [[ -z "$(installed_process_pids)" ]] && return 0
        sleep 0.25
    done

    assert_installed_copy_is_stopped
}

launch_and_verify_installed_copy() {
    local previous_pids="$1"
    local launched_pids
    local pid

    "$open_bin" -g "$target_app"
    for _ in {1..40}; do
        launched_pids="$(installed_process_pids)"
        if [[ -n "$launched_pids" ]]; then
            while read -r pid; do
                [[ -n "$pid" ]] || continue
                if pid_is_in_list "$pid" "$previous_pids"; then
                    fail "the previous process PID $pid is still alive after install; the new build did not start"
                fi
            done <<< "$launched_pids"
            echo "Installed and running: $target_app (new PID: ${launched_pids//$'\n'/, })"
            return 0
        fi
        sleep 0.25
    done

    fail "the bundle was installed, but no new process from $target_executable was seen within 10 seconds; it may still be starting, so nothing was rolled back"
}

echo "Preparing a full copy of the bundle…"
"$ditto_bin" "$source_app" "$candidate_app"
verify_bundle "$candidate_app" || fail "the new bundle was rejected before replacing anything"

previous_cdhash=""
if [[ -d "$target_app" ]]; then
    previous_cdhash="$(signature_field "$target_app" CDHash || true)"
fi

# The running executable must keep its bundle intact until it exits. Never force
# it down: a timeout leaves the installed app and its TCC identity untouched.
previous_installed_pids="$(installed_process_pids)"
stop_installed_copy "$previous_installed_pids"
# Runtime self-check of the core invariant: replacement is forbidden while any
# process whose executable is inside the installed bundle remains alive.
assert_installed_copy_is_stopped

if [[ -e "$target_app" || -L "$target_app" ]]; then
    mv "$target_app" "$backup_app"
    had_previous=1
fi
if ! mv "$candidate_app" "$target_app"; then
    fail "could not move the new bundle into place"
fi

if ! verify_bundle "$target_app"; then
    if [[ $had_previous -eq 0 ]]; then
        rm -rf "$target_app"
    fi
    fail "the installed bundle failed verification after the swap"
fi
installed_cdhash="$(signature_field "$target_app" CDHash)" \
    || fail "could not read the CDHash of the installed bundle"
installed_team_identifier="$(signature_field "$target_app" TeamIdentifier)" \
    || fail "could not read the TeamIdentifier of the installed bundle"

# Once launch is requested the new copy may already be running, so it is never
# rolled back from under it. Until its start is confirmed the previous copy stays
# on disk next to it instead of being deleted.
had_previous=0
keep_staging=1
launch_and_verify_installed_copy "$previous_installed_pids"
keep_staging=0

report_privacy_grant_state \
    "$previous_cdhash" \
    "$installed_cdhash" \
    "$installed_team_identifier"
