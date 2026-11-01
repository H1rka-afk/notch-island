import Foundation

// 3.5.1 — the music waveform behaves like the Dynamic Island on iPhone:
// • every bar is a small spring — it overshoots a little and settles, so the
//   motion is fluid instead of jumping from one analyser value to the next;
// • bars "breathe" independently around the real loudness, so even a steady
//   sound looks alive, centre bars a little taller than the edges;
// • on pause the bars sink into round dots; on play they spring back up;
// • without the system-audio capture the bars still move with a calm,
//   music-like rhythm (as on iPhone, where no permission is needed).
//   With capture on, real silence keeps them as still dots.
final class IslandWaveformPhysics {
    static let barCount = 6

    private(set) var heights = [Double](repeating: 0, count: barCount)
    private var velocity = [Double](repeating: 0, count: barCount)
    private var lastTime: Double?

    // Spring: quick, with a slight bounce (damping ratio ≈ 0.52).
    static let stiffness = 260.0
    static let damping = 2 * sqrt(stiffness) * 0.52

    private static let speeds: [Double] = [5.1, 6.7, 4.6, 7.3, 5.8, 4.2]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 0.6, 2.4, 4.2]
    private static let envelope: [Double] = [0.74, 0.9, 1.0, 1.0, 0.9, 0.74]

    var isSettled: Bool {
        heights.allSatisfy { abs($0) < 0.004 } && velocity.allSatisfy { abs($0) < 0.01 }
    }

    // Where each bar wants to be at `time` (seconds).
    static func targets(levels: [Double], time t: Double, playing: Bool, live: Bool) -> [Double] {
        guard playing else { return [Double](repeating: 0, count: barCount) }
        return (0..<barCount).map { i in
            let breathe = 0.5 + 0.5 * sin(t * speeds[i] + phases[i])
            let level: Double
            if live {
                let measured = i < levels.count && levels[i].isFinite ? min(1, max(0, levels[i])) : 0
                guard measured > 0.015 else { return 0 }   // true silence: still dots
                level = measured * (0.68 + 0.32 * breathe)
            } else {
                // Two slow waves per bar + a shared "beat" ≈ 2 Hz.
                let beat = 0.5 + 0.5 * sin(t * 12.4)
                let wave = 0.38
                    + 0.22 * sin(t * speeds[i] * 0.83 + phases[i])
                    + 0.14 * sin(t * speeds[(i + 2) % barCount] * 1.37 + phases[i] * 2.1)
                    + 0.12 * beat
                level = min(0.95, max(0.08, wave))
            }
            return min(1, level * envelope[i])
        }
    }

    // Advances every spring to `time`; returns heights in 0…~1.08.
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
                if heights[i] > 1.08 { heights[i] = 1.08; velocity[i] = min(0, velocity[i]) }
            }
        }
        return heights
    }
}
