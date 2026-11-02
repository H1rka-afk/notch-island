import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

// 4.0.0 — the new expanded player, idle «wings» and cinema mode.

// MARK: Expanded player style

enum ExpandedPlayerStyle {
    static let key = "expandedPlayerStyleV400"
    // «new» (default) or «classic».
    static var isNew: Bool { (UserDefaults.standard.string(forKey: key) ?? "new") == "new" }
}

// System volume for the slider in the new player.
final class PlayerVolumeModel: ObservableObject {
    @Published private(set) var level: Double = Double(SystemVolume.current() ?? 0.5)
    @Published private(set) var available = SystemVolume.current() != nil

    func refresh() {
        let now = SystemVolume.current()
        available = now != nil
        if let now, abs(Double(now) - level) > 0.005 { level = Double(now) }
    }

    func set(_ value: Double) {
        level = value
        SystemVolume.set(Float(value))
    }
}

// Output devices for «where the sound goes».
struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let symbol: String
}

extension SystemVolume {
    static func set(_ level: Float) {
        guard let device = defaultOutputDeviceID() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value = Float32(min(1, max(0, level)))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            let name = SystemVolume.name(of: id)
            return AudioOutputDevice(id: id, name: name, symbol: SystemVolume.symbol(for: id, name: name))
        }
    }

    static func setDefaultOutput(_ device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }
}

// MARK: Cinema mode

enum CinemaMode {
    static let key = "cinemaModeV400"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }
    // Video players besides the music players and browsers already known.
    static let videoApps: Set<String> = [
        "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.apple.TV",
        "com.firecore.infuse", "io.mpv", "com.movist.MovistPro", "tv.plex.desktop", "com.kinopoisk.mac"
    ]
}

// MARK: Idle wings

enum IdleWings {
    static let enabledKey = "idleWingsV400"
    static let leftKey = "idleWingsLeftV400"
    static let rightKey = "idleWingsRightV400"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
    static var left: String { UserDefaults.standard.string(forKey: leftKey) ?? "weather" }
    static var right: String { UserDefaults.standard.string(forKey: rightKey) ?? "battery" }
    static let wing: CGFloat = 46

    static let choices: [(id: String, title: String)] = [
        ("weather", "Погода"), ("battery", "Заряд"), ("time", "Время"), ("date", "Дата"), ("none", "Пусто")
    ]
}

// The black notch with a little information on each side.
struct IdleWingsView: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var weather = WeatherService.shared
    @AppStorage(IdleWings.leftKey) private var left = "weather"
    @AppStorage(IdleWings.rightKey) private var right = "battery"
    let roof: CGFloat

    var body: some View {
        let wing = IdleWings.wing
        HStack(spacing: 0) {
            item(left).frame(width: wing).offset(x: 3)
            Color.clear.frame(width: state.notchWidth)
            item(right).frame(width: wing).offset(x: -3)
        }
        .frame(height: state.notchHeight)
        .padding(.top, roof)
        .background(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                   bottomTrailingRadius: 10, topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
                .frame(height: state.notchHeight + roof)
        }
        .foregroundStyle(.white)
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func item(_ kind: String) -> some View {
        switch kind {
        case "weather":
            if let snapshot = weather.snapshot {
                HStack(spacing: 3) {
                    Image(systemName: WeatherCodes.symbol(snapshot.code, night: Self.isNight))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 11))
                    Text("\(snapshot.temperature)°")
                }
            } else {
                Image(systemName: "cloud.sun").font(.system(size: 11)).opacity(0.6)
            }
        case "battery":
            if let power = state.power {
                HStack(spacing: 3) {
                    Image(systemName: power.isCharging ? "bolt.fill" : Self.batterySymbol(power.percentage))
                        .font(.system(size: power.isCharging ? 9.5 : 11))
                        .foregroundStyle(power.isCharging ? Color.green
                                         : (power.percentage <= 20 ? Color(red: 1, green: 0.3, blue: 0.25) : .white))
                    Text("\(power.percentage)%")
                }
            }
        case "time":
            TimelineView(.everyMinute) { context in Text(Self.format(context.date, "HH:mm")) }
        case "date":
            TimelineView(.everyMinute) { context in Text(Self.format(context.date, "EE d").capitalized) }
        default:
            Color.clear
        }
    }

    static var isNight: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 || hour >= 21
    }

    static func batterySymbol(_ p: Int) -> String {
        p > 87 ? "battery.100percent" : p > 62 ? "battery.75percent" : p > 37 ? "battery.50percent"
            : p > 12 ? "battery.25percent" : "battery.0percent"
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

// MARK: Pieces of the new player

// The current output (AirPods, speakers…); click → choose another.
struct OutputDeviceButton: View {
    var size: CGFloat = 16
    @StateObject private var route = LockOutputRoute()
    @StateObject private var list = OutputDeviceList()

    var body: some View {
        Menu {
            ForEach(list.devices) { device in
                Button {
                    SystemVolume.setDefaultOutput(device.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { route.refresh() }
                } label: {
                    Label(device.name, systemImage: device.name == route.name ? "checkmark" : device.symbol)
                }
            }
            if list.devices.isEmpty { Text("Нет устройств вывода") }
        } label: {
            Image(systemName: route.symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Звук: \(route.name)")
        .onAppear { route.refresh(); list.refresh() }
        .simultaneousGesture(TapGesture().onEnded { list.refresh() })
    }
}

final class OutputDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    func refresh() {
        let fresh = SystemVolume.outputDevices()
        if fresh != devices { devices = fresh }
    }
}

struct PlayerVolumeRow: View {
    let tint: Color
    let externalLevel: Float?
    @StateObject private var volume = PlayerVolumeModel()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 10))
            Slider(value: Binding(get: { volume.level }, set: { volume.set($0) }), in: 0...1)
                .controlSize(.mini)
                .tint(.white)
                .disabled(!volume.available)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.6))
        .onAppear { volume.refresh() }
        .onChange(of: externalLevel) { _, _ in volume.refresh() }
    }
}
