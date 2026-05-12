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

    // Ask the system for whatever wallpaper sky-bg most recently set on this screen,
    // and load that file. No shared-state files, no glob discovery — sidesteps the
    // screensaver-sandbox HOME redirect that breaks ~/Library/Application Support reads.
    private func reloadIfNeeded() -> Bool {
        guard let screen = window?.screen ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            lastError = "no desktopImageURL for screen"
            diag(lastError)
            if image != nil { image = nil; return true }
            return false
        }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        if url.path != imagePath || mtime != imageMtime {
            imagePath = url.path
            imageMtime = mtime
            image = NSImage(contentsOf: url)
            if image == nil {
                lastError = "NSImage(contentsOf:) failed for \(url.path)"
                diag(lastError)
            } else {
                lastError = ""
                diag("loaded \(url.path)")
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
