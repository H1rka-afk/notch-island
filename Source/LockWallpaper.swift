import AppKit
import AVFoundation
import ScreenCaptureKit

// 3.9.4 — the wallpaper that is set on the Mac right now, for the widget
// editor. `desktopImageURL` alone is not enough on macOS 14+: for Aerials
// (the moving wallpapers) it returns an unrelated still. The order:
// 1. the exact picture of the desktop wallpaper window, when Notch Island
//    already may record the screen (no new permission is ever requested);
// 2. the wallpaper chosen in System Settings, read from the wallpaper store:
//    a picture file, or a frame of the Aerial video;
// 3. `desktopImageURL`.

final class EditorWallpaper: ObservableObject {
    @Published var image: NSImage?
}

enum CurrentWallpaper {
    // Fills `target` (on the main queue): first the quick still, then — when
    // allowed — the exact picture of the wallpaper window.
    static func load(for screen: NSScreen, into target: EditorWallpaper) {
        let desktopURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        DispatchQueue.global(qos: .userInitiated).async {
            let (still, source) = quickStill(desktopURL: desktopURL, maxSize: pixels)
            LockIslandLog.record("editor wallpaper: \(source)")
            DispatchQueue.main.async {
                if let still, target.image == nil { target.image = still }
            }
        }
        if let displayID, CGPreflightScreenCaptureAccess() {
            captureWallpaperWindow(displayID: displayID, pixels: pixels) { image in
                guard let image else { return }
                LockIslandLog.record("editor wallpaper: exact capture")
                DispatchQueue.main.async { target.image = image }
            }
        }
    }

    static func quickStill(desktopURL: URL?, maxSize: CGSize) -> (NSImage?, String) {
        if let data = try? Data(contentsOf: WallpaperStore.indexURL),
           let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let choice = WallpaperStore.currentChoice(in: root) {
            for path in choice.files where FileManager.default.fileExists(atPath: path) {
                if let image = image(at: path, maxSize: maxSize) { return (image, "store file \(path)") }
            }
            if !choice.assetIDs.isEmpty {
                let paths = aerialFiles()
                for id in choice.assetIDs {
                    if let path = WallpaperStore.bestAsset(for: id, among: paths),
                       let image = image(at: path, maxSize: maxSize) {
                        return (image, "aerial \(id) \(path)")
                    }
                }
                LockIslandLog.record("editor wallpaper: aerial \(choice.assetIDs) not found among \(paths.count) files")
            }
        }
        if let desktopURL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: desktopURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let first = (try? FileManager.default.contentsOfDirectory(atPath: desktopURL.path))?
                    .sorted()
                    .first { WallpaperStore.mediaExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                if let first, let image = image(at: desktopURL.appendingPathComponent(first).path, maxSize: maxSize) {
                    return (image, "desktop folder \(desktopURL.path)")
                }
            } else if let image = image(at: desktopURL.path, maxSize: maxSize) {
                return (image, "desktopImageURL \(desktopURL.path)")
            }
        }
        return (nil, "none")
    }

    // Aerial videos and their stills, by file name.
    static func aerialFiles() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "\(home)/Library/Application Support/com.apple.wallpaper/aerials",
            "/Library/Application Support/com.apple.idleassetsd",
            "\(home)/Library/Containers/com.apple.wallpaper.extension.aerials/Data/Library/Application Support"
        ]
        var result: [String] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            var seen = 0
            while let item = enumerator.nextObject() as? String, seen < 20000 {
                seen += 1
                if WallpaperStore.mediaExtensions.contains((item as NSString).pathExtension.lowercased()) {
                    result.append("\(root)/\(item)")
                }
            }
        }
        return result
    }

    static func image(at path: String, maxSize: CGSize) -> NSImage? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "mov" || ext == "mp4" {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maxSize
            guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }
        return NSImage(contentsOfFile: path)
    }

    // The desktop wallpaper window itself (owned by the Dock / wallpaper
    // agent, at the desktop level) — exactly what is on screen.
    static func captureWallpaperWindow(displayID: CGDirectDisplayID, pixels: CGSize,
                                       completion: @escaping (NSImage?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                completion(nil); return
            }
            let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
            let candidates = content.windows.filter { window in
                let title = window.title ?? ""
                let covers = window.frame.width >= display.frame.width - 2 && window.frame.height >= display.frame.height - 2
                    && window.frame.intersects(display.frame)
                return covers && (window.windowLayer == desktopLevel || title.hasPrefix("Wallpaper"))
            }
            guard let wallpaper = candidates.min(by: { $0.windowLayer < $1.windowLayer }) else {
                completion(nil); return
            }
            let filter = SCContentFilter(display: display, including: [wallpaper])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                completion(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            }
        }
    }
}
