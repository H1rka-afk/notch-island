import Foundation

// swiftc -parse-as-library Source/SettingsSearch.swift Tests/SettingsSearchTests.swift -o ss-tests && ./ss-tests
@main
struct SettingsSearchTests {
    static func first(_ query: String) -> SettingsSearchEntry? { SettingsSearch.search(query).first }

    static func main() {
        precondition(SettingsSearch.search("").isEmpty)
        precondition(SettingsSearch.search("   ").isEmpty)
        precondition(first("громкость")?.title == "Громкость")
        precondition(first("автозапуск")?.title == "Открывать при входе в macOS")
        precondition(first("тема")?.title == "Оформление")
        precondition(first("скриншот")?.section == "shelf")
        precondition(first("Spotify")?.section == "media")
        precondition(first("iphone")?.title == "Как на iPhone")
        // Ё and case.
        precondition(first("ЧЁЛКА") != nil)
        precondition(first("тёмная")?.title == "Оформление")
        // All words must match.
        precondition(first("полка снимки")?.title == "Новые снимки экрана")
        precondition(SettingsSearch.search("громкость zzzz").isEmpty)
        // Every entry points to a known section.
        let sections: Set<String> = ["general", "profiles", "stats", "permissions", "island", "media",
                                     "lock", "notifications", "helpers", "shelf", "devices", "timer"]
        // 4.5.0: the spectrogram lives in the media player.
        precondition(first("спектрограмма")?.section == "media")
        precondition(SettingsSearch.index.allSatisfy { sections.contains($0.section) })
        print("SettingsSearchTests: OK")
    }
}
