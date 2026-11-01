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

    private func tick() {
        let anyInput = CGEventType(rawValue: ~UInt32(0))!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if shown && idle < 1 { setShown(false) }
        else if !shown && idle >= StandBySettings.idleBeforeShow { setShown(true) }
    }

    private func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        show?(on)
        if on && StandBySettings.keepAwake && !hasAssertion {
            hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "Notch Island StandBy" as CFString, &assertion) == kIOReturnSuccess
        } else if !on && hasAssertion {
            IOPMAssertionRelease(assertion)
            hasAssertion = false
        }
    }
}

struct StandByView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var activity: LockCoverActivity
    @ObservedObject private var weather = WeatherService.shared
    @AppStorage(StandBySettings.nightKey) private var nightMode = true

    var body: some View {
        if activity.active {
            TimelineView(.everyMinute) { context in
                content(context.date)
            }
        } else {
            Color.clear
        }
    }

    private func content(_ now: Date) -> some View {
        let night = nightMode && StandBySettings.isNight(now)
        return GeometryReader { geometry in
            let size = geometry.size
            let h = size.height
            HStack(spacing: size.width * 0.04) {
                // The big clock.
                VStack(alignment: .leading, spacing: h * 0.01) {
                    Text(Self.format(now, "HH:mm"))
                        .font(.system(size: h * 0.36, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(Self.format(now, "EEEE, d MMMM").capitalizedFirst)
                        .font(.system(size: h * 0.045, weight: .semibold, design: .rounded))
                        .opacity(0.6)
                }
                .frame(width: size.width * 0.56, alignment: .leading)
                VStack(spacing: h * 0.035) {
                    chargingCard(h: h)
                    secondCard(h: h)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, size.width * 0.06)
            .frame(width: size.width, height: size.height)
            .foregroundStyle(.white)
            .background(Color.black)
            // Night: dim red, easy on the eyes in the dark.
            .colorMultiply(night ? Color(red: 1, green: 0.18, blue: 0.12) : .white)
            .opacity(night ? 0.6 : 1)
            .background(Color.black)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func card<Content: View>(h: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(h * 0.03)
            .frame(maxWidth: .infinity, minHeight: h * 0.3, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: h * 0.045, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private func chargingCard(h: CGFloat) -> some View {
        let percent = state.power?.percentage ?? 0
        let charging = state.power?.isCharging ?? false
        let green = Color(red: 0.25, green: 0.9, blue: 0.45)
        return card(h: h) {
            HStack(spacing: h * 0.03) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: h * 0.018)
                    Circle().trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(green, style: StrokeStyle(lineWidth: h * 0.018, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: h * 0.05, weight: .bold))
                        .foregroundStyle(green)
                }
                .frame(width: h * 0.17, height: h * 0.17)
                VStack(alignment: .leading, spacing: h * 0.005) {
                    Text("\(percent)%")
                        .font(.system(size: h * 0.075, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(percent >= 100 ? "Заряжено" : (charging ? "Заряжается" : "Подключено к питанию"))
                        .font(.system(size: h * 0.03, weight: .medium))
                        .opacity(0.6)
                }
            }
        }
    }

    @ViewBuilder
    private func secondCard(h: CGFloat) -> some View {
        if let track = state.track {
            card(h: h) {
                HStack(spacing: h * 0.03) {
                    Group {
                        if let art = state.musicArtwork {
                            Image(nsImage: art).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.12)
                                .overlay(Image(systemName: "music.note").font(.system(size: h * 0.05)))
                        }
                    }
                    .frame(width: h * 0.17, height: h * 0.17)
                    .clipShape(RoundedRectangle(cornerRadius: h * 0.025, style: .continuous))
                    VStack(alignment: .leading, spacing: h * 0.006) {
                        Text(track.title)
                            .font(.system(size: h * 0.04, weight: .bold, design: .rounded))
                        Text(track.artist)
                            .font(.system(size: h * 0.03, weight: .medium))
                            .opacity(0.6)
                        Image(systemName: track.isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: h * 0.03))
                            .foregroundStyle(state.musicArtworkTint)
                    }
                    .lineLimit(1)
                }
            }
        } else if let snapshot = weather.snapshot {
            card(h: h) {
                HStack(spacing: h * 0.03) {
                    Image(systemName: WeatherCodes.symbol(snapshot.code, night: IdleWingsView.isNight))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: h * 0.1))
                        .frame(width: h * 0.17)
                    VStack(alignment: .leading, spacing: h * 0.005) {
                        Text("\(snapshot.temperature)°")
                            .font(.system(size: h * 0.075, weight: .bold, design: .rounded))
                        Text(snapshot.place)
                            .font(.system(size: h * 0.03, weight: .medium))
                            .opacity(0.6)
                        if let low = snapshot.low, let high = snapshot.high {
                            Text("↓ \(low)° ↑ \(high)°")
                                .font(.system(size: h * 0.028, weight: .medium))
                                .opacity(0.5)
                        }
                    }
                    .lineLimit(1)
                }
            }
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
