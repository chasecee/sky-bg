# sky-bg

Pulls a webcam frame on an interval (JPEG endpoint or the last frame of an MP4/MOV), fits it onto the virtual desktop arrangement, slices out each monitor's region, and sets it as the macOS wallpaper across a multi-monitor setup. Runs as a `launchd` user agent.

## Stack

A single compiled Swift binary (`bin/skybg`) does everything image-and-display:

- `URLSession` — JPEG fetch
- `AVFoundation` — `AVURLAsset` + `AVAssetImageGenerator` decode the trailing frame of remote MP4/MOV via HTTP range reads (no full-file download)
- `CryptoKit` — SHA-256 hash of the raw bytes for the "skip if unchanged" fast path
- `CoreImage` — banner crop, virtual-canvas mapping, per-monitor slice, optional `CIGaussianBlur` / `CIMaskedVariableBlur` (gradient stops), `CIColorControls` for saturation/brightness
- `NSScreen` — auto-detect the current display arrangement (no manual config)
- `NSWorkspace.setDesktopImageURL(_:for:options:)` — apply each slice (Apple's official wallpaper API; reliable on every macOS version)
- HEIF 10-bit + Display P3 output (`CIContext.writeHEIF10Representation`) — 1024 values per channel kills the banding 8-bit JPEG produces in smooth sky gradients

Bash is only used for install / dev tooling: `scripts/build.sh`, `scripts/install.sh`, `test/run-once.sh`, `scripts/detect.sh`. No Homebrew / Node / Python deps — every dependency ships in macOS.

## Model

1. Fetch the source. JPEG endpoints are pulled directly; MP4/MOV endpoints go through AVFoundation, which uses HTTP range requests to grab only the moov atom + trailing samples and decode the last frame.
2. SHA-256 the raw bytes; if it matches last cycle's hash, exit early. (`install.sh` deletes `.cache/last-hash` so any config edit forces a re-process.)
3. Trim the top `RAW_CROP_TOP` rows (the webcam's burned-in timestamp banner).
4. Auto-detect every monitor via `NSScreen` (origin in points, pixel size, screen handle).
5. Compute the bounding rect of all monitor frames — that's the virtual canvas.
6. Scale the source onto the canvas per `CANVAS_FIT` (`cover` fills + crops overflow, `contain` letterboxes), pinned per `CANVAS_ANCHOR`.
7. Apply `CIColorControls` (saturation/brightness) and optional blur. `BLUR_RADIUS` accepts a single number (uniform `CIGaussianBlur`) or a comma-separated stop list (`CIMaskedVariableBlur` driven by a vertical gradient mask, e.g. `5,20` = light at top, heavy at bottom).
8. For each monitor, slice the canvas at that monitor's point-rect, resample to its native pixel resolution, and write to `wallpaper-<id>-{A|B}.heic` (alternating slot — fresh path each cycle so the WindowServer refreshes, but bounded "Recent Wallpapers" entries).
9. Apply each slice via `NSWorkspace.setDesktopImageURL` against that monitor's `NSScreen`, dispatched concurrently across displays.

## Layout

```
sky-bg/
├── config.sh                  # defaults sourced by install.sh and test/run-once.sh
├── com.skybg.wallpaper.plist  # launchd template (placeholders substituted by install.sh)
├── scripts/
│   ├── skybg.swift            # the whole runtime pipeline
│   ├── screensaver.swift      # SkyBgScreenSaverView source for the .saver bundle
│   ├── build.sh               # swiftc -O scripts/skybg.swift -o bin/skybg
│   ├── build-saver.sh         # build SkyBg.saver bundle (Developer ID signed)
│   ├── install.sh             # build + render plist + launchctl bootstrap (--unload to remove)
│   ├── install-saver.sh       # copy SkyBg.saver into ~/Library/Screen Savers/
│   └── detect.sh              # debug: dump the current NSScreen arrangement
├── test/
│   └── run-once.sh            # rebuild + run once (--watch, --no-set)
├── bin/skybg                  # built locally, gitignored
├── SkyBg.saver/               # built locally, gitignored
├── .cache/                    # raw.jpg + wallpaper-<id>-{A|B}.heic + last-hash (gitignored)
└── .logs/                     # launchd stdout/stderr (gitignored)
```

## Configuration

All knobs live in `config.sh` (overridable via env). The binary reads them from its environment at runtime; `install.sh` bakes them into the plist's `EnvironmentVariables` so `launchctl` injects them on every cycle.

| Var                | Default              | Notes                                                       |
|--------------------|----------------------|-------------------------------------------------------------|
| `WEBCAM_URL`       | `wbbs_cam_hour.mp4`  | JPEG, MP4, or MOV. Video → last-frame via AVFoundation       |
| `INTERVAL_SEC`     | 60                   | launchd `StartInterval`                                     |
| `RAW_CROP_TOP`     | 22                   | trims the timestamp banner; tuned to the 1280×960 mp4       |
| `CANVAS_FIT`       | cover                | `cover` fills (crops overflow) / `contain` letterboxes      |
| `CANVAS_ANCHOR`    | center               | `center | top | bottom | left | right`                     |
| `BLUR_RADIUS`      | `5,20`               | scalar = uniform; comma list = top→bottom gradient stops    |
| `COLOR_SATURATION` | 1.05                 | CIColorControls multiplier; 1.0 = unchanged                 |
| `COLOR_BRIGHTNESS` | -0.04                | CIColorControls additive offset; 0.0 = unchanged            |
| `LOG_LEVEL`        | info                 | `debug | info | warn | error`                               |
| `LOG_MAX_BYTES`    | 5_242_880            | rotate `.logs/{stdout,stderr}.log` past this size           |

## Source endpoint trade-offs

|                        | `wbbs_cam_current.jpg` | `wbbs_cam_hour.mp4` (default) | `wbbs_cam_day.mp4` |
|------------------------|------------------------|-------------------------------|--------------------|
| Resolution             | 500×375                | 1280×960                      | 1280×960           |
| Latency vs real time   | ~1 min                 | ~12–15 min                    | ~12–15 min         |
| Bytes pulled per cycle | ~22 KB                 | ~few hundred KB (range reads) | same; bigger file  |
| File size on server    | ~22 KB                 | ~16 MB                        | ~58 MB             |

Flipping `WEBCAM_URL` is enough — `fetchFrameJPEG` dispatches on extension. Bump `RAW_CROP_TOP` to 8 for the legacy jpg, leave at 22 for either mp4. Sky doesn't move fast, so the freshness hit is usually fine.

## Dev workflow

```bash
chmod +x scripts/*.sh test/*.sh

./test/run-once.sh                      # rebuild + run + apply
./test/run-once.sh --no-set             # skip the wallpaper-set phase (sets SKYBG_NO_APPLY)
./test/run-once.sh --watch              # rebuild + re-run on file change (needs fswatch)
LOG_LEVEL=debug ./test/run-once.sh      # verbose
CANVAS_ANCHOR=top ./test/run-once.sh    # any env var overrides the config default
./scripts/detect.sh                     # dump current display arrangement
```

## Install

```bash
./scripts/install.sh           # builds bin/skybg, copies plist, bootstraps the agent
./scripts/install.sh --unload  # bootout and remove
```

The agent runs at load and every `INTERVAL_SEC`. Logs land in `.logs/stdout.log` and `.logs/stderr.log`.

After editing `config.sh`, re-run `./scripts/install.sh` to re-render the plist and reload. (It also `unset`s any inherited env vars first so leftover shell exports don't leak into the agent.)

## Screensaver (optional)

A companion `.saver` bundle (`SkyBg.saver`) shows the same per-monitor slice during screensaver mode, so the wallpaper region stays pixel-identical when macOS activates/deactivates the screensaver. You'll still see the standard system fade and chrome (dock, icons, windows) appearing/disappearing — those aren't suppressible — but the background image content is continuous.

Requires a **Developer ID Application** certificate in your login keychain (free with Apple Developer enrollment; create via Xcode → Settings → Accounts → Manage Certificates → +). `build-saver.sh` auto-detects the first one. macOS Sequoia/Tahoe `amfid` rejects ad-hoc-signed `.saver` bundles, so this is non-optional.

Build, install, and pick it once:

```bash
./scripts/build-saver.sh                          # compiles + signs with your Developer ID
./scripts/install-saver.sh                         # copies into ~/Library/Screen Savers/
open 'x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension'
# scroll to Screen Saver, pick "SkyBg"
```

Per-monitor slice discovery uses `NSWorkspace.shared.desktopImageURL(for:)` — the screensaver simply asks the system "what wallpaper is currently set on this screen?" and loads that file. No shared state files, no path discovery, sidesteps the screensaver-sandbox `~` redirect.

After editing `screensaver.swift`, rebuild + reinstall + force the daemons to pick up the new bundle:

```bash
./scripts/build-saver.sh && ./scripts/install-saver.sh
killall WallpaperAgent legacyScreenSaver Wallpaper WallpaperLegacyExtension 2>/dev/null
```

## Notes

- Display arrangement is detected on every cycle, so plug/unplug/rearrange just works.
- `NSWorkspace.setDesktopImageURL` is the official wallpaper API and does not have the path-cache bug that `osascript`'s `set picture of desktop` has on macOS 14+. We still alternate filenames between an `-A` and `-B` slot per display so the WindowServer (which caches at a deeper layer) treats each cycle as a fresh path.
- Cold-start cost: a `swiftc -O` binary launches in ~10 ms; AVFoundation video-frame decode is ~0.4–0.6 s; full cycle wall time ~1–3 s depending on network. The hash-skip path bypasses everything past the fetch (~150 ms total).
- Output is HEIF 10-bit Display P3 (`writeHEIF10Representation`), file size typically smaller than the equivalent 8-bit JPEG.
