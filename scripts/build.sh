#!/usr/bin/env bash
# Compile scripts/skybg.swift into bin/skybg (skips compile if binary is up to date).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$HERE/bin"
SRC="$HERE/scripts/skybg.swift"
BIN="$HERE/bin/skybg"
if [[ -f "$BIN" && "$BIN" -nt "$SRC" && "${FORCE_BUILD:-}" != "1" ]]; then
    echo "skybg up to date (source unchanged; set FORCE_BUILD=1 to override)"
    exit 0
fi
/usr/bin/swiftc -O "$SRC" -o "$BIN"

SIGN_IDENTITY="${SKYBG_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/grep "Developer ID Application:" \
    | /usr/bin/sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40}).*$/\1/' \
    | /usr/bin/head -1)
fi
[[ -n "$SIGN_IDENTITY" ]] || { echo "no Developer ID Application cert found in keychain (set SKYBG_SIGN_IDENTITY to override)"; exit 1; }
/usr/bin/codesign --force --options runtime --timestamp --identifier com.skybg.wallpaper --sign "$SIGN_IDENTITY" "$HERE/bin/skybg" >/dev/null

echo "built $HERE/bin/skybg (signed: $SIGN_IDENTITY)"
