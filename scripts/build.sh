#!/usr/bin/env bash
# Compile scripts/skybg.swift and scripts/cleanup.swift into bin/ (skips
# compile if a binary is up to date).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$HERE/bin"

SIGN_IDENTITY="${SKYBG_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/grep "Developer ID Application:" \
    | /usr/bin/sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40}).*$/\1/' \
    | /usr/bin/head -1)
fi
[[ -n "$SIGN_IDENTITY" ]] || { echo "no Developer ID Application cert found in keychain (set SKYBG_SIGN_IDENTITY to override)"; exit 1; }

# TCC only persists app-data grants against a stable bundle identifier, so
# CLI binaries that touch other apps' containers embed an Info.plist section.
build() {
  local src="$HERE/scripts/$1" bin="$HERE/bin/$2" ident="$3" info="${4:-}"
  if [[ -f "$bin" && "$bin" -nt "$src" && ( -z "$info" || "$bin" -nt "$HERE/scripts/$info" ) && "${FORCE_BUILD:-}" != "1" ]]; then
    echo "$2 up to date (source unchanged; set FORCE_BUILD=1 to override)"
    return
  fi
  local extra=()
  [[ -n "$info" ]] && extra=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HERE/scripts/$info")
  /usr/bin/swiftc -O "$src" -o "$bin" "${extra[@]}"
  /usr/bin/codesign --force --options runtime --timestamp --identifier "$ident" --sign "$SIGN_IDENTITY" "$bin" >/dev/null
  echo "built $bin (signed: $SIGN_IDENTITY)"
}

build skybg.swift skybg com.skybg.wallpaper
build cleanup.swift skybg-cleanup com.skybg.cache-cleanup cleanup-info.plist
