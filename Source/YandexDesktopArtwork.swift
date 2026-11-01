import AppKit
import ApplicationServices
import Foundation

// Optional, read-only adapter for the *native* Yandex Music app. MediaRemote
// sometimes supplies song metadata without its cover; browser metadata cannot
// help because ru.yandex.desktop.music is not a browser. Never screenshot,
// inspect account storage or try an unofficial authenticated service endpoint.
// We accept an AX image URL ONLY if the actual playing title AND artist occur
// in the player footer near the image. No blind album/search-result thumbnails.
enum YandexDesktopArtwork {
    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private static func text(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .compactMap { value(element, $0) as? String }
            .joined(separator: " ")
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute),
              let dimensions = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        let pos = unsafeBitCast(position, to: AXValue.self)
        let sz = unsafeBitCast(dimensions, to: AXValue.self)
        guard AXValueGetValue(pos, .cgPoint, &point), AXValueGetValue(sz, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func lookup(for track: PlayingTrack, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard track.sourceBundle == "ru.yandex.desktop.music", ArtworkProvider.yandex.isEnabled() else {
                completion(nil)
                return
            }
            // Recheck the CURRENT signed process. An Accessibility toggle can
            // still appear enabled for a previous ad-hoc-signed build.
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let trusted = AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary)
            guard trusted else {
                ArtworkDiagnostics.write("Yandex desktop AX: permission missing for current Notch Island process; use Settings > Island > Artwork sources to re-authorize")
                completion(nil)
                return
            }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.music").first else {
                ArtworkDiagnostics.write("Yandex desktop AX: application not found")
                completion(nil)
                return
            }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.12)
            guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
                ArtworkDiagnostics.write("Yandex desktop AX: no accessible windows")
                completion(nil)
                return
            }
            let expectedTitle = ArtworkPageMatcher.normalized(track.title)
            let expectedArtist = ArtworkPageMatcher.normalized(track.artist)
            guard !expectedTitle.isEmpty, !expectedArtist.isEmpty else { completion(nil); return }
            for window in windows.prefix(2) {
                guard let bounds = frame(window), bounds.width > 250, bounds.height > 220 else { continue }
                let footerTop = bounds.maxY - min(220, bounds.height * 0.30)
                var queue: [AXUIElement] = [window]
                var index = 0
                var images: [(CGRect, URL)] = []
                var titleRects: [CGRect] = []
                var artistFound = false
                var examined = 0
                while index < queue.count && examined < 320 {
                    let item = queue[index]
                    index += 1
                    examined += 1
                    let boundsOfItem = frame(item)
                    if let box = boundsOfItem,
                       box.midY >= footerTop && box.midY <= bounds.maxY + 8,
                       box.midX >= bounds.minX && box.midX <= bounds.maxX {
                        let label = ArtworkPageMatcher.normalized(text(item))
                        if !label.isEmpty {
                            if label == expectedTitle || label.contains(expectedTitle) {
                                titleRects.append(box)
                            }
                            if label == expectedArtist || label.contains(expectedArtist) {
                                artistFound = true
                            }
                        }
                        if (value(item, kAXRoleAttribute) as? String) == (kAXImageRole as String),
                           let raw = value(item, kAXURLAttribute),
                           let url = YandexArtworkURLPolicy.accept(raw) {
                            images.append((box, url))
                        }
                    }
                    if let children = value(item, kAXChildrenAttribute) as? [AXUIElement] {
                        queue.append(contentsOf: children.prefix(50))
                    }
                }
                guard artistFound, !titleRects.isEmpty else {
                    ArtworkDiagnostics.write("Yandex desktop AX: current song not verified in footer")
                    continue
                }
                // Usually the album cover is the small image just LEFT of the
                // playing title. Requiring proximity rejects playlist covers.
                if let match = images.first(where: { candidate in
                    titleRects.contains(where: { title in
                        abs(candidate.0.midY - title.midY) <= 75 &&
                        candidate.0.midX <= title.midX + 35 &&
                        title.midX - candidate.0.midX <= 190
                    })
                }) {
                    ArtworkDiagnostics.write("Yandex desktop AX: verified cover URL found")
                    completion(match.1)
                    return
                }
                ArtworkDiagnostics.write("Yandex desktop AX: footer verified; no usable cover URL (imageNodes=\(images.count))")
            }
            completion(nil)
        }
    }
}
