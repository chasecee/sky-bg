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

mkdir -p "$SAVER/Contents/Resources"

# Static thumbnail for the System Settings picker — macOS Sequoia/Tahoe pull
# this image rather than calling our draw(_:) for the small preview tile.
# Use the most-recent main-monitor wallpaper if one exists; otherwise skip.
THUMB_SRC=$(/bin/ls -t "$HERE/.cache/wallpaper-3-"*.heic "$HERE/.cache/wallpaper-3-"*.jpg 2>/dev/null | /usr/bin/head -1 || true)
if [[ -n "${THUMB_SRC:-}" && -f "$THUMB_SRC" ]]; then
  /usr/bin/sips -z 240 480 "$THUMB_SRC" --out "$SAVER/Contents/Resources/thumbnail.png" >/dev/null 2>&1 || true
fi

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

SIGN_IDENTITY="${SKYBG_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Use SHA-1 hash (uniquely identifies one cert even if names collide).
  SIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/grep "Developer ID Application:" \
    | /usr/bin/sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40}).*$/\1/' \
    | /usr/bin/head -1)
fi
[[ -n "$SIGN_IDENTITY" ]] || { echo "no Developer ID Application cert found in keychain (set SKYBG_SIGN_IDENTITY to override)"; exit 1; }

/usr/bin/codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SAVER" >/dev/null

echo "built $SAVER"
echo "  signed with: $SIGN_IDENTITY"
echo "  (spctl will report 'Unnotarized Developer ID' but amfid still accepts it for personal install)"
echo "install with: ./scripts/install-saver.sh"
