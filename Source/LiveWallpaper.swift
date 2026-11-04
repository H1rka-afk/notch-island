import AppKit
import AVFoundation
import CoreImage
import Combine
import SwiftUI

// 4.9.0 — live wallpapers for the desktop and the lock screen.
//
// • «Обложка»: the playing cover, hugely blurred, slowly drifting (slower on
//   pause); without music nothing is drawn and the usual wallpaper shows.
// • «Переливы»: a mesh of the cover's (or the theme's) colours flowing.
// • «Видео»: the user's own clip, looped, without sound.
//
// The desktop copy is a borderless window at the desktop level — under the
// icons and every window, over the system picture. It never takes clicks
// and stops drawing whenever it cannot be seen (covered, locked, asleep),
// and on battery if asked. The system wallpaper itself is never changed.
enum LiveWallpaperSettings {
    static let modeKey = "liveWallpaperModeV490"
    static let desktopKey = "liveWallpaperDesktopV490"
    static let lockKey = "liveWallpaperLockV490"
    static let qualityKey = "liveWallpaperQualityV490"
    static let fpsKey = "liveWallpaperFPSV490"
    static let batteryKey = "liveWallpaperBatteryPauseV490"
    static let videoKey = "liveWallpaperVideoV490"

    static let modes: [(id: String, title: String)] = [
        ("off", "Выкл"), ("cover", "Обложка"), ("aurora", "Переливы"), ("video", "Видео")
    ]
    static let qualities: [(value: Double, title: String)] = [
        (0.5, "Экономно"), (0.75, "Баланс"), (1.0, "Максимум")
    ]
    static let fpsChoices = [15, 24, 30, 60]

    private static var d: UserDefaults { .standard }
    static var mode: String { d.string(forKey: modeKey) ?? "off" }
    static var onDesktop: Bool { (d.object(forKey: desktopKey) as? Bool) ?? true }
    static var onLock: Bool { (d.object(forKey: lockKey) as? Bool) ?? true }
    static var quality: Double { (d.object(forKey: qualityKey) as? Double) ?? 0.75 }
    static var fps: Int {
        let v = d.integer(forKey: fpsKey)
        return fpsChoices.contains(v) ? v : 30
    }
    static var pauseOnBattery: Bool { (d.object(forKey: batteryKey) as? Bool) ?? true }
    static var videoPath: String { d.string(forKey: videoKey) ?? "" }
}

// Whether one wallpaper window should be drawing right now.
final class LiveWallpaperActivity: ObservableObject {
    @Published var running = false
    // 4.9.3: true once there is a real picture (for a video: its first
    // frame is ready). The lock-screen copy stays invisible until then, so
    // a video that cannot play there never leaves a black screen.
    @Published var contentReady = false
}

struct LiveWallpaperView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var activity: LiveWallpaperActivity
    // 4.9.3: on the lock screen the window covers the system clock and the
    // login — draw our own clock, picture, name and hint where they are
    // (the real login keeps working underneath, as with the cover).
    var lockScreen = false
    @ObservedObject private var palette = CoverPalette.shared
    @AppStorage(LiveWallpaperSettings.modeKey) private var mode = "off"
    @AppStorage(LiveWallpaperSettings.qualityKey) private var quality = 0.75
    @AppStorage(LiveWallpaperSettings.fpsKey) private var fps = 30
    @AppStorage(LiveWallpaperSettings.videoKey) private var videoPath = ""
    @AppStorage(SystemLockWallpaperSettings.enabledKey) private var systemLogin = true

    private var fpsValue: Double { Double(LiveWallpaperSettings.fpsChoices.contains(fps) ? fps : 30) }

    var body: some View {
        Group {
            switch mode {
            case "cover":
                if let image = state.musicArtwork {
                    LiveCoverLayers(image: image, playing: state.track?.isPlaying == true,
                                    fps: fpsValue, quality: quality, running: activity.running)
                        .transition(.opacity)
                } else {
                    Color.clear
                }
            case "aurora":
                LiveMeshLayers(colors: auroraColors, fps: fpsValue, quality: quality, running: activity.running)
            case "video":
                if videoPath.isEmpty {
                    Color.clear
                } else {
                    LoopingVideoView(path: videoPath, running: activity.running,
                                     copyFrames: lockScreen, fps: fpsValue) { ready in
                        if activity.contentReady != ready { activity.contentReady = ready }
                    }
                }
            default:
                Color.clear
            }
        }
        .animation(.easeInOut(duration: 0.8), value: state.musicArtwork.map(ObjectIdentifier.init))
        .overlay {
            if lockScreen { LockScreenChrome(hints: !systemLogin) }
        }
        .mask { if lockScreen && systemLogin { LoginWindowMask() } else { Color.black } }
        .ignoresSafeArea()
        .onAppear { updateReady() }
        .onChange(of: mode) { _, _ in updateReady() }
        .onChange(of: state.musicArtwork.map(ObjectIdentifier.init)) { _, _ in updateReady() }
    }

    private func updateReady() {
        switch mode {
        case "cover": activity.contentReady = state.musicArtwork != nil
        case "aurora": activity.contentReady = true
        case "video": break        // reported by the player itself
        default: activity.contentReady = false
        }
    }

    private var auroraColors: [Color] {
        if state.track != nil { return palette.colors.map(\.color) }
        let theme = SettingsTheme.current.palette
        return theme.count >= 2 ? theme : CoverPalette.fallback.map(\.color)
    }
}

// MARK: Cover

struct LiveCoverLayers: View {
    let image: NSImage
    let playing: Bool
    let fps: Double
    let quality: Double
    let running: Bool
    @StateObject private var phase = LivingPhase()

    // Drawn small and scaled up (it is a blur anyway): less work at lower
    // quality.
    private var downscale: CGFloat { quality >= 0.99 ? 5 : (quality >= 0.74 ? 8 : 12) }
    private var moving: Bool { running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !moving)) { context in
                let t = moving ? phase.advance(to: context.date, speed: playing ? 1 : 0.3) : phase.value
                layers(size: size, t: t)
            }
        }
    }

    private func layers(size: CGSize, t: Double) -> some View {
        let k = downscale
        let small = CGSize(width: size.width / k * 1.3, height: size.height / k * 1.3)
        let side = max(small.width, small.height)
        return ZStack {
            Color.black
            layer(side: side * 1.5, angle: t * 7, dx: sin(t * 0.21) * 0.16, dy: cos(t * 0.17) * 0.12,
                  scale: 1.0 + 0.10 * sin(t * 0.13), small: small, opacity: 1)
            layer(side: side * 1.1, angle: -t * 9 + 120, dx: cos(t * 0.19 + 1.3) * 0.22, dy: sin(t * 0.23 + 0.4) * 0.18,
                  scale: 1.0 + 0.14 * cos(t * 0.11), small: small, opacity: 0.8)
            layer(side: side * 0.8, angle: t * 12 + 240, dx: sin(t * 0.27 + 2.1) * 0.25, dy: cos(t * 0.15 + 2.7) * 0.22,
                  scale: 1.0 + 0.18 * sin(t * 0.17 + 1), small: small, opacity: 0.7)
            Color.black.opacity(0.18)
        }
        .frame(width: small.width, height: small.height)
        .blur(radius: 72 / k)
        .saturation(1.5)
        .drawingGroup()
        .scaleEffect(k)
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func layer(side: CGFloat, angle: Double, dx: Double, dy: Double, scale: Double,
                       small: CGSize, opacity: Double) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.low)
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(Circle())
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle))
            .offset(x: small.width * dx, y: small.height * dy)
            .opacity(opacity)
    }
}

// MARK: Flowing colours

struct LiveMeshLayers: View {
    let colors: [Color]
    let fps: Double
    let quality: Double
    let running: Bool
    @StateObject private var phase = LivingPhase()

    private var downscale: CGFloat { quality >= 0.99 ? 4 : (quality >= 0.74 ? 6 : 10) }
    private var moving: Bool { running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !moving)) { context in
                let t = moving ? phase.advance(to: context.date, speed: 1) : phase.value
                content(t: t)
                    .frame(width: size.width / downscale, height: size.height / downscale)
                    .blur(radius: 4)
                    .drawingGroup()
                    .scaleEffect(downscale)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
        }
        .background(Color.black)
    }

    private func color(_ i: Int) -> Color {
        guard !colors.isEmpty else { return .purple }
        return colors[i % colors.count]
    }

    @ViewBuilder
    private func content(t: Double) -> some View {
        if #available(macOS 15.0, *) {
            mesh(t: t)
        } else {
            blobs(t: t)
        }
    }

    @available(macOS 15.0, *)
    private func mesh(t: Double) -> some View {
        func p(_ x: Double, _ y: Double) -> SIMD2<Float> { SIMD2(Float(x), Float(y)) }
        let points: [SIMD2<Float>] = [
            p(0, 0), p(0.5 + 0.1 * sin(t * 0.21), 0), p(1, 0),
            p(0, 0.5 + 0.1 * cos(t * 0.19)),
            p(0.5 + 0.18 * sin(t * 0.23), 0.5 + 0.16 * cos(t * 0.17)),
            p(1, 0.5 + 0.1 * sin(t * 0.25 + 1)),
            p(0, 1), p(0.5 + 0.1 * cos(t * 0.2 + 2), 1), p(1, 1)
        ]
        let dark = Color.black
        let cols: [Color] = [
            color(0), dark, color(1),
            dark.opacity(0.6), color(Int(t / 9) + 2).opacity(0.9), dark,
            color(3), dark, color(0).opacity(0.85)
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: cols, smoothsColors: true)
            .saturation(1.2)
    }

    private func blobs(t: Double) -> some View {
        GeometryReader { g in
            let s = g.size
            let d = max(s.width, s.height)
            ZStack {
                Color.black
                Circle().fill(color(0)).frame(width: d * 0.8, height: d * 0.8)
                    .position(x: s.width * (0.3 + 0.2 * sin(t * 0.2)), y: s.height * (0.3 + 0.2 * cos(t * 0.17)))
                Circle().fill(color(1)).frame(width: d * 0.7, height: d * 0.7)
                    .position(x: s.width * (0.75 + 0.18 * cos(t * 0.23)), y: s.height * (0.7 + 0.2 * sin(t * 0.19)))
                Circle().fill(color(2)).frame(width: d * 0.5, height: d * 0.5)
                    .position(x: s.width * (0.6 + 0.25 * sin(t * 0.15 + 2)), y: s.height * (0.35 + 0.25 * cos(t * 0.21 + 1)))
            }
            .blur(radius: d / 10)
        }
    }
}

// MARK: Video

struct LoopingVideoView: NSViewRepresentable {
    let path: String
    let running: Bool
    // 4.9.3: on the lock screen frames are copied into an ordinary layer —
    // a video layer is not always composited in the protected lock space.
    var copyFrames = false
    var fps: Double = 30
    var onReady: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> LoopingVideoNSView {
        // 4.10.2: frames are always copied into a plain layer that keeps the
        // last picture — a video layer goes empty for a moment when the
        // video starts over, and the real wallpaper flashed through.
        _ = copyFrames
        let view = LoopingVideoNSView(copyFrames: true)
        view.onReady = onReady
        view.fps = fps
        view.load(path)
        view.setRunning(running)
        return view
    }

    func updateNSView(_ view: LoopingVideoNSView, context: Context) {
        view.fps = fps
        view.load(path)
        view.setRunning(running)
    }

    static func dismantleNSView(_ view: LoopingVideoNSView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingVideoNSView: NSView {
    var onReady: (Bool) -> Void = { _ in }
    var fps: Double = 30
    private let copyFrames: Bool
    private var readyObservation: NSKeyValueObservation?
    private let playerLayer = AVPlayerLayer()
    private let frameLayer = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var frameTimer: Timer?
    private var shownBuffers: [CVPixelBuffer] = []
    private var loadedPath = ""
    private var reportedReady = false
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(copyFrames: Bool) {
        self.copyFrames = copyFrames
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        if copyFrames {
            frameLayer.contentsGravity = .resizeAspectFill
            frameLayer.masksToBounds = true
            layer?.addSublayer(frameLayer)
        } else {
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { self?.report(ready) }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    private func report(_ ready: Bool) {
        guard ready != reportedReady else { return }
        reportedReady = ready
        onReady(ready)
    }

    func load(_ path: String) {
        guard path != loadedPath else { return }
        stop()
        loadedPath = path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        self.looper = looper
        player = queue
        if copyFrames {
            // 4.9.4: the looper makes its copies of the item only after the
            // file is read, so outputs are attached lazily (see output(for:)).
            for looped in looper.loopingPlayerItems { _ = output(for: looped) }
            loadStarted = CACurrentMediaTime()
            loggedProblem = false
            loadPoster(path)
        } else {
            playerLayer.player = queue
        }
    }

    func setRunning(_ running: Bool) {
        guard let player else { return }
        if running {
            if player.rate == 0 { player.play() }
            if copyFrames && frameTimer == nil { startFrames() }
        } else {
            if player.rate != 0 { player.pause() }
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func startFrames() {
        let timer = Timer(timeInterval: 1.0 / max(10, min(60, fps)), repeats: true) { [weak self] _ in self?.copyFrame() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func output(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let existing = outputs[ObjectIdentifier(item)] { return existing }
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        outputs[ObjectIdentifier(item)] = output
        return output
    }

    // 4.9.4: a still of the chosen video is shown at once, so the lock
    // screen always has the user's wallpaper — even before (or without)
    // the first decoded frame.
    private var hasVideoFrame = false

    private func loadPoster(_ path: String) {
        hasVideoFrame = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 2400)
            let cg = try? generator.copyCGImage(at: .zero, actualTime: nil)
            DispatchQueue.main.async {
                guard let self, self.loadedPath == path else { return }
                guard let cg else {
                    LockIslandLog.record("live wallpaper: no still frame for the video")
                    return
                }
                if !self.hasVideoFrame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.frameLayer.contents = cg
                    CATransaction.commit()
                }
                self.report(true)
            }
        }
    }

    private var loadStarted: CFTimeInterval = 0
    private var loggedProblem = false

    private func copyFrame() {
        if let player, player.rate == 0, player.currentItem != nil { player.play() }
        guard let item = player?.currentItem else { logIfStuck(nil); return }
        let output = output(for: item)
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            logIfStuck(item)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            // No copy: the layer shows the decoded frame itself. The buffer
            // is kept so the decoder does not reuse it while it is on screen.
            frameLayer.contents = surface
            shownBuffers = [buffer] + shownBuffers.prefix(1)
        } else {
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = Self.ciContext.createCGImage(image, from: image.extent) { frameLayer.contents = cg }
        }
        CATransaction.commit()
        hasVideoFrame = true
        report(true)
    }

    private func logIfStuck(_ item: AVPlayerItem?) {
        guard !hasVideoFrame, !loggedProblem, CACurrentMediaTime() - loadStarted > 4 else { return }
        loggedProblem = true
        let status = item.map { "\($0.status.rawValue)" } ?? "no item"
        let error = item?.error.map { "\($0)" } ?? "-"
        LockIslandLog.record("live wallpaper: no frames yet (item=\(status), rate=\(player?.rate ?? -1), "
                             + "loops=\(looper?.loopingPlayerItems.count ?? -1), looper=\(looper?.status.rawValue ?? -1), error=\(error))")
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        outputs = [:]
        playerLayer.player = nil
        loadedPath = ""
    }
}

// MARK: Desktop

// One window per display, at the desktop level, under the icons.
final class DesktopWallpaperController: NSObject {
    private let state: IslandState
    private var windows: [(window: NSWindow, activity: LiveWallpaperActivity)] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var defaultsDebounce: DispatchWorkItem?
    private var timer: Timer?
    private var locked = false
    private var asleep = false

    init(state: IslandState) {
        self.state = state
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.defaultsChanged() })
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil,
                                                 queue: .main) { [weak self] _ in self?.asleep = true; self?.updateRunning() })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                                 queue: .main) { [weak self] _ in self?.asleep = false; self?.updateRunning() })
        let dc = DistributedNotificationCenter.default()
        distributedObservers.append(dc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                                   queue: .main) { [weak self] _ in self?.locked = true; self?.updateRunning() })
        distributedObservers.append(dc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                                   queue: .main) { [weak self] _ in self?.locked = false; self?.updateRunning() })
        // Battery state is read from EnergySaver; check now and then.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.updateRunning() }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        rebuild()
    }

    private var wanted: Bool {
        LiveWallpaperSettings.mode != "off" && LiveWallpaperSettings.onDesktop
    }

    private var lastSignature = ""

    private func defaultsChanged() {
        defaultsDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let signature = "\(self.wanted)"
            if signature != self.lastSignature { self.rebuild() } else { self.updateRunning() }
        }
        defaultsDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func rebuild() {
        lastSignature = "\(wanted)"
        for entry in windows {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: entry.window)
            entry.activity.running = false
            entry.window.orderOut(nil)
            entry.window.contentView = nil
        }
        windows = []
        guard wanted else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            let activity = LiveWallpaperActivity()
            window.contentView = NSHostingView(rootView: LiveWallpaperView(state: state, activity: activity))
            window.setFrame(screen.frame, display: false)
            window.orderBack(nil)
            window.orderFrontRegardless()
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window)
            windows.append((window, activity))
        }
        updateRunning()
    }

    @objc private func occlusionChanged(_ note: Notification) { updateRunning() }

    func updateRunning() {
        let batteryStop = LiveWallpaperSettings.pauseOnBattery && EnergySaver.onBattery
        for entry in windows {
            let visible = entry.window.occlusionState.contains(.visible)
            let run = visible && !locked && !asleep && !batteryStop
            if entry.activity.running != run { entry.activity.running = run }
        }
    }
}

// A small live copy in Settings.
struct LiveWallpaperPreview: View {
    @ObservedObject var state: IslandState
    @StateObject private var activity = LiveWallpaperActivity()
    @AppStorage(LiveWallpaperSettings.modeKey) private var mode = "off"
    @AppStorage(LiveWallpaperSettings.videoKey) private var videoPath = ""

    var body: some View {
        ZStack {
            Color.black
            LiveWallpaperView(state: state, activity: activity)
            if (mode == "cover" && state.musicArtwork == nil) || (mode == "video" && videoPath.isEmpty) {
                Text(mode == "cover" ? "Включи музыку — здесь появится обложка" : "Выбери видео ниже")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .onAppear { activity.running = true }
        .onDisappear { activity.running = false }
    }
}

// MARK: 4.9.2 Saved wallpapers

// Videos used before, newest first, so they can be picked again with one
// click. Only paths are kept; files that were moved or deleted disappear.
enum LiveWallpaperLibrary {
    static let key = "liveWallpaperRecentVideosV492"
    static let limit = 12

    static var videos: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        return stored.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func remember(_ path: String) {
        guard !path.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func forget(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        UserDefaults.standard.set(list, forKey: key)
    }
}

// The list as an observable object, so the grid redraws on every change.
final class SavedVideos: ObservableObject {
    static let shared = SavedVideos()
    @Published private(set) var videos: [String]

    private init() {
        // A video chosen before 4.9.2 joins the list too.
        let current = LiveWallpaperSettings.videoPath
        let stored = UserDefaults.standard.stringArray(forKey: LiveWallpaperLibrary.key) ?? []
        if !current.isEmpty && !stored.contains(current) { LiveWallpaperLibrary.remember(current) }
        videos = LiveWallpaperLibrary.videos
    }

    func reload() {
        let fresh = LiveWallpaperLibrary.videos
        if fresh != videos { videos = fresh }
    }
    func remember(_ path: String) { LiveWallpaperLibrary.remember(path); reload() }
    func forget(_ path: String) { LiveWallpaperLibrary.forget(path); reload() }
}

// First-frame pictures of the saved videos, made off the main thread.
final class VideoThumbnails: ObservableObject {
    static let shared = VideoThumbnails()
    @Published private(set) var images: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "app.ovira.video-thumbnails", qos: .utility)

    func load(_ paths: [String]) {
        for path in paths where images[path] == nil && !pending.contains(path) {
            pending.insert(path)
            queue.async { [weak self] in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 200)
                let time = CMTime(seconds: 0.5, preferredTimescale: 600)
                let cg = try? generator.copyCGImage(at: time, actualTime: nil)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(path)
                    if let cg { self.images[path] = NSImage(cgImage: cg, size: .zero) }
                }
            }
        }
    }
}

// The grid of saved videos in Settings: click to use, «×» to forget.
struct SavedWallpapersGrid: View {
    @Binding var selection: String
    let accent: Color
    @ObservedObject private var thumbnails = VideoThumbnails.shared
    @ObservedObject private var library = SavedVideos.shared

    var body: some View {
        let videos = library.videos
        Group {
            if videos.isEmpty {
                Text("Здесь появятся видео, которые ты уже ставил на обои.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(14)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                    ForEach(videos, id: \.self) { path in
                        card(path)
                    }
                }
                .padding(12)
            }
        }
        .onAppear { library.reload(); thumbnails.load(library.videos) }
        .onChange(of: library.videos) { _, list in thumbnails.load(list) }
    }

    private func card(_ path: String) -> some View {
        let selected = path == selection
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                shape.fill(Color.black)
                if let image = thumbnails.images[path] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 74)
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? accent : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                Button {
                    library.forget(path)
                    if selection == path { selection = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Убрать из сохранённых (сам файл не удаляется)")
            }
            .overlay(alignment: .bottomLeading) {
                if selected {
                    Label("Сейчас", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(accent))
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = path; library.remember(path) }
        .help((path as NSString).lastPathComponent)
    }
}

// 4.9.3 — the lock screen's clock, the user's picture and name and the
// «Touch ID или пароль» hint, drawn over the live wallpaper at the places
// macOS uses (same as the artwork wallpaper). Pure picture, no input.
// 4.10.4: opaque down to the login, then fades out — macOS draws its real
// user picture, name and password field in the transparent part.
struct LoginWindowMask: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.73),
            .init(color: .clear, location: 0.80)
        ], startPoint: .top, endPoint: .bottom)
    }
}

struct LockScreenChrome: View {
    var hints = true
    @ObservedObject private var identity = LockUserIdentity.shared
    @AppStorage("lockCoverClockV372") private var showsClock = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // Gentle shading so the clock and the login stay readable.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.32), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.66),
                    .init(color: .black.opacity(0.4), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                if showsClock {
                    TimelineView(.everyMinute) { context in
                        ZStack {
                            Text(LockCoverWallpaper.date(context.date))
                                .font(.system(size: size.height * 0.025, weight: .semibold))
                                .position(x: size.width / 2, y: size.height * 0.1056)
                            Text(LockCoverWallpaper.time(context.date))
                                .font(.system(size: size.height * 0.119, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .position(x: size.width / 2, y: size.height * 0.187)
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    }
                }
                if hints {
                Group {
                    if let picture = identity.picture {
                        Image(nsImage: picture).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable()
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: size.height * 0.054, height: size.height * 0.054)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .position(x: size.width / 2, y: size.height * 0.8495)
                Text(identity.name)
                    .font(.system(size: max(12, size.height * 0.0150), weight: .semibold))
                    .foregroundStyle(.white)
                    .position(x: size.width / 2, y: size.height * 0.9033)
                Text("Touch ID или пароль")
                    .font(.system(size: max(11, size.height * 0.0128), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .position(x: size.width / 2, y: size.height * 0.9355)
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        }
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
        .onAppear { identity.refresh() }
    }
}
