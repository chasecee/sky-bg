#!/bin/sh
# Delete wallpaper-agent BMP cache entries older than 5 minutes.
# Run via a separate launchd agent so the system shell (not skybg) owns the
# access — platform-signed binaries are not subject to kTCCServiceSystemPolicyAppData.
CACHE_DIR="$HOME/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image"
[ -d "$CACHE_DIR" ] && /usr/bin/find "$CACHE_DIR" -maxdepth 1 -name "*.bmp" -mmin +5 -delete 2>/dev/null
exit 0
