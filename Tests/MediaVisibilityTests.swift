import Foundation

// swiftc -parse-as-library Source/MediaVisibilityPolicy.swift Tests/MediaVisibilityTests.swift -o mv-tests && ./mv-tests
@main
struct MediaVisibilityTests {
    static func input(front: String, source: String, track: String = "Комета",
                      window: String? = nil, fullscreen: Bool = false,
                      hideFS: Bool = true, hideSource: Bool = true) -> MediaVisibilityPolicy.Input {
        .init(frontBundle: front, sourceBundle: source, trackTitle: track,
              frontWindowTitle: window, frontIsFullscreen: fullscreen,
              hideInFullscreen: hideFS, hideWhenSourceInFront: hideSource)
    }

    static func main() {
        let hide = MediaVisibilityPolicy.shouldHide
        let ym = "ru.yandex.desktop.music", safari = "com.apple.Safari"

        // Music app in front → hide; other app in front → keep.
        precondition(hide(input(front: ym, source: ym)))
        precondition(hide(input(front: "com.spotify.client", source: "com.spotify.client")))
        precondition(!hide(input(front: "com.apple.finder", source: ym)))
        precondition(!hide(input(front: ym, source: ym, hideSource: false)))

        // Browser: only the tab that shows the music.
        precondition(hide(input(front: safari, source: safari, window: "Комета — JONY")))
        precondition(hide(input(front: safari, source: safari, track: "Other",
                                window: "Моя волна — Яндекс Музыка")))
        precondition(hide(input(front: "com.google.Chrome", source: "com.google.Chrome",
                                track: "Lose Yourself", window: "lose yourself - YouTube - Google Chrome")))
        precondition(!hide(input(front: safari, source: safari, window: "Почта — Gmail")))
        precondition(!hide(input(front: safari, source: safari, window: nil)))
        // Browser in front but music plays in the Yandex Music app → keep.
        precondition(!hide(input(front: safari, source: ym, window: "Комета — JONY")))
        // Unknown source, browser tab with the track → hide.
        precondition(hide(input(front: safari, source: "", window: "Комета")))
        // Ё / case / diacritics.
        precondition(hide(input(front: safari, source: safari, track: "Ёлка", window: "елка — слушать")))

        // Full screen: media app or source app → hide, editor → keep.
        precondition(hide(input(front: safari, source: ym, window: "Фильм", fullscreen: true)))
        precondition(hide(input(front: ym, source: ym, fullscreen: true, hideSource: false)))
        precondition(!hide(input(front: "com.apple.dt.Xcode", source: ym, fullscreen: true)))
        precondition(!hide(input(front: safari, source: ym, window: "Фильм", fullscreen: true, hideFS: false)))

        print("MediaVisibilityTests: OK")
    }
}
