#!/usr/bin/env bash
# Build bin/skybg, render the launchd plist with current config, and bootstrap it.
# Pass --unload to remove.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/config.sh"

LABEL="com.skybg.wallpaper"
PLIST_SRC="$PROJECT_DIR/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

info() { echo "skybg: $*" >&2; }
fail() { info "$*"; exit 1; }

if [[ "${1:-}" == "--unload" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DST"
  info "unloaded $LABEL"
  exit 0
fi

[[ -f "$PLIST_SRC" ]] || fail "missing $PLIST_SRC"

"$SCRIPT_DIR/build.sh"

mkdir -p "$(dirname "$PLIST_DST")"
sed \
  -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
  -e "s|__INTERVAL__|$INTERVAL_SEC|g" \
  -e "s|__LOG_DIR__|$LOG_DIR|g" \
  -e "s|__CACHE_DIR__|$CACHE_DIR|g" \
  -e "s|__WEBCAM_URL__|$WEBCAM_URL|g" \
  -e "s|__LOG_LEVEL__|$LOG_LEVEL|g" \
  -e "s|__RAW_CROP_TOP__|$RAW_CROP_TOP|g" \
  -e "s|__CANVAS_FIT__|$CANVAS_FIT|g" \
  -e "s|__CANVAS_ANCHOR__|$CANVAS_ANCHOR|g" \
  -e "s|__BLUR_RADIUS__|$BLUR_RADIUS|g" \
  "$PLIST_SRC" > "$PLIST_DST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl enable "$DOMAIN/$LABEL"

info "installed $LABEL (interval=${INTERVAL_SEC}s)"
info "logs: $LOG_DIR/{stdout,stderr}.log"
