#!/usr/bin/env bash
# Build (if needed) and copy SkyBg.saver into ~/Library/Screen Savers/.
# After install, you must pick "SkyBg" once in System Settings -> Lock Screen -> Screen Saver.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAVER="$HERE/SkyBg.saver"
DST_DIR="$HOME/Library/Screen Savers"
DST="$DST_DIR/SkyBg.saver"

[[ -d "$SAVER" ]] || "$HERE/scripts/build-saver.sh"

mkdir -p "$DST_DIR"
rm -rf "$DST"
cp -R "$SAVER" "$DST"

echo "installed $DST"
echo
echo "next:"
echo "  open 'x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension'"
echo "  scroll to Screen Saver, pick 'SkyBg'"
