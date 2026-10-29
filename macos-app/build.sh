#!/usr/bin/env bash
#
# Build WiFi Butler.app (and optionally a .dmg) using only tools that ship
# with macOS (swiftc + hdiutil). No third-party dependencies.
#
# Usage:
#   ./build.sh              build the .app and a .dmg
#   ./build.sh --no-dmg     build the .app only (no installer)
#   ./build.sh --install    also copy the .app into /Applications
#   flags combine, e.g.:  ./build.sh --no-dmg --install
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="WiFi Butler"
BIN_NAME="WifiAutoLogin"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/WiFi-Butler.dmg"

MAKE_DMG=1
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

rm -rf "$BUILD_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

# Deployment target must match LSMinimumSystemVersion in Info.plist so the
# built binary actually runs on the OS the app claims to support.
DEPLOY_TARGET="arm64-apple-macosx26.0"

echo "==> Compiling Swift sources (target ${DEPLOY_TARGET})"
swiftc -O \
  -target "${DEPLOY_TARGET}" \
  -o "${APP_DIR}/Contents/MacOS/${BIN_NAME}" \
  Sources/*.swift \
  -framework Cocoa -framework Security -framework ServiceManagement -framework CoreWLAN

cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Optional custom app icon: drop a square PNG named AppIcon.png next to this
# script and it becomes the bundle icon. Without it, the generic icon is used.
if [ -f AppIcon.png ]; then
  echo "==> Generating app icon from AppIcon.png"
  ICONSET="${BUILD_DIR}/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  gen() { sips -z "$2" "$2" AppIcon.png --out "${ICONSET}/$1" >/dev/null; }
  gen icon_16x16.png 16;      gen icon_16x16@2x.png 32
  gen icon_32x32.png 32;      gen icon_32x32@2x.png 64
  gen icon_128x128.png 128;   gen icon_128x128@2x.png 256
  gen icon_256x256.png 256;   gen icon_256x256@2x.png 512
  gen icon_512x512.png 512;   gen icon_512x512@2x.png 1024
  iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Flat bundle (no nested code), so plain --sign is enough; --deep is deprecated.
echo "==> Ad-hoc code signing"
codesign --force --sign - "${APP_DIR}"

if [ "$MAKE_DMG" = 1 ]; then
  echo "==> Building .dmg"
  STAGING="${BUILD_DIR}/dmg-staging"
  mkdir -p "$STAGING"
  cp -R "$APP_DIR" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
  rm -rf "$STAGING"
fi

if [ "$INSTALL" = 1 ]; then
  echo "==> Installing to /Applications"
  # Quit any running instance so we don't replace the bundle out from under it.
  pkill -x "$BIN_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP_DIR" "/Applications/"
fi

echo
echo "Done:"
echo "  App: ${APP_DIR}"
[ "$MAKE_DMG" = 1 ] && echo "  DMG: ${DMG_PATH}"
[ "$INSTALL" = 1 ]  && echo "  Installed: /Applications/${APP_NAME}.app"
echo
if [ "$INSTALL" = 1 ]; then
  echo "Launch it from Launchpad/Spotlight, or: open \"/Applications/${APP_NAME}.app\""
else
  echo "Run it with: open \"${APP_DIR}\"   (or drag it wherever you like)"
fi
