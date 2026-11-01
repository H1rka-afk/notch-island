import Foundation

// 4.4.0 — statistics for the day. Pure data and arithmetic (tested): one
// record per calendar day, the last `keepDays` days are kept. Everything
// stays on this Mac.
struct DayStats: Codable, Equatable {
    var day: String                 // "yyyy-MM-dd" in the user's time zone
    var activeSeconds: Double = 0   // at the Mac: input within the last minute
    var musicSeconds: Double = 0    // something was playing
    var tracks = 0                  // songs that played for a while
    var eyeBreaks = 0               // 20-20-20 breaks completed
    var eyeSkipped = 0              // … and skipped
    var timers = 0                  // Clock timers seen
    var unlocks = 0                 // Mac unlocked
    var layoutFixes = 0             // ⌃⌥L
    var airdrops = 0                // files received or sent

    init(day: String) { self.day = day }

    // Older saved records may lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        musicSeconds = try c.decodeIfPresent(Double.self, forKey: .musicSeconds) ?? 0
        tracks = try c.decodeIfPresent(Int.self, forKey: .tracks) ?? 0
        eyeBreaks = try c.decodeIfPresent(Int.self, forKey: .eyeBreaks) ?? 0
        eyeSkipped = try c.decodeIfPresent(Int.self, forKey: .eyeSkipped) ?? 0
        timers = try c.decodeIfPresent(Int.self, forKey: .timers) ?? 0
        unlocks = try c.decodeIfPresent(Int.self, forKey: .unlocks) ?? 0
        layoutFixes = try c.decodeIfPresent(Int.self, forKey: .layoutFixes) ?? 0
        airdrops = try c.decodeIfPresent(Int.self, forKey: .airdrops) ?? 0
    }
}

enum DayStatsEvent: String {
    case track, eyeBreak, eyeSkipped, timer, unlock, layoutFix, airdrop
}

enum DayStatsMath {
    static let keepDays = 7
    // A gap longer than this between two ticks (sleep, App Nap) is not
    // counted as time at the Mac.
    static let maxTick: TimeInterval = 120
    static let workingIdleLimit: TimeInterval = 60

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // The history with today's record last; a new day starts a new record
    // and old days beyond `keepDays` are dropped.
    static func rolled(_ history: [DayStats], today: String) -> [DayStats] {
        var list = history.sorted { $0.day < $1.day }
        if list.last?.day != today { list.append(DayStats(day: today)) }
        return Array(list.suffix(keepDays))
    }

    static func tick(_ stats: DayStats, elapsed: TimeInterval, idle: TimeInterval,
                     locked: Bool, playing: Bool) -> DayStats {
        var s = stats
        let step = min(max(0, elapsed), maxTick)
        if !locked && idle < workingIdleLimit { s.activeSeconds += step }
        if playing { s.musicSeconds += step }
        return s
    }

    static func record(_ event: DayStatsEvent, in stats: DayStats) -> DayStats {
        var s = stats
        switch event {
        case .track: s.tracks += 1
        case .eyeBreak: s.eyeBreaks += 1
        case .eyeSkipped: s.eyeSkipped += 1
        case .timer: s.timers += 1
        case .unlock: s.unlocks += 1
        case .layoutFix: s.layoutFixes += 1
        case .airdrop: s.airdrops += 1
        }
        return s
    }

    // «3 ч 25 мин», «45 мин», «меньше минуты».
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "меньше минуты" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    // Short weekday for the chart: «пн», «вт»…
    static func weekday(_ dayKey: String, calendar: Calendar = .current) -> String {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return "" }
        let names = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
        return names[(calendar.component(.weekday, from: date) - 1) % 7]
    }

    // Russian plural: 1 трек, 2 трека, 5 треков.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }
}
