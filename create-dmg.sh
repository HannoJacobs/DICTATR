#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-common.sh"

assert_release_config
require_command xcodebuild
require_command codesign
require_command hdiutil
require_command ditto

require_file "$WORKSPACE_PATH"
require_file "$SOURCE_PLIST"
require_file "$CHANGELOG_PATH"
require_file "$APP_ENTITLEMENTS_PATH"
require_file "$SCRIPT_DIR/AppIcon.icns"
verify_verbose_changelog_entry

note "Building Release archive"
rm -rf "$BUILD_DIR" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -workspace "$WORKSPACE_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    archive

require_file "$ARCHIVE_BINARY_PATH"

RELEASE_PRODUCTS_DIR="$(archive_build_products_dir)"
require_file "$RELEASE_PRODUCTS_DIR"

note "Assembling app bundle from archived binary and Xcode resource bundles"
rm -rf "$ARCHIVED_APP_PATH"
mkdir -p "$ARCHIVED_APP_PATH/Contents/MacOS" "$ARCHIVED_APP_PATH/Contents/Resources"
ditto "$ARCHIVE_BINARY_PATH" "$ARCHIVED_APP_PATH/Contents/MacOS/$APP_NAME"
ditto "$SOURCE_PLIST" "$ARCHIVED_APP_PATH/Contents/Info.plist"
ditto "$SCRIPT_DIR/AppIcon.icns" "$ARCHIVED_APP_PATH/Contents/Resources/AppIcon.icns"

find "$RELEASE_PRODUCTS_DIR" -maxdepth 1 -name '*.bundle' -type d -print0 | while IFS= read -r -d '' bundle_path; do
    ditto "$bundle_path" "$ARCHIVED_APP_PATH/Contents/Resources/$(basename "$bundle_path")"
done

assert_bundle_metadata "$ARCHIVED_APP_PATH"

note "Signing archived app with $(codesign_identity_label)"
codesign_args=(
    --force
    --deep
    --entitlements "$APP_ENTITLEMENTS_PATH"
    --sign "$(codesign_identity_label)"
)

case "$DICTATR_CODESIGN_MODE" in
    developer_id)
        codesign_args+=(--options runtime)
        ;;
    adhoc)
        ;;
    *)
        fail "Unsupported DICTATR_CODESIGN_MODE value: $DICTATR_CODESIGN_MODE"
        ;;
esac

codesign "${codesign_args[@]}" "$ARCHIVED_APP_PATH"

verify_signed_app "$ARCHIVED_APP_PATH"

DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

note "Preparing DMG staging directory"
ditto "$ARCHIVED_APP_PATH" "$DMG_STAGING/$APP_BUNDLE"
ln -s /Applications "$DMG_STAGING/Applications"

note "Creating $DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

note "Created $DMG_PATH"
echo "Archive: $ARCHIVE_PATH"
echo "App: $ARCHIVED_APP_PATH"
echo "DMG: $DMG_PATH"
