import AppKit

// 3.9.0 — the app icon follows the theme: the dark minimal icon in dark
// mode, the light one in light mode. «Оформление» in Notch Island's
// Settings decides: «Системная» follows macOS, «Тёмная»/«Светлая» force it.
//
// macOS lets a running app change its icon in the Dock, the app switcher,
// alerts and its own windows. The icon in Finder/Launchpad is the bundle's
// file (the dark one): changing it would break the app's signature, and
// with it the permissions that are kept between updates.
final class AppIconSwitcher {
    private var appearanceObservation: NSKeyValueObservation?
    private var defaultsObserver: NSObjectProtocol?
    private var current: String?

    private lazy var dark = Bundle.main.url(forResource: "IconDark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    private lazy var light = Bundle.main.url(forResource: "IconLight", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    func start() {
        apply()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    static var wantsDark: Bool {
        // 3.16.0: colour themes are light or dark too.
        if let dark = SettingsTheme.find(UserDefaults.standard.string(forKey: "settingsAppearanceV323") ?? "system").dark {
            return dark
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func apply() {
        let wanted = Self.wantsDark ? "dark" : "light"
        guard wanted != current, let image = (wanted == "dark" ? dark : light) else { return }
        current = wanted
        NSApp.applicationIconImage = image
    }
}
