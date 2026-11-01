import Foundation

// Source switches apply only to artwork discovery. The original image supplied
// by the currently playing app/MediaRemote always takes precedence.
enum ArtworkProvider: String, CaseIterable {
    case yandex, spotify, youtube, apple, deezer

    var preferenceKey: String { "artworkProvider.\(rawValue).v312" }

    // Unlike UserDefaults.bool(forKey:), absent values mean ON for a new install.
    func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: preferenceKey) as? Bool) ?? true
    }

    static func pageProvider(for url: URL) -> ArtworkProvider? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        if host == "music.yandex.ru" || host == "music.yandex.com" { return .yandex }
        if host == "music.youtube.com" { return .youtube }
        return nil
    }
}

// Never download an arbitrary AXURL from another part of the Yandex UI.
// The desktop player may expose a CDN link on its actual artwork AXImage;
// these are public image URLs, NOT user tokens or album pages.
enum YandexArtworkURLPolicy {
    static func accept(_ value: Any) -> URL? {
        let url: URL?
        if let native = value as? URL { url = native }
        else if let string = value as? String { url = URL(string: string) }
        else { url = nil }
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        if host == "avatars.yandex.net" || host == "avatars.mds.yandex.net" {
            return url.path.contains("get-music-content") ? url : nil
        }
        return nil
    }
}

// Only accept a browser cover if the page metadata mentions both song and
// artist; never use the cover from an unrelated tab or a general search page.
struct ArtworkPageMatcher {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(pageTitle: String, song: String, artist: String) -> Bool {
        let page = normalized(pageTitle)
        let track = normalized(song)
        let creator = normalized(artist)
        // Require nontrivial metadata: a generic player homepage is not a cover.
        return track.count >= 3 && creator.count >= 2 &&
            page.contains(track) && page.contains(creator)
    }
}


// Keep lookup eligibility and browser track matching independently testable
// without the macOS AppKit SDK.
enum ArtworkLookupPolicy {
    static func canLoadDirectURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    static func hasCatalogMetadata(title: String, artist: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func sameTrack(pageTitle: String, pageArtist: String,
                          trackTitle: String, trackArtist: String) -> Bool {
        let actualTitle = ArtworkPageMatcher.normalized(pageTitle)
        let expectedTitle = ArtworkPageMatcher.normalized(trackTitle)
        guard !actualTitle.isEmpty, actualTitle == expectedTitle else { return false }
        let expectedArtist = ArtworkPageMatcher.normalized(trackArtist)
        let actualArtist = ArtworkPageMatcher.normalized(pageArtist)
        return expectedArtist.isEmpty || (actualArtist == expectedArtist ||
               (!actualArtist.isEmpty && (actualArtist.contains(expectedArtist) ||
                   expectedArtist.contains(actualArtist))))
    }
}

// Intentionally never writes song titles, artist names, search queries or
// full image URLs: troubleshooting does not require revealing listening data.
enum ArtworkDiagnostics {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchIsland-Artwork.log")
    private static let queue = DispatchQueue(label: "app.notchisland.artwork.log", qos: .utility)

    static func write(_ message: String) {
        queue.async {
            let path = fileURL
            let fileManager = FileManager.default
            let date = ISO8601DateFormatter().string(from: Date())
            let line = "\(date)  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !fileManager.fileExists(atPath: path.path) {
                _ = fileManager.createFile(atPath: path.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: path) else { return }
            defer { try? handle.close() }
            // Bound the log: no unlimited growth during periodic playback.
            if (try? fileManager.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0 > 250_000 {
                try? data.write(to: path, options: .atomic)
            } else {
                handle.seekToEndOfFile()
                handle.write(data)
            }
        }
    }
}
