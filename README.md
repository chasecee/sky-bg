# sky-bg

Pulls a webcam JPEG on an interval, fits it onto the virtual desktop arrangement, slices out each monitor's region, and sets it as the macOS wallpaper across a multi-monitor setup. Runs as a `launchd` user agent.

## Stack

A single compiled Swift binary (`bin/skybg`) does everything image-and-display:

- `URLSession` — fetch
- `CoreImage` — banner crop, virtual-canvas mapping, per-monitor slice, optional `CIGaussianBlur`
- `NSScreen` — auto-detect the current display arrangement (no manual config)
- `NSWorkspace.setDesktopImageURL(_:for:options:)` — apply each slice (Apple's official wallpaper API; reliable on every macOS version)

Bash is only used for install / dev tooling: `scripts/build.sh`, `scripts/install.sh`, `test/run-once.sh`, `scripts/detect.sh`. No Homebrew / Node / Python deps — every dependency ships in macOS.

## Model

1. Fetch raw JPEG, validate the SOI marker, write to cache.
2. Trim the top `RAW_CROP_TOP` rows (the webcam's burned-in timestamp banner).
3. Auto-detect every monitor via `NSScreen` (origin in points, pixel size, screen handle).
4. Compute the bounding rect of all monitor frames — that's the virtual canvas.
5. Scale the source onto the canvas per `CANVAS_FIT` (`cover` fills + crops overflow, `contain` letterboxes), pinned per `CANVAS_ANCHOR`.
6. Optional `CIGaussianBlur` on the canvas.
7. For each monitor, slice the canvas at that monitor's point-rect and resample to its native pixel resolution.
8. Apply each slice via `NSWorkspace.setDesktopImageURL` against that monitor's `NSScreen`.

## Layout

```
sky-bg/
├── config.sh                  # defaults sourced by install.sh and test/run-once.sh
├── com.skybg.wallpaper.plist  # launchd template (placeholders substituted by install.sh)
├── scripts/
│   ├── skybg.swift            # the whole runtime pipeline
│   ├── screensaver.swift      # SkyBgScreenSaverView source for the .saver bundle
│   ├── build.sh               # swiftc -O scripts/skybg.swift -o bin/skybg
│   ├── build-saver.sh         # build SkyBg.saver bundle (ad-hoc signed)
│   ├── install.sh             # build + render plist + launchctl bootstrap (--unload to remove)
│   ├── install-saver.sh       # copy SkyBg.saver into ~/Library/Screen Savers/
│   └── detect.sh              # debug: dump the current NSScreen arrangement
├── test/
│   └── run-once.sh            # rebuild + run once (--watch, --no-set)
├── bin/skybg                  # built locally, gitignored
├── SkyBg.saver/               # built locally, gitignored
├── .cache/                    # raw + per-monitor JPEGs (gitignored)
└── .logs/                     # launchd stdout/stderr (gitignored)
```

## Configuration

All knobs live in `config.sh` (overridable via env). The binary reads them from its environment at runtime; `install.sh` bakes them into the plist's `EnvironmentVariables` so `launchctl` injects them on every cycle.

| Var             | Default          | Notes                                                       |
|-----------------|------------------|-------------------------------------------------------------|
| `WEBCAM_URL`    | wbbs_cam_current | JPEG endpoint                                               |
| `INTERVAL_SEC`  | 300              | launchd `StartInterval`                                     |
| `RAW_CROP_TOP`  | 8                | trims the webcam's timestamp banner                         |
| `CANVAS_FIT`    | cover            | `cover` fills (crops overflow) / `contain` letterboxes      |
| `CANVAS_ANCHOR` | bottom           | `center | top | bottom | left | right`                     |
| `BLUR_RADIUS`   | 10,58            | radius; single value = uniform, comma list = top->bottom    |
| `LOG_LEVEL`     | info             | `debug | info | warn | error`                               |

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

After editing `config.sh`, re-run `./scripts/install.sh` to re-render the plist and reload.

## Screensaver (optional)

A companion `.saver` bundle (`SkyBg.saver`) shows the same per-monitor slice during screensaver mode, so the wallpaper region stays pixel-identical when macOS activates/deactivates the screensaver. You'll still see the standard system fade and chrome (dock, icons, windows) appearing/disappearing — those aren't suppressible — but the background image content is continuous.

Build, install, and pick it once:

```bash
./scripts/build-saver.sh                          # compiles + ad-hoc signs SkyBg.saver/
./scripts/install-saver.sh                         # copies into ~/Library/Screen Savers/
open 'x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension'
# scroll to Screen Saver, pick "SkyBg"
```

The screensaver discovers the cache by reading `~/Library/Application Support/com.skybg/cache_path`, which `bin/skybg` writes on every cycle. No hardcoded paths.

## Notes

- Display arrangement is detected on every cycle, so plug/unplug/rearrange just works.
- `NSWorkspace.setDesktopImageURL` is the official wallpaper API and does not have the path-cache bug that `osascript`'s `set picture of desktop` has on macOS 14+, so output filenames are stable (`wallpaper-<id>.jpg`) and overwritten in place every cycle.
- Cold-start cost: a `swiftc -O` binary launches in ~10 ms, vs ~500 ms for `swift` JIT. Total runtime per cycle is ~250–900 ms depending on network latency.
