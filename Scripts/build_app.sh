#!/usr/bin/env bash
# Builds SlowFlowX.app for Apple Silicon (arm64) and Intel (x86_64) as two separate apps.
#
#   ./Scripts/build_app.sh                         → release, both architectures
#   ./Scripts/build_app.sh debug                   → debug, both architectures
#   ./Scripts/build_app.sh release arm64           → only one architecture (arm64 | x86_64 | all)
#   ./Scripts/build_app.sh release all --install   → also copy the app for this Mac to /Applications
#
# Output:
#   build/arm64/SlowFlowX.app     + build/SlowFlowX-<version>-arm64.zip
#   build/x86_64/SlowFlowX.app    + build/SlowFlowX-<version>-x86_64.zip
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
ARCHS="${2:-all}"
INSTALL="${3:-}"
if [ "$ARCHS" = "all" ]; then ARCHS="arm64 x86_64"; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0)"
NATIVE="$(uname -m)"   # arm64 or x86_64

# A running copy would keep showing the old build ("open" just brings it to the front).
if pgrep -x SlowFlowX >/dev/null 2>&1; then
  echo "▸ Quitting the running SlowFlowX so the new build is used"
  osascript -e 'tell application "SlowFlowX" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x SlowFlowX >/dev/null 2>&1 || true
fi

# Build the .icns once (iconutil if available, otherwise the bundled one)
mkdir -p build
ICNS="build/AppIcon.icns"
if command -v iconutil >/dev/null 2>&1 && [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$ICNS" || cp Resources/AppIcon.icns "$ICNS"
else
  cp Resources/AppIcon.icns "$ICNS"
fi

for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unknown architecture: $ARCH (use arm64, x86_64 or all)"; exit 1 ;;
  esac

  echo "▸ Building $ARCH ($CONFIG)…"
  swift build -c "$CONFIG" --arch "$ARCH"
  BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

  APP="build/$ARCH/SlowFlowX.app"
  echo "▸ Assembling $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/SlowFlowX" "$APP/Contents/MacOS/SlowFlowX"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$APP/Contents/PkgInfo"

  echo "▸ Signing $ARCH (ad-hoc)"
  codesign --force --deep --sign - "$APP"

  BUILT_ARCHS="$(lipo -archs "$APP/Contents/MacOS/SlowFlowX")"
  if [ "$BUILT_ARCHS" != "$ARCH" ]; then
    echo "✗ Expected a $ARCH binary but got: $BUILT_ARCHS"; exit 1
  fi

  ZIP="build/SlowFlowX-$VERSION-$ARCH.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $APP  ($BUILT_ARCHS)  →  $ZIP"
done

if [ "$INSTALL" = "--install" ]; then
  if [ -d "build/$NATIVE/SlowFlowX.app" ]; then
    echo "▸ Installing the $NATIVE app to /Applications"
    rm -rf "/Applications/SlowFlowX.app"
    cp -R "build/$NATIVE/SlowFlowX.app" /Applications/
  else
    echo "⚠️  No $NATIVE build to install (build it with: ./Scripts/build_app.sh $CONFIG $NATIVE --install)"
  fi
fi

echo ""
echo "✓ Done."
if [ -d "build/$NATIVE/SlowFlowX.app" ]; then
  echo "  Run the version for this Mac ($NATIVE):  open \"build/$NATIVE/SlowFlowX.app\""
fi
