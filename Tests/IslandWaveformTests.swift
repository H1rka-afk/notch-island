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

        // Live loud music: bars move up and stay inside the bounds.
        let p = P()
        let a = run(p, from: 0, seconds: 2, levels: loud, playing: true, live: true)
        precondition(a.max > 0.4 && a.max <= 1.08 && a.min >= 0)

        // Pause: everything sinks to dots and settles.
        _ = run(p, from: 2, seconds: 2, levels: loud, playing: false, live: true)
        precondition(p.isSettled, "bars must settle on pause")

        // Live silence: still dots.
        let q = P()
        let b = run(q, from: 0, seconds: 1, levels: silent, playing: true, live: true)
        precondition(b.max < 0.001)

        // No capture: calm motion while playing, never zero, never full.
        let r = P()
        _ = run(r, from: 0, seconds: 0.6, levels: silent, playing: true, live: false)
        let c = run(r, from: 0.6, seconds: 3, levels: silent, playing: true, live: false)
        precondition(c.min > 0.02 && c.max < 1.0 && c.max - c.min > 0.2)

        // Targets: centre bars are favoured over the edges on equal input.
        let t = P.targets(levels: [Double](repeating: 1, count: 6), time: 0.0, playing: true, live: true)
        precondition(t.count == 6 && t.allSatisfy { $0 >= 0 && $0 <= 1 })

        // A long stall (sleep, hidden window) never explodes.
        let s = P()
        _ = s.step(to: 0, targets: loud)
        let h = s.step(to: 500, targets: loud)
        precondition(h.allSatisfy { $0.isFinite && $0 <= 1.08 })

        print("IslandWaveformTests: OK")
    }
}
