import AppKit
import SwiftUI

// 4.2.0 — the user's own themes: a name, light or dark, and 2–4 colours.
// Saved in the app; they can be deleted, the ready-made ones cannot.
struct CustomTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var dark: Bool
    var colors: [PaletteRGB]
}

enum CustomThemeStore {
    static let key = "customThemesV420"
    static let idPrefix = "custom-"

    // Read once and kept: the settings window asks for themes very often.
    private(set) static var themes: [CustomTheme] = load()

    private static func load() -> [CustomTheme] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CustomTheme].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [CustomTheme]) {
        themes = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    @discardableResult
    static func add(name: String, dark: Bool, colors: [PaletteRGB]) -> CustomTheme {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = String((trimmed.isEmpty ? "Моя тема" : trimmed).prefix(24))
        let taken = Set(themes.map { $0.name.lowercased() } + SettingsTheme.builtInNames.map { $0.lowercased() })
        if taken.contains(title.lowercased()) {
            var n = 2
            while taken.contains("\(title) \(n)".lowercased()) { n += 1 }
            title = "\(title) \(n)"
        }
        let theme = CustomTheme(id: idPrefix + UUID().uuidString, name: title, dark: dark,
                                colors: Array(colors.prefix(4)))
        save(themes + [theme])
        return theme
    }

    static func delete(_ id: String) {
        save(themes.filter { $0.id != id })
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix(idPrefix) }
}

extension PaletteRGB {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    // Mixed with white: the pastel background of a light theme.
    func mixedWithWhite(_ amount: Double) -> PaletteRGB {
        PaletteRGB(r: r + (1 - r) * amount, g: g + (1 - g) * amount, b: b + (1 - b) * amount)
    }
}

extension SettingsTheme {
    // A ready theme from the user's colours: the colours themselves for the
    // tiles and switches, a deep (dark) or pastel (light) background from them.
    static func from(_ custom: CustomTheme) -> SettingsTheme {
        var colors = custom.colors.isEmpty ? CoverPalette.fallback : custom.colors
        while colors.count < 4 { colors.append(colors[colors.count % max(1, custom.colors.count)]) }
        let a = colors[0], b = colors[1]
        let background: [Color] = custom.dark
            ? [a.scaled(0.3).color, b.scaled(0.22).color, Color(white: 0.05)]
            : [a.mixedWithWhite(0.82).color, b.mixedWithWhite(0.86).color, a.mixedWithWhite(0.92).color]
        return SettingsTheme(id: custom.id, name: custom.name, icon: "paintpalette.fill", dark: custom.dark,
                             background: background, palette: colors.map(\.color),
                             preview: [a.color, b.color])
    }
}
