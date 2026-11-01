import AppKit
import Foundation
import CryptoKit
import Combine
import Security

// Favorites are NEVER simulated. Apple Music is changed via Music's own
// AppleScript dictionary. Spotify requires an explicit Web API authorization.
// Unsupported publishers do not receive a star button.
enum FavoriteProviderKind {
    case appleMusic, spotify, yandexMusic
}

final class FavoritesController {
    var onState: ((String, Bool?, Bool) -> Void)?  // key, saved?, busy
    var onSpotifyConnection: ((String) -> Void)?
    var onYandexConnection: ((String) -> Void)?

    private let scripting = DispatchQueue(label: "app.notchisland.favorites.script", qos: .userInitiated)
    private let spotify = SpotifyLibraryClient()
    private let yandex = YandexAccountFavorites()
    private var observedKey = ""
    private var lastCheck = Date.distantPast
    private var revision = 0
    private var busy = false

    init() {
        spotify.onConnection = { [weak self] status in self?.onSpotifyConnection?(status) }
    }

    var yandexConnected: Bool { yandex.connected }
    var yandexAccessibilityGranted: Bool { YandexDesktopFavorites.authorized }
    func requestYandexAccessibility() { YandexDesktopFavorites.requestAuthorization() }
    func yandexLocalStatus(track: PlayingTrack?) -> String {
        guard let track else { return "Нет текущего трека" }
        let bundle = track.source == .system ? track.sourceBundle : track.source.bundleIdentifier
        return Self.isBrowser(bundle)
            ? "Браузер: проверяется кнопка на music.yandex.ru"
            : YandexDesktopFavorites.availability(track)
    }


    func connectYandex(token: String, completion: @escaping (Bool) -> Void) {
        scripting.async { [weak self] in
            guard let self else { return }
            let success = self.yandex.connect(token: token)
            DispatchQueue.main.async {
                self.invalidate()
                completion(success)
                self.onYandexConnection?(success ? "Яндекс Музыка: аккаунт подключён" : "Яндекс Музыка: ошибка подключения")
            }
        }
    }

    func disconnectYandex() {
        yandex.disconnect()
        invalidate()
        onYandexConnection?("Яндекс Музыка: аккаунт не подключён")
    }

    var spotifyConnected: Bool { spotify.connected }
    var spotifyClientID: String { spotify.clientID }

    func beginSpotifyConnection(clientID: String) {
        spotify.beginAuthorization(clientID: clientID)
    }

    func receiveSpotifyRedirect(_ url: URL) { spotify.receiveRedirect(url) }

    func disconnectSpotify() {
        spotify.disconnect()
        observedKey = ""
    }

    static func kind(for track: PlayingTrack) -> FavoriteProviderKind? {
        let bundle = track.source == .system ? track.sourceBundle : track.source.bundleIdentifier
        if bundle == "com.apple.Music" { return .appleMusic }
        if bundle == "com.spotify.client" { return .spotify }
        // Some Yandex Music builds publish a generic MediaRemote bundle id.
        // Prefer the process name, but never classify Safari/Chrome or other
        // applications just because Yandex Music is also running.
        let lowered = bundle.lowercased()
        let source = track.sourceName.lowercased()
        if source.contains("яндекс музыка") || source.contains("yandex music") ||
           (lowered.contains("yandex") && lowered.contains("music") &&
            !lowered.contains("browser")) {
            return .yandexMusic
        }
        // A web browser may publish Yandex Music through macOS Now Playing.
        // The bridge verifies the exact track and like button on the actual
        // Yandex Music tab before showing the star; other tabs are ignored.
        let browserBundles = ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
                              "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
                              "ru.yandex.desktop.yandex-browser", "ru.yandex.desktop.yandex-browser.beta"]
        if browserBundles.contains(bundle) || track.sourceName.localizedCaseInsensitiveContains("Яндекс") ||
            track.sourceName.localizedCaseInsensitiveContains("Yandex Music") {
            return .yandexMusic
        }
        return nil
    }

    static func isBrowser(_ bundle: String) -> Bool {
        let list = ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
                    "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
                    "ru.yandex.desktop.yandex-browser", "ru.yandex.desktop.yandex-browser.beta"]
        return list.contains(bundle)
    }

    static func key(for track: PlayingTrack) -> String {
        // Stable across MediaRemote updates, not across different songs.
        return track.artworkIdentity + "|" + (kind(for: track).map { "\($0)" } ?? "unsupported")
    }

    func invalidate() { lastCheck = .distantPast }

    func refresh(track: PlayingTrack?) {
        guard let track, let kind = Self.kind(for: track) else {
            // Publishing the same empty favorite state on every idle poll
            // causes needless view invalidations.
            if !observedKey.isEmpty {
                observedKey = ""
                revision += 1
                onState?("", nil, false)
            }
            return
        }
        let key = Self.key(for: track)
        if kind == .spotify && !spotify.connected {
            observedKey = key
            onState?(key, nil, false)
            return
        }
        let now = Date()
        // A delayed refresh must not override an optimistic star press.
        if busy { return }
        if observedKey == key && now.timeIntervalSince(lastCheck) < 8 { return }
        observedKey = key
        lastCheck = now
        revision += 1
        let version = revision
        // Keep the current star only if this is the same track; unknown
        // state must not masquerade as an unfavorited song.
        if kind == .appleMusic {
            scripting.async { [weak self] in
                let value = Self.musicScriptStatus(expected: track)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == version, self.observedKey == key else { return }
                    self.onState?(key, value, false)
                }
            }
        } else if kind == .yandexMusic {
            scripting.async { [weak self] in
                let bundle = track.source == .system ? track.sourceBundle : track.source.bundleIdentifier
                let browser = Self.isBrowser(bundle)
                let value: Bool?
                if !browser, let native = YandexDesktopFavorites.read(track) {
                    value = native
                } else if self?.yandex.connected == true &&
                          (!browser || YandexBrowserFavorites.verifiesCurrentTrack(track)) {
                    value = self?.yandex.read(track)
                } else if browser {
                    value = YandexBrowserFavorites.read(expected: track)
                } else {
                    value = nil
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == version, self.observedKey == key else { return }
                    self.onState?(key, value, false)
                }
            }
        } else {
            spotify.trackURI(expected: track) { [weak self] uri in
                guard let self else { return }
                guard let uri else {
                    self.complete(key: key, version: version, saved: nil, busy: false)
                    return
                }
                self.spotify.contains(uri: uri) { [weak self] value in
                    self?.complete(key: key, version: version, saved: value, busy: false)
                }
            }
        }
    }

    private func complete(key: String, version: Int, saved: Bool?, busy: Bool) {
        guard observedKey == key, revision == version else { return }
        onState?(key, saved, busy)
    }

    func change(track: PlayingTrack, to target: Bool, done: @escaping (Bool) -> Void) {
        guard let kind = Self.kind(for: track), !busy else { done(false); return }
        busy = true
        revision += 1  // invalidate any outstanding status response
        let key = Self.key(for: track)
        let version = revision
        let finish: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.busy = false
            self.lastCheck = .distantPast
            // Never alter the visible state of a different song.
            if key == self.observedKey && version == self.revision { done(success) }
        }
        if kind == .appleMusic {
            scripting.async {
                let result = Self.musicScriptChange(expected: track, to: target)
                DispatchQueue.main.async { finish(result) }
            }
        } else if kind == .yandexMusic {
            scripting.async { [weak self] in
                guard let self else { DispatchQueue.main.async { finish(false) }; return }
                let bundle = track.source == .system ? track.sourceBundle : track.source.bundleIdentifier
                let browser = Self.isBrowser(bundle)
                let verifiedBrowser = browser && YandexBrowserFavorites.verifiesCurrentTrack(track)
                let result: Bool
                if !browser, YandexDesktopFavorites.read(track) != nil {
                    result = YandexDesktopFavorites.write(track, target: target)
                } else if self.yandex.connected && (!browser || verifiedBrowser) {
                    result = self.yandex.write(track, target: target)
                } else if verifiedBrowser {
                    result = YandexBrowserFavorites.write(expected: track, to: target)
                } else {
                    result = false
                }
                DispatchQueue.main.async { finish(result) }
            }
        } else {
            guard spotify.connected else { busy = false; done(false); return }
            spotify.trackURI(expected: track) { [weak self] uri in
                guard let self, let uri else { finish(false); return }
                self.spotify.setSaved(uri: uri, saved: target, completion: finish)
            }
        }
    }

    private static func scriptValue(_ text: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: text) else { return nil }
        var error: NSDictionary?
        return script.executeAndReturnError(&error)
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func musicScriptStatus(expected: PlayingTrack) -> Bool? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").count > 0 else { return nil }
        let script = """
        try
            tell application id "com.apple.Music"
                set t to current track
                set sep to ASCII character 31
                return (name of t as text) & sep & (artist of t as text) & sep & (favorited of t as text)
            end tell
        on error
            return ""
        end try
        """
        guard let line = scriptValue(script)?.stringValue else { return nil }
        let parts = line.components(separatedBy: "\u{001F}")
        guard parts.count == 3,
              normalized(parts[0]) == normalized(expected.title),
              normalized(parts[1]) == normalized(expected.artist) else { return nil }
        return parts[2].lowercased() == "true"
    }

    private static func appleScriptString(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func musicScriptChange(expected: PlayingTrack, to value: Bool) -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").count > 0 else { return false }
        // Atomically check that Music is still playing the song originally
        // tapped, before writing its actual 'favorited' flag.
        let script = """
        try
            tell application id "com.apple.Music"
                set t to current track
                if (name of t as text) is not \(appleScriptString(expected.title)) then return "mismatch"
                if (artist of t as text) is not \(appleScriptString(expected.artist)) then return "mismatch"
                set favorited of t to \(value ? "true" : "false")
                if (favorited of t) is \(value ? "true" : "false") then return "ok"
            end tell
        on error
            return "failed"
        end try
        return "failed"
        """
        return scriptValue(script)?.stringValue == "ok"
    }
}

// Spotify's app scripting dictionary does not expose a saved/favorite flag.
// Authentication is per-user OAuth authorization-code + PKCE; credentials are
// NEVER sent to our own server. Tokens stay in macOS Keychain.
final class SpotifyLibraryClient {
    var onConnection: ((String) -> Void)?
    private(set) var clientID = UserDefaults.standard.string(forKey: "SpotifyFavoriteClientID") ?? ""
    private(set) var connected = false
    private let redirect = "notchisland://spotify-callback"
    private var verifier = ""
    private var oauthState = ""
    private var accessToken = ""
    private var validUntil = Date.distantPast
    private var refreshToken = ""

    init() {
        refreshToken = Self.keychainRead("spotify.refresh") ?? ""
        connected = !refreshToken.isEmpty && !clientID.isEmpty
    }

    func disconnect() {
        accessToken = ""
        refreshToken = ""
        validUntil = .distantPast
        connected = false
        Self.keychainDelete("spotify.refresh")
        onConnection?("Spotify: отключён")
    }

    func beginAuthorization(clientID: String) {
        let candidate = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            onConnection?("Spotify: неверный Client ID")
            return
        }
        self.clientID = candidate
        UserDefaults.standard.set(candidate, forKey: "SpotifyFavoriteClientID")
        let random = Self.randomBytes(40)
        verifier = Self.base64URL(random)
        oauthState = UUID().uuidString
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: candidate),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: "user-library-read user-library-modify"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(digest)),
            URLQueryItem(name: "state", value: oauthState)
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
        onConnection?("Spotify: ожидается вход в браузере")
    }

    func receiveRedirect(_ url: URL) {
        guard url.scheme == "notchisland", url.host == "spotify-callback" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        guard value("state") == oauthState, !verifier.isEmpty,
              let code = value("code"), value("error") == nil else {
            onConnection?("Spotify: вход не подтверждён")
            return
        }
        oauthState = ""
        let savedVerifier = verifier
        verifier = ""
        tokenRequest(["client_id": clientID, "grant_type": "authorization_code",
                      "code": code, "redirect_uri": redirect, "code_verifier": savedVerifier]) { [weak self] ok in
            self?.onConnection?(ok ? "Spotify: подключён" : "Spotify: не удалось получить доступ")
        }
    }

    func trackURI(expected: PlayingTrack, completion: @escaping (String?) -> Void) {
        // Source ID is obtained from the actual Spotify app, never guessed
        // from title search: otherwise we could save a different recording.
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            try
                tell application id "com.spotify.client"
                    set t to current track
                    set sep to ASCII character 31
                    return (id of t as text) & sep & (name of t as text) & sep & (artist of t as text)
                end tell
            on error
                return ""
            end try
            """
            var error: NSDictionary?
            let value = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? ""
            let parts = value.components(separatedBy: "\u{001F}")
            func normalize(_ s: String) -> String {
                s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let uri: String? = parts.count == 3 && parts[0].hasPrefix("spotify:track:") &&
                normalize(parts[1]) == normalize(expected.title) &&
                normalize(parts[2]) == normalize(expected.artist) ? parts[0] : nil
            DispatchQueue.main.async { completion(uri) }
        }
    }

    func contains(uri: String, completion: @escaping (Bool?) -> Void) {
        api(method: "GET", path: "/me/library/contains", uri: uri) { result in
            guard let data = result, let values = try? JSONSerialization.jsonObject(with: data) as? [Bool] else {
                completion(nil); return
            }
            completion(values.first)
        }
    }

    func setSaved(uri: String, saved: Bool, completion: @escaping (Bool) -> Void) {
        api(method: saved ? "PUT" : "DELETE", path: "/me/library", uri: uri) { data in
            completion(data != nil)
        }
    }

    private func api(method: String, path: String, uri: String, completion: @escaping (Data?) -> Void) {
        withAccessToken { [weak self] token in
            guard let self, let token else { completion(nil); return }
            var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
            if method == "GET" { components.queryItems = [URLQueryItem(name: "uris", value: uri)] }
            guard let url = components.url else { completion(nil); return }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if method != "GET" {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["uris": [uri]])
            }
            URLSession.shared.dataTask(with: req) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { completion((200..<300).contains(status) ? (data ?? Data()) : nil) }
            }.resume()
        }
    }

    private func withAccessToken(_ callback: @escaping (String?) -> Void) {
        if !accessToken.isEmpty && Date() < validUntil { callback(accessToken); return }
        guard !refreshToken.isEmpty, !clientID.isEmpty else { callback(nil); return }
        tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken,
                      "client_id": clientID]) { [weak self] ok in
            callback(ok ? self?.accessToken : nil)
        }
    }

    private func tokenRequest(_ fields: [String: String], done: @escaping (Bool) -> Void) {
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self, (200..<300).contains(status),
                      let token = json?["access_token"] as? String else { done(false); return }
                self.accessToken = token
                self.validUntil = Date().addingTimeInterval(Double(json?["expires_in"] as? Int ?? 3600) - 60)
                if let refresh = json?["refresh_token"] as? String {
                    self.refreshToken = refresh
                    Self.keychainSave("spotify.refresh", value: refresh)
                }
                self.connected = !self.refreshToken.isEmpty
                done(true)
            }
        }.resume()
    }

    private static func randomBytes(_ length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes)
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func keychainRead(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "app.notchisland.desktop",
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func keychainSave(_ key: String, value: String) {
        keychainDelete(key)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "app.notchisland.desktop",
                                   kSecAttrAccount as String: key,
                                   kSecValueData as String: Data(value.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }
    private static func keychainDelete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "app.notchisland.desktop",
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
