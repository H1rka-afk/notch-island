import AppKit
import SQLite3
import SwiftUI

// 4.16.0 — taxi, food and parcel updates in the island.
//
// Yandex Go, Lavka, VkusVill, Samokat and the like have no Mac apps; their
// news reaches the Mac as ordinary notifications — from the iPhone (iPhone
// Mirroring, macOS 15+) or from the service's website in a browser. macOS
// keeps every delivered notification in its notification database; Ovira
// reads only the NEW ones, only from these services, and shows the text in
// the island («Водитель приедет через 4 мин», «Курьер уже у двери»…).
// Nothing is changed or sent anywhere. Reading the database needs Full Disk
// Access — the same one the Focus banner uses.
struct DeliveryService {
    let name: String
    let symbol: String
    let tint: Color
    let ids: [String]        // pieces of the app's identifier
    let words: [String]      // or words in the notification (website pushes)
}

enum DeliveryCatalog {
    static let services: [DeliveryService] = [
        DeliveryService(name: "Такси", symbol: "car.fill", tint: Color(red: 1.0, green: 0.82, blue: 0.0),
                        ids: ["yandex.taxi", "ru.yandex.mobile.taxi", "yandex.go", "yandexgo", "ru.yandex.ytaxi",
                              "uber", "citymobil", "taxi.maxim", "bolt.client", "ee.mtakso", "vezet", "drivee"],
                        words: ["яндекс go", "yandex go", "водитель", "такси", "ситимобил", "максим"]),
        DeliveryService(name: "Лавка", symbol: "basket.fill", tint: Color(red: 1.0, green: 0.36, blue: 0.47),
                        ids: ["lavka", "ru.yandex.grocery"],
                        words: ["лавка"]),
        DeliveryService(name: "Еда", symbol: "takeoutbag.and.cup.and.straw.fill", tint: Color(red: 1.0, green: 0.55, blue: 0.1),
                        ids: ["yandex.eda", "foodfox", "deliveryclub", "delivery-club", "dodopizza", "dodo", "kfc",
                              "burgerking", "vkusnoitochka", "tanuki", "yakitoriya", "chibbis"],
                        words: ["яндекс еда", "delivery club", "доставка еды", "курьер", "додо"]),
        DeliveryService(name: "Продукты", symbol: "cart.fill", tint: Color(red: 0.3, green: 0.85, blue: 0.4),
                        ids: ["vkusvill", "samokat", "kuper", "sbermarket", "perekrestok", "magnit", "metro-cc",
                              "auchan", "lentaonline", "utkonos", "pyaterochka"],
                        words: ["вкусвилл", "самокат", "купер", "сбермаркет", "перекрёсток", "перекресток", "магнит"]),
        DeliveryService(name: "Посылка", symbol: "shippingbox.fill", tint: Color(red: 0.45, green: 0.68, blue: 1.0),
                        ids: ["ozon", "wildberries", "cdek", "pochta", "boxberry", "aliexpress", "yandex.market",
                              "beru", "dpd", "avito", "lamoda"],
                        words: ["ozon", "озон", "wildberries", "вайлдберриз", "сдэк", "cdek", "почта россии", "пункт выдачи",
                                "постамат", "яндекс маркет"])
    ]

    // Which service a notification belongs to, if any.
    static func match(appID: String, text: String) -> DeliveryService? {
        let id = appID.lowercased()
        if let s = services.first(where: { s in s.ids.contains(where: { id.contains($0) }) }) { return s }
        // Website notifications come from the browser: look at the words.
        let browsers = ["com.apple.safari", "com.google.chrome", "ru.yandex.desktop.yandex-browser", "yandex.browser",
                        "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware", "company.thebrowser"]
        guard browsers.contains(where: { id.contains($0) }) || id.contains("mirroring") else { return nil }
        let lower = text.lowercased()
        return services.first(where: { s in s.words.contains(where: { lower.contains($0) }) })
    }

    // One line for the island: the body when it is short, else the title.
    static func line(title: String, subtitle: String, body: String) -> String {
        let candidates = [body, subtitle, title].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = candidates.first(where: { !$0.isEmpty && $0.count <= 38 })
            ?? candidates.first(where: { !$0.isEmpty }) ?? ""
        return text.count > 38 ? String(text.prefix(36)) + "…" : text
    }
}

final class DeliveryNotificationWatch {
    var onUpdate: ((DeliveryService, String) -> Void)?
    private var timer: Timer?
    private var lastID: Int64 = -1
    private var seenApps: Set<String> = []
    private let queue = DispatchQueue(label: "ovira.delivery", qos: .utility)
    private var reportedNoAccess = false

    // macOS 15+ keeps it in a group container; older systems in DARWIN_USER_DIR.
    private static var databaseURL: URL {
        let modern = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
        if FileManager.default.fileExists(atPath: modern.path) { return modern }
        var buffer = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            let legacy = URL(fileURLWithPath: String(cString: buffer))
                .appendingPathComponent("com.apple.notificationcenter/db2/db")
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        }
        return modern
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        queue.async { [weak self] in self?.read() }
    }

    private func read() {
        var db: OpaquePointer?
        let path = "file:\(Self.databaseURL.path)?mode=ro"
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if !reportedNoAccess {
                reportedNoAccess = true
                DeliveryLog.write("no access to the notification database (Full Disk Access?)")
            }
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        // First look: start from the newest — old notifications are not shown.
        if lastID < 0 {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &statement, nil) == SQLITE_OK,
               sqlite3_step(statement) == SQLITE_ROW {
                lastID = sqlite3_column_int64(statement, 0)
                DeliveryLog.write("watching from record \(lastID)")
            }
            sqlite3_finalize(statement)
            return
        }
        let sql = """
            SELECT r.rec_id, IFNULL(a.identifier, ''), r.data FROM record r
            LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 30
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            DeliveryLog.write("unexpected database layout: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastID)
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            lastID = max(lastID, id)
            let app = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard let blob = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            let (title, subtitle, body) = Self.texts(from: data)
            // Only the app identifier goes to the log — never the text.
            if seenApps.insert(app).inserted { DeliveryLog.write("notifications from \(app)") }
            guard let service = DeliveryCatalog.match(appID: app, text: "\(title) \(subtitle) \(body)") else { continue }
            let line = DeliveryCatalog.line(title: title, subtitle: subtitle, body: body)
            guard !line.isEmpty else { continue }
            DeliveryLog.write("shown: \(service.name) from \(app)")
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(service, line) }
        }
    }

    // The record is a binary property list: req → titl / subt / body.
    private static func texts(from data: Data) -> (String, String, String) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let req = plist["req"] as? [String: Any] else { return ("", "", "") }
        return ((req["titl"] as? String) ?? "", (req["subt"] as? String) ?? "", (req["body"] as? String) ?? "")
    }
}

enum DeliveryLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchIsland-Delivery.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp)  \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
