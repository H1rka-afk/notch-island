import Foundation

// swiftc -parse-as-library Source/YandexCatalogArtwork.swift Tests/YandexCatalogTests.swift -o yc-tests && ./yc-tests
// Fixture: real Yandex Music catalog answer (trimmed) captured on the user's Mac.
@main
struct YandexCatalogTests {
    static func main() {
        let response = Data(#"{"result": {"type": "track", "tracks": {"results": [{"title": "8 миля", "artists": [{"name": "Другой исполнитель"}], "coverUri": "avatars.yandex.net/get-music-content/1/wrong/%%"}, {"title": "8 миля", "version": null, "artists": [{"name": "madk1d"}, {"name": "VILLIAN"}], "coverUri": "avatars.yandex.net/get-music-content/16334817/d8a21089.a.40642889-1/%%", "albums": [{"coverUri": "avatars.yandex.net/get-music-content/16334817/d8a21089.a.40642889-1/%%"}]}]}}}"#.utf8)
        let expected = URL(string: "https://avatars.yandex.net/get-music-content/16334817/d8a21089.a.40642889-1/400x400")!

        // Now Playing reports both artists in one string.
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: response,
                     title: "8 миля", artist: "madk1d, VILLIAN") == expected)
        // The decoy with the same title but another artist is never chosen.
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: response,
                     title: "8 миля", artist: "Другой") == nil)
        // A single matching artist out of several is enough.
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: response,
                     title: "8 миля", artist: "VILLIAN") == expected)
        // Wrong title or empty artist → no cover.
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: response,
                     title: "9 миля", artist: "madk1d") == nil)
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: response,
                     title: "8 миля", artist: "") == nil)
        // Empty result (no "tracks" key) and junk.
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: Data(#"{"result":{"type":"track"}}"#.utf8),
                     title: "a", artist: "b") == nil)
        precondition(YandexCatalogArtwork.coverURL(fromSearchResponse: Data("x".utf8), title: "a", artist: "b") == nil)

        // Queries: precise first, then title only.
        precondition(YandexCatalogArtwork.queries(title: "8 миля", artist: "madk1d, VILLIAN")
                     == ["8 миля madk1d", "8 миля"])
        precondition(YandexCatalogArtwork.queries(title: "Song", artist: "A feat. B") == ["Song A", "Song"])
        precondition(YandexCatalogArtwork.queries(title: " ", artist: "A").isEmpty)

        // Only Yandex image hosts, always https, size filled in.
        precondition(YandexCatalogArtwork.coverURL(fromURI: "avatars.yandex.net/x/%%")?.absoluteString
                     == "https://avatars.yandex.net/x/400x400")
        precondition(YandexCatalogArtwork.coverURL(fromURI: "evil.example.com/x/%%") == nil)
        precondition(YandexCatalogArtwork.coverURL(fromURI: "http://avatars.yandex.net/x") == nil)
        precondition(YandexCatalogArtwork.searchURL(query: "8 миля madk1d")?.host == "api.music.yandex.net")

        print("YandexCatalogTests: OK")
    }
}
