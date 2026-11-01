import Foundation

/// One alert per threshold on a downward discharge. A reading can jump past
/// several thresholds between IOKit notifications: only the lowest reached
/// threshold should be delivered, and all higher ones are considered passed.
struct LowBatteryWarningTracker {
    static let thresholds = [20, 10, 5, 1]

    /// The next *lower* threshold, not the one currently being displayed.
    static func nextThreshold(below percentage: Int) -> Int? {
        thresholds.first { percentage > $0 }
    }

    private var previousPercentage: Int?
    private var previousOnACPower: Bool?
    private var delivered = Set<Int>()

    /// Returns the deepest newly reached threshold, or nil. An initial
    /// reading already below a threshold is eligible, provided that the
    /// same threshold has not previously been delivered on this discharge.
    mutating func observe(percentage: Int, onACPower: Bool) -> Int? {
        let current = min(100, max(0, percentage))
        let oldPercentage = previousPercentage
        let oldOnACPower = previousOnACPower
        previousPercentage = current
        previousOnACPower = onACPower

        // A threshold can rearm only after recovering at least 2 percentage
        // points above it; cable bouncing at 10% cannot replay the 20% alert.
        for threshold in Self.thresholds where current >= threshold + 2 {
            delivered.remove(threshold)
        }
        guard !onACPower else { return nil }

        let startingOnBattery = oldPercentage == nil || oldOnACPower == true
        let reached = Self.thresholds.filter { current <= $0 }
        guard let deepest = reached.min() else { return nil }

        if startingOnBattery {
            // If an alert for 10% has already been delivered, unplugging
            // again at 10% must NOT resurrect an undelivered 20% alert.
            let shouldWarn = !delivered.contains(deepest)
            delivered.formUnion(reached)
            return shouldWarn ? deepest : nil
        }

        let crossed = reached.filter { threshold in
            !delivered.contains(threshold) && (oldPercentage ?? current) > threshold
        }
        guard let alert = crossed.min() else { return nil }
        // Skip all higher reached levels if IOKit jumped across several.
        delivered.formUnion(reached.filter { $0 >= alert })
        return alert
    }
}
