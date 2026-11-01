import Foundation

func assertNear(_ a: Double, _ b: Double, _ label: String, tolerance: Double = 0.0000001) {
    precondition(abs(a - b) < tolerance, "\(label): \(a) != \(b)")
}

@main
struct SpectrumTuningTests {
    static func main() {
        let original = SpectrumTuning.defaults
        assertNear(original.smoothingCoefficient(rising: true), 0.78, "default attack")
        assertNear(original.smoothingCoefficient(rising: false), 0.17, "default release")
        precondition(original.amplitude(rms: 0, peak: 0.1, band: 0) == 0)
        precondition(original.amplitude(rms: 0.00002, peak: 0.1, band: 0) == 0)
        let testRms = 0.002
        let peak = 0.01
        let standard = original.amplitude(rms: testRms, peak: peak, band: 3)
        var adjusted = original
        adjusted.sensitivity = 1.8
        precondition(adjusted.amplitude(rms: testRms, peak: peak, band: 3) > standard)
        adjusted = original
        adjusted.attack = 1.8
        precondition(adjusted.smoothingCoefficient(rising: true) > 0.78)
        adjusted.attack = 0.5
        precondition(adjusted.smoothingCoefficient(rising: true) < 0.78)
        adjusted = original
        adjusted.release = 2.4
        precondition(adjusted.smoothingCoefficient(rising: false) < 0.17)
        adjusted.release = 0.5
        precondition(adjusted.smoothingCoefficient(rising: false) > 0.17)
        adjusted = original
        adjusted.bassBoost = 1.7
        precondition(adjusted.amplitude(rms: testRms, peak: peak, band: 0) > standard)
        assertNear(adjusted.amplitude(rms: testRms, peak: peak, band: 3), standard, "upper band not boosted")
        adjusted = original
        adjusted.noiseGate = 3.0
        precondition(adjusted.amplitude(rms: 0.0001, peak: peak, band: 2) == 0)
        adjusted.noiseGate = 0.25
        precondition(adjusted.amplitude(rms: 0.0001, peak: peak, band: 2) > 0)
        let suite = "notchisland.spectrum.tests.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        precondition(SpectrumTuning.load(from: ud) == original)
        adjusted = SpectrumTuning(sensitivity: 1.7, attack: 1.6, release: 1.2, bassBoost: 1.4, noiseGate: 2.0)
        adjusted.save(to: ud)
        precondition(SpectrumTuning.load(from: ud) == adjusted)
        adjusted = SpectrumTuning(sensitivity: .infinity, attack: -10, release: 500, bassBoost: -.infinity, noiseGate: 0)
        let safe = adjusted.validated()
        precondition(safe.sensitivity == 1 && safe.attack == 0.5 && safe.release == 2.5)
        precondition(safe.bassBoost == 1 && safe.noiseGate == 0.25)
        for k in 0..<6 {
            for rms in [0, 0.00001, 0.001, 0.1] {
                let x = original.amplitude(rms: rms, peak: 0.003, band: k)
                precondition(x.isFinite && (0...1).contains(x))
            }
        }
        print("Spectrum tuning: 19 DSP/persistence checks passed")
    }
}
