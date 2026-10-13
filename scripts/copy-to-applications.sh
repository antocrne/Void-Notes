#!/bin/zsh
# Puts a built Void Notes.app in /Applications, in place of the copy there. If that copy is
# running, it is quit first (politely, so the notes being written are saved) and not reopened.
# Called after every build of the VoidNotes scheme (Xcode or xcodebuild), and by install.sh.
#   ./scripts/copy-to-applications.sh "<path>/Void Notes.app"
set -euo pipefail

APP=${1:?"usage: $0 <path>/Void Notes.app"}
TARGET="/Applications/Void Notes.app"
BUNDLE_ID="app.void.notes"
RUNNING="$TARGET/Contents/MacOS/Void Notes"

[[ -d "$APP" ]] || { echo "Pas d'app à $APP"; exit 1; }
[[ "$APP" -ef "$TARGET" ]] && exit 0

if pgrep -f "$RUNNING" > /dev/null; then
  echo "→ Fermeture de la copie de /Applications…"
  osascript -e "tell application \"$TARGET\" to quit" || true
  for _ in {1..50}; do
    pgrep -f "$RUNNING" > /dev/null || break
    sleep 0.1
  done
fi

echo "→ Copie dans /Applications…"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
echo "✓ $TARGET ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET/Contents/Info.plist"), $(date '+%H:%M:%S'))"
