// skybg-cleanup — delete wallpaper-agent BMP cache entries older than 5 minutes.
// Runs as its own signed binary so it can be granted Full Disk Access once in
// System Settings; launchd-spawned /bin/sh is denied container access by TCC.
// Logs a heartbeat line every run and posts a notification if the cache grows
// past 5 GB, so a future silent failure surfaces in minutes, not 500 GB later.

import Foundation

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let cacheDir = home.appendingPathComponent(
    "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image")

let stampFmt = DateFormatter()
stampFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

func log(_ msg: String) {
    FileHandle.standardError.write(Data("\(stampFmt.string(from: Date())) \(msg)\n".utf8))
}

guard fm.fileExists(atPath: cacheDir.path) else { exit(0) }

let entries: [URL]
do {
    entries = try fm.contentsOfDirectory(
        at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
} catch {
    log("list failed: \(error.localizedDescription)")
    exit(1)
}

let cutoff = Date().addingTimeInterval(-300)
var matched = 0, deleted = 0, failed = 0, totalBytes = 0
for url in entries where url.pathExtension == "bmp" {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    totalBytes += values?.fileSize ?? 0
    guard let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
    matched += 1
    do {
        try fm.removeItem(at: url)
        deleted += 1
    } catch {
        failed += 1
        if failed == 1 { log("delete failed: \(error.localizedDescription)") }
    }
}

log("matched=\(matched) deleted=\(deleted) failed=\(failed) cache_mb=\(totalBytes / 1_048_576)")

if totalBytes > 5 * 1_073_741_824 || failed > 0 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e",
        "display notification \"Wallpaper cache cleanup is failing — check .logs/cache-cleanup.log\" with title \"skybg\""]
    try? p.run()
}

exit(failed > 0 ? 1 : 0)
