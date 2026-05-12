// skybg — fetch a webcam frame, fit it across the multi-monitor desktop arrangement,
// slice per display, and set each slice as that display's wallpaper via NSWorkspace.
//
// Knobs (all from environment, set by launchd or test/run-once.sh):
//   WEBCAM_URL      : source URL — JPEG or MP4/MOV (required)
//                     For video, the last frame is decoded via AVFoundation.
//   CACHE_DIR       : where to write raw + processed images (required)
//   LOG_LEVEL       : debug | info | warn | error            (default info)
//   RAW_CROP_TOP    : pixels trimmed off the top of the source (default 0)
//   CANVAS_FIT      : cover | contain                          (default cover)
//   CANVAS_ANCHOR   : center | top | bottom | left | right     (default center)
//   BLUR_RADIUS     : blur radius; single value or comma list  (default 0)
//                     of stops top->bottom (e.g. "10,50")
//   COLOR_SATURATION: CIColorControls saturation multiplier    (default 1.0)
//   COLOR_BRIGHTNESS: CIColorControls brightness offset        (default 0.0)
//   SKYBG_NO_APPLY  : "1" to skip the wallpaper-set phase      (default unset)

import Foundation
import CoreImage
import AppKit
import AVFoundation
import CryptoKit

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

// Rotate stderr/stdout once they exceed the cap. launchd holds the inode FD;
// renaming sends the rest of this cycle's output to the .1 file, and the next
// cycle's launchd start opens a fresh stderr.log. Default 5 MB ≈ 35 days at
// 5-min intervals.
func rotateLogs() {
    guard let logDir = ProcessInfo.processInfo.environment["LOG_DIR"] else { return }
    let maxBytes = Int64(ProcessInfo.processInfo.environment["LOG_MAX_BYTES"] ?? "") ?? 5_242_880
    let fm = FileManager.default
    for name in ["stderr.log", "stdout.log"] {
        let path = (logDir as NSString).appendingPathComponent(name)
        let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
        if size > maxBytes {
            let archived = path + ".1"
            try? fm.removeItem(atPath: archived)
            try? fm.moveItem(atPath: path, toPath: archived)
        }
    }
}

struct Config {
    let webcamURL: URL
    let cacheDir: URL
    let cropTop: CGFloat
    let fit: String
    let anchor: String
    let blurStops: [Double]
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
        let stops = (env["BLUR_RADIUS"] ?? "0")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return Config(
            webcamURL: url,
            cacheDir: cacheURL,
            cropTop: CGFloat(Int(env["RAW_CROP_TOP"] ?? "0") ?? 0),
            fit: (env["CANVAS_FIT"] ?? "cover").lowercased(),
            anchor: (env["CANVAS_ANCHOR"] ?? "center").lowercased(),
            blurStops: stops.isEmpty ? [0] : stops,
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

func fetchFrameJPEG(url: URL, timeout: TimeInterval = 30) -> Data {
    switch url.pathExtension.lowercased() {
    case "mp4", "mov", "m4v":
        return decodeLastVideoFrame(url: url, timeout: timeout)
    default:
        return fetchJPEG(url: url, timeout: timeout)
    }
}

func fetchJPEG(url: URL, timeout: TimeInterval) -> Data {
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

// Decode the last frame of a remote MP4/MOV via AVFoundation. AVURLAsset uses
// HTTP range requests under the hood, so we don't download the whole file —
// just the moov atom plus the trailing samples needed for the final frame.
func decodeLastVideoFrame(url: URL, timeout: TimeInterval) -> Data {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    var outcome: Result<CGImage, Error>!
    Task {
        do {
            let dur = try await asset.load(.duration)
            let durSec = CMTimeGetSeconds(dur)
            guard durSec.isFinite, durSec > 0 else {
                throw NSError(domain: "skybg", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "video duration is zero or invalid"])
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = .zero
            let target = CMTimeSubtract(dur, CMTime(seconds: 0.1, preferredTimescale: 600))
            let (cg, _) = try await gen.image(at: target)
            outcome = .success(cg)
        } catch {
            outcome = .failure(error)
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        die("video frame decode timed out after \(Int(timeout))s")
    }
    switch outcome! {
    case .failure(let e): die("video frame decode failed: \(e.localizedDescription)")
    case .success(let cg):
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            die("jpeg encode of decoded frame failed")
        }
        return data
    }
}

// Vertical grayscale gradient sized to the canvas. stops[0] is the top,
// stops.last is the bottom; intermediate values are spaced evenly. Brightness
// is normalized to maxStop so it can drive CIMaskedVariableBlur's inputRadius.
func makeBlurMask(stops: [Double], width: CGFloat, height: CGFloat) -> CIImage {
    let w = max(2, Int(width.rounded(.up)))
    let h = max(2, Int(height.rounded(.up)))
    let maxStop = stops.max() ?? 1.0
    let cs = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { die("CGContext for blur mask failed") }
    var components: [CGFloat] = []
    for s in stops { components.append(CGFloat(s / maxStop)); components.append(1.0) }
    let n = stops.count
    let locations: [CGFloat] = (0..<n).map { n == 1 ? 0 : CGFloat(Double($0) / Double(n - 1)) }
    guard let gradient = CGGradient(
        colorSpace: cs, colorComponents: components, locations: locations, count: n
    ) else { die("CGGradient for blur mask failed") }
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(h)),
        end: CGPoint(x: 0, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    guard let cg = ctx.makeImage() else { die("CGImage for blur mask failed") }
    return CIImage(cgImage: cg)
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
    let maxStop = cfg.blurStops.max() ?? 0
    let uniform = Set(cfg.blurStops).count == 1
    if maxStop > 0 {
        let clamped = working.clampedToExtent()
        if uniform {
            guard let blurred = CIFilter(
                name: "CIGaussianBlur",
                parameters: [kCIInputImageKey: clamped, kCIInputRadiusKey: maxStop]
            )?.outputImage else { die("CIGaussianBlur failed") }
            canvas = blurred
        } else {
            let mask = makeBlurMask(stops: cfg.blurStops, width: canvasW, height: canvasH)
                .clampedToExtent()
            guard let blurred = CIFilter(
                name: "CIMaskedVariableBlur",
                parameters: [
                    kCIInputImageKey: clamped,
                    "inputMask": mask,
                    kCIInputRadiusKey: maxStop,
                ]
            )?.outputImage else { die("CIMaskedVariableBlur failed") }
            canvas = blurred
        }
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
        // Alternate A/B slot per monitor: WindowServer treats it as a fresh path
        // every cycle (so the wallpaper actually refreshes), but the system's
        // "Recent Wallpapers" list stays capped at 2 entries per display instead
        // of growing unboundedly with cycle-suffixed filenames.
        let currentName = NSWorkspace.shared.desktopImageURL(for: m.screen)?.lastPathComponent ?? ""
        let nextSlot = currentName.hasSuffix("-A.jpg") ? "B" : "A"
        let outURL = cfg.cacheDir.appendingPathComponent("wallpaper-\(m.id)-\(nextSlot).jpg")
        do { try data.write(to: outURL) } catch { die("write failed for \(m.label): \(error)") }
        results.append((m, outURL))
    }
    return results
}

rotateLogs()

let cfg = Config.fromEnv()

log("info", "fetch \(cfg.webcamURL.absoluteString)")
let jpeg = fetchFrameJPEG(url: cfg.webcamURL)
log("debug", "raw \(jpeg.count) bytes")

// Skip the rest of the pipeline if the bytes match the last cycle. install.sh
// deletes last-hash so any config edit forces a re-process on the next cycle.
let hashHex = SHA256.hash(data: jpeg).compactMap { String(format: "%02x", $0) }.joined()
let hashFile = cfg.cacheDir.appendingPathComponent("last-hash")
if let prev = try? String(contentsOf: hashFile, encoding: .utf8),
   prev.trimmingCharacters(in: .whitespacesAndNewlines) == hashHex {
    log("info", "source unchanged (sha=\(hashHex.prefix(12))), skipping")
    exit(0)
}
try? hashHex.write(to: hashFile, atomically: true, encoding: .utf8)

let rawURL = cfg.cacheDir.appendingPathComponent("raw.jpg")
do { try jpeg.write(to: rawURL) } catch { die("could not write raw.jpg: \(error)") }
guard let src = CIImage(contentsOf: rawURL) else { die("could not parse raw image") }

let monitors = detectMonitors()
guard !monitors.isEmpty else { die("no displays detected") }
log("info", "displays: " + monitors.map { "\($0.label)#\($0.id) \($0.widthPx)x\($0.heightPx)" }.joined(separator: ", "))
log("info", "process fit=\(cfg.fit) anchor=\(cfg.anchor) blur=\(cfg.blurStops) sat=\(cfg.saturation) bri=\(cfg.brightness) crop_top=\(Int(cfg.cropTop))")

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
