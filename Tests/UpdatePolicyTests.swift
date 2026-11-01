import Foundation

// swiftc -parse-as-library Source/UpdatePolicy.swift Tests/UpdatePolicyTests.swift -o up-tests && ./up-tests
@main
struct UpdatePolicyTests {
    static func main() {
        typealias R = UpdatePolicy.Release
        // Names exactly as releases are delivered.
        precondition(UpdatePolicy.release(fromName: "Notch-Island-v3.1.13-One-Click-Update.zip", isDirectory: false)
                     == R(version: "3.1.13", isArchive: true))
        precondition(UpdatePolicy.release(fromName: "Notch-Island-v3.1.9.1-Focus-Fix.zip", isDirectory: false)
                     == R(version: "3.1.9.1", isArchive: true))
        precondition(UpdatePolicy.release(fromName: "Notch-Island-v3.1.13-Update (1).zip", isDirectory: false)
                     == R(version: "3.1.13", isArchive: true))
        precondition(UpdatePolicy.release(fromName: "Notch-Island-Installer-v3.1.13", isDirectory: true)
                     == R(version: "3.1.13", isArchive: false))
        precondition(UpdatePolicy.release(fromName: "Notch-Island-Installer-v3.1.13 2", isDirectory: true)
                     == R(version: "3.1.13", isArchive: false))
        // Not releases: wrong kind, wrong prefix, no version, other files.
        precondition(UpdatePolicy.release(fromName: "Notch-Island-v3.1.13.zip", isDirectory: true) == nil)
        precondition(UpdatePolicy.release(fromName: "Notch-Island-Installer-v3.1.13.zip", isDirectory: false) == nil)
        precondition(UpdatePolicy.release(fromName: "Notch-Island-v3.1.13-Update", isDirectory: true) == nil)
        precondition(UpdatePolicy.release(fromName: "Notch-Island-v3-final.zip", isDirectory: false) == nil)
        precondition(UpdatePolicy.release(fromName: "Other-App-v9.9.9.zip", isDirectory: false) == nil)
        precondition(UpdatePolicy.release(fromName: "NotchIsland-v3.1.13.zip", isDirectory: false) == nil)

        // Version ordering.
        precondition(UpdatePolicy.isNewer("3.1.10", than: "3.1.9.1"))
        precondition(UpdatePolicy.isNewer("3.1.9.1", than: "3.1.9"))
        precondition(UpdatePolicy.isNewer("3.2", than: "3.1.13"))
        precondition(!UpdatePolicy.isNewer("3.1.9", than: "3.1.10"))
        precondition(!UpdatePolicy.isNewer("3.1.13", than: "3.1.13"))
        precondition(!UpdatePolicy.isNewer("3.1.13.0", than: "3.1.13"))

        // Choosing among a real-looking Downloads folder.
        let entries: [(name: String, isDirectory: Bool)] = [
            ("Notch-Island-v3.1.8-Timer-and-Lock-Transitions.zip", false),
            ("Notch-Island-v3.1.12-Settings-Redesign.zip", false),
            ("Notch-Island-v3.1.13-One-Click-Update.zip", false),
            ("Notch-Island-Installer-v3.1.13", true),
            ("Notch-Island-v3.1.11-Settings.zip", false),
            ("photo.jpg", false)
        ]
        let best = UpdatePolicy.newest(in: entries, current: "3.1.12")
        precondition(best?.release.version == "3.1.13" && best?.release.isArchive == false,
                     "same version: unpacked folder preferred")
        precondition(UpdatePolicy.newest(in: entries, current: "3.1.13") == nil)
        precondition(UpdatePolicy.newest(in: entries, current: "3.1.9")?.release.version == "3.1.13")

        // Installer name in both Unicode forms (zip tools may decompose "й").
        precondition(UpdatePolicy.isInstaller("Установить Notch Island.command"))
        precondition(UpdatePolicy.isInstaller("Установить Notch Island.command".decomposedStringWithCanonicalMapping))
        precondition(!UpdatePolicy.isInstaller("Восстановить доступ к таймеру.command"))

        // 4.0.0: GitHub release JSON.
        let json = """
        {"tag_name":"v4.0.1","draft":false,"prerelease":false,"assets":[
          {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
          {"name":"Notch-Island-v4.0.1.zip","browser_download_url":"https://example.com/Notch-Island-v4.0.1.zip"}]}
        """.data(using: .utf8)!
        let gh = UpdatePolicy.githubRelease(from: json)!
        precondition(gh.version == "4.0.1" && gh.assetName == "Notch-Island-v4.0.1.zip")
        precondition(gh.assetURL.absoluteString == "https://example.com/Notch-Island-v4.0.1.zip")
        let mismatch = """
        {"tag_name":"v4.0.2","assets":[{"name":"Notch-Island-v4.0.1.zip","browser_download_url":"https://e.com/a.zip"}]}
        """.data(using: .utf8)!
        precondition(UpdatePolicy.githubRelease(from: mismatch) == nil)
        let draft = """
        {"tag_name":"v5.0.0","draft":true,"assets":[{"name":"Notch-Island-v5.0.0.zip","browser_download_url":"https://e.com/a.zip"}]}
        """.data(using: .utf8)!
        precondition(UpdatePolicy.githubRelease(from: draft) == nil)
        precondition(UpdatePolicy.githubRelease(from: Data("{}".utf8)) == nil)
        print("UpdatePolicyTests: OK")
    }
}
