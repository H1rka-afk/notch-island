import Foundation

// Cover lookup in the Yandex Music catalog by title + artist.
//
// The native Yandex Music app announces its cover to macOS Now Playing
// (artworkAvailable, MIME type, size) but never delivers the image bytes, so
// neither Control Center nor Notch Island can show it. iTunes/Deezer rarely
// carry Russian releases. The catalog search used by Yandex Music's own
// clients answers anonymously; only the title and artist are sent, never
// account data. A cover is accepted ONLY when the title AND one of the
// artists match the playing track.
enum YandexCatalogArtwork {
    static let searchEndpoint = "https://api.music.yandex.net/search"

    // Most precise and fastest first: title + first artist, then title only.
    static func queries(title: String, artist: String) -> [String] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return [] }
        let first = artist
            .components(separatedBy: CharacterSet(charactersIn: ",&"))
            .first?
            .replacingOccurrences(of: "\\s+(feat\\.?|ft\\.?)\\s.*$", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var result: [String] = []
        if !first.isEmpty { result.append(cleanTitle + " " + first) }
        result.append(cleanTitle)
        return result
    }

    static func searchURL(query: String) -> URL? {
        var components = URLComponents(string: searchEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "text", value: query)
        ]
        return components?.url
    }

    static func key(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
    }

    // Returns the verified 400×400 cover URL from a search response, or nil.
    static func coverURL(fromSearchResponse data: Data, title: String, artist: String) -> URL? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tracks = (result["tracks"] as? [String: Any])?["results"] as? [[String: Any]] else {
            return nil
        }
        let wantedTitle = key(title)
        let wantedArtist = key(artist)
        guard !wantedTitle.isEmpty, !wantedArtist.isEmpty else { return nil }
        for track in tracks.prefix(20) {
            let baseTitle = track["title"] as? String ?? ""
            let version = track["version"] as? String ?? ""
            let titles = [baseTitle, version.isEmpty ? "" : "\(baseTitle) (\(version))"]
                .map(key).filter { !$0.isEmpty }
            guard titles.contains(wantedTitle) else { continue }
            let artists = ((track["artists"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }
                .map(key)
                .filter { $0.count >= 2 }
            // Now Playing often joins several artists ("A, B"); each catalog
            // artist must appear in that string. The reverse direction is NOT
            // accepted: "Другой" must not match "Другой исполнитель".
            guard artists.contains(where: { wantedArtist.contains($0) }) else { continue }
            let albums = (track["albums"] as? [[String: Any]]) ?? []
            let raw = (track["coverUri"] as? String)
                ?? albums.lazy.compactMap { $0["coverUri"] as? String }.first
                ?? (track["ogImage"] as? String)
            if let url = coverURL(fromURI: raw) { return url }
        }
        return nil
    }

    // "avatars.yandex.net/get-music-content/…/%%" → https URL at 400×400.
    // Only Yandex image hosts are accepted.
    static func coverURL(fromURI raw: String?) -> URL? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "%%", with: "400x400")
        if value.hasPrefix("//") { value = "https:" + value }
        if !value.hasPrefix("http") { value = "https://" + value }
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "avatars.yandex.net" || host.hasSuffix(".yandex.net") else { return nil }
        return url
    }
}
