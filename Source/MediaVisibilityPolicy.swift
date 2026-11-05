import Foundation

// 3.4.1 — when the music player gets out of the way.
// Pure decisions only (no AppKit), so they are covered by tests.
//
// 1. Full screen: a video / music app opened on the whole screen, or a
//    browser that is itself playing (4.12.4), but never for an ordinary
//    fullscreen editor.
// 2. The music source itself is in front: the Yandex Music / Spotify / Music
//    app, or the browser whose CURRENT tab plays the track (its window title
//    shows the track or a music service).
enum MediaVisibilityPolicy {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "org.chromium.Chromium", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera",
        "com.microsoft.edgemac", "ru.yandex.desktop.yandex-browser", "com.vivaldi.Vivaldi"
    ]

    static let players: Set<String> = [
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        "com.apple.TV", "com.firecore.infuse", "com.apple.Music", "com.spotify.client",
        "ru.yandex.desktop.music", "com.apple.podcasts"
    ]

    // Titles of music-service tabs, even when the track title is not in them.
    static let musicSiteMarkers = [
        "яндекс музыка", "яндекс.музыка", "yandex music", "spotify", "youtube music",
        "soundcloud", "apple music", "vk музыка", "vk music", "звук", "deezer"
    ]

    struct Input {
        var frontBundle: String
        var sourceBundle: String     // "" when MediaRemote did not say
        var trackTitle: String
        var frontWindowTitle: String?
        var frontIsFullscreen: Bool
        var hideInFullscreen: Bool
        var hideWhenSourceInFront: Bool
        var trackPlaying: Bool = true
    }

    static func isMediaApp(_ bundle: String) -> Bool {
        browsers.contains(bundle) || players.contains(bundle)
    }

    static func frontIsSource(front: String, source: String) -> Bool {
        if source.isEmpty { return isMediaApp(front) }
        return front == source
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Does the browser's focused window (= current tab) show this music?
    static func browserTitleShowsMusic(windowTitle: String?, trackTitle: String) -> Bool {
        guard let windowTitle, !windowTitle.isEmpty else { return false }
        let title = normalized(windowTitle)
        let track = normalized(trackTitle)
        if track.count >= 2 && title.contains(track) { return true }
        return musicSiteMarkers.contains { title.contains($0) }
    }

    static func shouldHide(_ input: Input) -> Bool {
        let fromSource = frontIsSource(front: input.frontBundle, source: input.sourceBundle)
        if input.hideInFullscreen && input.frontIsFullscreen {
            // 4.12.4: a browser on the whole screen hides the island only
            // while it plays something itself — not an empty or loading page,
            // and not when the music comes from another app.
            if browsers.contains(input.frontBundle) {
                if input.sourceBundle == input.frontBundle && input.trackPlaying { return true }
            } else if fromSource || isMediaApp(input.frontBundle) {
                return true
            }
        }
        guard input.hideWhenSourceInFront, fromSource else { return false }
        if browsers.contains(input.frontBundle) {
            return browserTitleShowsMusic(windowTitle: input.frontWindowTitle,
                                          trackTitle: input.trackTitle)
        }
        return true
    }
}
