import Foundation
import CoreGraphics
import AppKit

// 3.17.0 — counts active time at the Mac (keyboard / mouse / trackpad input)
// and asks for a 20-second look into the distance every 20 minutes. Never
// during a call (camera or microphone in use) or on the lock screen — then
// the reminder waits for the next check.
final class EyeBreakWatch {
    var onRemind: (() -> Void)?
    var canRemindNow: (() -> Bool)?

    private var timer: Timer?
    private var policy = EyeBreakPolicy()
    private var lastCheck = Date()
    private static let interval: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        policy.reset()
        lastCheck = Date()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        policy.reset()
    }

    private func check() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCheck)
        lastCheck = now
        let anyInput = CGEventType(rawValue: ~UInt32(0))!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard policy.tick(elapsed: elapsed, idle: idle) else { return }
        guard canRemindNow?() ?? true else { return }      // try again in 30 s
        policy.reset()
        onRemind?()
    }
}

// 4.6.1 — a short, soft sound when the break starts and when it ends
// (macOS system sounds, quieter than an alert). Switchable in Settings.
enum EyeBreakSound {
    enum Moment { case start, end }
    static let key = "eyeBreakSoundV461"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }

    // 4.13.0: loaded once, ahead of time — reading the sound file at the
    // moment of the break held the island for ~0.1 s as the banner opened.
    private static var cache: [String: NSSound] = [:]

    static func preload() {
        for name in ["Purr", "Glass"] where cache[name] == nil {
            cache[name] = NSSound(named: NSSound.Name(name))
        }
    }

    static func play(_ moment: Moment) {
        guard isEnabled else { return }
        let name = moment == .start ? "Purr" : "Glass"
        if cache[name] == nil { preload() }
        guard let sound = cache[name]?.copy() as? NSSound else { return }
        let base: Float = moment == .start ? 0.45 : 0.4
        // 4.14.6: music and video get quieter while the sound plays; the
        // sound itself is raised by the same amount, so it is heard exactly
        // as loud as before.
        if VolumeDuck.isEnabled, VolumeDuck.duck(for: sound.duration) {
            sound.volume = min(1, base / VolumeDuck.factor)
            DispatchQueue.main.asyncAfter(deadline: .now() + VolumeDuck.rampDown) { sound.play() }
        } else {
            sound.volume = base
            sound.play()
        }
    }
}

// 4.14.6 — «ducking»: macOS has no volume per app, so the whole output is
// lowered for the length of the break sound and then put back. If the
// volume was changed by hand meanwhile, it is left as the user set it.
enum VolumeDuck {
    static let key = "eyeBreakDuckV4146"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }
    static let factor: Float = 0.45
    static let rampDown: Double = 0.15
    static let rampUp: Double = 0.45
    // True while Ovira itself moves the volume — the volume banner stays away.
    private(set) static var isDucking = false
    private static var token = UUID()

    @discardableResult
    static func duck(for seconds: Double) -> Bool {
        guard !isDucking, let start = SystemVolume.current(), start > 0.02, !SystemVolume.isMuted() else { return false }
        let current = UUID()
        token = current
        isDucking = true
        let low = start * factor
        ramp(from: start, to: low, over: rampDown)
        DispatchQueue.main.asyncAfter(deadline: .now() + rampDown + seconds + 0.15) {
            guard token == current else { return }
            if let now = SystemVolume.current(), abs(now - low) < 0.04 {
                ramp(from: low, to: start, over: rampUp)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + rampUp + 0.35) {
                if token == current { isDucking = false }
            }
        }
        return true
    }

    private static func ramp(from a: Float, to b: Float, over duration: Double) {
        let steps = 10
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let eased = t * t * (3 - 2 * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) {
                SystemVolume.set(a + (b - a) * eased)
            }
        }
    }
}
