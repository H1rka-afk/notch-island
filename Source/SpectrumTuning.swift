import Foundation

// Five independent DSP controls. Values are intentionally separate from the
// SwiftUI view, and modifications never recreate the CoreAudio process tap.
struct SpectrumTuning: Equatable {
    var sensitivity: Double = 1.0
    var attack: Double = 1.0
    var release: Double = 1.0
    var bassBoost: Double = 1.0
    var noiseGate: Double = 1.0

    static let defaults = SpectrumTuning()

    private static let prefix = "spectrumTuning.v314."

    func validated() -> SpectrumTuning {
        func safe(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            guard value.isFinite else { return 1.0 }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        return SpectrumTuning(
            sensitivity: safe(sensitivity, 0.5...2.0),
            attack: safe(attack, 0.5...2.0),
            release: safe(release, 0.5...2.5),
            bassBoost: safe(bassBoost, 0.5...1.8),
            noiseGate: safe(noiseGate, 0.25...3.0)
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> SpectrumTuning {
        func read(_ key: String) -> Double {
            guard defaults.object(forKey: prefix + key) != nil else { return 1.0 }
            return defaults.double(forKey: prefix + key)
        }
        return SpectrumTuning(sensitivity: read("sensitivity"),
                              attack: read("attack"),
                              release: read("release"),
                              bassBoost: read("bassBoost"),
                              noiseGate: read("noiseGate")).validated()
    }

    func save(to defaults: UserDefaults = .standard) {
        let value = validated()
        defaults.set(value.sensitivity, forKey: Self.prefix + "sensitivity")
        defaults.set(value.attack, forKey: Self.prefix + "attack")
        defaults.set(value.release, forKey: Self.prefix + "release")
        defaults.set(value.bassBoost, forKey: Self.prefix + "bassBoost")
        defaults.set(value.noiseGate, forKey: Self.prefix + "noiseGate")
    }

    // A separate gate avoids animating noise in otherwise silent audio.
    // No minimum synthetic movement is added: absolute silence remains still.
    func amplitude(rms: Double, peak: Double, band: Int) -> Double {
        let value = validated()
        guard rms.isFinite, peak.isFinite, rms > 0.00006 * value.noiseGate else { return 0 }
        let bassWeight = band == 0 ? value.bassBoost :
                         (band == 1 ? (1 + (value.bassBoost - 1) * 0.25) : 1)
        let normalized = max(0, rms) / (max(0.003, peak) * 1.15)
        return min(1, max(0, pow(normalized, 0.82) * value.sensitivity * bassWeight))
    }

    // Maintains the current release/attack behavior at the defaults (0.78/0.17
    // per presentation frame), with bounded real-time adjustment.
    func smoothingCoefficient(rising: Bool) -> Double {
        let value = validated()
        if rising { return 1 - pow(1 - 0.78, value.attack) }
        return 1 - pow(1 - 0.17, 1 / value.release)
    }
}
