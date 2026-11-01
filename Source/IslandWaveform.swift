import Foundation

// 4.5.0 — behaves like the Now Playing waveform on iPhone:
// • each bar drifts smoothly between random heights (a new height every
//   quarter of a second, bars out of step with each other) — no springy
//   bounce, no jitter;
// • the outer bars stay lower than the middle ones;
// • with the system-audio capture on, loudness scales the whole wave (quiet
//   passages are low, loud ones high) and real silence leaves still dots;
// • on pause the bars glide down into round dots, on play they glide up.
final class IslandWaveformPhysics {
    static let barCount = 6

    private(set) var heights = [Double](repeating: 0, count: barCount)
    private var velocity = [Double](repeating: 0, count: barCount)
    private var lastTime: Double?

    // Critically damped: follows the target smoothly, never overshoots.
    static let stiffness = 150.0
    static let damping = 2 * sqrt(stiffness)

    // A new random height per bar this often (seconds).
    static let slot = 0.26
    private static let offsets: [Double] = [0.0, 0.41, 0.77, 0.19, 0.58, 0.93]
    private static let envelope: [Double] = [0.62, 0.86, 1.0, 1.0, 0.86, 0.62]

    var isSettled: Bool {
        heights.allSatisfy { abs($0) < 0.004 } && velocity.allSatisfy { abs($0) < 0.01 }
    }

    // Deterministic 0…1 noise for bar `i`, step `k`.
    static func noise(_ i: Int, _ k: Int) -> Double {
        var x = UInt64(bitPattern: Int64(k &* 7919 &+ i &* 104_729 &+ 17))
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 10_000) / 10_000
    }

    // Smooth random walk: eases from one random height to the next.
    static func pattern(_ i: Int, _ t: Double) -> Double {
        let position = t / slot + offsets[i % offsets.count]
        let k = Int(floor(position))
        let f = position - floor(position)
        let eased = f * f * (3 - 2 * f)
        let a = noise(i, k), b = noise(i, k + 1)
        return a + (b - a) * eased
    }

    // Where each bar wants to be at `time` (seconds).
    static func targets(levels: [Double], time t: Double, playing: Bool, live: Bool) -> [Double] {
        guard playing else { return [Double](repeating: 0, count: barCount) }
        var loudness = 1.0
        var measured = [Double](repeating: 0, count: barCount)
        if live {
            let clean = levels.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
            let average = clean.isEmpty ? 0 : clean.reduce(0, +) / Double(clean.count)
            guard (clean.max() ?? 0) > 0.015 else { return [Double](repeating: 0, count: barCount) }
            loudness = 0.4 + 0.6 * min(1, average * 1.5)
            for i in 0..<barCount where i < clean.count { measured[i] = clean[i] }
        }
        return (0..<barCount).map { i in
            let wave = 0.24 + 0.72 * pattern(i, t)
            let level = live ? (0.78 * wave + 0.22 * measured[i]) * loudness : wave
            return min(1, max(0, level * envelope[i]))
        }
    }

    // Advances every bar to `time`; returns heights in 0…1.
    @discardableResult
    func step(to time: Double, targets: [Double]) -> [Double] {
        let previous = lastTime ?? time
        lastTime = time
        var remaining = min(0.1, max(0, time - previous))   // ignore long stalls
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 120.0)
            remaining -= dt
            for i in 0..<Self.barCount {
                let target = i < targets.count ? targets[i] : 0
                let force = Self.stiffness * (target - heights[i]) - Self.damping * velocity[i]
                velocity[i] += force * dt
                heights[i] += velocity[i] * dt
                if heights[i] < 0 { heights[i] = 0; velocity[i] = max(0, velocity[i]) }
                if heights[i] > 1 { heights[i] = 1; velocity[i] = min(0, velocity[i]) }
            }
        }
        return heights
    }
}
