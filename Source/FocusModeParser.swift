import Foundation

// Pure, Foundation-only reader for the macOS Focus database. It never writes
// anything and has no AppKit dependency, so it is covered by FocusModeTests.
//
// macOS keeps Focus state in ~/Library/DoNotDisturb/DB:
//  • Assertions.json         — the modes that are ACTIVE right now. macOS
//                              itself records scheduled activations here too
//                              (assertionDetailsLifetimeType == "schedule"),
//                              and removes them when the user turns the mode
//                              off early. This file is the single source of truth.
//  • ModeConfigurations.json — every mode's name, SF Symbol and tint.
// 3.1.9 also guessed schedules from the clock; that kept "Do Not Disturb"
// permanently "on" inside a schedule window and hid every manual switch.
struct FocusMode: Equatable {
    let identifier: String
    let name: String
    let symbol: String
    let tintName: String
    let scheduled: Bool
}

enum FocusDatabaseParser {
    static let defaultIdentifier = "com.apple.donotdisturb.mode.default"

    // Built-in modes: stable Russian names and fallbacks when the database
    // omits a field. The database's own symbol and tint take precedence.
    static let builtIns: [String: (name: String, symbol: String, tint: String)] = [
        "com.apple.donotdisturb.mode.default": ("Не беспокоить", "moon.fill", "systemIndigoColor"),
        "com.apple.sleep.sleep-mode": ("Сон", "bed.double.fill", "systemMintColor"),
        "com.apple.focus.work": ("Работа", "person.lanyardcard.fill", "systemTealColor"),
        "com.apple.focus.personal-time": ("Личное", "person.fill", "systemPurpleColor"),
        "com.apple.donotdisturb.mode.driving": ("Вождение", "car.fill", "systemBlueColor"),
        "com.apple.focus.reduce-interruptions": ("Меньше отвлечений", "sparkles", "systemCyanColor"),
        "com.apple.focus.gaming": ("Игры", "gamecontroller.fill", "systemBlueColor"),
        "com.apple.focus.mindfulness": ("Осознанность", "brain.head.profile", "systemMintColor"),
        "com.apple.focus.reading": ("Чтение", "book.fill", "systemOrangeColor"),
        "com.apple.focus.fitness": ("Фитнес", "figure.run", "systemGreenColor")
    ]

    static func activeMode(assertionsJSON: Data?, configurationsJSON: Data?) -> FocusMode? {
        guard let asserted = activeAssertion(assertionsJSON) else { return nil }
        let configurations = modeConfigurations(configurationsJSON)
        return describe(asserted.identifier, configuration: configurations[asserted.identifier],
                        scheduled: asserted.scheduled)
    }

    // True when the bytes are a complete JSON document. A half-written file
    // must never be interpreted as "Focus turned off".
    static func isWellFormed(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func describe(_ identifier: String, configuration: [String: Any]?,
                         scheduled: Bool) -> FocusMode {
        let mode = configuration?["mode"] as? [String: Any]
        let builtIn = builtIns[identifier]
        let configuredName = (mode?["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = builtIn?.name ?? (configuredName.isEmpty ? "Фокусирование" : configuredName)
        let configuredSymbol = (mode?["symbolImageName"] as? String) ?? ""
        let symbol = configuredSymbol.isEmpty ? (builtIn?.symbol ?? "moon.fill") : configuredSymbol
        let configuredTint = (mode?["tintColorName"] as? String) ?? ""
        let tint = configuredTint.isEmpty ? (builtIn?.tint ?? "systemIndigoColor") : configuredTint
        return FocusMode(identifier: identifier, name: name, symbol: symbol,
                         tintName: tint, scheduled: scheduled)
    }

    // MARK: - Assertions.json

    static func latestAssertedIdentifier(_ data: Data?) -> String? {
        activeAssertion(data)?.identifier
    }

    static func activeAssertion(_ data: Data?) -> (identifier: String, scheduled: Bool)? {
        var best: (identifier: String, scheduled: Bool, start: Double, order: Int)?
        var order = 0
        for entry in dataEntries(data) {
            // A "turn everything off" request newer than an assertion means
            // that assertion is no longer in force, even if still listed.
            var latestInvalidateAll = -Double.infinity
            for request in (entry["storeInvalidationRequestRecords"] as? [[String: Any]]) ?? [] {
                let predicate = (request["invalidationRequestPredicate"] as? [String: Any])?["invalidationPredicateType"] as? String
                if predicate == "any", let date = number(request["invalidationRequestDateTimestamp"]) {
                    latestInvalidateAll = max(latestInvalidateAll, date)
                }
            }
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                order += 1
                guard let details = record["assertionDetails"] as? [String: Any],
                      let identifier = details["assertionDetailsModeIdentifier"] as? String,
                      !identifier.isEmpty else { continue }
                let start = number(record["assertionStartDateTimestamp"]) ?? 0
                if start < latestInvalidateAll { continue }
                let lifetime = details["assertionDetailsLifetime"] as? [String: Any]
                let scheduled = (lifetime?["assertionDetailsLifetimeType"] as? String) == "schedule"
                if best == nil || start > best!.start ||
                    (start == best!.start && order > best!.order) {
                    best = (identifier, scheduled, start, order)
                }
            }
        }
        guard let best else { return nil }
        return (best.identifier, best.scheduled)
    }

    // MARK: - ModeConfigurations.json

    static func modeConfigurations(_ data: Data?) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for entry in dataEntries(data) {
            guard let configurations = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configurations {
                if let configuration = value as? [String: Any] { result[identifier] = configuration }
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func dataEntries(_ data: Data?) -> [[String: Any]] {
        guard let data, !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [] }
        return entries
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
