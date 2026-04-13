#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-common.sh"

assert_release_config
require_command ditto
require_command open
require_command rg
require_command stat
require_command tccutil

require_file "$ARCHIVED_APP_PATH"

note "Installing $ARCHIVED_APP_PATH to $INSTALLED_APP_PATH"
rm -rf "$INSTALLED_APP_PATH"
ditto "$ARCHIVED_APP_PATH" "$INSTALLED_APP_PATH"

verify_signed_app "$INSTALLED_APP_PATH"

expected_version="$(app_version)"
expected_build="$(app_build)"
previous_log_mtime=0

if [ -e "$LATEST_LOG_PATH" ]; then
    previous_log_mtime="$(stat -f '%m' "$LATEST_LOG_PATH")"
fi

note "Launching installed app"
open "$INSTALLED_APP_PATH"

launch_verified=0
for _ in {1..30}; do
    if [ -e "$LATEST_LOG_PATH" ]; then
        current_log_mtime="$(stat -f '%m' "$LATEST_LOG_PATH")"
        if [ "$current_log_mtime" -ge "$previous_log_mtime" ] && \
           rg -q "applicationDidFinishLaunching .*bundlePath=$INSTALLED_APP_PATH .*version=$expected_version .*build=$expected_build" "$LATEST_LOG_PATH"; then
            launch_verified=1
            break
        fi
    fi
    sleep 1
done

[ "$launch_verified" -eq 1 ] || fail "Launch log did not show bundlePath=$INSTALLED_APP_PATH version=$expected_version build=$expected_build in $LATEST_LOG_PATH"

note "Launch verification evidence"
rg -n "applicationDidFinishLaunching .*bundlePath=$INSTALLED_APP_PATH .*version=$expected_version .*build=$expected_build" "$LATEST_LOG_PATH"
rg -n "applicationDidFinishLaunching .*accessibilityTrusted=(yes|no)" "$LATEST_LOG_PATH" || fail "Launch log did not record accessibilityTrusted status."

if requires_accessibility_regrant || rg -q "applicationDidFinishLaunching .*accessibilityTrusted=no" "$LATEST_LOG_PATH"; then
    if requires_accessibility_regrant; then
        note "Ad-hoc signing mode cannot preserve Accessibility trust across updates; resetting DICTATR's TCC entry and opening System Settings."
    else
        note "Accessibility trust is missing for the installed app; resetting TCC entry and opening System Settings."
    fi
    tccutil reset Accessibility "$BUNDLE_ID"
    open_accessibility_settings
    fail "Accessibility must be re-enabled for $BUNDLE_ID. Re-enable DICTATR in System Settings, relaunch it, and rerun install-release.sh."
fi

echo "Installed app verified at $INSTALLED_APP_PATH"
echo "Log evidence: $LATEST_LOG_PATH"
