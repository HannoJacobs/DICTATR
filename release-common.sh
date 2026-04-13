#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="DICTATR"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.hannojacobs.DICTATR"
SCHEME_NAME="DICTATR"
WORKSPACE_PATH="$SCRIPT_DIR/.swiftpm/xcode/package.xcworkspace"
SOURCE_PLIST="$SCRIPT_DIR/Sources/DICTATR/Info.plist"
BUILD_DIR="$SCRIPT_DIR/build-release"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
ARCHIVE_BINARY_PATH="$ARCHIVE_PATH/Products/usr/local/bin/$APP_NAME"
ARCHIVED_APP_PATH="$BUILD_DIR/$APP_BUNDLE"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="$SCRIPT_DIR/$DMG_NAME"
INSTALLED_APP_PATH="/Applications/$APP_BUNDLE"
LATEST_LOG_PATH="$HOME/Library/Application Support/DICTATR/Logs/latest.log"
ACCESSIBILITY_SETTINGS_URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

RELEASE_CONFIG_FILE="${DICTATR_RELEASE_CONFIG:-$SCRIPT_DIR/release.env}"
if [ -f "$RELEASE_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$RELEASE_CONFIG_FILE"
fi

DICTATR_CODESIGN_IDENTITY="${DICTATR_CODESIGN_IDENTITY:-}"
DICTATR_CODESIGN_MODE="${DICTATR_CODESIGN_MODE:-developer_id}"
DICTATR_SPCTL_EXPECT="${DICTATR_SPCTL_EXPECT:-}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

note() {
    echo "==> $*"
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
}

require_file() {
    local path="$1"
    [ -e "$path" ] || fail "Missing required path: $path"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

app_version() {
    plist_value "$SOURCE_PLIST" "CFBundleShortVersionString"
}

app_build() {
    plist_value "$SOURCE_PLIST" "CFBundleVersion"
}

assert_release_config() {
    case "$DICTATR_CODESIGN_MODE" in
        developer_id)
            [ -n "$DICTATR_CODESIGN_IDENTITY" ] || fail "DICTATR_CODESIGN_IDENTITY is not set. Create $RELEASE_CONFIG_FILE from release.env.example with your Developer ID Application identity."
            ;;
        adhoc)
            ;;
        *)
            fail "Unsupported DICTATR_CODESIGN_MODE value: $DICTATR_CODESIGN_MODE"
            ;;
    esac
    [ -n "$DICTATR_SPCTL_EXPECT" ] || fail "DICTATR_SPCTL_EXPECT is not set. Set it to 'accepted', 'rejected', or 'skip' in $RELEASE_CONFIG_FILE."
}

codesign_identity_label() {
    if [ "$DICTATR_CODESIGN_MODE" = "adhoc" ]; then
        echo "-"
    else
        echo "$DICTATR_CODESIGN_IDENTITY"
    fi
}

assert_bundle_metadata() {
    local app_path="$1"
    local actual_bundle_id
    actual_bundle_id="$(plist_value "$app_path/Contents/Info.plist" "CFBundleIdentifier")"
    [ "$actual_bundle_id" = "$BUNDLE_ID" ] || fail "Unexpected bundle identifier for $app_path: $actual_bundle_id"
}

verify_signed_app() {
    local app_path="$1"
    local codesign_output requirement_output spctl_output spctl_rc

    require_file "$app_path"
    assert_bundle_metadata "$app_path"

    note "codesign metadata for $app_path"
    codesign_output="$(codesign -dv --verbose=4 "$app_path" 2>&1)" || fail "codesign metadata read failed for $app_path"
    printf '%s\n' "$codesign_output"

    grep -q "Identifier=$BUNDLE_ID" <<<"$codesign_output" || fail "codesign identifier mismatch for $app_path"
    grep -q "Info.plist=not bound" <<<"$codesign_output" && fail "codesign metadata shows Info.plist is not bound for $app_path"

    note "designated requirement for $app_path"
    requirement_output="$(codesign -d -r- "$app_path" 2>&1)" || fail "designated requirement read failed for $app_path"
    printf '%s\n' "$requirement_output"

    if grep -Eq '^# designated => cdhash H"' <<<"$requirement_output"; then
        if [ "$DICTATR_CODESIGN_MODE" = "developer_id" ]; then
            fail "Designated requirement for $app_path is still cdhash-only; stable Accessibility trust will not persist across releases."
        fi
        note "Ad-hoc signing detected for $app_path; Accessibility trust will not persist across updates."
    fi

    note "strict signature verification for $app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path" || fail "codesign strict verification failed for $app_path"

    note "spctl assessment for $app_path"
    spctl_rc=0
    spctl_output="$(spctl -a -t exec -vv "$app_path" 2>&1)" || spctl_rc=$?
    printf '%s\n' "$spctl_output"

    case "$DICTATR_SPCTL_EXPECT" in
        accepted)
            [ "$spctl_rc" -eq 0 ] || fail "spctl was expected to accept $app_path but it did not."
            ;;
        rejected)
            [ "$spctl_rc" -ne 0 ] || fail "spctl was expected to reject $app_path but it was accepted."
            ;;
        skip)
            ;;
        *)
            fail "Unsupported DICTATR_SPCTL_EXPECT value: $DICTATR_SPCTL_EXPECT"
            ;;
    esac
}

requires_accessibility_regrant() {
    [ "$DICTATR_CODESIGN_MODE" = "adhoc" ]
}

open_accessibility_settings() {
    open "$ACCESSIBILITY_SETTINGS_URL"
}

archive_build_products_dir() {
    local archive_parent
    archive_parent="$(cd "$ARCHIVE_PATH/.." && pwd)"
    local archive_name
    archive_name="$(basename "$ARCHIVE_PATH" .xcarchive)"
    local derived_release_dir

    derived_release_dir="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*/ArchiveIntermediates/$archive_name/BuildProductsPath/Release" \
        -type d 2>/dev/null | head -1)"

    [ -n "$derived_release_dir" ] || fail "Could not locate ArchiveIntermediates build products for $archive_name"
    printf '%s\n' "$derived_release_dir"
}
