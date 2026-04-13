#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-common.sh"

assert_release_config
require_command ditto
require_command open
require_command pgrep
require_command pkill
require_command readlink
require_command rg
require_command stat
require_command tccutil

require_file "$ARCHIVED_APP_PATH"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    note "Stopping running $APP_NAME processes before install"
    pkill -x "$APP_NAME" || true
    for _ in {1..15}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        fail "Could not stop running $APP_NAME processes before install."
    fi
fi

note "Installing $ARCHIVED_APP_PATH to $INSTALLED_APP_PATH"
rm -rf "$INSTALLED_APP_PATH"
ditto "$ARCHIVED_APP_PATH" "$INSTALLED_APP_PATH"

verify_signed_app "$INSTALLED_APP_PATH"

expected_version="$(app_version)"
expected_build="$(app_build)"
previous_log_mtime=0
previous_log_target=""

if [ -e "$LATEST_LOG_PATH" ]; then
    previous_log_mtime="$(stat -f '%m' "$LATEST_LOG_PATH")"
    previous_log_target="$(readlink "$LATEST_LOG_PATH" || true)"
fi

note "Launching installed app"
open "$INSTALLED_APP_PATH"

launch_verified=0
for _ in {1..30}; do
    if [ -e "$LATEST_LOG_PATH" ]; then
        current_log_mtime="$(stat -f '%m' "$LATEST_LOG_PATH")"
        current_log_target="$(readlink "$LATEST_LOG_PATH" || true)"
        if [ "$current_log_mtime" -gt "$previous_log_mtime" ] && \
           [ "$current_log_target" != "$previous_log_target" ] && \
           rg -q "applicationDidFinishLaunching .*version=$expected_version .*build=$expected_build .*bundlePath=$INSTALLED_APP_PATH" "$LATEST_LOG_PATH"; then
            launch_verified=1
            break
        fi
    fi
    sleep 1
done

[ "$launch_verified" -eq 1 ] || fail "Launch log did not show version=$expected_version build=$expected_build bundlePath=$INSTALLED_APP_PATH in $LATEST_LOG_PATH"

note "Launch verification evidence"
rg -n "applicationDidFinishLaunching .*version=$expected_version .*build=$expected_build .*bundlePath=$INSTALLED_APP_PATH" "$LATEST_LOG_PATH"
rg -n "applicationDidFinishLaunching .*accessibilityTrusted=(yes|no)" "$LATEST_LOG_PATH" || fail "Launch log did not record accessibilityTrusted status."
rg -n "applicationDidFinishLaunching .*microphoneStatus=[^ ]+" "$LATEST_LOG_PATH" || fail "Launch log did not record microphoneStatus."

if rg -q "applicationDidFinishLaunching .*microphoneStatus=authorized" "$LATEST_LOG_PATH"; then
    note "Installed app retained microphone authorization."
else
    note "Installed app launch shows microphone authorization is not yet granted; DICTATR will surface microphone grant flow before recording."
fi

if rg -q "applicationDidFinishLaunching .*accessibilityTrusted=no" "$LATEST_LOG_PATH"; then
    note "Accessibility trust is missing for the installed app; resetting DICTATR's TCC entry and opening System Settings."
    tccutil reset Accessibility "$BUNDLE_ID"
    open_accessibility_settings
    note "Local permission step still required: re-enable Accessibility for $INSTALLED_APP_PATH, then continue verification."
    echo "Installed app verified at $INSTALLED_APP_PATH"
    echo "Log evidence: $LATEST_LOG_PATH"
    echo "Reminder: Accessibility still needs to be re-enabled for $INSTALLED_APP_PATH before accessibility-dependent behavior can be re-verified."
    exit 0
fi

if [ "$DICTATR_CODESIGN_MODE" = "adhoc" ]; then
    note "Installed app retained Accessibility trust on this ad-hoc install, but future reinstalls or updates may still require re-enabling it."
fi

echo "Installed app verified at $INSTALLED_APP_PATH"
echo "Log evidence: $LATEST_LOG_PATH"
