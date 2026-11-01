import Foundation

// 3.17.0 — the 20-20-20 rule: after 20 minutes of work, look at something
// about 6 metres (20 feet) away for 20 seconds. Pure counting (tested).
struct EyeBreakPolicy {
    static let workSeconds: TimeInterval = 20 * 60
    static let restSeconds = 20
    // Away from the Mac this long already rested the eyes: start over.
    static let naturalBreak: TimeInterval = 5 * 60
    // A key press or mouse move within the last minute = working.
    static let workingIdleLimit: TimeInterval = 60

    private(set) var worked: TimeInterval = 0

    // `elapsed` since the last check, `idle` since the last input.
    // Returns true when a reminder is due.
    mutating func tick(elapsed: TimeInterval, idle: TimeInterval) -> Bool {
        if idle >= Self.naturalBreak {
            worked = 0
            return false
        }
        if idle < Self.workingIdleLimit { worked += max(0, elapsed) }
        return worked >= Self.workSeconds
    }

    mutating func reset() { worked = 0 }

    // What the island shows at second `second` (0…restSeconds) of the break.
    static func banner(at second: Int) -> (text: String, level: Double) {
        let left = max(0, restSeconds - second)
        if second < 2 { return ("Вдаль", 1) }
        return ("\(left) с", Double(left) / Double(restSeconds))
    }
}
