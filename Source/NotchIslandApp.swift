import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import Combine
import QuartzCore
import IOKit.ps
import Carbon
import ServiceManagement
import Darwin
import UniformTypeIdentifiers
import EventKit

// All regular island surfaces share one Spaces/full-screen policy. A window
// must join the OTHER application's full-screen Space, not only all desktop
// Spaces. Without canJoinAllApplications, a screenSaver-level panel can still
// disappear behind Safari, video players, or Stage Manager layouts.
// The secure SkyLight lock-screen window has separate lifecycle rules.
enum IslandWindowSpaces {
    static let foregroundBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]
}

@main
struct NotchIslandApp: App {
    @NSApplicationDelegateAdaptor(IslandAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// 3.10.1: the latest audio band levels, read by the waveform every frame.
enum AudioLevelStore {
    static var values: [CGFloat] = Array(repeating: 0, count: 6)
}

enum IslandEvent: Equatable {
    case charging
    case unplugged
    case lowBattery
    case airPods
    case focus
    case update
    case notice
}

// 3.3.0 (experimental): one compact banner for all "Laboratory" features.
// Icon or thumbnail on the left, a short label (and optional level bar) on
// the right — the same silhouette and motion as every other banner.
struct IslandNotice: Equatable {
    enum Kind: String {
        case volume, output, microphone, camera, vpn, network, thermal, cpu
        case disk, clipboard, screenshot, meeting, reminder, sleepTimer, shelf
        case airdrop, eyeBreak, layoutFix
    }
    enum Tap: Equatable {
        case none
        case openURL(URL)
        case revealFile(URL)
        case openApp(String)       // bundle identifier
        case openSettingsPane(String)
        case openShelf
        case stopEyeBreak
    }

    var kind: Kind
    var symbol: String
    var tint: Color
    var text: String
    var thumbnail: NSImage? = nil
    var level: Double? = nil
    var tap: Tap = .none
    var duration: TimeInterval = IslandMotion.eventHoldNotice
    var accessibility: String
}

// What the Focus banner shows: the mode that was switched and its new state.
struct FocusPresentation: Equatable {
    let mode: FocusMode
    let isOn: Bool
}

struct PowerState: Equatable {
    let percentage: Int
    let isCharging: Bool
    let onACPower: Bool
}

final class IslandState: ObservableObject {
    @Published var track: PlayingTrack? {
        didSet {
            // A pause or track skip must not restart the entrance animation.
            // Animate ONLY when a media/timer session first becomes visible.
            let wasVisible = oldValue != nil || timerPresented
            let nowVisible = track != nil || timerPresented
            if wasVisible != nowVisible {
                layoutChanged?()
                // A late media poll during the desktop unlock animation must
                // not restart the normal compact entrance from notch width.
                if !unlockTransitionActive {
                    updateCompactPresentation(isVisible: nowVisible)
                }
            } else if (oldValue == nil) != (track == nil) {
                // When music starts, detach Clock into the satellite; when it
                // ends, return Clock to the same main island without replaying
                // the normal compact entrance animation.
                layoutChanged?()
            }
        }
    }
    // Image belongs to the current song; never fall back to the player app icon.
    @Published var musicArtwork: NSImage? {
        // 3.19.0: the «Обложка» theme follows the cover.
        didSet { if musicArtwork !== oldValue { CoverPalette.shared.update(from: musicArtwork) } }
    }
    // The waveform is tinted from the current COVER (not the player icon).
    // A muted neutral is shown before album art becomes available.
    @Published var musicArtworkTint = Color(red: 0.71, green: 0.69, blue: 0.66)
    private var tintedArtworkKey = ""
    private var artworkTints: [String: Color] = [:]
    private var artworkTintPending = Set<String>()
    private let artworkTintQueue = DispatchQueue(label: "app.notchisland.arttint", qos: .utility)
    private let neutralTint = Color(red: 0.71, green: 0.69, blue: 0.66)
    // Covers survive temporary source changes and pauses, and do not need to
    // be downloaded again when the same song comes back into the queue.
    private let artworkMemory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 36
        return cache
    }()

    func receiveArtwork(_ image: NSImage, for identity: String) {
        artworkMemory.setObject(image, forKey: identity as NSString)
        guard track?.artworkIdentity == identity else { return }
        musicArtwork = image
        updateArtworkTint(image, for: identity)
    }

    // MARK: Cover-colour glow (3.2.0)
    // On a track change the island's outline briefly glows in the colour of
    // the new cover (the same tint as the spectrum). Can be switched off.
    @Published private(set) var coverGlowEnabled =
        (UserDefaults.standard.object(forKey: "coverGlowEnabledV320") as? Bool) ?? true
    @Published private(set) var coverGlowOpacity: Double = 0
    @Published private(set) var coverGlowCanvasActive = false {
        didSet { if oldValue != coverGlowCanvasActive { layoutChanged?() } }
    }
    private var coverGlowToken = UUID()
    private var lastGlowIdentity = ""

    func setCoverGlowEnabled(_ enabled: Bool) {
        coverGlowEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "coverGlowEnabledV320")
        if !enabled { stopCoverGlow() }
    }

    // The glow needs a few transparent points around the compact island.
    // Never while the player is open, a banner is shown or the timer
    // satellite holds the media canvas in place.
    var coverGlowCanvasInUse: Bool {
        coverGlowCanvasActive && event == nil && !canvasExpanded && !isExpanded &&
            !usesFixedMediaSatelliteCanvas && !unlockTransitionActive && !isSessionLocked
    }

    private func triggerCoverGlow(for identity: String) {
        guard identity != lastGlowIdentity, track?.artworkIdentity == identity else { return }
        lastGlowIdentity = identity
        guard coverGlowEnabled, track?.isPlaying == true, event == nil,
              !isExpanded, !canvasExpanded, compactRevealed, !isSessionLocked,
              !mediaSuppressedInFullscreen, !unlockTransitionActive,
              !usesFixedMediaSatelliteCanvas else { return }
        let token = UUID()
        coverGlowToken = token
        coverGlowCanvasActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.coverGlowToken == token else { return }
            withAnimation(.easeOut(duration: 0.45)) { self.coverGlowOpacity = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.coverGlowToken == token else { return }
            withAnimation(.easeInOut(duration: 0.9)) { self.coverGlowOpacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.coverGlowToken == token else { return }
            self.coverGlowCanvasActive = false
        }
    }

    func stopCoverGlow() {
        coverGlowToken = UUID()
        if coverGlowOpacity != 0 { coverGlowOpacity = 0 }
        if coverGlowCanvasActive { coverGlowCanvasActive = false }
    }

    // A small, one-time average-color sample from the real cover. Running
    // this off the UI thread prevents stutter during an island animation.
    private func updateArtworkTint(_ artwork: NSImage?, for identity: String) {
        guard let artwork else {
            if tintedArtworkKey != identity {
                musicArtworkTint = neutralTint
                tintedArtworkKey = ""
            }
            return
        }
        if let cached = artworkTints[identity] {
            musicArtworkTint = cached
            tintedArtworkKey = identity
            triggerCoverGlow(for: identity)
            return
        }
        // Never show the previous track's palette while a new one loads.
        if tintedArtworkKey != identity {
            tintedArtworkKey = ""
            musicArtworkTint = neutralTint
        }
        guard !artworkTintPending.contains(identity) else { return }
        artworkTintPending.insert(identity)
        artworkTintQueue.async { [weak self] in
            let tint = ArtworkColorSampler.tint(from: artwork)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.artworkTintPending.remove(identity)
                self.artworkTints[identity] = tint
                guard self.track?.artworkIdentity == identity else { return }
                self.tintedArtworkKey = identity
                self.musicArtworkTint = tint
                self.triggerCoverGlow(for: identity)
            }
        }
    }
    // The favorite button is visible ONLY when a supported player confirms
    // the actual saved state of the exact current track.
    @Published var favoriteSupported = false
    @Published var favoriteIsVerified = false
    var requestFavoriteSetup: (() -> Void)?
    @Published var favoriteIsSaved = false
    @Published var favoriteIsUpdating = false
    @Published var favoritePulse = 0
    private var favoriteForKey = ""
    var requestFavorite: ((PlayingTrack, Bool) -> Void)?

    func receiveFavorite(key: String, value: Bool?, busy: Bool) {
        let currentKey = track.map { FavoritesController.key(for: $0) } ?? ""
        guard key == currentKey else { return }
        favoriteForKey = key
        // In Yandex Music, keep the star visible while status is being read.
        // Unverified favorites cannot be toggled blindly.
        favoriteSupported = value != nil || (track.map { FavoritesController.kind(for: $0) == .yandexMusic } ?? false)
        favoriteIsVerified = value != nil
        favoriteIsUpdating = busy
        if let value { favoriteIsSaved = value }
    }

    func tapFavorite() {
        guard let song = track, favoriteSupported && !favoriteIsUpdating else { return }
        // During the first status check there is no verified key yet.
        // The first tap should still open the setup instructions.
        guard favoriteIsVerified else {
            // Never open the setup window behind the lock screen.
            if !isSessionLocked { requestFavoriteSetup?() }
            return
        }
        guard favoriteForKey == FavoritesController.key(for: song) else { return }
        favoriteIsUpdating = true
        favoriteIsSaved.toggle()
        favoritePulse += 1
        requestFavorite?(song, favoriteIsSaved)
    }

    func finishFavorite(trackKey: String, desired: Bool, success: Bool) {
        guard self.track.map({ FavoritesController.key(for: $0) }) == trackKey else { return }
        favoriteIsUpdating = false
        if !success { favoriteIsSaved = !desired }
    }

    // 3.10.1: NOT published. The levels arrive up to 60 times a second;
    // publishing them redrew every view that watches IslandState (the lock
    // screen windows, the settings window…) at that rate. The waveform reads
    // them itself on each animation frame.
    var audioLevels: [CGFloat] {
        get { AudioLevelStore.values }
        set { AudioLevelStore.values = newValue }
    }
    @Published var audioStatus = "Выключена"
    @Published var audioCaptureEnabled = UserDefaults.standard.bool(forKey: "audioCaptureEnabled")
    // 3.5.1: the waveform follows real audio only while the tap actually
    // delivers sound; otherwise it uses the calm iPhone-like rhythm.
    var audioLive: Bool { audioCaptureEnabled && audioStatus.hasPrefix("Системный звук получен") }
    // Navigation gives instant visual feedback; the song metadata itself
    // must be confirmed by the external player before changing the title.
    @Published private(set) var pendingSkip: PlaybackCommand?
    @Published private(set) var nextPulse = 0
    @Published private(set) var previousPulse = 0
    @Published var isExpanded = false
    // Full-screen video or music should have an unobstructed top edge. Events
    // and the Clock satellite still work, and the track keeps polling.
    @Published private(set) var mediaSuppressedInFullscreen = false {
        didSet { if oldValue != mediaSuppressedInFullscreen { layoutChanged?() } }
    }
    @Published var hideMediaDuringFullscreen =
        (UserDefaults.standard.object(forKey: "hideMediaDuringFullscreenV323") as? Bool) ?? true
    func setHideMediaDuringFullscreen(_ enabled: Bool) {
        hideMediaDuringFullscreen = enabled
        UserDefaults.standard.set(enabled, forKey: "hideMediaDuringFullscreenV323")
        mediaVisibilitySettingsChanged?()
    }
    // 3.4.1: also step aside while the music app / the playing browser tab
    // is in front — the same music is already visible there.
    @Published var hideMediaWhenSourceInFront =
        (UserDefaults.standard.object(forKey: "hideMediaWhenSourceInFrontV341") as? Bool) ?? true
    func setHideMediaWhenSourceInFront(_ enabled: Bool) {
        hideMediaWhenSourceInFront = enabled
        UserDefaults.standard.set(enabled, forKey: "hideMediaWhenSourceInFrontV341")
        mediaVisibilitySettingsChanged?()
    }
    var mediaVisibilitySettingsChanged: (() -> Void)?
    // 4.0.0: cinema mode — a full-screen video in front: the island and all
    // banners stay away until it ends.
    @Published private(set) var cinemaMode = false {
        didSet { if oldValue != cinemaMode { layoutChanged?() } }
    }
    func setCinemaMode(_ on: Bool) {
        guard on != cinemaMode else { return }
        if on {
            resetExpandedImmediately()
            pointerInsideIsland = false
            hoverEnter?.cancel(); hoverEnter = nil
            hoverExit?.cancel(); hoverExit = nil
        }
        cinemaMode = on
    }
    private var mediaSuppressionTarget = false
    private var mediaSuppressionToken = UUID()

    // 3.4.1: the player no longer vanishes in one frame. It first shrinks
    // back into the camera notch, and only then is the panel removed; on
    // return it grows out of the notch with the normal entrance.
    func updateFullscreenMediaSuppression(_ suppressed: Bool) {
        guard mediaSuppressionTarget != suppressed else { return }
        mediaSuppressionTarget = suppressed
        let token = UUID()
        mediaSuppressionToken = token
        if suppressed {
            // Prevent expanded hit regions from surviving behind a video.
            resetExpandedImmediately()
            pointerInsideIsland = false
            hoverEnter?.cancel(); hoverEnter = nil
            hoverExit?.cancel(); hoverExit = nil
            guard event == nil, compactRevealed, !unlockTransitionActive, !isSessionLocked else {
                mediaSuppressedInFullscreen = true
                return
            }
            compactRevealToken = UUID()
            withAnimation(IslandMotion.bannerRetract) { compactRevealed = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
                guard let self, self.mediaSuppressionToken == token, self.mediaSuppressionTarget else { return }
                self.mediaSuppressedInFullscreen = true
            }
        } else if mediaSuppressedInFullscreen {
            mediaSuppressedInFullscreen = false
            if (track != nil || timerPresented) && event == nil && !unlockTransitionActive {
                updateCompactPresentation(isVisible: true)
            }
        } else if (track != nil || timerPresented) && event == nil && !unlockTransitionActive {
            // Came back while still shrinking: grow again from where it is.
            compactRevealToken = UUID()
            withAnimation(IslandMotion.morph) { compactRevealed = true }
        }
    }
    // The host window reserves space immediately, while this flag gently
    // grows the visible black surface out from the *physical* camera notch.
    @Published private(set) var compactRevealed = false
    private var compactRevealToken = UUID()

    // Real unlock animates inside the existing media NSPanel; no additional
    // desktop padlock NSWindow is presented. All four values are view state,
    // never used to alter the real lock-screen SkyLight attachment.
    @Published private(set) var unlockTransitionActive = false { didSet { layoutChanged?() } }
    @Published private(set) var unlockSurfaceProgress: CGFloat = 0
    @Published private(set) var unlockSymbolOpen = false
    @Published private(set) var unlockSymbolOpacity: Double = 0
    @Published private(set) var unlockMediaOpacity: Double = 1
    private var unlockTransitionToken = UUID()
    private var unlockSequenceStarted = false
    // Delegate's post-unlock callback must survive until the SkyLight handoff
    // finishes and the separately scheduled icon sequence completes.
    private var unlockHandoffCompletion: (() -> Void)?
    var unlockSurfaceWidth: CGFloat {
        let destination = (track != nil || timerPresented) ? compactWidth : notchWidth
        return destination + ((notchWidth + 76) - destination) * unlockSurfaceProgress
    }

    private func updateCompactPresentation(isVisible: Bool) {
        let token = UUID()
        compactRevealToken = token
        guard isVisible else {
            compactRevealed = false
            return
        }
        compactRevealed = false
        // Defer a frame so NSPanel is positioned before SwiftUI animates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
            guard let self, self.compactRevealToken == token,
                  (self.track != nil || self.timerPresented), !self.isSessionLocked else { return }
            withAnimation(IslandMotion.morph) {
                self.compactRevealed = true
            }
        }
    }
    // The actual lock/unlock overlay has its own window and never opens the media card.
    @Published var isSessionLocked = false { didSet { layoutChanged?() } }
    // The window grows first, then the black shape morphs inside it. During
    // collapse it shrinks *after* the visual spring has completed.
    @Published private(set) var canvasExpanded = false { didSet { layoutChanged?() } }
    @Published var event: IslandEvent? { didSet { layoutChanged?() } }
    @Published private(set) var eventRevealed = false
    // Banner contents appear after the shape and leave before it (3.2.0).
    @Published private(set) var eventContentVisible = false
    // Starting width of the next event. Avoid collapsing to the hardware
    // cutout if another banner interrupts the one already visible.
    @Published private(set) var eventRestingWidth: CGFloat?
    // Preserve the current media wings when a charging banner begins.
    // Without this the black silhouette collapses to the camera width
    // for a frame before growing again, producing a visible empty notch.
    @Published private(set) var eventEnteringFromMedia = false
    // Keep the outgoing event and the returning compact player in the SAME
    // silhouette until the hand-off ends. Avoid an empty notch-width frame.
    @Published private(set) var eventReturningToMedia = false
    // A shared, notch-centred transparent canvas survives the charging/media
    // handoff. Only the black SwiftUI silhouette changes size and opacity.
    @Published private(set) var eventHandoffCanvasActive = false { didSet { layoutChanged?() } }
    private var eventCanvasReleaseToken = UUID()
    @Published var power: PowerState?
    // The alert freezes its displayed sample and threshold for the full 7 s.
    // A manual preview can therefore use a realistic 20/10/5/1% sample even
    // when the computer is connected to power. No battery reading is altered.
    @Published private(set) var lowBatteryDisplayPercentage: Int?
    @Published private(set) var lowBatteryWarningThreshold: Int?
    var powerDisplayPercentage: Int? {
        event == .lowBattery ? lowBatteryDisplayPercentage : power?.percentage
    }
    var powerTintPercentage: Int? {
        event == .lowBattery ? lowBatteryWarningThreshold : power?.percentage
    }
    func setLowBatteryPresentation(threshold: Int, percentage: Int) {
        lowBatteryWarningThreshold = threshold
        lowBatteryDisplayPercentage = percentage
    }
    func clearLowBatteryPresentation() {
        lowBatteryWarningThreshold = nil
        lowBatteryDisplayPercentage = nil
    }
    @Published var airPods: AirPodsStatus?
    // Frozen for the banner's lifetime; a newer switch simply replaces it.
    @Published private(set) var focusPresentation: FocusPresentation?
    @Published private(set) var focusPulse = 0

    @Published private(set) var notice: IslandNotice?
    // File shelf (lab). The island accepts dropped files when it is set.
    weak var shelfModel: ShelfModel?
    var noticeTapHandler: ((IslandNotice.Tap) -> Void)?

    // Lab banners are low priority: they never interrupt an open player or
    // another kind of banner. A repeated notice of the same kind (volume
    // steps, CPU readings) updates the visible banner in place and simply
    // extends its stay instead of replaying the entrance.
    // 4.3.2 — whether a banner would actually appear right now (the same
    // conditions presentNotice checks). Reminders wait for a free island
    // instead of being dropped silently.
    var canPresentNoticeNow: Bool {
        !isSessionLocked && !unlockTransitionActive && !cinemaMode &&
            !isExpanded && !canvasExpanded && scheduledEvent == nil &&
            (event == nil || event == .notice)
    }

    func presentNotice(_ next: IslandNotice) {
        guard !isSessionLocked, !unlockTransitionActive, !cinemaMode else { return }
        if event == .notice, notice?.kind == next.kind, eventRevealed {
            notice = next
            let token = UUID()
            eventToken = token
            // 3.3.1: an update can arrive after the old contents already
            // started fading out (the empty black banner in the recording).
            if !eventContentVisible {
                withAnimation(IslandMotion.bannerContentIn) { eventContentVisible = true }
            }
            scheduleEventExit(.notice, token: token, dwell: next.duration)
            return
        }
        if isExpanded || canvasExpanded { return }
        if let current = event, current != .notice { return }
        if scheduledEvent != nil { return }
        notice = next
        show(.notice)
    }

    // One-click update banner: tapping it installs the release from Downloads.
    @Published private(set) var updateVersion: String?
    var requestUpdate: (() -> Void)?

    func presentUpdate(version: String) {
        guard !isSessionLocked else { return }
        updateVersion = version
        show(.update)
    }

    func presentFocusChange(_ presentation: FocusPresentation) {
        guard !isSessionLocked else { return }
        focusPresentation = presentation
        focusPulse += 1
        show(.focus)
    }

    // An independent monotonic countdown, not tied to media metadata/pause.
    @Published var timerActive = false {
        didSet {
            layoutChanged?()
            let wasVisible = oldValue || timerPreviewActive || track != nil
            let nowVisible = timerPresented || track != nil
            if wasVisible != nowVisible { updateCompactPresentation(isVisible: nowVisible) }
        }
    }
    @Published var timerPaused = false
    // A separate always-on-top NSPanel belongs exclusively to the timer.
    // Its canvas is resized once, while the visible capsule animates inside.
    @Published private(set) var timerExpanded = false
    // Visual-only diagnostics: this never starts an independent timer.
    @Published private(set) var timerPreviewActive = false {
        didSet {
            layoutChanged?()
            // The test uses the very same main/satellite layout as a real
            // Clock timer. No forced satellite or special diagnostic card.
            if track == nil && !timerActive && !isSessionLocked {
                updateCompactPresentation(isVisible: timerPreviewActive)
            }
        }
    }
    private var timerPreviewToken = UUID()
    private var timerPreviewDeadline = Date.distantPast
    var timerPresented: Bool { timerActive || timerPreviewActive }

    func previewTimerSatellite() {
        guard !isSessionLocked && !unlockTransitionActive else { return }
        if timerActive { layoutChanged?(); return } // show the genuine timer
        timerPreviewToken = UUID()
        let token = timerPreviewToken
        timerPreviewDeadline = Date().addingTimeInterval(10 * 60)
        timerPreviewActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
            guard let self, self.timerPreviewToken == token else { return }
            self.timerPreviewActive = false
            if !self.timerActive { self.resetTimerSatellite() }
        }
    }
    @Published private(set) var timerCanvasExpanded = false { didSet { layoutChanged?() } }
    private var timerPanelToken = UUID()
    // Pending timer hover actions must live on IslandState. Earlier builds
    // referenced these fields without declaring them, preventing compilation.
    private var timerHoverOpen: DispatchWorkItem?
    private var timerHoverExit: DispatchWorkItem?
    private var timerPointerInside = false

    var showsTimerSatellite: Bool {
        // Only detach when the main island is occupied. When the timer is the
        // only active content it lives inside the physical-notch island.
        // The diagnostic preview deliberately exercises the side window.
        TimerRoutingPolicy.showsSatellite(timer: timerActive,
                                          preview: timerPreviewActive,
                                          music: track != nil, event: event != nil,
                                          locked: isSessionLocked,
                                          unlocking: unlockTransitionActive)
    }
    // Align the small timer's bottom edge with the compact media island.
    // Earlier max(44, notchHeight + 4) made it visibly taller than the notch.
    var timerCompactDiameter: CGFloat { mediaCompactHeight }
    let timerExpandedWidth: CGFloat = 254
    let timerExpandedHeight: CGFloat = 144
    let timerSatelliteGap: CGFloat = 19
    // The satellite canvas reaches LEFT across the gap (+3 pt into the main
    // island) so its entrance can grow out of the main island like a drop.
    // Hit-testing stays limited to the visible black shape.
    var timerLeadInset: CGFloat { timerSatelliteGap + 3 }

    // Entrance/exit are drawn by SwiftUI inside a window that does not move.
    // presence 0 → a thin bridge at the main island's edge (or a small dot
    // for an in-place exit); 1 → the full timer. The spring overshoots a
    // little, which gives the liquid "detaching drop" look.
    @Published private(set) var timerSatellitePresence: CGFloat = 0
    @Published private(set) var timerSatelliteContentVisible = false
    @Published private(set) var timerSatelliteShrinksInPlace = false
    private var timerSatelliteAnimationToken = UUID()
    // 4.3.3 — while the satellite is leaving, the music island keeps the
    // layout it had next to it, and the readout keeps the last time instead
    // of jumping to 00:00. Everything switches once the drop is gone.
    @Published private(set) var timerSatelliteExiting = false
    private var timerExitRemaining: TimeInterval?

    func animateTimerSatelliteIn() {
        let token = UUID()
        timerSatelliteAnimationToken = token
        timerSatelliteExiting = false
        timerExitRemaining = nil
        // Re-entry during an exit continues from the current shape.
        if timerSatelliteShrinksInPlace || timerSatellitePresence <= 0.01 {
            timerSatelliteShrinksInPlace = false
            timerSatellitePresence = 0
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timerSatelliteAnimationToken == token else { return }
            withAnimation(.spring(response: 0.56, dampingFraction: 0.66)) {
                self.timerSatellitePresence = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.timerSatelliteAnimationToken == token else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.timerSatelliteContentVisible = true }
        }
    }

    // home: the timer moves back into the main island → retract into it.
    // Otherwise (finished/cancelled) the drop shrinks away where it is.
    func animateTimerSatelliteOut(home: Bool, completion: @escaping () -> Void) {
        let token = UUID()
        timerSatelliteAnimationToken = token
        timerSatelliteExiting = true
        withAnimation(.easeIn(duration: 0.14)) { timerSatelliteContentVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.timerSatelliteAnimationToken == token else { return }
            self.timerSatelliteShrinksInPlace = !home
            withAnimation(home ? .spring(response: 0.4, dampingFraction: 0.92)
                               : .easeIn(duration: 0.26)) {
                self.timerSatellitePresence = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
            guard let self, self.timerSatelliteAnimationToken == token else { return }
            completion()
            self.finishTimerSatelliteExit()
        }
    }

    // Ends the exit: the music island takes its usual layout in one step,
    // without an animated slide.
    func finishTimerSatelliteExit() {
        timerExitRemaining = nil
        guard timerSatelliteExiting else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            timerSatelliteExiting = false
            timerSatelliteShrinksInPlace = false
        }
        layoutChanged?()
    }
    // Never resize the NSPanel during hover: only the BLACK SwiftUI surface
    // changes its dimensions. A fixed transparent canvas prevents window
    // re-anchoring, lost hover events and sharp position jumps.
    // Just like the primary notch, five points of black are drawn ABOVE the
    // physical top edge. This does not change the timer's visible height.
    var timerTopBleed: CGFloat { islandTopBleed }
    var timerPanelSize: CGSize {
        // Use the small hit area in compact mode: no invisible menu-bar shield.
        // The extra roof lies outside the visible screen.
        if timerExpanded || timerCanvasExpanded {
            return CGSize(width: timerExpandedWidth,
                          height: timerExpandedHeight + timerTopBleed)
        }
        return CGSize(width: timerCompactDiameter,
                      height: timerCompactDiameter + timerTopBleed)
    }

    // When the Clock timer occupies the right satellite, keep the media
    // NSPanel at ONE fixed position and at its maximum transparent canvas
    // size for both hover states. The visible media shape remains attached
    // to the camera cutout because IslandView right-aligns it in this canvas.
    // The black silhouette, rather than the NSPanel, expands to the LEFT.
    var usesFixedMediaSatelliteCanvas: Bool {
        track != nil && (showsTimerSatellite || timerSatelliteExiting) &&
            event == nil && !unlockTransitionActive
    }

    // Hover on an NSPanel may briefly report an exit while AppKit grows the
    // hosting window. Debounce BOTH edges; otherwise a pending expand from an
    // old frame can run after the pointer has already left and the two springs
    // fight each other (the visible bouncing in the user's capture).
    func timerHoverChanged(_ over: Bool) {
        // SwiftUI sends redundant hover updates during its own layout pass.
        // Do not restart pending expand/collapse timers on those events.
        guard over != timerPointerInside else { return }
        timerPointerInside = over
        timerHoverOpen?.cancel()
        timerHoverOpen = nil
        timerHoverExit?.cancel()
        timerHoverExit = nil
        guard showsTimerSatellite else { return }
        if over && dragInProgress { return }
        if over {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.timerPointerInside, self.showsTimerSatellite,
                      !self.dragInProgress else { return }
                // The satellite takes focus; a stale main-panel hover must
                // not leave its invisible expanded canvas stuck open.
                self.pointerInsideIsland = false
                self.hoverEnter?.cancel()
                self.hoverEnter = nil
                self.hoverExit?.cancel()
                self.hoverExit = nil
                self.collapsePlayer(force: true)
                self.expandTimerSatellite()
            }
            timerHoverOpen = task
            // A single run-loop turn lets the compact hit region settle;
            // do not delay the visible reaction by 160 milliseconds.
            DispatchQueue.main.asyncAfter(deadline: .now() +
                max(0.01, ignoreHoverBefore.timeIntervalSinceNow + 0.01), execute: task)
        } else {
            let task = DispatchWorkItem { [weak self] in
                guard let self, !self.timerPointerInside else { return }
                self.collapseTimerSatellite()
            }
            timerHoverExit = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: task)
        }
    }

    func expandTimerSatellite(force: Bool = false) {
        guard showsTimerSatellite && !timerExpanded else { return }
        let token = UUID()
        timerPanelToken = token
        if timerCanvasExpanded {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.87)) {
                timerExpanded = true
            }
            return
        }
        timerCanvasExpanded = true
        // The panel is allowed to resize first; do not let stale hover tasks
        // trigger a second animation while the first resize is still in flight.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timerPanelToken == token else { return }
            guard self.showsTimerSatellite, self.timerPointerInside || force else {
                self.timerCanvasExpanded = false
                return
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.87)) {
                self.timerExpanded = true
            }
        }
    }

    func collapseTimerSatellite(force: Bool = false) {
        guard timerExpanded || timerCanvasExpanded else { return }
        let token = UUID()
        timerPanelToken = token
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            timerExpanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            guard let self, self.timerPanelToken == token,
                  !self.timerExpanded, (force || !self.timerPointerInside) else { return }
            self.timerCanvasExpanded = false
        }
    }

    private func resetTimerSatellite() {
        timerHoverOpen?.cancel()
        timerHoverOpen = nil
        timerHoverExit?.cancel()
        timerHoverExit = nil
        timerPointerInside = false
        timerPanelToken = UUID()
        timerExpanded = false
        timerCanvasExpanded = false
    }

    // The system Clock app is authoritative. The legacy internal countdown
    // stays only as a UI interpolation of an observed Clock timer.
    var requestClockTimerToggle: (() -> Void)?
    var requestClockTimerCancel: (() -> Void)?
    private var timerDeadline = Date.distantPast
    private var pausedTimerRemaining: TimeInterval = 0
    private var timerFinishedAt: Date?
    var onTimerFinished: (() -> Void)?

    // Called with a real observed Clock.app countdown, never to start a second
    // competing countdown. The last observation is interpolated smoothly.
    func applyClockTimer(remaining: TimeInterval, paused: Bool) {
        guard remaining > 0 else { clearClockTimer(); return }
        // A genuine Clock observation replaces the synthetic settings demo.
        let wasPreview = timerPreviewActive
        let newDeadline = Date().addingTimeInterval(remaining)
        if !timerActive || timerPaused != paused ||
            abs(timerRemaining() - remaining) > 1.1 {
            timerDeadline = newDeadline
            pausedTimerRemaining = remaining
            timerFinishedAt = nil
            timerPaused = paused
            timerActive = true
        } else if !paused && abs(timerDeadline.timeIntervalSince(newDeadline)) > 0.35 {
            timerDeadline = newDeadline
        }
        if wasPreview { timerPreviewToken = UUID(); timerPreviewActive = false }
    }

    func clearClockTimer() {
        guard timerActive else { return }
        // 4.3.4: the exit flag must be up BEFORE timerActive changes —
        // that change re-lays out the music panel at once. Raised later
        // (from the satellite window), the music island had already left
        // its fixed canvas: it vanished and slid back in from the right.
        if showsTimerSatellite {
            timerExitRemaining = timerRemaining()
            timerSatelliteExiting = true
        }
        timerFinishedAt = nil
        timerPaused = false
        pausedTimerRemaining = 0
        // An open satellite folds smoothly; the music island itself must
        // not animate here (no implicit transaction around timerActive).
        if timerExpanded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { resetTimerSatellite() }
        } else {
            resetTimerSatellite()
        }
        timerActive = false
        if track == nil { collapsePlayer() }
    }

    // UI controls never optimistically alter Clock's timer; they ask the
    // bridge to perform the action, then wait for a fresh system observation.
    func toggleTimerPause() { requestClockTimerToggle?() }
    func stopTimer() { requestClockTimerCancel?() }

    func timerRemaining(at now: Date = Date()) -> TimeInterval {
        if !timerActive {
            if let frozen = timerExitRemaining { return frozen }
            return timerPreviewActive ? max(0, timerPreviewDeadline.timeIntervalSince(now)) : 0
        }
        if timerFinishedAt != nil { return 0 }
        return max(0, timerPaused ? pausedTimerRemaining : timerDeadline.timeIntervalSince(now))
    }

    // A Clock.app timer keeps running and playing its alarm independently.
    // We only interpolate the currently observed remaining time in SwiftUI.
    func timerTick() { }


    func receiveAirPods(_ status: AirPodsStatus, newlyConnected: Bool) {
        // Avoid repainting the entire island for identical Bluetooth snapshots.
        if airPods != status { airPods = status }
        if newlyConnected && !isSessionLocked { show(.airPods) }
    }
    @Published var notchWidth: CGFloat = 194 { didSet { layoutChanged?() } }
    @Published var notchHeight: CGFloat = 38 { didSet { layoutChanged?() } }
    @Published var notchCenterX: CGFloat? = nil
    @Published var autoNotchSize = true

    func setNotchSize(_ width: CGFloat) {
        autoNotchSize = false
        UserDefaults.standard.set(Double(width), forKey: "manualNotchWidthV15")
        notchWidth = width
    }
    func useAutomaticNotch() {
        autoNotchSize = true
        UserDefaults.standard.removeObject(forKey: "manualNotchWidthV15")
        layoutChanged?()
    }
    func updateNotchGeometry(for screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            let measured = right.minX - left.maxX
            notchCenterX = (right.minX + left.maxX) / 2
            if autoNotchSize && measured >= 100 && measured <= 340 {
                notchWidth = measured
            }
        } else { notchCenterX = screen.frame.midX }
        let height = screen.safeAreaInsets.top
        if height >= 25 && height <= 55 { notchHeight = height }
    }

    var layoutChanged: (() -> Void)?
    // Called only when the previous event has fully withdrawn from the shared
    // silhouette. The app delegate uses this to drain battery warnings.
    var onEventFinished: (() -> Void)?
    var requestCommand: ((PlaybackCommand) -> Void)?
    var requestSeek: ((Double) -> Void)?
    private var eventToken = UUID()
    private var scheduledEvent: IslandEvent?
    private var deferredEvents: [IslandEvent] = []
    var isBusyForLowBatteryWarning: Bool {
        isSessionLocked || event != nil || scheduledEvent != nil ||
        isExpanded || canvasExpanded
    }
    private var canvasToken = UUID()
    private var mediaMissingSince: Date?
    private var protectPlaybackUntil = Date.distantPast
    private var optimisticPlaying: Bool?
    private var optimisticUntil = Date.distantPast
    private var pendingSkipFrom: String?
    private var pendingSkipUntil = Date.distantPast
    private var hoverExit: DispatchWorkItem?
    private var ignoreHoverBefore = Date.distantPast

    // Progress is based on a real clock, not on the cadence of the AppleScript
    // poll. Incoming near-identical positions do not restart the animation.
    private var anchorPosition: Double = 0
    private var anchorDate = Date()
    private var seekHoldUntil = Date.distantPast
    private var seekTarget: Double?

    func displayedPosition(at time: Date) -> Double {
        guard let current = track else { return 0 }
        let seconds = anchorPosition + (current.isPlaying ? max(0, time.timeIntervalSince(anchorDate)) : 0)
        return min(max(0, seconds), current.duration > 0 ? current.duration : Double.greatestFiniteMagnitude)
    }

    func receiveMedia(_ raw: PlayingTrack?, artwork: NSImage?) {
        let now = Date()
        guard var incoming = raw else {
            // A dropped MediaRemote poll must never be interpreted as Pause.
            // Keep a paused session around while macOS temporarily omits it.
            guard let current = track else { return }
            if mediaMissingSince == nil { mediaMissingSince = now }
            let missing = now.timeIntervalSince(mediaMissingSince ?? now)
            let sourceExited = !current.sourceBundle.isEmpty &&
                NSRunningApplication.runningApplications(withBundleIdentifier: current.sourceBundle).isEmpty
            // Paused content is kept while its source app remains open, even
            // if the operating system stops publishing metadata for a while.
            // A stopped playing session or exited app is eventually dismissed.
            if ((current.isPlaying && missing > 15.0) ||
                (sourceExited && missing > 5.0)) && now >= protectPlaybackUntil {
                clearMedia()
            }
            return
        }
        mediaMissingSince = nil

        // Some Now Playing publishers briefly omit the artist during refresh.
        // Keep the known artist if the normalized title has not changed.
        if let previous = track, incoming.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !previous.artist.isEmpty,
           incoming.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ==
           previous.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) {
            incoming.artist = previous.artist
        }

        // Next/Previous often returns one or more copies of the OLD song.
        // Ignore those until the new identity arrives or the command times out.
        if pendingSkip != nil {
            if incoming.artworkIdentity != pendingSkipFrom {
                pendingSkip = nil
                pendingSkipFrom = nil
                pendingSkipUntil = .distantPast
                optimisticPlaying = nil
            } else if now < pendingSkipUntil {
                if let artwork { receiveArtwork(artwork, for: incoming.artworkIdentity) }
                return
            } else {
                pendingSkip = nil
                pendingSkipFrom = nil
                pendingSkipUntil = .distantPast
                // The external player may not support this skip command.
            }
        }

        let sameSong = track?.identity == incoming.identity || track?.artworkIdentity == incoming.artworkIdentity
        // The parent app reported by MediaRemote can change without a new
        // song. Only invalidate artwork if the actual title/artist changes.
        let sameArtwork = track?.artworkIdentity == incoming.artworkIdentity
        let artKey = incoming.artworkIdentity
        let previousFavoriteKey = track.map { FavoritesController.key(for: $0) }
        if previousFavoriteKey != FavoritesController.key(for: incoming) {
            favoriteSupported = FavoritesController.kind(for: incoming) == .yandexMusic
            favoriteIsVerified = false
            favoriteIsSaved = false
            favoriteIsUpdating = false
            favoriteForKey = ""
        }
        if let artwork { artworkMemory.setObject(artwork, forKey: artKey as NSString) }
        // The UI already changed Play -> Pause (or vice versa) at click time.
        // Do not let an out-of-date system read undo that response.
        if let desired = optimisticPlaying, sameSong {
            if incoming.isPlaying == desired || now >= optimisticUntil {
                optimisticPlaying = nil
            } else {
                incoming.isPlaying = desired
            }
        } else if !sameSong {
            optimisticPlaying = nil
        }

        if let previous = track, sameSong {
            if incoming.duration < 1 && previous.duration > 1 {
                incoming.duration = previous.duration
            }
            let predicted = displayedPosition(at: now)
            if previous.isPlaying != incoming.isPlaying {
                // Freeze the last smooth position when Pausing, and continue
                // from there when resuming. Ignore transient zero positions.
                anchorPosition = (incoming.position < 0.5 && predicted > 3.0)
                    ? predicted : max(0, incoming.position)
                anchorDate = now
            } else if let wanted = seekTarget, now < seekHoldUntil {
                if abs(incoming.position - wanted) < 3.0 {
                    seekTarget = nil
                    seekHoldUntil = .distantPast
                    anchorPosition = max(0, incoming.position)
                    anchorDate = now
                }
            } else {
                seekTarget = nil
                if optimisticPlaying == nil && abs(incoming.position - predicted) > 1.6 {
                    anchorPosition = max(0, incoming.position)
                    anchorDate = now
                }
            }
            if let artwork { if artwork !== musicArtwork { musicArtwork = artwork } }
            else if musicArtwork == nil { musicArtwork = artworkMemory.object(forKey: artKey as NSString) }
        } else {
            if sameArtwork {
                // Do not erase an image just because the publisher changes.
                if let artwork { if artwork !== musicArtwork { musicArtwork = artwork } }
                else if musicArtwork == nil { musicArtwork = artworkMemory.object(forKey: artKey as NSString) }
            } else {
                let next = artwork ?? artworkMemory.object(forKey: artKey as NSString)
                if next !== musicArtwork { musicArtwork = next }
            }
            anchorPosition = max(0, incoming.position)
            anchorDate = now
            seekTarget = nil
            seekHoldUntil = .distantPast
        }
        protectPlaybackUntil = .distantPast
        // Position is rendered from anchorDate, so publishing every periodic
        // position update needlessly redraws all SwiftUI children. Publish
        // only metadata, duration, play/pause, or source changes.
        var displayTrack = incoming
        if let previous = track, sameSong {
            displayTrack.position = previous.position
        }
        if track != displayTrack { track = displayTrack }
        // Hold real art for a stable song identity; only clear the palette on
        // an actual track switch, never on a dropped artwork metadata field.
        if let currentArt = musicArtwork {
            if tintedArtworkKey != artKey { updateArtworkTint(currentArt, for: artKey) }
        } else if tintedArtworkKey != artKey {
            updateArtworkTint(nil, for: artKey)
        }
    }

    private func clearMedia() {
        resetExpandedImmediately()
        track = nil
        favoriteSupported = false
        favoriteIsSaved = false
        favoriteIsUpdating = false
        favoriteForKey = ""
        musicArtwork = nil
        tintedArtworkKey = ""
        musicArtworkTint = neutralTint
        pendingSkip = nil
        pendingSkipFrom = nil
        optimisticPlaying = nil
        seekTarget = nil
        mediaMissingSince = nil
    }

    func protectDuringTrackChange() {
        protectPlaybackUntil = Date().addingTimeInterval(4.5)
    }

    // Optimistic UI: show the newly selected time immediately; stale reads
    // cannot reset progress until macOS acknowledges or the timeout expires.
    func seek(to seconds: Double) {
        guard let track = track, track.duration > 0 else { return }
        let safe = min(max(seconds, 0), track.duration)
        anchorPosition = safe
        anchorDate = Date()
        seekTarget = safe
        seekHoldUntil = Date().addingTimeInterval(4.0)
        requestSeek?(safe)
        objectWillChange.send()
    }

    // A single gentle click when the pointer ENTERS an island. SwiftUI may
    // re-create a hover tracking region during an animated resize, so both
    // entry-state gating and a small cooldown prevent unwanted repeated taps.
    private var pointerInsideIsland = false
    var isPointerOverIsland: Bool { pointerInsideIsland }

    // Media gestures: brief visual answers, never new windows.
    @Published private(set) var volumeLevel: Float?
    @Published private(set) var swipeNudge: CGFloat = 0
    private var volumeHideToken = UUID()

    func showVolume(_ level: Float) {
        let token = UUID()
        volumeHideToken = token
        withAnimation(.easeOut(duration: 0.16)) { volumeLevel = level }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.volumeHideToken == token else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.volumeLevel = nil }
        }
    }

    // A small sideways nudge of the cover in the swipe direction.
    func nudgeForSwipe(next: Bool) {
        withAnimation(.easeOut(duration: 0.12)) { swipeNudge = next ? -7 : 7 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { self?.swipeNudge = 0 }
        }
    }
    private var hoverEnter: DispatchWorkItem?
    private var lastHoverHaptic = Date.distantPast
    var hoverHapticsEnabled = (UserDefaults.standard.object(forKey: "hoverHapticsEnabledV303") as? Bool) ?? true

    func setHoverHapticsEnabled(_ enabled: Bool) {
        hoverHapticsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "hoverHapticsEnabledV303")
    }

    // 3.3.2: while the left mouse button is held (a file, text or anything
    // else is being dragged) the islands never open under the pointer.
    static var pointerIsDragging: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    private var dragInProgress: Bool {
        Self.pointerIsDragging || (shelfModel?.dropTargeted ?? false)
    }

    func hoverChanged(_ over: Bool) {
        // Avoid restarting the delayed open on redundant SwiftUI hover
        // notifications caused by a changing cover/waveform/layout.
        guard over != pointerInsideIsland else { return }
        let justEntered = over
        pointerInsideIsland = over
        if justEntered && hoverHapticsEnabled && !isSessionLocked && isVisible &&
           Date().timeIntervalSince(lastHoverHaptic) > 0.65 {
            lastHoverHaptic = Date()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        hoverEnter?.cancel()
        hoverEnter = nil
        hoverExit?.cancel()
        hoverExit = nil
        guard !isSessionLocked && event == nil && !mediaSuppressedInFullscreen &&
              (track != nil || timerPresented) else { return }
        if over && dragInProgress { return }
        if over {
            // An entry can arrive during charging/unlock hover suppression.
            // Schedule its opening for AFTER the suppression window instead
            // of swallowing the only hover edge until the user moves out.
            let wait = max(0.045, ignoreHoverBefore.timeIntervalSinceNow + 0.015)
            let pending = DispatchWorkItem { [weak self] in
                guard let self, self.pointerInsideIsland, Date() >= self.ignoreHoverBefore,
                      !self.dragInProgress,
                      !self.isSessionLocked, self.event == nil,
                      (self.track != nil || self.timerPresented) else { return }
                // Transfer focus from the independent timer panel. Delayed
                // SwiftUI mouseExited events must not prevent the timer
                // canvas from settling while the main player opens.
                self.timerPointerInside = false
                self.timerHoverOpen?.cancel()
                self.timerHoverOpen = nil
                self.timerHoverExit?.cancel()
                self.timerHoverExit = nil
                self.collapseTimerSatellite(force: true)
                self.expandPlayer()
            }
            hoverEnter = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: pending)
        } else {
            // SwiftUI briefly loses tracking while an NSPanel expands. Don't
            // instantly collapse at that artificial exit (hover ping-pong).
            let pending = DispatchWorkItem { [weak self] in
                guard let self, !self.pointerInsideIsland else { return }
                self.collapsePlayer()
            }
            hoverExit = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.58, execute: pending)
        }
    }

    func expandPlayer() {
        guard !isSessionLocked && event == nil && !mediaSuppressedInFullscreen &&
              (track != nil || timerPresented) && !isExpanded else { return }
        stopCoverGlow()
        let token = UUID()
        canvasToken = token
        // Reverse an interrupted close in the SAME canvas. Previously the
        // old canvasExpanded=true flag swallowed hover-enter until another
        // mouse-exit, making the player appear unresponsive.
        if canvasExpanded {
            withAnimation(IslandMotion.morph) { isExpanded = true }
            return
        }
        canvasExpanded = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canvasToken == token, self.canvasExpanded,
                  self.event == nil, !self.isSessionLocked,
                  (self.track != nil || self.timerPresented) else { return }
            withAnimation(IslandMotion.morph) {
                self.isExpanded = true
            }
        }
    }

    func collapsePlayer(force: Bool = false) {
        // During an in-flight open the canvas is already expanded but the
        // silhouette has not yet grown. That state must still be cancellable.
        guard isExpanded || canvasExpanded else { return }
        let token = UUID()
        canvasToken = token
        withAnimation(IslandMotion.morph) {
            isExpanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.canvasSettle) { [weak self] in
            guard let self, self.canvasToken == token, !self.isExpanded,
                  (force || !self.pointerInsideIsland || !self.isVisible || self.event != nil) else { return }
            self.canvasExpanded = false
        }
    }

    private func resetExpandedImmediately() {
        hoverEnter?.cancel()
        hoverEnter = nil
        hoverExit?.cancel()
        canvasToken = UUID()
        isExpanded = false
        canvasExpanded = false
        resetTimerSatellite()
    }

    init() {
        let manual = UserDefaults.standard.double(forKey: "manualNotchWidthV15")
        if manual >= 140 && manual <= 340 {
            autoNotchSize = false
            notchWidth = CGFloat(manual)
        }
    }

    // The main island is for media/events; the Clock timer has a separate
    // satellite window. Do not keep a second, invisible timer in the notch.
    var isVisible: Bool {
        !cinemaMode && !isSessionLocked && (event != nil || unlockTransitionActive ||
            (!mediaSuppressedInFullscreen && (track != nil || timerPresented)) ||
            (track == nil && timerPresented))
    }
    var compactWing: CGFloat { 35 }
    // With music + timer, the timer is its own circular satellite to the
    // right of the music island, never squeezed into its waveform wing.
    // With timer only, keep the existing main-island countdown as fallback.
    var leftWing: CGFloat { track == nil ? 0 : compactWing }
    var rightWing: CGFloat { track != nil ? compactWing : (timerPresented ? 86 : 0) }
    var compactWidth: CGFloat { notchWidth + leftWing + rightWing }
    // The music mini-island extends just below the physical cutout:
    // 0.2 pt until 3.8.16, then 0.4, 0.5, 0.6 pt; 0.8 pt since 3.8.20.
    // Other compact states still use the true measured notch height.
    var mediaCompactHeight: CGFloat { notchHeight + 0.8 }
    var compactDisplayHeight: CGFloat { track != nil ? mediaCompactHeight : notchHeight }
    var expandedWidth: CGFloat { max(410, notchWidth + 188) }
    var expandedHeight: CGFloat {
        if track == nil { return max(156, notchHeight + 122) }
        // 4.0.0: the new player is taller (bigger cover, volume row).
        if ExpandedPlayerStyle.isNew { return max(268, notchHeight + 232) }
        return max(210, notchHeight + 174)
    }
    // Charging is deliberately compact. Keep the unplugged label roomy,
    // because "От батареи" is significantly longer than "Зарядка".
    var chargingWing: CGFloat { 72 }
    var chargingWidth: CGFloat { notchWidth + chargingWing * 2 }
    // Narrower warning wings only; charging, unplugged, AirPods and media retain their geometry.
    // The warning label may scale slightly on Macs with a smaller physical notch.
    var lowBatteryWing: CGFloat { 78 }
    var unpluggedWing: CGFloat { 76 }
    var powerEventWing: CGFloat {
        if event == .unplugged { return unpluggedWing }
        if event == .lowBattery { return lowBatteryWing }
        return chargingWing
    }
    var airPodsLeftWing: CGFloat { 40 }
    var airPodsRightWing: CGFloat { 40 }
    var airPodsWidth: CGFloat { notchWidth + airPodsLeftWing + airPodsRightWing }
    // Focus: a symmetric, compact banner (icon on the left, state on the right).
    var focusWing: CGFloat { 46 }
    var focusWidth: CGFloat { notchWidth + focusWing * 2 }
    // 3.18.1: wide enough that «Обновить» never reaches the rounded edge.
    var updateWing: CGFloat { 84 }
    var updateWidth: CGFloat { notchWidth + updateWing * 2 }
    var noticeWing: CGFloat { 56 }
    var noticeWidth: CGFloat { notchWidth + noticeWing * 2 }
    var eventWidth: CGFloat {
        if event == .airPods { return airPodsWidth }
        if event == .focus { return focusWidth }
        if event == .update { return updateWidth }
        if event == .notice { return noticeWidth }
        return notchWidth + powerEventWing * 2
    }
    // The cutout itself contains no pixels. Put the charging glow's bottom
    // bridge just BELOW the physical notch, rather than trying to draw it
    // through the camera cutout where macOS cannot display anything.
    // Keep AirPods and media at their original height.
    var chargingBridgeDepth: CGFloat { 1.2 }
    var eventHeight: CGFloat {
        notchHeight + ((event == .charging || event == .lowBattery) ? chargingBridgeDepth : 0)
    }
    // A clear border in the hosting window is required for an OUTSIDE glow.
    // This does not change the shape width or the physical notch position.
    var chargingGlowWindowMargin: CGFloat { 7 }
    // Render a black roof ABOVE the screen edge. The visible lower edge
    // stays fixed, preventing a thin menu-bar seam at the top of charging.
    var chargingTopBleed: CGFloat { 5 }
    var mediaTopBleed: CGFloat { 5 }
    // One viewport origin for EVERY visible mode, not separate charge/media
    // window coordinates. The roof lives above the physical display edge.
    var islandTopBleed: CGFloat { 5 }

    var panelSize: CGSize {
        if unlockTransitionActive {
            // Reserve the complete final canvas BEFORE presenting the panel.
            // The silhouette contracts only within this single window.
            return CGSize(width: max(notchWidth + 76, compactWidth),
                          height: max(notchHeight, compactDisplayHeight) + islandTopBleed)
        }
        if event != nil || eventHandoffCanvasActive || coverGlowCanvasInUse {
            // Hold a single AppKit frame through charging/other events and
            // the immediate return to compact media. Visible widths/heights
            // in IslandView are unchanged.
            let glow = chargingGlowWindowMargin
            let maxEventWidth = max(chargingWidth, notchWidth + lowBatteryWing * 2,
                                    notchWidth + unpluggedWing * 2, airPodsWidth, focusWidth, updateWidth, noticeWidth)
            return CGSize(width: max(maxEventWidth + glow * 2, compactWidth),
                          height: max(notchHeight + chargingBridgeDepth + islandTopBleed + glow,
                                      compactDisplayHeight + islandTopBleed))
        }
        if canvasExpanded || usesFixedMediaSatelliteCanvas {
            return CGSize(width: expandedWidth,
                          height: expandedHeight + islandTopBleed)
        }
        if track != nil || timerPresented {
            return CGSize(width: compactWidth,
                          height: compactDisplayHeight + islandTopBleed)
        }
        return .zero
    }

    func prepareForScreenLock() {
        // Invalidate a still-running previous unlock before the lock NSPanel
        // appears. Stale callbacks must never expose the old music window.
        unlockTransitionToken = UUID()
        unlockSequenceStarted = false
        unlockHandoffCompletion = nil
        unlockTransitionActive = false
        unlockSurfaceProgress = 0
        unlockSymbolOpacity = 0
        unlockSymbolOpen = false
        unlockMediaOpacity = 1
        pointerInsideIsland = false
        // All pending media/event transitions belong to the old desktop
        // session. Cancel their callbacks before SkyLight takes over.
        eventToken = UUID()
        scheduledEvent = nil
        deferredEvents.removeAll()
        clearLowBatteryPresentation()
        eventCanvasReleaseToken = UUID()
        eventHandoffCanvasActive = false
        compactRevealToken = UUID()
        resetExpandedImmediately()
        eventRevealed = false
        eventContentVisible = false
        stopCoverGlow()
        eventEnteringFromMedia = false
        eventReturningToMedia = false
        eventRestingWidth = nil
        event = nil
        // Never reuse a fully revealed compact island when the desktop returns.
        // Its original state may have been captured before the lock screen.
        compactRevealToken = UUID()
        compactRevealed = false
        isSessionLocked = true
    }

    func finishScreenUnlock() {
        // Used by the existing desktop-only settings preview.
        ignoreHoverBefore = Date().addingTimeInterval(1.15)
        compactRevealToken = UUID()
        compactRevealed = (track != nil || timerPresented)
        isSessionLocked = false
    }

    // A deliberate on-screen pause after the glyph opens: the old 430 ms
    // retraction made the unlocked state almost impossible to see. These
    // timings govern only the desktop handoff, not the protected SkyLight
    // lock entrance or any other island animation.
    private enum UnlockTiming {
        static let openDelay: TimeInterval = 0.28
        static let openDuration: Double = 0.26
        static let openHold: TimeInterval = 1.15
        static let retractDelay = openDelay + openDuration + openHold
        static let retractDuration: Double = 0.55
        static let completionDelay = retractDelay + retractDuration + 0.14
    }

    func animateRealScreenUnlock(completion: @escaping () -> Void) {
        // First publish the fully reserved lock-sized canvas; only then reveal
        // the already-existing media NSPanel in the app delegate. Never create
        // a second desktop lock panel or run the normal compact entrance.
        let token = UUID()
        unlockTransitionToken = token
        unlockSequenceStarted = false
        unlockHandoffCompletion = completion
        ignoreHoverBefore = Date().addingTimeInterval(UnlockTiming.completionDelay + 0.25)
        compactRevealToken = UUID()
        // 3.4.1: the staged lock silhouette must appear EXACTLY like the
        // SkyLight lock island. compactRevealed has an implicit morph spring
        // in IslandView; without this transaction the desktop island started
        // narrow and with a half-faded padlock, and sprang open → the visible
        // twitch right after unlock.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            compactRevealed = (track != nil || timerPresented)
            // Arrange the silhouette AND symbol before the window is ordered.
            // Publish the visibility flag only after the presentation is ready.
            unlockSurfaceProgress = 1
            unlockSymbolOpacity = 1
            unlockSymbolOpen = false
            unlockMediaOpacity = 0
            unlockTransitionActive = true
            isSessionLocked = false
        }
        LockScreenOverlay.logSessionEvent("unlock: single-panel closed padlock staged")
    }

    // Start the icon sequence only AFTER the SkyLight handoff has actually
    // finished. Under slow WindowServer transitions, a fixed timestamp from
    // sessionIsUnlocked could open/retract the symbol behind the protected
    // surface before the desktop island had been drawn.
    func playRealScreenUnlockPhases() {
        guard unlockTransitionActive, !isSessionLocked,
              !unlockSequenceStarted else { return }
        unlockSequenceStarted = true
        let token = unlockTransitionToken
        LockScreenOverlay.logSessionEvent("unlock: desktop panel ready; icon sequence starting")
        // The closed lock becomes an open lock while the black outline stays
        // attached to the hardware notch; the media remains hidden underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + UnlockTiming.openDelay) { [weak self] in
            guard let self, self.unlockTransitionToken == token,
                  self.unlockTransitionActive && !self.isSessionLocked else { return }
            withAnimation(.easeInOut(duration: UnlockTiming.openDuration)) {
                self.unlockSymbolOpen = true
            }
            LockScreenOverlay.logSessionEvent("unlock: opening padlock glyph")
        }
        // Once the glyph has fully opened, leave the black island and OPEN
        // padlock visible for over one second. Neither music nor cable/AirPods
        // banners may pre-empt this phase. The original silhouette is NOT
        // discarded or recreated between these states.
        DispatchQueue.main.asyncAfter(deadline: .now() + UnlockTiming.openDelay + UnlockTiming.openDuration) { [weak self] in
            guard let self, self.unlockTransitionToken == token,
                  self.unlockTransitionActive && !self.isSessionLocked else { return }
            LockScreenOverlay.logSessionEvent("unlock: open padlock hold started (1.15s)")
        }
        // End the open-lock hold by gently returning to compact music (or the
        // bare hardware notch when nothing is playing). The same NSPanel and
        // SwiftUI shape remain mounted during the entire contraction.
        DispatchQueue.main.asyncAfter(deadline: .now() + UnlockTiming.retractDelay) { [weak self] in
            guard let self, self.unlockTransitionToken == token,
                  self.unlockTransitionActive && !self.isSessionLocked else { return }
            withAnimation(.easeInOut(duration: UnlockTiming.retractDuration)) {
                self.unlockSurfaceProgress = 0
                self.unlockSymbolOpacity = 0
                self.unlockMediaOpacity = 1
            }
            LockScreenOverlay.logSessionEvent("unlock: open padlock hold ended; compact contraction begun")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + UnlockTiming.completionDelay) { [weak self] in
            guard let self, self.unlockTransitionToken == token,
                  self.unlockTransitionActive && !self.isSessionLocked else { return }
            self.unlockTransitionActive = false
            self.unlockSequenceStarted = false
            self.unlockSymbolOpacity = 0
            self.unlockSymbolOpen = false
            self.unlockMediaOpacity = 1
            self.unlockSurfaceProgress = 0
            LockScreenOverlay.logSessionEvent("unlock: one-panel animation completed after open-lock hold")
            // The callback originated in animateRealScreenUnlock(), not in
            // playRealScreenUnlockPhases(). Take it exactly once, and only for
            // this still-current generation (validated by the guard above).
            let completion = self.unlockHandoffCompletion
            self.unlockHandoffCompletion = nil
            completion?()  // Delegate drains genuine battery alerts first.
            // Deliver ordinary cable/AirPods events only after that priority
            // decision, without interrupting a 7-second low-battery warning.
            if self.event == nil && !self.isSessionLocked && !self.deferredEvents.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.unlockTransitionActive,
                          !self.isSessionLocked, self.event == nil,
                          !self.deferredEvents.isEmpty else { return }
                    let nextEvent = self.deferredEvents.removeFirst()
                    self.show(nextEvent)
                }
            }
        }
    }

    func show(_ nextEvent: IslandEvent) {
        PerformanceMonitor.write("event \(nextEvent)")
        guard !isSessionLocked, !cinemaMode else { return }
        // A late cable/AirPods event must not cut off the visible open-padlock
        // transition. Queue it until the single-panel handoff is finished.
        if unlockTransitionActive {
            if nextEvent == .charging || nextEvent == .unplugged {
                deferredEvents.removeAll { $0 == .charging || $0 == .unplugged }
            }
            if !deferredEvents.contains(nextEvent) { deferredEvents.append(nextEvent) }
            return
        }
        // A 7-second low-battery warning must not be overwritten by a later
        // cable or AirPods notification, including during player collapse.
        // Keep those ordinary notifications for the end of the warning.
        if nextEvent != .lowBattery &&
           (event == .lowBattery || scheduledEvent == .lowBattery) {
            if nextEvent == .charging || nextEvent == .unplugged {
                deferredEvents.removeAll { $0 == .charging || $0 == .unplugged }
            }
            if !deferredEvents.contains(nextEvent) { deferredEvents.append(nextEvent) }
            return
        }
        // If the tall player is open, give its silhouette time to collapse
        // smoothly. Starting the event in the same tick used to discard the
        // expanded window mid-spring and exposed a frame of empty black.
        if isExpanded || canvasExpanded {
            let token = UUID()
            eventToken = token
            scheduledEvent = nextEvent
            collapsePlayer()
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.canvasSettle) { [weak self] in
                guard let self, self.eventToken == token, !self.isSessionLocked else { return }
                self.startEvent(nextEvent, token: token)
            }
            return
        }
        let token = UUID()
        eventToken = token
        startEvent(nextEvent, token: token)
    }

    private func startEvent(_ nextEvent: IslandEvent, token: UUID) {
        guard eventToken == token, !isSessionLocked else { return }
        scheduledEvent = nil
        // This is the sole event-transition sequence. All callbacks check
        // the generation so late timers cannot resurrect previous events.
        eventCanvasReleaseToken = UUID()
        eventHandoffCanvasActive = true
        hoverEnter?.cancel()
        hoverEnter = nil
        hoverExit?.cancel()
        hoverExit = nil
        pointerInsideIsland = false
        let fromMedia = (track != nil || timerPresented) && event == nil && compactRevealed
        if event != nil {
            // An event can interrupt another event: retain the CURRENT wing
            // width rather than flashing the physical-notch-sized surface.
            eventRestingWidth = eventRevealed ? eventWidth : (eventRestingWidth ?? notchWidth)
        } else {
            eventRestingWidth = fromMedia ? compactWidth : notchWidth
        }
        eventEnteringFromMedia = fromMedia
        eventReturningToMedia = false
        stopCoverGlow()
        if eventContentVisible {
            withAnimation(.easeIn(duration: 0.1)) { eventContentVisible = false }
        }
        eventRevealed = false
        event = nextEvent
        // The panel is positioned and its compact content is rendered before
        // changing any animated property. No forced blank-notch frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self, self.eventToken == token, self.event == nextEvent,
                  !self.isSessionLocked else { return }
            withAnimation(IslandMotion.banner) {
                self.eventRevealed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035 + IslandMotion.bannerContentDelay) { [weak self] in
            guard let self, self.eventToken == token, self.event == nextEvent,
                  !self.isSessionLocked else { return }
            withAnimation(IslandMotion.bannerContentIn) { self.eventContentVisible = true }
        }
        let dwell: TimeInterval
        if nextEvent == .airPods { dwell = IslandMotion.eventHoldAirPods }
        else if nextEvent == .focus { dwell = IslandMotion.eventHoldFocus }
        else if nextEvent == .update { dwell = IslandMotion.eventHoldUpdate }
        else if nextEvent == .notice { dwell = notice?.duration ?? IslandMotion.eventHoldNotice }
        else if nextEvent == .lowBattery { dwell = IslandMotion.eventHoldLowBattery }
        else { dwell = IslandMotion.eventHoldCharging }
        scheduleEventExit(nextEvent, token: token, dwell: dwell)
    }

    // The exit half of the banner sequence. Extracted (3.3.0) so a banner
    // can be extended in place with a new generation token.
    private func scheduleEventExit(_ nextEvent: IslandEvent, token: UUID, dwell: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell) { [weak self] in
            guard let self, self.eventToken == token, self.event == nextEvent,
                  !self.isSessionLocked else { return }
            withAnimation(IslandMotion.bannerContentOut) { self.eventContentVisible = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell + IslandMotion.bannerExitLead) { [weak self] in
            guard let self, self.eventToken == token, self.event == nextEvent,
                  !self.isSessionLocked else { return }
            let returning = self.track != nil || self.timerPresented
            withAnimation(IslandMotion.bannerRetract) {
                self.eventRestingWidth = returning ? self.compactWidth : self.notchWidth
                self.eventReturningToMedia = returning
                self.eventRevealed = false
                if returning { self.compactRevealed = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell + IslandMotion.bannerExitLead + IslandMotion.eventSettle) { [weak self] in
            guard let self, self.eventToken == token, self.event == nextEvent,
                  !self.isSessionLocked else { return }
            // The single silhouette already matches compact media size.
            // End the event without a second entrance animation.
            // Clear transition flags before relinquishing the event so the
            // compact content is already ready on the very next SwiftUI pass.
            self.eventEnteringFromMedia = false
            self.eventReturningToMedia = false
            self.eventRestingWidth = nil
            self.event = nil
            let releaseToken = UUID()
            self.eventCanvasReleaseToken = releaseToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, self.eventCanvasReleaseToken == releaseToken,
                      self.event == nil, !self.isSessionLocked else { return }
                self.eventHandoffCanvasActive = false
            }
            if self.track != nil && !self.compactRevealed {
                self.compactRevealed = true
            }
            self.onEventFinished?()
            // The delegate gets first refusal: a genuine queued battery
            // warning takes priority over ordinary deferred notifications.
            if self.event == nil && !self.isSessionLocked && !self.deferredEvents.isEmpty {
                let next = self.deferredEvents.removeFirst()
                self.show(next)
            }
        }
    }

    func command(_ command: PlaybackCommand) {
        guard var song = track else { return }
        let now = Date()
        switch command {
        case .toggle:
            // Optimistic UI: icon and progress clock update synchronously with
            // the click. Any stale poll is ignored for a short acknowledgement
            // window; eventually the authoritative player state wins.
            let position = displayedPosition(at: now)
            song.isPlaying.toggle()
            anchorPosition = position
            anchorDate = now
            optimisticPlaying = song.isPlaying
            optimisticUntil = now.addingTimeInterval(2.8)
            track = song
        case .next, .previous:
            protectDuringTrackChange()
            pendingSkip = command
            pendingSkipFrom = song.artworkIdentity
            pendingSkipUntil = now.addingTimeInterval(4.0)
            if command == .next { nextPulse += 1 }
            else { previousPulse += 1 }
        }
        requestCommand?(command)
    }
}

final class IslandPanel: NSPanel {
    // Charging and media share an off-screen roof to hide the menu-bar seam.
    // AppKit's default constraint would push the roof back onto the display.
    var permitsChargingTopBleed = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        permitsChargingTopBleed ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// Keep the timer window hit area inside its visible black silhouette.
// AppKit positions NSView bounds with a bottom-left origin; the visible
// timer always grows downward from the top-left corner.
final class TimerSatelliteHostingView: NSHostingView<TimerSatelliteView> {
    var visibleSize: (() -> CGSize)?
    // Transparent lead-in on the left used only by the entrance animation.
    var leadingInset: (() -> CGFloat)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let size = visibleSize?() ?? bounds.size
        let hit = CGRect(x: leadingInset?() ?? 0, y: bounds.height - size.height,
                         width: size.width, height: size.height)
        guard hit.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

final class IslandAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = IslandState()
    private let media = MediaReader()
    private let favorites = FavoritesController()
    private let audio = SystemAudioAnalyzer()
    private let airPodsMonitor = AirPodsMonitor()
    private let focusMonitor = FocusModeMonitor()
    private let updater = AppUpdater()
    // 3.3.0 laboratory
    private let outputMonitor = OutputMonitor()
    private let privacyMonitor = PrivacyMonitor()
    private let networkWatch = NetworkWatch()
    private let loadMonitor = LoadMonitor()
    private let diskWatch = DiskWatch()
    private let clipboardWatch = ClipboardWatch()
    private let screenshotWatch = ScreenshotWatch()
    private let agenda = AgendaWatch()
    private let hotKey = IslandHotKey()
    // 4.3.0: ⌃⌥L — fix the layout of the selected text / last word.
    private let layoutHotKey = IslandHotKey(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, id: 2)
    private let layoutFixer = LayoutFixer()
    private let shelf = ShelfModel()
    private let airDropWatch = AirDropReceiveWatch()
    private let eyeBreak = EyeBreakWatch()
    private var eyeBreakTimer: Timer?
    private let loadSampler = SystemLoadSampler()
    private var stateChangeCounter: AnyCancellable?
    private let standby = StandByController()
    private var shelfPanel: IslandPanel?
    private var shelfPanelVisible = false
    private var notchDropPanel: IslandPanel?
    private var shelfObserver: AnyCancellable?
    private var sleepDeadline: Date?
    private var sleepTimer: Timer?
    private var scrollMonitor: Any?
    private var mediaGesture = MediaScrollGesture()
    private var mediaGestureActive = false
    private let clockTimers = ClockTimerBridge()
    private var panel: IslandPanel?
    private var timerPanel: IslandPanel?
    private var timerPanelIsVisible = false
    private var timerWindowTransitionToken = UUID()
    private var timerWindowTransitionEnds = Date.distantPast
    // Keep the mini-island beneath the cursor while the main island collapses.
    private var timerPinnedX: CGFloat?
    private var lockOverlay: LockScreenOverlay?
    private var lockWidgetsTimer: Timer?
    private var isScreenLocked = false
    // Screen-unlocked notifications may arrive later than the actual WindowServer
    // transition. Watch the session bit only WHILE locked as an early hint.
    private var unlockWatchTimer: Timer?
    private var observedLockedSessionBit = false
    private var lastCompletedUnlockAt = Date.distantPast
    // Cancel any late desktop fade if macOS unlocks before it completes.
    private var desktopLockFadeToken = UUID()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    // Show preferences on the first foreground launch; later Dock clicks use
    // applicationShouldHandleReopen, even if the always-on-top islands exist.
    private var handledInitialActivation = false
    private let settingsSnapshot = NotchSettingsSnapshot()
    private var audioCaptureMenuItem: NSMenuItem?
    private var hapticsMenuItem: NSMenuItem?
    private var lockMenuItem: NSMenuItem?
    private var audioStatusItem: NSMenuItem?
    private var lockStatusItem: NSMenuItem?
    private var spotifyStatusItem: NSMenuItem?
    private var yandexStatusItem: NSMenuItem?
    private var clockStatusItem: NSMenuItem?
    private var timerDiagnosticsItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var batteryStatusItem: NSMenuItem?
    private var batteryExplanationItem: NSMenuItem?
    private var mediaTimer: Timer?
    private var batteryTimer: Timer?
    private var fullscreenVisibilityTimer: Timer?
    private var countdownCheckTimer: Timer?
    private var powerRunLoopSource: CFRunLoopSource?
    private var mediaBusy = false
    private var lastACPower: Bool?
    private var lowBatteryWarnings = LowBatteryWarningTracker()
    // Only the deepest pending real threshold is kept. A manual preview is
    // independent and never marks a threshold as delivered.
    private var pendingLowBatteryWarning: Int?
    private var pendingLowBatteryPreview: Int?
    private var activeLowBatteryWarning: (threshold: Int, preview: Bool)?
    private var unlockHandoffInProgress = false
    private var panelIsVisible = false

    private let iconSwitcher = AppIconSwitcher()

    // 3.11.0: double-click on a «.notchprofile» file → added to «Мои профили».
    func application(_ application: NSApplication, open urls: [URL]) {
        var added: [String] = []
        for url in urls where url.pathExtension.lowercased() == UserProfileStore.fileExtension {
            guard let data = try? Data(contentsOf: url),
                  var profile = UserProfileStore.importProfile(from: data) else { continue }
            var list = UserProfileStore.load()
            profile.name = UserProfileStore.uniqueName(profile.name, among: list)
            list.append(profile)
            UserProfileStore.save(list)
            added.append(profile.name)
        }
        guard !added.isEmpty else { return }
        settingsSnapshot.userProfiles = UserProfileStore.load()
        settingsSnapshot.profileMessage = added.count == 1 ? "Добавлен профиль «\(added[0])»" : "Добавлено профилей: \(added.count)"
        settingsSnapshot.selectedSection = "profiles"
        settingsSnapshot.onHome = false
        openSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This is a regular Dock app, not a background-only menu-bar agent.
        // The two-command status menu and nonactivating island panels remain.
        NSApp.setActivationPolicy(.regular)
        PerformanceMonitor.start()
        standby.show = { [weak self] on in
            guard let self else { return }
            self.lockOverlay?.setStandBy(on, on: self.displayScreen())
        }
        lockOverlayStandByHook()
        stateChangeCounter = state.objectWillChange.sink { _ in PerformanceMonitor.count("state change") }
        iconSwitcher.start()
        // 3.1.11: the artwork-source switches were removed from Settings.
        // Clear any switch turned off earlier so no source stays silently disabled.
        for provider in ArtworkProvider.allCases {
            UserDefaults.standard.removeObject(forKey: provider.preferenceKey)
        }
        makeMenu()
        makePanel()
        favorites.onState = { [weak self] key, saved, busy in
            self?.state.receiveFavorite(key: key, value: saved, busy: busy)
        }
        favorites.onYandexConnection = { [weak self] message in
            self?.yandexStatusItem?.title = message
            self?.favorites.invalidate()
            self?.favorites.refresh(track: self?.state.track)
        }
        favorites.onSpotifyConnection = { [weak self] message in
            self?.spotifyStatusItem?.title = message
            self?.favorites.invalidate()
            self?.favorites.refresh(track: self?.state.track)
        }
        state.requestFavoriteSetup = { [weak self] in
            self?.showYandexFavoriteSetup()
        }
        state.requestFavorite = { [weak self] song, target in
            guard let self else { return }
            let key = FavoritesController.key(for: song)
            self.favorites.change(track: song, to: target) { [weak self] success in
                guard let self else { return }
                self.state.finishFavorite(trackKey: key, desired: target, success: success)
                self.favorites.invalidate()
                self.favorites.refresh(track: self.state.track)
            }
        }
        // Handle OAuth's registered custom redirect scheme from the browser.
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(receiveSpotifyURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        // Prepare the secure-space candidate while the user session is active.
        // Unlike the normal media panel, this second panel is noninteractive
        // and only draws a small padlock, never personal/media information.
        lockOverlay = LockScreenOverlay(state: state)
        lockOverlayStandByHook()
        lockOverlay?.prepare(on: displayScreen())
        lockStatusItem?.title = lockOverlay?.usesPrivateLockSpace == true
            ? "Замочек: экспериментальный SkyLight (не гарантирован)"
            : "Замочек: только обычное окно (ограничено)"
        audio.onLevels = { [weak self] values in self?.state.audioLevels = values }
        audio.onStatus = { [weak self] message in
            guard let self else { return }
            self.state.audioStatus = message
            self.audioStatusItem?.title = "Аудио: " + message
        }
        if state.audioCaptureEnabled { audio.start() }

        state.layoutChanged = { [weak self] in
            guard let self else { return }
            self.updatePanelFrame(animated: true)
            self.lockOverlay?.reposition(on: self.displayScreen())
            // layoutChanged can run within a @Published didSet. Drain on the
            // next main-loop turn so the full state transition has completed.
            DispatchQueue.main.async { [weak self] in self?.drainLowBatteryQueue() }
        }
        state.onEventFinished = { [weak self] in
            guard let self else { return }
            if self.activeLowBatteryWarning != nil {
                self.activeLowBatteryWarning = nil
                self.state.clearLowBatteryPresentation()
            }
            self.drainLowBatteryQueue()
        }
        state.requestCommand = { [weak self] action in self?.send(action) }
        state.requestSeek = { [weak self] seconds in self?.seek(to: seconds) }
        state.onTimerFinished = nil // Clock.app itself delivers its timer alert.
        clockTimers.onStatus = { [weak self] message in
            self?.settingsSnapshot.clockStatus = message
        }
        clockTimers.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            if let snapshot {
                self.state.applyClockTimer(remaining: snapshot.remaining, paused: snapshot.paused)
                self.clockStatusItem?.title = "Часы: системный таймер синхронизирован"
                self.refreshTimerDiagnostics()
            } else {
                self.state.clearClockTimer()
                self.clockStatusItem?.title = self.clockTimers.statusLine
                self.refreshTimerDiagnostics()
            }
        }
        state.requestClockTimerToggle = { [weak self] in self?.clockTimers.togglePause() }
        state.requestClockTimerCancel = { [weak self] in self?.clockTimers.cancel() }
        clockTimers.start()
        airPodsMonitor.onConnected = { [weak self] status in
            self?.state.receiveAirPods(status, newlyConnected: true)
        }
        airPodsMonitor.onUpdated = { [weak self] status in
            self?.state.receiveAirPods(status, newlyConnected: false)
        }
        airPodsMonitor.start()
        focusMonitor.onChange = { [weak self] mode, previous in
            guard let self else { return }
            // A switch between two modes announces the new one; turning
            // Focus off shows the mode that has just ended, in grey.
            if let mode {
                self.state.presentFocusChange(FocusPresentation(mode: mode, isOn: true))
            } else if let previous {
                self.state.presentFocusChange(FocusPresentation(mode: previous, isOn: false))
            }
        }
        focusMonitor.onStatus = { [weak self] in self?.refreshFocusStatus() }
        if Self.focusIslandEnabled { focusMonitor.start() }
        updater.onChange = { [weak self] updateState in
            guard let self else { return }
            self.refreshUpdateStatus()
            // Announce each newer release once in the island itself.
            if case .available(let candidate) = updateState,
               UserDefaults.standard.string(forKey: Self.announcedUpdateKey) != candidate.version {
                UserDefaults.standard.set(candidate.version, forKey: Self.announcedUpdateKey)
                self.state.presentUpdate(version: candidate.version)
            }
        }
        state.requestUpdate = { [weak self] in self?.installAvailableUpdate() }
        // Scroll events reach this app only while the pointer is over one of
        // its windows; we act only over the visible music island.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleMediaScroll(event) ? nil : event
        }
        updater.start()
        setUpLaboratory()
        // 3.15.0: the tour once (also after updating); it covers permissions.
        if UserDefaults.standard.bool(forKey: OnboardingView.doneKey) {
            showPermissionsAssistantIfNeeded()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showOnboarding() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sessionLocked(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionUnlocked(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionLocked(_:)), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionUnlocked(_:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspace.addObserver(self, selector: #selector(foregroundApplicationChanged(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(activeSpaceChanged(_:)),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        state.mediaVisibilitySettingsChanged = { [weak self] in self?.refreshMediaFullscreenVisibility() }
        // Tab switches inside a browser have no notification: a light check
        // (one window title through Accessibility) twice a second.
        fullscreenVisibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            PerformanceMonitor.measure("media visibility") {
                self?.refreshMediaFullscreenVisibility()
                self?.refreshCinemaMode()
            }
        }
        fullscreenVisibilityTimer?.tolerance = 0.3

        // 3.8.0: changes in Now Playing arrive as events; each one triggers
        // an immediate (process-free) read of the stream's latest state.
        media.onStreamChange = { [weak self] in PerformanceMonitor.measure("media poll") { self?.pollMedia() } }
        media.startStream()
        pollMedia()
        checkBattery()
        // A one-shot timer is scheduled only AFTER each media query finishes.
        // This avoids launching a new osascript every second while idle.
        // Buttons still request an immediate poll after the command completes.
        // Notifications fire immediately on cable connect/disconnect. The
        // fallback poll handles systems that do not deliver IOKit callbacks.
        if let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let delegate = Unmanaged<IslandAppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { [weak delegate] in delegate?.checkBattery() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
        // Power-source changes are normally delivered by IOKit immediately;
        // polling is only a conservative fallback.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in self?.checkBattery() }
        batteryTimer?.tolerance = 2.0
    }

    // Clicking the already-running app in the Dock must reopen the real
    // settings NSWindow, regardless of whether a media/timer NSPanel is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false // We handle window presentation ourselves.
    }

    // A first manual launch from Finder, Spotlight, Launchpad or the Dock
    // should open preferences without requiring a second Dock click.
    // Login-item launches that stay in the background do not get a popup.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !handledInitialActivation else { return }
        handledInitialActivation = true
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive, self.settingsWindow?.isVisible != true else { return }
            self.openSettings()
        }
    }

    // Closing the preferences window never shuts down the island service.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaTimer?.invalidate()
        batteryTimer?.invalidate()
        fullscreenVisibilityTimer?.invalidate()
        countdownCheckTimer?.invalidate()
        stopUnlockWatch()
        clockTimers.stop()
        airPodsMonitor.stop()
        media.stopStream()
        focusMonitor.stop()
        updater.stop()
        stopLaboratory()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let source = powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerRunLoopSource = nil
        }
        audio.stop()
        lockOverlay?.hideImmediately()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func makeMenu() {
        // All functionality stays in the native settings window; keep the
        // menu bar deliberately minimal, with exactly two visible commands.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.dotted.circle.fill", accessibilityDescription: "Notch Island")
        item.button?.toolTip = "Notch Island — настройки"

        let menu = NSMenu()
        menu.delegate = self
        let settingsItem = NSMenuItem(title: "Настройки Notch Island…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        refreshLaunchAtLogin()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLogin()
        refreshTimerDiagnostics()
        checkBattery()
        refreshBatteryMenuStatus()
        syncSettingsToggles()
    }

    private func setSpectrumTuning(_ settings: SpectrumTuning) {
        let validated = settings.validated()
        settingsSnapshot.spectrumTuning = validated
        validated.save()
        audio.updateTuning(validated)
    }

    private func syncSettingsToggles() {
        settingsSnapshot.hoverHapticsEnabled = state.hoverHapticsEnabled
        settingsSnapshot.audioCaptureEnabled = state.audioCaptureEnabled
        settingsSnapshot.lockIslandEnabled = UserDefaults.standard.object(forKey: "enableLockIslandV21") as? Bool != false
        settingsSnapshot.focusIslandEnabled = Self.focusIslandEnabled
        settingsSnapshot.mediaGesturesEnabled = Self.mediaGesturesEnabled
        refreshFocusStatus()
    }

    // New in 3.1.9; enabled by default. Existing preferences are untouched.
    private static let focusIslandKey = "focusIslandEnabledV319"
    private static var focusIslandEnabled: Bool {
        UserDefaults.standard.object(forKey: focusIslandKey) as? Bool ?? true
    }

    private func setFocusIslandEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.focusIslandKey)
        settingsSnapshot.focusIslandEnabled = enabled
        if enabled { focusMonitor.start() } else { focusMonitor.stop() }
        refreshFocusStatus()
    }

    private func refreshFocusStatus() {
        settingsSnapshot.focusStatus = focusMonitor.statusLine
        settingsSnapshot.focusNeedsAccess = focusMonitor.isRunning && focusMonitor.access == .denied
    }

    private static let announcedUpdateKey = "announcedUpdateVersionV3113"

    // MARK: Media gestures (3.1.14)

    // MARK: Permissions and diagnostics (3.2.0)

    private var permissionsTimer: Timer?

    private func refreshPermissions() {
        let report = PermissionChecker.check()
        settingsSnapshot.permAccessibility = report.accessibility
        settingsSnapshot.permFullDisk = report.fullDiskAccess
        settingsSnapshot.permDownloads = report.downloads
        switch report.signing {
        case .persistent(let name):
            settingsSnapshot.signingPersistent = true
            settingsSnapshot.signingDescription = "Постоянная подпись «\(name)». Разрешения сохраняются при обновлениях."
        case .adhoc:
            settingsSnapshot.signingPersistent = false
            settingsSnapshot.signingDescription = "Временная подпись: после каждого обновления разрешения нужно включать заново. Установщик 3.2.0 создаёт постоянную подпись автоматически — переустанови приложение."
        case .unknown:
            settingsSnapshot.signingPersistent = false
            settingsSnapshot.signingDescription = "Не удалось определить подпись приложения."
        }
    }

    // While Settings is open, follow permission changes made in System Settings.
    private func startPermissionsWatch() {
        guard permissionsTimer == nil else { return }
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.settingsWindow?.isVisible == true else {
                self.permissionsTimer?.invalidate()
                self.permissionsTimer = nil
                return
            }
            self.refreshPermissions()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionsTimer = timer
    }

    private func requestAccessibilityFix() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        PermissionChecker.open(PermissionChecker.accessibilityPane)
    }

    private func diagnosticsStatusLines() -> [(String, String)] {
        [("Фокусирование", focusMonitor.statusLine),
         ("Часы", clockTimers.statusLine),
         ("Спектрограмма", state.audioStatus),
         ("Обновление", updater.statusLine),
         ("Жесты", Self.mediaGesturesEnabled ? "включены" : "выключены"),
         ("Свечение обложки", state.coverGlowEnabled ? "включено" : "выключено"),
         ("Поиск музыки", media.streamStatus)]
    }

    // First launch of a new build with an essential permission missing:
    // open Settings directly on the Permissions page.
    private func showPermissionsAssistantIfNeeded() {
        let info = Bundle.main.infoDictionary ?? [:]
        let stamp = "\(info["CFBundleShortVersionString"] as? String ?? "")-\(info["CFBundleVersion"] as? String ?? "")"
        let key = "permissionsAssistantShownV320"
        guard UserDefaults.standard.string(forKey: key) != stamp,
              !PermissionChecker.check().essentialsGranted else { return }
        UserDefaults.standard.set(stamp, forKey: key)
        settingsSnapshot.selectedSection = "permissions"
        settingsSnapshot.onHome = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openSettings() }
    }

    // MARK: Laboratory (3.3.0, experimental)

    private func setUpLaboratory() {
        state.noticeTapHandler = { [weak self] tap in self?.handleNoticeTap(tap) }
        outputMonitor.onVolume = { [weak self] level, muted in
            guard let self, LabFeature.volume.isOn else { return }
            let symbol = muted || level <= 0.001 ? "speaker.slash.fill"
                : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            self.state.presentNotice(IslandNotice(
                kind: .volume, symbol: symbol, tint: .white,
                text: muted ? "Без звука" : "\(Int((level * 100).rounded()))%",
                level: muted ? 0 : Double(level), duration: 1.4,
                accessibility: "Громкость \(Int((level * 100).rounded())) процентов"))
        }
        outputMonitor.onDevice = { [weak self] name, symbol in
            guard let self, LabFeature.output.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .output, symbol: symbol, tint: Color(red: 0.39, green: 0.82, blue: 1.0),
                text: name, tap: .openSettingsPane("x-apple.systempreferences:com.apple.Sound-Settings.extension"),
                duration: 2.6, accessibility: "Звук: \(name)"))
        }
        privacyMonitor.onChange = { [weak self] camera, active in
            guard let self, LabFeature.privacy.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: camera ? .camera : .microphone,
                symbol: camera ? (active ? "video.fill" : "video.slash.fill") : (active ? "mic.fill" : "mic.slash.fill"),
                tint: active ? (camera ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(red: 1.0, green: 0.62, blue: 0.04)) : .gray,
                text: active ? "Вкл" : "Выкл", duration: 2.2,
                accessibility: (camera ? "Камера " : "Микрофон ") + (active ? "используется" : "освобождена")))
        }
        networkWatch.onVPN = { [weak self] active in
            guard let self, LabFeature.vpn.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .vpn, symbol: active ? "lock.shield.fill" : "lock.open.fill",
                tint: active ? Color(red: 0.19, green: 0.82, blue: 0.35) : .gray,
                text: active ? "VPN вкл" : "VPN выкл", duration: 2.2,
                accessibility: active ? "VPN подключён" : "VPN отключён"))
        }
        networkWatch.onInternet = { [weak self] online in
            guard let self, LabFeature.network.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .network, symbol: online ? "wifi" : "wifi.slash",
                tint: online ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(red: 1.0, green: 0.27, blue: 0.23),
                text: online ? "Онлайн" : "Нет сети", duration: online ? 2.0 : 3.5,
                accessibility: online ? "Интернет восстановлен" : "Нет подключения к интернету"))
        }
        loadMonitor.onThermal = { [weak self] _ in
            guard let self, LabFeature.thermal.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .thermal, symbol: "thermometer.high", tint: Color(red: 1.0, green: 0.27, blue: 0.23),
                text: "Нагрев", tap: .openApp("com.apple.ActivityMonitor"), duration: 3.5,
                accessibility: "Mac сильно нагрелся"))
        }
        loadMonitor.onCPU = { [weak self] usage in
            guard let self, LabFeature.thermal.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .cpu, symbol: "cpu", tint: Color(red: 1.0, green: 0.62, blue: 0.04),
                text: "ЦП \(usage)%", level: Double(usage) / 100,
                tap: .openApp("com.apple.ActivityMonitor"), duration: 3.0,
                accessibility: "Процессор загружен на \(usage) процентов"))
        }
        diskWatch.onMount = { [weak self] url in
            guard let self, LabFeature.disks.isOn else { return }
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
            self.state.presentNotice(IslandNotice(
                kind: .disk, symbol: "externaldrive.fill", tint: .white, text: name,
                tap: .revealFile(url), duration: 2.6, accessibility: "Подключён диск \(name)"))
            self.refreshLabSnapshot()
        }
        diskWatch.onUnmount = { [weak self] name in
            guard let self, LabFeature.disks.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .disk, symbol: "eject.fill", tint: .gray, text: "Извлечён",
                duration: 1.8, accessibility: "Диск \(name) извлечён"))
            self.refreshLabSnapshot()
        }
        clipboardWatch.onCopy = { [weak self] kind, symbol in
            guard let self, LabFeature.clipboard.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .clipboard, symbol: symbol, tint: .white, text: kind, duration: 1.3,
                accessibility: "Скопировано: \(kind)"))
            self.refreshLabSnapshot()
        }
        screenshotWatch.onScreenshot = { [weak self] url, isRecording in
            guard let self, LabFeature.screenshots.isOn else { return }
            if LabFeature.shelf.isOn { self.shelf.add([url]) }
            self.state.presentNotice(IslandNotice(
                kind: .screenshot, symbol: isRecording ? "record.circle" : "camera.viewfinder",
                tint: isRecording ? Color(red: 1.0, green: 0.27, blue: 0.23) : .white,
                text: isRecording ? "Запись" : "Снимок",
                thumbnail: ScreenshotWatch.thumbnail(for: url), tap: .revealFile(url), duration: 3.0,
                accessibility: isRecording ? "Новая запись экрана" : "Новый снимок экрана"))
        }
        screenshotWatch.onFinalized = { [weak self] temporary, final in
            self?.shelf.replace(temporary, with: final)
        }
        screenshotWatch.onDiscarded = { [weak self] temporary in
            self?.shelf.remove(temporary)
        }
        // 3.9.4: AirDrop — receiving progress, «Получено», «Отправлено».
        airDropWatch.onProgress = { [weak self] fraction, files, name in
            guard let self, LabFeature.airdrop.isOn else { return }
            self.state.presentNotice(IslandNotice(
                kind: .airdrop, symbol: "antenna.radiowaves.left.and.right",
                tint: Color(red: 0.04, green: 0.52, blue: 1.0),
                text: AirDropFormat.progressText(fraction: fraction, files: files),
                level: fraction, duration: 6,
                accessibility: "AirDrop: принимается \(name), \(Int(fraction * 100)) процентов"))
        }
        airDropWatch.onReceived = { [weak self] urls in
            guard let self, LabFeature.airdrop.isOn, let first = urls.first else { return }
            if LabFeature.shelf.isOn { self.shelf.add(urls) }
            self.state.presentNotice(IslandNotice(
                kind: .airdrop, symbol: "checkmark.circle.fill",
                tint: Color(red: 0.04, green: 0.52, blue: 1.0),
                text: AirDropFormat.receivedText(count: urls.count),
                thumbnail: AirDropReceiveWatch.icon(for: urls),
                tap: .revealFile(first), duration: 4,
                accessibility: "AirDrop: получено \(first.lastPathComponent)"))
        }
        // 3.17.0: 20-20-20 — not during calls, not on the lock screen.
        eyeBreak.canRemindNow = { [weak self] in
            guard let self else { return false }
            return !self.isScreenLocked && !self.state.isSessionLocked
                && self.state.canPresentNoticeNow
                && !PrivacyMonitor.cameraInUse() && !PrivacyMonitor.microphoneInUse()
        }
        eyeBreak.onRemind = { [weak self] in self?.runEyeBreak() }
        AirDropSender.shared.onSent = { [weak self] count in
            guard let self else { return }
            self.state.presentNotice(IslandNotice(
                kind: .airdrop, symbol: "paperplane.fill",
                tint: Color(red: 0.04, green: 0.52, blue: 1.0),
                text: "Отправлено", duration: 2.5,
                accessibility: count > 1 ? "AirDrop: отправлено файлов — \(count)" : "AirDrop: отправлено"))
        }
        agenda.onMeeting = { [weak self] title, minutes, link in
            guard let self else { return }
            self.state.presentNotice(IslandNotice(
                kind: .meeting, symbol: link == nil ? "calendar" : "video.fill",
                tint: Color(red: 1.0, green: 0.27, blue: 0.23), text: "\(minutes) мин",
                tap: link.map { .openURL($0) } ?? .openApp("com.apple.iCal"), duration: 6,
                accessibility: "Через \(minutes) минут: \(title)"))
        }
        agenda.onReminder = { [weak self] title in
            guard let self else { return }
            self.state.presentNotice(IslandNotice(
                kind: .reminder, symbol: "checklist", tint: Color(red: 1.0, green: 0.62, blue: 0.04),
                text: "Пора", tap: .openApp("com.apple.reminders"), duration: 6,
                accessibility: "Напоминание: \(title)"))
        }
        layoutHotKey.onPress = { [weak self] in self?.layoutFixer.run() }
        layoutFixer.pauseClipboardWatch = { [weak self] seconds in self?.clipboardWatch.pause(for: seconds) }
        layoutFixer.onResult = { [weak self] toRussian in
            self?.state.presentNotice(IslandNotice(
                kind: .layoutFix, symbol: "keyboard", tint: Color(red: 0.35, green: 0.6, blue: 1.0),
                text: toRussian ? "→ RU" : "→ EN", duration: 1.4,
                accessibility: toRussian ? "Текст переведён на русскую раскладку" : "Текст переведён на английскую раскладку"))
        }
        layoutFixer.onNothing = { [weak self] in
            self?.state.presentNotice(IslandNotice(
                kind: .layoutFix, symbol: "keyboard", tint: .gray, text: "Нечего", duration: 1.2,
                accessibility: "Нет выделенного текста для исправления раскладки"))
        }
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            if self.state.isExpanded { self.state.collapsePlayer(force: true) } else { self.state.expandPlayer() }
        }
        state.shelfModel = shelf
        shelfObserver = shelf.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let screen = self.displayScreen() else { return }
                self.updateShelfPanels(on: screen)
            }
        }
        makeShelfPanels()
        makeIdleWings()
        applyLaboratory()
    }

    // MARK: 20-20-20 (3.17.0)

    // 20 seconds in the island: «Вдаль», then the countdown with a bar, then
    // «Готово». A tap on the banner skips the break.
    private func runEyeBreak() {
        eyeBreakTimer?.invalidate()
        var second = 0
        presentEyeBreak(second)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            second += 1
            if second >= EyeBreakPolicy.restSeconds {
                timer.invalidate()
                self.eyeBreakTimer = nil
                self.state.presentNotice(IslandNotice(
                    kind: .eyeBreak, symbol: "checkmark.circle.fill", tint: Color(red: 0.2, green: 0.8, blue: 0.45),
                    text: "Готово", duration: 1.6, accessibility: "Перерыв для глаз закончен"))
            } else {
                self.presentEyeBreak(second)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eyeBreakTimer = timer
    }

    private func presentEyeBreak(_ second: Int) {
        let banner = EyeBreakPolicy.banner(at: second)
        let left = EyeBreakPolicy.restSeconds - second
        state.presentNotice(IslandNotice(
            kind: .eyeBreak, symbol: "eye.fill", tint: Color(red: 0.25, green: 0.8, blue: 0.85),
            text: banner.text, level: banner.level, tap: .stopEyeBreak, duration: 2.5,
            accessibility: "Правило 20-20-20: посмотри на что-нибудь вдалеке, метрах в шести. Осталось \(left) секунд. Нажми, чтобы пропустить"))
    }

    private func stopEyeBreak() {
        eyeBreakTimer?.invalidate()
        eyeBreakTimer = nil
        state.presentNotice(IslandNotice(kind: .eyeBreak, symbol: "eye.slash", tint: .gray, text: "Пропущено",
                                         duration: 1.2, accessibility: "Перерыв для глаз пропущен"))
    }

    private func applyLaboratory() {
        LabFeature.volume.isOn || LabFeature.output.isOn ? outputMonitor.start() : outputMonitor.stop()
        LabFeature.privacy.isOn ? privacyMonitor.start() : privacyMonitor.stop()
        LabFeature.vpn.isOn ? networkWatch.startVPN() : networkWatch.stopVPN()
        LabFeature.network.isOn ? networkWatch.startInternet() : networkWatch.stopInternet()
        LabFeature.thermal.isOn ? loadMonitor.start() : loadMonitor.stop()
        LabFeature.disks.isOn ? diskWatch.start() : diskWatch.stop()
        LabFeature.clipboard.isOn ? clipboardWatch.start() : clipboardWatch.stop()
        LabFeature.screenshots.isOn ? screenshotWatch.start() : screenshotWatch.stop()
        LabFeature.airdrop.isOn ? airDropWatch.start() : airDropWatch.stop()
        LabFeature.eyes.isOn ? eyeBreak.start() : eyeBreak.stop()
        LabFeature.hotkey.isOn ? hotKey.register() : hotKey.unregister()
        LabFeature.layout.isOn ? layoutHotKey.register() : layoutHotKey.unregister()
        agenda.calendarEnabled = LabFeature.calendar.isOn
        agenda.remindersEnabled = LabFeature.reminders.isOn
        (agenda.calendarEnabled || agenda.remindersEnabled) ? agenda.start() : agenda.stop()
        if let screen = displayScreen() { updateShelfPanels(on: screen) }
        refreshLabSnapshot()
    }

    private func stopLaboratory() {
        outputMonitor.stop(); privacyMonitor.stop(); networkWatch.stopVPN(); networkWatch.stopInternet()
        loadMonitor.stop(); diskWatch.stop(); clipboardWatch.stop(); screenshotWatch.stop(); airDropWatch.stop(); eyeBreak.stop()
        agenda.stop(); hotKey.unregister(); layoutHotKey.unregister(); sleepTimer?.invalidate()
    }

    private func setLabFeature(_ raw: String, _ on: Bool) {
        guard let feature = LabFeature(rawValue: raw) else { return }
        if on && (feature == .calendar || feature == .reminders) {
            let type: EKEntityType = feature == .calendar ? .event : .reminder
            agenda.requestAccess(to: type) { [weak self] granted in
                feature.set(granted)
                self?.applyLaboratory()
            }
            return
        }
        feature.set(on)
        applyLaboratory()
    }

    private func handleNoticeTap(_ tap: IslandNotice.Tap) {
        switch tap {
        case .none: break
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .revealFile(let url):
            // A capture may have moved from the preview folder meanwhile.
            var target = url
            if !FileManager.default.fileExists(atPath: url.path) {
                target = ScreenshotWatch.folder.appendingPathComponent(url.lastPathComponent)
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        case .openApp(let bundle):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openSettingsPane(let pane): PermissionChecker.open(pane)
        case .openShelf: shelf.hoverChanged(true)
        case .stopEyeBreak: stopEyeBreak()
        }
    }

    private func refreshLabSnapshot() {
        PerformanceMonitor.count("lab snapshot")
        var toggles: [String: Bool] = [:]
        for feature in LabFeature.allCases { toggles[feature.rawValue] = feature.isOn }
        settingsSnapshot.labToggles = toggles
        settingsSnapshot.clipboardHistory = clipboardWatch.history
        settingsSnapshot.ejectableVolumes = DiskWatch.ejectableVolumes().map(\.path)
        settingsSnapshot.batteryTimeText = BatteryTime.remainingText() ?? "Оценка недоступна"
        if let deadline = sleepDeadline {
            let minutes = max(1, Int(ceil(deadline.timeIntervalSinceNow / 60)))
            settingsSnapshot.sleepTimerStatus = "Музыка встанет на паузу через \(minutes) мин"
        } else {
            settingsSnapshot.sleepTimerStatus = "Выключен"
        }
    }

    // MARK: - Lock-screen widgets (3.7.1)

    private func refreshLockWidgets() {
        PerformanceMonitor.count("lock widgets")
        let model = LockWidgetsModel.shared
        guard model.enabled, !model.selected.isEmpty else { model.publish([:]); return }
        var available: [LockWidgetKind: LockWidgetItem] = [:]
        let wanted = Set(model.selected)
        if wanted.contains(.weather) || wanted.contains(.sun) {
            let weather = WeatherService.shared
            if let item = LockWidgetBuilder.weather(weather.snapshot) { available[.weather] = item }
            if let item = LockWidgetBuilder.sun(weather.snapshot) { available[.sun] = item }
            // Fresh weather arrives asynchronously; redraw once it is here.
            // No location prompt while locked — nobody could answer it.
            weather.refreshIfNeeded(allowPrompt: !isScreenLocked) { [weak self] in self?.refreshLockWidgets() }
        }
        if wanted.contains(.battery), let item = LockWidgetBuilder.battery(state.power) { available[.battery] = item }
        // 3.12.0
        if wanted.contains(.accessories),
           let item = LockWidgetBuilder.accessories(AccessoryBatteryReader.read()) { available[.accessories] = item }
        if wanted.contains(.system), let item = LockWidgetBuilder.system(loadSampler.sample()) { available[.system] = item }
        if wanted.contains(.airpods), let item = LockWidgetBuilder.airPods(state.airPods) { available[.airpods] = item }
        if wanted.contains(.calendar), AgendaWatch.hasAccess(to: .event),
           let item = LockWidgetBuilder.calendar(agenda.nextEvent()) { available[.calendar] = item }
        if wanted.contains(.timer), let item = LockWidgetBuilder.timer(active: state.timerActive) { available[.timer] = item }
        if wanted.contains(.focus), let mode = focusMonitor.current,
           let item = LockWidgetBuilder.focus(mode, tint: FocusPalette.color(for: mode.tintName)) { available[.focus] = item }
        if wanted.contains(.reminders) {
            agenda.remindersDueToday { count in
                var withReminders = available
                if let item = LockWidgetBuilder.reminders(count) { withReminders[.reminders] = item }
                model.publish(withReminders)
            }
        }
        model.publish(available)
    }

    private func startLockWidgets() {
        refreshLockWidgets()
        lockWidgetsTimer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.refreshLockWidgets() }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        lockWidgetsTimer = timer
    }

    private func stopLockWidgets() {
        lockWidgetsTimer?.invalidate()
        lockWidgetsTimer = nil
    }

    // MARK: - Profiles (3.5.0)

    private func currentProfileValues() -> [String: Bool] {
        var values: [String: Bool] = [:]
        for feature in LabFeature.allCases { values[feature.rawValue] = feature.isOn }
        values["lockIsland"] = settingsSnapshot.lockIslandEnabled
        values["focus"] = settingsSnapshot.focusIslandEnabled
        values["gestures"] = settingsSnapshot.mediaGesturesEnabled
        values["coverGlow"] = state.coverGlowEnabled
        values["hideFullscreen"] = state.hideMediaDuringFullscreen
        values["hideSource"] = state.hideMediaWhenSourceInFront
        // 3.11.0
        values["lockMedia"] = (UserDefaults.standard.object(forKey: LockScreenOverlay.mediaKey) as? Bool) ?? true
        values["lockWidgets"] = LockWidgetsModel.shared.enabled
        values["coverAnimated"] = (UserDefaults.standard.object(forKey: "lockCoverAnimatedV395") as? Bool) ?? true
        // 4.3.3
        values["standby"] = StandBySettings.isEnabled
        values["wings"] = IdleWings.isEnabled
        values["cinema"] = CinemaMode.isEnabled
        values["playerNew"] = ExpandedPlayerStyle.isNew
        return values
    }

    // Remember the user's own combination before something replaces it.
    private func rememberCustomIfNeeded(_ current: [String: Bool]) {
        if IslandProfiles.match(current) == .custom,
           UserProfileStore.match(current, in: UserProfileStore.load()) == nil {
            IslandProfiles.saveCustom(current)
        }
    }

    private func applyProfile(_ profile: IslandProfile) {
        let current = currentProfileValues()
        rememberCustomIfNeeded(current)
        let values = IslandProfiles.values(for: profile, saved: IslandProfiles.loadCustom(),
                                           current: current) { key in
            AgendaWatch.hasAccess(to: key == "calendar" ? .event : .reminder)
        }
        applyProfileValues(values)
    }

    // 3.11.0: one of the user's own profiles.
    private func applyUserProfile(_ id: String) {
        guard let profile = UserProfileStore.load().first(where: { $0.id == id }) else { return }
        let current = currentProfileValues()
        rememberCustomIfNeeded(current)
        var values = profile.values
        for key in IslandProfiles.permissionDependent where values[key] == true {
            if !AgendaWatch.hasAccess(to: key == "calendar" ? .event : .reminder) { values[key] = current[key] ?? false }
        }
        applyProfileValues(values)
    }

    private func applyProfileValues(_ values: [String: Bool]) {
        for feature in LabFeature.allCases {
            if let on = values[feature.rawValue] { feature.set(on) }
        }
        applyLaboratory()
        if let on = values["lockIsland"], on != settingsSnapshot.lockIslandEnabled { setLockOverlayEnabled(on) }
        if let on = values["focus"], on != settingsSnapshot.focusIslandEnabled { setFocusIslandEnabled(on) }
        if let on = values["gestures"], on != settingsSnapshot.mediaGesturesEnabled { setMediaGesturesEnabled(on) }
        if let on = values["coverGlow"], on != state.coverGlowEnabled { state.setCoverGlowEnabled(on) }
        if let on = values["hideFullscreen"], on != state.hideMediaDuringFullscreen {
            state.setHideMediaDuringFullscreen(on)
        }
        if let on = values["hideSource"], on != state.hideMediaWhenSourceInFront {
            state.setHideMediaWhenSourceInFront(on)
        }
        if let on = values["lockMedia"] { UserDefaults.standard.set(on, forKey: LockScreenOverlay.mediaKey) }
        if let on = values["lockWidgets"], on != LockWidgetsModel.shared.enabled { LockWidgetsModel.shared.setEnabled(on) }
        if let on = values["coverAnimated"] { UserDefaults.standard.set(on, forKey: "lockCoverAnimatedV395") }
        // 4.3.3
        if let on = values["standby"] { UserDefaults.standard.set(on, forKey: StandBySettings.enabledKey) }
        if let on = values["wings"] { UserDefaults.standard.set(on, forKey: IdleWings.enabledKey) }
        if let on = values["cinema"] {
            UserDefaults.standard.set(on, forKey: CinemaMode.key)
            if !on && state.cinemaMode { state.setCinemaMode(false) }
        }
        if let on = values["playerNew"] {
            UserDefaults.standard.set(on ? "new" : "classic", forKey: ExpandedPlayerStyle.key)
        }
        updateIdleWings()
        refreshLabSnapshot()
    }

    private func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        if sleepDeadline != nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, let deadline = self.sleepDeadline else { return }
                if Date() >= deadline {
                    self.sleepDeadline = nil
                    self.sleepTimer?.invalidate()
                    self.sleepTimer = nil
                    self.media.pauseSystemPlayback()
                    self.state.presentNotice(IslandNotice(
                        kind: .sleepTimer, symbol: "moon.zzz.fill", tint: Color(red: 0.49, green: 0.48, blue: 1.0),
                        text: "Пауза", duration: 3, accessibility: "Таймер сна: музыка на паузе"))
                }
                self.refreshLabSnapshot()
            }
            RunLoop.main.add(timer, forMode: .common)
            sleepTimer = timer
        }
        refreshLabSnapshot()
    }

    private func runCleanup() {
        let items = ReleaseCleanup.candidates()
        ReleaseCleanup.moveToTrash(items) { [weak self] moved in
            self?.settingsSnapshot.cleanupMessage = moved == 0
                ? "Нечего убирать."
                : "В Корзину перемещено файлов: \(moved). Их можно вернуть из Корзины."
        }
    }

    // MARK: Shelf windows

    private var shelfGap: CGFloat { state.timerSatelliteGap }

    // The visible LEFT edge of the main island right now.
    private func islandLeftEdge(centre: CGFloat) -> CGFloat {
        let notchLeft = centre - state.notchWidth / 2
        guard state.isVisible else { return idleWingsShown ? notchLeft - IdleWings.wing : notchLeft }
        if state.isExpanded || state.canvasExpanded {
            if state.usesFixedMediaSatelliteCanvas {
                // With the timer satellite the card grows leftwards from the
                // compact media island's right edge.
                return centre + state.notchWidth / 2 + state.compactWing - state.expandedWidth
            }
            return centre - state.expandedWidth / 2
        }
        if state.event != nil {
            let width = max(state.eventWidth, state.eventRestingWidth ?? 0)
            return centre - width / 2
        }
        return notchLeft - state.leftWing
    }

    // 4.1.0: a click on StandBy leaves it (the overlay is created later,
    // so the hook is attached whenever it exists).
    private func lockOverlayStandByHook() {
        guard let overlay = lockOverlay else { return }
        overlay.onStandByDismiss = { [weak self] in self?.standby.userDismissed() }
    }

    // MARK: Idle wings (4.0.0)

    private var idleWingsPanel: IslandPanel?
    private(set) var idleWingsShown = false
    private var idleWingsObservers: [AnyCancellable] = []
    private var idleWingsDefaultsObserver: NSObjectProtocol?
    private var idleWingsToken = UUID()

    // A separate, click-through black window around the notch, shown only
    // while the island itself is hidden; the island always covers it.
    private func makeIdleWings() {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.permitsChargingTopBleed = true
        panel.level = .statusBar
        panel.collectionBehavior = IslandWindowSpaces.foregroundBehavior
        let host = NSHostingView(rootView: IdleWingsView(state: state, roof: state.islandTopBleed))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        idleWingsPanel = panel
        idleWingsObservers.append(state.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateIdleWings() })
        idleWingsDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateIdleWings()
        }
        updateIdleWings()
    }

    private func updateIdleWings() {
        guard let panel = idleWingsPanel else { return }
        let screen = displayScreen()
        let want = IdleWings.isEnabled && (screen?.safeAreaInsets.top ?? 0) > 0 && !state.isVisible
            && !state.cinemaMode && !isScreenLocked && !state.isSessionLocked
        if want, let screen {
            let centre = state.notchCenterX ?? screen.frame.midX
            let width = state.notchWidth + IdleWings.wing * 2
            let frame = CGRect(x: centre - width / 2, y: screen.frame.maxY - state.notchHeight,
                               width: width, height: state.notchHeight + state.islandTopBleed)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if [IdleWings.left, IdleWings.right].contains("weather") {
                WeatherService.shared.refreshIfNeeded(allowPrompt: false) {}
            }
            guard !idleWingsShown else { return }
            idleWingsShown = true
            let token = UUID()
            idleWingsToken = token
            // After the island has shrunk back into the notch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.idleWingsToken == token, self.idleWingsShown else { return }
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 1
                }
                self.updateShelfPanels(on: screen)
            }
        } else if idleWingsShown {
            idleWingsShown = false
            let token = UUID()
            idleWingsToken = token
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.idleWingsToken == token, !self.idleWingsShown else { return }
                panel.orderOut(nil)
            })
            if let screen { updateShelfPanels(on: screen) }
        }
    }

    private func makeShelfPanels() {
        let canvas = CGSize(width: shelf.expandedSize.width, height: shelf.expandedSize.height + state.islandTopBleed)
        let panel = IslandPanel(contentRect: CGRect(origin: .zero, size: canvas),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.permitsChargingTopBleed = true
        panel.level = .screenSaver
        panel.collectionBehavior = IslandWindowSpaces.foregroundBehavior
        let host = ShelfHostingView(rootView: ShelfView(shelf: shelf, roof: state.islandTopBleed))
        host.visibleSize = { [weak self] in
            guard let self else { return .zero }
            let size = self.shelf.showsExpanded ? self.shelf.expandedSize
                : CGSize(width: self.shelf.compactSize, height: self.shelf.compactSize)
            return CGSize(width: size.width, height: size.height + self.state.islandTopBleed)
        }
        host.frame = NSRect(origin: .zero, size: canvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        shelfPanel = panel

        let drop = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        drop.isOpaque = true
        drop.backgroundColor = .black
        drop.hasShadow = false
        drop.hidesOnDeactivate = false
        drop.isMovable = false
        drop.permitsChargingTopBleed = true
        drop.level = .statusBar
        drop.collectionBehavior = IslandWindowSpaces.foregroundBehavior
        let dropView = NotchDropView(frame: .zero)
        dropView.shelf = shelf
        drop.contentView = dropView
        notchDropPanel = drop
    }

    private func updateShelfPanels(on screen: NSScreen) {
        guard let panel = shelfPanel, let drop = notchDropPanel else { return }
        let enabled = LabFeature.shelf.isOn && !state.isSessionLocked && !isScreenLocked && !state.cinemaMode
        let centre = state.notchCenterX ?? screen.frame.midX
        // Drop zone: exactly the physical notch (black on black).
        if enabled && screen.safeAreaInsets.top > 0 {
            let rect = CGRect(x: centre - state.notchWidth / 2, y: screen.frame.maxY - state.notchHeight,
                              width: state.notchWidth, height: state.notchHeight)
            if drop.frame != rect { drop.setFrame(rect, display: true) }
            if !drop.isVisible { drop.orderFrontRegardless() }
        } else if drop.isVisible {
            drop.orderOut(nil)
        }
        // Shelf: mirror of the timer satellite, to the LEFT of the island.
        // 3.3.2: instead of hiding, the shelf glides LEFT so it always keeps
        // a gap from the island's current left edge (open player, banners),
        // and glides back when the island becomes compact again.
        let show = enabled && shelf.isVisible
        let canvas = CGSize(width: shelf.expandedSize.width, height: shelf.expandedSize.height + state.islandTopBleed)
        let right = islandLeftEdge(centre: centre) - shelfGap
        let frame = CGRect(x: right - canvas.width, y: screen.frame.maxY - canvas.height + state.islandTopBleed,
                           width: canvas.width, height: canvas.height)
        if show {
            if panel.frame != frame {
                if shelfPanelVisible && abs(panel.frame.minY - frame.minY) < 1 {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.38
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                        panel.animator().setFrame(frame, display: true)
                    }
                } else {
                    panel.setFrame(frame, display: true)
                }
            }
            if !shelfPanelVisible {
                shelfPanelVisible = true
                panel.alphaValue = 1
                if !panel.isVisible { panel.orderFrontRegardless() }
                // Window first, then the SwiftUI drop on the next run-loop turn.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.shelfPanelVisible else { return }
                    self.shelf.present()
                }
            }
        } else if shelfPanelVisible {
            shelfPanelVisible = false
            shelf.dismiss { [weak self, weak panel] in
                guard let self, !self.shelfPanelVisible else { return }
                panel?.orderOut(nil)
            }
        }
    }

    private static let mediaGesturesKey = "mediaGesturesEnabledV3114"
    private static var mediaGesturesEnabled: Bool {
        UserDefaults.standard.object(forKey: mediaGesturesKey) as? Bool ?? true
    }

    private func setMediaGesturesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.mediaGesturesKey)
        settingsSnapshot.mediaGesturesEnabled = enabled
    }

    // Returns true when the event was used (and must not reach other views).
    private func handleMediaScroll(_ event: NSEvent) -> Bool {
        guard Self.mediaGesturesEnabled, let panel, event.window === panel,
              state.track != nil, state.event == nil, !state.isSessionLocked,
              !state.unlockTransitionActive, state.isPointerOverIsland else {
            mediaGestureActive = false
            return false
        }
        // Inertia after lifting the fingers must not keep skipping/turning.
        if !event.momentumPhase.isEmpty { return true }

        // Remove "natural scrolling" so +x/+y are the real finger directions.
        let inverted = event.isDirectionInvertedFromDevice
        let fingerRight = Double(inverted ? event.scrollingDeltaX : -event.scrollingDeltaX)
        let fingerUp = Double(inverted ? -event.scrollingDeltaY : event.scrollingDeltaY)

        var actions: [MediaScrollGesture.Action] = []
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) || !mediaGestureActive {
                mediaGesture.reset()
                mediaGestureActive = true
            }
            if event.phase.contains(.changed) || event.phase.contains(.began) || event.phase.isEmpty {
                actions = mediaGesture.update(dx: fingerRight, dy: fingerUp)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                mediaGestureActive = false
            }
        } else if let action = MediaScrollGesture.wheelAction(dy: Double(event.scrollingDeltaY)) {
            // A wheel turned "up" (towards the screen top) raises the volume.
            actions = [action]
        }

        for action in actions {
            switch action {
            case .next, .previous:
                let next = action == .next
                state.nudgeForSwipe(next: next)
                state.command(next ? .next : .previous)
                if state.hoverHapticsEnabled {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            case .volume(let steps):
                outputMonitor.suppressVolumeUntil = Date().addingTimeInterval(0.7)
                if let level = SystemVolume.adjust(steps: steps) {
                    state.showVolume(level)
                } else if let level = SystemVolume.current() {
                    state.showVolume(level)
                }
            }
        }
        return true
    }

    private var notesCandidateURL: URL?

    private func refreshUpdateStatus() {
        settingsSnapshot.updateStatus = updater.statusLine
        settingsSnapshot.updateAvailableVersion = updater.availableCandidate?.version
        // 3.20.0: «Что нового» from the waiting archive, read once per file.
        let candidate = updater.availableCandidate
        if candidate?.url != notesCandidateURL {
            notesCandidateURL = candidate?.url
            settingsSnapshot.updateNotes = []
            if let candidate {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let notes = ReleaseNotes.load(from: candidate.url, isArchive: candidate.isArchive)
                    DispatchQueue.main.async {
                        guard let self, self.notesCandidateURL == candidate.url else { return }
                        self.settingsSnapshot.updateNotes = notes
                    }
                }
            }
        }
        if case .installing = updater.state { settingsSnapshot.updateInstalling = true }
        else { settingsSnapshot.updateInstalling = false }
    }

    private func installAvailableUpdate() {
        guard let candidate = updater.availableCandidate else { return }
        updater.install(candidate)
    }

    private func previewFocusIsland() {
        // Demonstration only: the real Focus state is never changed.
        let mode = focusMonitor.current ?? FocusMode.demo
        state.presentFocusChange(FocusPresentation(mode: mode, isOn: true))
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshLaunchAtLogin() {
        let serviceStatus = SMAppService.mainApp.status
        launchAtLoginItem?.state = serviceStatus == .enabled ? .on : .off
        launchAtLoginItem?.title = serviceStatus == .requiresApproval
            ? "Запускать при входе (нужно разрешение macOS)"
            : "Запускать при входе в macOS"
        settingsSnapshot.launchAtLoginEnabled = serviceStatus == .enabled || serviceStatus == .requiresApproval
        settingsSnapshot.launchAtLoginNeedsApproval = serviceStatus == .requiresApproval
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        updateLaunchAtLogin(!settingsSnapshot.launchAtLoginEnabled)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = "macOS: \(error.localizedDescription). Убедись, что Notch Island установлен в папке «Программы»."
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Закрыть")
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
        refreshLaunchAtLogin()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshTimerDiagnostics() {
        guard let item = timerDiagnosticsItem else { return }
        let status = state.timerActive ? "найден" : "не найден"
        let visibility = (timerPanel?.isVisible == true && timerPanel?.alphaValue == 1)
            ? "окно показано" : "окно скрыто"
        item.title = "Остров таймера: \(status), \(visibility)"
    }

    @objc private func showTimerSatellitePreview() {
        // No second fake timer and no unconditional satellite. Preview routes
        // to the normal notch unless an actual media/event island is busy.
        state.previewTimerSatellite()
        updatePanelFrame(animated: true)
        refreshTimerDiagnostics()
    }

    private func makePanel() {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let newPanel = IslandPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isMovable = false
        newPanel.level = .screenSaver
        newPanel.collectionBehavior = IslandWindowSpaces.foregroundBehavior
        newPanel.contentView = NSHostingView(rootView: IslandView(state: state))
        panel = newPanel

        // The second panel has its own hit region, independent hover, and
        // never covers the physical notch or the main music controls.
        // Compact AppKit canvas intercepts only the actual timer surface.
        // It grows toward the right/bottom on hover without moving its roof.
        let canvas = state.timerPanelSize
        let satelliteRect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let small = IslandPanel(contentRect: satelliteRect,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        small.backgroundColor = .clear
        small.isOpaque = false
        small.hasShadow = false
        small.hidesOnDeactivate = false
        small.isMovable = false
        small.ignoresMouseEvents = false
        small.permitsChargingTopBleed = true
        small.alphaValue = 1
        // The satellite must not steal menu-bar clicks outside its bounds.
        small.level = .screenSaver
        small.collectionBehavior = IslandWindowSpaces.foregroundBehavior
        let timerHost = TimerSatelliteHostingView(rootView: TimerSatelliteView(state: state))
        timerHost.visibleSize = { [weak state] in
            guard let state else { return .zero }
            return CGSize(width: state.timerExpanded ? state.timerExpandedWidth : state.timerCompactDiameter,
                          height: state.timerExpanded ? state.timerExpandedHeight : state.timerCompactDiameter)
        }
        timerHost.leadingInset = { [weak state] in state?.timerLeadInset ?? 0 }
        timerHost.frame = NSRect(origin: .zero, size: satelliteRect.size)
        timerHost.autoresizingMask = [.width, .height]
        small.contentView = timerHost
        timerPanel = small
        if let screen = displayScreen() { state.updateNotchGeometry(for: screen) }
        updatePanelFrame(animated: false)
        // Initially nothing is drawn: the physical notch is already black.
        // updatePanelFrame() will show us on playback or a system event.
    }

    private func displayScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    // Keep the satellite at one stable x-coordinate, even when it expands.
    // Reserve space for the *expanded* timer width so hovering never pushes
    // the mini-island from underneath the cursor.
    private func timerSatelliteX(on screen: NSScreen) -> CGFloat {
        let centre = state.notchCenterX ?? screen.frame.midX
        let compactMediaRight = centre + state.notchWidth / 2 + state.compactWing
        // Give the satellite room of its own instead of placing it in the
        // notch or inside the primary panel's hover region.
        let preferredX = compactMediaRight + state.timerSatelliteGap
        let maxX = screen.frame.maxX - state.timerExpandedWidth - 10
        return max(screen.frame.minX + 10, min(preferredX, maxX))
    }

    private func updatePanelFrame(animated: Bool) {
        guard let screen = displayScreen() else { return }
        if let window = panel, state.isVisible {
            let size = state.panelSize
            let centre = state.notchCenterX ?? screen.frame.midX
            // The timer-only compact island is intentionally asymmetric:
            // no left wing and an 86pt countdown wing to the RIGHT of the
            // physical notch. Its visible centre is therefore shifted right.
            // An expanded timer must keep THAT centre, not recenter on the
            // notch (the latter made it jump left before opening and jump
            // right on collapse, as seen in the screen recordings).
            let baseLeft: CGFloat
            if state.usesFixedMediaSatelliteCanvas {
                // Same NSPanel frame before, during and after a media hover.
                // Its RIGHT edge remains at the compact media right edge;
                // IslandView top-trailing-aligns the changing black surface.
                // No AppKit relocation => no lost mouseEntered/mouseExited.
                baseLeft = CGFloat(TimerRoutingPolicy.fixedMediaCanvasLeft(
                    notchCenter: Double(centre), notchWidth: Double(state.notchWidth),
                    mediaWing: Double(state.compactWing), canvasWidth: Double(size.width)))
            } else if state.unlockTransitionActive || state.event != nil || state.eventHandoffCanvasActive ||
                        state.coverGlowCanvasInUse {
                baseLeft = centre - size.width / 2
            } else if state.event == nil && state.canvasExpanded &&
                      state.track == nil && state.timerPresented {
                baseLeft = CGFloat(TimerRoutingPolicy.expandedTimerLeft(
                    notchCenter: Double(centre),
                    notchWidth: Double(state.notchWidth),
                    leftWing: Double(state.leftWing),
                    rightWing: Double(state.rightWing),
                    expandedWidth: Double(size.width)))
            } else if state.event == nil && !state.canvasExpanded {
                baseLeft = centre - state.notchWidth / 2 - state.leftWing
            } else {
                baseLeft = centre - size.width / 2
            }
            // The fixed media canvas already ends BEFORE the timer satellite
            // in its compact position. Do not shift the AppKit NSPanel when
            // canvasExpanded toggles: that caused the recorded hover jitter.
            let leftEdge = baseLeft
            // The top of the NSPanel stays at the same screen coordinate
            // across ALL presentation modes. Only its invisible canvas grows.
            // This prevents a 5 pt vertical step at media/event boundaries.
            let roof = state.islandTopBleed
            window.permitsChargingTopBleed = true
            let frame = CGRect(x: leftEdge,
                               y: screen.frame.maxY - size.height + roof,
                               width: size.width, height: size.height)
            if window.frame != frame {
                let resized = window.frame.size != frame.size
                window.setFrame(frame, display: true)
                // 4.3.4: when the canvas changes size (e.g. the timer
                // satellite just left), let SwiftUI lay out in the SAME
                // pass — otherwise one frame shows the old alignment in the
                // new window and the island seems to jump.
                if resized { window.contentView?.layoutSubtreeIfNeeded() }
            }
            if !panelIsVisible {
                window.orderFrontRegardless()
                panelIsVisible = true
            }
        } else if let window = panel, panelIsVisible {
            window.orderOut(nil)
            panelIsVisible = false
        }
        // The Clock timer is independent: update it even when the music
        // panel is hidden or no track is playing.
        updateTimerPanelFrame(on: screen)
        updateShelfPanels(on: screen)
    }

    private func commitDesktopUnlockIsland() {
        guard !isScreenLocked, state.unlockTransitionActive else { return }
        // updatePanelFrame orders the usual media NSPanel while its lock
        // silhouette is already the initial fully expanded shape.
        updatePanelFrame(animated: false)
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        CATransaction.flush()
    }

    private var desktopUnlockIslandReady: Bool {
        guard !isScreenLocked, state.unlockTransitionActive,
              let panel, panelIsVisible, panel.isVisible,
              panel.alphaValue > 0.99 else { return false }
        return panel.frame.width >= state.notchWidth + 76 - 0.5
    }

    // Window handoff: move the Clock badge from the main notch's right wing
    // toward the satellite, or glide it back when music/event content leaves.
    // Only one window draws the timer when stationary. The short overlap is a
    // crossfade, not another persistent island or an independent timer.
    private func timerDepartureX(on screen: NSScreen, width: CGFloat) -> CGFloat {
        let center = state.notchCenterX ?? screen.frame.midX
        return center + state.notchWidth / 2 + 12 - width / 2
    }

    private func updateTimerPanelFrame(on screen: NSScreen) {
        guard let satellite = timerPanel else { return }
        let inset = state.timerLeadInset
        if !state.showsTimerSatellite {
            timerPinnedX = nil
            guard timerPanelIsVisible else {
                if state.timerSatelliteExiting && Date() >= timerWindowTransitionEnds {
                    state.finishTimerSatelliteExit()
                }
                return
            }
            timerPanelIsVisible = false
            let token = UUID()
            timerWindowTransitionToken = token
            timerWindowTransitionEnds = Date().addingTimeInterval(0.55)
            // A still-running timer whose main island became free retracts
            // INTO the main island; a finished/cancelled one shrinks away.
            let returnToNotch = state.timerPresented && state.track == nil && state.event == nil
            state.animateTimerSatelliteOut(home: returnToNotch) { [weak self, weak satellite] in
                guard let self, let satellite,
                      self.timerWindowTransitionToken == token,
                      !self.state.showsTimerSatellite else { return }
                satellite.orderOut(nil)
                self.timerWindowTransitionEnds = Date.distantPast
            }
            return
        }

        // The window never travels: it is placed at its final position and
        // only the black SwiftUI shape inside animates. Its right part is the
        // true timer canvas; `inset` points on the left are a transparent
        // lead-in reaching into the main island.
        timerPinnedX = nil
        let size = state.timerPanelSize
        let x = (timerPinnedX ?? timerSatelliteX(on: screen)) - inset
        // Window's top is above the physical display by timerTopBleed;
        // the SAME visible timer bottom is kept throughout hover morphs.
        let frame = CGRect(x: x,
                           y: screen.frame.maxY - size.height + state.timerTopBleed,
                           width: size.width + inset, height: size.height)
        if let content = satellite.contentView {
            let bounds = NSRect(origin: .zero, size: frame.size)
            if content.frame != bounds { content.frame = bounds }
            content.isHidden = false
        }
        if satellite.frame != frame { satellite.setFrame(frame, display: true) }
        if satellite.alphaValue != 1 { satellite.alphaValue = 1 }
        if !timerPanelIsVisible || !satellite.isVisible {
            let token = UUID()
            timerWindowTransitionToken = token
            timerWindowTransitionEnds = Date().addingTimeInterval(0.6)
            if !satellite.isVisible { satellite.orderFrontRegardless() }
            timerPanelIsVisible = true
            state.animateTimerSatelliteIn()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.timerWindowTransitionToken == token else { return }
                self.timerWindowTransitionEnds = Date.distantPast
            }
        }
    }

    private func scheduleNextMediaPoll() {
        mediaTimer?.invalidate()
        // Faster metadata response, without polling progress on the main UI.
        // Smooth progress runs on a local clock, independently of this timer.
        let interval: TimeInterval
        // 3.6.0: the lock-screen player needs fresh titles, but stays light.
        if isScreenLocked { interval = state.track?.isPlaying == true ? 2.5 : 6.0 }
        else if state.track?.isPlaying == true { interval = 1.05 }
        else if state.track != nil { interval = 2.2 }
        else { interval = 2.8 }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.pollMedia()
        }
        timer.tolerance = min(0.5, interval * 0.12)
        RunLoop.main.add(timer, forMode: .common)
        mediaTimer = timer
    }

    @objc private func foregroundApplicationChanged(_ notification: Notification) {
        refreshMediaFullscreenVisibility()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        // Entering/leaving a fullscreen Space animates for ~0.7 s; check
        // right away and again once the windows have settled.
        refreshMediaFullscreenVisibility()
        for delay in [0.15, 0.45, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshMediaFullscreenVisibility()
            }
        }
    }

    private func refreshMediaFullscreenVisibility() {
        guard !isScreenLocked,
              state.hideMediaDuringFullscreen || state.hideMediaWhenSourceInFront,
              let track = state.track,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundle = front.bundleIdentifier,
              let screen = displayScreen() else {
            state.updateFullscreenMediaSuppression(false)
            return
        }
        let source = track.source == .system ? track.sourceBundle : track.source.bundleIdentifier
        let fromSource = MediaVisibilityPolicy.frontIsSource(front: bundle, source: source)
        let candidate = fromSource || MediaVisibilityPolicy.isMediaApp(bundle)
        let wantsFullscreen = state.hideMediaDuringFullscreen && candidate
        let wantsTitle = state.hideMediaWhenSourceInFront && fromSource &&
            MediaVisibilityPolicy.browsers.contains(bundle)
        let hideInFullscreen = state.hideMediaDuringFullscreen
        let hideWhenSource = state.hideMediaWhenSourceInFront
        let decide: (String?, Bool) -> Bool = { title, fullscreen in
            MediaVisibilityPolicy.shouldHide(.init(
                frontBundle: bundle, sourceBundle: source, trackTitle: track.title,
                frontWindowTitle: title, frontIsFullscreen: fullscreen,
                hideInFullscreen: hideInFullscreen, hideWhenSourceInFront: hideWhenSource))
        }
        guard wantsFullscreen || wantsTitle else {
            state.updateFullscreenMediaSuppression(decide(nil, false))
            return
        }
        // 3.10.2: the window list and the Accessibility title are read on a
        // background queue — a busy browser can take up to 0.2 s to answer,
        // which froze the island twice a second while it was in front.
        guard !visibilityCheckBusy else { return }
        visibilityCheckBusy = true
        let pid = front.processIdentifier
        let screenFrame = screen.frame
        let primaryX = NSScreen.screens.first?.frame.minX ?? 0
        visibilityQueue.async { [weak self] in
            let fullscreen = wantsFullscreen && Self.hasFullscreenWindow(pid: pid, screenFrame: screenFrame, primaryX: primaryX)
            let title = wantsTitle ? Self.focusedWindowTitle(pid: pid) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.visibilityCheckBusy = false
                guard self.state.track?.title == track.title, !self.isScreenLocked else { return }
                self.state.updateFullscreenMediaSuppression(decide(title, fullscreen))
            }
        }
    }

    private let visibilityQueue = DispatchQueue(label: "app.notchisland.visibility", qos: .userInitiated)
    private var cinemaCheckBusy = false

    // 4.0.0: a video player or browser in full screen in front → cinema.
    private func refreshCinemaMode() {
        guard CinemaMode.isEnabled, !isScreenLocked,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundle = front.bundleIdentifier,
              MediaVisibilityPolicy.isMediaApp(bundle) || CinemaMode.videoApps.contains(bundle),
              let screen = displayScreen() else {
            if state.cinemaMode { state.setCinemaMode(false); updateIdleWings() }
            return
        }
        guard !cinemaCheckBusy else { return }
        cinemaCheckBusy = true
        let pid = front.processIdentifier
        let frame = screen.frame
        let primaryX = NSScreen.screens.first?.frame.minX ?? 0
        visibilityQueue.async { [weak self] in
            let fullscreen = Self.hasFullscreenWindow(pid: pid, screenFrame: frame, primaryX: primaryX)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cinemaCheckBusy = false
                if fullscreen != self.state.cinemaMode {
                    self.state.setCinemaMode(fullscreen)
                    self.updateIdleWings()
                    if let screen = self.displayScreen() { self.updateShelfPanels(on: screen) }
                }
            }
        }
    }
    private var visibilityCheckBusy = false

    // A window of this app covering the island's display. Quartz uses
    // top-left coordinates; compare sizes and the horizontal span only.
    private static func hasFullscreenWindow(pid: pid_t, screenFrame: CGRect, primaryX: CGFloat) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let screenLeft = Double(screenFrame.minX - primaryX)
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let frame = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (frame["X"] as? NSNumber)?.doubleValue,
                  let width = (frame["Width"] as? NSNumber)?.doubleValue,
                  let height = (frame["Height"] as? NSNumber)?.doubleValue else { return false }
            return abs(x - screenLeft) < 4 &&
                width >= Double(screenFrame.width) * 0.94 &&
                height >= Double(screenFrame.height) * 0.91
        }
    }

    // Title of the focused window = the current browser tab. Needs only the
    // Accessibility permission the app already has; never logged.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    private var pollAgainAfterBusy = false

    private func pollMedia() {
        guard !mediaBusy else { pollAgainAfterBusy = true; return }
        mediaBusy = true
        let apps = NSWorkspace.shared.runningApplications
        let hasSpotify = apps.contains { $0.bundleIdentifier == "com.spotify.client" }
        let hasMusic = apps.contains { $0.bundleIdentifier == "com.apple.Music" }
        media.poll(spotifyRunning: hasSpotify, musicRunning: hasMusic) { [weak self] track, artwork in
            guard let self = self else { return }
            self.mediaBusy = false
            PerformanceMonitor.measure("media apply") { self.state.receiveMedia(track, artwork: artwork) }
            // A live-stream change arrived during this read: read again now.
            if self.pollAgainAfterBusy {
                self.pollAgainAfterBusy = false
                DispatchQueue.main.async { [weak self] in self?.pollMedia() }
            }
            self.refreshMediaFullscreenVisibility()
            self.scheduleNextMediaPoll()
            self.favorites.refresh(track: self.state.track)
            if let track, let artwork { self.media.rememberArtwork(artwork, for: track) }
            // Opportunistic remote artwork lookup, with exact track matching.
            // UI ignores late responses belonging to the previous song.
            if let song = self.state.track, self.state.musicArtwork == nil {
                self.media.requestArtwork(for: song) { [weak self] identity, image in
                    guard let self, let image else { return }
                    // Store the cover even if the user has switched tracks:
                    // it will be ready instantly if the song returns later.
                    self.state.receiveArtwork(image, for: identity)
                }
            }
        }
    }

    private func send(_ command: PlaybackCommand) {
        guard let track = state.track else { return }
        if command == .next || command == .previous { state.protectDuringTrackChange() }
        media.send(command, to: track.source) { [weak self] in self?.pollMedia() }
    }

    private func seek(to position: Double) {
        guard let track = state.track else { return }
        media.seek(to: position, in: track.source) { [weak self] in self?.pollMedia() }
    }

    private func checkBattery() {
        guard let fresh = PowerReader.current() else {
            refreshBatteryMenuStatus()
            return
        }
        if state.power != fresh { state.power = fresh }
        EnergySaver.onBattery = !fresh.onACPower
        standby.update(locked: isScreenLocked, onPower: fresh.onACPower)
        let warningThreshold = lowBatteryWarnings.observe(percentage: fresh.percentage,
                                                          onACPower: fresh.onACPower)
        let supplyChanged = lastACPower.map { $0 != fresh.onACPower } ?? false
        lastACPower = fresh.onACPower

        // AC cancels queued *real* warnings, not the menu preview. A warning
        // is generated only by the tracker on battery, never by the 15s poll
        // merely noticing that the machine remains below a threshold.
        if fresh.onACPower { pendingLowBatteryWarning = nil }
        if let threshold = warningThreshold {
            enqueueLowBatteryWarning(threshold)
        }
        if supplyChanged && !isScreenLocked && !state.isSessionLocked {
            state.show(fresh.onACPower ? .charging : .unplugged)
        }
        drainLowBatteryQueue()
    }

    private func enqueueLowBatteryWarning(_ threshold: Int) {
        // A polling jump such as 21 -> 9 must produce 10% rather than
        // 20%; if another warning was waiting, replace it with the deeper
        // threshold. Never enqueue the same warning again while it is active.
        if let active = activeLowBatteryWarning,
           !active.preview && active.threshold <= threshold { return }
        pendingLowBatteryWarning = min(pendingLowBatteryWarning ?? threshold, threshold)
        refreshBatteryMenuStatus()
    }

    private func drainLowBatteryQueue() {
        guard !isScreenLocked && !state.isSessionLocked &&
              !unlockHandoffInProgress && !state.isBusyForLowBatteryWarning &&
              activeLowBatteryWarning == nil else {
            refreshBatteryMenuStatus()
            return
        }
        if let threshold = pendingLowBatteryWarning {
            // Revalidate after a lock, charging event or long-running music
            // expansion. A stale alert is never shown on external power.
            guard let current = state.power, !current.onACPower,
                  current.percentage <= threshold else {
                pendingLowBatteryWarning = nil
                drainLowBatteryQueue()
                return
            }
            pendingLowBatteryWarning = nil
            presentLowBattery(threshold: threshold,
                              percentage: current.percentage, preview: false)
        } else if let threshold = pendingLowBatteryPreview {
            pendingLowBatteryPreview = nil
            presentLowBattery(threshold: threshold,
                              percentage: threshold, preview: true)
        }
        refreshBatteryMenuStatus()
    }

    private func presentLowBattery(threshold: Int, percentage: Int, preview: Bool) {
        activeLowBatteryWarning = (threshold: threshold, preview: preview)
        state.setLowBatteryPresentation(threshold: threshold, percentage: percentage)
        state.show(.lowBattery)
    }

    private func refreshBatteryMenuStatus() {
        // The settings view must receive live status directly; no hidden
        // NSMenuItem may be required after simplifying the status-bar menu.
        guard let power = state.power else {
            updateBatteryStatus(summary: "Батарея: нет данных IOKit",
                                explanation: "Предупреждения: проверь доступность аккумулятора")
            return
        }
        let next = LowBatteryWarningTracker.nextThreshold(below: power.percentage)
        let nextText = next.map { "\($0)%" } ?? "нет (достигнут 1%)"
        let source = power.onACPower ? "внешнее питание" : "от батареи"
        let summary = "Батарея: \(power.percentage)% · \(source) · следующий порог: \(nextText)"
        let explanation: String
        if let pending = pendingLowBatteryWarning {
            let why: String
            if isScreenLocked || state.isSessionLocked { why = "экран заблокирован" }
            else if unlockHandoffInProgress { why = "идёт разблокировка" }
            else if state.isExpanded || state.canvasExpanded { why = "плеер раскрыт" }
            else { why = "островок занят анимацией" }
            explanation = "Ожидает \(pending)%: \(why)"
        } else if let active = activeLowBatteryWarning {
            explanation = active.preview
                ? "Тест \(active.threshold)%: показ 7 секунд"
                : "Порог \(active.threshold)%: предупреждение показано"
        } else if let preview = pendingLowBatteryPreview {
            explanation = "Тест \(preview)%: ожидает освобождения островка"
        } else if power.onACPower {
            explanation = "На зарядке: предупреждения о разряде отключены"
        } else {
            explanation = next == nil
                ? "Порог 1% уже достигнут; повторов нет до подзарядки"
                : "Ожидаю \(nextText); пройденные пороги не повторяются"
        }
        updateBatteryStatus(summary: summary, explanation: explanation)
    }

    private func updateBatteryStatus(summary: String, explanation: String) {
        settingsSnapshot.batterySummary = summary
        settingsSnapshot.batteryExplanation = explanation
    }

    private func startUnlockWatch() {
        unlockWatchTimer?.invalidate()
        observedLockedSessionBit = false
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.isScreenLocked else { return }
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
            // This legacy WindowServer key can be absent. NEVER mistake an
            // absent key on the first poll for an unlock: require a prior true.
            // Missing is UNKNOWN, not "unlocked": some macOS versions omit
            // this private field temporarily during a Spaces switch.
            guard let locked = session["CGSSessionScreenIsLocked"] as? Bool else { return }
            if locked {
                self.observedLockedSessionBit = true
            } else if self.observedLockedSessionBit {
                self.sessionUnlocked(Notification(name: NSWorkspace.sessionDidBecomeActiveNotification))
            }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        unlockWatchTimer = timer
    }

    private func stopUnlockWatch() {
        unlockWatchTimer?.invalidate()
        unlockWatchTimer = nil
        observedLockedSessionBit = false
    }

    @objc private func sessionLocked(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.sessionLocked(notification) }
            return
        }
        guard !isScreenLocked else { return }
        let explicitScreenLock = notification.name.rawValue == "com.apple.screenIsLocked"
        let screenLockFlag = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
        // NSWorkspace.sessionDidResignActive is also sent for application,
        // Spaces and WindowServer focus changes. In particular, a delayed
        // event may arrive MORE than five seconds after an actual unlock.
        // Never fabricate a new lock cycle from that event unless the session
        // explicitly reports being protected. The distributed lock event is
        // independently authoritative when that private key is unavailable.
        if !explicitScreenLock &&
           (screenLockFlag != true || Date().timeIntervalSince(lastCompletedUnlockAt) < 2.0) {
            LockScreenOverlay.logSessionEvent("ignored unconfirmed/recent session resign: bit=\(String(describing: screenLockFlag))")
            return
        }
        if explicitScreenLock && screenLockFlag == false {
            LockScreenOverlay.logSessionEvent("ignored stale distributed lock: session already unlocked")
            return
        }
        LockScreenOverlay.logSessionEvent("session locked: source=\(notification.name.rawValue), bit=\(String(describing: screenLockFlag))")
        isScreenLocked = true
        standby.update(locked: true, onPower: state.power?.onACPower ?? false)
        // 4.1.1: StandBy shows the temperature — have it ready.
        if StandBySettings.isEnabled { WeatherService.shared.refreshIfNeeded(allowPrompt: false) {} }
        unlockHandoffInProgress = false
        LockUserIdentity.shared.refresh(force: true)
        // If a 7-second warning was interrupted by the protected screen,
        // replay it once after unlock rather than losing a delivered threshold.
        if let active = activeLowBatteryWarning {
            if active.preview { pendingLowBatteryPreview = active.threshold }
            else { enqueueLowBatteryWarning(active.threshold) }
            activeLowBatteryWarning = nil
        }
        refreshBatteryMenuStatus()
        startUnlockWatch()
        startLockWidgets()
        // Present the protected SkyLight surface first. Retiring the desktop
        // panel in the same callback could produce one empty composition
        // frame while WindowServer moved into the secured Space.
        lockOverlay?.showLocked()
        let fadeToken = UUID()
        desktopLockFadeToken = fadeToken
        // Keep the existing media surface composed while the protected
        // SkyLight window expands from the notch. Fade its real NSPanel
        // instead of ordering it out abruptly in the next 75ms frame.
        if let desktop = panel, desktop.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.36
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                desktop.animator().alphaValue = 0
            } completionHandler: { [weak self, weak desktop] in
                guard let self, self.isScreenLocked,
                      self.desktopLockFadeToken == fadeToken else { return }
                self.state.prepareForScreenLock()
                // Reset only AFTER the panel has been ordered out, so the
                // later desktop-unlock handoff can display at full opacity.
                desktop?.alphaValue = 1
            }
        } else {
            state.prepareForScreenLock()
        }
    }

    @objc private func sessionUnlocked(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.sessionUnlocked(notification) }
            return
        }
        guard isScreenLocked else { return }
        let isExplicitUnlock = notification.name.rawValue == "com.apple.screenIsUnlocked"
        let screenLockFlag = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
        if !isExplicitUnlock && screenLockFlag != false {
            // Workspace activation can fire during a Space switch while
            // the private lock flag is temporarily unavailable. Require a
            // confirmed false, or the explicit macOS unlock notification.
            LockScreenOverlay.logSessionEvent("ignored unconfirmed session activation during lock")
            return
        }
        LockScreenOverlay.logSessionEvent("session unlocked: source=\(notification.name.rawValue), bit=\(String(describing: screenLockFlag))")
        lockStatusItem?.title = "Замочек: " + (lockOverlay?.diagnosticSummary ?? "Не проверено")
        isScreenLocked = false
        standby.update(locked: false, onPower: false)
        stopLockWidgets()
        desktopLockFadeToken = UUID()
        // An early unlock may interrupt a pending desktop fade. Keep the
        // next ordinary-media composition fully opaque behind SkyLight.
        panel?.alphaValue = 1
        lastCompletedUnlockAt = Date()
        unlockHandoffInProgress = true
        stopUnlockWatch()
        // The protected SkyLight window remains unchanged. After macOS
        // unlocks, the existing main island panel animates its OWN padlock
        // from closed to open before revealing music. There is never a second
        // desktop NSWindow for this real-session unlock.
        lockOverlay?.animateUnlock(beginMediaTransition: { [weak self] in
            guard let self, !self.isScreenLocked else { return }
            self.state.animateRealScreenUnlock { [weak self] in
                guard let self, !self.isScreenLocked else { return }
                self.unlockHandoffInProgress = false
                self.pollMedia()
                self.checkBattery()
                self.drainLowBatteryQueue()
            }
            // Let the existing NSHostingView finish composing its first
            // fully black frame before the protected SkyLight panel leaves.
            self.commitDesktopUnlockIsland()
            DispatchQueue.main.async { [weak self] in
                self?.commitDesktopUnlockIsland()
            }
        }, isDesktopReady: { [weak self] in
            guard let self else { return false }
            self.commitDesktopUnlockIsland()
            return self.desktopUnlockIslandReady
        }, completion: { [weak self] in
            // Phase timers run from the ACTUAL SkyLight retirement, not the
            // unlock notification. This keeps the open symbol visible even
            // if WindowServer needs several frames to swap Spaces.
            guard let self, !self.isScreenLocked else { return }
            self.state.playRealScreenUnlockPhases()
        })
    }

    @objc private func toggleHoverHaptics(_ item: NSMenuItem) {
        setHoverHapticsEnabled(item.state != .on)
    }

    private func setHoverHapticsEnabled(_ enabled: Bool) {
        state.setHoverHapticsEnabled(enabled)
        hapticsMenuItem?.state = enabled ? .on : .off
        settingsSnapshot.hoverHapticsEnabled = enabled
    }

    @objc private func toggleLockOverlay(_ item: NSMenuItem) {
        setLockOverlayEnabled(item.state != .on)
    }

    private func setLockOverlayEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "enableLockIslandV21")
        lockMenuItem?.state = enabled ? .on : .off
        settingsSnapshot.lockIslandEnabled = enabled
        lockOverlay?.setEnabled(enabled)
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        if let screen = displayScreen() { state.updateNotchGeometry(for: screen) }
        updatePanelFrame(animated: false)
        lockOverlay?.reposition(on: displayScreen())
    }
    @objc private func changeWidth(_ sender: NSMenuItem) {
        if let width = sender.representedObject as? Int { state.setNotchSize(CGFloat(width)) }
    }
    @objc private func useAutoWidth() {
        state.useAutomaticNotch()
        if let screen = displayScreen() { state.updateNotchGeometry(for: screen) }
    }
    @objc private func toggleAudioCapture(_ item: NSMenuItem) {
        setAudioCaptureEnabled(!state.audioCaptureEnabled)
    }

    private func setAudioCaptureEnabled(_ enabled: Bool) {
        guard state.audioCaptureEnabled != enabled else { return }
        state.audioCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "audioCaptureEnabled")
        audioCaptureMenuItem?.state = enabled ? .on : .off
        settingsSnapshot.audioCaptureEnabled = enabled
        if enabled { audio.start() } else {
            audio.stop()
            state.audioLevels = Array(repeating: 0, count: 6)
            state.audioStatus = "Выключена"
            audioStatusItem?.title = "Аудио: Выключена"
        }
    }
    @objc private func retryAudio() {
        guard state.audioCaptureEnabled else { return }
        audio.restart()
    }
    @objc private func reloadArtwork() {
        guard let song = state.track else { return }
        media.retryArtworkLookup(for: song)
        // Do not erase an already visible cover while a refresh is running.
        media.requestArtwork(for: song) { [weak self] identity, image in
            guard let self, let image else { return }
            self.state.receiveArtwork(image, for: identity)
        }
    }
    @objc private func receiveSpotifyURL(_ event: NSAppleEventDescriptor,
                                         withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        favorites.receiveSpotifyRedirect(url)
    }

    private func showYandexFavoriteSetup() {
        // A Yandex track has been detected, but the favorite status could not
        // be verified. We keep the star visible and explain how to activate it.
        let alert = NSAlert()
        alert.messageText = "Избранное Яндекс Музыки"
        alert.informativeText = "Звёздочка видна, но статус лайка пока не удалось проверить. OAuth не нужен: для отдельного приложения разрешите Notch Island Универсальный доступ, для браузера — управление вкладкой Яндекс Музыки через Apple Events. Если macOS не показывает состояние сердечка, приложение не нажмёт его вслепую."
        alert.addButton(withTitle: "Разрешить управление")
        alert.addButton(withTitle: "Закрыть")
        if alert.runModal() == .alertFirstButtonReturn {
            favorites.requestYandexAccessibility()
            favorites.invalidate()
            favorites.refresh(track: state.track)
        }
    }

    @objc private func enableYandexLocalFavorites() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Яндекс Музыка — избранное без OAuth"
        alert.informativeText = "В отдельном приложении Notch Island использует только Универсальный доступ macOS. В браузере управление идёт через открытую вкладку music.yandex.ru и Apple Events.\n\nПроверка: " + favorites.yandexLocalStatus(track: state.track) + "\n\nРазрешите управление, затем закройте и снова откройте Notch Island. Пароль и OAuth-токен вводить не нужно."
        alert.addButton(withTitle: "Запросить доступ")
        alert.addButton(withTitle: "Закрыть")
        if alert.runModal() == .alertFirstButtonReturn {
            favorites.requestYandexAccessibility()
            favorites.invalidate()
            favorites.refresh(track: state.track)
        }
    }

    @objc private func showYandexFavoritesHelp() {
        let alert = NSAlert()
        alert.messageText = "Избранное Яндекс Музыки"
        alert.informativeText = "OAuth-токен НЕ нужен для прямого управления кнопкой лайка.\n\n" +
            "Приложение Яндекс Музыка: разрешите Notch Island в Системные настройки → Конфиденциальность и безопасность → Универсальный доступ, затем перезапустите Notch Island.\n\n" +
            "Яндекс Музыка в браузере: включите Allow JavaScript from Apple Events (разрешить JavaScript из Apple Events) и разрешите Notch Island управление браузером.\n\n" +
            "Для предотвращения случайного удаления песни из избранного требуется доступ к текущему состоянию сердечка. Если приложение не публикует его, звезда останется приглушённой. Опциональная интеграция с аккаунтом доступна отдельно."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }

    @objc private func connectYandex() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Подключить Яндекс Музыку"
        alert.informativeText = "Для общего избранного в приложении и браузере нужен ваш OAuth-токен Яндекса с доступом к Музыке. Не вводите пароль. Токен хранится в Связке ключей и отправляется только Яндексу."
        alert.addButton(withTitle: "Подключить")
        alert.addButton(withTitle: "Отмена")
        let entry = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 370, height: 26))
        entry.placeholderString = "OAuth-токен (не пароль)"
        alert.accessoryView = entry
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = entry.stringValue
        entry.stringValue = ""
        favorites.connectYandex(token: value) { [weak self] success in
            let reply = NSAlert()
            reply.messageText = success ? "Яндекс Музыка подключена" : "Подключить не удалось"
            reply.informativeText = success ? "Теперь звёздочка использует избранное аккаунта для треков из Яндекс Музыки." : "Проверьте токен и доступ к Яндекс Музыке. Токен не сохранён."
            reply.runModal()
            self?.favorites.refresh(track: self?.state.track)
        }
    }

    @objc private func disconnectYandex() {
        favorites.disconnectYandex()
        favorites.refresh(track: state.track)
    }

    @objc private func connectSpotify() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Подключить избранное Spotify"
        alert.informativeText = "Нужен Client ID из Spotify Developer Dashboard. Добавь Redirect URI: notchisland://spotify-callback. Авторизация откроется в браузере. Для новых Dev Mode приложений Spotify может требовать Premium."
        alert.addButton(withTitle: "Подключить")
        alert.addButton(withTitle: "Отмена")
        let entry = NSTextField(string: favorites.spotifyClientID)
        entry.placeholderString = "Spotify Client ID"
        entry.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = entry
        if alert.runModal() == .alertFirstButtonReturn {
            favorites.beginSpotifyConnection(clientID: entry.stringValue)
        }
    }

    @objc private func disconnectSpotify() {
        favorites.disconnectSpotify()
        favorites.refresh(track: state.track)
    }

    @objc private func openLockLog() {
        let url = LockScreenOverlay.diagnosticURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "Пока нет журнала замочка"
            alert.informativeText = "Заблокируй и разблокируй Mac хотя бы один раз, затем снова открой журнал."
            alert.runModal()
        }
    }

    @objc private func demoUnlock() {
        guard !isScreenLocked else { return }
        state.prepareForScreenLock()
        lockOverlay?.showLocked(forcePreview: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            self?.lockOverlay?.animateUnlock(beginMediaTransition: { [weak self] in
                self?.state.finishScreenUnlock()
            }, completion: { [weak self] in
                self?.pollMedia()
            })
        }
    }
    @objc private func openClockTimers() {
        clockTimers.openClock()
    }
    @objc private func openAccessibilitySettings() {
        clockTimers.requestAccessibilityAccess()
    }
    @objc private func pauseCountdownAction() { state.toggleTimerPause() }
    @objc private func stopCountdownAction() { state.stopTimer() }
    @objc private func showConnectedAirPods() {
        if !airPodsMonitor.showConnectedPreview() {
            let alert = NSAlert()
            alert.messageText = "AirPods не подключены"
            alert.informativeText = "Подключи AirPods к этому Mac в настройках Bluetooth и повтори попытку. Заряд кейса появится только если macOS передаёт его значение."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    // This is an ordinary NSWindow, NOT an IslandPanel. Closing it hides the
    // preferences UI but does not interrupt the island or its SkyLight overlay.
    // 3.15.0: shared by the settings window and the onboarding tour.
    private func makeSettingsActions() -> NotchSettingsActions {
        return NotchSettingsActions(
            setHaptics: { [weak self] value in self?.setHoverHapticsEnabled(value) },
            setAudioCapture: { [weak self] value in self?.setAudioCaptureEnabled(value) },
            setSpectrumTuning: { [weak self] settings in self?.setSpectrumTuning(settings) },
            setLockIsland: { [weak self] value in self?.setLockOverlayEnabled(value) },
            setLaunchAtLogin: { [weak self] value in self?.updateLaunchAtLogin(value) },
            useAutomaticWidth: { [weak self] in self?.useAutoWidth() },
            setManualWidth: { [weak self] width in self?.state.setNotchSize(width) },
            previewLowBattery: { [weak self] threshold in
                guard let self, LowBatteryWarningTracker.thresholds.contains(threshold) else { return }
                self.pendingLowBatteryPreview = threshold
                self.drainLowBatteryQueue()
            },
            previewCharging: { [weak self] in self?.demoCharging() },
            previewAirPods: { [weak self] in self?.showConnectedAirPods() },
            setFocusIsland: { [weak self] value in self?.setFocusIslandEnabled(value) },
            previewFocus: { [weak self] in self?.previewFocusIsland() },
            openFullDiskAccess: { [weak self] in self?.openFullDiskAccessSettings() },
            installUpdate: { [weak self] in self?.installAvailableUpdate() },
            setMediaGestures: { [weak self] value in self?.setMediaGesturesEnabled(value) },
            fixAccessibility: { [weak self] in self?.requestAccessibilityFix() },
            fixFullDisk: { PermissionChecker.open(PermissionChecker.fullDiskPane) },
            fixDownloads: { [weak self] in
                // Listing Downloads makes macOS ask for access if needed.
                _ = PermissionChecker.canReadDownloads()
                PermissionChecker.open(PermissionChecker.filesPane)
                self?.refreshPermissions()
            },
            recheckPermissions: { [weak self] in self?.refreshPermissions() },
            relaunchApp: { AppUpdater.relaunch() },
            copyDiagnostics: { [weak self] in
                guard let self else { return }
                self.clipboardWatch.ignoreNextChange = true
                let saved = DiagnosticsReport.write(statusLines: self.diagnosticsStatusLines(),
                                                    copyToClipboard: true)
                self.settingsSnapshot.diagnosticsMessage = saved == nil
                    ? "Отчёт скопирован в буфер обмена (файл сохранить не удалось)."
                    : "Отчёт скопирован в буфер обмена и сохранён в ~/Library/Logs/NotchIsland-Diagnostics.txt."
            },
            setLab: { [weak self] raw, on in self?.setLabFeature(raw, on) },
            setSleepTimer: { [weak self] minutes in self?.setSleepTimer(minutes: minutes) },
            copyClipboardItem: { [weak self] text in self?.clipboardWatch.copyAgain(text) },
            clearClipboardHistory: { [weak self] in
                self?.clipboardWatch.clearHistory()
                self?.refreshLabSnapshot()
            },
            ejectVolume: { [weak self] path in
                _ = DiskWatch.eject(URL(fileURLWithPath: path))
                self?.refreshLabSnapshot()
            },
            runCleanup: { [weak self] in self?.runCleanup() },
            openDiagnostics: { [weak self] in
                guard let self else { return }
                if let url = DiagnosticsReport.write(statusLines: self.diagnosticsStatusLines(),
                                                     copyToClipboard: false) {
                    NSWorkspace.shared.open(url)
                }
            },
            checkForUpdates: { [weak self] in
                self?.updater.scan()
                self?.updater.checkGitHub(force: true)
            },
            openUpdateLog: {
                let file = AppUpdater.logURL
                if FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.open(file)
                } else {
                    NSWorkspace.shared.open(AppUpdater.downloadsFolder)
                }
            },
            previewLock: { [weak self] in self?.demoUnlock() },
            previewTimer: { [weak self] in self?.showTimerSatellitePreview() },
            retryAudio: { [weak self] in self?.retryAudio() },
            reloadArtwork: { [weak self] in self?.reloadArtwork() },
            openArtworkLog: {
                ArtworkDiagnostics.write("diagnostic log opened by user")
                let file = ArtworkDiagnostics.fileURL
                if FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.open(file)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Журнал обложек пока пуст"
                    alert.informativeText = "Включи воспроизведение и нажми «Повторить поиск для текущего трека», затем открой журнал снова."
                    alert.runModal()
                }
            },
            requestYandexArtworkAccess: {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                let options = [promptKey: true] as CFDictionary
                let trusted = AXIsProcessTrustedWithOptions(options)
                ArtworkDiagnostics.write("Yandex desktop AX: permission check from settings trusted=\(trusted); runningBundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
                let alert = NSAlert()
                alert.messageText = trusted ? "Универсальный доступ разрешён" : "Notch Island не получил доступ к Яндекс Музыке"
                alert.informativeText = trusted
                    ? "Разрешение подтверждено для этой запущенной копии Notch Island. Включи трек в настольной Яндекс Музыке и повтори поиск обложки. Если приложение не отдаёт адрес изображения, это будет отражено в журнале."
                    : "Открой Системные настройки → Конфиденциальность и безопасность → Универсальный доступ. Удали старый Notch Island из списка и заново добавь /Applications/Notch Island.app. Включи разрешение, затем полностью выйди из Notch Island и открой снова. После установки версии с временной подписью macOS может не признавать прежний доступ."
                alert.addButton(withTitle: "Открыть Универсальный доступ")
                alert.addButton(withTitle: "Позже")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            openLockLog: { [weak self] in self?.openLockLog() },
            openLoginItems: { [weak self] in self?.openLoginItemsSettings() },
            connectSpotify: { [weak self] in self?.connectSpotify() },
            setupYandexFavorites: { [weak self] in self?.enableYandexLocalFavorites() },
            openClock: { [weak self] in self?.openClockTimers() },
            openAccessibility: { [weak self] in self?.openAccessibilitySettings() },
            refreshClock: { [weak self] in
                self?.clockTimers.refreshNow(diagnostics: true)
            },
            forceQuit: { Darwin.exit(0) },
            openClockLog: {
                let file = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/NotchIsland-ClockTimer.log")
                if FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.open(file)
                }
            },
            previewLockWidgets: { [weak self] in
                guard let self else { return }
                self.refreshLockWidgets()
                self.lockOverlay?.previewWidgets(on: self.displayScreen())
            },
            resetLockWidgetsPosition: { [weak self] in
                guard let self else { return }
                self.lockOverlay?.resetWidgetsPosition(on: self.displayScreen())
            },
            previewLockMedia: { [weak self] in
                guard let self else { return }
                self.lockOverlay?.previewMedia(on: self.displayScreen())
            },
            applyUserProfile: { [weak self] id in self?.applyUserProfile(id) },
            currentProfileValues: { [weak self] in self?.currentProfileValues() ?? [:] },
            applyProfile: { [weak self] raw in
                guard let profile = IslandProfile(rawValue: raw) else { return }
                self?.applyProfile(profile)
            },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            previewEyeBreak: { [weak self] in self?.runEyeBreak() },
            previewStandBy: { [weak self] in
                guard let self else { return }
                self.lockOverlay?.previewStandBy(on: self.displayScreen())
            }
        )
    }

    // MARK: Onboarding (3.15.0)

    // 3.20.0: the tour opens inside the settings window, over its content.
    func showOnboarding() {
        settingsSnapshot.onboardingVisible = true
        openSettings()
    }

    @objc private func openSettings() {
        refreshLaunchAtLogin()
        syncSettingsToggles()
        refreshBatteryMenuStatus()
        settingsSnapshot.clockStatus = clockTimers.statusLine
        clockTimers.refreshNow()
        focusMonitor.refreshNow()
        updater.scan()
        refreshUpdateStatus()
        refreshPermissions()
        startPermissionsWatch()
        refreshLabSnapshot()
        if settingsWindow == nil {
            let actions = makeSettingsActions()
            let view = NotchSettingsWindowView(island: state, snapshot: settingsSnapshot, actions: actions)
            // 3.10.0: Liquid Glass window — transparent title bar, content
            // under it, the desktop blurred behind everything.
            let size = NotchSettingsWindowView.windowSize
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Настройки Notch Island"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            settingsWindow = window
            // 3.10.1: a closed settings window kept its whole SwiftUI view
            // alive and redrawing in the background. It is now released on
            // close and built again (in a moment) on the next open.
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                if let observer = self.settingsCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.settingsCloseObserver = nil
                }
                DispatchQueue.main.async {
                    window.contentView = nil
                    if self.settingsWindow === window { self.settingsWindow = nil }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func demoCharging() { checkBattery(); state.show(.charging) }
    @objc private func demoLowBatteryWarning(_ sender: NSMenuItem) {
        guard let threshold = sender.representedObject as? Int,
              LowBatteryWarningTracker.thresholds.contains(threshold) else { return }
        // Simulated readings never enter LowBatteryWarningTracker and cannot
        // consume a genuine threshold. A busy island or lock defers the test.
        pendingLowBatteryPreview = threshold
        drainLowBatteryQueue()
    }
    @objc private func expand() { state.event = nil; state.expandPlayer() }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}

enum PowerReader {
    static func current() -> PowerState? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let percent = description["Current Capacity"] as? Int else { continue }
            let onAC = (description["Power Source State"] as? String) == "AC Power"
            let charging = (description["Is Charging"] as? Bool) ?? false
            return PowerState(percentage: percent, isCharging: charging, onACPower: onAC)
        }
        return nil
    }
}

// Match the screenshot's cover-coordinated waveform without an artificial
// blur or bloom. Average 8x8 samples rather than using GPU filters every
// audio frame; this function runs only when the album image first changes.
private enum ArtworkColorSampler {
    static func tint(from image: NSImage) -> Color {
        guard let raw = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: raw),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            return Color(red: 0.71, green: 0.69, blue: 0.66)
        }
        var red = 0.0, green = 0.0, blue = 0.0, weightSum = 0.0
        for y in 0..<8 {
            for x in 0..<8 {
                let px = min(bitmap.pixelsWide - 1, (2*x + 1) * bitmap.pixelsWide / 16)
                let py = min(bitmap.pixelsHigh - 1, (2*y + 1) * bitmap.pixelsHigh / 16)
                guard let source = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                // Bright, saturated pixels help the hue remain perceptible
                // when the artwork is mostly black.
                let saturation = max(source.redComponent, source.greenComponent, source.blueComponent)
                               - min(source.redComponent, source.greenComponent, source.blueComponent)
                let weight = 0.6 + Double(saturation)
                red += Double(source.redComponent) * weight
                green += Double(source.greenComponent) * weight
                blue += Double(source.blueComponent) * weight
                weightSum += weight
            }
        }
        guard weightSum > 0 else { return Color(red: 0.71, green: 0.69, blue: 0.66) }
        // Warm the average with neutral light so the bars remain visible on
        // true-black macOS notch surfaces, while retaining the album hue.
        return Color(red: min(1, 0.33 + 0.67 * red / weightSum),
                     green: min(1, 0.33 + 0.67 * green / weightSum),
                     blue: min(1, 0.33 + 0.67 * blue / weightSum))
    }
}
