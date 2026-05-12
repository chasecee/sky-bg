#!/usr/bin/env bash
# Defaults sourced by scripts/install.sh and test/run-once.sh.
# The compiled binary (bin/skybg) reads these values from its environment at runtime.

# The hour mp4 streams the same 1280x960 footage as the day mp4 in a much smaller
# file (~16 MB vs ~58 MB), so AVFoundation's HTTP range reads fetch the trailing
# moov + last-frame samples faster. The last frame of the video is what we render.
WEBCAM_URL="${WEBCAM_URL:-https://horel.chpc.utah.edu/data/station_cameras/wbbs_cam/wbbs_cam_hour.mp4}"

INTERVAL_SEC="${INTERVAL_SEC:-60}"

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CACHE_DIR="${CACHE_DIR:-$PROJECT_DIR/.cache}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/.logs}"

LOG_LEVEL="${LOG_LEVEL:-info}"

# Pixels to crop off the top of the raw frame (removes the timestamp banner).
# Tuned to the 1280x960 mp4 source; was 8 for the legacy 500x375 jpg.
RAW_CROP_TOP="${RAW_CROP_TOP:-22}"

# How the source maps onto the virtual canvas: cover | contain.
CANVAS_FIT="${CANVAS_FIT:-cover}"

# Where to pin the source within the canvas: center | top | bottom | left | right.
CANVAS_ANCHOR="${CANVAS_ANCHOR:-bottom}"

# Blur radius applied before slicing. Single value = uniform.
# Comma list = progressive top->bottom, evenly distributed (e.g. "10,50" or "10,30,50"). 0 = sharp.
BLUR_RADIUS="${BLUR_RADIUS:-13,18}"

# CIColorControls. Saturation: multiplier (1.0 unchanged). Brightness: additive offset (0.0 unchanged).
COLOR_SATURATION="${COLOR_SATURATION:-1.05}"
COLOR_BRIGHTNESS="${COLOR_BRIGHTNESS:--0.04}"

mkdir -p "$CACHE_DIR" "$LOG_DIR"
