import Foundation

// swiftc -parse-as-library Source/IslandWaveform.swift Tests/IslandWaveformTests.swift -o wf-tests && ./wf-tests
@main
struct IslandWaveformTests {
    typealias P = IslandWaveformPhysics

    static func run(_ physics: P, from start: Double, seconds: Double,
                    levels: [Double], playing: Bool, live: Bool) -> (min: Double, max: Double) {
        var low = Double.infinity, high = -Double.infinity
        var t = start
        while t < start + seconds {
            let heights = physics.step(to: t, targets: P.targets(levels: levels, time: t, playing: playing, live: live))
            low = min(low, heights.min()!); high = max(high, heights.max()!)
            t += 1.0 / 60.0
        }
        return (low, high)
    }

    static func main() {
        let loud = [Double](repeating: 0.8, count: 6)
        let silent = [Double](repeating: 0, count: 6)

        // Live loud music: bars go up and stay inside 0…1.
        let p = P()
        let a = run(p, from: 0, seconds: 1, levels: loud, playing: true, live: true)
        precondition(a.max > 0.6 && a.max <= 1.0 && a.min >= 0)

        // Fast attack: from a dot to most of the target within ~0.1 s.
        let q = P()
        _ = q.step(to: 0, targets: [1, 1, 1, 1, 1, 1])
        let up = q.step(to: 0.1, targets: [1, 1, 1, 1, 1, 1])
        precondition(up[0] > 0.9, "attack must be quick like iPhone")
        // Slower release: still visible 0.1 s after the sound stops.
        let down = q.step(to: 0.2, targets: [0, 0, 0, 0, 0, 0])
        precondition(down[0] > 0.3 && down[0] < 0.6)

        // Pause: everything sinks into dots within ~0.6 s.
        _ = run(p, from: 1, seconds: 0.9, levels: loud, playing: false, live: true)
        precondition(p.isSettled, "bars must settle on pause")

        // A band with no sound stays a dot while others move.
        let r = P()
        _ = run(r, from: 0, seconds: 0.5, levels: [0, 0, 0.7, 0.7, 0.7, 0.7], playing: true, live: true)
        precondition(r.heights[0] == 0 && r.heights[1] == 0 && r.heights[2] > 0.5)

        // Live silence: still dots.
        let s = P()
        let b = run(s, from: 0, seconds: 1, levels: silent, playing: true, live: true)
        precondition(b.max < 0.001)

        // Never above the target (no spring overshoot).
        let u = P()
        var t = 0.0
        while t < 3 {
            let target = P.targets(levels: silent, time: t, playing: true, live: false)
            let hs = u.step(to: t, targets: target)
            precondition(hs.allSatisfy { $0 <= 1.0 && $0 >= 0 })
            t += 1.0 / 60.0
        }

        // Synthetic track: the bass bar hits near the top on the kick and
        // drops between kicks; every bar moves.
        var bassHigh = 0.0, bassLow = 1.0
        for k in 0..<240 {
            let v = P.synthetic(0, Double(k) / 60)
            bassHigh = max(bassHigh, v); bassLow = min(bassLow, v)
        }
        precondition(bassHigh > 0.9 && bassLow < 0.35)
        let v = P()
        _ = run(v, from: 0, seconds: 0.5, levels: silent, playing: true, live: false)
        let c = run(v, from: 0.5, seconds: 3, levels: silent, playing: true, live: false)
        precondition(c.min > 0.05 && c.max - c.min > 0.4)

        // A long stall never explodes.
        let w = P()
        _ = w.step(to: 0, targets: loud)
        let h = w.step(to: 500, targets: loud)
        precondition(h.allSatisfy { $0.isFinite && $0 <= 1.0 })

        print("IslandWaveformTests: OK")
    }
}
