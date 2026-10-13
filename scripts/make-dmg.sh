#!/bin/zsh
# Builds Void Notes in Release and packages it as build/Void-Notes-<version>.dmg
# (Void Notes.app + a shortcut to /Applications, to install by drag and drop).
#   ./scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void Notes.app"

echo "→ Compilation Release…"
# The Mac target alone: the scheme also builds the iPhone app, whose signing needs a provisioning
# profile that xcodebuild can't make on its own (Xcode can).
xcodebuild -project VoidNotes.xcodeproj -target VoidNotes -configuration Release \
  SYMROOT="$DERIVED/Build/Products" OBJROOT="$DERIVED/Build/Intermediates.noindex" build -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT/build/Void-Notes-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "→ Préparation de l'image disque…"
ditto "$APP" "$STAGING/Void Notes.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Void Notes $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
