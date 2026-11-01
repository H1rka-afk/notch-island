import Foundation

// Pure rules for one-click updates (Foundation only, covered by UpdatePolicyTests).
// A release is recognised by the name it is always delivered with:
//   Notch-Island-v3.1.13-Something.zip       (archive)
//   Notch-Island-Installer-v3.1.13            (already unpacked folder)
// Browser duplicates such as "… (1).zip" are accepted.
enum UpdatePolicy {
    static let installerName = "Установить Notch Island.command"
    static let bundleIdentifier = "app.notchisland.desktop"

    private static let namePattern = try! NSRegularExpression(
        pattern: #"^Notch-Island-(Installer-)?v(\d+(?:\.\d+){1,3})(?:[-_ (].*)?$"#)

    struct Release: Equatable {
        let version: String
        let isArchive: Bool
    }

    // `isDirectory` comes from the file system; the name alone decides nothing.
    static func release(fromName rawName: String, isDirectory: Bool) -> Release? {
        let name = rawName.precomposedStringWithCanonicalMapping
        let isZip = name.lowercased().hasSuffix(".zip")
        guard isZip != isDirectory else { return nil }
        let stem = isZip ? String(name.dropLast(4)) : name
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = namePattern.firstMatch(in: stem, range: range),
              let versionRange = Range(match.range(at: 2), in: stem) else { return nil }
        let installerFolder = match.range(at: 1).location != NSNotFound
        // Archives are named "Notch-Island-v…", unpacked folders "…-Installer-v…".
        if isZip == installerFolder { return nil }
        return Release(version: String(stem[versionRange]), isArchive: isZip)
    }

    static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    // 3.1.10 > 3.1.9.1 > 3.1.9; missing components count as zero.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func isInstaller(_ fileName: String) -> Bool {
        fileName.precomposedStringWithCanonicalMapping ==
            installerName.precomposedStringWithCanonicalMapping
    }

    // Newest acceptable release among folder entries, strictly newer than current.
    static func newest(in entries: [(name: String, isDirectory: Bool)],
                       current: String) -> (name: String, release: Release)? {
        var best: (name: String, release: Release)?
        for entry in entries {
            guard let release = release(fromName: entry.name, isDirectory: entry.isDirectory),
                  isNewer(release.version, than: current) else { continue }
            if let chosen = best {
                if isNewer(release.version, than: chosen.release.version) ||
                    // Same version: prefer an unpacked folder (no extraction needed).
                    (release.version == chosen.release.version && !release.isArchive && chosen.release.isArchive) {
                    best = (entry.name, release)
                }
            } else {
                best = (entry.name, release)
            }
        }
        return best
    }

    // 4.0.0: the latest GitHub release: version from the tag («v4.0.1»)
    // and the ready-made archive among its files.
    struct GitHubRelease: Equatable {
        let version: String
        let assetName: String
        let assetURL: URL
    }

    static func githubRelease(from data: Data) -> GitHubRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              (root["draft"] as? Bool) != true, (root["prerelease"] as? Bool) != true,
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !components(version).isEmpty else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                  let parsed = release(fromName: name, isDirectory: false),
                  parsed.isArchive, parsed.version == version else { continue }
            return GitHubRelease(version: version, assetName: name, assetURL: url)
        }
        return nil
    }
}
