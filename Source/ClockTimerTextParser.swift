import Foundation

// The Clock AX tree may publish a timer as mm:ss, hh:mm:ss or a localized
// phrase. Never infer seconds from UI labels unless an actual time is present.
enum ClockTimerTextParser {
    private static let colon = try! NSRegularExpression(
        pattern: "(?<![0-9])(?:([0-9]{1,2})\\s*:\\s*)?([0-9]{1,3})\\s*:\\s*([0-9]{2})(?![0-9])")
    private static let hour = try! NSRegularExpression(
        pattern: "(?i)(?<![0-9])([0-9]{1,3})\\s*(?:час(?:а|ов)?|ч|hours?|h)(?=[^\\p{L}]|$)")
    private static let minute = try! NSRegularExpression(
        pattern: "(?i)(?<![0-9])([0-9]{1,3})\\s*(?:мин(?:ут(?:а|ы)?)?|minutes?|mins?|min|m)(?=[^\\p{L}]|$)")
    private static let second = try! NSRegularExpression(
        pattern: "(?i)(?<![0-9])([0-9]{1,2})\\s*(?:сек(?:унд(?:а|ы)?)?|seconds?|secs?|sec|s)(?=[^\\p{L}]|$)")

    // Clock sometimes exposes digit groups as separate AXStaticText children
    // rather than a single time string. Join ONLY a tiny numeric sibling
    // cluster, never arbitrary page text or a collection of timer presets.
    static func remainingFromDigitSiblings(_ labels: [String]) -> TimeInterval? {
        let tokens = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard tokens.count >= 2 && tokens.count <= 5 else { return nil }
        let numbers = tokens.filter { $0 != ":" }
        guard (2...3).contains(numbers.count),
              numbers.allSatisfy({ $0.count > 0 && $0.count <= 2 && $0.allSatisfy(\.isNumber) }),
              tokens.allSatisfy({ $0 == ":" || ($0.count <= 2 && $0.allSatisfy(\.isNumber)) }) else {
            return nil
        }
        let candidate = numbers.joined(separator: ":")
        return remaining(in: candidate)
    }

    // Only a genuinely decreasing value at the SAME AX element is proof of
    // a running countdown. Static presets and the advancing wall clock are
    // not accepted as system timers.
    static func isDecreasingCountdown(previous: TimeInterval,
                                      current: TimeInterval,
                                      elapsed: TimeInterval) -> Bool {
        guard elapsed >= 0.7 && elapsed < 42 else { return false }
        let decrement = previous - current
        return decrement >= max(0.5, elapsed - 3) && decrement <= elapsed + 3
    }

    static func remaining(in text: String) -> TimeInterval? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = colon.firstMatch(in: text, range: range) {
            func number(_ index: Int) -> Int {
                guard match.range(at: index).location != NSNotFound else { return 0 }
                return Int(ns.substring(with: match.range(at: index))) ?? 0
            }
            let hasHours = match.range(at: 1).location != NSNotFound
            let hours = number(1), minutes = number(2), seconds = number(3)
            guard seconds < 60 && (!hasHours || minutes < 60) else { return nil }
            return TimeInterval(hours * 3600 + minutes * 60 + seconds)
        }
        func component(_ regex: NSRegularExpression) -> Int? {
            guard let match = regex.firstMatch(in: text, range: range) else { return nil }
            return Int(ns.substring(with: match.range(at: 1)))
        }
        // A vague label like "5 minutes" is not a live seconds-precision
        // reading; require a seconds field before extrapolating a deadline.
        guard let seconds = component(second), seconds < 60 else { return nil }
        let minutes = component(minute) ?? 0
        let hours = component(hour) ?? 0
        guard hours > 0 || minutes > 0 || seconds > 0 else { return nil }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }
}
