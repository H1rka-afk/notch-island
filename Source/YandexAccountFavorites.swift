import AppKit
import Foundation
import Security

// Cross-player favorite integration for an explicitly authorized Yandex account.
// API endpoints are unofficial and may change. Fail closed when a track is
// ambiguous or when the server does not confirm a favorite operation.
final class YandexAccountFavorites {
    private let service = "app.notchisland.yandex-music.oauth"
    private let account = "user-token"
    private var cachedUID: String?
    private var cachedLikes: Set<String>?
    private var likesFetchedAt = Date.distantPast
    private var resolvedTracks: [String: String] = [:]
    private let apiRoot = "https://api.music.yandex.net"

    var connected: Bool { token != nil }

    private var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func connect(token newToken: String) -> Bool {
        let value = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count < 4096,
              let uid = accountUID(using: value) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var save = query
        save[kSecValueData as String] = Data(value.utf8)
        save[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(save as CFDictionary, nil) == errSecSuccess else { return false }
        cachedUID = uid
        cachedLikes = nil
        resolvedTracks.removeAll()
        return true
    }

    func disconnect() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        cachedUID = nil
        cachedLikes = nil
        resolvedTracks.removeAll()
    }

    private func query(_ path: String, token: String, method: String = "GET",
                       parameters: [URLQueryItem] = [], form: String? = nil) -> [String: Any]? {
        guard var components = URLComponents(string: apiRoot + path) else { return nil }
        if !parameters.isEmpty { components.queryItems = parameters }
        guard let url = components.url, url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("NotchIsland/2.5", forHTTPHeaderField: "User-Agent")
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
        }
        let lock = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultStatus = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            resultData = data
            resultStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            lock.signal()
        }.resume()
        guard lock.wait(timeout: .now() + 9) == .success,
              (200...299).contains(resultStatus), let resultData,
              let json = try? JSONSerialization.jsonObject(with: resultData),
              let value = json as? [String: Any] else { return nil }
        if value["error"] != nil { return nil }
        return value
    }

    private func result(_ json: [String: Any]) -> [String: Any] {
        (json["result"] as? [String: Any]) ?? json
    }

    private func accountUID(using token: String) -> String? {
        guard let response = query("/account/status", token: token) else { return nil }
        let body = result(response)
        let user = body["account"] as? [String: Any] ?? [:]
        if let uid = user["uid"] as? NSNumber { return uid.stringValue }
        if let uid = user["uid"] as? String, !uid.isEmpty { return uid }
        return nil
    }

    private func uid(token: String) -> String? {
        if let cachedUID { return cachedUID }
        cachedUID = accountUID(using: token)
        return cachedUID
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func idString(_ value: Any?) -> String? {
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v.stringValue }
        return nil
    }

    // Resolve current song by both title and artist. Never silently like the
    // first search hit when several different recordings could match.
    private func trackID(for track: PlayingTrack, token: String) -> String? {
        let key = Self.normalize(track.title) + "|" + Self.normalize(track.artist)
        if let existing = resolvedTracks[key] { return existing }
        guard !Self.normalize(track.artist).isEmpty,
              let response = query("/search", token: token, parameters: [
                URLQueryItem(name: "text", value: "\(track.title) \(track.artist)"),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "page", value: "0")
              ]) else { return nil }
        let content = result(response)
        let block = content["tracks"] as? [String: Any] ?? [:]
        let candidates = block["results"] as? [[String: Any]] ?? []
        var ids = Set<String>()
        for candidate in candidates {
            let title = (candidate["title"] as? String) ?? ""
            let artistNames = (candidate["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            let nameMatches = artistNames.contains { artist in
                Self.normalize(artist) == Self.normalize(track.artist) ||
                Self.normalize(track.artist).contains(Self.normalize(artist)) && !Self.normalize(artist).isEmpty
            }
            guard Self.normalize(title) == Self.normalize(track.title), nameMatches,
                  let id = idString(candidate["id"]) else { continue }
            ids.insert(id)
        }
        guard ids.count == 1, let id = ids.first else { return nil }
        resolvedTracks[key] = id
        return id
    }

    private func likedIDs(token: String, uid: String, ignoreCache: Bool = false) -> Set<String>? {
        if !ignoreCache, let cachedLikes,
           Date().timeIntervalSince(likesFetchedAt) < 30 { return cachedLikes }
        guard let response = query("/users/\(uid)/likes/tracks", token: token) else { return nil }
        let content = result(response)
        let library = content["library"] as? [String: Any] ?? [:]
        guard let tracks = library["tracks"] as? [[String: Any]] else { return nil }
        let ids = Set(tracks.compactMap { idString($0["id"]) })
        cachedLikes = ids
        likesFetchedAt = Date()
        return ids
    }

    func read(_ track: PlayingTrack) -> Bool? {
        guard let token, let uid = uid(token: token),
              let id = trackID(for: track, token: token),
              let ids = likedIDs(token: token, uid: uid) else { return nil }
        return ids.contains(id)
    }

    func write(_ track: PlayingTrack, target: Bool) -> Bool {
        guard let token, let uid = uid(token: token),
              let id = trackID(for: track, token: token),
              let current = likedIDs(token: token, uid: uid) else { return false }
        if current.contains(id) == target { return true }
        let route = target ? "add-multiple" : "remove"
        let body = "track-ids=" + (id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)
        guard let response = query("/users/\(uid)/likes/tracks/\(route)", token: token,
                                   method: "POST", form: body),
              result(response)["revision"] != nil else { return false }
        cachedLikes = nil
        guard let verified = likedIDs(token: token, uid: uid, ignoreCache: true) else { return false }
        return verified.contains(id) == target
    }
}
