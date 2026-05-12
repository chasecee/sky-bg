#!/usr/bin/env bash
# Defaults sourced by scripts/install.sh and test/run-once.sh.
# The compiled binary (bin/skybg) reads these values from its environment at runtime.

WEBCAM_URL="${WEBCAM_URL:-https://horel.chpc.utah.edu/data/station_cameras/wbbs_cam/wbbs_cam_current.jpg}"

INTERVAL_SEC="${INTERVAL_SEC:-300}"

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CACHE_DIR="${CACHE_DIR:-$PROJECT_DIR/.cache}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/.logs}"

LOG_LEVEL="${LOG_LEVEL:-info}"

# Pixels to crop off the top of the raw webcam image (removes the timestamp banner).
RAW_CROP_TOP="${RAW_CROP_TOP:-8}"

# How the source maps onto the virtual canvas: cover | contain.
CANVAS_FIT="${CANVAS_FIT:-cover}"

# Where to pin the source within the canvas: center | top | bottom | left | right.
CANVAS_ANCHOR="${CANVAS_ANCHOR:-center}"

# Gaussian blur radius applied to the canvas before slicing. 0 = sharp.
BLUR_RADIUS="${BLUR_RADIUS:-20}"

# CIColorControls. Saturation: multiplier (1.0 unchanged). Brightness: additive offset (0.0 unchanged).
COLOR_SATURATION="${COLOR_SATURATION:-1.05}"
COLOR_BRIGHTNESS="${COLOR_BRIGHTNESS:--0.04}"

mkdir -p "$CACHE_DIR" "$LOG_DIR"
