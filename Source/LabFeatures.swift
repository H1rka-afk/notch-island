import AppKit
import AudioToolbox
import AVFoundation
import Carbon
import CoreAudio
import CoreMediaIO
import Darwin
import Foundation
import IOKit.ps
import Network
import SystemConfiguration

// 3.3.0 (EXPERIMENTAL) — "Laboratory". Every feature is independent and has
// its own switch; all monitors only READ system state.

enum LabFeature: String, CaseIterable {
    case volume, output, privacy, vpn, network, thermal, disks
    case clipboard, screenshots, shelf, calendar, reminders, hotkey
    case airdrop     // 3.9.4
    case eyes        // 3.17.0: the 20-20-20 rule
    case layout      // 4.3.0: fix text typed in the wrong layout

    var key: String { "lab.\(rawValue).v330" }

    // Calendar/Reminders ask macOS for access, so they start switched off.
    var defaultOn: Bool {
        switch self {
        case .calendar, .reminders: return false
        default: return true
        }
    }

    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn }

    func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}

// MARK: - Volume and output device

extension SystemVolume {
    static func defaultOutputDeviceID() -> AudioDeviceID? {
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

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "Устройство" }
        return value as String
    }

    static func transport(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func symbol(for device: AudioDeviceID, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods") { return "airpodspro" }
        switch transport(of: device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

final class OutputMonitor {
    var onVolume: ((Float, Bool) -> Void)?
    var onDevice: ((String, String) -> Void)?
    // Our own scroll gesture shows its feedback in the island wing; do not
    // also announce those changes as a banner.
    var suppressVolumeUntil = Date.distantPast
    private var timer: Timer?
    private var lastDevice: AudioDeviceID?
    private var lastVolume: Float?
    private var lastMuted: Bool?

    func start() {
        guard timer == nil else { return }
        lastDevice = SystemVolume.defaultOutputDeviceID()
        lastVolume = SystemVolume.current()
        lastMuted = SystemVolume.isMuted()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in PerformanceMonitor.measure("volume") { self?.tick() } }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let device = SystemVolume.defaultOutputDeviceID()
        if device != lastDevice {
            lastDevice = device
            lastVolume = SystemVolume.current()
            lastMuted = SystemVolume.isMuted()
            if let device {
                let name = SystemVolume.name(of: device)
                onDevice?(name, SystemVolume.symbol(for: device, name: name))
            }
            return
        }
        let volume = SystemVolume.current()
        let muted = SystemVolume.isMuted()
        defer { lastVolume = volume; lastMuted = muted }
        guard let volume else { return }
        let changed = muted != lastMuted || abs(volume - (lastVolume ?? volume)) > 0.004
        guard changed, Date() >= suppressVolumeUntil else { return }
        onVolume?(volume, muted)
    }
}

// MARK: - Microphone and camera in use

final class PrivacyMonitor {
    var onChange: ((_ camera: Bool, _ active: Bool) -> Void)?
    private var timer: Timer?
    private var micActive = false
    private var cameraActive = false
    private let queue = DispatchQueue(label: "app.notchisland.privacy", qos: .utility)

    func start() {
        guard timer == nil else { return }
        queue.async { [weak self] in
            let mic = Self.microphoneInUse(), camera = Self.cameraInUse()
            DispatchQueue.main.async { self?.micActive = mic; self?.cameraActive = camera }
        }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        queue.async { [weak self] in
            let mic = Self.microphoneInUse(), camera = Self.cameraInUse()
            DispatchQueue.main.async {
                guard let self else { return }
                if camera != self.cameraActive { self.cameraActive = camera; self.onChange?(true, camera) }
                if mic != self.micActive { self.micActive = mic; self.onChange?(false, mic) }
            }
        }
    }

    // 4.3.2 — asks which *processes* are recording, not whether the input
    // device is busy. AirPods and other headsets are one device for input
    // and output, so plain music playback kept them "running" and looked
    // like a call: the 20-20-20 reminder then never came.
    static func microphoneInUse() -> Bool {
        if #available(macOS 14.4, *), let recording = processesRecordingInput() {
            return recording
        }
        guard let device = SystemVolume.defaultInputDeviceID() else { return false }
        if device == SystemVolume.defaultOutputDeviceID() { return false }
        return SystemVolume.isRunningSomewhere(device)
    }

    @available(macOS 14.4, *)
    private static func processesRecordingInput() -> Bool? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        let me = getpid()
        for process in processes {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
               pid == me { continue }
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(process, &inputAddress, 0, nil, &runningSize, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }

    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0))
        var size = UInt32(0)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(0))
            var value = UInt32(0)
            var valueUsed = UInt32(0)
            if CMIOObjectGetPropertyData(device, &running, 0, nil,
                                         UInt32(MemoryLayout<UInt32>.size), &valueUsed, &value) == 0,
               value != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - VPN and internet

final class NetworkWatch {
    var onVPN: ((Bool) -> Void)?
    var onInternet: ((Bool) -> Void)?
    private var vpnTimer: Timer?
    private var vpnActive: Bool?
    private var pathMonitor: NWPathMonitor?
    private var online: Bool?
    private var pendingOnline: DispatchWorkItem?

    func startVPN() {
        guard vpnTimer == nil else { return }
        vpnActive = Self.vpnIsActive()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let active = Self.vpnIsActive()
            if active != self.vpnActive {
                self.vpnActive = active
                self.onVPN?(active)
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        vpnTimer = timer
    }

    func stopVPN() { vpnTimer?.invalidate(); vpnTimer = nil }

    // A VPN client (INCY and others) makes its tunnel the primary interface.
    static func vpnIsActive() -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "NotchIsland" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return false }
        return ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { primary.hasPrefix($0) }
    }

    func startInternet() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { self?.internetChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "app.notchisland.path"))
        pathMonitor = monitor
    }

    func stopInternet() { pathMonitor?.cancel(); pathMonitor = nil; online = nil }

    // Brief drops while switching networks are ignored (2 s debounce).
    private func internetChanged(_ up: Bool) {
        guard let previous = online else { online = up; return }
        pendingOnline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, previous != up, self.online != up else { return }
            self.online = up
            self.onInternet?(up)
        }
        pendingOnline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

// MARK: - Heat and sustained CPU load

final class LoadMonitor {
    var onThermal: ((ProcessInfo.ThermalState) -> Void)?
    var onCPU: ((Int) -> Void)?
    private var timer: Timer?
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var highSamples = 0
    private var lastCPUAlert = Date.distantPast
    private var observer: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical { self?.onThermal?(state) }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func sample() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return }
        let usage = Int(Double(busy - previous.busy) / Double(total - previous.total) * 100)
        // 30 s above 85 % → one alert, then quiet for 10 minutes.
        highSamples = usage >= 85 ? highSamples + 1 : 0
        if highSamples >= 6 && Date().timeIntervalSince(lastCPUAlert) > 600 {
            lastCPUAlert = Date()
            highSamples = 0
            onCPU?(usage)
        }
    }
}

// MARK: - External disks

final class DiskWatch {
    var onMount: ((URL) -> Void)?
    var onUnmount: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  Self.isExternal(url) else { return }
            self?.onMount?(url)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let name = (note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String) ?? "Диск"
            self?.onUnmount?(name)
        })
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    static func isExternal(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey])
        if values?.volumeIsInternal == true && values?.volumeIsEjectable != true { return false }
        return values?.volumeIsEjectable == true || values?.volumeIsRemovable == true || values?.volumeIsInternal == false
    }

    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { $0.path != "/" && isExternal($0) }
    }

    static func eject(_ url: URL) -> Bool {
        (try? NSWorkspace.shared.unmountAndEjectDevice(at: url)) != nil
    }
}

// MARK: - Clipboard

final class ClipboardWatch {
    var onCopy: ((_ kind: String, _ symbol: String) -> Void)?
    private(set) var history: [String] = []
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    // Set when Ovira itself writes to the clipboard.
    var ignoreNextChange = false

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in PerformanceMonitor.measure("clipboard") { self?.poll() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    // 4.3.0: Ovira itself uses the clipboard for a moment (layout fix).
    private var pausedUntil = Date.distantPast
    func pause(for seconds: TimeInterval) { pausedUntil = Date().addingTimeInterval(seconds) }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        if Date() < pausedUntil { return }
        if ignoreNextChange { ignoreNextChange = false; return }
        let types = board.types?.map(\.rawValue) ?? []
        // Password managers mark secrets; never show or remember them.
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") {
            return
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            onCopy?("Файл", "doc.on.doc.fill")
        } else if types.contains(NSPasteboard.PasteboardType.tiff.rawValue) ||
                    types.contains(NSPasteboard.PasteboardType.png.rawValue) {
            onCopy?("Фото", "photo.on.rectangle")
        } else if let text = board.string(forType: .string), !text.isEmpty {
            // Kept in memory only (never written to disk), 10 items.
            history.removeAll { $0 == text }
            history.insert(String(text.prefix(2000)), at: 0)
            if history.count > 10 { history.removeLast(history.count - 10) }
            onCopy?("Текст", "doc.on.clipboard.fill")
        }
    }

    func copyAgain(_ text: String) {
        ignoreNextChange = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearHistory() { history.removeAll() }
}

// MARK: - New screenshots

final class ScreenshotWatch {
    // url, isRecording
    var onScreenshot: ((URL, Bool) -> Void)?
    // A capture first seen in the floating-preview temp folder is now saved
    // at its real place (same name) — swap the reference on the shelf.
    var onFinalized: ((_ temporary: URL, _ final: URL) -> Void)?
    // The preview was thrown away before macOS saved it.
    var onDiscarded: ((URL) -> Void)?

    private var timer: Timer?
    private var known = Set<String>()
    // name → (temporary URL, time it vanished)
    private var pending: [String: (url: URL, goneSince: Date?)] = [:]
    // 3.3.3: also pick up a screenshot taken while Ovira was
    // restarting (e.g. during an update) — one minute of look-back.
    private let started = Date().addingTimeInterval(-60)
    private let queue = DispatchQueue(label: "app.notchisland.screenshots", qos: .utility)
    private var query: NSMetadataQuery?
    private var queryObservers: [NSObjectProtocol] = []

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "pdf"]
    static let videoExtensions: Set<String> = ["mov", "mp4"]
    static let namePrefixes = ["Снимок экрана", "Запись экрана", "Screenshot", "Screen Shot", "Screen Recording"]

    static func isCapture(_ url: URL) -> Bool {
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else { return false }
        return namePrefixes.contains { name.hasPrefix($0.precomposedStringWithCanonicalMapping) }
    }

    static func isRecording(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static var folder: URL {
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    // 3.4.2: while the floating thumbnail is on screen (~5 s) macOS keeps the
    // capture here and only then moves it to the Desktop. Readable with the
    // Full Disk Access the app already has; silently skipped otherwise.
    static var previewFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.screencaptureui/Data/tmp", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in PerformanceMonitor.measure("screenshots") { self?.poll() } }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        startSpotlightQuery()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        query?.stop(); query = nil
        queryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        queryObservers.removeAll()
    }

    private func startSpotlightQuery() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        // Spotlight marks screenshots with kMDItemIsScreenCapture (any folder
        // or language); recordings are matched by their system name.
        query.predicate = NSPredicate(
            format: "(kMDItemIsScreenCapture == 1 OR kMDItemFSName BEGINSWITH %@ OR kMDItemFSName BEGINSWITH %@) AND kMDItemFSCreationDate >= %@",
            "Запись экрана", "Screen Recording", started as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let handler: (Notification) -> Void = { [weak self] _ in self?.collectSpotlightResults() }
        queryObservers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main, using: handler))
        queryObservers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main, using: handler))
        self.query = query
        query.start()
    }

    private func collectSpotlightResults() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var found: [URL] = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/Containers/") else { continue }
            found.append(URL(fileURLWithPath: path))
        }
        deliverFinal(found)
    }

    private func poll() {
        let since = started
        queue.async { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
            let finals = ((try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles])) ?? [])
                .filter { url in
                    guard Self.isCapture(url),
                          let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    else { return false }
                    return created > since
                }
            // Preview copies: tmp/<anything>/<maybe one more level>/name
            var previews: [URL] = []
            if let walker = fm.enumerator(at: Self.previewFolder, includingPropertiesForKeys: keys,
                                          options: [.skipsHiddenFiles]) {
                for case let url as URL in walker {
                    if walker.level > 3 { walker.skipDescendants(); continue }
                    if Self.isCapture(url),
                       (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        previews.append(url)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.deliverFinal(finals)
                self.deliverPreviews(previews)
            }
        }
    }

    private static func key(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping }
    private static func nameKey(_ url: URL) -> String { url.lastPathComponent.precomposedStringWithCanonicalMapping }

    private func deliverFinal(_ urls: [URL]) {
        for url in urls where !known.contains(Self.key(url)) &&
            FileManager.default.fileExists(atPath: url.path) {
            known.insert(Self.key(url))
            if let preview = pending.removeValue(forKey: Self.nameKey(url)) {
                onFinalized?(preview.url, url)
            } else {
                onScreenshot?(url, Self.isRecording(url))
            }
        }
    }

    private func deliverPreviews(_ urls: [URL]) {
        for url in urls where !known.contains(Self.key(url)) {
            known.insert(Self.key(url))
            pending[Self.nameKey(url)] = (url, nil)
            onScreenshot?(url, Self.isRecording(url))
        }
        // A preview that vanished and never reached the folder was discarded.
        let now = Date()
        for (name, entry) in pending where !FileManager.default.fileExists(atPath: entry.url.path) {
            if let gone = entry.goneSince {
                if now.timeIntervalSince(gone) > 6 {
                    pending.removeValue(forKey: name)
                    onDiscarded?(entry.url)
                }
            } else {
                pending[name] = (entry.url, now)
            }
        }
    }

    static func thumbnail(for url: URL) -> NSImage? {
        if isRecording(url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 128, height: 128)
            if let image = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                return NSImage(cgImage: image, size: NSSize(width: 64, height: 64 * CGFloat(image.height) / CGFloat(max(image.width, 1))))
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 64, height: 64 * image.size.height / max(image.size.width, 1))
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumb.unlockFocus()
        return thumb
    }
}

// MARK: - Global hotkey (⌃⌥N) — toggles the island

final class IslandHotKey {
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    // 4.3.0: several hot keys — each handler answers only its own id.
    private let keyCode: Int
    private let modifiers: Int
    let hotKeyID: UInt32

    init(keyCode: Int = kVK_ANSI_N, modifiers: Int = controlKey | optionKey, id: UInt32 = 1) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyID = id
    }

    func register() {
        guard reference == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<IslandHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.id == hotKey.hotKeyID else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.onPress?() }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x4E495348), id: hotKeyID) // 'NISH'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                            GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}

// MARK: - Cleanup of old releases and test files

enum ReleaseCleanup {
    // Old Ovira archives/folders in Downloads (older than or equal to
    // the running version) and the diagnostic test files in ~/Library/Logs.
    // Everything goes to the Trash, so it can be restored.
    static func candidates() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let downloads = AppUpdater.downloadsFolder
        let current = AppUpdater.currentVersion
        if let urls = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) {
            for url in urls {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if let release = UpdatePolicy.release(fromName: url.lastPathComponent, isDirectory: isDirectory),
                   !UpdatePolicy.isNewer(release.version, than: current) {
                    result.append(url)
                }
            }
        }
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        if let urls = try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls {
                let name = url.lastPathComponent
                let isTestFile = name.hasPrefix("nip") || name.hasPrefix("NotchIsland-probe") ||
                    name == "NotchIsland-artwork-probe.js" || name == "NotchIsland-sign-test.txt" ||
                    name == "NotchIsland-verify.txt"
                let isOldRelease = UpdatePolicy.release(fromName: name, isDirectory: false).map {
                    !UpdatePolicy.isNewer($0.version, than: current)
                } ?? false
                if isTestFile || isOldRelease { result.append(url) }
            }
        }
        return result
    }

    static func moveToTrash(_ urls: [URL], completion: @escaping (Int) -> Void) {
        guard !urls.isEmpty else { completion(0); return }
        NSWorkspace.shared.recycle(urls) { moved, _ in
            DispatchQueue.main.async { completion(moved.count) }
        }
    }
}

// MARK: - Battery time remaining (Settings → Battery)

enum BatteryTime {
    static func remainingText() -> String? {
        let seconds = IOPSGetTimeRemainingEstimate()
        if seconds == kIOPSTimeRemainingUnlimited { return "Питание от сети" }
        if seconds == kIOPSTimeRemainingUnknown || seconds <= 0 { return nil }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "≈ \(minutes / 60) ч \(minutes % 60) мин" : "≈ \(minutes) мин"
    }
}
