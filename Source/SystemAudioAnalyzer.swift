import AppKit
import CoreAudio
import AudioToolbox
import Foundation

// Core Audio *process tap* (macOS 14.2+) uses the System Audio Recording
// permission only. This never captures the desktop image, accesses the
// microphone, stores PCM, or sends PCM to a server.
//
// Core Audio delivers a copy of the system output. We calculate six
// approximate frequency bands directly in memory and discard the samples.
final class SystemAudioAnalyzer {
    var onLevels: (([CGFloat]) -> Void)?
    var onStatus: ((String) -> Void)?

    private let controlQueue = DispatchQueue(label: "app.notchisland.tap.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "app.notchisland.tap.io", qos: .userInitiated)
    private let emptyLevels = [CGFloat](repeating: 0, count: 6)

    // Touched on controlQueue only, except for audio filter state (ioQueue).
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var isStarted = false
    private var sampleRate: Double = 48_000
    private var serial = 0

    // Touched only by the serial IOProc callback queue.
    private var lowpass = [Double](repeating: 0, count: 12)
    private var smoothLevels = [Double](repeating: 0, count: 6)
    private var targetLevels = [Double](repeating: 0, count: 6)
    private var peaks = [Double](repeating: 0.004, count: 6)
    private var lastPresentation = Date.distantPast
    private var receivedSound = false
    private var coefficientRate: Double = 0
    private var filterCoefficients = [Double](repeating: 0, count: 6)
    private var lastLevelsSent = [CGFloat](repeating: 0, count: 6)
    // Written and read only on ioQueue; sliders do not restart the audio tap.
    private var tuning = SpectrumTuning.load()

    func updateTuning(_ settings: SpectrumTuning) {
        let validated = settings.validated()
        ioQueue.async { [weak self] in self?.tuning = validated }
    }

    private func status(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(value) }
    }

    func start() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isStarted else { return }
            self.openTap()
        }
    }

    func restart() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.closeTap()
            self.openTap()
        }
    }

    func stop() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.closeTap()
            self.status("Выключена")
            DispatchQueue.main.async { [weak self] in self?.onLevels?(self?.emptyLevels ?? []) }
        }
    }

    private func openTap() {
        guard #available(macOS 14.2, *) else {
            status("Нужна macOS 14.2 или новее")
            return
        }
        status("Подключение Core Audio…")

        // Global stereo output, without muting what the user hears.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Ovira Visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMono = false

        let result = AudioHardwareCreateProcessTap(description, &tapID)
        guard result == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            status("Не удалось создать аудиотап (код \(result))")
            closeTap()
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var audioFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &formatSize, &audioFormat) == noErr,
           audioFormat.mSampleRate > 0 {
            sampleRate = audioFormat.mSampleRate
        }
        // The system tap provides 32-bit PCM float samples. Never interpret
        // an unexpected format as floats (would produce meaningless bars).
        guard audioFormat.mFormatID == kAudioFormatLinearPCM,
              (audioFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              audioFormat.mBitsPerChannel == 32 else {
            status("Формат системного звука не поддерживается")
            closeTap()
            return
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ovira Audio Analysis",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        let deviceError = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard deviceError == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            status("Ошибка аудиоустройства (код \(deviceError))")
            closeTap()
            return
        }

        // Apple calls this block with an AudioBufferList. Dispatch processing
        // to an isolated serial queue; never write samples to disk.
        let ioError = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        guard ioError == noErr, ioProc != nil else {
            status("Ошибка потока аудио (код \(ioError))")
            closeTap()
            return
        }
        let startError = AudioDeviceStart(aggregateID, ioProc)
        guard startError == noErr else {
            status("Ошибка запуска аудио (код \(startError))")
            closeTap()
            return
        }
        isStarted = true
        serial &+= 1
        let token = serial
        ioQueue.async { [weak self] in
            self?.lowpass = [Double](repeating: 0, count: 12)
            self?.smoothLevels = [Double](repeating: 0, count: 6)
            self?.targetLevels = [Double](repeating: 0, count: 6)
            self?.peaks = [Double](repeating: 0.004, count: 6)
            self?.receivedSound = false
            self?.coefficientRate = 0
            self?.lastLevelsSent = [CGFloat](repeating: 0, count: 6)
        }
        status("Ожидание системного звука…")
        controlQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.serial == token, self.isStarted else { return }
            self.ioQueue.async { [weak self] in
                guard let self, !self.receivedSound else { return }
                self.status("Поток запущен, звука нет (проверь разрешение)")
            }
        }
    }

    private func closeTap() {
        serial &+= 1
        if let proc = ioProc {
            if isStarted { _ = AudioDeviceStop(aggregateID, proc) }
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProc = nil
        }
        isStarted = false
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { _ = AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !buffers.isEmpty else { return }
        let first = buffers[0]
        guard let raw = first.mData, first.mDataByteSize >= 4 else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let samples = raw.assumingMemoryBound(to: Float.self)
        let count = Int(first.mDataByteSize) / 4 / channels
        guard count > 8 else { return }

        // Six coarse frequency bands. Separate lowpass energies approximate
        // bass/mid/treble without running an FFT on the main thread.
        // The sample rate changes only when a new tap is opened; cache six
        // exp() calculations instead of repeating them for every callback.
        // At most 384 representative samples per buffer. Adjust the filter
        // rate to account for each skipped source sample.
        let strideSize = max(1, (count + 383) / 384)
        let effectiveRate = sampleRate / Double(strideSize)
        if coefficientRate != effectiveRate {
            let cutoffs = [75.0, 220, 620, 1600, 4600, 9500]
            filterCoefficients = cutoffs.map { 1 - exp(-2 * Double.pi * $0 / effectiveRate) }
            coefficientRate = effectiveRate
        }
        // 3.16.3: no heap allocation inside the per-sample loop (an array
        // was created for every sample — tens of thousands per second).
        var e0 = 0.0, e1 = 0.0, e2 = 0.0, e3 = 0.0, e4 = 0.0, e5 = 0.0
        var frames = 0
        let channelsToRead = min(channels, 2)
        let c0 = filterCoefficients[0], c1 = filterCoefficients[1], c2 = filterCoefficients[2]
        let c3 = filterCoefficients[3], c4 = filterCoefficients[4], c5 = filterCoefficients[5]
        lowpass.withUnsafeMutableBufferPointer { lp in
            for i in stride(from: 0, to: count, by: strideSize) {
                // Left and right envelopes independently: averaging
                // opposite-phase stereo first could cancel a real beat.
                for channel in 0..<channelsToRead {
                    let x = Double(samples[i * channels + channel])
                    if !x.isFinite { continue }
                    let o = channel * 6
                    lp[o] += c0 * (x - lp[o])
                    lp[o + 1] += c1 * (x - lp[o + 1])
                    lp[o + 2] += c2 * (x - lp[o + 2])
                    lp[o + 3] += c3 * (x - lp[o + 3])
                    lp[o + 4] += c4 * (x - lp[o + 4])
                    lp[o + 5] += c5 * (x - lp[o + 5])
                    let b0 = lp[o], b1 = lp[o + 1] - lp[o], b2 = lp[o + 2] - lp[o + 1]
                    let b3 = lp[o + 3] - lp[o + 2], b4 = lp[o + 4] - lp[o + 3], b5 = x - lp[o + 4]
                    e0 += b0 * b0; e1 += b1 * b1; e2 += b2 * b2
                    e3 += b3 * b3; e4 += b4 * b4; e5 += b5 * b5
                    frames += 1
                }
            }
        }
        let energy = [e0, e1, e2, e3, e4, e5]
        guard frames > 0 else { return }
        let rms = energy.map { sqrt($0 / Double(frames)) }
        for k in 0..<6 {
            // Adapt to song dynamics without amplifying silence. Band
            // dynamics are integrated on the *presentation* clock below,
            // not for every Core Audio callback (buffer-size dependent).
            peaks[k] = max(0.003, max(rms[k], peaks[k] * 0.988))
            targetLevels[k] = tuning.amplitude(rms: rms[k], peak: peaks[k], band: k)
        }
        let audible = rms.contains { $0 > 0.00012 }
        if audible && !receivedSound {
            receivedSound = true
            status("Системный звук получен")
        }
        let now = Date()
        if now.timeIntervalSince(lastPresentation) >= 0.045 {
            lastPresentation = now
            for k in 0..<6 {
                let target = targetLevels[k]
                // Swift attacks within a beat, slower fall keeps adjacent
                // samples connected. No synthetic bouncing when silent.
                let response = tuning.smoothingCoefficient(rising: target > smoothLevels[k])
                smoothLevels[k] += (target - smoothLevels[k]) * response
                if target == 0 && smoothLevels[k] < 0.008 { smoothLevels[k] = 0 }
            }
            let values = smoothLevels.map { CGFloat($0) }
            // Don't invalidate SwiftUI for negligible filter noise.
            let hasVisualChange = zip(values, lastLevelsSent).contains { pair in
                abs(pair.0 - pair.1) > 0.012
            }
            if hasVisualChange {
                lastLevelsSent = values
                DispatchQueue.main.async { [weak self] in self?.onLevels?(values) }
            }
        }
    }
}
