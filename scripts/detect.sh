#!/usr/bin/env bash
# Print the current display arrangement as detected by NSScreen.
# Debug-only — bin/skybg auto-detects this at runtime, no config to update.
set -euo pipefail

/usr/bin/swift - <<'SWIFT'
import AppKit
for s in NSScreen.screens {
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    let f = s.frame
    let scale = s.backingScaleFactor
    let pxW = Int(f.width * scale)
    let pxH = Int(f.height * scale)
    print("id=\(id) name=\"\(s.localizedName)\" origin=(\(Int(f.origin.x)),\(Int(f.origin.y))) size=\(Int(f.width))x\(Int(f.height))pt \(pxW)x\(pxH)px scale=\(scale)x")
}
SWIFT
