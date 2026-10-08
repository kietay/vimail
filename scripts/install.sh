#!/bin/bash
# Installs build/app.noindex/vimail.app into /Applications (or ~/Applications if /Applications is not writable)
# and registers it with Launch Services so Spotlight, Launchpad and the Dock pick it up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/app.noindex/vimail.app"
[ -d "$APP" ] || { echo "Build the app first: make app"; exit 1; }

DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/vimail.app"

# Quit a running copy so it can be replaced. Mail data lives in Application Support and is kept.
osascript -e 'tell application id "dev.vimail.app" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x vimail >/dev/null || break; sleep 0.5; done

rm -rf "$DEST"
ditto "$APP" "$DEST"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST"
# Point Launch Services at the installed copy, not the build folder.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
touch "$DEST"
echo "Installed $DEST"
