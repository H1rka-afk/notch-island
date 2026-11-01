import Foundation

@main
struct DayStatsTests {
    static func main() {
        var s = DayStats(day: "2026-11-01")
        s = DayStatsMath.tick(s, elapsed: 30, idle: 5, locked: false, playing: true)
        precondition(s.activeSeconds == 30 && s.musicSeconds == 30)
        // Idle or locked: no time at the Mac, music still counts.
        s = DayStatsMath.tick(s, elapsed: 30, idle: 90, locked: false, playing: true)
        s = DayStatsMath.tick(s, elapsed: 30, idle: 1, locked: true, playing: false)
        precondition(s.activeSeconds == 30 && s.musicSeconds == 60)
        // Sleep gaps are capped.
        s = DayStatsMath.tick(s, elapsed: 3600, idle: 1, locked: false, playing: false)
        precondition(s.activeSeconds == 30 + DayStatsMath.maxTick)

        s = DayStatsMath.record(.track, in: s)
        s = DayStatsMath.record(.eyeBreak, in: s)
        s = DayStatsMath.record(.eyeSkipped, in: s)
        precondition(s.tracks == 1 && s.eyeBreaks == 1 && s.eyeSkipped == 1)

        // Rolling: a new day appends, at most a week is kept.
        var history = (1...7).map { DayStats(day: String(format: "2026-10-%02d", $0)) }
        history = DayStatsMath.rolled(history, today: "2026-10-08")
        precondition(history.count == 7 && history.first?.day == "2026-10-02" && history.last?.day == "2026-10-08")
        precondition(DayStatsMath.rolled(history, today: "2026-10-08").count == 7)

        precondition(DayStatsMath.duration(20) == "меньше минуты")
        precondition(DayStatsMath.duration(45 * 60) == "45 мин")
        precondition(DayStatsMath.duration(3 * 3600) == "3 ч")
        precondition(DayStatsMath.duration(3 * 3600 + 25 * 60) == "3 ч 25 мин")
        precondition(DayStatsMath.plural(1, "трек", "трека", "треков") == "трек")
        precondition(DayStatsMath.plural(3, "трек", "трека", "треков") == "трека")
        precondition(DayStatsMath.plural(12, "трек", "трека", "треков") == "треков")
        precondition(DayStatsMath.plural(21, "трек", "трека", "треков") == "трек")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Europe/Moscow")!
        precondition(DayStatsMath.weekday("2026-11-01", calendar: gregorian) == "вс")

        // Old records without new fields still decode.
        let old = #"[{"day":"2026-10-30","activeSeconds":120}]"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode([DayStats].self, from: old)
        precondition(decoded.first?.activeSeconds == 120 && decoded.first?.tracks == 0)
        print("DayStatsTests: OK")
    }
}
