import AudioToolbox
import CoreAudio
import Foundation

// Output volume of the CURRENT default output device (speakers, AirPods,
// headphones…) through Core Audio's virtual main volume — the same control
// as the menu bar slider. Devices without a software volume (some HDMI/USB
// outputs) report nil and are left untouched.
enum SystemVolume {
    static let step: Float = 1.0 / 32.0

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func current() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    private static func setMuted(_ muted: Bool, device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // Changes the volume by `steps` × 1/32 and returns the new level, or nil
    // when the output device has no adjustable volume.
    @discardableResult
    static func adjust(steps: Int) -> Float? {
        guard steps != 0, let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        var target = min(1, max(0, volume + Float32(steps) * step))
        // Snap to the grid so repeated small gestures stay predictable.
        target = (target / step).rounded() * step
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &target) == noErr else { return nil }
        // Turning the volume up un-mutes, as the keyboard volume keys do.
        if steps > 0 && isMuted() { setMuted(false, device: device) }
        return target
    }
}
