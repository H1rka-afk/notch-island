import AppKit
import SwiftUI
import Darwin
import QuartzCore
import Combine

// A small off-screen roof keeps the black island visually attached to the
// top bezel while WindowServer switches from loginwindow to the desktop.
// It does not alter the visible bottom edge or the SkyLight space.
private let padlockTopBleed: CGFloat = 7

// Lock-screen windows must be allowed to sit flush against the physical
// camera notch. AppKit's default frame constraint can push a panel downward
// into the menu-bar safe area, making the symbol disappear behind the cutout.
// Buttons react to the very first click on a non-key panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// 3.9.2: the lock-screen editor takes the keyboard (Return = «Готово»).
private final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 3.9.1: the widgets preview moves with the mouse (drag anywhere on it).
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class LockIslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Non-sensitive diagnostics: no track data, passwords, window titles or tokens.
// 3.10.1: whether the artwork wallpaper is on screen. The cover windows are
// only made transparent when hidden — their SwiftUI content (blur, living
// background) kept drawing behind alpha 0. Now it is not built at all then.
final class LockCoverActivity: ObservableObject {
    static let shared = LockCoverActivity()
    // 3.16.3: the same switch for the player card and the widgets. Their
    // windows are only made transparent when hidden; the card's waveform
    // kept animating at 60 fps behind alpha 0 all day while music played.
    static let media = LockCoverActivity()
    static let widgets = LockCoverActivity()
    static let standby = LockCoverActivity()     // 4.0.0
    @Published private(set) var active = false
    private var token = UUID()

    func show() {
        token = UUID()
        if !active { active = true }
    }

    func hide(after delay: TimeInterval) {
        let current = UUID()
        token = current
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.token == current, self.active else { return }
            self.active = false
        }
    }
}

enum LockIslandLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchIsland-LockScreen.log")

    static func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// This deliberately has no keyboard, password, biometric or accessibility
// functionality. It only decorates an existing macOS lock/unlock transition.
private final class PadlockPresentation: ObservableObject {
    // One progress value drives the silhouette AND the glyph's horizontal
    // anchor. Separate implicit animations for frame, scale and opacity used
    // to leave the glyph hanging outside the retreating black surface.
    @Published var expansion: CGFloat = 0
    @Published var symbolOpacity: Double = 0
    @Published var surfaceOpacity: Double = 1
    @Published var unlocked = false

    func reset(expanded: Bool) {
        expansion = expanded ? 1 : 0
        symbolOpacity = expanded ? 1 : 0
        surfaceOpacity = 1
        unlocked = false
    }
}

private struct PadlockNotchView: View {
    @ObservedObject var notch: IslandState
    @ObservedObject var appearance: PadlockPresentation

    private var width: CGFloat {
        notch.notchWidth + 76 * min(1, max(0, appearance.expansion))
    }

    var body: some View {
        let contour = UnevenRoundedRectangle(topLeadingRadius: 0,
                                             bottomLeadingRadius: 17,
                                             bottomTrailingRadius: 17,
                                             topTrailingRadius: 0,
                                             style: .continuous)
        // The glyph and black silhouette are both children of this SAME
        // variable-width container. The container's stable outer frame is
        // independent of the private SkyLight window's fixed size.
        ZStack(alignment: .bottom) {
            contour.fill(Color.black)
                .frame(width: width, height: notch.notchHeight + padlockTopBleed)

            HStack(spacing: 0) {
                ZStack {
                    Image(systemName: "lock.fill")
                        .opacity(appearance.unlocked ? 0 : 1)
                    Image(systemName: "lock.open.fill")
                        .opacity(appearance.unlocked ? 1 : 0)
                }
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 38, height: notch.notchHeight)
                .offset(x: 2)
                .opacity(appearance.symbolOpacity)
                Spacer(minLength: 0)
            }
            .frame(width: width, height: notch.notchHeight)
        }
        .frame(width: notch.notchWidth + 96,
               height: notch.notchHeight + padlockTopBleed,
               alignment: .bottom)
        .opacity(appearance.surfaceOpacity)
        // No implicit or nested .animation modifiers: the controller gives
        // each entrance/unlock/retraction one explicit transaction.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A private, optional compatibility layer. Normal NSWindow levels do not
// reliably appear on the macOS loginwindow lock space; the SkyLight space at
// level 400 sometimes can. Every symbol is checked at runtime, and failure
// falls back to the ordinary screenSaver NSPanel without crashing.
private final class LockSpaceBridge {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CreateSpace = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias MoveWindow = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var move: MoveWindow?
    private var showSpaces: ShowSpaces?
    private var levelStatus: Int32 = -1
    private var showStatus: Int32 = -1
    private(set) var lastStatus = "Не проверено"
    // 3.8.7: each bridge owns one space; the artwork wallpaper may use a
    // lower absolute level to sit UNDER the login (user picture, password).
    private(set) var absoluteLevel: Int32
    private var setLevelFunction: SetLevel?

    init(level: Int32 = 400) {
        absoluteLevel = level
    }

    func updateLevel(_ level: Int32) {
        guard level != absoluteLevel else { return }
        absoluteLevel = level
        if space != 0, let setLevelFunction {
            levelStatus = setLevelFunction(connection, space, level)
            LockIslandLog.record("space level → \(level): \(levelStatus)")
        }
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    func attach(_ panel: NSWindow) -> Bool {
        // A non-zero SLSShowSpaces return code does not prove that moving a
        // window into the space will fail. Glimpse and SkyLightWindow issue
        // the move independently of this return value. Earlier versions
        // skipped the move entirely when show returned 0xB0000000.
        if space == 0 {
            if handle == nil {
                handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
            }
            guard let main = symbol("SLSMainConnectionID", as: MainConnection.self),
                  let create = symbol("SLSSpaceCreate", as: CreateSpace.self),
                  let level = symbol("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
                  let show = symbol("SLSShowSpaces", as: ShowSpaces.self),
                  let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: MoveWindow.self)
            else {
                lastStatus = "Не найдены функции SkyLight"
                LockIslandLog.record(lastStatus)
                return false
            }
            let cid = main()
            guard cid > 0 else {
                lastStatus = "Нет соединения с WindowServer"
                LockIslandLog.record(lastStatus)
                return false
            }
            let sid = create(cid, 1, 0)
            guard sid > 0 else {
                lastStatus = "Не удалось создать SkyLight space (id=\(sid))"
                LockIslandLog.record(lastStatus)
                return false
            }
            connection = cid
            space = sid
            self.move = add
            self.showSpaces = show
            setLevelFunction = level
            levelStatus = level(cid, sid, absoluteLevel)
            showStatus = show(cid, [NSNumber(value: sid)] as CFArray)
            LockIslandLog.record("space: level=\(levelStatus), show=\(showStatus)")
        } else if showStatus != 0, let showSpaces {
            // A transient WindowServer transition may change the result.
            // Retrying uses the same space rather than creating duplicates.
            showStatus = showSpaces(connection, [NSNumber(value: space)] as CFArray)
        }

        guard let move else {
            lastStatus = "Нет функции перемещения окна SkyLight"
            LockIslandLog.record(lastStatus)
            return false
        }
        guard panel.windowNumber > 0 else {
            lastStatus = "Окно ещё не создано (windowNumber=0)"
            LockIslandLog.record(lastStatus)
            return false
        }
        let moveStatus = move(connection, space,
                              [NSNumber(value: panel.windowNumber)] as CFArray, 7)
        lastStatus = "SkyLight: level=\(levelStatus), show=\(showStatus), move=\(moveStatus)"
        LockIslandLog.record(lastStatus)
        // Successful attachment is not a guarantee that the window will be
        // visible on the protected lock screen; only an on-device test can
        // confirm that. Keep the raw diagnostic values for further analysis.
        return levelStatus == 0 && moveStatus == 0
    }

    deinit {
        if let handle { dlclose(handle) }
    }
}

final class LockScreenOverlay {
    private let state: IslandState
    // Separate view models are essential: the loginwindow and desktop windows
    // must never animate the same state simultaneously. In particular, the
    // menu preview should not render into the protected SkyLight window.
    private let secureAppearance = PadlockPresentation()
    private let desktopAppearance = PadlockPresentation()
    private let bridge = LockSpaceBridge()
    // 3.8.7: own space for the artwork wallpaper, level from Settings.
    private let coverBridge = LockSpaceBridge(level: LockScreenOverlay.coverLayer)
    static let coverLayerKey = "lockCoverLayerV387"
    // 3.8.9: tested on macOS 27 — the lock wallpaper and the login are one
    // surface: any level that keeps the cover visible also covers the login,
    // lower ones hide it under the wallpaper. So the cover stays on top and
    // draws the user's picture and name itself (see LockCoverWallpaper).
    static var coverLayer: Int32 { 400 }
    private var window: LockIslandPanel?
    // A regular desktop panel is independent from the experimental lock space.
    // That ensures the unlock animation is visible after loginwindow dismisses.
    private var postUnlockWindow: LockIslandPanel?
    // 3.6.0: iPhone-style player on the lock screen (same SkyLight space).
    private var mediaWindow: LockIslandPanel?
    private var mediaPreviewWindow: LockIslandPanel?
    private var mediaToken = UUID()
    // 3.6.8: wallpaper under the card for the hand-made glass.
    private let backdrop = LockCardBackdrop()
    // 3.7.1: widgets under the clock.
    private var widgetsWindow: LockIslandPanel?
    // 3.7.2: artwork instead of the wallpaper.
    private var coverWindow: LockIslandPanel?
    // 4.9.0: the live wallpaper under everything on the lock screen.
    private var liveWindow: LockIslandPanel?
    private let liveActivity = LiveWallpaperActivity()
    private var liveShown = false
    private var liveReadyObserver: AnyCancellable?
    // 4.11.0: the video plays as the system Aerial under the real login —
    // the window copy steps aside once that has started.
    private var liveBySystem = false
    private var aerialObserver: NSObjectProtocol?
    private var coverPreviewWindow: LockIslandPanel?
    private var coverObserver: AnyCancellable?
    // 3.8.3: tapping the artwork on the wallpaper brings the wallpaper back.
    // A separate transparent target over the middle of the screen — the
    // wallpaper window itself never takes clicks, and the login area at the
    // bottom stays free.
    private var coverTapWindow: LockIslandPanel?
    private var coverTapPreviewWindow: LockIslandPanel?
    private var widgetsPreviewWindow: LockIslandPanel?
    private var widgetsToken = UUID()
    private var lastScreen: NSScreen?
    static let mediaKey = "lockScreenMediaV360"
    private var mediaEnabled: Bool { (UserDefaults.standard.object(forKey: Self.mediaKey) as? Bool) ?? true }
    private var generation = 0
    // The system posts more than one lock notification on some macOS
    // releases. Animate just once per locking cycle, but still retry SkyLight.
    private var lockPresentationActive = false
    private var previewMode = false
    private var enabled = (UserDefaults.standard.object(forKey: "enableLockIslandV21") as? Bool) ?? true
    private(set) var usesPrivateLockSpace = false
    var diagnosticSummary: String { bridge.lastStatus }
    static var diagnosticURL: URL { LockIslandLog.url }
    static func logSessionEvent(_ message: String) { LockIslandLog.record(message) }

    init(state: IslandState) {
        self.state = state
        aerialObserver = NotificationCenter.default.addObserver(forName: SystemLockWallpaper.aerialChanged,
                                                                object: nil, queue: .main) { [weak self] note in
            self?.aerialChanged(note.object as? String)
        }
        coverObserver = LockCardUIState.shared.$expanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.setCover(on) }
    }

    // MARK: Artwork wallpaper (3.7.2)

    private func makeCoverPanel(on screen: NSScreen, loginHole: Bool = false) -> LockIslandPanel {
        let panel = LockIslandPanel(contentRect: screen.frame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true      // never in the way of the login
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: LockCoverWallpaper(state: state, loginHole: loginHole))
        return panel
    }

    private func coverTapFrame(on screen: NSScreen) -> NSRect {
        // Exactly over the cover (3.8.4 size setting), never over the login.
        let f = screen.frame
        let scale = CGFloat(min(1, max(0.3, (UserDefaults.standard.object(forKey: "lockCoverScaleV384") as? Double) ?? 0.55)))
        let side = f.height * scale
        let centerY = f.maxY - f.height * LockCoverWallpaper.coverCenter
        // 3.8.10: reaches down over the picture and name too — a tap there
        // brings back the real macOS login (password field) at once.
        let bottom = f.minY + f.height * 0.03
        let top = min(f.maxY - f.height * 0.03, centerY + side / 2)
        return NSRect(x: f.midX - side / 2, y: bottom, width: side, height: max(40, top - bottom))
    }

    // 4.10.3: the big artwork of the system wallpaper (SystemLockWallpaper
    // draws it at the same place and size).
    static func artworkOnlyFrame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let side = f.height * SystemLockWallpaper.coverShare
        let centerY = f.maxY - f.height * LockCoverWallpaper.coverCenter
        return NSRect(x: f.midX - side / 2, y: centerY - side / 2, width: side, height: side)
    }

    private func makeCoverTapPanel() -> LockIslandPanel {
        let panel = LockIslandPanel(contentRect: .zero,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView:
            // Not 0.001: macOS treats pixels with alpha 0 (0.001 rounds to
            // 0) as holes and lets clicks fall through — the 3.8.3 bug.
            Color.black.opacity(0.02)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
                        LockCardUIState.shared.expanded = false
                    }
                }
                .accessibilityLabel("Вернуть обои"))
        return panel
    }

    private func showCoverTap(_ panel: LockIslandPanel, on screen: NSScreen, attach: Bool) {
        panel.setFrame(coverTapFrame(on: screen), display: false)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        if attach { _ = bridge.attach(panel) }
    }

    private func hideCoverTaps() {
        for panel in [coverTapWindow, coverTapPreviewWindow].compactMap({ $0 }) {
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
        }
        coverTapPreviewWindow?.orderOut(nil)
    }

    private func prepareCover(on screen: NSScreen) {
        if coverTapWindow == nil {
            let tap = makeCoverTapPanel()
            tap.level = NSWindow.Level(rawValue: Int(Int32.max - 3))
            tap.canBecomeVisibleWithoutLogin = true
            tap.setFrame(coverTapFrame(on: screen), display: false)
            tap.alphaValue = 0
            tap.orderFrontRegardless()
            _ = bridge.attach(tap)
            coverTapWindow = tap
        }
        if coverWindow == nil {
            let panel = makeCoverPanel(on: screen, loginHole: true)
            // Just below the card, padlock and widgets.
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 3))
            panel.canBecomeVisibleWithoutLogin = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let attached = coverBridge.attach(panel)
            coverWindow = panel
            LockIslandLog.record("cover: prepared private=\(attached) level=\(coverBridge.absoluteLevel)")
        }
        coverWindow?.setFrame(screen.frame, display: false)
    }

    private func fade(_ panel: NSWindow, to alpha: CGFloat, duration: TimeInterval = 0.5) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    private func setCover(_ on: Bool) {
        let lockedCardVisible = (mediaWindow?.alphaValue ?? 0) > 0.5 && mediaWindow?.ignoresMouseEvents == false
        let previewVisible = (mediaPreviewWindow?.isVisible ?? false) && (mediaPreviewWindow?.alphaValue ?? 0) > 0.5
        guard on else {
            hideCoverTaps()
            LockCoverActivity.shared.hide(after: 0.45)
            if let coverWindow, coverWindow.alphaValue > 0 { fade(coverWindow, to: 0, duration: 0.35) }
            if let coverPreviewWindow, coverPreviewWindow.alphaValue > 0 {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.35
                    coverPreviewWindow.animator().alphaValue = 0
                }, completionHandler: { [weak coverPreviewWindow] in coverPreviewWindow?.orderOut(nil) })
            }
            return
        }
        guard let screen = lastScreen ?? NSScreen.main else { return }
        // 4.10.2: with the real macOS login SystemLockWallpaper puts the
        // artwork into the system wallpaper — no window over the login.
        if lockedCardVisible, let panel = coverWindow {
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            coverBridge.updateLevel(Self.coverLayer)
            _ = coverBridge.attach(panel)
            LockIslandLog.record("cover: layer \(coverBridge.absoluteLevel) — \(coverBridge.lastStatus)")
            if let tap = coverTapWindow {
                showCoverTap(tap, on: screen, attach: true)
                // 4.10.4: with the real login under the window the tap target
                // is only the artwork itself.
                if SystemLockWallpaperSettings.enabled {
                    tap.setFrame(Self.artworkOnlyFrame(on: screen), display: false)
                }
            }
            // Keep the card and widgets above the new wallpaper.
            mediaWindow?.orderFrontRegardless()
            widgetsWindow?.orderFrontRegardless()
            LockCoverActivity.shared.show()
            fade(panel, to: 1)
            LockIslandLog.record("cover: artwork wallpaper on")
        } else if previewVisible {
            if coverPreviewWindow == nil {
                let panel = makeCoverPanel(on: screen)
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
                coverPreviewWindow = panel
            }
            guard let panel = coverPreviewWindow else { return }
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            LockCoverActivity.shared.show()
            panel.orderFrontRegardless()
            if coverTapPreviewWindow == nil {
                let tap = makeCoverTapPanel()
                tap.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
                coverTapPreviewWindow = tap
            }
            if let tap = coverTapPreviewWindow { showCoverTap(tap, on: screen, attach: false) }
            mediaPreviewWindow?.orderFrontRegardless()
            fade(panel, to: 1)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { hideImmediately() }
    }

    // MARK: Lock-screen player (3.6.0)

    private func makeMediaPanel() -> LockIslandPanel {
        let size = LockScreenMediaCard.panelSize
        let panel = LockIslandPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Clicks only while visible: an invisible panel must never swallow
        // clicks on the desktop. showMedia() turns them on.
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: LockScreenMediaCard(state: state, backdrop: backdrop))
        panel.contentView = host
        return panel
    }

    private func mediaFrame(on screen: NSScreen) -> NSRect {
        let scale = LockScreenMediaCard.currentScale
        let size = LockScreenMediaCard.panelSize(scale: scale)
        let margin = LockScreenMediaCard.margin * scale
        // Bottom centre, above the user picture and password field. The
        // panel is larger than the card by `margin` for shadow and rim.
        let bottom = screen.frame.minY + max(190, screen.frame.height * 0.235) - margin
        return NSRect(x: screen.frame.midX - size.width / 2, y: bottom,
                      width: size.width, height: size.height)
    }

    // MARK: Widgets under the clock (3.7.1; 3.9.2 — free placement)

    // A transparent full-screen canvas: every widget is drawn at its own
    // place. Look only on the lock screen.
    private func makeWidgetsPanel() -> LockIslandPanel {
        let panel = LockIslandPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: LockWidgetsView(model: LockWidgetsModel.shared, state: state))
        return panel
    }

    private func widgetsFrame(on screen: NSScreen) -> NSRect { screen.frame }

    // MARK: Lock-screen editor (3.9.2)

    private var widgetsEditor: NSPanel?

    // Opens a lock-screen look-alike over the desktop; stays until «Готово».
    func previewWidgets(on screen: NSScreen?) {
        guard let screen else { return }
        if let editor = widgetsEditor, editor.isVisible {
            editor.setFrame(screen.frame, display: true)
            return
        }
        let editor = EditorPanel(contentRect: screen.frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        editor.level = .screenSaver
        editor.isOpaque = true
        editor.backgroundColor = .black
        editor.hasShadow = false
        editor.hidesOnDeactivate = false
        editor.isReleasedWhenClosed = false
        editor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let wallpaper = EditorWallpaper()
        CurrentWallpaper.load(for: screen, into: wallpaper)
        editor.contentView = FirstClickHostingView(rootView: LockWidgetsEditor(
            model: LockWidgetsModel.shared, state: state, wallpaper: wallpaper,
            onDone: { [weak self] in self?.closeWidgetsEditor() }))
        editor.setFrame(screen.frame, display: false)
        editor.alphaValue = 0
        editor.makeKeyAndOrderFront(nil)
        editor.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            editor.animator().alphaValue = 1
        }
        widgetsEditor = editor
    }

    func closeWidgetsEditor() {
        guard let editor = widgetsEditor else { return }
        widgetsEditor = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            editor.animator().alphaValue = 0
        }, completionHandler: { editor.orderOut(nil) })
    }

    func resetWidgetsPosition(on screen: NSScreen?) {
        // 4.6.0: widgets stand in the row under the clock; nothing to reset.
    }

    private func prepareWidgets(on screen: NSScreen) {
        if widgetsWindow == nil {
            let panel = makeWidgetsPanel()
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            panel.canBecomeVisibleWithoutLogin = true
            panel.setFrame(widgetsFrame(on: screen), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let attached = bridge.attach(panel)
            widgetsWindow = panel
            LockIslandLog.record("widgets: prepared private=\(attached)")
        } else {
            widgetsWindow?.setFrame(widgetsFrame(on: screen), display: false)
        }
    }

    private func showWidgets() {
        let model = LockWidgetsModel.shared
        guard model.enabled, !model.selected.isEmpty, let panel = widgetsWindow else { return }
        widgetsToken = UUID()
        if let screen = lastScreen { panel.setFrame(widgetsFrame(on: screen), display: false) }
        LockCoverActivity.widgets.show()
        panel.orderFrontRegardless()
        _ = bridge.attach(panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        LockIslandLog.record("widgets: shown (\(model.items.count))")
    }

    // MARK: Live wallpaper (4.9.0)

    private func showLiveWallpaper() {
        // 4.10.4: with the real macOS login the window leaves the login area
        // transparent (LoginWindowMask); a still of the same wallpaper is the
        // system wallpaper there (SystemLockWallpaper).
        guard LiveWallpaperSettings.onLock, LiveWallpaperSettings.mode != "off",
              let screen = lastScreen ?? NSScreen.main else {
            hideLiveWallpaper()
            return
        }
        let panel: LockIslandPanel
        if let existing = liveWindow {
            panel = existing
        } else {
            panel = LockIslandPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true      // never in the way of the login
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.canBecomeVisibleWithoutLogin = true
            // Under the artwork wallpaper, the card and the widgets.
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 4))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: LiveWallpaperView(state: state, activity: liveActivity,
                                                                          lockScreen: true))
            panel.alphaValue = 0
            liveWindow = panel
            // 4.9.3: visible only while there is a real picture.
            liveReadyObserver = liveActivity.$contentReady
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] ready in self?.liveReadyChanged(ready) }
        }
        panel.setFrame(screen.frame, display: false)
        liveActivity.running = true
        panel.orderFrontRegardless()
        _ = coverBridge.attach(panel)
        // Everything else stays above the live wallpaper.
        coverWindow?.orderFrontRegardless()
        mediaWindow?.orderFrontRegardless()
        widgetsWindow?.orderFrontRegardless()
        liveShown = true
        if liveActivity.contentReady && !liveBySystem { fade(panel, to: 1, duration: 0.6) }
        LockIslandLog.record("live wallpaper: on (\(LiveWallpaperSettings.mode)) ready=\(liveActivity.contentReady)")
    }

    private func aerialChanged(_ kind: String?) {
        let bySystem = kind == "video"
        liveBySystem = bySystem
        guard liveShown, let panel = liveWindow else { return }
        if bySystem {
            // A moment for the wallpaper agent to start the video.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.liveBySystem, self.liveShown else { return }
                self.fade(panel, to: 0, duration: 0.8)
                LockIslandLog.record("live wallpaper: window hidden, the system plays the video")
            }
        } else if liveActivity.contentReady {
            fade(panel, to: 1, duration: 0.4)
        }
    }

    private func liveReadyChanged(_ ready: Bool) {
        guard liveShown, !liveBySystem, let panel = liveWindow else { return }
        LockIslandLog.record("live wallpaper: ready=\(ready)")
        fade(panel, to: ready ? 1 : 0, duration: ready ? 0.6 : 0.2)
    }

    private func hideLiveWallpaper() {
        liveShown = false
        liveActivity.running = false
        liveWindow?.alphaValue = 0
    }

    private func hideWidgets(animated: Bool) {
        hideLiveWallpaper()
        LockCoverActivity.widgets.hide(after: animated ? 0.3 : 0)
        guard let panel = widgetsWindow, panel.alphaValue > 0 else { return }
        widgetsToken = UUID()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            }
        } else {
            panel.alphaValue = 0
        }
    }

    private func prepareMedia(on screen: NSScreen) {
        lastScreen = screen
        prepareCover(on: screen)
        prepareWidgets(on: screen)
        if mediaWindow == nil {
            let panel = makeMediaPanel()
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            panel.canBecomeVisibleWithoutLogin = true
            panel.setFrame(mediaFrame(on: screen), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let attached = bridge.attach(panel)
            mediaWindow = panel
            LockIslandLog.record("media: prepared private=\(attached)")
        } else {
            mediaWindow?.setFrame(mediaFrame(on: screen), display: false)
        }
    }

    private func showMedia() {
        guard mediaEnabled, let panel = mediaWindow else { return }
        LockCardUIState.shared.expanded = false
        mediaToken = UUID()
        if let screen = lastScreen {
            let frame = mediaFrame(on: screen)
            panel.setFrame(frame, display: false)
        }
        panel.ignoresMouseEvents = false     // play / pause / next on the lock screen
        LockCoverActivity.media.show()
        panel.orderFrontRegardless()
        _ = bridge.attach(panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        LockIslandLog.record("media: shown on lock screen (track=\(state.track != nil))")
    }

    private func hideMedia(animated: Bool) {
        LockCoverActivity.media.hide(after: animated ? 0.3 : 0)
        guard let panel = mediaWindow else { return }
        panel.ignoresMouseEvents = true
        hideCoverTaps()
        LockCoverActivity.shared.hide(after: animated ? 0.3 : 0)
        if let coverWindow, coverWindow.alphaValue > 0 {
            if animated { fade(coverWindow, to: 0, duration: 0.22) } else { coverWindow.alphaValue = 0 }
        }
        // Next lock starts with the compact card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LockCardUIState.shared.expanded = false }
        guard panel.alphaValue > 0 else { return }
        mediaToken = UUID()
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            })
        } else {
            panel.alphaValue = 0
        }
    }

    // Desktop preview from Settings: the same card for five seconds.
    func previewMedia(on screen: NSScreen?) {
        guard let screen else { return }
        if mediaPreviewWindow == nil {
            let panel = makeMediaPanel()
            panel.level = .screenSaver
            mediaPreviewWindow = panel
        }
        guard let panel = mediaPreviewWindow else { return }
        panel.setFrame(mediaFrame(on: screen), display: false)
        panel.ignoresMouseEvents = false
        LockCoverActivity.media.show()
        if !(panel.isVisible && panel.alphaValue > 0.5) {
            // Already on screen (e.g. switching glass modes): just keep it longer.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 1
            }
        }
        let token = UUID()
        mediaToken = token
        // A little longer, so the artwork wallpaper can be tried out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak panel] in
            guard let self, self.mediaToken == token, let panel else { return }
            LockCardUIState.shared.expanded = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
            LockCoverActivity.media.hide(after: 0.35)
        }
    }

    func prepare(on screen: NSScreen?) {
        guard let screen else { return }
        if window == nil {
            let panel = LockIslandPanel(contentRect: NSRect(x: 0, y: 0, width: state.notchWidth + 96, height: state.notchHeight + padlockTopBleed),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.canBecomeVisibleWithoutLogin = true
            // Same high, non-interactive overlay level used by open-source
            // SkyLight lock-screen UI implementations (e.g. Glimpse, MIT).
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: PadlockNotchView(notch: state, appearance: secureAppearance))
            window = panel
            reposition(on: screen)
            panel.alphaValue = 0
            // Create and attach to the special space *while unlocked*.
            panel.orderFrontRegardless()
            usesPrivateLockSpace = bridge.attach(panel)
            LockIslandLog.record("prepare: private=\(usesPrivateLockSpace), frame=\(NSStringFromRect(panel.frame))")
        }
        prepareMedia(on: screen)
        if postUnlockWindow == nil {
            let desktop = LockIslandPanel(contentRect: NSRect(x: 0, y: 0, width: state.notchWidth + 96, height: state.notchHeight + padlockTopBleed),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            desktop.backgroundColor = .clear
            desktop.isOpaque = false
            desktop.hasShadow = false
            desktop.hidesOnDeactivate = false
            desktop.ignoresMouseEvents = true
            desktop.isMovable = false
            desktop.isReleasedWhenClosed = false
            // Above the main media panel (.screenSaver) and the timer
            // satellite (.screenSaver + 1) during the unlock hand-off.
            // Otherwise a newly ordered media panel covers the padlock early.
            desktop.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            desktop.collectionBehavior = IslandWindowSpaces.foregroundBehavior
            desktop.contentView = NSHostingView(rootView: PadlockNotchView(notch: state, appearance: desktopAppearance))
            desktop.alphaValue = 0
            postUnlockWindow = desktop
        }
        reposition(on: screen)
    }

    func reposition(on screen: NSScreen?) {
        guard let screen, let window else { return }
        let width = state.notchWidth + 96
        let height = state.notchHeight + padlockTopBleed
        // Keep the BOTTOM edge fixed. The extra roof extends beyond the
        // screen's top boundary, so a brief WindowServer coordinate shift
        // cannot expose a gap above the animated padlock.
        let frame = NSRect(x: (state.notchCenterX ?? screen.frame.midX) - width / 2,
                           y: screen.frame.maxY - state.notchHeight,
                           width: width, height: height)
        window.setFrame(frame, display: false)
        postUnlockWindow?.setFrame(frame, display: false)
        lastScreen = screen
        mediaWindow?.setFrame(mediaFrame(on: screen), display: false)
        widgetsWindow?.setFrame(widgetsFrame(on: screen), display: false)
    }

    func showLocked(forcePreview: Bool = false) {
        // The lock-screen player is independent of the padlock switch.
        if !forcePreview { showLiveWallpaper(); showMedia(); showWidgets() }
        guard enabled || forcePreview, let window else { return }
        // Duplicate session lock notifications may require a new SkyLight
        // attachment, but must not restart the entrance animation.
        if lockPresentationActive && !forcePreview && !previewMode {
            window.alphaValue = 1
            window.orderFrontRegardless()
            usesPrivateLockSpace = bridge.attach(window)
            return
        }

        generation += 1
        let token = generation
        lockPresentationActive = true
        previewMode = forcePreview
        let presenter = forcePreview ? desktopAppearance : secureAppearance
        presenter.reset(expanded: false)

        if forcePreview {
            // Critical fix: the old preview showed BOTH windows at alpha=1.
            // On some macOS versions the private-space window was visible on
            // the desktop too, creating a duplicate grey lock and contour.
            window.alphaValue = 0
            window.orderOut(nil)
            guard let desktop = postUnlockWindow else { return }
            desktop.alphaValue = 0
            desktop.orderFrontRegardless()
            desktop.contentView?.needsDisplay = true
            desktop.displayIfNeeded()
            desktop.alphaValue = 1
            LockIslandLog.record("preview: desktop panel only; SkyLight panel hidden")
        } else {
            // 3.0.10 REGRESSION: revealing the desktop backing here made a
            // second opaque island visible throughout the protected session.
            // It competed with the SkyLight padlock and could survive into the
            // desktop as a ghost. Only the protected panel participates in a
            // real lock; the desktop preview panel must remain hidden.
            desktopAppearance.reset(expanded: false)
            postUnlockWindow?.alphaValue = 0
            postUnlockWindow?.orderOut(nil)
            window.alphaValue = 1
            window.orderFrontRegardless()
            usesPrivateLockSpace = bridge.attach(window)
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
            LockIslandLog.record("lock: private=\(usesPrivateLockSpace); \(bridge.lastStatus); frame=\(NSStringFromRect(window.frame))")
        }

        // One animation controls width. Start symbol opacity only after
        // the expanding left wing can safely contain the glyph.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self, self.generation == token, self.lockPresentationActive else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) {
                presenter.expansion = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self, self.generation == token, self.lockPresentationActive else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                presenter.symbolOpacity = 1
            }
        }
    }

    // Check on the next compositor turns without creating a second desktop
    // lock window. A finite retry budget avoids retaining a protected window
    // indefinitely if AppKit never makes the media panel visible.
    private func retireSecureAfterDesktopReady(token: Int,
                                               readiness: @escaping () -> Bool,
                                               remainingAttempts: Int,
                                               completion: @escaping () -> Void) {
        guard generation == token else { return }
        if !readiness() && remainingAttempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
                self?.retireSecureAfterDesktopReady(token: token,
                                                    readiness: readiness,
                                                    remainingAttempts: remainingAttempts - 1,
                                                    completion: completion)
            }
            return
        }
        let ready = readiness()
        window?.alphaValue = 0
        window?.orderOut(nil)
        secureAppearance.reset(expanded: false)
        LockIslandLog.record(ready
            ? "unlock: secure retired after desktop island committed"
            : "unlock: desktop readiness timeout; secure panel retired")
        completion()
    }

    func animateUnlock(beginMediaTransition: @escaping () -> Void,
                       isDesktopReady: @escaping () -> Bool = { true },
                       completion: @escaping () -> Void) {
        hideMedia(animated: false); hideWidgets(animated: false)
        guard enabled, let desktop = postUnlockWindow else {
            hideImmediately()
            beginMediaTransition()
            completion()
            return
        }
        generation += 1
        let token = generation
        let isPreview = previewMode
        previewMode = false
        lockPresentationActive = false

        if !isPreview {
            hideMedia(animated: false); hideWidgets(animated: false)
            // On the real lock screen, the protected SkyLight panel is the
            // ONLY lock island. After unlock the normal media panel draws the
            // open-padlock transition inside its own SwiftUI canvas. No
            // separate desktop padlock NSWindow is shown or animated here.
            desktop.alphaValue = 0
            desktop.orderOut(nil)
            beginMediaTransition()
            CATransaction.flush()
            // 65 ms was too short on the user's Mac. Keep the SAME SkyLight
            // surface until the regular NSPanel is ordered and its first
            // hosting-view frame has been explicitly flushed. The short
            // overlap prevents a blank physical-notch frame, with no second
            // desktop padlock NSWindow and no new entrance animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) { [weak self] in
                self?.retireSecureAfterDesktopReady(token: token,
                                                    readiness: isDesktopReady,
                                                    remainingAttempts: 9,
                                                    completion: completion)
            }
            return
        }

        // Settings preview is deliberately a different case: it is shown
        // only on the desktop and should still demonstrate the padlock.
        desktop.alphaValue = 1
        desktop.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, self.generation == token else { return }
            withAnimation(.easeInOut(duration: 0.27)) {
                self.desktopAppearance.unlocked = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.18) { [weak self] in
            guard let self, self.generation == token else { return }
            beginMediaTransition()
            withAnimation(.easeInOut(duration: 0.46)) {
                self.desktopAppearance.expansion = 0
                self.desktopAppearance.symbolOpacity = 0
                self.desktopAppearance.surfaceOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) { [weak self, weak desktop] in
            guard let self, self.generation == token, let desktop else { return }
            desktop.alphaValue = 0
            desktop.orderOut(nil)
            self.desktopAppearance.reset(expanded: false)
            completion()
            LockIslandLog.record("preview: desktop demonstration retired")
        }
    }

    // MARK: StandBy (4.0.0)

    private var standbyWindow: LockIslandPanel?
    var onStandByDismiss: (() -> Void)?
    private var standbyPreviewWindow: NSPanel?

    // Full screen, above the card and widgets, never taking a click: the
    // login stays under it (typing or a mouse move hides StandBy first).
    func setStandBy(_ on: Bool, on screen: NSScreen?) {
        if on {
            guard let screen = screen ?? lastScreen ?? NSScreen.main else { return }
            let panel: LockIslandPanel
            if let existing = standbyWindow {
                panel = existing
            } else {
                panel = LockIslandPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.isMovable = false
                panel.isReleasedWhenClosed = false
                panel.canBecomeVisibleWithoutLogin = true
                panel.acceptsMouseMovedEvents = true
                panel.level = NSWindow.Level(rawValue: Int(Int32.max - 1))
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                // 4.1.0: takes clicks — a click leaves StandBy, the music
                // island opens with one.
                panel.contentView = FirstClickHostingView(rootView: StandByView(
                    state: state, activity: LockCoverActivity.standby,
                    onDismiss: { [weak self] in self?.onStandByDismiss?() }))
                panel.alphaValue = 0
                standbyWindow = panel
            }
            panel.setFrame(screen.frame, display: false)
            LockCoverActivity.standby.show()
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            _ = bridge.attach(panel)
            fade(panel, to: 1, duration: 0.6)
            LockIslandLog.record("standby: on")
        } else {
            LockCoverActivity.standby.hide(after: 0.4)
            standbyWindow?.ignoresMouseEvents = true
            if let panel = standbyWindow, panel.alphaValue > 0 {
                fade(panel, to: 0, duration: 0.3)
                LockIslandLog.record("standby: off")
            }
        }
    }

    // Settings → «Показать»: StandBy on the desktop for 8 s, a click closes it.
    func previewStandBy(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let panel = standbyPreviewWindow ?? {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        standbyPreviewWindow = panel
        panel.contentView = FirstClickHostingView(rootView:
            StandByView(state: state, activity: LockCoverActivity.standby,
                        onDismiss: { [weak self] in self?.closeStandByPreview() }))
        panel.setFrame(screen.frame, display: false)
        LockCoverActivity.standby.show()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fade(panel, to: 1, duration: 0.4)
        let token = UUID()
        standbyPreviewToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.standbyPreviewToken == token else { return }
            self.closeStandByPreview()
        }
    }
    private var standbyPreviewToken = UUID()

    private func closeStandByPreview() {
        guard let panel = standbyPreviewWindow else { return }
        standbyPreviewToken = UUID()
        if standbyWindow?.alphaValue ?? 0 == 0 { LockCoverActivity.standby.hide(after: 0.35) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.contentView = nil
        })
    }

    func hideImmediately() {
        standbyWindow?.alphaValue = 0
        standbyWindow?.ignoresMouseEvents = true
        LockCoverActivity.standby.hide(after: 0)
        generation += 1
        lockPresentationActive = false
        previewMode = false
        hideMedia(animated: false)
        hideWidgets(animated: false)
        coverWindow?.alphaValue = 0
        LockCoverActivity.shared.hide(after: 0)
        window?.alphaValue = 0
        postUnlockWindow?.alphaValue = 0
        postUnlockWindow?.orderOut(nil)
        secureAppearance.reset(expanded: false)
        desktopAppearance.reset(expanded: false)
    }
}
