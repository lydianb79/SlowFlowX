#!/usr/bin/env bash
# Builds SlowFlowX.app into ./build (release by default).
#   ./Scripts/build_app.sh            → release build
#   ./Scripts/build_app.sh debug      → debug build
#   ./Scripts/build_app.sh release --install   → also copies the app to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
INSTALL="${2:-}"
APP="build/SlowFlowX.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SlowFlowX" "$APP/Contents/MacOS/SlowFlowX"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: prefer a fresh iconutil build from the iconset, fall back to the bundled .icns
if command -v iconutil >/dev/null 2>&1 && [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" || cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [ "$INSTALL" = "--install" ]; then
  echo "▸ Installing to /Applications"
  rm -rf "/Applications/SlowFlowX.app"
  cp -R "$APP" /Applications/
fi

echo "✓ Done: $(pwd)/$APP"
echo "  Run it with:  open \"$APP\""
