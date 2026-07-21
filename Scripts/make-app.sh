#!/bin/bash
# Builds StorageCleanerApp and assembles a runnable StorageCleaner.app bundle.
#
#   ./Scripts/make-app.sh            # debug build
#   ./Scripts/make-app.sh release    # optimized build
#
# The result is ./build/StorageCleaner.app, ad-hoc signed so it launches locally.
# (Distribution requires a Developer ID cert + notarization — see README.)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building StorageCleanerApp ($CONFIG)…"
swift build --product StorageCleanerApp -c "$CONFIG"

BINDIR="$(swift build --product StorageCleanerApp -c "$CONFIG" --show-bin-path | tail -n 1)"
BIN="$BINDIR/StorageCleanerApp"
APP="$ROOT/build/LeftSpace.app"

echo "▸ Assembling ${APP} …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StorageCleanerApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "$ROOT/Resources/AppIconColor.png" "$APP/Contents/Resources/AppIconColor.png"
cp "$ROOT/Resources/BuyMeACoffeeButton.png" "$APP/Contents/Resources/BuyMeACoffeeButton.png"

# Prefer the stable local identity (set up via Scripts/setup-signing.sh) so macOS
# keeps privacy grants between rebuilds. Fall back to ad-hoc if it isn't installed.
IDENTITY="StorageCleaner Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/storagecleaner-signing.keychain-db"
if [ -f "$SIGN_KEYCHAIN" ] && security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "▸ Signing with stable identity ($IDENTITY)…"
  security unlock-keychain -p storagecleaner "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    || { echo "  (stable signing failed; using ad-hoc)"; codesign --force --sign - "$APP" >/dev/null 2>&1 || true; }
else
  echo "▸ Ad-hoc signing (run ./Scripts/setup-signing.sh for a stable identity)…"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"
fi

echo "✓ Built $APP"
