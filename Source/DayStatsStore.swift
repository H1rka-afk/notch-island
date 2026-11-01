import Foundation
import CoreGraphics
import Combine

// 4.4.0 — keeps today's statistics and the last week. Counts every 30 s:
// time at the Mac (keyboard/mouse within the last minute) and time with
// music playing. Events (songs, eye breaks, timers…) are recorded by the
// app as they happen. Saved in the app's preferences only.
final class DayStatsStore: ObservableObject {
    static let shared = DayStatsStore()
    static let enabledKey = "dayStatsEnabledV440"
    private static let storageKey = "dayStatsV440"

    @Published private(set) var history: [DayStats] = []
    @Published private(set) var enabled: Bool

    var isLocked: (() -> Bool)?
    var isPlaying: (() -> Bool)?
    // Title + artist of what plays now; a song counts once it is heard.
    var currentTrack: (() -> String?)?
    private var lastCountedTrack: String?

    private var timer: Timer?
    private var lastTick = Date()
    private var dirty = false
    private var lastSave = Date.distantPast

    var today: DayStats {
        let key = DayStatsMath.dayKey(Date())
        return history.last(where: { $0.day == key }) ?? DayStats(day: key)
    }

    // The week as seven days, oldest first, with empty days filled in.
    var week: [DayStats] {
        let calendar = Calendar.current
        return (0..<DayStatsMath.keepDays).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            let key = DayStatsMath.dayKey(date)
            return history.first(where: { $0.day == key }) ?? DayStats(day: key)
        }
    }

    private init() {
        enabled = (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let list = try? JSONDecoder().decode([DayStats].self, from: data) {
            history = list
        }
        history = DayStatsMath.rolled(history, today: DayStatsMath.dayKey(Date()))
    }

    func start() {
        guard enabled, timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        tick()
        timer?.invalidate()
        timer = nil
        save(force: true)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        enabled = on
        on ? start() : stop()
    }

    func reset() {
        history = DayStatsMath.rolled([], today: DayStatsMath.dayKey(Date()))
        save(force: true)
    }

    func record(_ event: DayStatsEvent) {
        guard enabled else { return }
        update { DayStatsMath.record(event, in: $0) }
        save(force: false)
    }

    private func tick() {
        guard enabled else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        let anyInput = CGEventType(rawValue: ~UInt32(0))!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let locked = isLocked?() ?? false
        let playing = isPlaying?() ?? false
        update { DayStatsMath.tick($0, elapsed: elapsed, idle: idle, locked: locked, playing: playing) }
        if playing, let key = currentTrack?(), !key.isEmpty, key != lastCountedTrack {
            lastCountedTrack = key
            update { DayStatsMath.record(.track, in: $0) }
        }
        save(force: false)
    }

    private func update(_ change: (DayStats) -> DayStats) {
        var list = DayStatsMath.rolled(history, today: DayStatsMath.dayKey(Date()))
        list[list.count - 1] = change(list[list.count - 1])
        history = list
        dirty = true
    }

    private func save(force: Bool) {
        guard dirty || force else { return }
        guard force || Date().timeIntervalSince(lastSave) >= 60 else { return }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        dirty = false
        lastSave = Date()
    }
}
