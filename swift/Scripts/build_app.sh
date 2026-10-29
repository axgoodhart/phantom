#!/usr/bin/env bash
#
# Builds Phantom.app from the Swift package.
#
#   ./Scripts/build_app.sh                 # universal release build, ad-hoc signed
#   ./Scripts/build_app.sh --debug         # faster, native arch only
#   DEVELOPER_ID="Developer ID Application: NAME (TEAMID)" ./Scripts/build_app.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug"; ARCH_FLAGS=() ;;
    --native) ARCH_FLAGS=() ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP="$ROOT/build/Phantom.app"
CONTENTS="$APP/Contents"

echo "==> Building ($CONFIG)"
if ! swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"; then
  if [ ${#ARCH_FLAGS[@]} -gt 0 ]; then
    echo "==> Universal build failed; falling back to this machine's architecture"
    ARCH_FLAGS=()
    swift build -c "$CONFIG"
  else
    exit 1
  fi
fi
BINARY="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/Phantom"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/Phantom"

# Icon and font come from the repo root, shared with the Python build.
for asset in "$ROOT/../Phantomicon.icns" "$ROOT/Resources/Phantomicon.icns"; do
  [ -f "$asset" ] && cp "$asset" "$CONTENTS/Resources/Phantomicon.icns" && break
done
for asset in "$ROOT/../phantom/ui/Anxler.ttf" "$ROOT/Resources/Anxler.ttf"; do
  [ -f "$asset" ] && cp "$asset" "$CONTENTS/Resources/Anxler.ttf" && break
done

VERSION="2.0.0"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Phantom</string>
    <key>CFBundleDisplayName</key><string>Phantom</string>
    <key>CFBundleIdentifier</key><string>com.alexgoodhart.Phantom</string>
    <key>CFBundleExecutable</key><string>Phantom</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>Phantomicon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 https://alexgoodh.art</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Phantom needs Accessibility access to record and replay input events.</string>
    <key>NSAppSleepDisabled</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signing"
if [ -n "${DEVELOPER_ID:-}" ]; then
  # A stable Developer ID keeps the Accessibility grant across updates: TCC
  # ties the permission to the code signature, not the path.
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --sign - "$APP"
  echo "    (ad-hoc signed — macOS will ask for Accessibility again after each rebuild;"
  echo "     set DEVELOPER_ID to sign properly)"
fi

echo "==> Done: $APP"
du -sh "$APP" | sed 's/^/    /'
