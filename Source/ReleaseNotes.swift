import Foundation

// 3.20.0 — «Что нового» for the update waiting in Downloads. Read straight
// from the archive (CHANGES.txt, or the first section of «ПРОЧТИ МЕНЯ.txt»),
// nothing is unpacked or sent anywhere.
enum ReleaseNotes {
    // Items of the newest section: «- …» lines become items, indented lines
    // continue the previous one, plain sentences are kept as items too.
    static func parse(_ text: String, limit: Int = 10) -> [String] {
        var items: [String] = []
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 4.7.0: the app is now called Ovira; old notes keep the old name.
            let header = (line.hasPrefix("Notch Island ") && !line.hasPrefix("Notch Island —"))
                || (line.hasPrefix("Ovira ") && !line.hasPrefix("Ovira —"))
            if header {
                if inSection { break }
                inSection = true
                continue
            }
            guard inSection, !line.isEmpty else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                items.append(String(line.dropFirst(2)))
            } else if raw.hasPrefix(" ") || raw.hasPrefix("\t"), let last = items.popLast() {
                items.append(last + " " + line)
            } else {
                items.append(line)
            }
        }
        return Array(items.prefix(limit))
    }

    // Runs /usr/bin/unzip (part of macOS); nil when nothing readable.
    static func load(from url: URL, isArchive: Bool) -> [String] {
        let text: String?
        if isArchive {
            let listing = run(["-Z1", url.path]) ?? ""
            let entries = listing.components(separatedBy: .newlines)
            let entry = entries.first { $0.hasSuffix("/CHANGES.txt") || $0 == "CHANGES.txt" }
                ?? entries.first { $0.contains("ПРОЧТИ") && $0.hasSuffix(".txt") }
            text = entry.flatMap { run(["-p", url.path, $0]) }
        } else {
            let changes = url.appendingPathComponent("CHANGES.txt")
            let readme = url.appendingPathComponent("ПРОЧТИ МЕНЯ.txt")
            text = (try? String(contentsOf: changes, encoding: .utf8)) ?? (try? String(contentsOf: readme, encoding: .utf8))
        }
        return text.map { parse($0) } ?? []
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
