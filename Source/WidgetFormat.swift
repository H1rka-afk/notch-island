import Foundation

// 3.12.0 — pure helpers for the new lock-screen widgets (covered by tests).

struct AccessoryBattery: Equatable {
    var name: String
    var percent: Int

    // One entry per device (both registry classes may list it), real
    // percentages only, AirPods left to their own widget; lowest first.
    static func cleaned(_ list: [AccessoryBattery]) -> [AccessoryBattery] {
        var seen = Set<String>()
        return list
            .filter { (0...100).contains($0.percent) && !$0.name.lowercased().contains("airpods") }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.percent == $1.percent ? $0.name < $1.name : $0.percent < $1.percent }
    }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mouse") || lower.contains("мышь") { return "computermouse.fill" }
        if lower.contains("keyboard") || lower.contains("клавиатура") { return "keyboard.fill" }
        if lower.contains("trackpad") || lower.contains("трекпад") { return "hand.point.up.left.fill" }
        if lower.contains("pencil") { return "pencil" }
        return "dot.radiowaves.left.and.right"
    }

    // «Magic Mouse» or «Magic Mouse и ещё 2».
    static func heading(_ list: [AccessoryBattery]) -> String {
        guard let first = list.first else { return "" }
        return list.count > 1 ? "\(first.name) и ещё \(list.count - 1)" : first.name
    }
}

struct SystemLoad: Equatable {
    var cpu: Double?
    var memory: Double?

    static func fraction(busy: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(busy) / Double(total)))
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded())) %"
    }
}

enum SunFormat {
    static func time(_ date: Date, in zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // «Световой день 9 ч 12 мин».
    static func dayLength(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "Световой день \(minutes / 60) ч \(minutes % 60) мин"
    }
}
