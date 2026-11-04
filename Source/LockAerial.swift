import AppKit
import AVFoundation
import CoreImage
import CryptoKit

// 4.11.0: a moving lock screen under the real macOS login.
//
// macOS plays its Aerial wallpapers on the lock screen itself, under its own
// clock, password field, Touch ID and user list. Ovira adds its video (the
// live wallpaper chosen in Settings, or a short looping film of the music
// artwork) to the user's Aerial list and selects it while the Mac is locked;
// on unlock the user's own wallpaper record is put back (SystemLockWallpaper
// keeps the copy).
//
// Only files in the user's own Library are touched — the same files System
// Settings writes when a wallpaper is chosen. Nothing here needs an
// administrator password and nothing touches the login itself.
//
// The Aerial manifest and wallpaper-store format follows the open-source
// LivePaper project (MIT License, © 2026 Raunak Gupta) for macOS 26+.
enum LockAerial {
    static let categoryID = "0E1A0000-0000-4000-8000-0000000000A1"
    static let subcategoryID = "0E1A0000-0000-4000-8000-0000000000A2"
    static let activeKey = "lockAerialActiveV4110"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var aerials: URL { home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials") }
    private static var videosDir: URL { aerials.appendingPathComponent("videos") }
    private static var thumbsDir: URL { aerials.appendingPathComponent("thumbnails") }
    private static var entriesURL: URL { aerials.appendingPathComponent("manifest/entries.json") }
    static var storeURL: URL { home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist") }
    private static var loopsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ovira/LockWallpaper/loops", isDirectory: true)
    }
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Aerials with this store format exist from macOS 26 on.
    static var supported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            && FileManager.default.fileExists(atPath: storeURL.path)
    }

    // A stable id for the same content, so a video is added only once.
    static func assetID(for key: String) -> String {
        let hex = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02X", $0) }.joined()
        func part(_ a: Int, _ b: Int) -> String {
            String(hex[hex.index(hex.startIndex, offsetBy: a)..<hex.index(hex.startIndex, offsetBy: b)])
        }
        return "\(part(0, 8))-\(part(8, 12))-4\(part(13, 16))-8\(part(17, 20))-\(part(20, 32))"
    }

    // MARK: Adding a video to the Aerial list

    // Puts the video file in place (a hard link when possible — no copy of a
    // big file), writes its thumbnail and its entry. Off the main thread.
    @discardableResult
    static func register(video: URL, key: String, name: String) -> String? {
        let fm = FileManager.default
        let id = assetID(for: key)
        let target = videosDir.appendingPathComponent("\(id).mov")
        do {
            try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) {
                do { try fm.linkItem(at: video, to: target) } catch { try fm.copyItem(at: video, to: target) }
            }
        } catch {
            LockIslandLog.record("aerial: could not place the video — \(error.localizedDescription)")
            return nil
        }
        let thumb = thumbsDir.appendingPathComponent("\(id).png")
        if !fm.fileExists(atPath: thumb.path) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil),
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: thumb)
            }
        }
        guard writeEntries(keeping: id, name: name) else { return nil }
        return id
    }

    private static func writeEntries(keeping id: String, name: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: entriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var entries: [String: Any] = ["version": 1, "categories": [Any](), "assets": [Any]()]
        if let data = try? Data(contentsOf: entriesURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = parsed
        }
        var categories = entries["categories"] as? [[String: Any]] ?? []
        var assets = entries["assets"] as? [[String: Any]] ?? []
        let thumb = thumbsDir.appendingPathComponent("\(id).png").absoluteString
        let video = videosDir.appendingPathComponent("\(id).mov").absoluteString
        let category: [String: Any] = [
            "id": categoryID,
            "localizedNameKey": "Ovira",
            "localizedDescriptionKey": "Ovira",
            "preferredOrder": 999,
            "representativeAssetID": id,
            "previewImage": thumb,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "Ovira",
                "localizedDescriptionKey": "Ovira",
                "preferredOrder": 0,
                "previewImage": thumb,
                "representativeAssetID": id
            ]]
        ]
        categories.removeAll { ($0["id"] as? String) == categoryID }
        categories.append(category)
        // Ovira keeps one entry: older ones (and their files) go away.
        let old = assets.filter { (($0["categories"] as? [String]) ?? []).contains(categoryID) }
            .compactMap { $0["id"] as? String }.filter { $0 != id }
        assets.removeAll { (($0["categories"] as? [String]) ?? []).contains(categoryID) }
        assets.append([
            "id": id,
            "localizedNameKey": name,
            "accessibilityLabel": name,
            "shotID": "OVIRA_LOCK",
            "showInTopLevel": true,
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": video,
            "previewImage": thumb,
            "pointsOfInterest": ["0": "OVIRA_0"]
        ])
        entries["categories"] = categories
        entries["assets"] = assets
        for gone in old { removeFiles(of: gone) }
        return write(json: entries)
    }

    private static func write(json: [String: Any]) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: entriesURL, options: .atomic)
            return true
        } catch {
            LockIslandLog.record("aerial: could not write the list — \(error.localizedDescription)")
            return false
        }
    }

    private static func removeFiles(of id: String) {
        try? FileManager.default.removeItem(at: videosDir.appendingPathComponent("\(id).mov"))
        try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent("\(id).png"))
    }

    // Everything Ovira added, gone (on unlock and in «Восстановить обои»).
    static func removeAll() {
        guard let data = try? Data(contentsOf: entriesURL),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var assets = entries["assets"] as? [[String: Any]] ?? []
        for asset in assets where (((asset["categories"] as? [String]) ?? []).contains(categoryID)) {
            if let id = asset["id"] as? String { removeFiles(of: id) }
        }
        assets.removeAll { (($0["categories"] as? [String]) ?? []).contains(categoryID) }
        var categories = entries["categories"] as? [[String: Any]] ?? []
        categories.removeAll { ($0["id"] as? String) == categoryID }
        entries["assets"] = assets
        entries["categories"] = categories
        _ = write(json: entries)
    }

    // MARK: Choosing it

    // The wallpaper record now points every display and space at the video.
    static func select(_ id: String) -> Bool {
        guard let config = try? PropertyListSerialization.data(fromPropertyList: ["assetID": id],
                                                               format: .binary, options: 0),
              let data = try? Data(contentsOf: storeURL),
              var store = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves,
                                                                       format: nil)) as? [String: Any] else {
            LockIslandLog.record("aerial: wallpaper record unreadable")
            return false
        }
        let entry: [String: Any] = [
            "Type": "linked",
            "Linked": [
                "Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Files": [Any](),
                    "Configuration": config
                ]]],
                "LastSet": Date(),
                "LastUse": Date()
            ] as [String: Any]
        ]
        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry
        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys { displays[key] = entry }
            store["Displays"] = displays
        }
        if var spaces = store["Spaces"] as? [String: Any] {
            for key in spaces.keys {
                guard var space = spaces[key] as? [String: Any] else { continue }
                if space["Default"] != nil { space["Default"] = entry }
                if var spaceDisplays = space["Displays"] as? [String: Any] {
                    for d in spaceDisplays.keys { spaceDisplays[d] = entry }
                    space["Displays"] = spaceDisplays
                }
                spaces[key] = space
            }
            store["Spaces"] = spaces
        }
        do {
            let out = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
            try out.write(to: storeURL, options: .atomic)
        } catch {
            LockIslandLog.record("aerial: could not write the wallpaper record — \(error.localizedDescription)")
            return false
        }
        restartAgent()
        // Did macOS take it? The agent rewrites the record if it cannot.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            let raw = (try? Data(contentsOf: storeURL)) ?? Data()
            let kept = raw.range(of: Data(id.utf8)) != nil
            LockIslandLog.record("aerial: record after restart — ours=\(kept), agent=\(agentRunning()) — \(describeStore())")
        }
        return true
    }

    static func agentRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "WallpaperAgent"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // 4.11.1: Apple's Aerials are HEVC films without sound in a .mov; any
    // other video is rewritten that way once (a few seconds) and kept.
    static func aerialVideo(from source: URL) -> URL? {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.intValue ?? 0
        let dir = loopsDir.deletingLastPathComponent().appendingPathComponent("videos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(assetID(for: "\(source.path)|\(size)")).mov")
        if fm.fileExists(atPath: url.path) { return url }
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first else {
            LockIslandLog.record("aerial: the video has no picture track")
            return nil
        }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? target.insertTimeRange(CMTimeRange(start: .zero, duration: track.timeRange.duration),
                                           of: track, at: .zero)) != nil else { return nil }
        target.preferredTransform = track.preferredTransform
        let preset = AVAssetExportSession.exportPresets(compatibleWith: composition)
            .contains(AVAssetExportPresetHEVCHighestQuality) ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { return nil }
        export.outputURL = url
        export.outputFileType = .mov
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        export.exportAsynchronously { done.signal() }
        done.wait()
        let ok = export.status == .completed
        LockIslandLog.record("aerial: video prepared \(ok ? "ok" : "failed: \(export.error?.localizedDescription ?? "?")") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if !ok { try? fm.removeItem(at: url) }
        return ok ? url : nil
    }

    // 4.11.2: what the wallpaper record points at, for the log: every
    // place (path) with its provider and asset — no pictures, no paths of
    // the user's files.
    static func describeStore() -> String {
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return "unreadable" }
        var lines: [String] = []
        func walk(_ value: Any, _ path: String) {
            guard lines.count < 40 else { return }
            if let dict = value as? [String: Any] {
                if let provider = dict["Provider"] as? String {
                    var asset = ""
                    if let config = dict["Configuration"] as? Data,
                       let decoded = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any] {
                        asset = (decoded["assetID"] as? String) ?? decoded.keys.sorted().joined(separator: ",")
                    }
                    let mine = isOurs(asset) ? " (Ovira)" : ""
                    lines.append("\(path): \(provider.replacingOccurrences(of: "com.apple.wallpaper.choice.", with: "")) \(asset)\(mine)")
                    return
                }
                for key in dict.keys.sorted() where key != "LastSet" && key != "LastUse" {
                    let short = key.count > 12 ? String(key.prefix(8)) : key
                    walk(dict[key]!, path.isEmpty ? short : "\(path)/\(short)")
                }
            } else if let array = value as? [Any] {
                for (i, item) in array.enumerated() { walk(item, "\(path)[\(i)]") }
            }
        }
        walk(root, "")
        return lines.joined(separator: " | ")
    }

    private static func isOurs(_ asset: String) -> Bool {
        guard let data = try? Data(contentsOf: entriesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return false }
        return assets.contains { ($0["id"] as? String) == asset
            && (($0["categories"] as? [String]) ?? []).contains(categoryID) }
    }

    // The wallpaper agent re-reads the list and the record when it starts.
    static func restartAgent() {
        let caches = home.appendingPathComponent(
            "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.aerials")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: caches.path) {
            for item in items where item.hasSuffix(".bmp") {
                try? FileManager.default.removeItem(at: caches.appendingPathComponent(item))
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
    }

    // MARK: A looping film of the artwork

    // The same picture as the artwork wallpaper, with the blurred colours
    // flowing behind the cover. 20 seconds that loop without a seam.
    static func coverLoop(art: CGImage, screen: CGSize, withCover: Bool, coverShare: CGFloat, key: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: loopsDir, withIntermediateDirectories: true)
        let url = loopsDir.appendingPathComponent("\(assetID(for: key)).mov")
        if fm.fileExists(atPath: url.path) { return url }
        // Older films are not needed any more.
        for old in (try? fm.contentsOfDirectory(at: loopsDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        let width = Int(min(1920, screen.width)) / 2 * 2
        let height = Int(CGFloat(width) * screen.height / max(1, screen.width)) / 2 * 2
        guard width > 0, height > 0 else { return nil }
        let started = Date()
        let ok = writeLoop(art: art, width: width, height: height, withCover: withCover,
                           coverShare: coverShare, to: url)
        LockIslandLog.record("aerial: artwork film \(ok ? "ready" : "failed") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if !ok { try? fm.removeItem(at: url) }
        return ok ? url : nil
    }

    private static func writeLoop(art: CGImage, width: Int, height: Int, withCover: Bool,
                                  coverShare: CGFloat, to url: URL) -> Bool {
        let fps: Int32 = 30
        let seconds = 20
        let size = CGSize(width: width, height: height)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        // The blurred colours, made once, small (they are a blur anyway).
        let side = max(size.width, size.height) * 1.5
        let small = side / 4
        let source = CIImage(cgImage: art)
        let fit = small / min(source.extent.width, source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        let base = scaled
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: size.height / 14 / 4])
            .cropped(to: scaled.extent)
        guard let baseImage = ciContext.createCGImage(base, from: base.extent) else { return false }
        let blurred = CIImage(cgImage: baseImage)
        let foreground = CIImage(cgImage: foregroundLayer(art: art, size: size, withCover: withCover,
                                                         coverShare: coverShare) ?? art)
        let bounds = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let total = Int(fps) * seconds
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        func layer(_ t: Double, scale: Double, angle: Double, dx: Double, dy: Double,
                   phase: Double, opacity: CGFloat) -> CIImage {
            let w = 2 * Double.pi * t
            let s = 4 * (1.15 + scale * sin(w + phase))
            let a = angle * sin(w + phase * 1.3)
            let ox = size.width * dx * sin(w * 1 + phase)
            let oy = size.height * dy * cos(w * 1 + phase * 0.7)
            var image = blurred.transformed(by: CGAffineTransform(translationX: -blurred.extent.midX, y: -blurred.extent.midY))
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            image = image.transformed(by: CGAffineTransform(rotationAngle: a))
            image = image.transformed(by: CGAffineTransform(translationX: center.x + ox, y: center.y + oy))
            if opacity < 1 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                ])
            }
            return image
        }

        for index in 0..<total {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            let t = Double(index) / Double(total)       // 0…1, one loop
            var frame = CIImage(color: .black).cropped(to: bounds)
            frame = layer(t, scale: 0.10, angle: 0.35, dx: 0.10, dy: 0.08, phase: 0, opacity: 1).composited(over: frame)
            frame = layer(t, scale: 0.14, angle: -0.45, dx: 0.16, dy: 0.12, phase: 2.1, opacity: 0.8).composited(over: frame)
            frame = layer(t, scale: 0.18, angle: 0.55, dx: 0.18, dy: 0.16, phase: 4.2, opacity: 0.7).composited(over: frame)
            frame = frame.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
            frame = foreground.composited(over: frame).cropped(to: bounds)
            ciContext.render(frame, to: buffer, bounds: bounds, colorSpace: space)
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) {
                return false
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    // Darkening, the sharp cover with its shadow and the shading for the
    // clock and the login — over a transparent background.
    private static func foregroundLayer(art: CGImage, size: CGSize, withCover: Bool, coverShare: CGFloat) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        context.fill(bounds)
        if withCover {
            let side = bounds.height * coverShare
            let center = CGPoint(x: bounds.midX, y: bounds.height * 0.5)
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            let radius = side * 0.045
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let unit = bounds.height / 1000
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -18 * unit), blur: 80 * unit,
                              color: NSColor.black.withAlphaComponent(0.5).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.interpolationQuality = .high
            let aspect = CGFloat(art.width) / CGFloat(max(1, art.height))
            var drawRect = rect
            if aspect > 1 { drawRect.size.width = side * aspect; drawRect.origin.x = center.x - drawRect.width / 2 }
            if aspect < 1 { drawRect.size.height = side / aspect; drawRect.origin.y = center.y - drawRect.height / 2 }
            context.draw(art, in: drawRect)
            context.restoreGState()
        }
        let colors = [NSColor.black.withAlphaComponent(0.38).cgColor, NSColor.clear.cgColor,
                      NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.45).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors,
                                     locations: [0, 0.32, 0.62, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.height), end: .zero, options: [])
        }
        return context.makeImage()
    }
}
