import AppKit
import AVFoundation
import Combine
import CoreImage

// 4.10.0: the real macOS lock screen with the music artwork.
//
// A window can sit either above the macOS login (and hide the password
// field and the user list) or under the lock wallpaper (and not be seen) —
// macOS draws the lock wallpaper and the login as one surface. So instead of
// a window, Ovira puts the picture INTO the system wallpaper while the Mac is
// locked: macOS itself draws its clock, the password field, Touch ID and the
// user list on top, all of them real. On unlock the user's own wallpaper is
// put back exactly as it was.
//
// Nothing here touches the login itself: no keystrokes, no password field of
// our own — only the desktop picture, through the public NSWorkspace API.
enum SystemLockWallpaperSettings {
    static let enabledKey = "lockSystemWallpaperV4100"
    static var enabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
}

final class SystemLockWallpaper {
    private let state: IslandState
    private var observers: [NSObjectProtocol] = []
    private var artworkObserver: AnyCancellable?
    private var requestObserver: AnyCancellable?
    private var requested = false
    private var pending: DispatchWorkItem?
    private var locked = false
    private var applied = false
    private var lastKey = ""

    private static let backupKey = "lockSystemWallpaperBackupV4100"
    private static let storeBackupName = "Index-backup.plist"
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ovira/LockWallpaper", isDirectory: true)
    }

    private static var wallpaperStore: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    init(state: IslandState) {
        self.state = state
        // A crash or a power cut while locked would leave the artwork as the
        // desktop picture — put the user's wallpaper back on the next launch.
        restoreIfNeeded(reason: "launch")
        let dc = DistributedNotificationCenter.default()
        observers.append(dc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                        queue: .main) { [weak self] _ in self?.didLock() })
        observers.append(dc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                        queue: .main) { [weak self] _ in self?.didUnlock() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.restoreIfNeeded(reason: "quit")
        })
        // 4.10.2: only after a tap on the artwork in the lock-screen player
        // (and back on the next tap).
        requestObserver = LockCardUIState.shared.$expanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.setRequested(on) }
        artworkObserver = state.$musicArtwork
            .map { $0.map(ObjectIdentifier.init) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleUpdate(delay: 0.8) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Lock / unlock

    private func didLock() {
        guard !locked else { return }
        locked = true
        if requested { scheduleUpdate(delay: 0) }
    }

    private func didUnlock() {
        locked = false
        pending?.cancel()
        restoreIfNeeded(reason: "unlock")
    }

    private func setRequested(_ on: Bool) {
        requested = on
        if on {
            scheduleUpdate(delay: 0)
        } else {
            pending?.cancel()
            if applied || UserDefaults.standard.data(forKey: Self.backupKey) != nil {
                restoreIfNeeded(reason: "tap")
            }
        }
    }

    private func scheduleUpdate(delay: TimeInterval) {
        guard locked else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // What the lock screen should show right now, if anything of ours.
    private enum Source {
        case artwork(NSImage)
        case video(String)
    }

    private func currentSource() -> Source? {
        if let art = state.musicArtwork { return .artwork(art) }
        return nil
    }

    private func update() {
        guard locked, requested, SystemLockWallpaperSettings.enabled else { return }
        guard let source = currentSource() else {
            // Music stopped while locked: back to the user's own wallpaper.
            if applied { restoreIfNeeded(reason: "nothing to show") }
            return
        }
        let key: String
        switch source {
        case .artwork(let image): key = "art-\(ObjectIdentifier(image).hashValue)"
        case .video(let path): key = "video-\(path)"
        }
        guard key != lastKey || !applied else { return }
        lastKey = key
        let screens = NSScreen.screens
        let sizes = screens.map { s in
            CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
        }
        let artwork: CGImage?
        switch source {
        case .artwork(let image): artwork = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case .video: artwork = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var files: [URL?] = []
            for size in sizes {
                switch source {
                case .artwork:
                    files.append(artwork.flatMap { Self.renderArtwork($0, size: size) }.flatMap(Self.save))
                case .video(let path):
                    files.append(Self.videoStill(path, size: size).flatMap(Self.save))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.locked, self.lastKey == key else { return }
                self.apply(files: files, screens: screens)
            }
        }
    }

    private func apply(files: [URL?], screens: [NSScreen]) {
        let workspace = NSWorkspace.shared
        if !applied { backup(screens: screens) }
        var done = 0
        for (screen, file) in zip(screens, files) {
            guard let file else { continue }
            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true
            ]
            do {
                try workspace.setDesktopImageURL(file, for: screen, options: options)
                done += 1
            } catch {
                LockIslandLog.record("system wallpaper: set failed — \(error.localizedDescription)")
            }
        }
        if done > 0 { applied = true }
        LockIslandLog.record("system wallpaper: artwork set on \(done)/\(screens.count) screen(s)")
        cleanOldFiles(keeping: Set(files.compactMap { $0?.lastPathComponent }))
    }

    // MARK: Backup and restore

    private struct Saved: Codable {
        var screen: UInt32
        var url: String
        var scaling: Int?
        var clipping: Bool?
        var color: [Double]?
    }

    private static func number(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func backup(screens: [NSScreen]) {
        // An earlier backup that was never restored is the real original.
        if UserDefaults.standard.data(forKey: Self.backupKey) != nil { return }
        let workspace = NSWorkspace.shared
        var saved: [Saved] = []
        for screen in screens {
            guard let url = workspace.desktopImageURL(for: screen) else { continue }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            var color: [Double]?
            if let c = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
                color = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)]
            }
            saved.append(Saved(screen: Self.number(of: screen), url: url.path,
                               scaling: (options[.imageScaling] as? NSNumber)?.intValue,
                               clipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                               color: color))
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.backupKey)
        }
        // The full macOS wallpaper choice (Aerial, dynamic, shuffle…) lives
        // in this file; a copy brings exactly that back if a plain picture
        // path is not enough.
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let copy = Self.folder.appendingPathComponent(Self.storeBackupName)
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: Self.wallpaperStore, to: copy)
        LockIslandLog.record("system wallpaper: saved the user's wallpaper (\(saved.count) screen(s))")
    }

    private func restoreIfNeeded(reason: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.backupKey),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else {
            applied = false
            lastKey = ""
            return
        }
        let workspace = NSWorkspace.shared
        let storeCopy = Self.folder.appendingPathComponent(Self.storeBackupName)
        let storeData = try? Data(contentsOf: storeCopy)
        // Aerial and other non-picture wallpapers can't be set back through
        // a file path — put macOS's own wallpaper record back instead.
        let special = storeData.map { data in
            let text = String(decoding: data, as: UTF8.self).lowercased()
            return text.contains("aerial") || text.contains("shuffle") || text.contains("dynamic")
        } ?? false
        var restored = 0
        for screen in NSScreen.screens {
            let id = Self.number(of: screen)
            guard let item = saved.first(where: { $0.screen == id }) ?? saved.first else { continue }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = item.scaling { options[.imageScaling] = scaling }
            if let clipping = item.clipping { options[.allowClipping] = clipping }
            if let c = item.color, c.count == 4 {
                options[.fillColor] = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            }
            if (try? workspace.setDesktopImageURL(URL(fileURLWithPath: item.url), for: screen, options: options)) != nil {
                restored += 1
            }
        }
        if special, let storeData {
            restoreStore(storeData)
        }
        UserDefaults.standard.removeObject(forKey: Self.backupKey)
        applied = false
        lastKey = ""
        LockIslandLog.record("system wallpaper: user's wallpaper back (\(reason), \(restored) screen(s), full=\(special))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard self?.applied == false else { return }
            self?.cleanOldFiles(keeping: [Self.storeBackupName])
        }
    }

    private func restoreStore(_ data: Data) {
        do {
            try data.write(to: Self.wallpaperStore, options: .atomic)
            // The wallpaper agent re-reads its record when it starts again.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["WallpaperAgent"]
            try task.run()
        } catch {
            LockIslandLog.record("system wallpaper: could not restore the wallpaper record — \(error.localizedDescription)")
        }
    }

    private func cleanOldFiles(keeping: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.folder.path) else { return }
        for name in names where !keeping.contains(name) && name.hasPrefix("lock-") {
            try? fm.removeItem(at: Self.folder.appendingPathComponent(name))
        }
    }

    // MARK: Pictures

    private static func save(_ image: CGImage) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A new name every time: macOS caches desktop pictures by path.
        let url = folder.appendingPathComponent("lock-\(UUID().uuidString).jpg")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    private static func videoStill(_ path: String, size: CGSize) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    // Like an iPhone with music: the artwork, blurred, fills the screen and
    // the sharp artwork sits between the clock and the login.
    static func renderArtwork(_ art: CGImage, size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        // Background: blurred, a bit more saturated, slightly darkened.
        let input = CIImage(cgImage: art)
        let fill = max(bounds.width / input.extent.width, bounds.height / input.extent.height) * 1.15
        let scaled = input.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY))
        let blurred = centered.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: bounds.height / 18])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35,
                                                            kCIInputBrightnessKey: -0.08])
            .cropped(to: bounds)
        if let background = ciContext.createCGImage(blurred, from: bounds) {
            context.draw(background, in: bounds)
        }
        context.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.fill(bounds)

        // The sharp artwork, centred a little above the middle.
        let side = bounds.height * 0.30
        let center = CGPoint(x: bounds.midX, y: bounds.height * 0.50)
        let aspect = CGFloat(art.width) / CGFloat(max(1, art.height))
        let w = aspect >= 1 ? side : side * aspect
        let h = aspect >= 1 ? side / aspect : side
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: min(w, h) * 0.06, cornerHeight: min(w, h) * 0.06, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.03), blur: side * 0.12,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(art, in: rect)
        context.restoreGState()
        return context.makeImage()
    }
}
