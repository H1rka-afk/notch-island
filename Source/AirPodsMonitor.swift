import Foundation
import IOBluetooth
import CoreAudio

// Battery information comes exclusively from the user's own macOS Bluetooth
// report. Unknown values stay nil (not invented). The report is read off the
// UI thread so system_profiler cannot stutter the island's animations.
struct AirPodsStatus: Equatable {
    let address: String
    let name: String
    var left: Int?
    var right: Int?
    var caseBattery: Int?
    var main: Int?

    var batterySummary: String {
        var parts: [String] = []
        if let left { parts.append("Л \(left)%") }
        if let right { parts.append("П \(right)%") }
        if let caseBattery { parts.append("Кейс \(caseBattery)%") }
        if parts.isEmpty, let main { parts.append("\(main)%") }
        return parts.isEmpty ? "Заряд не предоставлен macOS" : parts.joined(separator: "  ·  ")
    }
}

final class AirPodsMonitor: NSObject {
    var onConnected: ((AirPodsStatus) -> Void)?
    var onUpdated: ((AirPodsStatus) -> Void)?
    private var connectionNotification: IOBluetoothUserNotification?
    private var pollTimer: Timer?
    private var knownAddresses = Set<String>()
    private var snapshots: [String: AirPodsStatus] = [:]
    private var batteryScanBusy = false
    private var lastBatteryScan = Date.distantPast
    // AirPods can switch their audio route without a new Bluetooth connection.
    // A Core Audio output-device transition is the second source of truth.
    private var lastOutputRouteName: String?
    private var lastAutomaticAnnouncement = Date.distantPast

    func start() {
        // Existing connections at launch should not fire unsolicited banners.
        lastOutputRouteName = Self.defaultOutputDeviceName()
        let connected = connectedDevices()
        knownAddresses = Set(connected.map { $0.address })
        for device in connected { snapshots[device.address] = device }
        connectionNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(didConnect(_:device:)))
        // Bluetooth connect notifications are immediate. A slower fallback
        // also detects AirPods changing the active audio output.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.checkConnections()
        }
        pollTimer?.tolerance = 0.5
        if !connected.isEmpty { refreshBattery(force: true) }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        connectionNotification?.unregister()
        connectionNotification = nil
    }

    private func connectedDevices() -> [AirPodsStatus] {
        let paired = IOBluetoothDevice.pairedDevices() ?? []
        return paired.compactMap { item in
            guard let device = item as? IOBluetoothDevice,
                  device.isConnected(),
                  let name = device.name,
                  Self.looksLikeAirPods(name) else { return nil }
            let address = Self.normalizeAddress(device.addressString ?? name)
            return snapshots[address] ?? AirPodsStatus(address: address, name: name)
        }
    }

    private static func normalizeAddress(_ value: String) -> String {
        return String(value.lowercased().filter { $0.isHexDigit })
    }

    static func looksLikeAirPods(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("airpods") || value.contains("air pods") || value.contains("эйрподс")
    }

    @objc private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Cocoa and the window state must be updated on the main queue.
        DispatchQueue.main.async { [weak self] in
            guard let self, let name = device.name, Self.looksLikeAirPods(name) else { return }
            let address = Self.normalizeAddress(device.addressString ?? name)
            guard self.knownAddresses.insert(address).inserted else { return }
            // Do not claim an old charge reading after a new connection.
            let status = AirPodsStatus(address: address, name: name)
            self.snapshots[address] = status
            self.announceConnection(status)
            self.refreshBattery(force: true)
        }
    }

    private func announceConnection(_ status: AirPodsStatus) {
        // A route change and Bluetooth connection may be reported together.
        guard Date().timeIntervalSince(lastAutomaticAnnouncement) >= 3 else { return }
        lastAutomaticAnnouncement = Date()
        onConnected?(status)
    }

    private static func defaultOutputDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceNameCFString
        var deviceName: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil,
                                         &size, &deviceName) == noErr,
              let name = deviceName else { return nil }
        return name as String
    }

    private func checkConnections() {
        let connected = connectedDevices()
        let activeAddresses = Set(connected.map { $0.address })
        for disconnected in knownAddresses.subtracting(activeAddresses) {
            snapshots.removeValue(forKey: disconnected)
        }
        for device in connected where !knownAddresses.contains(device.address) {
            announceConnection(AirPodsStatus(address: device.address, name: device.name))
        }
        knownAddresses = activeAddresses
        for device in connected { snapshots[device.address] = device }

        // Auto-switching AirPods often remain logically Bluetooth-connected
        // while macOS changes its active audio output. The Bluetooth callback
        // will not fire in that case, but the audio route changes.
        if let route = Self.defaultOutputDeviceName() {
            // A transient Core Audio query failure is not a disconnection.
            let routeDidChange = route != lastOutputRouteName
            lastOutputRouteName = route
            if routeDidChange, Self.looksLikeAirPods(route) {
                let match = connected.first { device in
                    device.name.compare(route, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
                let status = match ?? AirPodsStatus(address: "audio-route:\(route)", name: route)
                announceConnection(status)
            }
        }
        if !connected.isEmpty { refreshBattery(force: false) }
    }

    @discardableResult
    func showConnectedPreview() -> Bool {
        checkConnections()
        // A manual preview must work even if the AirPods are already connected
        // and Bluetooth pairing metadata is momentarily unavailable.
        if let device = connectedDevices().first {
            onConnected?(device)
            refreshBattery(force: true)
            return true
        }
        if let route = Self.defaultOutputDeviceName(), Self.looksLikeAirPods(route) {
            onConnected?(AirPodsStatus(address: "audio-route:\(route)", name: route))
            return true
        }
        return false
    }

    private func refreshBattery(force: Bool) {
        guard !batteryScanBusy else { return }
        guard force || Date().timeIntervalSince(lastBatteryScan) > 120 else { return }
        batteryScanBusy = true
        lastBatteryScan = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // No shell interpreter, no elevated permissions and no network.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            var result: [String: [String: Int]] = [:]
            do {
                try process.run()
                // Read while running to prevent pipe-buffer deadlock.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { result = Self.parseBatteryData(data) }
            } catch { /* Some Macs block the profiler; show unknown battery. */ }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.batteryScanBusy = false
                for (address, old) in self.snapshots where self.knownAddresses.contains(address) {
                    guard let battery = result[address] else { continue }
                    var updated = old
                    updated.left = battery["left"]
                    updated.right = battery["right"]
                    updated.caseBattery = battery["case"]
                    updated.main = battery["main"]
                    self.snapshots[address] = updated
                    self.onUpdated?(updated)
                }
            }
        }
    }

    // Isolated parser. Apple occasionally emits  "80 %", "80%" or number 80.
    static func parseBatteryData(_ data: Data) -> [String: [String: Int]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: [String: Int]] = [:]
        for controller in entries {
            guard let devices = controller["device_connected"] as? [[String: Any]] else { continue }
            for item in devices {
                for (_, raw) in item {
                    guard let device = raw as? [String: Any],
                          let address = device["device_address"] as? String else { continue }
                    var readings: [String: Int] = [:]
                    let keys: [(String, String)] = [
                        ("device_batteryLevelMain", "main"),
                        ("device_batteryLevelLeft", "left"),
                        ("device_batteryLevelRight", "right"),
                        ("device_batteryLevelCase", "case")]
                    for (systemKey, localKey) in keys {
                        if let rawValue = device[systemKey] {
                            let value = String(describing: rawValue)
                            let digits = value.prefix { $0.isNumber }
                            if let percent = Int(digits), (0...100).contains(percent) {
                                readings[localKey] = percent
                            }
                        }
                    }
                    result[normalizeAddress(address)] = readings
                }
            }
        }
        return result
    }
}
