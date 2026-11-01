import Foundation

// 3.5.0 — profiles. A profile is only a set of feature switches; width,
// spectrum, theme, haptics and permissions are never touched.
//
// • «Как на iPhone» — what the Dynamic Island on iPhone does: Now Playing,
//   charging, AirPods, Focus, the Clock timer, Face ID-style lock, camera and
//   microphone indicator; the player steps aside when its app is in front.
// • «Максимум» — everything Notch Island can do: shelf, screenshots,
//   clipboard, volume, VPN, disks, gestures, cover glow…
// • «Свой» — the user's own combination, remembered when a preset is chosen
//   and restored when «Свой» is picked again.
enum IslandProfile: String, CaseIterable {
    case iphone, quiet, extended, custom
}

enum IslandProfiles {
    // Switches managed by profiles. Lab features use their raw names.
    static let labKeys = ["volume", "output", "privacy", "vpn", "network", "thermal", "disks",
                          "clipboard", "screenshots", "shelf", "calendar", "reminders", "hotkey",
                          "airdrop", "eyes", "layout"]
    static let islandKeys = ["lockIsland", "focus", "gestures", "coverGlow",
                             "hideFullscreen", "hideSource",
                             // 3.11.0: lock-screen player, widgets under the
                             // clock, the living cover background.
                             "lockMedia", "lockWidgets", "coverAnimated",
                             // 4.3.3: StandBy, idle wings, cinema mode and
                             // the new expanded player.
                             "standby", "wings", "cinema", "playerNew"]
    static var allKeys: [String] { labKeys + islandKeys }

    // Calendar and reminders depend on a macOS permission: «Максимум» turns
    // them on only when access is already granted, so matching ignores them.
    static let permissionDependent: Set<String> = ["calendar", "reminders"]

    static func preset(_ profile: IslandProfile) -> [String: Bool]? {
        switch profile {
        case .custom:
            return nil
        case .iphone:
            var values = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, false) })
            for key in ["privacy", "lockIsland", "focus", "hideFullscreen", "hideSource", "airdrop",
                        "lockMedia", "lockWidgets", "coverAnimated", "eyes",
                        "standby", "cinema", "playerNew"] {
                values[key] = true
            }
            return values
        case .quiet:
            // 4.3.3 «Тихий»: only music, the timer and the lock screen —
            // no banners, no wings, nothing that pops up uninvited.
            var values = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, false) })
            for key in ["lockIsland", "hideFullscreen", "hideSource", "lockMedia",
                        "cinema", "playerNew"] {
                values[key] = true
            }
            return values
        case .extended:
            return Dictionary(uniqueKeysWithValues: allKeys.map { ($0, true) })
        }
    }

    // Which preset the current switches equal; .custom when none.
    static func match(_ current: [String: Bool]) -> IslandProfile {
        for profile in [IslandProfile.iphone, .quiet, .extended] {
            guard let preset = preset(profile) else { continue }
            let equal = allKeys.allSatisfy { key in
                if profile == .extended && permissionDependent.contains(key) { return true }
                return (current[key] ?? false) == (preset[key] ?? false)
            }
            if equal { return profile }
        }
        return .custom
    }

    // Values to apply when choosing `profile`. `saved` is the remembered
    // custom set; `granted` tells whether a permission-dependent key may be on.
    static func values(for profile: IslandProfile, saved: [String: Bool]?,
                       current: [String: Bool], granted: (String) -> Bool) -> [String: Bool] {
        var result: [String: Bool]
        if let preset = preset(profile) {
            result = preset
        } else {
            result = saved ?? current
        }
        for key in permissionDependent where result[key] == true && !granted(key) {
            result[key] = current[key] ?? false
        }
        return result
    }

    static let savedCustomKey = "islandProfileCustomV350"

    static func loadCustom() -> [String: Bool]? {
        UserDefaults.standard.dictionary(forKey: savedCustomKey) as? [String: Bool]
    }

    static func saveCustom(_ values: [String: Bool]) {
        UserDefaults.standard.set(values, forKey: savedCustomKey)
    }
}

// MARK: - 3.11.0 The user's own profiles

// A named set of switches with a description. Saved in the app and can be
// exported to a small «.notchprofile» file (JSON) to send to another Mac.
struct UserIslandProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var values: [String: Bool]
    var created: Date

    var enabledCount: Int { values.values.filter { $0 }.count }
}

enum UserProfileStore {
    static let key = "islandUserProfilesV3110"
    static let fileExtension = "notchprofile"
    static let format = "notch-island-profile"
    static let maxName = 40
    static let maxSummary = 160

    static func load(_ defaults: UserDefaults = .standard) -> [UserIslandProfile] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([UserIslandProfile].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [UserIslandProfile], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }

    static func cleanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Мой профиль" : trimmed).prefix(maxName))
    }

    static func cleanSummary(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxSummary))
    }

    // Only switches Notch Island knows; anything else in a file is ignored.
    static func cleanValues(_ values: [String: Bool]) -> [String: Bool] {
        let known = Set(IslandProfiles.allKeys)
        return values.filter { known.contains($0.key) }
    }

    static func make(name: String, summary: String, values: [String: Bool], now: Date = Date()) -> UserIslandProfile {
        UserIslandProfile(id: UUID().uuidString, name: cleanName(name), summary: cleanSummary(summary),
                          values: cleanValues(values), created: now)
    }

    // A name that is not taken yet: «Работа», «Работа 2», «Работа 3»…
    static func uniqueName(_ name: String, among list: [UserIslandProfile]) -> String {
        let taken = Set(list.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    // The user profile equal to the current switches (keys it defines).
    static func match(_ current: [String: Bool], in list: [UserIslandProfile]) -> String? {
        list.first { profile in
            !profile.values.isEmpty && profile.values.allSatisfy { key, value in
                IslandProfiles.permissionDependent.contains(key) || (current[key] ?? false) == value
            }
        }?.id
    }

    private struct ExportFile: Codable {
        var format: String
        var version: Int
        var name: String
        var description: String
        var values: [String: Bool]
    }

    static func exportData(_ profile: UserIslandProfile) -> Data? {
        let file = ExportFile(format: format, version: 1, name: profile.name,
                              description: profile.summary, values: profile.values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(file)
    }

    static func importProfile(from data: Data, now: Date = Date()) -> UserIslandProfile? {
        guard let file = try? JSONDecoder().decode(ExportFile.self, from: data),
              file.format == format, file.version >= 1 else { return nil }
        let values = cleanValues(file.values)
        guard !values.isEmpty else { return nil }
        return make(name: file.name, summary: file.description, values: values, now: now)
    }

    static func fileName(for profile: UserIslandProfile) -> String {
        let safe = profile.name.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
        return String(safe) + "." + fileExtension
    }
}
