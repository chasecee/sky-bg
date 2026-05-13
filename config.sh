#!/usr/bin/env bash
# Defaults sourced by scripts/install.sh and test/run-once.sh.
# The compiled binary (bin/skybg) reads these values from its environment at runtime.

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ -f "$PROJECT_DIR/.env" ] && source "$PROJECT_DIR/.env"

# Local Thingino IP cam — main-stream JPEG snapshot (1920x1080) via API token
# (web UI → API key panel). Put WEBCAM_TOKEN=... in .env (gitignored).
# Substream (640x360) is /x/ch1.jpg; RTSP streams live at rtsp://.../ch0|ch1.
WEBCAM_URL="${WEBCAM_URL:-http://192.168.4.20/x/ch0.jpg?token=${WEBCAM_TOKEN:?set WEBCAM_TOKEN in .env}}"

# Salt Lake WBBS public webcam. The hour mp4 streams the same 1280x960 footage
# as the day mp4 in a much smaller file (~16 MB vs ~58 MB), so AVFoundation's
# HTTP range reads fetch the trailing moov + last-frame samples faster. The
# last frame of the video is what we render.
# WEBCAM_URL="${WEBCAM_URL:-https://horel.chpc.utah.edu/data/station_cameras/wbbs_cam/wbbs_cam_hour.mp4}"

INTERVAL_SEC="${INTERVAL_SEC:-120}"

CACHE_DIR="${CACHE_DIR:-$PROJECT_DIR/.cache}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/.logs}"

LOG_LEVEL="${LOG_LEVEL:-info}"

# Pixels to crop off the top of the raw frame (removes any OSD banner).
RAW_CROP_TOP="${RAW_CROP_TOP:-40}"
# Tuned to the 1280x960 WBBS mp4 source; was 8 for the legacy 500x375 jpg.
# RAW_CROP_TOP="${RAW_CROP_TOP:-22}"

# How the source maps onto the virtual canvas: cover | contain.
CANVAS_FIT="${CANVAS_FIT:-cover}"

# Vertical anchor of the source within the canvas: 0 = bottom, 0.5 = center, 1 = top.
# Horizontal is always centered.
CANVAS_ANCHOR="${CANVAS_ANCHOR:-1}"
# Tuned for the WBBS sky framing across the tri-monitor canvas.
# CANVAS_ANCHOR="${CANVAS_ANCHOR:-0.333}"

# Blur radius applied before slicing. Single value = uniform.
# Comma list = progressive top->bottom, evenly distributed (e.g. "10,50" or "10,30,50"). 0 = sharp.
BLUR_RADIUS="${BLUR_RADIUS:-20,0,20}"

# CIColorControls. Saturation: multiplier (1.0 unchanged). Brightness: additive offset (0.0 unchanged).
COLOR_SATURATION="${COLOR_SATURATION:-1.0}"
COLOR_BRIGHTNESS="${COLOR_BRIGHTNESS:--0.0}"

mkdir -p "$CACHE_DIR" "$LOG_DIR"
