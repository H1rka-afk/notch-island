import Foundation

// 4.5.1 — measured from a screen recording of iPhone's Dynamic Island:
// • six bars, each a frequency band, bass on the LEFT, treble on the right
//   (the left bar jumps to full height on every kick drum);
// • a bar shoots up within ~40 ms and falls back over ~0.15–0.25 s —
//   no springy bounce, no overshoot; loud bands simply hit the top;
// • bars without sound in their band stay round dots while others move;
// • all bars are centred on one line, edges are NOT made smaller;
// • on pause everything falls into dots in about 0.3 s.
// Without the system-audio capture a synthetic track with the same
// character plays: a kick in the bass bar, busier mids and highs.
final class IslandWaveformPhysics {
    static let barCount = 6

    private(set) var heights = [Double](repeating: 0, count: barCount)
    private var lastTime: Double?

    // Exponential followers (seconds): up fast, down slower.
    static let attackTime = 0.035
    static let releaseTime = 0.11

    var isSettled: Bool { heights.allSatisfy { $0 < 0.004 } }

    // Deterministic 0…1 noise for bar `i`, step `k`.
    static func noise(_ i: Int, _ k: Int) -> Double {
        var x = UInt64(bitPattern: Int64(k &* 7919 &+ i &* 104_729 &+ 17))
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 10_000) / 10_000
    }

    // Synthetic music for bar `i` at `t`: a kick drum at ~126 BPM in the
    // bass, offbeat hits in the low mids, quick random accents above.
    static func synthetic(_ i: Int, _ t: Double) -> Double {
        let beat = 60.0 / 126.0
        let sinceKick = t.truncatingRemainder(dividingBy: beat)
        let kick = exp(-sinceKick / 0.09)
        switch i {
        case 0:
            return min(1, 0.22 + 0.85 * kick)
        case 1:
            let sinceOff = (t + beat / 2).truncatingRemainder(dividingBy: beat)
            return min(1, 0.18 + 0.45 * exp(-sinceOff / 0.12) + 0.25 * noise(i, Int(t / 0.13)))
        default:
            let slot = 0.11 + 0.02 * Double(i)
            let k = Int(floor(t / slot))
            let accent = noise(i, k)
            let sinceSlot = t - Double(k) * slot
            return min(1, 0.2 + 0.7 * accent * exp(-sinceSlot / 0.16) + 0.15 * kick)
        }
    }

    // Where each bar wants to be at `time` (seconds).
    static func targets(levels: [Double], time t: Double, playing: Bool, live: Bool) -> [Double] {
        guard playing else { return [Double](repeating: 0, count: barCount) }
        return (0..<barCount).map { i in
            if live {
                let measured = i < levels.count && levels[i].isFinite ? min(1, max(0, levels[i])) : 0
                guard measured > 0.015 else { return 0 }   // nothing in this band: a dot
                // A little contrast: quiet bands lower, loud ones reach the top.
                return min(1, pow(measured, 1.25) * 1.12)
            }
            return synthetic(i, t)
        }
    }

    // Advances every bar to `time`; returns heights in 0…1.
    @discardableResult
    func step(to time: Double, targets: [Double]) -> [Double] {
        let previous = lastTime ?? time
        lastTime = time
        let dt = min(0.1, max(0, time - previous))   // ignore long stalls
        guard dt > 0 else { return heights }
        for i in 0..<Self.barCount {
            let target = min(1, max(0, i < targets.count ? targets[i] : 0))
            let tau = target > heights[i] ? Self.attackTime : Self.releaseTime
            heights[i] += (target - heights[i]) * (1 - exp(-dt / tau))
            if target == 0 && heights[i] < 0.003 { heights[i] = 0 }
        }
        return heights
    }
}
