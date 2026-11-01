import AppKit
import ApplicationServices
import Foundation

// Local bridge for the Yandex Music macOS application. No Yandex login,
// access token, network request or screenshot is used by this bridge.
// We refuse to press anything unless the exact playing song and existing
// "Like" button state can both be checked using macOS Accessibility.
enum YandexDesktopFavorites {
    static var authorized: Bool { AXIsProcessTrusted() }

    static func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // The macOS Swift SDK exposes constants such as kAXTitleAttribute as
    // String, while the AXUIElement C API requires CFString. Bridge them
    // explicitly at this single entry point to avoid compiler errors.
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String {
        (attribute(element, key) as? String) ?? ""
    }

    private static func rect(_ element: AXUIElement) -> CGRect? {
        guard let pos = attribute(element, kAXPositionAttribute),
              let sz = attribute(element, kAXSizeAttribute),
              CFGetTypeID(pos) == AXValueGetTypeID(),
              CFGetTypeID(sz) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeBitCast(pos, to: AXValue.self)
        let dimensions = unsafeBitCast(sz, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func descendants(_ root: AXUIElement, limit: Int = 1800) -> [AXUIElement] {
        var output: [AXUIElement] = []
        var queue: [AXUIElement] = [root]
        var index = 0
        while index < queue.count && output.count < limit {
            let current = queue[index]
            index += 1
            output.append(current)
            if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(150))
            }
        }
        return output
    }

    private static func runningYandex(_ track: PlayingTrack) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return name.contains("яндекс музыка") || name.contains("yandex music") ||
                (bundle.contains("yandex") && bundle.contains("music") && !bundle.contains("browser"))
        }
        if let match = apps.first(where: { $0.bundleIdentifier == track.sourceBundle }) { return match }
        return apps.count == 1 ? apps.first : nil
    }

    private struct Target {
        let element: AXUIElement
        let saved: Bool
    }

    private static func label(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
            .map { string(element, $0).lowercased() }.joined(separator: " ")
    }

    // Return nil rather than guessing from a generic heart icon. Many
    // versions label both states "Мне нравится", so we inspect AXValue/
    // AXSelected first when they are supplied by Yandex's native view.
    private static func likeStatus(_ element: AXUIElement) -> Bool? {
        let text = label(element)
        if text.contains("удалить из") || text.contains("убрать из") ||
           text.contains("снять лайк") || text.contains("remove from") ||
           text.contains("unlike") || text.contains("already liked") ||
           text.contains("убрать лайк") { return true }
        if text.contains("добавить в") || text.contains("поставить лайк") ||
           text.contains("add to") || text.contains("like song") ||
           text.contains("like track") || text.contains("поставить нравится") { return false }
        if let value = attribute(element, kAXValueAttribute) as? NSNumber { return value.boolValue }
        if let selected = attribute(element, kAXSelectedAttribute) as? NSNumber { return selected.boolValue }
        return nil
    }

    private static func isMatchingText(_ text: String, expected: String) -> Bool {
        let t = normalize(text), q = normalize(expected)
        guard !q.isEmpty, !t.isEmpty else { return false }
        // AX can combine the title, artist and controls into one node.
        // Bound by spaces to avoid matching arbitrary substrings.
        return t == q || (" " + t + " ").contains(" " + q + " ")
    }

    private static func findTarget(_ track: PlayingTrack) -> Target? {
        guard authorized, let application = runningYandex(track) else { return nil }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.7)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows.prefix(4) {
            guard let windowRect = rect(window), windowRect.height > 200, windowRect.width > 300 else { continue }
            // Use only the player footer, not hearts in the search results or
            // playlists. The footer appears in the bottom 180 pt of the window.
            let footerTop = windowRect.maxY - min(180, windowRect.height * 0.24)
            let bottomNodes = descendants(window).filter { node in
                guard let r = rect(node) else { return false }
                return r.midY >= footerTop && r.midY <= windowRect.maxY + 3 &&
                    r.midX >= windowRect.minX && r.midX <= windowRect.maxX
            }
            let texts = bottomNodes.flatMap { node -> [String] in
                [string(node, kAXTitleAttribute), string(node, kAXValueAttribute),
                 string(node, kAXDescriptionAttribute)]
            }.filter { !$0.isEmpty }
            guard !normalize(track.title).isEmpty, !normalize(track.artist).isEmpty,
                  texts.contains(where: { isMatchingText($0, expected: track.title) }),
                  texts.contains(where: { isMatchingText($0, expected: track.artist) }) else { continue }
            // Prefer a Like control close to the bottom, where the permanent
            // player controls are, rather than an item in the collection.
            var matches: [(AXUIElement, Bool, CGFloat)] = []
            for node in bottomNodes {
                let role = string(node, kAXRoleAttribute)
                guard role == (kAXButtonRole as String) || role == (kAXCheckBoxRole as String) else { continue }
                let text = label(node)
                guard !text.contains("не нравится") && !text.contains("dislike") &&
                      !text.contains("skip song") else { continue }
                guard text.contains("нрав") || text.contains("лайк") ||
                      text.contains("любим") || text.contains("liked") ||
                      text.contains("favorite") || text.contains("like-") else { continue }
                guard let state = likeStatus(node), let r = rect(node) else { continue }
                matches.append((node, state, r.midY))
            }
            // If multiple candidates are on the same footer line, refuse to
            // guess; clicking the wrong song would silently corrupt favorites.
            let ordered = matches.sorted { $0.2 > $1.2 }
            guard let highest = ordered.first else { continue }
            if ordered.count > 1 && abs(highest.2 - ordered[1].2) < 8 { continue }
            return Target(element: highest.0, saved: highest.1)
        }
        return nil
    }

    static func read(_ track: PlayingTrack) -> Bool? { findTarget(track)?.saved }

    static func write(_ track: PlayingTrack, target: Bool) -> Bool {
        guard let control = findTarget(track) else { return false }
        if control.saved == target { return true }
        guard AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success else { return false }
        // Reflect the real app state, not just a locally animated star.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.17)
            if read(track) == target { return true }
        }
        return false
    }

    static func availability(_ track: PlayingTrack) -> String {
        if !authorized { return "Нет разрешения Универсального доступа" }
        if runningYandex(track) == nil { return "Приложение Яндекс Музыки не найдено" }
        if findTarget(track) != nil { return "Найден и проверен лайк текущего трека" }
        return "Кнопка лайка или её состояние не доступны через macOS"
    }
}
