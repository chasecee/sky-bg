#!/usr/bin/env bash
# Render docs/preview.gif from the live source MP4 using the current canvas
# config. Dev tool — independent of the runtime agent. Re-run any time you
# want to refresh the README artifact.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/config.sh"
export WEBCAM_URL CACHE_DIR LOG_DIR LOG_LEVEL \
       RAW_CROP_TOP CANVAS_FIT CANVAS_ANCHOR BLUR_RADIUS \
       COLOR_SATURATION COLOR_BRIGHTNESS

cd "$HERE"
exec /usr/bin/swift "$HERE/scripts/gen-preview.swift" "$@"
