#!/usr/bin/env bash
# Defaults sourced by scripts/install.sh and test/run-once.sh.
# The compiled binary (bin/skybg) reads these values from its environment at runtime.

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ -f "$PROJECT_DIR/.env" ] && source "$PROJECT_DIR/.env"

# Local Thingino IP cam — main-stream JPEG snapshot (1920x1080) via API token
# (web UI → API key panel). Put WEBCAM_TOKEN=... in .env (gitignored).
# Substream (640x360) is /x/ch1.jpg; RTSP streams live at rtsp://.../ch0|ch1.
WEBCAM_URL="${WEBCAM_URL:-http://192.168.4.203/x/ch0.jpg?token=${WEBCAM_TOKEN:?set WEBCAM_TOKEN in .env}}"

# Public WBBS alternative:
# WEBCAM_URL="${WEBCAM_URL:-https://horel.chpc.utah.edu/data/station_cameras/wbbs_cam/wbbs_cam_hour.mp4}"

INTERVAL_SEC="${INTERVAL_SEC:-60}"

OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
HISTORY_DIR="${HISTORY_DIR:-$OUTPUT_DIR/history}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/.logs}"

LOG_LEVEL="${LOG_LEVEL:-info}"

# Pixels to crop off the top of the raw frame (removes any OSD banner).
RAW_CROP_TOP="${RAW_CROP_TOP:-38}"

# How the source maps onto the virtual canvas: cover | contain.
CANVAS_FIT="${CANVAS_FIT:-cover}"

# Vertical anchor of the source within the canvas: 0 = bottom, 0.5 = center, 1 = top.
# Horizontal is always centered.
CANVAS_ANCHOR="${CANVAS_ANCHOR:-0.5}"

# Blur radius applied before slicing. Single value = uniform.
# Comma list = progressive top->bottom, evenly distributed (e.g. "10,50" or "10,30,50"). 0 = sharp.
BLUR_RADIUS="${BLUR_RADIUS:-100,40,1,40,100}"

# CIColorControls. Saturation: multiplier (1.0 unchanged). Brightness: additive offset (0.0 unchanged).
COLOR_SATURATION="${COLOR_SATURATION:-1.0}"
COLOR_BRIGHTNESS="${COLOR_BRIGHTNESS:--0.05}"

# Chromatic channel shift in canvas px: R offset -X, G fixed, B offset +X along
# CHANNEL_SHIFT_ANGLE (degrees; 0 = R left / B right, 90 = R top / B bottom).
# Channels are recombined, then blurred. 0 = off.
CHANNEL_SHIFT="${CHANNEL_SHIFT:-110}"
CHANNEL_SHIFT_ANGLE="${CHANNEL_SHIFT_ANGLE:-45}"

# Optional day curve for the shift magnitude. Comma-separated HH:MM:value control
# points; the binary cosine-eases between them based on the current wall-clock time.
# When set, overrides CHANNEL_SHIFT. Angle is unchanged.
# 09:30-18:00 holds at 10 (focus), eases to 50 by 21:00, peaks at 150 midnight-5am,
# then fades back to 10 by 09:30.
CHANNEL_SHIFT_SCHEDULE="${CHANNEL_SHIFT_SCHEDULE:-09:30:10,18:00:10,21:00:50,00:00:150,05:00:80}"

# Composite trail of the last N frames (most-recent first, auto-normalized).
# "1" = no blend (hard swap each cycle, hash-skip enabled).
# "1,1" = 50/50 current+prev. "1,1,1" = last-3 equal blend.
# "3,2,1" = 3-frame decaying trail (newest heaviest).
# Length N >= 2 disables the hash-skip so the trail keeps advancing.
#BLEND_WEIGHTS="${BLEND_WEIGHTS:-8,4,2,1}"
BLEND_WEIGHTS="${BLEND_WEIGHTS:-1}"

mkdir -p "$OUTPUT_DIR" "$HISTORY_DIR" "$LOG_DIR"
