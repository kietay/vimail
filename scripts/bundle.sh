#!/bin/bash
# Packages the SwiftPM build as build/app.noindex/vimail.app (ad-hoc signed). Usage: scripts/bundle.sh [release|debug]
set -euo pipefail
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
# ".noindex" keeps Spotlight from listing this dev copy next to the installed app.
APP="$ROOT/build/app.noindex/vimail.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/vimail" "$APP/Contents/MacOS/vimail"
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ "$CONFIG" = "debug" ]; then
  # Debug builds are a separate app to macOS (and use ~/Library/Application Support/vimail-debug),
  # so they never stand in for the installed vimail.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.vimail.app.debug" -c "Set :CFBundleName vimail-debug" "$APP/Contents/Info.plist"
fi
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
