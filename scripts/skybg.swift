// skybg — fetch a webcam frame, fit it across the multi-monitor desktop arrangement,
// slice per display, and set each slice as that display's wallpaper via NSWorkspace.
//
// Knobs (all from environment, set by launchd or test/run-once.sh):
//   WEBCAM_URL      : source URL — JPEG or MP4/MOV (required)
//                     For video, the last frame is decoded via AVFoundation.
//   OUTPUT_DIR      : where to write raw + processed images (required)
//   HISTORY_DIR     : where to archive timestamped source frames (default OUTPUT_DIR/history)
//   LOG_LEVEL       : debug | info | warn | error            (default info)
//   RAW_CROP_TOP    : pixels trimmed off the top of the source (default 0)
//   CANVAS_FIT      : cover | contain                          (default cover)
//   CANVAS_ANCHOR   : vertical anchor 0..1 (0=bottom, 1=top)   (default 0.5)
//   BLUR_RADIUS     : blur radius; single value or comma list  (default 0)
//                     of stops top->bottom (e.g. "10,50")
//   COLOR_SATURATION: CIColorControls saturation multiplier    (default 1.0)
//   COLOR_BRIGHTNESS: CIColorControls brightness offset        (default 0.0)
//   CHANNEL_SHIFT   : chromatic shift in canvas px: R offset    (default 0)
//                     -X, G fixed, B offset +X along the angle
//                     axis; recombined before blurring. 0 = off.
//   CHANNEL_SHIFT_ANGLE : axis in degrees: 0 = R left / B right (default 0)
//                     (left-to-right), 90 = R top / B bottom.
//   BLEND_WEIGHTS   : comma list of frame weights, most-recent  (default "1")
//                     first; auto-normalized. List length = N
//                     means current + (N-1) past frames are
//                     composited. "1" disables blending.
//                     Examples: "1,1" = 50/50 trail (current+prev),
//                     "1,1,1" = last-3 equal blend,
//                     "3,2,1" = 3-frame decaying trail.
//                     N>1 disables the hash-skip so every cycle
//                     re-renders and the trail keeps advancing.
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
    for name in ["stderr.log"] {
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
    let outputDir: URL
    let historyDir: URL
    let cropTop: CGFloat
    let fit: String
    let anchor: Double
    let blurStops: [Double]
    let saturation: Double
    let brightness: Double
    let channelShift: Double
    let channelShiftAngle: Double
    let blendWeights: [Double]
    let noApply: Bool

    static func fromEnv() -> Config {
        let env = ProcessInfo.processInfo.environment
        guard let urlStr = env["WEBCAM_URL"], let url = URL(string: urlStr) else {
            die("WEBCAM_URL must be set to a valid URL")
        }
        guard let outputStr = env["OUTPUT_DIR"] else { die("OUTPUT_DIR must be set") }
        let outputURL = URL(fileURLWithPath: outputStr)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let historyURL: URL
        if let historyStr = env["HISTORY_DIR"], !historyStr.isEmpty {
            historyURL = URL(fileURLWithPath: historyStr)
        } else {
            historyURL = outputURL.appendingPathComponent("history")
        }
        try? FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        let stops = (env["BLUR_RADIUS"] ?? "0")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return Config(
            webcamURL: url,
            outputDir: outputURL,
            historyDir: historyURL,
            cropTop: CGFloat(Int(env["RAW_CROP_TOP"] ?? "0") ?? 0),
            fit: (env["CANVAS_FIT"] ?? "cover").lowercased(),
            anchor: min(1, max(0, Double(env["CANVAS_ANCHOR"] ?? "0.5") ?? 0.5)),
            blurStops: stops.isEmpty ? [0] : stops,
            saturation: Double(env["COLOR_SATURATION"] ?? "1.0") ?? 1.0,
            brightness: Double(env["COLOR_BRIGHTNESS"] ?? "0.0") ?? 0.0,
            channelShift: Double(env["CHANNEL_SHIFT"] ?? "0") ?? 0,
            channelShiftAngle: Double(env["CHANNEL_SHIFT_ANGLE"] ?? "0") ?? 0,
            blendWeights: {
                let parsed = (env["BLEND_WEIGHTS"] ?? "1")
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0 > 0 }
                return parsed.isEmpty ? [1.0] : parsed
            }(),
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

func redactURL(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    components.queryItems = components.queryItems?.map { item in
        item.name.lowercased() == "token"
            ? URLQueryItem(name: item.name, value: "REDACTED")
            : item
    }
    return components.string ?? url.absoluteString
}

// Shell out to /usr/bin/curl. CFNetwork inside launchd-spawned processes hits
// the Local Network privacy resolver (nehelper UUID lookup) on every RFC1918
// destination and races against process startup, returning -1009 before the
// grant lands. /usr/bin/curl is a system binary with its own attribution and
// bypasses that path entirely.
func fetchJPEG(url: URL, timeout: TimeInterval) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = [
        "--silent", "--show-error", "--fail",
        "--max-time", "\(Int(timeout))",
        url.absoluteString,
    ]
    let out = Pipe(), errp = Pipe()
    p.standardOutput = out
    p.standardError = errp
    do { try p.run() } catch { die("curl spawn failed: \(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = errp.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        die("fetch failed: curl exit \(p.terminationStatus)\(msg.isEmpty ? "" : ": \(msg)")")
    }
    guard data.count > 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF else {
        die("response is not a JPEG")
    }
    return data
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

// Split into R/G/B, translate R by -shift and B by +shift along the angle axis
// (0deg = R left / B right, 90deg = R top / B bottom; screen-down convention),
// then recombine additively. Classic chromatic aberration: identical to the
// source wherever channels agree, colored fringes at edges.
func channelShift(_ img: CIImage, shift: Double, angleDeg: Double) -> CIImage {
    let rad = angleDeg * Double.pi / 180
    // Screen coords (y down) -> CI coords (y up): negate the y component.
    let dx = CGFloat(shift * cos(rad))
    let dy = CGFloat(-shift * sin(rad))

    func channel(_ src: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        guard let out = CIFilter(
            name: "CIColorMatrix",
            parameters: [
                kCIInputImageKey: src,
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]
        )?.outputImage else { die("CIColorMatrix channel extract failed") }
        return out
    }
    func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        guard let out = CIFilter(
            name: "CIAdditionCompositing",
            parameters: [kCIInputImageKey: a, kCIInputBackgroundImageKey: b]
        )?.outputImage else { die("CIAdditionCompositing failed") }
        return out
    }

    let clamped = img.clampedToExtent()
    let rOnly = channel(clamped.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)),
                        r: 1, g: 0, b: 0)
    let gOnly = channel(clamped, r: 0, g: 1, b: 0)
    let bOnly = channel(clamped.transformed(by: CGAffineTransform(translationX: dx, y: dy)),
                        r: 0, g: 0, b: 1)
    return add(rOnly, add(bOnly, gOnly)).cropped(to: img.extent)
}

// The wallpaper agent renders every image it's handed into a decompressed BMP
// in its container cache and never prunes it (~14 MB per set per display; this
// is what grew to 340 GB). Deleting entries older than 5 minutes is safe:
// in-use files stay mapped by WindowServer after unlink, and the agent
// regenerates on demand.
func cleanupWallpaperAgentCache(olderThan maxAge: TimeInterval = 300) {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image")
    guard let entries = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    let cutoff = Date().addingTimeInterval(-maxAge)
    var removed = 0
    for url in entries where url.pathExtension == "bmp" {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let mod, mod < cutoff {
            try? fm.removeItem(at: url)
            removed += 1
        }
    }
    if removed > 0 { log("info", "pruned \(removed) stale wallpaper-agent cache bmp(s)") }
}

func cleanupOldCycles(in dir: URL, keep: Set<URL>) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    // Match any wallpaper-* file (covers legacy .jpg outputs from older cycles too).
    for url in entries
    where url.lastPathComponent.hasPrefix("wallpaper-") && !keep.contains(url) {
        try? fm.removeItem(at: url)
    }
}

let historyStampFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return f
}()

func archiveSourceFrame(_ data: Data, hashHex: String, cfg: Config) {
    let now = Date()
    let stamp = historyStampFmt.string(from: now)
    let fileName = "frame-\(stamp)-\(hashHex.prefix(12)).jpg"
    let frameURL = cfg.historyDir.appendingPathComponent(fileName)
    do {
        try data.write(to: frameURL, options: .atomic)
    } catch {
        log("warn", "history write failed: \(error)")
        return
    }
    let indexURL = cfg.historyDir.appendingPathComponent("index.csv")
    let unixMs = Int64(now.timeIntervalSince1970 * 1000)
    let row = "\(stamp),\(unixMs),\(hashHex),\(fileName)\n"
    let fm = FileManager.default
    if !fm.fileExists(atPath: indexURL.path) {
        let header = "timestamp_utc,unix_ms,sha256,file\n"
        try? header.write(to: indexURL, atomically: true, encoding: .utf8)
    }
    guard let handle = try? FileHandle(forWritingTo: indexURL) else {
        log("warn", "history index open failed")
        return
    }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(row.utf8))
        try handle.close()
    } catch {
        log("warn", "history index append failed: \(error)")
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

    let offsetX = (canvasW - scaledW) / 2
    let offsetY = CGFloat(cfg.anchor) * (canvasH - scaledH)

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

    if cfg.channelShift != 0 {
        working = channelShift(working, shift: cfg.channelShift, angleDeg: cfg.channelShiftAngle)
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
        let positioned = img.cropped(to: outRect)
        // Alternate A/B slot per monitor: WindowServer treats it as a fresh path
        // every cycle (so the wallpaper actually refreshes), but the system's
        // "Recent Wallpapers" list stays capped at 2 entries per display.
        let currentName = NSWorkspace.shared.desktopImageURL(for: m.screen)?.lastPathComponent ?? ""
        let nextSlot = currentName.hasSuffix("-A.heic") ? "B" : "A"
        let outURL = cfg.outputDir.appendingPathComponent("wallpaper-\(m.id)-\(nextSlot).heic")
        // HEIF 10-bit + Display P3 — 1024 values per channel kills the banding
        // 8-bit JPEG produces in smooth sky gradients.
        do {
            try ctx.writeHEIF10Representation(
                of: positioned,
                to: outURL,
                colorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [:]
            )
        } catch {
            die("HEIF10 encode failed for \(m.label): \(error)")
        }
        results.append((m, outURL))
    }
    return results
}

rotateLogs()

let cfg = Config.fromEnv()

log("info", "fetch \(redactURL(cfg.webcamURL))")
let jpeg = fetchFrameJPEG(url: cfg.webcamURL)
log("debug", "raw \(jpeg.count) bytes")

// Hash-skip the rest of the pipeline if the source bytes match the last cycle.
// install.sh deletes last-hash so any config edit forces a re-process. With a
// multi-frame blend trail we always re-render so the trail keeps advancing
// even on duplicate fetches.
let hashHex = SHA256.hash(data: jpeg).compactMap { String(format: "%02x", $0) }.joined()
let hashFile = cfg.outputDir.appendingPathComponent("last-hash")
let prevHash = (try? String(contentsOf: hashFile, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let sourceUnchanged = prevHash == hashHex
if sourceUnchanged && cfg.blendWeights.count == 1 {
    log("info", "source unchanged (sha=\(hashHex.prefix(12))), skipping")
    exit(0)
}
try? hashHex.write(to: hashFile, atomically: true, encoding: .utf8)
if !sourceUnchanged {
    archiveSourceFrame(jpeg, hashHex: hashHex, cfg: cfg)
}

let rawURL = cfg.outputDir.appendingPathComponent("raw.jpg")
do { try jpeg.write(to: rawURL) } catch { die("could not write raw.jpg: \(error)") }
guard let current = CIImage(contentsOf: rawURL) else { die("could not parse raw image") }

func prevFrameURL(_ i: Int) -> URL {
    cfg.outputDir.appendingPathComponent("prev-\(i).jpg")
}

func alignedToExtent(_ img: CIImage, _ target: CGRect) -> CIImage {
    let e = img.extent
    if e == target { return img }
    return img
        .transformed(by: CGAffineTransform(scaleX: target.width / e.width,
                                           y: target.height / e.height))
        .transformed(by: CGAffineTransform(translationX: target.origin.x - e.origin.x,
                                           y: target.origin.y - e.origin.y))
}

let src: CIImage
if cfg.blendWeights.count > 1 {
    // Pair current + available prev-i.jpg with their weights (most recent first),
    // drop missing past frames, then composite oldest-to-newest with
    // alpha_k = w_k / sum(w_0..w_k). The math collapses to the exact normalized
    // weighted sum of all layers in a single CI graph.
    var layers: [(CIImage, Double)] = [(current, cfg.blendWeights[0])]
    for i in 1..<cfg.blendWeights.count {
        if let img = CIImage(contentsOf: prevFrameURL(i)) {
            layers.append((alignedToExtent(img, current.extent), cfg.blendWeights[i]))
        }
    }
    if layers.count == 1 {
        src = current
    } else {
        var composed: CIImage = layers.last!.0
        var cumulative: Double = layers.last!.1
        for (img, w) in layers.dropLast().reversed() {
            cumulative += w
            let alpha = CGFloat(w / cumulative)
            guard let attenuated = CIFilter(
                name: "CIColorMatrix",
                parameters: [
                    kCIInputImageKey: img,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                ]
            )?.outputImage,
            let next = CIFilter(
                name: "CISourceOverCompositing",
                parameters: [
                    kCIInputImageKey: attenuated,
                    kCIInputBackgroundImageKey: composed,
                ]
            )?.outputImage else { die("blend composite failed at layer w=\(w)") }
            composed = next
        }
        src = composed
        log("info", "blend \(layers.count)-frame weights=\(layers.map { $0.1 })")
    }
} else {
    src = current
}

let monitors = detectMonitors()
guard !monitors.isEmpty else { die("no displays detected") }
log("info", "displays: " + monitors.map { "\($0.label)#\($0.id) \($0.widthPx)x\($0.heightPx)" }.joined(separator: ", "))
log("info", "process fit=\(cfg.fit) anchor=\(cfg.anchor) blur=\(cfg.blurStops) sat=\(cfg.saturation) bri=\(cfg.brightness) crop_top=\(Int(cfg.cropTop)) shift=\(cfg.channelShift)@\(cfg.channelShiftAngle)deg")

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
    cleanupOldCycles(in: cfg.outputDir, keep: Set(outputs.map { $0.1 }))
    cleanupWallpaperAgentCache()
}

// Rolling ring buffer: shift prev-(i-1) → prev-i for i = N-1 down to 2, then
// write the current raw bytes to prev-1.jpg. Prune any prev-K.jpg with K >= N
// so shrinking BLEND_WEIGHTS doesn't leak stale frames.
do {
    let fm = FileManager.default
    let n = cfg.blendWeights.count
    if n > 1 {
        for i in stride(from: n - 1, through: 2, by: -1) {
            let from = prevFrameURL(i - 1), to = prevFrameURL(i)
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
        }
        try jpeg.write(to: prevFrameURL(1))
    }
    var k = max(n, 1)
    while fm.fileExists(atPath: prevFrameURL(k).path) {
        try? fm.removeItem(at: prevFrameURL(k))
        k += 1
    }
} catch {
    log("warn", "prev rotation failed: \(error)")
}

log("info", "done")
