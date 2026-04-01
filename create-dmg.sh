#!/bin/bash
set -euo pipefail

APP_NAME="DICTATR"
BUNDLE_ID="com.hannojacobs.DICTATR"
DMG_NAME="${APP_NAME}.dmg"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="build-release"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_PLIST="$SCRIPT_DIR/Sources/DICTATR/Info.plist"

# Find the Release binary from Xcode's DerivedData
BINARY=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Release/${APP_NAME}" -type f 2>/dev/null | head -1)

if [ -z "$BINARY" ]; then
    echo "Error: No Release build found."
    echo "In Xcode:"
    echo "  1. Product > Scheme > Edit Scheme"
    echo "  2. Select 'Run' on the left"
    echo "  3. Change Build Configuration to 'Release'"
    echo "  4. Close, then Cmd+B to build"
    exit 1
fi

echo "Found binary: $BINARY"

# Clean previous build artifacts
rm -rf "$BUILD_DIR" "$DMG_NAME"
mkdir -p "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$BUILD_DIR/$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "Included app icon"
fi

if [ ! -f "$SOURCE_PLIST" ]; then
    echo "Error: Missing source Info.plist at $SOURCE_PLIST"
    exit 1
fi

cp "$SOURCE_PLIST" "$BUILD_DIR/$APP_BUNDLE/Contents/Info.plist"

echo "Created $APP_BUNDLE"

# Create a temporary DMG directory with the app and an Applications symlink
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$BUILD_DIR/$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_NAME"

# Clean up
rm -rf "$BUILD_DIR"

echo ""
echo "Done! Created: $DMG_NAME"
echo ""
echo "To install, your colleagues should:"
echo "  1. Open the DMG"
echo "  2. Drag DICTATR to the Applications folder"
echo "  3. Right-click the app > Open (first time only, to bypass Gatekeeper)"
echo "  4. Grant Microphone and Accessibility permissions when prompted"
