#!/usr/bin/env bash
# Render docs/preview.gif from the live source MP4 using the current canvas
# config. Dev tool — independent of the runtime agent. Re-run any time you
# want to refresh the README artifact.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Preserve any externally-set WEBCAM_URL across config.sh's default assignment,
# so `WEBCAM_URL=... ./scripts/gen-preview.sh` still wins.
_USER_WEBCAM_URL="${WEBCAM_URL:-}"
source "$HERE/config.sh"
# Preview defaults to the 24h day mp4 — single GIF covers a full sunrise→
# sunset→night cycle. The runtime agent uses the hour mp4 for snappy updates;
# the README artifact wants maximum temporal range.
WEBCAM_URL="${_USER_WEBCAM_URL:-https://horel.chpc.utah.edu/data/station_cameras/wbbs_cam/wbbs_cam_day.mp4}"

export WEBCAM_URL CACHE_DIR LOG_DIR LOG_LEVEL \
       RAW_CROP_TOP CANVAS_FIT CANVAS_ANCHOR BLUR_RADIUS \
       COLOR_SATURATION COLOR_BRIGHTNESS

cd "$HERE"
exec /usr/bin/swift "$HERE/scripts/gen-preview.swift" "$@"
