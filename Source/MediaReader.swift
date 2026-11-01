import AppKit
import Foundation
import Darwin

// macOS has no public API that allows a third-party utility to read the
// currently playing item from *other* apps. We use the private MediaRemote
// Now Playing service via the system's /usr/bin/osascript (JXA), with a
// safe AppleScript fallback for Music / Spotify. Apple can change this API.
enum MusicSource: String {
    case system
    case appleMusic
    case spotify

    var bundleIdentifier: String {
        switch self {
        case .system: return ""
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }
    var label: String {
        switch self {
        case .system: return "Сейчас исполняется"
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }
}

struct PlayingTrack: Equatable {
    var source: MusicSource
    var sourceName: String
    var sourceBundle: String
    var title: String
    var artist: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var artworkURL: URL?

    // Keep the visual identity stable while the progress bar advances or the
    // system temporarily changes its underlying Now Playing source.
    var identity: String { "\(title)|\(artist)|\(sourceBundle)" }

    // Album artwork belongs to the SONG, not the app that publishes it.
    // MediaRemote can alternate between the browser, its parent application,
    // Spotify, or an empty bundle id for the very same song. A source-based
    // cache key made the visible cover disappear every time that happened.
    // Old v1.9 storage key. Preserve it to migrate disk caches without
    // invalidating the artwork users have already downloaded.
    var legacyArtworkIdentity: String {
        func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        return normalize(title) + "|" + normalize(artist)
    }

    // Cosmetic differences in metadata (punctuation, feat., etc.) must NOT
    // evict artwork while the underlying song is the same. Keep the artist
    // in the key to prevent conflating unrelated recordings of a song.
    var artworkIdentity: String {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
                .replacingOccurrences(of: "[\\(\\[]?(?:feat\\.?|ft\\.?|featuring)\\s+[^\\)\\]]*[\\)\\]]?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized(title) + "|" + normalized(artist)
    }
}

enum PlaybackCommand: Equatable {
    case toggle
    case next
    case previous
}

final class MediaReader {
    private let queue = DispatchQueue(label: "app.notchisland.media", qos: .utility)
    // Playback commands must never wait behind expensive metadata queries.
    private let commandQueue = DispatchQueue(label: "app.notchisland.commands", qos: .userInitiated)
    private let artworkQueue = DispatchQueue(label: "app.notchisland.artwork", qos: .userInitiated)
    private let artworkFolder: URL = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("NotchIsland/TrackArtwork", isDirectory: true)
    }()
    private func artworkFile(for identity: String) -> URL {
        // FNV-1a gives a stable non-identifying file name, unlike hashValue.
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            value = (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return artworkFolder.appendingPathComponent(String(format: "%016llx", value) + ".png")
    }
    private var remoteArtworkAttempted: [String: Date] = [:]
    private var remoteArtworkAttemptSignature: [String: String] = [:]
    private var artworkInFlight = Set<String>()
    // Accessed ONLY on artworkQueue; avoids shared mutable closure captures
    // when the two catalog callbacks finish on different URLSession threads.
    private var artworkCatalogOutstanding: [String: Int] = [:]
    private var remoteArtworkCache: [String: NSImage] = [:]
    private var cachedArtKey = ""
    private var cachedArt: NSImage?
    private var lastArtAttempt = Date.distantPast
    private var spotifyArtURL: URL?
    private var spotifyArtKey = ""
    private var lastSpotifyAttempt = Date.distantPast
    private var lastSystemArtKey = ""
    private var lastSystemArt: NSImage?

    // MARK: 3.8.0 — live Now Playing stream
    // One long-lived Apple osascript process watches MediaRemote and writes a
    // JSON line only when something changes (track, play/pause, source, a
    // seek), plus a heartbeat every 10 s. Changes reach the island within
    // ~0.25 s, and regular polls no longer start a process every second.
    // If the stream stops, the old per-poll reading takes over by itself.
    var onStreamChange: (() -> Void)?
    private var stream: Process?
    private var streamBuffer = Data()
    private var streamPayload: [String: Any]?
    private var streamLastLine = Date.distantPast
    private var streamRestarts = 0
    private var streamStopped = false

    private var streamHealthy: Bool {
        (stream?.isRunning ?? false) && Date().timeIntervalSince(streamLastLine) < 25
    }

    var streamStatus: String {
        streamHealthy ? "мгновенно (живой поток)" : "опрос раз в 1–3 с (поток недоступен)"
    }

    func startStream() {
        queue.async { [weak self] in
            self?.streamStopped = false
            self?.launchStream()
        }
    }

    func stopStream() {
        queue.async { [self] in
            streamStopped = true
            stream?.terminationHandler = nil
            if stream?.isRunning == true { stream?.terminate() }
            stream = nil
            streamPayload = nil
        }
    }

    private func launchStream() {
        guard !streamStopped, !(stream?.isRunning ?? false) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.nowPlayingStreamJXA]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consumeStream(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.stream = nil
                self.streamPayload = nil
                self.streamBuffer.removeAll()
                guard !self.streamStopped else { return }
                // Back off: 2 s, 4 s … up to a minute.
                self.streamRestarts += 1
                let delay = min(60, pow(2, Double(min(self.streamRestarts, 6))))
                ArtworkDiagnostics.write("now playing stream ended; restart in \(Int(delay)) s")
                self.queue.asyncAfter(deadline: .now() + delay) { self.launchStream() }
            }
        }
        do {
            try process.run()
            stream = process
            ArtworkDiagnostics.write("now playing stream started")
        } catch {
            ArtworkDiagnostics.write("now playing stream could not start")
        }
    }

    private func consumeStream(_ data: Data) {
        streamBuffer.append(data)
        var changed = false
        while let end = streamBuffer.firstIndex(of: 0x0A) {
            let line = streamBuffer[streamBuffer.startIndex..<end]
            streamBuffer.removeSubrange(streamBuffer.startIndex...end)
            guard var payload = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            streamLastLine = Date()
            streamRestarts = 0
            if payload["error"] != nil { continue }
            let isHeartbeat = payload["heartbeat"] as? Bool ?? false
            payload["heartbeat"] = nil
            // Artwork is sent once per song; keep it for the same song.
            if payload["artwork"] == nil, let previous = streamPayload,
               previous["Title"] as? String == payload["Title"] as? String,
               previous["Artist"] as? String == payload["Artist"] as? String {
                payload["artwork"] = previous["artwork"]
            }
            streamPayload = payload
            if !isHeartbeat { changed = true }
        }
        if changed { DispatchQueue.main.async { [weak self] in self?.onStreamChange?() } }
    }

    func poll(spotifyRunning: Bool, musicRunning: Bool,
              completion: @escaping (PlayingTrack?, NSImage?) -> Void) {
        queue.async {
            // System Now Playing covers Safari/Chrome/Firefox/YouTube, QuickTime,
            // Music/Spotify, and other apps when they publish metadata to macOS.
            let system = self.readSystemNowPlaying()
            if var systemTrack = system?.0, systemTrack.isPlaying {
                var artwork = system?.1
                // JXA often provides metadata but no ArtworkData. Fill in a
                // source-specific image without throwing away the system track.
                if artwork == nil && self.lastSystemArtKey == systemTrack.artworkIdentity {
                    artwork = self.lastSystemArt
                }
                // MediaRemote frequently supplies the title before the
                // artwork. Ask the *actual playing app* for its track artwork,
                // and only attach it if the title + artist match our system
                // track. Never substitute a Spotify/Music app icon.
                if artwork == nil && systemTrack.artworkURL == nil && spotifyRunning && ArtworkProvider.spotify.isEnabled() {
                    let key = systemTrack.artworkIdentity
                    if self.spotifyArtKey != key || Date().timeIntervalSince(self.lastSpotifyAttempt) > 7 {
                        self.spotifyArtKey = key
                        self.lastSpotifyAttempt = Date()
                        self.spotifyArtURL = nil
                        if let spotify = self.readAppleScript(.spotify),
                           Self.sameSong(spotify, systemTrack) {
                            self.spotifyArtURL = spotify.artworkURL
                        }
                    }
                    systemTrack.artworkURL = self.spotifyArtURL
                }
                if artwork == nil && systemTrack.artworkURL == nil && musicRunning && ArtworkProvider.apple.isEnabled() {
                    // Check the music identity before requesting Apple Music
                    // artwork, to avoid displaying an unrelated album.
                    if let music = self.readAppleScript(.appleMusic),
                       Self.sameSong(music, systemTrack) {
                        artwork = self.cachedMusicArtwork(key: "\(music.title)|\(music.artist)")
                    }
                }
                DispatchQueue.main.async { completion(systemTrack, artwork) }
                return
            }
            var candidates: [(PlayingTrack, NSImage?)] = []
            if spotifyRunning, ArtworkProvider.spotify.isEnabled(), let spotify = self.readAppleScript(.spotify) {
                candidates.append((spotify, nil))
            }
            if musicRunning, ArtworkProvider.apple.isEnabled(), let music = self.readAppleScript(.appleMusic) {
                let art = self.cachedMusicArtwork(key: "\(music.title)|\(music.artist)")
                candidates.append((music, art))
            }
            if let sys = system { candidates.append(sys) }
            // The system's paused Now Playing item is the most relevant paused
            // candidate; prioritize it over stale, paused Spotify/Music items.
            // A truly playing candidate still takes priority over a paused one.
            let chosen = candidates.first(where: { $0.0.isPlaying })
                ?? system ?? candidates.first
            DispatchQueue.main.async { completion(chosen?.0, chosen?.1) }
        }
    }

    // MediaRemote or Apple Music sometimes returns the cover directly.
    // Save THAT actual cover to persistent cache; it is more reliable than
    // relying on catalog network lookups after every new launch.
    func rememberArtwork(_ image: NSImage, for track: PlayingTrack) {
        let identity = track.artworkIdentity
        artworkQueue.async { [weak self] in
            guard let self, self.remoteArtworkCache[identity] == nil else { return }
            self.remoteArtworkCache[identity] = image
            if let data = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: self.artworkFolder, withIntermediateDirectories: true)
                try? data.write(to: self.artworkFile(for: identity), options: .atomic)
            }
        }
    }

    // User-requested refresh. Only the negative retry window is reset; a
    // good cached cover remains available immediately on later plays.
    func retryArtworkLookup(for track: PlayingTrack) {
        artworkQueue.async { [weak self] in
            self?.remoteArtworkAttempted.removeValue(forKey: track.artworkIdentity)
            self?.remoteArtworkAttemptSignature.removeValue(forKey: track.artworkIdentity)
            ArtworkDiagnostics.write("manual retry requested")
        }
    }

    // MediaRemote artwork is often absent. Spotify gives a direct URL; for
    // catalogued music we optionally search Apple's public iTunes catalog.
    // This is best-effort and NEVER substitutes an application icon.
    // Titles and artists in the query are sent to Apple when fallback is used.
    func requestArtwork(for track: PlayingTrack,
                        completion: @escaping (String, NSImage?) -> Void) {
        let identity = track.artworkIdentity
        artworkQueue.async { [weak self] in
            guard let self = self else { return }
            if let cached = self.remoteArtworkCache[identity] {
                DispatchQueue.main.async { completion(identity, cached) }
                return
            }
            // Fast path: repeated tracks show their cover without waiting for
            // the network. Migrate files created by v1.8, which used to put
            // the publishing app bundle identifier in the artwork cache key.
            let location = self.artworkFile(for: identity)
            let legacyLocation = self.artworkFile(for: track.identity)
            let previousCache = self.artworkFile(for: track.legacyArtworkIdentity)
            for candidate in [location, previousCache, legacyLocation] {
                if let bytes = try? Data(contentsOf: candidate), let cached = NSImage(data: bytes) {
                    self.remoteArtworkCache[identity] = cached
                    if candidate != location {
                        try? FileManager.default.createDirectory(at: self.artworkFolder, withIntermediateDirectories: true)
                        try? bytes.write(to: location, options: .atomic)
                    }
                    DispatchQueue.main.async { completion(identity, cached) }
                    return
                }
            }
            // MediaRemote often publishes a direct artwork URL BEFORE artist
            // metadata. Never discard that genuine image merely because the
            // catalog matching fields have not arrived yet.
            let canSearchCatalog = ArtworkLookupPolicy.hasCatalogMetadata(
                title: track.title, artist: track.artist)
            let validDirect = ArtworkLookupPolicy.canLoadDirectURL(track.artworkURL)
            let appleEnabled = canSearchCatalog && ArtworkProvider.apple.isEnabled()
            let deezerEnabled = canSearchCatalog && ArtworkProvider.deezer.isEnabled()
            let browserEnabled = Self.isMusicBrowser(track.sourceBundle) &&
                (ArtworkProvider.youtube.isEnabled() || ArtworkProvider.yandex.isEnabled())
            // The native Yandex app announces a cover to macOS but never hands
            // over its bytes; its own catalog is the reliable source. Russian
            // releases from any player benefit, so it is not app-specific.
            let yandexCatalogEnabled = canSearchCatalog && ArtworkProvider.yandex.isEnabled()
            let jobCount = (validDirect ? 1 : 0) + (appleEnabled ? 1 : 0)
                + (deezerEnabled ? 1 : 0) + (browserEnabled ? 1 : 0)
                + (yandexCatalogEnabled ? 1 : 0)
            if jobCount == 0 {
                ArtworkDiagnostics.write("skipped: no eligible source; title=\(!track.title.isEmpty) artist=\(!track.artist.isEmpty) browser=\(Self.isMusicBrowser(track.sourceBundle))")
                return
            }
            // Retry immediately when a direct URL or artist arrives after a
            // previously failed search. Throttle only IDENTICAL attempts.
            let signature = "\(track.artist.isEmpty ? "no-artist" : "artist")|\(track.artworkURL?.absoluteString ?? "no-direct")|\(jobCount)"
            if self.artworkInFlight.contains(identity) { return }
            if let attempted = self.remoteArtworkAttempted[identity],
               self.remoteArtworkAttemptSignature[identity] == signature,
               Date().timeIntervalSince(attempted) < 45 { return }
            self.remoteArtworkAttempted[identity] = Date()
            self.remoteArtworkAttemptSignature[identity] = signature
            self.artworkInFlight.insert(identity)
            self.artworkCatalogOutstanding[identity] = jobCount
            ArtworkDiagnostics.write("search started: source=\(track.sourceBundle.isEmpty ? "unknown" : track.sourceBundle) direct=\(validDirect) iTunes=\(appleEnabled) Deezer=\(deezerEnabled) browser=\(browserEnabled) yandexCatalog=\(yandexCatalogEnabled) artistPresent=\(!track.artist.isEmpty)")

            func fetchImage(_ url: URL, done: @escaping (NSImage?) -> Void) {
                var request = URLRequest(url: url)
                request.timeoutInterval = 4
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    guard let data = data, !data.isEmpty, data.count < 8_000_000,
                          let image = NSImage(data: data), image.isValid else {
                        ArtworkDiagnostics.write("image download rejected: host=\(url.host ?? "unknown")")
                        done(nil)
                        return
                    }
                    done(image)
                }.resume()
            }
            func publish(_ image: NSImage?, source: String = "unknown") {
                self.artworkQueue.async {
                    // Concurrent catalogs race to return the FIRST genuine
                    // matching cover. Never publish a second/stale result.
                    guard self.artworkInFlight.remove(identity) != nil else { return }
                    self.artworkCatalogOutstanding.removeValue(forKey: identity)
                    if let image = image {
                        self.remoteArtworkCache[identity] = image
                        if let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) {
                            try? FileManager.default.createDirectory(at: self.artworkFolder, withIntermediateDirectories: true)
                            try? png.write(to: self.artworkFile(for: identity), options: .atomic)
                        }
                    }
                    ArtworkDiagnostics.write(image == nil ? "all enabled sources returned no verified image" : "cover loaded and cached: provider=\(source)")
                    DispatchQueue.main.async { completion(identity, image) }
                }
            }
            // Apple and Deezer used to run SEQUENTIALLY: six seconds waiting
            // for Apple's response before Deezer could even start. Search
            // both at once; publish the first image whose title AND artist
            // really match. Only report failure if both searches fail.
            func catalogResolved(_ image: NSImage?, source: String) {
                self.artworkQueue.async {
                    guard self.artworkInFlight.contains(identity) else { return }
                    if let image {
                        publish(image, source: source)
                    } else {
                        let remaining = (self.artworkCatalogOutstanding[identity] ?? 1) - 1
                        self.artworkCatalogOutstanding[identity] = remaining
                        if remaining == 0 { publish(nil) }
                    }
                }
            }
            func searchDeezer() {
                var components = URLComponents(string: "https://api.deezer.com/search")!
                components.queryItems = [
                    URLQueryItem(name: "q", value: "\(track.title) \(track.artist)"),
                    URLQueryItem(name: "limit", value: "30")
                ]
                guard let url = components.url else { catalogResolved(nil, source: "Deezer"); return }
                var req = URLRequest(url: url)
                req.timeoutInterval = 6
                URLSession.shared.dataTask(with: req) { data, response, _ in
                    guard let data = data,
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["data"] as? [[String: Any]] else {
                        ArtworkDiagnostics.write("Deezer search unavailable: HTTP=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
                        catalogResolved(nil, source: "Deezer")
                        return
                    }
                    let wantedTitle = Self.catalogKey(track.title)
                    let wantedArtist = Self.catalogKey(track.artist)
                    let matched = results.first { result in
                        let artist = Self.catalogKey((result["artist"] as? [String: Any])?["name"] as? String ?? "")
                        let title = Self.catalogKey(result["title_short"] as? String ?? result["title"] as? String ?? "")
                        return !title.isEmpty && title == wantedTitle &&
                            !artist.isEmpty && (artist == wantedArtist ||
                               artist.contains(wantedArtist) || wantedArtist.contains(artist))
                    }
                    if matched == nil { ArtworkDiagnostics.write("Deezer returned no matching title/artist") }
                    guard let album = matched?["album"] as? [String: Any],
                          let rawURL = (album["cover_big"] as? String) ?? (album["cover_medium"] as? String),
                          let artURL = URL(string: rawURL), artURL.scheme == "https" else {
                        catalogResolved(nil, source: "Deezer")
                        return
                    }
                    fetchImage(artURL) { image in catalogResolved(image, source: "Deezer") }
                }.resume()
            }
            // Precise query first (title + first artist, ~0.2 s), then the
            // title alone. A cover is accepted only for a verified match.
            func searchYandexCatalog(_ queries: [String]) {
                guard let query = queries.first, let url = YandexCatalogArtwork.searchURL(query: query) else {
                    ArtworkDiagnostics.write("Yandex catalog returned no matching title/artist")
                    catalogResolved(nil, source: "Yandex catalog")
                    return
                }
                var req = URLRequest(url: url)
                req.timeoutInterval = 6
                URLSession.shared.dataTask(with: req) { data, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let data, status == 200 else {
                        ArtworkDiagnostics.write("Yandex catalog unavailable: HTTP=\(status) timeout=\((error as NSError?)?.code == NSURLErrorTimedOut)")
                        // A slow first response must not hide the faster fallback query.
                        searchYandexCatalog(Array(queries.dropFirst()))
                        return
                    }
                    guard let cover = YandexCatalogArtwork.coverURL(fromSearchResponse: data,
                                                                   title: track.title, artist: track.artist) else {
                        searchYandexCatalog(Array(queries.dropFirst()))
                        return
                    }
                    fetchImage(cover) { image in catalogResolved(image, source: "Yandex catalog") }
                }.resume()
            }
            func searchCatalog() {
                var components = URLComponents(string: "https://itunes.apple.com/search")!
                components.queryItems = [
                    URLQueryItem(name: "term", value: "\(track.title) \(track.artist)"),
                    URLQueryItem(name: "media", value: "music"),
                    URLQueryItem(name: "entity", value: "song"),
                    URLQueryItem(name: "limit", value: "30")
                ]
                guard let url = components.url else { catalogResolved(nil, source: "iTunes"); return }
                var req = URLRequest(url: url)
                req.timeoutInterval = 6
                URLSession.shared.dataTask(with: req) { data, response, _ in
                    guard let data = data,
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = value["results"] as? [[String: Any]] else {
                        ArtworkDiagnostics.write("iTunes search unavailable: HTTP=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
                        catalogResolved(nil, source: "iTunes")
                        return
                    }
                    let expectedTitle = Self.catalogKey(track.title)
                    let expectedArtist = Self.catalogKey(track.artist)
                    let urlString = results.first(where: { result in
                        let title = Self.catalogKey(result["trackName"] as? String ?? "")
                        let artist = Self.catalogKey(result["artistName"] as? String ?? "")
                        return !title.isEmpty && title == expectedTitle
                            && (artist == expectedArtist || (!artist.isEmpty && !expectedArtist.isEmpty &&
                                (artist.contains(expectedArtist) || expectedArtist.contains(artist))))
                    })?["artworkUrl100"] as? String
                    if urlString == nil { ArtworkDiagnostics.write("iTunes returned no matching title/artist") }
                    guard let string = urlString,
                          let artwork = URL(string: string.replacingOccurrences(of: "100x100bb", with: "400x400bb")),
                          artwork.scheme == "https" else { catalogResolved(nil, source: "iTunes"); return }
                    fetchImage(artwork) { image in catalogResolved(image, source: "iTunes") }
                }.resume()
            }
            // A real URL supplied by the player gets a short head start.
            // Catalog requests then run in parallel; stale/slow sources never
            // delay the main media view and the first verified image wins.
            if validDirect, let direct = track.artworkURL {
                fetchImage(direct) { image in catalogResolved(image, source: "player URL") }
            }
            self.artworkQueue.asyncAfter(deadline: .now() + (validDirect ? 0.35 : 0)) {
                guard self.artworkInFlight.contains(identity) else { return }
                if appleEnabled { searchCatalog() }
                if deezerEnabled { searchDeezer() }
                if browserEnabled {
                    Self.searchPlayingBrowserPage(track: track) { url in
                        guard let url else { catalogResolved(nil, source: "browser Media Session"); return }
                        fetchImage(url) { image in catalogResolved(image, source: "browser Media Session") }
                    }
                }
                if yandexCatalogEnabled {
                    searchYandexCatalog(YandexCatalogArtwork.queries(title: track.title, artist: track.artist))
                }
            }
            // Accessibility calls can hang on a busy app. Never leave this
            // track permanently "in flight" if the desktop app does not reply.
            self.artworkQueue.asyncAfter(deadline: .now() + 16) {
                if self.artworkInFlight.contains(identity) {
                    ArtworkDiagnostics.write("artwork search timed out after 16s")
                    publish(nil)
                }
            }
        }
    }

    // The Yandex Music and YouTube Music adapters operate on the ACTUAL
    // playing browser tab, not on unofficial search endpoints or guessed video
    // thumbnails. Public page metadata is a best-effort fallback only.
    // The user's browser may ask for Apple Events automation permission.
    private static func isMusicBrowser(_ bundle: String) -> Bool {
        switch bundle {
        case "com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
             "com.microsoft.edgemac", "org.chromium.Chromium":
            return true
        default:
            return false
        }
    }

    private static func searchPlayingBrowserPage(track: PlayingTrack,
                                                 completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let script: String
            switch track.sourceBundle {
            case "com.apple.Safari":
                script = "tell application id \"com.apple.Safari\" to get URL of current tab of front window"
            case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium":
                script = "tell application id \"\(track.sourceBundle)\" to get URL of active tab of front window"
            default:
                completion(nil)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { completion(nil); return }
            let stop = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: stop)
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stop.cancel()
            guard process.terminationStatus == 0,
                  let value = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let pageURL = URL(string: value),
                  let actualProvider = ArtworkProvider.pageProvider(for: pageURL),
                  actualProvider.isEnabled() else { completion(nil); return }
            // A browser's Media Session exposes artwork for its ACTUAL
            // playing track, even when its public HTML contains only a generic
            // Yandex/YouTube thumbnail. This is optional: browsers can disable
            // JavaScript via Apple Events, so HTML metadata remains a fallback.
            if let native = Self.browserMediaSessionArtwork(track: track) {
                ArtworkDiagnostics.write("browser MediaSession provided verified artwork")
                completion(native)
                return
            }
            // Source is determined by the currently playing website, not by
            // the browser application. Both Yandex and YouTube are supported.
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 5
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let responseURL = response?.url,
                      ArtworkProvider.pageProvider(for: responseURL) == actualProvider,
                      let data, data.count < 1_500_000,
                      let html = String(data: data, encoding: .utf8) else {
                    completion(nil)
                    return
                }
                let title = Self.htmlMeta("og:title", html: html) ?? Self.htmlMeta("twitter:title", html: html)
                let image = Self.htmlMeta("og:image", html: html) ?? Self.htmlMeta("twitter:image", html: html)
                guard let title, ArtworkPageMatcher.matches(pageTitle: Self.htmlDecode(title),
                                                              song: track.title, artist: track.artist),
                      let image, let url = URL(string: Self.htmlDecode(image), relativeTo: responseURL)?.absoluteURL,
                      url.scheme?.lowercased() == "https" else {
                    completion(nil)
                    return
                }
                completion(url)
            }.resume()
        }
    }

    private static func browserMediaSessionArtwork(track: PlayingTrack) -> URL? {
        guard !track.title.isEmpty else { return nil }
        let javascript = """
        (function() {
          var m = navigator.mediaSession && navigator.mediaSession.metadata;
          if (!m) return '';
          return JSON.stringify({title:m.title||'',artist:m.artist||'',artwork:m.artwork||[]});
        })()
        """.replacingOccurrences(of: "\n", with: " ")
        let quoted = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if track.sourceBundle == "com.apple.Safari" {
            script = "tell application id \"com.apple.Safari\" to do JavaScript \"\(quoted)\" in current tab of front window"
        } else {
            script = "tell application id \"\(track.sourceBundle)\" to execute active tab of front window javascript \"\(quoted)\""
        }
        guard let value = executeAppleScript(script)?.stringValue,
              let data = value.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = payload["title"] as? String,
              let artist = payload["artist"] as? String,
              ArtworkLookupPolicy.sameTrack(pageTitle: title, pageArtist: artist,
                                           trackTitle: track.title, trackArtist: track.artist),
              let images = payload["artwork"] as? [[String: Any]] else { return nil }
        // Browsers often return a 16x16 favicon first. Prefer >= 96px.
        let sorted = images.sorted { left, right in
            func size(_ image: [String: Any]) -> Int {
                let dimensions = (image["sizes"] as? String ?? "").split(separator: "x")
                return Int(dimensions.first ?? "") ?? 0
            }
            return size(left) > size(right)
        }
        for item in sorted {
            if let raw = item["src"] as? String,
               let url = URL(string: raw), url.scheme?.lowercased() == "https" {
                return url
            }
        }
        return nil
    }

    private static func htmlMeta(_ name: String, html: String) -> String? {
        // Attribute order varies among music services; accept property/name
        // before or after content while limiting what can be parsed.
        guard let tags = try? NSRegularExpression(pattern: "<meta\\s+[^>]{0,1200}>", options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tags.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let property = htmlAttribute("property", tag: tag) ?? htmlAttribute("name", tag: tag)
            if property?.lowercased() == name,
               let content = htmlAttribute("content", tag: tag), !content.isEmpty {
                return content
            }
        }
        return nil
    }

    private static func htmlAttribute(_ name: String, tag: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let r = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[r])
    }

    private static func htmlDecode(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // Search results from Apple and metadata from Spotify/MediaRemote often
    // differ in punctuation, "feat." credits and title suffixes. Match a
    // conservative normalized title/artist rather than requesting the cover
    // of a totally unrelated track.
    private static func catalogKey(_ value: String) -> String {
        var result = normalized(value)
        result = result.replacingOccurrences(of: "\\s*[\\(\\[]?(?:feat\\.?|ft\\.?|featuring)\\s+.*$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "[’'`.,!?–—:;\\-]", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameSong(_ a: PlayingTrack, _ b: PlayingTrack) -> Bool {
        func simplified(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return simplified(a.title) == simplified(b.title)
            && (a.artist.isEmpty || b.artist.isEmpty || simplified(a.artist) == simplified(b.artist))
    }

    private func cachedMusicArtwork(key: String) -> NSImage? {
        if cachedArtKey != key {
            cachedArtKey = key
            cachedArt = nil
            lastArtAttempt = .distantPast
        }
        if cachedArt == nil && Date().timeIntervalSince(lastArtAttempt) > 6 {
            lastArtAttempt = Date()
            cachedArt = musicArtwork()
        }
        return cachedArt
    }

    // Sleep timer (3.3.0): an explicit Pause, never a toggle.
    func pauseSystemPlayback() {
        commandQueue.async { SystemMediaRemote.pause() }
    }

    func send(_ command: PlaybackCommand, to source: MusicSource, completion: @escaping () -> Void) {
        commandQueue.async {
            if source == .system {
                SystemMediaRemote.command(command)
            } else {
                let action: String
                switch command {
                case .toggle: action = "playpause"
                case .next: action = "next track"
                case .previous: action = "previous track"
                }
                _ = Self.executeAppleScript("tell application id \"\(source.bundleIdentifier)\" to \(action)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: completion)
        }
    }

    func seek(to seconds: Double, in source: MusicSource, completion: @escaping () -> Void) {
        commandQueue.async {
            let safe = max(0, seconds.isFinite ? seconds : 0)
            if source == .system {
                SystemMediaRemote.seek(to: safe)
            } else {
                _ = Self.executeAppleScript("tell application id \"\(source.bundleIdentifier)\" to set player position to \(safe)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: completion)
        }
    }

    private func readSystemNowPlaying() -> (PlayingTrack, NSImage?)? {
        // 3.8.0: while the live stream is healthy, its latest state is the
        // answer — no new process per poll.
        if let payload = streamPayload, streamHealthy {
            return parseSystemPayload(payload)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.nowPlayingJXA]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // A hanging system bridge must never permanently stall the island.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseSystemPayload(payload)
    }

    private func parseSystemPayload(_ payload: [String: Any]) -> (PlayingTrack, NSImage?)? {
        guard payload["error"] == nil,
              let title = payload["Title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        func number(_ key: String) -> Double { (payload[key] as? NSNumber)?.doubleValue ?? 0 }
        let bundle = (payload["parentBundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                  ?? (payload["bundle"] as? String) ?? ""
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .first?.localizedName ?? (bundle.isEmpty ? "Медиа" : bundle)
        let rate = number("PlaybackRate")
        let playing = (payload["playing"] as? Bool) ?? (rate > 0)
        let artKey = PlayingTrack(source: .system, sourceName: "", sourceBundle: bundle,
                                  title: title, artist: payload["Artist"] as? String ?? "",
                                  duration: 0, position: 0, isPlaying: playing,
                                  artworkURL: nil).artworkIdentity
        if lastSystemArtKey != artKey {
            lastSystemArtKey = artKey
            lastSystemArt = nil
            ArtworkDiagnostics.write("Now Playing changed: source=\(bundle.isEmpty ? "unknown" : bundle) artistPresent=\(!(payload["Artist"] as? String ?? "").isEmpty) embeddedArtwork=\(payload["artwork"] != nil) directURL=\(payload["ArtworkURL"] != nil)")
        }
        // Decode on track change, not every poll; large JPEG/PNG decoding was
        // creating noticeable stalls during hover animations.
        if lastSystemArt == nil, let base64 = payload["artwork"] as? String,
           let bytes = Data(base64Encoded: base64),
           let image = NSImage(data: bytes), image.isValid {
            lastSystemArt = image
        }
        let artwork = lastSystemArt

        let duration = max(0, number("Duration"))
        let elapsed = max(0, number("ElapsedTime"))
        let timestamp = number("Timestamp")
        // Last reported position may lag while the media is playing.
        let projected = elapsed + ((playing && rate > 0 && timestamp > 0)
                    ? max(0, Date().timeIntervalSince1970 - timestamp) * rate : 0)
        let position = duration > 0 ? min(duration, projected) : projected
        let track = PlayingTrack(source: .system, sourceName: appName,
                                 sourceBundle: bundle, title: title,
                                 artist: payload["Artist"] as? String ?? "",
                                 duration: duration, position: position,
                                 isPlaying: playing,
                                 artworkURL: (payload["ArtworkURL"] as? String).flatMap(URL.init(string:)))
        return (track, artwork)
    }

    private func readAppleScript(_ source: MusicSource) -> PlayingTrack? {
        let duration = source == .spotify ? "(duration of t) / 1000" : "duration of t"
        let cover = source == .spotify ? """
                set imageURL to ""
                try
                    set imageURL to artwork url of t as text
                end try
            """ : "set imageURL to \"\""
        let script = """
        try
            tell application id "\(source.bundleIdentifier)"
                set status to player state as text
                if status is not "playing" and status is not "paused" then return ""
                set t to current track
                set sep to ASCII character 31
                \(cover)
                return status & sep & (name of t as text) & sep & (artist of t as text) & sep & (\(duration) as text) & sep & (player position as text) & sep & imageURL
            end tell
        on error
            return ""
        end try
        """
        guard let descriptor = Self.executeAppleScript(script),
              let text = descriptor.stringValue, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: "\u{001F}")
        guard parts.count >= 6 else { return nil }
        return PlayingTrack(source: source, sourceName: source.label,
                            sourceBundle: source.bundleIdentifier,
                            title: parts[1], artist: parts[2],
                            duration: max(0, Double(parts[3]) ?? 0),
                            position: max(0, Double(parts[4]) ?? 0),
                            isPlaying: parts[0] == "playing", artworkURL: URL(string: parts[5]))
    }

    private func musicArtwork() -> NSImage? {
        let code = """
        try
            tell application id "com.apple.Music" to return data of first artwork of current track
        on error
            return ""
        end try
        """
        guard let descriptor = Self.executeAppleScript(code) else { return nil }
        return NSImage(data: descriptor.data)
    }

    private static func executeAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        return script.executeAndReturnError(&error)
    }

    // 3.8.0: the same reading as nowPlayingJXA, in a loop (4× a second, in
    // one process). Prints a line on change; artwork once per song; quits
    // when Notch Island is gone (parent becomes launchd) or stdout closes.
    private static let nowPlayingStreamJXA = #"""
    ObjC.import('Foundation');
    ObjC.bindFunction('getppid', ['int', []]);
    function out(text) {
      $.NSFileHandle.fileHandleWithStandardOutput.writeData($(text + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
    }
    function read(cls, wantArt) {
      var data = {playing: !!cls.localIsPlaying};
      var item = cls.localNowPlayingItem;
      if (item && !item.isNil() && item.nowPlayingInfo) {
        var values = item.nowPlayingInfo;
        var en = values.keyEnumerator;
        var key;
        while ((key = en.nextObject) && !key.isNil()) {
          var full = String(ObjC.unwrap(key));
          var name = full.replace('kMRMediaRemoteNowPlayingInfo', '');
          var obj = values.objectForKey(key);
          if (!obj || obj.isNil()) continue;
          if (obj.isKindOfClass($.NSDate)) data[name] = obj.timeIntervalSince1970;
          else if (obj.isKindOfClass($.NSString) || obj.isKindOfClass($.NSNumber)) data[name] = ObjC.unwrap(obj);
          else if (name === 'ArtworkData' && obj.isKindOfClass($.NSData)) {
            data.hasArtwork = true;
            if (wantArt) data.artwork = ObjC.unwrap(obj.base64EncodedStringWithOptions(0));
          }
        }
      }
      var path = cls.localNowPlayingPlayerPath;
      if (path && !path.isNil() && path.client) {
        var client = path.client;
        if (client.bundleIdentifier && !client.bundleIdentifier.isNil()) data.bundle = ObjC.unwrap(client.bundleIdentifier);
        if (client.parentApplicationBundleIdentifier && !client.parentApplicationBundleIdentifier.isNil())
          data.parentBundle = ObjC.unwrap(client.parentApplicationBundleIdentifier);
      }
      return data;
    }
    function run() {
      try {
        var framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
        if (!framework || !framework.load) { out(JSON.stringify({error: 'media framework unavailable'})); return; }
        var cls = $.NSClassFromString('MRNowPlayingRequest');
        if (!cls) { out(JSON.stringify({error: 'now playing API unavailable'})); return; }
        var lastSig = null, artKey = null, artSent = false, lastBeat = 0;
        var lastPosition = 0, lastNow = 0, lastRate = 0;
        while (true) {
          if ($.getppid() === 1) return;
          var now = Date.now() / 1000;
          var d = read(cls, false);
          var key = (d.Title || '') + '|' + (d.Artist || '');
          var sig = [key, d.Album || '', d.playing, d.bundle || '', d.parentBundle || '',
                     Math.round(d.Duration || 0), d.PlaybackRate || 0].join('|');
          // 3.16.5: compare positions projected to NOW. ElapsedTime is the
          // position at Timestamp; it used to be compared with a projection
          // to now, so 2.5 s after any update every read looked like a seek
          // and a line was sent 4 times a second for the whole song.
          var rate = d.playing ? (d.PlaybackRate || 1) : 0;
          var position = (d.ElapsedTime || 0) + (d.Timestamp ? Math.max(0, now - d.Timestamp) * rate : 0);
          var expected = lastPosition + (now - lastNow) * lastRate;
          var seek = lastNow > 0 && Math.abs(position - expected) > 2.5;
          var needArt = d.hasArtwork && (key !== artKey || !artSent);
          if (sig !== lastSig || seek || needArt) {
            if (needArt) { d = read(cls, true); artKey = key; artSent = true; }
            if (key !== artKey) { artKey = key; artSent = false; }
            out(JSON.stringify(d));
            lastSig = sig; lastBeat = now;
          } else if (now - lastBeat > 10) {
            d.heartbeat = true;
            out(JSON.stringify(d));
            lastBeat = now;
          }
          lastPosition = position;
          lastNow = now;
          lastRate = rate;
          $.NSThread.sleepForTimeInterval(0.25);
        }
      } catch (e) {
        try { out(JSON.stringify({error: String(e)})); } catch (ignored) {}
      }
    }
    """#

    // JXA's ObjC bridge runs in Apple's /usr/bin/osascript process. Modern macOS
    // restricts MediaRemote reads from regular unsigned third-party binaries.
    // There is no screen recording, browser automation or network connection.
    private static let nowPlayingJXA = #"""
    ObjC.import('Foundation');
    function run() {
      try {
        var framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
        if (!framework || !framework.load) return JSON.stringify({error:'media framework unavailable'});
        var cls = $.NSClassFromString('MRNowPlayingRequest');
        if (!cls) return JSON.stringify({error:'now playing API unavailable'});
        var data = {playing: !!cls.localIsPlaying};
        var item = cls.localNowPlayingItem;
        if (item && !item.isNil() && item.nowPlayingInfo) {
          var values = item.nowPlayingInfo;
          var en = values.keyEnumerator;
          var key;
          while ((key = en.nextObject) && !key.isNil()) {
            var full = String(ObjC.unwrap(key));
            var name = full.replace('kMRMediaRemoteNowPlayingInfo', '');
            var obj = values.objectForKey(key);
            if (!obj || obj.isNil()) continue;
            if (obj.isKindOfClass($.NSDate)) data[name] = obj.timeIntervalSince1970;
            else if (obj.isKindOfClass($.NSString) || obj.isKindOfClass($.NSNumber))
              data[name] = ObjC.unwrap(obj);
            else if (name === 'ArtworkData' && obj.isKindOfClass($.NSData))
              data.artwork = ObjC.unwrap(obj.base64EncodedStringWithOptions(0));
          }
        }
        var path = cls.localNowPlayingPlayerPath;
        if (path && !path.isNil() && path.client) {
          var client = path.client;
          if (client.bundleIdentifier && !client.bundleIdentifier.isNil())
            data.bundle = ObjC.unwrap(client.bundleIdentifier);
          if (client.parentApplicationBundleIdentifier && !client.parentApplicationBundleIdentifier.isNil())
            data.parentBundle = ObjC.unwrap(client.parentApplicationBundleIdentifier);
        }
        return JSON.stringify(data);
      } catch (e) {
        return JSON.stringify({error: String(e)});
      }
    }
    """#
}

private enum SystemMediaRemote {
    // Private, undocumented system API — best effort. No entitlements or SIP changes.
    private typealias CommandFunction = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let library: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    private static let sender: CommandFunction? = {
        guard let library = library,
              let symbol = dlsym(library, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: CommandFunction.self)
    }()

    static func command(_ command: PlaybackCommand) {
        let code: UInt32
        switch command {
        case .toggle: code = 2
        case .next: code = 4
        case .previous: code = 5
        }
        _ = sender?(code, nil)
    }

    static func pause() { _ = sender?(1, nil) }

    static func seek(to seconds: Double) {
        let options = ["kMRMediaRemoteOptionPlaybackPosition": seconds] as CFDictionary
        _ = sender?(24, options)
    }
}
