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
        sound.volume = moment == .start ? 0.45 : 0.4
        sound.play()
    }
}
