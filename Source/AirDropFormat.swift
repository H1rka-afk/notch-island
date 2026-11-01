import Foundation

// 3.9.4 — pure AirDrop helpers (covered by tests).
enum AirDropFormat {
    static func isAirDropQuarantine(_ value: String) -> Bool {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        let agent = parts[2].lowercased()
        return agent == "sharingd" || agent.contains("airdrop")
    }

    // Banner text: «45%» while receiving one file, «3 · 45%» for several.
    static func progressText(fraction: Double, files: Int) -> String {
        let percent = "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
        return files > 1 ? "\(files) · \(percent)" : percent
    }

    static func receivedText(count: Int) -> String {
        count > 1 ? "Получено \(count)" : "Получено"
    }
}
