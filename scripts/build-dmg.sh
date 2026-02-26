#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="anterminal"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$BUILD_DIR/dmg"

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DMG_DIR"

# Build Release configuration.
# Note: The CMUX_TAG / shouldBlockUntaggedDebugLaunch check only applies to
# DEBUG builds (guarded by `#if DEBUG`), so Release builds do not require
# CMUX_TAG and will launch normally.
echo "==> Building Release..."
xcodebuild -project GhosttyTabs.xcodeproj \
    -scheme cmux \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    build

# Find the built app
APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "*.app" -maxdepth 5 -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find built app"
    exit 1
fi

echo "==> Found app at: $APP_PATH"

# Ensure tmux is accessible from the DMG-installed app.
# The app looks for tmux at /opt/homebrew/bin/tmux, /usr/local/bin/tmux,
# and /usr/bin/tmux (see TmuxSessionManager.tmuxPath).
# If the user has tmux installed via Homebrew, it will be found automatically.
# No additional bundling is needed since tmux is a system-level dependency.

# Copy to DMG staging
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG with proper volume name
echo "==> Creating DMG..."
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$BUILD_DIR/$APP_NAME.dmg"

echo "==> DMG created at: $BUILD_DIR/$APP_NAME.dmg"
echo "==> Done!"
