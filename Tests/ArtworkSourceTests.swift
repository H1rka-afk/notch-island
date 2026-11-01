import Foundation

@main
struct ArtworkSourceTests {
    static func main() {
        let defaults = UserDefaults(suiteName: "notchisland.cover.test.312")!
        for key in ArtworkProvider.allCases.map(\.preferenceKey) { defaults.removeObject(forKey: key) }
        for provider in ArtworkProvider.allCases {
            precondition(provider.isEnabled(in: defaults))
            defaults.set(false, forKey: provider.preferenceKey)
            precondition(!provider.isEnabled(in: defaults))
            defaults.set(true, forKey: provider.preferenceKey)
            precondition(provider.isEnabled(in: defaults))
        }
        precondition(ArtworkProvider.pageProvider(for: URL(string: "https://music.yandex.ru/album/12")!) == .yandex)
        precondition(ArtworkProvider.pageProvider(for: URL(string: "https://music.youtube.com/watch?v=123")!) == .youtube)
        precondition(ArtworkProvider.pageProvider(for: URL(string: "https://malicious.music.youtube.com/watch")!) == nil)
        precondition(ArtworkProvider.pageProvider(for: URL(string: "http://music.youtube.com/watch")!) == nil)
        precondition(ArtworkPageMatcher.matches(pageTitle: "Artist Name — Song Title", song: "Song Title", artist: "Artist Name"))
        precondition(!ArtworkPageMatcher.matches(pageTitle: "Song Title — Someone Else", song: "Song Title", artist: "Artist Name"))
        precondition(!ArtworkPageMatcher.matches(pageTitle: "Music", song: "Song Title", artist: "Artist Name"))
        precondition(ArtworkLookupPolicy.canLoadDirectURL(URL(string: "https://i.scdn.co/image/1")))
        precondition(ArtworkLookupPolicy.canLoadDirectURL(URL(string: "http://example.test/cover")))
        precondition(!ArtworkLookupPolicy.canLoadDirectURL(nil))
        precondition(!ArtworkLookupPolicy.canLoadDirectURL(URL(string: "file:///Users/user/cover")))
        // A genuine direct cover is accepted even when artist metadata is still missing.
        precondition(!ArtworkLookupPolicy.hasCatalogMetadata(title: "Song", artist: ""))
        precondition(ArtworkLookupPolicy.hasCatalogMetadata(title: "Song", artist: "Singer"))
        precondition(ArtworkLookupPolicy.sameTrack(pageTitle: "Song", pageArtist: "Singer",
                                                  trackTitle: "song", trackArtist: ""))
        precondition(ArtworkLookupPolicy.sameTrack(pageTitle: "Song", pageArtist: "Singer",
                                                  trackTitle: "Song", trackArtist: "Singer"))
        precondition(!ArtworkLookupPolicy.sameTrack(pageTitle: "Other", pageArtist: "Singer",
                                                   trackTitle: "Song", trackArtist: "Singer"))
        precondition(!ArtworkLookupPolicy.sameTrack(pageTitle: "Song", pageArtist: "Other",
                                                   trackTitle: "Song", trackArtist: "Singer"))
        precondition(YandexArtworkURLPolicy.accept(URL(string: "https://avatars.yandex.net/get-music-content/123/abcdef/400x400")!) != nil)
        precondition(YandexArtworkURLPolicy.accept("https://avatars.mds.yandex.net/get-music-content/123/abcdef/300x300") != nil)
        precondition(YandexArtworkURLPolicy.accept("https://music.yandex.ru/album/42") == nil)
        precondition(YandexArtworkURLPolicy.accept("https://avatars.yandex.net/get-user-avatar/123/abc") == nil)
        precondition(YandexArtworkURLPolicy.accept("https://avatars.yandex.net.evil.test/get-music-content/1") == nil)
        precondition(YandexArtworkURLPolicy.accept("http://avatars.yandex.net/get-music-content/1") == nil)
        precondition(YandexArtworkURLPolicy.accept("file:///tmp/artwork") == nil)
        print("ArtworkSourceTests: OK (providers, direct-without-artist, metadata matching and preferences)")
    }
}
