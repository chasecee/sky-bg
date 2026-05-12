// SkyBgScreenSaverView — a .saver bundle that draws the latest sky-bg slice
// for whichever display the screensaver instance is on, so the wallpaper-region
// pixels stay continuous when macOS activates/deactivates the screensaver.

import ScreenSaver
import AppKit

@objc(SkyBgScreenSaverView)
final class SkyBgScreenSaverView: ScreenSaverView {
    private var image: NSImage?
    private var imagePath: String = ""
    private var imageMtime: TimeInterval = 0
    private var lastError: String = "init"

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 30
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        diag("init frame=\(frame) preview=\(isPreview)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 30
        diag("init(coder)")
    }

    // Logs go to Console (subsystem com.skybg.screensaver) and to /tmp/skybg-saver.log
    // when /tmp is writable from the screensaver host's sandbox.
    private func diag(_ msg: String) {
        NSLog("SkyBg: %@", msg)
        let line = "\(Date()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/skybg-saver.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func cacheDir() -> String? {
        let pointer = NSString(string: "~/Library/Application Support/com.skybg/cache_path").expandingTildeInPath
        do {
            let raw = try String(contentsOfFile: pointer, encoding: .utf8)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastError = "cacheDir read failed: \(error.localizedDescription)"
            diag(lastError)
            return nil
        }
    }

    private func currentDisplayID() -> UInt32? {
        if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            return id
        }
        return NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    private func newestWallpaper(in dir: String, for displayID: UInt32?) -> (path: String, mtime: TimeInterval)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            lastError = "list \(dir) failed"
            diag(lastError)
            return nil
        }
        let prefix: String? = displayID.map { "wallpaper-\($0)-" }
        var best: (String, TimeInterval)?
        for name in entries {
            guard name.hasPrefix("wallpaper-") && name.hasSuffix(".jpg") else { continue }
            if let p = prefix, !name.hasPrefix(p) { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let mtime = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? 0
            if best == nil || mtime > best!.1 { best = (path, mtime) }
        }
        if best == nil {
            lastError = "no wallpaper in \(dir) for id=\(displayID.map(String.init) ?? "any")"
            diag(lastError)
        }
        return best.map { (path: $0.0, mtime: $0.1) }
    }

    private func reloadIfNeeded() -> Bool {
        guard let dir = cacheDir() else { image = nil; return true }
        let id = currentDisplayID()
        var pick = newestWallpaper(in: dir, for: id)
        if pick == nil { pick = newestWallpaper(in: dir, for: nil) }
        guard let pick else { image = nil; return true }

        if pick.path != imagePath || pick.mtime != imageMtime {
            imagePath = pick.path
            imageMtime = pick.mtime
            image = NSImage(contentsOfFile: pick.path)
            if image == nil {
                lastError = "NSImage failed to load \(pick.path)"
                diag(lastError)
            } else {
                lastError = ""
                diag("loaded \(pick.path) (id=\(id.map(String.init) ?? "?"))")
            }
            return true
        }
        return false
    }

    override func draw(_ rect: NSRect) {
        _ = reloadIfNeeded()
        NSColor.black.setFill()
        bounds.fill()
        if let image {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            return
        }
        // Visible diagnostic so a broken preview isn't a silent black box.
        let style = NSMutableParagraphStyle(); style.alignment = .left
        let fontSize = max(14, bounds.height * 0.025)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .paragraphStyle: style,
        ]
        let msg = "SkyBg: \(lastError)\nframe=\(bounds)\nscreen=\(window?.screen?.localizedName ?? "nil")"
        NSAttributedString(string: msg, attributes: attrs)
            .draw(in: bounds.insetBy(dx: 12, dy: 12))
    }

    override func animateOneFrame() {
        if reloadIfNeeded() { needsDisplay = true }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
