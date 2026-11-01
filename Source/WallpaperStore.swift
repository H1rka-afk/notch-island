import Foundation

// 3.9.4 — Pure parsing of ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist.
enum WallpaperStore {
    struct Choice: Equatable {
        var files: [String] = []      // absolute paths
        var assetIDs: [String] = []   // Aerial asset UUIDs (upper-case)
    }

    static var indexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    // The most recently set «Desktop» choice anywhere in the store (all
    // displays, a single display, a Space); «Idle» only when there is none.
    static func currentChoice(in root: Any) -> Choice? {
        var desktop: [(Date, Any)] = []
        var idle: [(Date, Any)] = []
        func walk(_ value: Any, key: String?) {
            if let dict = value as? [String: Any] {
                if let content = dict["Content"], key == "Desktop" || key == "Idle" {
                    let date = dict["LastSet"] as? Date ?? dict["LastUse"] as? Date ?? .distantPast
                    if key == "Desktop" { desktop.append((date, content)) } else { idle.append((date, content)) }
                }
                for (k, v) in dict { walk(v, key: k) }
            } else if let array = value as? [Any] {
                array.forEach { walk($0, key: key) }
            }
        }
        walk(root, key: nil)
        for list in [desktop, idle] {
            for (_, content) in list.sorted(by: { $0.0 > $1.0 }) {
                let choice = parse(content)
                if !choice.files.isEmpty || !choice.assetIDs.isEmpty { return choice }
            }
        }
        return nil
    }

    static func parse(_ content: Any) -> Choice {
        var strings: [String] = []
        collectStrings(content, into: &strings, depth: 0)
        var choice = Choice()
        for text in strings {
            if let path = filePath(text), !choice.files.contains(path) { choice.files.append(path) }
            for id in uuids(in: text) where !choice.assetIDs.contains(id) { choice.assetIDs.append(id) }
        }
        return choice
    }

    // Strings anywhere inside, including plists stored as Data (the
    // «Configuration» blob of a choice is itself a binary plist).
    static func collectStrings(_ value: Any, into strings: inout [String], depth: Int) {
        guard depth < 12 else { return }
        switch value {
        case let text as String: strings.append(text)
        case let url as URL: strings.append(url.absoluteString)
        case let dict as [String: Any]:
            for key in dict.keys.sorted() { collectStrings(dict[key]!, into: &strings, depth: depth + 1) }
        case let array as [Any]:
            array.forEach { collectStrings($0, into: &strings, depth: depth + 1) }
        case let data as Data:
            if let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                collectStrings(nested, into: &strings, depth: depth + 1)
            }
        default: break
        }
    }

    static let mediaExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "mov", "mp4"]

    static func filePath(_ text: String) -> String? {
        var path: String?
        if text.hasPrefix("file://") { path = URL(string: text)?.path }
        else if text.hasPrefix("/") || text.hasPrefix("~/") { path = (text as NSString).expandingTildeInPath }
        guard let path, mediaExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return path
    }

    static func uuids(in text: String) -> [String] {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).uppercased() }
        }
    }

    // Picks the best file for an Aerial asset among file names: a still
    // picture first (thumbnail/snapshot), otherwise the video.
    static func bestAsset(for id: String, among paths: [String]) -> String? {
        let matching = paths.filter { ($0 as NSString).lastPathComponent.uppercased().contains(id) }
        let stills = matching.filter { ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"].contains(($0 as NSString).pathExtension.lowercased()) }
        if let still = stills.first { return still }
        return matching.first { ["mov", "mp4"].contains(($0 as NSString).pathExtension.lowercased()) }
    }
}
