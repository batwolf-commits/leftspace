#!/bin/bash
# Builds a release LeftSpace.app and packages it into a distributable .dmg
# (drag-to-Applications) under ./dist/. Ad-hoc signed — see README for the
# first-launch Gatekeeper step. Add notarization here later.
#
#   ./Scripts/package-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) Build + assemble the app bundle.
"$ROOT/Scripts/make-app.sh" release

APP="$ROOT/build/LeftSpace.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
DMG="$DIST/LeftSpace-$VERSION.dmg"
mkdir -p "$DIST"

# 2) Stage a folder with the app + an Applications symlink (the classic layout).
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3) Build a compressed DMG.
rm -f "$DMG"
hdiutil create -volname "LeftSpace" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Built $DMG"
echo "  size: $(du -h "$DMG" | cut -f1)"