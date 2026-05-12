#!/usr/bin/env bash
# Build SkyBg.saver bundle from scripts/screensaver.swift, ad-hoc sign it,
# and leave it at the repo root. Use scripts/install-saver.sh to deploy.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAVER="$HERE/SkyBg.saver"
MACOS_DIR="$SAVER/Contents/MacOS"
BIN="$MACOS_DIR/SkyBg"

rm -rf "$SAVER"
mkdir -p "$MACOS_DIR"

/usr/bin/swiftc -O \
  -framework AppKit \
  -framework Foundation \
  -framework ScreenSaver \
  -emit-library -Xlinker -bundle \
  "$HERE/scripts/screensaver.swift" \
  -o "$BIN"

cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>SkyBg</string>
  <key>CFBundleDisplayName</key>
  <string>SkyBg</string>
  <key>CFBundleIdentifier</key>
  <string>com.skybg.screensaver</string>
  <key>CFBundleExecutable</key>
  <string>SkyBg</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>NSPrincipalClass</key>
  <string>SkyBgScreenSaverView</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$SAVER" >/dev/null

echo "built $SAVER"
echo "install with: ./scripts/install-saver.sh"
