#!/bin/zsh
# Builds Void Notes Beta in Release and puts it in /Applications, next to Void Notes (its own
# app: its own notes, its own settings, its own synchronisation folder); quits the beta first if
# it is running, and opens the new one.
#   ./scripts/install-beta.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void Notes Beta.app"
TARGET="/Applications/Void Notes Beta.app"

echo "→ Compilation Release de la bêta…"
# arm64 alone, like the app: without it the separation of voices' package (Packages/VoidVoices)
# is built for Intel too. Its dependency (FluidAudio) is fetched by Xcode the first time.
xcodebuild -project VoidNotes.xcodeproj -target VoidNotesBeta -configuration Release -arch arm64 \
  COMPILER_INDEX_STORE_ENABLE=NO SYMROOT="$DERIVED/Build/Products" OBJROOT="$DERIVED/Build/Intermediates.noindex" build -quiet

"$ROOT/scripts/copy-to-applications.sh" "$APP"
# Right after the old copy quits, Launch Services may still refuse (error -600): once more.
open "$TARGET" 2>/dev/null || { sleep 1; open "$TARGET"; }
