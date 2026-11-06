import AppKit
import SwiftUI
import IOKit.pwr_mgt

// 4.0.0 — StandBy, like iPhone on a charger: when the Mac is locked, on
// power and nobody touches it for a while, the whole screen becomes a big
// clock with charging and the music or weather. Any key or mouse move brings
// back the normal lock screen at once (the password is never typed blind).
// At night everything turns dim red, as on iPhone.
enum StandBySettings {
    static let enabledKey = "standbyV400"
    static let keepAwakeKey = "standbyKeepAwakeV400"
    static let nightKey = "standbyNightV400"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
    static var keepAwake: Bool { (UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool) ?? true }
    static var nightMode: Bool { (UserDefaults.standard.object(forKey: nightKey) as? Bool) ?? true }
    // 4.5.3: the colour of the clock and text, «r,g,b» (0…1). Default: the
    // warm grey-beige of iPhone StandBy.
    static let textColorKey = "standbyTextColorV453"
    static let defaultTextColor = PaletteRGB(r: 0.67, g: 0.63, b: 0.59)
    static func decode(_ raw: String) -> PaletteRGB {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...1).contains($0) }) else { return defaultTextColor }
        return PaletteRGB(r: parts[0], g: parts[1], b: parts[2])
    }
    static func encode(_ c: PaletteRGB) -> String {
        String(format: "%.4f,%.4f,%.4f", min(1, max(0, c.r)), min(1, max(0, c.g)), min(1, max(0, c.b)))
    }
    static var textColor: PaletteRGB {
        decode(UserDefaults.standard.string(forKey: textColorKey) ?? "")
    }
    static let idleBeforeShow: TimeInterval = 20

    static func isNight(_ date: Date = Date()) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }
}

// Decides when StandBy is on; asks the display to stay awake meanwhile.
final class StandByController {
    var show: ((Bool) -> Void)?
    private var timer: Timer?
    private(set) var shown = false
    private var assertion: IOPMAssertionID = 0
    private var hasAssertion = false

    // Called on lock, unlock and power changes.
    func update(locked: Bool, onPower: Bool) {
        if locked && onPower && StandBySettings.isEnabled {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            setShown(false)
        }
    }

    // 4.1.0: StandBy is left by a click (see StandByView) — moving the mouse
    // does nothing. A key press also leaves it at once, so the password is
    // never typed into the hidden login field blindly.
    private func tick() {
        if shown {
            let keys = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            if keys < 1 { setShown(false) }
        } else {
            let anyInput = CGEventType(rawValue: ~UInt32(0))!
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            if idle >= StandBySettings.idleBeforeShow { setShown(true) }
        }
    }

    // A click on StandBy (outside the open music island).
    func userDismissed() { setShown(false) }

    private func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        show?(on)
        if on && StandBySettings.keepAwake && !hasAssertion {
            hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "Ovira StandBy" as CFString, &assertion) == kIOReturnSuccess
        } else if !on && hasAssertion {
            IOPMAssertionRelease(assertion)
            hasAssertion = false
        }
    }
}

// 4.1.0: the look of iPhone StandBy — a huge condensed clock in a warm tint
// on black, the day and the temperature at the top right. Music lives in a
// small island at the top that opens into a player. A click anywhere leaves
// StandBy; clicks inside the open island do not.
final class StandByUIState: ObservableObject {
    @Published var islandExpanded = false
}

struct StandByView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var activity: LockCoverActivity
    var onDismiss: () -> Void = {}
    @ObservedObject private var weather = WeatherService.shared
    @StateObject private var ui = StandByUIState()
    @AppStorage(StandBySettings.nightKey) private var nightMode = true
    @AppStorage(StandBySettings.textColorKey) private var textColorRaw = ""

    // 4.5.3: chosen in Settings; the warm grey-beige of iPhone by default.
    private var tint: Color { StandBySettings.decode(textColorRaw).color }

    var body: some View {
        if activity.active {
            TimelineView(.everyMinute) { context in
                content(context.date)
            }
            .onDisappear { ui.islandExpanded = false }
            // The temperature: fetched if there is none yet (no location prompt).
            .onAppear { WeatherService.shared.refreshIfNeeded(allowPrompt: false) {} }
        } else {
            Color.clear
        }
    }

    private func content(_ now: Date) -> some View {
        let night = nightMode && StandBySettings.isNight(now)
        return GeometryReader { geometry in
            let size = geometry.size
            let h = size.height
            ZStack(alignment: .top) {
                Color.black
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if ui.islandExpanded {
                            withAnimation(IslandMotion.surface) { ui.islandExpanded = false }
                        } else {
                            onDismiss()
                        }
                    }
                // 4.1.1: smaller, centred clock; the day and the temperature
                // sit at its top right, as on iPhone.
                HStack(alignment: .top, spacing: size.width * 0.035) {
                    Text(Self.format(now, "HH:mm"))
                        .font(.system(size: h * 0.6, weight: .semibold))
                        .fontWidth(.compressed)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: h * 0.008) {
                        (Text(Self.format(now, "EE").uppercased()).foregroundColor(tint)
                            + Text(", \(Calendar.current.component(.day, from: now))").foregroundColor(.white))
                        Text(weather.snapshot.map { "\($0.temperature) °C" } ?? "— °C")
                            .foregroundStyle(.white)
                            .opacity(weather.snapshot == nil ? 0.4 : 1)
                    }
                    .font(.system(size: h * 0.052, weight: .bold, design: .rounded))
                    .fixedSize()
                    .padding(.top, h * 0.075)
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                if state.track != nil {
                    musicIsland(h: h, width: size.width)
                        .padding(.top, max(44, h * 0.05))
                }
            }
            .frame(width: size.width, height: size.height)
            // Night: dim red, easy on the eyes in the dark.
            .colorMultiply(night ? Color(red: 1, green: 0.2, blue: 0.14) : .white)
            .opacity(night ? 0.62 : 1)
            .background(Color.black)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    // Compact: cover and waveform; tap → the player. Clicks inside the open
    // player never leave StandBy.
    private func musicIsland(h: CGFloat, width: CGFloat) -> some View {
        let expanded = ui.islandExpanded
        let shape = RoundedRectangle(cornerRadius: expanded ? 34 : 22, style: .continuous)
        return Group {
            if expanded { expandedPlayer } else { compactPlayer }
        }
        .padding(.horizontal, expanded ? 22 : 12)
        .padding(.vertical, expanded ? 20 : 8)
        .frame(width: expanded ? min(width * 0.42, 460) : 230)
        .background(shape.fill(Color(white: 0.07)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .contentShape(shape)
        .onTapGesture {
            withAnimation(IslandMotion.surface) { ui.islandExpanded.toggle() }
        }
        .animation(IslandMotion.surface, value: expanded)
    }

    private var cover: some View {
        Group {
            if let art = state.musicArtwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.12).overlay(Image(systemName: "music.note").foregroundStyle(.white))
            }
        }
    }

    private var compactPlayer: some View {
        HStack(spacing: 10) {
            cover.frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(state.track?.title ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: state.track?.isPlaying == true ? "waveform" : "pause.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.musicArtworkTint)
                .symbolEffect(.variableColor.iterative, isActive: state.track?.isPlaying == true)
        }
    }

    private var expandedPlayer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                cover.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.track?.title ?? "")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(state.track?.artist ?? "")
                        .font(.system(size: 14))
                        .opacity(0.65)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 40) {
                Button { state.command(.previous) } label: { Image(systemName: "backward.fill").font(.system(size: 24)) }
                Button { state.command(.toggle) } label: {
                    Image(systemName: state.track?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 34))
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { state.command(.next) } label: { Image(systemName: "forward.fill").font(.system(size: 24)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
