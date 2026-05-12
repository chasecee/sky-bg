// gen-preview — render docs/preview.gif: an animated stitched multi-monitor
// canvas built from the source MP4. Dev tool only; deliberately separate from
// the runtime pipeline in skybg.swift so the README artifact can evolve
// without bloating the wallpaper agent.
//
// Reads the same canvas/blur/color env vars as skybg.swift so the preview
// matches the live config when invoked via gen-preview.sh. Extra knobs:
//
//   GIF_FRAMES        24
//   GIF_DELAY_MS      100
//   GIF_TARGET_WIDTH  1100
//   GIF_BEZEL_PX      6
//   GIF_OUT           docs/preview.gif

import Foundation
import CoreImage
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
func envInt(_ k: String, _ d: Int) -> Int { Int(env(k) ?? "") ?? d }
func envDouble(_ k: String, _ d: Double) -> Double { Double(env(k) ?? "") ?? d }

func note(_ s: String) {
    FileHandle.standardError.write(Data("[gen-preview] \(s)\n".utf8))
}
func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data("[gen-preview] error: \(s)\n".utf8))
    exit(1)
}

let urlStr = env("WEBCAM_URL")
    ?? "https://horel.chpc.utah.edu/data/station_cameras/wbbs_cam/wbbs_cam_hour.mp4"
guard let url = URL(string: urlStr) else { die("invalid WEBCAM_URL: \(urlStr)") }
let ext = url.pathExtension.lowercased()
guard ["mp4", "mov", "m4v"].contains(ext) else {
    die("WEBCAM_URL must be an MP4/MOV (got .\(ext)) — only video sources have multiple frames to animate")
}

let frameCount = max(2, envInt("GIF_FRAMES", 24))
let delayMs    = max(20, envInt("GIF_DELAY_MS", 100))
let targetW    = max(200, envInt("GIF_TARGET_WIDTH", 1100))
let bezelPx    = max(0, envInt("GIF_BEZEL_PX", 6))
let outPath    = env("GIF_OUT") ?? "docs/preview.gif"

let cropTop    = CGFloat(envInt("RAW_CROP_TOP", 22))
let fit        = (env("CANVAS_FIT") ?? "cover").lowercased()
let anchor     = (env("CANVAS_ANCHOR") ?? "bottom").lowercased()
let blurStops: [Double] = (env("BLUR_RADIUS") ?? "13,18")
    .split(separator: ",")
    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
let saturation = envDouble("COLOR_SATURATION", 1.05)
let brightness = envDouble("COLOR_BRIGHTNESS", -0.04)

struct Mon {
    let id: UInt32
    let label: String
    let x, y, w, h: CGFloat
}

let monitors: [Mon] = NSScreen.screens.map { s in
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    let f = s.frame
    return Mon(id: id, label: s.localizedName,
               x: f.origin.x, y: f.origin.y, w: f.width, h: f.height)
}
guard !monitors.isEmpty else { die("no displays detected") }

let xmin = monitors.map { $0.x }.min()!
let ymin = monitors.map { $0.y }.min()!
let xmax = monitors.map { $0.x + $0.w }.max()!
let ymax = monitors.map { $0.y + $0.h }.max()!
let canvasW = xmax - xmin
let canvasH = ymax - ymin

note("displays: " + monitors.map {
    "\($0.label)#\($0.id) \(Int($0.w))x\(Int($0.h))pt @(\(Int($0.x)),\(Int($0.y)))"
}.joined(separator: ", "))
let outScale = CGFloat(targetW) / canvasW
let outH = max(1, Int((canvasH * outScale).rounded()))
note("canvas \(Int(canvasW))x\(Int(canvasH))pt -> output \(targetW)x\(outH)px (scale \(String(format: "%.3f", outScale)))")

// AVURLAsset against a remote URL would issue separate range reads per
// frame request. One bulk download is simpler and faster for N>3 frames.
let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("skybg-preview-\(UUID().uuidString).mp4")
do {
    note("download \(url.absoluteString)")
    let data = try Data(contentsOf: url)
    try data.write(to: tmpURL)
    note("downloaded \(data.count) bytes -> \(tmpURL.path)")
} catch {
    die("download failed: \(error.localizedDescription)")
}
defer { try? FileManager.default.removeItem(at: tmpURL) }

let asset = AVURLAsset(url: tmpURL)

let durSem = DispatchSemaphore(value: 0)
var dur: CMTime = .zero
var loadErr: String?
Task {
    do { dur = try await asset.load(.duration) }
    catch { loadErr = error.localizedDescription }
    durSem.signal()
}
durSem.wait()
if let e = loadErr { die("load duration failed: \(e)") }
let durSec = CMTimeGetSeconds(dur)
guard durSec.isFinite, durSec > 0 else { die("video duration invalid: \(durSec)") }
note("duration \(String(format: "%.2f", durSec))s, extracting \(frameCount) frames")

let times: [CMTime] = (0..<frameCount).map { i in
    let t = durSec * Double(i) / Double(frameCount - 1)
    return CMTime(seconds: t, preferredTimescale: 600)
}

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

var rawFrames: [CGImage] = []
let decodeSem = DispatchSemaphore(value: 0)
var decodeErr: String?
Task {
    do {
        for (i, t) in times.enumerated() {
            let (cg, _) = try await gen.image(at: t)
            rawFrames.append(cg)
            note("decoded \(i + 1)/\(times.count)")
        }
    } catch {
        decodeErr = error.localizedDescription
    }
    decodeSem.signal()
}
decodeSem.wait()
if let e = decodeErr { die("decode failed: \(e)") }
guard rawFrames.count >= 2 else { die("got only \(rawFrames.count) frames, need >= 2") }

let ciCtx = CIContext(options: nil)

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
    ) else { die("CGGradient failed") }
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(h)),
        end: CGPoint(x: 0, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    guard let cg = ctx.makeImage() else { die("CGImage for blur mask failed") }
    return CIImage(cgImage: cg)
}

func renderStitched(_ rawCG: CGImage) -> CGImage {
    let src = CIImage(cgImage: rawCG)
    let srcExt = src.extent
    guard srcExt.height > cropTop else { die("RAW_CROP_TOP \(cropTop) >= source height \(srcExt.height)") }

    let trimmed = src
        .cropped(to: CGRect(x: srcExt.origin.x, y: srcExt.origin.y,
                            width: srcExt.width, height: srcExt.height - cropTop))
        .transformed(by: CGAffineTransform(translationX: -srcExt.origin.x, y: -srcExt.origin.y))
    let srcW = trimmed.extent.width
    let srcH = trimmed.extent.height

    let scale: CGFloat
    switch fit {
    case "cover":   scale = max(canvasW / srcW, canvasH / srcH)
    case "contain": scale = min(canvasW / srcW, canvasH / srcH)
    default:        die("unknown CANVAS_FIT: \(fit)")
    }
    let scaledW = srcW * scale
    let scaledH = srcH * scale
    let offX, offY: CGFloat
    switch anchor {
    case "center": (offX, offY) = ((canvasW - scaledW)/2, (canvasH - scaledH)/2)
    case "top":    (offX, offY) = ((canvasW - scaledW)/2, canvasH - scaledH)
    case "bottom": (offX, offY) = ((canvasW - scaledW)/2, 0)
    case "left":   (offX, offY) = (0, (canvasH - scaledH)/2)
    case "right":  (offX, offY) = (canvasW - scaledW, (canvasH - scaledH)/2)
    default:       die("unknown CANVAS_ANCHOR: \(anchor)")
    }

    var work = trimmed
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: offX, y: offY))

    if saturation != 1.0 || brightness != 0.0 {
        guard let adj = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: work,
            kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: 1.0,
        ])?.outputImage else { die("CIColorControls failed") }
        work = adj
    }

    let canvas: CIImage
    let maxStop = blurStops.max() ?? 0
    let uniformBlur = Set(blurStops).count == 1
    if maxStop > 0 {
        let clamped = work.clampedToExtent()
        if uniformBlur {
            guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: clamped, kCIInputRadiusKey: maxStop,
            ])?.outputImage else { die("CIGaussianBlur failed") }
            canvas = blurred
        } else {
            let mask = makeBlurMask(stops: blurStops, width: canvasW, height: canvasH).clampedToExtent()
            guard let blurred = CIFilter(name: "CIMaskedVariableBlur", parameters: [
                kCIInputImageKey: clamped, "inputMask": mask, kCIInputRadiusKey: maxStop,
            ])?.outputImage else { die("CIMaskedVariableBlur failed") }
            canvas = blurred
        }
    } else {
        canvas = work
    }

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let outCtx = CGContext(
        data: nil, width: targetW, height: outH, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { die("output CGContext failed") }
    outCtx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    outCtx.fill(CGRect(x: 0, y: 0, width: targetW, height: outH))

    for m in monitors {
        let mx = m.x - xmin
        let my = m.y - ymin
        let cropRect = CGRect(x: mx, y: my, width: m.w, height: m.h)
        let sliceOutW = Int((m.w * outScale).rounded())
        let sliceOutH = Int((m.h * outScale).rounded())
        let slice = canvas
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -mx, y: -my))
            .transformed(by: CGAffineTransform(scaleX: outScale, y: outScale))
        guard let sliceCG = ciCtx.createCGImage(
            slice, from: CGRect(x: 0, y: 0, width: CGFloat(sliceOutW), height: CGFloat(sliceOutH))
        ) else { die("createCGImage failed for monitor \(m.label)") }
        let dx = (mx * outScale).rounded()
        let dy = (my * outScale).rounded()
        let inset = CGFloat(bezelPx)
        let rect = CGRect(
            x: dx + inset, y: dy + inset,
            width: CGFloat(sliceOutW) - 2 * inset,
            height: CGFloat(sliceOutH) - 2 * inset
        )
        outCtx.draw(sliceCG, in: rect)
    }

    guard let outCG = outCtx.makeImage() else { die("output makeImage failed") }
    return outCG
}

note("processing \(rawFrames.count) frames")
let stitched = rawFrames.enumerated().map { i, cg -> CGImage in
    let out = renderStitched(cg)
    note("stitched \(i + 1)/\(rawFrames.count)")
    return out
}

let outURL = URL(fileURLWithPath: outPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.gif.identifier as CFString, stitched.count, nil
) else { die("CGImageDestinationCreateWithURL failed for \(outURL.path)") }

let fileProps: [String: Any] = [
    kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFLoopCount as String: 0,
    ],
]
CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

let delaySec = Double(delayMs) / 1000.0
let frameProps: [String: Any] = [
    kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFUnclampedDelayTime as String: delaySec,
        kCGImagePropertyGIFDelayTime as String: delaySec,
    ],
]
for cg in stitched {
    CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { die("GIF finalize failed") }

let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int64 ?? 0
print("wrote \(outURL.path) — \(stitched.count) frames @ \(delayMs)ms, \(bytes) bytes")
