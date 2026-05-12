// skybg — fetch a webcam JPEG, fit it across the multi-monitor desktop arrangement,
// slice per display, and set each slice as that display's wallpaper via NSWorkspace.
//
// Knobs (all from environment, set by launchd or test/run-once.sh):
//   WEBCAM_URL      : source JPEG URL (required)
//   CACHE_DIR       : where to write raw + processed images (required)
//   LOG_LEVEL       : debug | info | warn | error            (default info)
//   RAW_CROP_TOP    : pixels trimmed off the top of the source (default 0)
//   CANVAS_FIT      : cover | contain                          (default cover)
//   CANVAS_ANCHOR   : center | top | bottom | left | right     (default center)
//   BLUR_RADIUS     : Gaussian blur radius applied to canvas   (default 0)
//   COLOR_SATURATION: CIColorControls saturation multiplier    (default 1.0)
//   COLOR_BRIGHTNESS: CIColorControls brightness offset        (default 0.0)
//   SKYBG_NO_APPLY  : "1" to skip the wallpaper-set phase      (default unset)

import Foundation
import CoreImage
import AppKit

let levels = ["debug": 0, "info": 1, "warn": 2, "error": 3]
let curLevel = levels[ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() ?? ""] ?? 1
let tsFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
}()

func log(_ level: String, _ msg: String) {
    guard (levels[level] ?? 1) >= curLevel else { return }
    let padded = level.padding(toLength: 5, withPad: " ", startingAt: 0)
    let line = "\(tsFmt.string(from: Date())) [\(padded)] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

func die(_ msg: String) -> Never { log("error", msg); exit(1) }

struct Config {
    let webcamURL: URL
    let cacheDir: URL
    let cropTop: CGFloat
    let fit: String
    let anchor: String
    let blur: Double
    let saturation: Double
    let brightness: Double
    let noApply: Bool

    static func fromEnv() -> Config {
        let env = ProcessInfo.processInfo.environment
        guard let urlStr = env["WEBCAM_URL"], let url = URL(string: urlStr) else {
            die("WEBCAM_URL must be set to a valid URL")
        }
        guard let cacheStr = env["CACHE_DIR"] else { die("CACHE_DIR must be set") }
        let cacheURL = URL(fileURLWithPath: cacheStr)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        return Config(
            webcamURL: url,
            cacheDir: cacheURL,
            cropTop: CGFloat(Int(env["RAW_CROP_TOP"] ?? "0") ?? 0),
            fit: (env["CANVAS_FIT"] ?? "cover").lowercased(),
            anchor: (env["CANVAS_ANCHOR"] ?? "center").lowercased(),
            blur: Double(env["BLUR_RADIUS"] ?? "0") ?? 0,
            saturation: Double(env["COLOR_SATURATION"] ?? "1.0") ?? 1.0,
            brightness: Double(env["COLOR_BRIGHTNESS"] ?? "0.0") ?? 0.0,
            noApply: env["SKYBG_NO_APPLY"] == "1"
        )
    }
}

struct Monitor {
    let id: UInt32
    let label: String
    let originX, originY, widthPt, heightPt: CGFloat
    let widthPx, heightPx: Int
    let screen: NSScreen
}

func detectMonitors() -> [Monitor] {
    NSScreen.screens.map { s in
        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        let f = s.frame
        let scale = s.backingScaleFactor
        return Monitor(
            id: id, label: s.localizedName,
            originX: f.origin.x, originY: f.origin.y,
            widthPt: f.width, heightPt: f.height,
            widthPx: Int(f.width * scale), heightPx: Int(f.height * scale),
            screen: s
        )
    }
}

func fetchJPEG(url: URL, timeout: TimeInterval = 30) -> Data {
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    var err: String?
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error = error { err = error.localizedDescription; return }
        guard let http = response as? HTTPURLResponse else { err = "no HTTP response"; return }
        guard (200..<300).contains(http.statusCode) else { err = "HTTP \(http.statusCode)"; return }
        guard let d = data, d.count > 3, d[0] == 0xFF, d[1] == 0xD8, d[2] == 0xFF else {
            err = "response is not a JPEG"; return
        }
        result = d
    }.resume()
    sem.wait()
    if let e = err { die("fetch failed: \(e)") }
    return result!
}

func cleanupOldCycles(in dir: URL, keep: Set<URL>) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for url in entries
    where url.lastPathComponent.hasPrefix("wallpaper-") && url.pathExtension == "jpg" && !keep.contains(url) {
        try? fm.removeItem(at: url)
    }
}

func processCanvas(src: CIImage, monitors: [Monitor], cfg: Config) -> [(Monitor, URL)] {
    let srcExt = src.extent
    guard srcExt.height > cfg.cropTop else { die("RAW_CROP_TOP \(cfg.cropTop) >= source height \(srcExt.height)") }

    let trimmed = src
        .cropped(to: CGRect(x: srcExt.origin.x, y: srcExt.origin.y,
                            width: srcExt.width, height: srcExt.height - cfg.cropTop))
        .transformed(by: CGAffineTransform(translationX: -srcExt.origin.x, y: -srcExt.origin.y))
    let srcW = trimmed.extent.width
    let srcH = trimmed.extent.height

    let xmin = monitors.map { $0.originX }.min()!
    let ymin = monitors.map { $0.originY }.min()!
    let xmax = monitors.map { $0.originX + $0.widthPt }.max()!
    let ymax = monitors.map { $0.originY + $0.heightPt }.max()!
    let canvasW = xmax - xmin
    let canvasH = ymax - ymin

    let scale: CGFloat
    switch cfg.fit {
    case "cover":   scale = max(canvasW / srcW, canvasH / srcH)
    case "contain": scale = min(canvasW / srcW, canvasH / srcH)
    default:        die("unknown CANVAS_FIT: \(cfg.fit)")
    }
    let scaledW = srcW * scale
    let scaledH = srcH * scale

    let offsetX, offsetY: CGFloat
    switch cfg.anchor {
    case "center": (offsetX, offsetY) = ((canvasW - scaledW)/2, (canvasH - scaledH)/2)
    case "top":    (offsetX, offsetY) = ((canvasW - scaledW)/2, canvasH - scaledH)
    case "bottom": (offsetX, offsetY) = ((canvasW - scaledW)/2, 0)
    case "left":   (offsetX, offsetY) = (0, (canvasH - scaledH)/2)
    case "right":  (offsetX, offsetY) = (canvasW - scaledW, (canvasH - scaledH)/2)
    default:       die("unknown CANVAS_ANCHOR: \(cfg.anchor)")
    }

    var working = trimmed
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

    if cfg.saturation != 1.0 || cfg.brightness != 0.0 {
        guard let adjusted = CIFilter(
            name: "CIColorControls",
            parameters: [
                kCIInputImageKey: working,
                kCIInputSaturationKey: cfg.saturation,
                kCIInputBrightnessKey: cfg.brightness,
                kCIInputContrastKey: 1.0,
            ]
        )?.outputImage else { die("CIColorControls failed") }
        working = adjusted
    }

    let canvas: CIImage
    if cfg.blur > 0 {
        guard let blurred = CIFilter(
            name: "CIGaussianBlur",
            parameters: [kCIInputImageKey: working.clampedToExtent(), kCIInputRadiusKey: cfg.blur]
        )?.outputImage else { die("CIGaussianBlur failed") }
        canvas = blurred
    } else {
        canvas = working
    }

    let ctx = CIContext(options: nil)
    var results: [(Monitor, URL)] = []
    for m in monitors {
        let mx = m.originX - xmin
        let my = m.originY - ymin
        let cropRect = CGRect(x: mx, y: my, width: m.widthPt, height: m.heightPt)
        let sx = CGFloat(m.widthPx) / m.widthPt
        let sy = CGFloat(m.heightPx) / m.heightPt
        let img = canvas
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -mx, y: -my))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let outRect = CGRect(x: 0, y: 0, width: CGFloat(m.widthPx), height: CGFloat(m.heightPx))
        guard let cg = ctx.createCGImage(img, from: outRect) else {
            die("createCGImage failed for \(m.label)")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            die("jpeg encode failed for \(m.label)")
        }
        let outURL = cfg.cacheDir.appendingPathComponent("wallpaper-\(m.id)-\(cycle).jpg")
        do { try data.write(to: outURL) } catch { die("write failed for \(m.label): \(error)") }
        results.append((m, outURL))
    }
    return results
}

// Cycle tag burned into output filenames. The WindowServer caches wallpapers by
// file path, so re-setting the same path is a visual no-op even when the bytes
// changed. A fresh path per cycle forces a real refresh.
let cycle = String(Int(Date().timeIntervalSince1970))

let cfg = Config.fromEnv()

log("info", "fetch \(cfg.webcamURL.absoluteString)")
let jpeg = fetchJPEG(url: cfg.webcamURL)
log("debug", "raw \(jpeg.count) bytes")

let rawURL = cfg.cacheDir.appendingPathComponent("raw.jpg")
do { try jpeg.write(to: rawURL) } catch { die("could not write raw.jpg: \(error)") }
guard let src = CIImage(contentsOf: rawURL) else { die("could not parse raw image") }

let monitors = detectMonitors()
guard !monitors.isEmpty else { die("no displays detected") }
log("info", "displays: " + monitors.map { "\($0.label)#\($0.id) \($0.widthPx)x\($0.heightPx)" }.joined(separator: ", "))
log("info", "process fit=\(cfg.fit) anchor=\(cfg.anchor) blur=\(cfg.blur) sat=\(cfg.saturation) bri=\(cfg.brightness) crop_top=\(Int(cfg.cropTop))")

let outputs = processCanvas(src: src, monitors: monitors, cfg: cfg)

if cfg.noApply {
    log("info", "SKYBG_NO_APPLY=1, skipping wallpaper set")
} else {
    let errLock = NSLock()
    var firstErr: String? = nil
    DispatchQueue.concurrentPerform(iterations: outputs.count) { i in
        let (m, url) = outputs[i]
        log("info", "set \(m.label) (id=\(m.id)) -> \(url.lastPathComponent)")
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: m.screen, options: [:])
        } catch {
            errLock.lock()
            if firstErr == nil { firstErr = "setDesktopImageURL failed for \(m.label): \(error)" }
            errLock.unlock()
        }
    }
    if let err = firstErr { die(err) }
    cleanupOldCycles(in: cfg.cacheDir, keep: Set(outputs.map { $0.1 }))
}

log("info", "done")
