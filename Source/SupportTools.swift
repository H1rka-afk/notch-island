import AppKit
import ApplicationServices
import Foundation
import Security

// 3.2.0 — read-only checks of everything Notch Island depends on, plus one
// combined diagnostic report. Nothing here changes system settings; the
// "Fix" buttons only open the matching pane of System Settings.
struct PermissionReport: Equatable {
    enum Signing: Equatable {
        case persistent(String)   // certificate name
        case adhoc
        case unknown
    }

    var accessibility: Bool
    var fullDiskAccess: Bool
    var downloads: Bool
    var signing: Signing

    var essentialsGranted: Bool { accessibility && fullDiskAccess }
}

enum PermissionChecker {
    static func check() -> PermissionReport {
        PermissionReport(accessibility: AXIsProcessTrusted(),
                         fullDiskAccess: hasFullDiskAccess(),
                         downloads: canReadDownloads(),
                         signing: signing())
    }

    // The system TCC database is readable only with Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    static func canReadDownloads() -> Bool {
        (try? FileManager.default.contentsOfDirectory(at: AppUpdater.downloadsFolder,
                                                      includingPropertiesForKeys: nil)) != nil
    }

    static func signing() -> PermissionReport.Signing {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unknown }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return .unknown }
        guard let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return .adhoc }
        let name = SecCertificateCopySubjectSummary(leaf) as String? ?? "сертификат"
        return .persistent(name)
    }

    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let fullDiskPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let filesPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"

    static func open(_ pane: String) {
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

enum DiagnosticsReport {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchIsland-Diagnostics.txt")
    }

    private static let logNames = [
        ("Обновление", "NotchIsland-Update.log"),
        ("Обложки", "NotchIsland-Artwork.log"),
        ("Таймер «Часов»", "NotchIsland-ClockTimer.log"),
        ("Экран блокировки", "NotchIsland-LockScreen.log")
    ]

    // Builds one text file from the app state and the tails of every log.
    // The individual logs never contain track titles or artists.
    static func build(statusLines: [(String, String)]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let permissions = PermissionChecker.check()
        let signing: String
        switch permissions.signing {
        case .persistent(let name): signing = "постоянная (\(name))"
        case .adhoc: signing = "временная (ad-hoc)"
        case .unknown: signing = "не определена"
        }
        var lines: [String] = []
        lines.append("Notch Island — диагностика")
        lines.append("Дата: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Версия: \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)")
        lines.append("Подпись: \(signing)")
        lines.append("Универсальный доступ: \(permissions.accessibility ? "есть" : "НЕТ")")
        lines.append("Полный доступ к диску: \(permissions.fullDiskAccess ? "есть" : "НЕТ")")
        lines.append("Папка «Загрузки»: \(permissions.downloads ? "доступна" : "НЕТ доступа")")
        for (title, value) in statusLines {
            lines.append("\(title): \(value)")
        }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        for (title, name) in logNames {
            lines.append("")
            lines.append("===== \(title) (\(name)) =====")
            guard let text = try? String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8) else {
                lines.append("(журнала нет)")
                continue
            }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(40).map(String.init))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    static func write(statusLines: [(String, String)], copyToClipboard: Bool) -> URL? {
        let text = build(statusLines: statusLines)
        if copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
}
