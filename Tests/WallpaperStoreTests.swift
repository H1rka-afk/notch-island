import Foundation

// swiftc -parse-as-library Source/WallpaperStore.swift Source/AirDropFormat.swift Tests/WallpaperStoreTests.swift -o ws-tests && ./ws-tests
@main
struct WallpaperStoreTests {
    static func main() {
        let aerial = "4C108785-A7BA-422E-9C79-B0129F1D5550"
        let config = try! PropertyListSerialization.data(
            fromPropertyList: ["assetID": aerial.lowercased()], format: .binary, options: 0)
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let root: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Desktop": ["LastSet": old, "Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Files": [["relative": "file:///Users/u/Pictures/Old%20one.jpg"]]]]]],
                "Idle": ["LastSet": new, "Content": ["Choices": [["Provider": "x", "Configuration": Data()]]]]
            ],
            "Displays": ["Main": [
                "Desktop": ["LastSet": new, "Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Configuration": config, "Files": [Any]()]]]]]]
        ]
        // Newest «Desktop» wins, the asset id comes out of the nested plist.
        let choice = WallpaperStore.currentChoice(in: root)
        precondition(choice?.assetIDs == [aerial], "\(String(describing: choice))")
        precondition(choice?.files.isEmpty == true)

        // A picture file (percent-escaped URL) is found.
        let image = WallpaperStore.parse(["Files": [["relative": "file:///Users/u/Pictures/Old%20one.jpg"]]])
        precondition(image.files == ["/Users/u/Pictures/Old one.jpg"])
        precondition(WallpaperStore.filePath("/tmp/readme.txt") == nil)

        // Empty store → nothing.
        precondition(WallpaperStore.currentChoice(in: [String: Any]()) == nil)

        // Still picture is preferred over the video of the same Aerial.
        let paths = ["/a/\(aerial).mov", "/b/thumbnails/\(aerial.lowercased()).png", "/c/other.png"]
        precondition(WallpaperStore.bestAsset(for: aerial, among: paths) == "/b/thumbnails/\(aerial.lowercased()).png")
        precondition(WallpaperStore.bestAsset(for: aerial, among: ["/a/\(aerial).mov"]) == "/a/\(aerial).mov")
        precondition(WallpaperStore.bestAsset(for: aerial, among: ["/c/other.png"]) == nil)

        // AirDrop helpers.
        precondition(AirDropFormat.isAirDropQuarantine("0083;6720c1f0;sharingd;"))
        precondition(!AirDropFormat.isAirDropQuarantine("0083;6720c1f0;Safari;ABC"))
        precondition(!AirDropFormat.isAirDropQuarantine("garbage"))
        precondition(AirDropFormat.progressText(fraction: 0.456, files: 1) == "45%")
        precondition(AirDropFormat.progressText(fraction: 1.4, files: 3) == "3 · 100%")
        precondition(AirDropFormat.receivedText(count: 2) == "Получено 2")
        print("WallpaperStoreTests: OK")
    }
}
