#!/usr/bin/env bash
# Build and run bin/skybg once. Pass --watch to re-run on file save, --no-set to skip apply.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/config.sh"
export WEBCAM_URL CACHE_DIR LOG_DIR LOG_LEVEL RAW_CROP_TOP CANVAS_FIT CANVAS_ANCHOR BLUR_RADIUS COLOR_SATURATION COLOR_BRIGHTNESS

WATCH=0
for arg in "$@"; do
  case "$arg" in
    --watch)    WATCH=1 ;;
    --no-set)   export SKYBG_NO_APPLY=1 ;;
    -h|--help)  echo "usage: $0 [--watch] [--no-set]"; exit 0 ;;
    *)          echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

run() {
  "$HERE/scripts/build.sh" >/dev/null
  "$HERE/bin/skybg"
}

if (( WATCH )); then
  command -v fswatch >/dev/null \
    || { echo "fswatch not installed: brew install fswatch" >&2; exit 1; }
  run || true
  fswatch -o "$HERE/scripts" "$HERE/config.sh" \
    | while read -r _; do
        echo "--- change detected, rebuilding + running ---"
        run || true
      done
else
  run
fi
