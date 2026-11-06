import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Collaboration
import OpenDirectory

// 4.8.0 — the island's black shape: straight along the top of the screen
// (hidden above the bezel by `roof`), rounded at the bottom and, when
// `flare` > 0, with concave curves where the sides meet the screen edge,
// like a drop of liquid hanging from it. Both values animate.
struct IslandSilhouette: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat
    var roof: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flare) }
        set { bottomRadius = newValue.first; flare = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let f = max(0, min(flare, w / 4, (h - roof) / 3))
        let r = max(0, min(bottomRadius, (w - 2 * f) / 2, (h - roof - f) / 2))
        let left = rect.minX + f, right = rect.maxX - f
        let top = rect.minY + roof
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: top))
        // concave curve from the screen edge into the right side
        p.addQuadCurve(to: CGPoint(x: right, y: top + f), control: CGPoint(x: right, y: top))
        p.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: right - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: left + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: left, y: top + f))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: top), control: CGPoint(x: left, y: top))
        p.closeSubpath()
        return p
    }
}

// 4.8.0: blur + scale + opacity for the cover change transition.
struct ArtworkSwap: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

// 4.5.0: squash-and-stretch of the opening drop.
struct IslandDropPhase {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

// A black surface grows from the real cutout. The NSWindow grows only once;
// the shape animates *within* that canvas instead of resizing a hosted view
// and an NSWindow continuously at the same time.
struct IslandView: View {
    @ObservedObject var state: IslandState

    // All foreground modes share a single black silhouette. Earlier builds
    // recreated the silhouette for every event, causing a black flash while
    // NSPanel changed its frame and SwiftUI mounted the next branch.
    private var expanded: Bool {
        state.isExpanded && state.event == nil && (state.track != nil || state.timerPresented)
    }

    private var surfaceWidth: CGFloat {
        if state.event != nil {
            let fromMedia = state.eventEnteringFromMedia || state.eventReturningToMedia
            let collapsedWidth = state.eventRestingWidth
                ?? (fromMedia ? state.compactWidth : state.notchWidth)
            return state.eventRevealed ? state.eventWidth : collapsedWidth
        }
        if expanded { return state.expandedWidth }
        if state.unlockTransitionActive { return state.unlockSurfaceWidth }
        return state.compactRevealed ? state.compactWidth : state.notchWidth
    }

    // 4.12.0: the smallest squash that still covers the physical notch
    // (with a point to spare on each side).
    private func minNotchScaleX(_ width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        return min(1, (state.notchWidth + 2) / width)
    }

    private func minNotchScaleY(_ height: CGFloat, roof: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        return min(1, (state.notchHeight + roof + 1) / height)
    }

    private var surfaceHeight: CGFloat {
        state.event == nil
            ? (expanded ? state.expandedHeight : state.compactDisplayHeight)
            : state.eventHeight
    }

    var body: some View {
        let _ = PerformanceMonitor.count("island redraw")
        let roof = state.islandTopBleed
        let width = surfaceWidth
        let height = surfaceHeight + roof
        let isCharging = state.event == .charging || state.event == .lowBattery
        let unlockCorner: CGFloat = state.unlockTransitionActive
            ? 13 + 4 * state.unlockSurfaceProgress : 13
        // 4.8.0: like a drop hanging from the screen edge — when open, the
        // top corners flow into the bezel with soft concave curves instead
        // of meeting it at a sharp angle.
        // 4.8.1: closed islands and banners have the curves too (7 pt,
        // drawn just outside the body; the window reserves that room).
        let flare: CGFloat = expanded ? 13 : state.edgeFlare
        let shapeWidth = expanded ? width : width + flare * 2
        let shape = IslandSilhouette(bottomRadius: expanded ? 26 : unlockCorner,
                                     flare: flare,
                                     roof: roof)

        ZStack(alignment: .top) {
            // The only background is shared by media, charging, AirPods and
            // expanded player. Its upper edge is always above the screen.
            if isCharging {
                ChargingThreeSidedGlow(tint: ChargingPalette.color(for: state.powerTintPercentage),
                                       flare: flare, roof: roof)
                    .frame(width: shapeWidth, height: height)
                    // No glow against the screen's TOP edge. Side glow
                    // eases in below the bezel; the bottom rim stays bright.
                    .mask(ChargingUpperGlowFade(roof: roof, height: height, reachTopEdge: true))
                    .opacity(state.eventRevealed ? 1 : 0)
            }

            // Cover-colour glow on a track change (3.2.0, optional).
            // 3.8.21: 0.1 pt higher, and at full strength right up to the
            // top edge of the screen (no fade just below the bezel).
            if state.event == nil && state.track != nil && !expanded &&
                state.coverGlowOpacity > 0.001 && state.coverGlowCanvasInUse {
                ChargingThreeSidedGlow(tint: state.musicArtworkTint, flare: flare, roof: roof)
                    .frame(width: shapeWidth, height: height)
                    .offset(y: -0.1)
                    .mask(ChargingUpperGlowFade(roof: roof, height: height, reachTopEdge: true, toScreenEdge: true))
                    .opacity(state.coverGlowOpacity)
            }

            shape.fill(Color.black)
                .frame(width: shapeWidth, height: height)
                .overlay {
                    if state.event == nil && state.track != nil && !expanded &&
                        state.coverGlowOpacity > 0.001 && state.coverGlowCanvasInUse {
                        ChargingThreeSidedContour(flare: flare, roof: roof)
                            .stroke(state.musicArtworkTint.opacity(0.8),
                                    style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
                            .offset(y: -0.1)
                            .mask(ChargingUpperGlowFade(roof: roof, height: height, reachTopEdge: true, toScreenEdge: true))
                            .opacity(state.coverGlowOpacity)
                    }
                    if isCharging {
                        ChargingThreeSidedContour(flare: flare, roof: roof)
                            .stroke(ChargingPalette.color(for: state.powerTintPercentage).opacity(0.82),
                                    style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
                            .mask(ChargingUpperGlowFade(roof: roof, height: height, reachTopEdge: true))
                            .opacity(state.eventRevealed ? 1 : 0)
                    }
                }
                // Reserve the left/right asymmetry only for timer-only media.
                .offset(x: state.event == nil && !expanded && !state.compactRevealed
                        && !state.unlockTransitionActive
                        ? (state.leftWing - state.rightWing) / 2 : 0)

            // Keep the compact player mounted while charging comes in or
            // leaves. Both sets of controls crossfade inside the SAME island.
            if state.track != nil || state.timerPresented {
                let showCompact: Bool = state.event == nil
                    ? (!expanded && state.compactRevealed)
                    : ((state.eventEnteringFromMedia || state.eventReturningToMedia)
                       && !state.eventRevealed)
                compactContent()
                    .padding(.top, roof)
                    .opacity((showCompact ? 1.0 : 0.0) *
                             (state.unlockTransitionActive ? state.unlockMediaOpacity : 1.0))
                    // 4.8.0: contents arrive and leave like on iPhone — from
                    // and into a soft blur, slightly smaller.
                    .blur(radius: showCompact ? 0 : 6)
                    .scaleEffect(x: state.compactRevealed ? 1 : 0.86, y: showCompact ? 1 : 0.86)
                    .allowsHitTesting(state.event == nil && !expanded)
            }

            // During a REAL unlock the only desktop padlock is a glyph drawn
            // INSIDE the normal media NSPanel, directly on its shared black
            // shape. The secure SkyLight NSPanel has already been retired and
            // there is no extra desktop window to blink or replay an entrance.
            if state.unlockTransitionActive {
                HStack(spacing: 0) {
                    ZStack {
                        Image(systemName: "lock.fill")
                            .opacity(state.unlockSymbolOpen ? 0 : 1)
                        Image(systemName: "lock.open.fill")
                            .opacity(state.unlockSymbolOpen ? 1 : 0)
                    }
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(width: 38, height: state.notchHeight)
                    .offset(x: 2)
                    .opacity(state.unlockSymbolOpacity)
                    Spacer(minLength: 0)
                }
                .frame(width: width, height: state.notchHeight)
                .padding(.top, roof)
                .animation(.easeInOut(duration: 0.26), value: state.unlockSymbolOpen)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if let event = state.event {
                eventContent(event)
                    .frame(width: state.eventWidth, height: state.eventHeight)
                    .padding(.top, roof)
                    .opacity(state.eventContentVisible ? 1 : 0)
                    .blur(radius: state.eventContentVisible ? 0 : 8)
                    .scaleEffect(state.eventContentVisible ? 1 : 0.8)
                    .allowsHitTesting(state.eventRevealed && state.eventContentVisible)
                    .mask(alignment: .top) {
                        shape.frame(width: shapeWidth, height: height)
                    }
            }

            // The expanded card stays mounted until the spring finishes its
            // collapse. The compact controls crossfade as the card contracts.
            if state.canvasExpanded && state.event == nil {
                Group {
                    // 4.0.0: the new player or the classic one (Settings).
                    if state.track != nil { ExpandedPlayerStyle.isNew ? AnyView(newExpandedContent) : AnyView(expandedContent) }
                    else { expandedTimerContent }
                }
                .padding(.top, state.notchHeight + 9 + roof)
                // 4.8.0: a smaller card — the contents are drawn at 92 %.
                .scaleEffect(0.92 * IslandLook.expandedScale, anchor: .top)
                .opacity(expanded ? 1 : 0)
                .blur(radius: expanded ? 0 : 10)
                .scaleEffect(expanded ? 1 : 0.88, anchor: .top)
                .allowsHitTesting(expanded)
            }
        }
        .animation(state.isExpanded ? IslandMotion.morph : IslandMotion.morphCollapse, value: state.isExpanded)
        .animation(state.compactRevealed ? IslandMotion.morph : IslandMotion.morphCollapse, value: state.compactRevealed)
        .animation(IslandMotion.content, value: state.eventReturningToMedia)
        // 4.14.0: under the pointer the closed island grows a little (when it
        // opens only on a click).
        .scaleEffect(state.hoverPeek && !expanded ? 1.045 : 1, anchor: .top)
        // 4.12.3: no squash keyframes any more (the «spring» on every change
        // of shape and the drop on opening) — they pulled the island inside
        // the camera cutout.
        // 4.12.2: a still black cover over the camera cutout itself, OUTSIDE
        // the squash above (in 4.12.1 it was squashed together with the
        // island, so the notch still peeked out). The island's springs can
        // briefly make it narrower or shorter than the notch; this keeps the
        // real notch hidden whatever the animation does.
        .background(alignment: .top) {
            if state.isVisible {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(Color.black)
                    .frame(width: state.notchWidth + 2, height: state.notchHeight + roof + 1)
                    .allowsHitTesting(false)
            }
        }
        // The AppKit window reserves the maximum transparent canvas. Limit
        // hover to the *visible* black silhouette, otherwise the pointer can
        // enter invisible padding and later never trigger another hover when
        // it reaches the actual compact media island.
        .frame(width: width, height: height, alignment: .top)
        .contentShape(Rectangle())
        // 4.14.5: while closed, the pointer is reported by CursorBehindIsland.
        .onHover { over in if state.isExpanded || state.canvasExpanded { state.hoverChanged(over) } }
        // 4.14.2: a click anywhere on the closed island opens it (the middle,
        // over the camera, used to let the click through).
        .onTapGesture {
            if !state.isExpanded && state.event == nil { state.expandPlayer() }
        }
        // File shelf (lab): files dropped on the island go to the shelf.
        .onDrop(of: [UTType.fileURL],
                isTargeted: Binding(get: { state.shelfModel?.dropTargeted ?? false },
                                    set: { targeted in
                                        if LabFeature.shelf.isOn { state.shelfModel?.dropTargeted = targeted }
                                    })) { providers in
            guard LabFeature.shelf.isOn, let shelf = state.shelfModel else { return false }
            return shelf.accept(providers)
        }
        // With a separate Clock timer, reserve a fixed invisible media canvas
        // but keep the visible island's RIGHT edge attached to the physical
        // notch. SwiftUI animates the black shape leftward *inside* that
        // canvas; the underlying NSPanel never jumps between two centres.
        // 4.8.1: room for the right-hand curve inside the fixed canvas.
        .padding(.trailing, state.usesFixedMediaSatelliteCanvas ? state.edgeFlare : 0)
        .frame(width: state.panelSize.width, height: state.panelSize.height,
               alignment: state.usesFixedMediaSatelliteCanvas ? .topTrailing : .top)
    }

    private func compactContent() -> some View {
        HStack(spacing: 0) {
            if let song = state.track {
                // 4.8.4: size chosen in Settings (75–125 %).
                albumArt(song, size: 22 * IslandLook.compactArtworkScale)
                    .offset(x: state.swipeNudge * 0.5)
                    .frame(width: state.leftWing, height: state.compactDisplayHeight)
            }
            // The physical camera notch is left unobstructed in the middle.
            Color.clear.frame(width: state.notchWidth)
            if state.track != nil {
                ZStack {
                    AudioReactiveBars(playing: state.track?.isPlaying == true,
                                      live: state.audioLive,
                                      maxHeight: 16, barWidth: 2.2,
                                      barSpacing: 1.7, tint: state.musicArtworkTint,
                                      artwork: state.musicArtwork,
                                      active: state.isVisible && !state.mediaHidden && state.event == nil
                                          && !state.isExpanded && state.compactRevealed)
                        .offset(x: -3)
                        .opacity(state.volumeLevel == nil ? 1 : 0)
                    if let level = state.volumeLevel {
                        VolumeLevelGlyph(level: level, compact: true)
                            .transition(.opacity)
                    }
                }
                .frame(width: state.rightWing, height: state.compactDisplayHeight)
            } else if state.timerPresented {
                CompactTimer(state: state)
                    .frame(width: state.rightWing, height: state.compactDisplayHeight)
            }
        }
        .frame(width: state.compactWidth, height: state.compactDisplayHeight)
        .onTapGesture { state.expandPlayer() }
        .accessibilityLabel(state.track != nil ? "Открыть медиаплеер" : "Открыть таймер")
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                if let song = state.track {
                    albumArt(song, size: 55)
                        .frame(width: 55, height: 55)
                        .offset(x: state.swipeNudge)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.track?.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(state.track?.artist ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Six round bars as in the iPhone reference. The actual audio
                // bands determine the height; the color comes from the cover.
                ZStack {
                    AudioReactiveBars(playing: state.track?.isPlaying == true,
                                      live: state.audioLive,
                                      maxHeight: 32, barWidth: 2.9,
                                      barSpacing: 2.3, tint: state.musicArtworkTint,
                                      artwork: state.musicArtwork)
                        .opacity(state.volumeLevel == nil ? 1 : 0)
                        .accessibilityLabel("Спектрограмма системного звука")
                    if let level = state.volumeLevel {
                        VolumeLevelGlyph(level: level, compact: false)
                            .transition(.opacity)
                    }
                }
                .frame(width: 55, height: 55)
            }
            .frame(maxWidth: .infinity)

            if (state.track?.duration ?? 0) > 0 {
                SmoothProgressView(state: state)
            }

            // iPhone-style bottom row: optional REAL favorite on the left,
            // three large media buttons in the middle, a balanced right edge.
            HStack(spacing: 0) {
                Group {
                    if state.favoriteSupported {
                        AnimatedFavoriteStar(state: state)
                    } else {
                        Color.clear.frame(width: 30, height: 43)
                    }
                }
                Spacer(minLength: 9)
                HStack(spacing: 22) {
                    Button { state.command(.previous) } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 22, weight: .medium))
                            .symbolEffect(.bounce, value: state.previousPulse)
                            .frame(width: 40, height: 43)
                    }
                    Button { state.command(.toggle) } label: {
                        Image(systemName: state.track?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 42, height: 43)
                    }
                    Button { state.command(.next) } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 22, weight: .medium))
                            .symbolEffect(.bounce, value: state.nextPulse)
                            .frame(width: 40, height: 43)
                    }
                }
                .buttonStyle(DynamicIslandButtonStyle())
                Spacer(minLength: 9)
                // 4.8.2: «where the sound goes», as in the new player.
                // 4.8.3: larger in the classic player.
                OutputDeviceButton(size: 20)
                    .frame(width: 30, height: 43)
            }
            .frame(maxWidth: .infinity)

        }
        .padding(.horizontal, 25)
        .frame(width: state.expandedWidth)
    }

    // MARK: 4.0.0 — the new expanded player

    // Big cover, the cover's colours glowing behind, title over artist with
    // the source app, progress, controls with «where the sound goes», and a
    // volume slider.
    private var newExpandedContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 14) {
                if let song = state.track {
                    albumArt(song, size: 78)
                        .frame(width: 78, height: 78)
                        .shadow(color: state.musicArtworkTint.opacity(0.55), radius: 14, y: 4)
                        .offset(x: state.swipeNudge)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let source = state.track?.sourceName, !source.isEmpty {
                        Text(source.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(state.track?.title ?? "")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(state.track?.artist ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    AudioReactiveBars(playing: state.track?.isPlaying == true,
                                      live: state.audioLive,
                                      maxHeight: 28, barWidth: 3.0,
                                      barSpacing: 2.3, tint: state.musicArtworkTint,
                                      artwork: state.musicArtwork)
                        .opacity(state.volumeLevel == nil ? 1 : 0)
                    if let level = state.volumeLevel {
                        VolumeLevelGlyph(level: level, compact: false)
                            .transition(.opacity)
                    }
                }
                .frame(width: 46, height: 46)
            }

            if (state.track?.duration ?? 0) > 0 {
                SmoothProgressView(state: state)
            }

            HStack(spacing: 0) {
                Group {
                    if state.favoriteSupported {
                        AnimatedFavoriteStar(state: state)
                    } else {
                        Color.clear.frame(width: 30, height: 40)
                    }
                }
                Spacer(minLength: 9)
                HStack(spacing: 24) {
                    Button { state.command(.previous) } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 21, weight: .medium))
                            .symbolEffect(.bounce, value: state.previousPulse)
                            .frame(width: 40, height: 40)
                    }
                    Button { state.command(.toggle) } label: {
                        Image(systemName: state.track?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 40)
                    }
                    Button { state.command(.next) } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 21, weight: .medium))
                            .symbolEffect(.bounce, value: state.nextPulse)
                            .frame(width: 40, height: 40)
                    }
                }
                .buttonStyle(DynamicIslandButtonStyle())
                Spacer(minLength: 9)
                OutputDeviceButton()
                    .frame(width: 30, height: 40)
            }
            .frame(maxWidth: .infinity)

            PlayerVolumeRow(tint: state.musicArtworkTint, externalLevel: state.volumeLevel)
        }
        .padding(.horizontal, 25)
        .frame(width: state.expandedWidth)
        .background(alignment: .top) {
            // The cover's colours glowing softly behind the controls.
            if let cover = ArtworkBlur.blurred(state.musicArtwork) {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: state.expandedWidth - 16, height: 190)
                    .blur(radius: 24)
                    .opacity(0.32)
                    .mask(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .offset(y: -18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var expandedTimerContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 24, weight: .medium))
                Text("Таймер")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                TimerReadout(state: state, fontSize: 24)
            }
            .foregroundStyle(.white)
            TimerInlineControls(state: state)
        }
        .padding(.horizontal, 25)
        .frame(width: state.expandedWidth)
    }

    // Art is always the *song* artwork. Never impersonate album artwork with
    // the Apple Music/Spotify/Safari application icon.
    @ViewBuilder
    private func albumArt(_ song: PlayingTrack, size: CGFloat) -> some View {
        // 4.8.0: a new cover arrives with a soft «focus pull» — from a blur
        // and slightly larger — while the old one fades out underneath.
        ZStack {
            if let image = state.musicArtwork {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .id(ObjectIdentifier(image))
                    .transition(.asymmetric(
                        insertion: .modifier(active: ArtworkSwap(blur: 8, scale: 1.16, opacity: 0),
                                             identity: ArtworkSwap(blur: 0, scale: 1, opacity: 1)),
                        removal: .modifier(active: ArtworkSwap(blur: 4, scale: 0.92, opacity: 0),
                                           identity: ArtworkSwap(blur: 0, scale: 1, opacity: 1))))
            } else {
                placeholderArtwork(size: size)
                    .transition(.opacity)
            }
        }
        .animation(IslandMotion.surface,
                   value: state.musicArtwork.map(ObjectIdentifier.init))
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size < 35 ? 6 : 10, style: .continuous))
        .accessibilityLabel("Обложка трека: \(song.title)")
    }

    private func placeholderArtwork(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(white: 0.13))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func eventContent(_ event: IslandEvent) -> some View {
        if event == .airPods {
            HStack(spacing: 0) {
                AirPodsCompactLeadingGlyph(
                    headphones: state.airPods?.name.lowercased().contains("max") == true)
                    .frame(width: state.airPodsLeftWing, height: state.eventHeight)
                Color.clear.frame(width: state.notchWidth, height: state.eventHeight)
                AirPodsChargeRing(percent: state.airPodsPrimaryBattery)
                    .frame(width: state.airPodsRightWing, height: state.eventHeight)
                    .offset(x: -2)
            }
            .frame(width: state.airPodsWidth, height: state.eventHeight)
        } else if event == .notice {
            NoticeEventContent(notice: state.notice,
                               wing: state.noticeWing,
                               notchWidth: state.notchWidth,
                               height: state.eventHeight)
                .frame(width: state.noticeWidth, height: state.eventHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let tap = state.notice?.tap, tap != .none { state.noticeTapHandler?(tap) }
                }
        } else if event == .update {
            UpdateEventContent(version: state.updateVersion ?? "",
                               wing: state.updateWing,
                               notchWidth: state.notchWidth,
                               height: state.eventHeight)
                .frame(width: state.updateWidth, height: state.eventHeight)
                .contentShape(Rectangle())
                .onTapGesture { state.requestUpdate?() }
        } else if event == .focus {
            FocusEventContent(presentation: state.focusPresentation,
                              bounceTrigger: state.eventRevealed ? state.focusPulse : -1,
                              wing: state.focusWing,
                              notchWidth: state.notchWidth,
                              height: state.eventHeight)
                .frame(width: state.focusWidth, height: state.eventHeight)
        } else {
            // Low battery uses the very same battery-island silhouette,
            // three-sided halo and percentage icon as the charging event.
            // Text accurately indicates a warning rather than AC charging.
            let batteryWarning = event == .lowBattery
            let chargingStyle = event == .charging || batteryWarning
            HStack(spacing: 0) {
                HStack(spacing: chargingStyle ? 1 : 1) {
                    if event != .charging {
                        Image(systemName: batteryWarning ? "exclamationmark.triangle.fill" : "bolt.slash.fill")
                            .font(.system(size: batteryWarning ? 8.6 : 9, weight: .semibold))
                            .foregroundStyle(batteryWarning
                                             ? ChargingPalette.color(for: state.powerTintPercentage)
                                             : Color.white)
                    }
                    Text(batteryWarning ? "Низкий заряд" : (event == .charging ? "Зарядка" : "От батареи"))
                        .font(.system(size: batteryWarning ? 9.6 : (event == .charging ? 11.0 : 10),
                                      weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Move the warning copy inwards without overlapping the
                // physical camera cutout. Padding is absorbed by the wing.
                .padding(.leading, batteryWarning ? 4 : 0)
                .frame(width: state.powerEventWing, height: state.eventHeight, alignment: .center)
                .offset(y: chargingStyle ? -state.chargingBridgeDepth / 2 : 0)

                Color.clear.frame(width: state.notchWidth, height: state.eventHeight)

                HStack(spacing: chargingStyle ? 0 : 2) {
                    Text(state.powerDisplayPercentage.map { "\($0)%" } ?? "—")
                        .font(.system(size: chargingStyle ? 11.0 : 10.5,
                                      weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    BatteryLevelIcon(percent: state.powerDisplayPercentage,
                                     tint: chargingStyle
                                         ? ChargingPalette.color(for: state.powerTintPercentage)
                                         : .white)
                        .scaleEffect(chargingStyle ? 0.78 : 1)
                        .frame(width: chargingStyle ? 16 : 20, height: 12)
                }
                .padding(.trailing, batteryWarning ? 4 : 0)
                .frame(width: state.powerEventWing, height: state.eventHeight, alignment: .center)
                .offset(y: chargingStyle ? -state.chargingBridgeDepth / 2 : 0)
            }
            .frame(width: state.eventWidth, height: state.eventHeight, alignment: .center)
        }
    }

}


// An open-bottom contour for charging. Deliberately NO horizontal top stroke.
// Separate glow and crisp strokes use the same open path; nothing is drawn
// along the MacBook's upper bezel.
private struct ChargingThreeSidedContour: Shape {
    // 4.8.5: follows the island's drop curves at the screen edge, so the
    // neon never stands outside the black shape.
    var flare: CGFloat = 0
    var roof: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Near the real outer edge, not several points inside the island.
        let inset: CGFloat = 0.75
        let f = max(0, flare)
        let left = rect.minX + f + inset
        let right = rect.maxX - f - inset
        let bottom = rect.maxY - inset
        let radius: CGFloat = min(13, max(0, (bottom - roof - f) / 2))
        var path = Path()
        if f > 0 {
            // From the screen edge, along the concave curve, then down.
            path.move(to: CGPoint(x: rect.minX, y: -3))
            path.addLine(to: CGPoint(x: rect.minX, y: roof))
            path.addQuadCurve(to: CGPoint(x: left, y: roof + f), control: CGPoint(x: left, y: roof))
        } else {
            // Extend the side strokes right up to (and slightly beyond) the top
            // of the display. No stroke is drawn across the top bezel.
            path.move(to: CGPoint(x: left, y: -3))
        }
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom),
                          control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius),
                          control: CGPoint(x: right, y: bottom))
        if f > 0 {
            path.addLine(to: CGPoint(x: right, y: roof + f))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: roof), control: CGPoint(x: right, y: roof))
            path.addLine(to: CGPoint(x: rect.maxX, y: -3))
        } else {
            path.addLine(to: CGPoint(x: right, y: -3))
        }
        return path
    }
}

enum ChargingPalette {
    static func color(for percentage: Int?) -> Color {
        let healthy = BannerTheme.tint(Color(red: 0.24, green: 0.89, blue: 0.52))
        guard let percentage else { return healthy }
        // Warnings keep their meaning in every theme.
        if percentage < 20 { return Color(red: 1.0, green: 0.25, blue: 0.25) }
        if percentage < 50 { return Color(red: 1.0, green: 0.63, blue: 0.16) }
        return healthy
    }
}

// 4.5.0 — banners in the colours of the Settings theme (switchable).
// Only «neutral» colours change: grey «off/skipped» and warning colours
// (low battery) keep their meaning. The system theme has no palette, so
// the original colours stay.
enum BannerTheme {
    static let key = "bannerThemeColorsV450"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }

    static var accent: Color? {
        guard isEnabled else { return nil }
        return SettingsTheme.current.palette.first
    }

    static func tint(_ original: Color) -> Color {
        guard let accent else { return original }
        return accent
    }

    // For notices: grey (off, skipped, nothing to do) stays grey.
    static func noticeTint(_ original: Color?) -> Color {
        guard let original else { return .white }
        if original == .gray || original == .white { return original }
        return tint(original)
    }
}

// A genuine battery-level pictogram instead of the always-full SF Symbol.
// The interior fill follows the actual reported charge from 0 to 100%.
private struct BatteryLevelIcon: View {
    let percent: Int?
    let tint: Color

    private var fillFraction: CGFloat {
        guard let percent else { return 0 }
        return CGFloat(max(0, min(percent, 100))) / 100
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                    .stroke(tint.opacity(0.95), lineWidth: 1.1)
                    .frame(width: 17, height: 10)
                RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                    .fill(tint)
                    .frame(width: 13 * fillFraction, height: 6)
                    .padding(.leading, 2)
            }
            .frame(width: 17, height: 10)
            RoundedRectangle(cornerRadius: 0.7)
                .fill(tint)
                .frame(width: 2, height: 4)
        }
        .frame(width: 20, height: 12)
        .accessibilityLabel(percent.map { "Заряд аккумулятора \($0) процентов" }
                            ?? "Заряд аккумулятора неизвестен")
    }
}

// Suppress the unwanted colored glint at the very TOP of the display,
// without cutting the black roof that hides the menu-bar seam.
// The colored side rim gradually fades in BELOW the visible top edge.
private struct ChargingUpperGlowFade: View {
    let roof: CGFloat
    let height: CGFloat
    let reachTopEdge: Bool
    // Music glow: fully visible from the screen's top edge downwards; the
    // fade happens entirely in the off-screen roof.
    var toScreenEdge = false

    var body: some View {
        let normalizedHeight = max(height, 1)
        let fadeBegins = toScreenEdge
            ? max(0, roof - 3.0) / normalizedHeight
            : min(1, max(0, roof + (reachTopEdge ? -3.5 : 6)) / normalizedHeight)
        let fadeEnds = toScreenEdge
            ? max(0, roof - 0.6) / normalizedHeight
            : min(1, (roof + (reachTopEdge ? 1.5 : 17)) / normalizedHeight)
        // The warning's VERTICAL side rim now reaches the visible top edge.
        // The contour remains an OPEN path, so it never draws a colored
        // horizontal stroke over the top bezel. Keep normal charging as-is.
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: fadeBegins),
                .init(color: .white, location: fadeEnds),
                .init(color: .white, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct ChargingThreeSidedGlow: View {
    let tint: Color
    var flare: CGFloat = 0
    var roof: CGFloat = 0

    var body: some View {
        ChargingThreeSidedContour(flare: flare, roof: roof)
            .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 4.3, lineCap: .round))
            .blur(radius: 3.4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A distinct tactile response for adding and removing favorites.
// The target app is still authoritative: IslandState rolls the icon back if
// the remote change fails, so the visual effect is not treated as success.
// Put animation state in a reference model so delayed animation closures
// never need to mutate a SwiftUI View value captured as immutable self.
private final class FavoriteStarMotion: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var rotation: Double = 0
    @Published var ringScale: CGFloat = 0.55
    @Published var ringOpacity: Double = 0
}

private struct AnimatedFavoriteStar: View {
    @ObservedObject var state: IslandState
    @StateObject private var motion = FavoriteStarMotion()

    var body: some View {
        Button { state.tapFavorite() } label: {
            ZStack {
                Circle()
                    .strokeBorder(state.musicArtworkTint.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 27, height: 27)
                    .scaleEffect(motion.ringScale)
                    .opacity(motion.ringOpacity)
                Image(systemName: state.favoriteIsSaved ? "star.fill" : "star")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(state.favoriteIsVerified
                                     ? (state.favoriteIsSaved ? state.musicArtworkTint : Color.white.opacity(0.84))
                                     : Color.white.opacity(0.43))
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(motion.scale)
                    .rotationEffect(.degrees(motion.rotation))
            }
            .frame(width: 30, height: 43)
            .contentShape(Rectangle())
        }
        .buttonStyle(DynamicIslandButtonStyle())
        .disabled(state.favoriteIsUpdating)
        .accessibilityLabel(state.favoriteIsVerified
            ? (state.favoriteIsSaved ? "Убрать из избранного" : "Добавить в избранное")
            : "Настроить избранное Яндекс Музыки")
        .onChange(of: state.favoritePulse) { _ in animatePress() }
    }

    private func animatePress() {
        if state.favoriteIsSaved {
            // Add: the star springs out and a thin ring expands and fades.
            motion.scale = 0.68
            motion.ringScale = 0.55
            motion.ringOpacity = 0.95
            motion.rotation = -10
            withAnimation(IslandMotion.press) {
                motion.scale = 1.16
                motion.rotation = 0
            }
            withAnimation(.easeOut(duration: 0.32)) {
                motion.ringScale = 1.65
                motion.ringOpacity = 0
            }
        } else {
            // Remove: short inward collapse, then spring back to an outline.
            motion.scale = 1.16
            motion.ringOpacity = 0
            motion.rotation = 10
            withAnimation(.easeIn(duration: 0.13)) {
                motion.scale = 0.60
                motion.rotation = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(IslandMotion.press) {
                motion.scale = 1
                motion.rotation = 0
            }
        }
    }
}

// Time is extrapolated from a monotonic Date anchor 20 times/second. Media
// system polling is deliberately decoupled from redraws, so the bar moves
// smoothly even with slow AppleScript responses or transient seek metadata.
private final class ProgressDragModel: ObservableObject {
    @Published var position: Double? = nil
}

private struct SmoothProgressView: View {
    @ObservedObject var state: IslandState
    @StateObject private var drag = ProgressDragModel()

    private var duration: Double { max(1, state.track?.duration ?? 1) }

    var body: some View {
        TimelineView(PeriodicTimelineSchedule(from: Date(), by: 0.1)) { timeline in
            progressContent(at: timeline.date)
        }
        .onChange(of: state.track?.identity) { _ in
            drag.position = nil
        }
    }

    private func progressContent(at date: Date) -> some View {
        let current = min(duration, max(0, drag.position ?? state.displayedPosition(at: date)))
        return VStack(spacing: 2) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                        .frame(height: 4)
                    Capsule().fill(Color.white)
                        .frame(width: max(0, width * CGFloat(current / duration)), height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(1.0, max(0.0, Double(gesture.location.x / width)))
                        drag.position = fraction * duration
                    }
                    .onEnded { gesture in
                        let fraction = min(1.0, max(0.0, Double(gesture.location.x / width)))
                        let chosen = fraction * duration
                        // Set the player clock before clearing drag state
                        // to avoid a transient 00:00 during seek.
                        state.seek(to: chosen)
                        drag.position = nil
                    })
            }
            .frame(height: 17)

            HStack {
                Text(timeString(current))
                Spacer()
                Text("-" + timeString(max(0, duration - current)))
            }
            .font(.system(size: 9, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.53))
        }
    }

    private func timeString(_ total: Double) -> String {
        guard total.isFinite else { return "0:00" }
        let seconds = Int(max(0, total))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Responsive press + spring-back like the supplied iPhone reference.
// The hit region stays constant, so the island never jolts when tapped.
struct DynamicIslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.white.opacity(0.73) : Color.white)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.78 : 1.0)
            .animation(IslandMotion.press, value: configuration.isPressed)
    }
}

// 3.5.1: iPhone-style waveform. Six capsules on springs (IslandWaveform-
// Physics) — fluid overshoot, independent breathing, dots on pause, a calm
// rhythm when system-audio capture is off. Redraws at display rate only
// while something moves.
private struct AudioReactiveBars: View {
    var playing: Bool
    var live: Bool
    var maxHeight: CGFloat
    var barWidth: CGFloat
    var barSpacing: CGFloat
    var tint: Color
    // 3.18.0: the cover shows through the bars, blurred — as on iPhone.
    var artwork: NSImage? = nil
    // 4.13.0: false while these bars cannot be seen (the player is open,
    // a banner covers it, or the player is hidden behind the music app) —
    // they stop drawing instead of animating at full rate behind it.
    var active = true

    // No @State: the command-line build has no SwiftUI macro plugin.
    @StateObject private var driver = WaveformDriver()
    // 4.8.3: look and size chosen in Settings.
    @AppStorage(WaveLook.styleKey) private var style = WaveLook.legacyStyle
    @AppStorage(WaveLook.colorKey) private var customColor = ""
    @AppStorage(WaveLook.blurKey) private var blurAmount = 0.4
    @AppStorage(WaveLook.sizeKey) private var sizeScale = 1.0

    private var animating: Bool { active && (playing || driver.settling) }

    private var blurredCover: NSImage? {
        style == "artwork" ? ArtworkBlur.blurred(artwork, amount: blurAmount) : nil
    }

    private var barColor: Color {
        style == "custom" ? WaveLook.decodeColor(customColor).color : tint.opacity(0.9)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / Double(EnergySaver.isActive ? min(15, WaveLook.fps) : WaveLook.fps),
                                paused: !animating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let heights = PerformanceMonitor.measure("wave") {
                driver.physics.step(
                    to: time,
                    targets: IslandWaveformPhysics.targets(levels: AudioLevelStore.values.map(Double.init), time: time,
                                                           playing: playing, live: live))
            }
            // 3.16.5: one Canvas (one layer) instead of six capsule views —
            // each frame now costs a single redraw instead of six layouts.
            let count = IslandWaveformPhysics.barCount
            let k = CGFloat(min(1.3, max(0.7, sizeScale)))
            let barWidth = self.barWidth * k, barSpacing = self.barSpacing * k, maxHeight = self.maxHeight * k
            let width = CGFloat(count) * barWidth + CGFloat(count - 1) * barSpacing
            let bars = Canvas { context, size in
                for index in 0..<count {
                    let value = CGFloat(index < heights.count ? heights[index] : 0)
                    let h = barWidth + max(0, value) * (maxHeight - barWidth)
                    let x = CGFloat(index) * (barWidth + barSpacing)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white))
                }
            }
            .frame(width: width, height: maxHeight)
            Group {
                if let cover = blurredCover {
                    Image(nsImage: cover)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: width, height: maxHeight)
                        .clipped()
                        .mask(bars)
                } else {
                    bars.colorMultiply(barColor)
                }
            }
        }
        .onChange(of: playing) { _, nowPlaying in
            driver.playingChanged(nowPlaying)
        }
    }
}

private final class WaveformDriver: ObservableObject {
    let physics = IslandWaveformPhysics()
    @Published private(set) var settling = false
    private var settleToken = UUID()

    // Keep drawing after a pause until the bars have sunk into dots.
    func playingChanged(_ playing: Bool) {
        let token = UUID()
        settleToken = token
        guard !playing else { settling = false; return }
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.settleToken == token else { return }
            self.settling = false
        }
    }
}

// The countdown uses an absolute deadline; it never depends on music's time
// or a player poll. The numbers remain smooth through player changes/pauses.
private struct TimerReadout: View {
    @ObservedObject var state: IslandState
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let seconds = Int(ceil(state.timerRemaining(at: context.date)))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.67)
                .allowsTightening(true)
                .foregroundStyle(.white)
        }
    }
}

private struct CompactTimer: View {
    @ObservedObject var state: IslandState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.timerPaused ? "pause.circle.fill" : "timer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.95, green: 0.71, blue: 0.39))
            TimerReadout(state: state, fontSize: 11)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Оставшееся время таймера")
    }
}

private struct TimerInlineControls: View {
    @ObservedObject var state: IslandState

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button { state.toggleTimerPause() } label: {
                Image(systemName: state.timerPaused ? "play.fill" : "pause.fill")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(state.timerPaused ? "Продолжить таймер" : "Пауза таймера")
            .disabled(state.timerPreviewActive && !state.timerActive)
            Button { state.stopTimer() } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Остановить таймер")
            .disabled(state.timerPreviewActive && !state.timerActive)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(DynamicIslandButtonStyle())
    }
}

// Focus banner in the iPhone style: the mode's own symbol on the left, its
// state on the right, both in the mode's tint. "Off" is shown in grey.
// Pure content: the shared black silhouette and its morph are unchanged.
private struct FocusEventContent: View {
    let presentation: FocusPresentation?
    let bounceTrigger: Int
    let wing: CGFloat
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let isOn = presentation?.isOn ?? true
        let mode = presentation?.mode ?? FocusMode.demo
        let accent = isOn ? BannerTheme.tint(FocusPalette.color(for: mode.tintName)) : Color.white.opacity(0.5)
        HStack(spacing: 0) {
            Image(systemName: mode.displaySymbol)
                .font(.system(size: 14.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(accent)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounceTrigger)
                .frame(width: wing, height: height)
                .offset(x: 2)
            Color.clear.frame(width: notchWidth, height: height)
            Text(isOn ? "Вкл" : "Выкл")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: wing, height: height)
                .offset(x: -2)
        }
        .animation(.easeInOut(duration: 0.25), value: isOn)
        .animation(.easeInOut(duration: 0.25), value: mode.identifier)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Фокусирование «\(mode.name)» \(isOn ? "включено" : "выключено")")
    }
}

// Volume feedback shown for ~1 s in place of the spectrum after a scroll
// gesture: a speaker glyph and a vertical level bar in the cover tint.
private struct VolumeLevelGlyph: View {
    let level: Float
    let compact: Bool

    private var symbol: String {
        if level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        let barHeight: CGFloat = compact ? 18 : 40
        HStack(spacing: compact ? 3 : 6) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 9 : 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: compact ? 13 : 26)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white)
                    .frame(height: max(compact ? 2 : 3, barHeight * CGFloat(level)))
            }
            .frame(width: compact ? 4 : 6, height: barHeight)
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel("Громкость \(Int((level * 100).rounded())) процентов")
    }
}

// Lab banner (3.3.0): symbol or thumbnail left, short label right, an
// optional level bar under the label (volume, CPU).
private struct NoticeEventContent: View {
    let notice: IslandNotice?
    let wing: CGFloat
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let image = notice?.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: notice?.symbol ?? "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(BannerTheme.noticeTint(notice?.tint))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: wing, height: height)
            .offset(x: 2)
            Color.clear.frame(width: notchWidth, height: height)
            VStack(spacing: 3) {
                Text(notice?.text ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let level = notice?.level {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(BannerTheme.noticeTint(notice?.tint))
                            .frame(width: max(2, 34 * CGFloat(min(1, max(0, level)))))
                    }
                    .frame(width: 34, height: 3)
                }
            }
            .frame(width: wing - 6, height: height)
            .offset(x: -3)
            .frame(width: wing, height: height)
        }
        .animation(.easeOut(duration: 0.15), value: notice?.level)
        .animation(.easeOut(duration: 0.15), value: notice?.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice?.accessibility ?? "")
    }
}

// "New version in Downloads": tap anywhere on the banner to install it.
private struct UpdateEventContent: View {
    let version: String
    let wing: CGFloat
    let notchWidth: CGFloat
    let height: CGFloat

    // 3.17.1: a glowing green badge that gently pulses on the left, and
    // «Обновить» over the version number on the right.
    // 3.18.2: in the colours of the theme chosen in Settings (a colour
    // theme's first two shades); green → blue for the plain themes.
    private var green: Color { SettingsTheme.updateColors.0 }
    private var teal: Color { SettingsTheme.updateColors.1 }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [green, teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .shadow(color: green.opacity(0.7), radius: 5)
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .frame(width: wing, height: height)
            .offset(x: 4)
            Color.clear.frame(width: notchWidth, height: height)
            VStack(alignment: .center, spacing: 0) {
                Text("Обновить")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [green, teal], startPoint: .leading, endPoint: .trailing))
                Text(version.isEmpty ? "новая версия" : "до \(version)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // Kept clear of the island's rounded right corner.
            .frame(width: wing - 20, height: height)
            .frame(width: wing, height: height, alignment: .center)
            .offset(x: -6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Доступна версия \(version). Нажми, чтобы обновить")
        .accessibilityAddTraits(.isButton)
    }
}

// Apple's dark-appearance system tints, fixed so the colours stay vivid on
// the black island regardless of the hosting window's appearance.
enum FocusPalette {
    static func color(for tintName: String?) -> Color {
        let key = (tintName ?? "").lowercased()
            .replacingOccurrences(of: "system", with: "")
            .replacingOccurrences(of: "color", with: "")
        switch key {
        case "purple": return Color(red: 0.75, green: 0.35, blue: 0.95)
        case "pink": return Color(red: 1.0, green: 0.22, blue: 0.37)
        case "red": return Color(red: 1.0, green: 0.27, blue: 0.23)
        case "orange": return Color(red: 1.0, green: 0.62, blue: 0.04)
        case "yellow": return Color(red: 1.0, green: 0.84, blue: 0.04)
        case "green": return Color(red: 0.19, green: 0.82, blue: 0.35)
        case "mint": return Color(red: 0.39, green: 0.90, blue: 0.89)
        case "teal": return Color(red: 0.25, green: 0.78, blue: 0.88)
        case "cyan": return Color(red: 0.39, green: 0.82, blue: 1.0)
        case "blue": return Color(red: 0.04, green: 0.52, blue: 1.0)
        case "brown": return Color(red: 0.67, green: 0.56, blue: 0.41)
        case "gray", "grey": return Color(red: 0.60, green: 0.60, blue: 0.62)
        // Indigo, slightly lifted so the moon reads well on true black.
        default: return Color(red: 0.49, green: 0.48, blue: 1.0)
        }
    }
}

// 4.5.0: a 3D model of the earbuds spinning around its own axis, like the
// connection animation on iPhone.
private struct AirPodsCompactLeadingGlyph: View {
    var headphones: Bool

    var body: some View {
        SpinningEarbudsView(headphones: headphones)
            .frame(width: 36, height: 36)
            .shadow(color: .white.opacity(0.12), radius: 3)
            .frame(width: 40, height: 40)
            .accessibilityLabel(headphones ? "Наушники" : "Наушники-вкладыши")
    }
}

private struct AirPodsChargeRing: View {
    let percent: Int?

    private var progress: CGFloat {
        guard let percent else { return 0 }
        return CGFloat(max(0, min(percent, 100))) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 2.25)
            Circle()
                .trim(from: 0, to: max(progress, 0.015))
                .stroke(BannerTheme.tint(Color(red: 0.22, green: 0.86, blue: 0.42)), style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(percent == nil ? 0.25 : 1)
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(percent == nil ? "Заряд AirPods недоступен" : "Заряд AirPods \(percent!) процентов")
    }
}

private extension IslandState {
    var airPodsPrimaryBattery: Int? {
        guard let airPods else { return nil }
        if let caseBattery = airPods.caseBattery { return caseBattery }
        if let main = airPods.main { return main }
        switch (airPods.left, airPods.right) {
        case let (left?, right?): return Int(round(Double(left + right) / 2.0))
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }
}

private struct AirPodsBatteryPill: View {
    let label: String
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.white.opacity(0.75))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.23))
                Capsule()
                    .fill(percent <= 20 ? Color.orange : Color.green)
                    .frame(width: max(2, CGFloat(percent) / 100 * 21))
            }
            .frame(width: 21, height: 4)
            Text("\(percent)%")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.96))
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .animation(.easeOut(duration: 0.32), value: percent)
    }
}


// 4.5.0: a liquid bridge drawn in absolute coordinates of the satellite's
// content (x < 0 reaches back into the music island). Straight top along
// the bezel, a concave bottom whose lowest point is `neck`.
struct SatelliteBridge: Shape {
    let left: CGFloat
    let right: CGFloat
    let leftDepth: CGFloat
    let rightDepth: CGFloat
    let neck: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard right > left + 1 else { return path }
        let width = right - left
        let mid = left + width * 0.5
        path.move(to: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: rightDepth - 1))
        path.addCurve(to: CGPoint(x: mid, y: neck),
                      control1: CGPoint(x: right - width * 0.18, y: rightDepth - 1),
                      control2: CGPoint(x: mid + width * 0.22, y: neck))
        path.addCurve(to: CGPoint(x: left, y: leftDepth - 1),
                      control1: CGPoint(x: mid - width * 0.22, y: neck),
                      control2: CGPoint(x: left + width * 0.18, y: leftDepth - 1))
        path.closeSubpath()
        return path
    }
}

// A dedicated mini-island for the timer, separate from the MacBook notch.
// Its own NSPanel provides independent hover, so opening the timer never
// expands the music player or steals its buttons.
struct TimerSatelliteView: View {
    @ObservedObject var state: IslandState

    private var openingWidth: CGFloat {
        state.timerExpanded ? state.timerExpandedWidth : state.timerCompactDiameter
    }
    private var openingHeight: CGFloat {
        state.timerExpanded ? state.timerExpandedHeight : state.timerCompactDiameter
    }

    var body: some View {
        let presence = state.timerSatellitePresence
        let width = openingWidth
        let height = openingHeight
        // Start geometry: a thin bridge emerging from the main island's
        // right edge — or, for an in-place exit, a small dot in the middle.
        let inPlace = state.timerSatelliteShrinksInPlace
        let startX: CGFloat = inPlace ? width * 0.3 : -state.timerLeadInset
        let startWidth: CGFloat = inPlace ? width * 0.4 : 12
        let startHeight: CGFloat = inPlace ? height * 0.4 : height * 0.62
        let shapeWidth = max(1, startWidth + (width - startWidth) * presence)
        let shapeHeight = max(1, startHeight + (height - startHeight) * presence)
        let shapeX = startX * (1 - presence)
        let corner: CGFloat = state.timerExpanded ? 16 : 9

        ZStack(alignment: .topLeading) {
            // 4.5.0: the liquid neck between the music island and the drop.
            // Thick while they touch, it thins as the drop pulls away and
            // snaps just before the drop settles — and grows back when the
            // drop flows home.
            if presence < 0.98 && !state.timerExpanded {
                let roofDepth = state.timerTopBleed
                let leftEdge = -state.timerLeadInset
                let dropLeft = shapeX + 2
                let mainDepth = state.timerCompactDiameter + roofDepth
                let dropDepth = shapeHeight + roofDepth
                let pull = min(1, max(0, Double(presence) / 0.9))
                let neckFactor = CGFloat(pow(1 - pull, 1.35))
                let neck = roofDepth + (min(mainDepth, dropDepth) - roofDepth) * neckFactor
                SatelliteBridge(left: leftEdge, right: dropLeft + min(corner, shapeWidth / 2),
                                leftDepth: mainDepth, rightDepth: dropDepth, neck: neck)
                    .fill(Color.black)
                    .opacity(neck > roofDepth + 0.3 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Like the main island: a straight top edge touching the screen
            // bezel, with rounding ONLY at the bottom two corners.
            // 4.8.5: the same drop curves at the screen edge as the main island.
            let satFlare = (state.timerExpanded ? 13 : state.edgeFlare) * min(1, max(0, presence))
            IslandSilhouette(bottomRadius: min(corner, shapeHeight / 2), flare: satFlare,
                             roof: state.timerTopBleed)
                .fill(Color.black)
                // Black fills the extra 5pt roof above the screen edge.
                .frame(width: shapeWidth + satFlare * 2,
                       height: shapeHeight + state.timerTopBleed)
                .offset(x: shapeX - satFlare)
                .opacity(min(1, Double(presence) * 4))
                .animation(state.timerExpanded ? IslandMotion.grow : IslandMotion.shrink,
                           value: state.timerExpanded)

            Group {
                if state.timerExpanded {
                    expandedTimer
                        .frame(width: state.timerExpandedWidth,
                               height: state.timerExpandedHeight)
                        .padding(.top, state.timerTopBleed)
                        .transition(.opacity.combined(with: .scale(scale: 0.94,
                                                                   anchor: .topLeading)))
                } else {
                    compactStopwatch
                        .frame(width: state.timerCompactDiameter,
                               height: state.timerCompactDiameter)
                        .padding(.top, state.timerTopBleed)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            // Contents appear after the drop has formed and leave first.
            .opacity(state.timerSatelliteContentVisible ? 1 : 0)
            .blur(radius: state.timerSatelliteContentVisible ? 0 : 4)
            .scaleEffect(state.timerSatelliteContentVisible ? 1 : 0.86)
        }
        .frame(width: openingWidth,
               height: openingHeight + state.timerTopBleed, alignment: .topLeading)
        // 4.14.4: lifts a little under the pointer, like the music island.
        .scaleEffect(state.timerHoverPeek && !state.timerExpanded ? 1.06 : 1, anchor: .top)
        .contentShape(Rectangle())
        .onHover { over in if state.timerExpanded { state.timerHoverChanged(over) } }
        .frame(width: state.timerPanelSize.width,
               height: state.timerPanelSize.height, alignment: .topLeading)
        .padding(.leading, state.timerLeadInset)
        .frame(width: state.timerPanelSize.width + state.timerLeadInset + 13,
               height: state.timerPanelSize.height, alignment: .topLeading)
        .accessibilityLabel(state.timerExpanded ? "Таймер, управление" : "Таймер, открыть")
    }

    private var compactStopwatch: some View {
        VStack(spacing: 1) {
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.64, blue: 0.10))
            TimerReadout(state: state, fontSize: 7.8)
                .frame(maxWidth: state.timerCompactDiameter - 5)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Оставшееся время таймера приложения Часы")
        .contentShape(Rectangle())
        .onTapGesture { state.expandTimerSatellite(force: true) }
    }

    private var expandedTimer: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Таймер")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                    TimerReadout(state: state, fontSize: 23)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)

            HStack(spacing: 10) {
                Button {
                    state.toggleTimerPause()
                } label: {
                    Label(state.timerPaused ? "Продолжить" : "Пауза",
                          systemImage: state.timerPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(Color.white.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 11))
                }
                .disabled(state.timerPreviewActive && !state.timerActive)
                Button { state.stopTimer() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 34)
                        .background(Color.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11))
                }
                .accessibilityLabel("Остановить таймер")
                .disabled(state.timerPreviewActive && !state.timerActive)
            }
            .foregroundStyle(.white)
            .buttonStyle(DynamicIslandButtonStyle())
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 17)
    }
}

// MARK: - 3.6.0 Lock-screen player (iPhone lock-screen style)

// Shown in the protected SkyLight space while the Mac is locked, at the
// bottom centre above the login field. Same data and commands as the island.
struct LockScreenMediaCard: View {
    @ObservedObject var state: IslandState
    @ObservedObject var backdrop: LockCardBackdrop
    // 3.6.1: follows System Settings → Accessibility → Display.
    @ObservedObject private var display = SystemDisplayOptions.shared
    @ObservedObject private var ui = LockCardUIState.shared
    @StateObject private var outputRoute = LockOutputRoute()
    @StateObject private var outputs = OutputDeviceList()
    @ObservedObject private var activity = LockCoverActivity.media
    private var scale: CGFloat { CGFloat(display.cardScale) }

    static let size = CGSize(width: 430, height: 196)
    // 3.7.0: big artwork, like the iPhone full-screen player.
    static let expandedSize = CGSize(width: 430, height: 540)
    // Room around the card for its soft shadow and rim light.
    static let margin: CGFloat = 26
    static var panelSize: CGSize { panelSize(scale: 1) }
    // The panel always has room for the expanded card; the card sits at
    // its bottom, so expanding grows it upwards (transparent area above).
    static func panelSize(scale k: CGFloat) -> CGSize {
        // 3.8.8: only as tall as the card. The old room for the big card
        // (3.7.0) was an invisible, click-catching area in the middle of
        // the screen — taps on the centre of the artwork wallpaper landed
        // there instead of returning the wallpaper.
        CGSize(width: (size.width + margin * 2) * k, height: (size.height + margin * 2) * k)
    }
    static var currentScale: CGFloat { CGFloat(SystemDisplayOptions.shared.cardScale) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 3.16.3: nothing is built while the card is hidden.
            if activity.active, let song = state.track {
                card(song)
                    .padding(.bottom, Self.margin * scale)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .frame(width: Self.panelSize(scale: scale).width, height: Self.panelSize(scale: scale).height,
               alignment: .bottom)
        .animation(IslandMotion.surface, value: state.track == nil)
    }

    private func card(_ song: PlayingTrack) -> some View {
        // 3.7.2: the big artwork replaces the lock-screen wallpaper (its own
        // full-screen window); the card itself stays compact.
        let size = Self.size
        return Group {
            compactLayout(song)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            if ui.outputsOpen { outputPicker(size: size) }
        }
        .onAppear { outputRoute.refresh(); ui.outputsOpen = false }
        .onChange(of: song.identity) { _, _ in outputRoute.refresh() }
        // Content is scaled as a picture; the glass (AppKit blur) is built
        // directly at the scaled size, since AppKit views ignore scaleEffect.
        .scaleEffect(scale)
        .frame(width: size.width * scale, height: size.height * scale)
        .modifier(LockCardSurface(display: display, backdrop: backdrop,
                                  tint: state.musicArtworkTint, scale: scale, cardSize: size))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Медиаплеер на экране блокировки")
    }

    // 4.8.3: devices listed inside the card (a system menu cannot appear
    // over the lock screen). A tap on a device switches the output.
    private func outputPicker(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        return ZStack {
            shape.fill(Color.black.opacity(0.82))
                .onTapGesture { closeOutputs() }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Выход звука").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button { closeOutputs() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(outputs.devices) { device in
                            outputRow(device)
                        }
                        if outputs.devices.isEmpty {
                            Text("Нет устройств вывода").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .buttonStyle(DynamicIslandButtonStyle())
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func outputRow(_ device: AudioOutputDevice) -> some View {
        let current = device.name == outputRoute.name
        return Button {
            SystemVolume.setDefaultOutput(device.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { outputRoute.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { closeOutputs() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.system(size: 17, weight: .medium)).frame(width: 26)
                Text(device.name).font(.system(size: 15, weight: current ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if current { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(current ? 0.14 : 0.0)))
            .contentShape(Rectangle())
        }
    }

    private func closeOutputs() {
        withAnimation(IslandMotion.surface) { ui.outputsOpen = false }
    }

    // 4.10.3: the same in both modes — the artwork leaves the card for the
    // wallpaper (real macOS login or the older window over it).
    private var artworkOnWallpaper: Bool { ui.expanded }

    private func toggleExpanded() {
        withAnimation(IslandMotion.surface) { ui.expanded.toggle() }
    }

    // MARK: Pieces

    private func artwork(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = state.musicArtwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.2))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded() }
        .help(ui.expanded ? "Вернуть обои" : "Обложка вместо обоев")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(ui.expanded ? "Вернуть обои" : "Обложка вместо обоев")
    }

    private func titles(_ song: PlayingTrack, title: CGFloat, artist: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(song.title)
                .font(.system(size: title, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(song.artist)
                .font(.system(size: artist, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bars(_ song: PlayingTrack) -> some View {
        AudioReactiveBars(playing: song.isPlaying,
                          live: state.audioLive,
                          maxHeight: 26, barWidth: 3.2,
                          barSpacing: 2.6, tint: Color.white.opacity(0.75))
            .frame(width: 38)
    }

    // Favourite · back · play · forward · output — evenly across the card.
    private func controls(_ song: PlayingTrack) -> some View {
        HStack(spacing: 0) {
            Group {
                if state.favoriteSupported {
                    AnimatedFavoriteStar(state: state)
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: 40)
            Spacer(minLength: 0)
            Button { state.command(.previous) } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .medium))
                    .symbolEffect(.bounce, value: state.previousPulse)
                    .frame(width: 52, height: 40)
            }
            Spacer(minLength: 0)
            Button { state.command(.toggle) } label: {
                Image(systemName: song.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 40)
            }
            Spacer(minLength: 0)
            Button { state.command(.next) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .medium))
                    .symbolEffect(.bounce, value: state.nextPulse)
                    .frame(width: 52, height: 40)
            }
            Spacer(minLength: 0)
            // 4.8.3: choose where the sound goes, right on the lock screen.
            Button {
                outputs.refresh()
                withAnimation(IslandMotion.surface) { ui.outputsOpen.toggle() }
            } label: {
                Image(systemName: outputRoute.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(ui.outputsOpen ? 1 : 0.62))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .help("Звук: \(outputRoute.name)")
            .accessibilityLabel("Звук: \(outputRoute.name). Выбрать устройство")
        }
        .buttonStyle(DynamicIslandButtonStyle())
        .foregroundStyle(.white)
    }

    // MARK: Layouts

    // 3.6.11: the layout of the iPhone lock-screen player.
    private func compactLayout(_ song: PlayingTrack) -> some View {
        VStack(spacing: 0) {
            // 3.8.6: one layout for both states, so the change animates —
            // the thumbnail shrinks away and the title glides to the centre
            // (centred over the progress line), and back again.
            HStack(alignment: .center, spacing: artworkOnWallpaper ? 0 : 14) {
                artwork(size: 60, radius: 12)
                    .scaleEffect(artworkOnWallpaper ? 0.5 : 1)
                    .opacity(artworkOnWallpaper ? 0 : 1)
                    .frame(width: artworkOnWallpaper ? 0 : 60, height: 60)
                    .allowsHitTesting(!artworkOnWallpaper)
                // Mirrors the spectrum on the right, so the title is centred
                // on the whole card.
                Color.clear.frame(width: artworkOnWallpaper ? 38 : 0, height: 1)
                VStack(alignment: artworkOnWallpaper ? .center : .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: artworkOnWallpaper ? 18 : 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(song.artist)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .lineLimit(1)
                .multilineTextAlignment(artworkOnWallpaper ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: artworkOnWallpaper ? .center : .leading)
                bars(song)
            }
            .frame(height: 60)
            .animation(IslandMotion.surface, value: ui.expanded)
            Spacer(minLength: 10)
            if song.duration > 0 { LockProgressRow(state: state) }
            Spacer(minLength: 8)
            controls(song)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // 3.7.0: big artwork over a blurred wash of the cover's colours.
    private func expandedLayout(_ song: PlayingTrack) -> some View {
        VStack(spacing: 0) {
            artwork(size: 270, radius: 20)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                .padding(.top, 26)
            Spacer(minLength: 16)
            HStack(alignment: .center, spacing: 12) {
                titles(song, title: 21, artist: 18)
                bars(song)
            }
            Spacer(minLength: 12)
            if song.duration > 0 { LockProgressRow(state: state) }
            Spacer(minLength: 10)
            controls(song)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
        .background {
            // The cover itself, hugely blurred — the iPhone "Now Playing" wash.
            if let image = state.musicArtwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60)
                    .saturation(1.4)
                    .overlay(Color.black.opacity(0.30))
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .opacity(0.92)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
    }
}

// Expanded/compact state shared by the lock-screen and preview cards; reset
// whenever the card is hidden so the next lock starts compact.
final class LockCardUIState: ObservableObject {
    static let shared = LockCardUIState()
    @Published var expanded = false
    // 4.8.3: the list of sound outputs open inside the card.
    @Published var outputsOpen = false
}

// 3.6.8: hand-made Liquid Glass. System glass does not draw inside the
// protected lock-screen window (see the 3.6.7 screenshot), so the card
// renders the glass itself from the real wallpaper under it: a lens body
// (slightly magnified, lightly blurred wallpaper), a refracting rim (more
// magnified ring), specular highlights, inner shading and a soft shadow.
// The «прозрачность стекла» value only adds frosting and dark tint.
private struct LockCardSurface: ViewModifier {
    @ObservedObject var display: SystemDisplayOptions
    @ObservedObject var backdrop: LockCardBackdrop
    var tint: Color
    var scale: CGFloat = 1
    var cardSize: CGSize = LockScreenMediaCard.size

    @ViewBuilder
    func body(content: Content) -> some View {
        if display.reduceTransparency {
            legacy(content)
        } else if display.cardStyle != "glass" {
            // 4.8.0: other looks for the lock-screen card.
            content
                .shadow(color: .black.opacity(display.cardStyle == "none" ? 0.6 : 0.3),
                        radius: display.cardStyle == "none" ? 6 : 2.5, y: 1)
                .background {
                    LockCardAltSurface(style: display.cardStyle, tint: tint, scale: scale, cardSize: cardSize)
                }
        } else {
            content
                .shadow(color: .black.opacity(0.28 + 0.2 * (1 - display.effectiveGlassTint)), radius: 2.5, y: 1)
                .background {
                    LiquidGlassSurface(backdrop: backdrop, tint: tint,
                                       t: display.effectiveGlassTint,
                                       blur: display.glassMode == "custom"
                                           ? display.backdropStrength
                                           : 0.78 + 0.22 * display.effectiveGlassTint,
                                       highContrast: display.increaseContrast,
                                       scale: scale, cardSize: cardSize)
                }
        }
    }

    @ViewBuilder
    private func legacy(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    if display.reduceTransparency {
                        // «Уменьшить прозрачность»: a solid card, no wallpaper
                        // showing through, only a faint cover tint.
                        Color(white: 0.12)
                        LinearGradient(colors: [tint.opacity(0.22), Color.clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        // 3.6.4: clearly different glass for every position of the
                        // macOS 27 slider (t: 0 = clear … 1 = tinted).
                        let t = display.effectiveGlassTint
                        LockCardBlur(strength: 0.45 + 0.55 * t, tinted: t > 0.5)
                        // A breath of the cover colour, like the iPhone lock screen.
                        LinearGradient(colors: [tint.opacity(0.16 + 0.14 * t),
                                                Color.black.opacity(0.04 + 0.26 * t)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        // Tinted: frosted dark glass.
                        Color.black.opacity(0.62 * t)
                        // Clear: a glass sheen from the top edge.
                        LinearGradient(colors: [Color.white.opacity(0.16 * (1 - t)), Color.clear],
                                       startPoint: .top, endPoint: .center)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .animation(.easeInOut(duration: 0.3), value: display.reduceTransparency)
                .animation(.easeInOut(duration: 0.3), value: display.effectiveGlassTint)
            }
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                // Clear glass: a bright rim, as Liquid Glass draws it.
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(display.reduceTransparency ? 0 : 0.34 * (1 - display.effectiveGlassTint)),
                                                      Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(display.increaseContrast ? 0.42 : 0.10),
                              lineWidth: display.increaseContrast ? 1.3 : 0.8))
    }
}

// 4.8.0 — the card without Liquid Glass: frosted, dark, in the cover's
// colours, or no card at all (just the text with a soft shadow).
struct LockCardAltSurface: View {
    var style: String
    var tint: Color
    var scale: CGFloat = 1
    var cardSize: CGSize = LockScreenMediaCard.size

    private var card: CGSize { CGSize(width: cardSize.width * scale, height: cardSize.height * scale) }
    private var panel: CGSize {
        let m = LockScreenMediaCard.margin * scale
        return CGSize(width: card.width + m * 2, height: card.height + m * 2)
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 36 * scale, style: .continuous) }

    var body: some View {
        ZStack {
            if style != "none" {
                shape.fill(Color.black.opacity(0.32))
                    .frame(width: card.width, height: card.height)
                    .blur(radius: 16)
                    .offset(y: 9)
                    .opacity(0.7)
            }
            switch style {
            case "frosted":
                LockCardBlur(strength: 1, tinted: false)
                    .clipShape(shape)
                    .frame(width: card.width, height: card.height)
                shape.fill(Color.white.opacity(0.10))
                    .frame(width: card.width, height: card.height)
                shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    .frame(width: card.width, height: card.height)
            case "dark":
                shape.fill(Color(white: 0.07).opacity(0.92))
                    .frame(width: card.width, height: card.height)
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    .frame(width: card.width, height: card.height)
            case "cover":
                shape.fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55), Color.black.opacity(0.7)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: card.width, height: card.height)
                shape.fill(Color.black.opacity(0.22))
                    .frame(width: card.width, height: card.height)
                shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    .frame(width: card.width, height: card.height)
            default:
                EmptyView()      // «none»: no card, only the contents
            }
        }
        .frame(width: panel.width, height: panel.height)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: tint)
    }
}

struct LiquidGlassSurface: View {
    @ObservedObject var backdrop: LockCardBackdrop
    var tint: Color
    var t: Double              // 0 = clear glass … 1 = tinted
    var blur: Double = 0.8     // how much frosting (0 = fully transparent)
    var highContrast: Bool
    var scale: CGFloat = 1
    var cardSize: CGSize = LockScreenMediaCard.size

    private var card: CGSize {
        CGSize(width: cardSize.width * scale, height: cardSize.height * scale)
    }
    // Card plus room for the shadow, centred on the card.
    private var panel: CGSize {
        let m = LockScreenMediaCard.margin * scale
        return CGSize(width: card.width + m * 2, height: card.height + m * 2)
    }
    var cornerRadius: CGFloat = 36
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous) }

    var body: some View {
        ZStack {
            // Soft shadow that lifts the glass off the wallpaper.
            // Only OUTSIDE the card, or it would darken the clear glass.
            ZStack {
                shape.fill(Color.black.opacity(0.30))
                    .frame(width: card.width, height: card.height)
                    .blur(radius: 16)
                    .offset(y: 9)
                    .opacity(0.75)
            }
            .frame(width: panel.width, height: panel.height)
            .mask {
                ZStack {
                    Rectangle()
                    shape.frame(width: card.width, height: card.height)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }

            // 3.6.9: the LIVE lock screen behind the card (behind-window
            // material sees the real, moving wallpaper). The desktop picture
            // file is not what the lock screen shows (aerials), so no copy.
            // Lens body: partly frosted, so the scene stays crisp-ish.
            // 3.6.10: like the iPhone lock-screen player — light, milky
            // glass (light vibrant material), not a grey/dark slab.
            // 3.6.11: as on the iPhone lock screen — the scene stays
            // visible through dark, smoky glass (not milky), white text pops.
            if blur > 0.01 {
                LockCardBlur(strength: blur, tinted: true)
                    .clipShape(shape)
                    .frame(width: card.width, height: card.height)
            }
            shape.fill(Color.black.opacity(0.16 + 0.10 * (1 - blur)))
                .frame(width: card.width, height: card.height)
            // Lens edge: a faint light along the rim.
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 6)
                .blur(radius: 3)
                .mask(shape)
                .frame(width: card.width, height: card.height)

            // Frosting / tint from the «прозрачность стекла» value.
            shape.fill(Color.black.opacity(0.58 * t))
                .frame(width: card.width, height: card.height)
            shape.fill(LinearGradient(colors: [tint.opacity(0.06 + 0.16 * t), Color.clear],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: card.width, height: card.height)

            // Inner light from the top, inner shade at the bottom.
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.0)],
                                              startPoint: .top, endPoint: .center),
                               lineWidth: 9)
                .blur(radius: 5)
                .mask(shape)
                .frame(width: card.width, height: card.height)
            shape.strokeBorder(LinearGradient(colors: [Color.clear, Color.black.opacity(0.22)],
                                              startPoint: .center, endPoint: .bottom),
                               lineWidth: 8)
                .blur(radius: 5)
                .mask(shape)
                .frame(width: card.width, height: card.height)

            // Specular rim: bright top-left and bottom-right corners, dim
            // sides — the two-sided glint of Liquid Glass.
            shape.strokeBorder(LinearGradient(stops: [
                    .init(color: Color.white.opacity(0.55), location: 0.0),
                    .init(color: Color.white.opacity(0.16), location: 0.25),
                    .init(color: Color.white.opacity(0.05), location: 0.5),
                    .init(color: Color.white.opacity(0.14), location: 0.78),
                    .init(color: Color.white.opacity(0.40), location: 1.0)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: highContrast ? 1.8 : 1.0)
                .frame(width: card.width, height: card.height)
        }
        .frame(width: panel.width, height: panel.height)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: t)
    }
}

// The wallpaper piece exactly under the card panel, cut from the current
// desktop picture (the lock screen shows the same one). Loaded off the main
// thread and cached per wallpaper file.
final class LockCardBackdrop: ObservableObject {
    @Published private(set) var image: NSImage?
    private let queue = DispatchQueue(label: "app.notchisland.lockbackdrop", qos: .userInitiated)
    private var cachedURL: URL?
    private var cachedImage: CGImage?
    private(set) var lastStatus = "не загружено"

    func update(panelFrame: NSRect, screen: NSScreen) {
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let screenFrame = screen.frame
        queue.async { [weak self] in
            guard let self else { return }
            guard let url else { self.publish(nil, "нет обоев"); return }
            if url != self.cachedURL {
                self.cachedURL = url
                self.cachedImage = Self.load(url)
            }
            guard let full = self.cachedImage else { self.publish(nil, "не прочитаны: \(url.pathExtension)"); return }
            let iw = Double(full.width), ih = Double(full.height)
            let sw = Double(screenFrame.width), sh = Double(screenFrame.height)
            guard iw > 0, ih > 0, sw > 0, sh > 0 else { self.publish(nil, "пустой размер"); return }
            // Aspect-fill, centred — how macOS places a wallpaper.
            let fill = max(sw / iw, sh / ih)
            let ox = (iw * fill - sw) / 2, oy = (ih * fill - sh) / 2
            let localX = Double(panelFrame.minX - screenFrame.minX)
            let localTop = Double(screenFrame.maxY - panelFrame.maxY)
            let crop = CGRect(x: (localX + ox) / fill, y: (localTop + oy) / fill,
                              width: Double(panelFrame.width) / fill, height: Double(panelFrame.height) / fill)
                .integral.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
            guard !crop.isEmpty, let piece = full.cropping(to: crop) else { self.publish(nil, "не вырезано"); return }
            let image = NSImage(cgImage: piece, size: panelFrame.size)
            self.publish(image, "обои: \(url.pathExtension.lowercased()) \(full.width)×\(full.height)")
        }
    }

    private func publish(_ image: NSImage?, _ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastStatus = status
            self?.image = image
        }
    }

    private static func load(_ url: URL) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4", "m4v"].contains(ext) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// Blur of the wallpaper behind the card (behind-window material).
private struct LockCardBlur: NSViewRepresentable {
    var strength: Double = 1   // 0…1: how much of the frosting is drawn
    var tinted = true
    var light = false          // milky iPhone-style glass
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Clear glass: thin, light material; tinted: the dense HUD material.
        nsView.material = tinted ? .hudWindow : .popover
        nsView.appearance = NSAppearance(named: light ? .vibrantLight : .darkAqua)
        nsView.alphaValue = CGFloat(min(1, max(0.2, strength)))
    }
}

// Live copy of the macOS display accessibility options
// (System Settings → Accessibility → Display). Updates instantly.
final class SystemDisplayOptions: NSObject, ObservableObject {
    static let shared = SystemDisplayOptions()
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool
    // 3.6.2: macOS 27 «Оформление → прозрачность стекла» (Liquid Glass).
    // Stored by macOS in the global domain as NSGlassTintAmount:
    // 0 = clear glass … 1 = most tinted / opaque. nil on older macOS.
    @Published private(set) var systemGlassTint: Double?
    // "system" — follow macOS; "clear" / "tinted" — own choice.
    @Published private(set) var glassMode: String
    private var observer: NSObjectProtocol?
    private var poll: Timer?

    static let glassKey = "NSGlassTintAmount"
    static let glassModeKey = "lockCardGlassModeV362"
    // 4.8.0: «glass» (Liquid Glass), «frosted», «dark», «cover», «none».
    static let cardStyleKey = "lockCardStyleV480"
    static let cardStyles: [(id: String, title: String)] = [
        ("glass", "Стекло"), ("frosted", "Матовое"), ("dark", "Тёмное"), ("cover", "Цвет обложки"), ("none", "Без карточки")
    ]
    @Published private(set) var cardStyle: String =
        UserDefaults.standard.string(forKey: "lockCardStyleV480") ?? "glass"

    func setCardStyle(_ style: String) {
        guard Self.cardStyles.contains(where: { $0.id == style }) else { return }
        cardStyle = style
        UserDefaults.standard.set(style, forKey: Self.cardStyleKey)
    }

    // Our own switch is offered only where macOS itself has the control.
    var systemHasGlassControl: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            || systemGlassTint != nil
    }

    // 3.6.12: lock-screen card size, 0.6…1.
    @Published private(set) var cardScale: Double =
        min(1, max(0.6, (UserDefaults.standard.object(forKey: "lockCardScaleV3612") as? Double) ?? 1))

    func setCardScale(_ value: Double) {
        cardScale = min(1, max(0.6, value))
        UserDefaults.standard.set(cardScale, forKey: "lockCardScaleV3612")
    }

    // 3.6.7: own value 0…1 (0 = fully transparent glass … 1 = tinted).
    @Published private(set) var customGlassTint: Double
    static let customGlassKey = "lockCardGlassCustomV367"

    // 0…1 used by the card; reduce-transparency always wins.
    var effectiveGlassTint: Double {
        switch glassMode {
        case "custom": return customGlassTint
        case "clear": return 0.15          // 3.6.2–3.6.6 choices
        case "tinted": return 1
        default: return min(1, max(0, systemGlassTint ?? 0))
        }
    }

    // How much blurred wallpaper sits under the glass. At 0 the card is
    // pure Liquid Glass: only the bent edges and highlights are visible.
    var backdropStrength: Double {
        let t = effectiveGlassTint
        if glassMode == "custom" { return t < 0.02 ? 0 : 0.15 + 0.85 * t }
        return 0.5 + 0.5 * t
    }

    func setCustomGlassTint(_ value: Double) {
        customGlassTint = min(1, max(0, value))
        UserDefaults.standard.set(customGlassTint, forKey: Self.customGlassKey)
        if glassMode != "custom" { setGlassMode("custom") }
    }

    private override init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        systemGlassTint = Self.readGlassTint()
        var mode = UserDefaults.standard.string(forKey: Self.glassModeKey) ?? "system"
        var custom = (UserDefaults.standard.object(forKey: Self.customGlassKey) as? Double) ?? 0.15
        // Earlier fixed choices become positions of the new slider.
        if mode == "clear" { mode = "custom"; custom = 0.15 }
        if mode == "tinted" { mode = "custom"; custom = 1 }
        glassMode = mode
        customGlassTint = custom
        super.init()
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        // System Settings writes the global domain from another process;
        // KVO on it is delivered via cfprefsd. A slow poll is the fallback.
        UserDefaults.standard.addObserver(self, forKeyPath: Self.glassKey, options: [.new], context: nil)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private static func readGlassTint() -> Double? {
        guard let value = UserDefaults(suiteName: UserDefaults.globalDomain)?.object(forKey: glassKey)
                ?? UserDefaults.standard.object(forKey: glassKey) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    func setGlassMode(_ mode: String) {
        glassMode = mode
        UserDefaults.standard.set(mode, forKey: Self.glassModeKey)
    }

    func refresh() {
        let workspace = NSWorkspace.shared
        let reduce = workspace.accessibilityDisplayShouldReduceTransparency
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
        if reduce != reduceTransparency { reduceTransparency = reduce }
        if contrast != increaseContrast { increaseContrast = contrast }
        let glass = Self.readGlassTint()
        if glass != systemGlassTint { systemGlassTint = glass }
    }

    static let appearancePane = "x-apple.systempreferences:com.apple.Appearance-Settings.extension"

    static let accessibilityDisplayPane =
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display"
}

// Times on both sides of the bar, as on the iPhone lock screen. Drag to seek.
private struct LockProgressRow: View {
    @ObservedObject var state: IslandState
    @StateObject private var drag = ProgressDragModel()

    private var duration: Double { max(1, state.track?.duration ?? 1) }

    var body: some View {
        TimelineView(PeriodicTimelineSchedule(from: Date(), by: 0.25)) { timeline in
            let current = min(duration, max(0, drag.position ?? state.displayedPosition(at: timeline.date)))
            HStack(spacing: 10) {
                Text(Self.time(current))
                    .frame(width: 38, alignment: .leading)
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: max(6, width * CGFloat(current / duration)))
                    }
                    .frame(height: 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag.position = min(1, max(0, Double($0.location.x / width))) * duration }
                        .onEnded { gesture in
                            state.seek(to: min(1, max(0, Double(gesture.location.x / width))) * duration)
                            drag.position = nil
                        })
                }
                .frame(height: 18)
                Text("−" + Self.time(max(0, duration - current)))
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.62))
        }
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// Current sound output, for the icon on the right of the controls.
final class LockOutputRoute: ObservableObject {
    @Published private(set) var symbol = "speaker.wave.2.fill"
    @Published private(set) var name = "Динамики"

    func refresh() {
        guard let device = SystemVolume.defaultOutputDeviceID() else { return }
        let deviceName = SystemVolume.name(of: device)
        let deviceSymbol = SystemVolume.symbol(for: device, name: deviceName)
        if deviceName != name { name = deviceName }
        if deviceSymbol != symbol { symbol = deviceSymbol }
    }
}


// MARK: - 3.7.2 Artwork as the lock-screen wallpaper

// Fills the whole screen like the iPhone "album art" lock screen: the cover
// hugely blurred as the wallpaper, the cover itself large in the middle,
// an own clock and date at the top (the system ones may be hidden under it).
// The bottom fades out so the user picture and password field stay visible.
// Purely visual: the window never takes clicks or keyboard input.
struct LockCoverWallpaper: View {
    @ObservedObject var state: IslandState
    var loginHole = false     // 4.11.3: no longer used (kept for callers)
    @ObservedObject private var widgets = LockWidgetsModel.shared
    @ObservedObject private var display = SystemDisplayOptions.shared
    @AppStorage("lockCoverClockV372") private var showsClock = true
    // 3.8.4: share of the screen height taken by the cover (Settings).
    @AppStorage("lockCoverScaleV384") private var coverScale = 0.55
    // 3.9.4: the locked user's own picture, read fresh on every lock.
    @ObservedObject private var identity = LockUserIdentity.shared
    // 3.9.5: the blurred colours behind the cover move (Settings).
    @AppStorage("lockCoverAnimatedV395") private var animatedBackground = true
    // 3.10.1: nothing is drawn while the wallpaper is hidden.
    @ObservedObject private var activity = LockCoverActivity.shared

    // 3.8.1: the cover fits BETWEEN the widgets under the clock and the
    // player card, instead of being drawn over both (as in the screenshot).
    private func coverSlot(in size: CGSize) -> (center: CGFloat, side: CGFloat) {
        let h = size.height
        var top = h * 0.255                        // just under the clock
        if widgets.enabled && !widgets.items.isEmpty {
            top += (LockWidgetGeometry.height + 6) * CGFloat(widgets.scale)
        }
        top += 18
        let k = CGFloat(display.cardScale)
        let cardTopFromBottom = max(190, h * 0.235) + LockScreenMediaCard.size.height * k
        let bottom = h - cardTopFromBottom - 18
        let side = max(80, min(size.width * 0.34, bottom - top))
        return ((top + bottom) / 2, side)
    }

    var body: some View {
        if activity.active {
            visibleBody
        } else {
            Color.clear
        }
    }

    private var visibleBody: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if let image = state.musicArtwork {
                    // 3.9.5: living colours of the cover, slowly flowing like
                    // the full-screen player on the iPhone lock screen.
                    LivingArtworkBackground(image: image,
                                            animated: animatedBackground,
                                            playing: state.track?.isPlaying ?? false)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.28))
                } else {
                    LinearGradient(colors: [state.musicArtworkTint, Color.black],
                                   startPoint: .top, endPoint: .bottom)
                }

                // 3.8.2: the artwork itself IS the wallpaper — full screen
                // height, centred; its left and right edges melt into the
                // blurred colours, so the whole screen is the cover.
                if let image = state.musicArtwork {
                    let side = size.height * CGFloat(min(1, max(0.3, coverScale)))
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.045, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
                        .position(x: size.width / 2, y: size.height * Self.coverCenter)
                    // Gentle shading so the clock and the login stay readable.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.38), location: 0),
                        .init(color: .clear, location: 0.32),
                        .init(color: .clear, location: 0.62),
                        .init(color: .black.opacity(0.45), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }

                if showsClock {
                    TimelineView(.everyMinute) { context in
                        // 3.8.11: same places and sizes as the macOS 27 lock
                        // screen (measured on this Mac's recording).
                        ZStack {
                            Text(Self.date(context.date))
                                .font(.system(size: size.height * 0.025, weight: .semibold))
                                .position(x: size.width / 2, y: size.height * 0.1056)
                            Text(Self.time(context.date))
                                // 3.8.14: −20% — the real clock is 600 px wide
                                // on the recording, ours was 750 px.
                                .font(.system(size: size.height * 0.119, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .position(x: size.width / 2, y: size.height * 0.187)
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            // 3.8.5: the whole screen, no "window" onto the old wallpaper.
            // macOS draws the user list and password field UNDER this
            // window: they stay fully working (clicks and typing pass
            // through, Touch ID works) but are not visible — so a hint is
            // drawn where they are.
            .overlay(alignment: .bottom) {
                // 4.11.3: only the hint — no picture and no name. The real
                // macOS login is under this window: type the password or
                // touch Touch ID as always.
                Text("Touch ID или пароль")
                    .font(.system(size: max(11, size.height * 0.0128), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    .position(x: size.width / 2, y: size.height * 0.90)
                    .frame(width: size.width, height: size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
        .onAppear { identity.refresh() }
    }

    // Vertical centre of the cover (share of the screen height, from top).
    static let coverCenter: CGFloat = 0.5

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"     // as the macOS lock screen: 00:22
        return formatter.string(from: date)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EE d MMM"
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}


// 3.9.5 — the cover's colours as a slowly flowing background: three large
// copies of the artwork turn and drift past each other under a heavy blur.
// Drawn at 1/8 of the screen and scaled up (the blur hides the pixels), so
// it costs very little. Slower while paused; still with «Reduce motion».
final class LivingPhase: ObservableObject {
    private var last: Date?
    private(set) var value: Double = Double.random(in: 0...400)
    // 3.9.6: the speed itself glides to the new target (pause → slow,
    // play → normal) over about two seconds instead of switching at once.
    private var speed: Double?
    static let easing: Double = 0.7      // seconds; ~95% of the way in ≈2 s

    func advance(to date: Date, speed target: Double) -> Double {
        let current = speed ?? target
        if let last {
            let dt = min(0.1, max(0, date.timeIntervalSince(last)))
            let next = target + (current - target) * exp(-dt / Self.easing)
            // Average of the old and new speed over the step: no visible jolt.
            value += dt * (current + next) / 2
            speed = next
        } else {
            speed = target
        }
        last = date
        return value
    }
}

struct LivingArtworkBackground: View {
    let image: NSImage
    let animated: Bool
    let playing: Bool
    @StateObject private var phase = LivingPhase()

    private static let downscale: CGFloat = 8
    private var moving: Bool {
        animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving)) { context in
                let t = moving ? phase.advance(to: context.date, speed: playing ? 1 : 0.3) : phase.value
                layers(size: size, t: t)
            }
        }
    }

    private func layers(size: CGSize, t: Double) -> some View {
        let small = CGSize(width: size.width / Self.downscale * 1.3, height: size.height / Self.downscale * 1.3)
        let side = max(small.width, small.height)
        return ZStack {
            Color.black
            layer(side: side * 1.5, angle: t * 7, dx: sin(t * 0.21) * 0.16, dy: cos(t * 0.17) * 0.12,
                  scale: 1.0 + 0.10 * sin(t * 0.13), small: small, opacity: 1)
            layer(side: side * 1.1, angle: -t * 9 + 120, dx: cos(t * 0.19 + 1.3) * 0.22, dy: sin(t * 0.23 + 0.4) * 0.18,
                  scale: 1.0 + 0.14 * cos(t * 0.11), small: small, opacity: 0.8)
            layer(side: side * 0.8, angle: t * 12 + 240, dx: sin(t * 0.27 + 2.1) * 0.25, dy: cos(t * 0.15 + 2.7) * 0.22,
                  scale: 1.0 + 0.18 * sin(t * 0.17 + 1), small: small, opacity: 0.7)
        }
        .frame(width: small.width, height: small.height)
        .blur(radius: 9)
        .saturation(1.6)
        .drawingGroup()
        .scaleEffect(Self.downscale)
        .frame(width: size.width, height: size.height)
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

// The account picture and full name of the user whose session is locked —
// whoever is logged in, never a fixed picture. 3.9.4: read again every time
// the screen locks (and when the cover appears), so a new account picture
// from System Settings shows up at once instead of the one from app launch.
final class LockUserIdentity: ObservableObject {
    static let shared = LockUserIdentity()

    @Published private(set) var picture: NSImage?
    @Published private(set) var name: String
    private var loadedAt = Date.distantPast

    private init() {
        name = Self.currentName()
        picture = Self.currentPicture()
        loadedAt = Date()
    }

    // Cheap enough to call on every lock; never more than once per 2 s.
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(loadedAt) > 2 else { return }
        loadedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let picture = Self.currentPicture()
            let name = Self.currentName()
            DispatchQueue.main.async {
                self.picture = picture
                if self.name != name { self.name = name }
            }
        }
    }

    static func currentName() -> String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    // The same picture the macOS login window uses: the account record's
    // JPEGPhoto, then its Picture file, then the identity service.
    static func currentPicture() -> NSImage? {
        let user = NSUserName()
        if let record = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            .record(withRecordType: kODRecordTypeUsers, name: user,
                    attributes: [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture]) {
            if let values = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto) {
                for case let data as Data in values {
                    if let image = NSImage(data: data) { return image }
                }
            }
            if let values = try? record.values(forAttribute: kODAttributeTypePicture) {
                for case let path as String in values where FileManager.default.fileExists(atPath: path) {
                    if let image = NSImage(contentsOfFile: path) { return image }
                }
            }
        }
        return CBIdentity(name: user, authority: CBIdentityAuthority.local())?.image
    }
}
