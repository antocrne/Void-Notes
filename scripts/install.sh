#!/bin/zsh
# Builds Void Notes in Release and puts it in /Applications, in place of the copy there; quits the
# app first if it is running, and opens the new one.
#   ./scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void Notes.app"
TARGET="/Applications/Void Notes.app"

echo "→ Compilation Release…"
# The Mac target alone: the scheme also builds the iPhone app, whose signing needs a provisioning
# profile that xcodebuild can't make on its own (Xcode can).
xcodebuild -project VoidNotes.xcodeproj -target VoidNotes -configuration Release \
  SYMROOT="$DERIVED/Build/Products" OBJROOT="$DERIVED/Build/Intermediates.noindex" build -quiet

"$ROOT/scripts/copy-to-applications.sh" "$APP"
# Right after the old copy quits, Launch Services may still refuse (error -600): once more.
open "$TARGET" 2>/dev/null || { sleep 1; open "$TARGET"; }
