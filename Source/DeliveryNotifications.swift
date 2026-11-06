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
    enum Category { case taxi, lavka, food, groceries, parcel }
    let name: String          // brand, as people call it
    let category: Category
    let ids: [String]         // pieces of the app's identifier
    let words: [String]       // or words in the notification (website pushes)
    let store: String?        // App Store search term for the icon

    var symbol: String {
        switch category {
        case .taxi: return "car.fill"
        case .lavka: return "basket.fill"
        case .food: return "takeoutbag.and.cup.and.straw.fill"
        case .groceries: return "cart.fill"
        case .parcel: return "shippingbox.fill"
        }
    }
    var tint: Color {
        switch category {
        case .taxi: return Color(red: 1.0, green: 0.82, blue: 0.0)
        case .lavka: return Color(red: 1.0, green: 0.36, blue: 0.47)
        case .food: return Color(red: 1.0, green: 0.55, blue: 0.1)
        case .groceries: return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .parcel: return Color(red: 0.45, green: 0.68, blue: 1.0)
        }
    }
}

enum DeliveryCatalog {
    private static func b(_ name: String, _ category: DeliveryService.Category, _ ids: [String],
                          _ words: [String] = [], store: String? = nil) -> DeliveryService {
        DeliveryService(name: name, category: category, ids: ids, words: words, store: store ?? name)
    }

    static let services: [DeliveryService] = [
        // Taxi
        b("Яндекс Go", .taxi, ["yandex.taxi", "ru.yandex.ytaxi", "ru.yandex.mobile.taxi", "yandex.go", "yandexgo"],
          ["яндекс go", "yandex go", "яндекс такси"]),
        b("Uber", .taxi, ["uber"], ["uber"], store: "Uber Russia"),
        b("Ситимобил", .taxi, ["citymobil"], ["ситимобил"]),
        b("Максим", .taxi, ["taxi.maxim", "taximaxim"], ["такси максим"], store: "Такси Максим"),
        b("Bolt", .taxi, ["bolt.client", "ee.mtakso"], ["bolt"]),
        b("Везёт", .taxi, ["vezet"], ["везёт"], store: "Везёт такси"),
        b("inDrive", .taxi, ["indriver", "indrive", "drivee"], ["indrive"]),
        // Lavka
        b("Лавка", .lavka, ["lavka", "ru.yandex.grocery"], ["лавка"], store: "Яндекс Лавка"),
        // Food
        b("Яндекс Еда", .food, ["yandex.eda", "foodfox"], ["яндекс еда"]),
        b("Delivery Club", .food, ["deliveryclub", "delivery-club"], ["delivery club"], store: "Маркет Деливери"),
        b("Додо Пицца", .food, ["dodopizza"], ["додо"]),
        b("KFC", .food, ["kfc"], ["kfc"], store: "KFC Россия"),
        b("Вкусно — и точка", .food, ["vkusnoitochka"], ["вкусно — и точка", "вкусно и точка"], store: "Вкусно и точка"),
        b("Бургер Кинг", .food, ["burgerking"], ["бургер кинг"]),
        b("Тануки", .food, ["tanuki"], ["тануки"]),
        b("Якитория", .food, ["yakitoriya"], ["якитория"]),
        b("Чиббис", .food, ["chibbis"], ["чиббис"]),
        // Groceries
        b("ВкусВилл", .groceries, ["vkusvill"], ["вкусвилл"]),
        b("Самокат", .groceries, ["samokat"], ["самокат"]),
        b("Купер", .groceries, ["kuper", "sbermarket"], ["купер", "сбермаркет"]),
        b("Перекрёсток", .groceries, ["perekrestok"], ["перекрёсток", "перекресток"], store: "Перекрёсток впрок"),
        b("Магнит", .groceries, ["magnit"], ["магнит"]),
        b("Пятёрочка", .groceries, ["pyaterochka"], ["пятёрочка", "пятерочка"]),
        b("Ашан", .groceries, ["auchan"], ["ашан"]),
        b("Утконос", .groceries, ["utkonos"], ["утконос"]),
        b("Metro", .groceries, ["metro-cc"], [], store: "METRO Россия"),
        b("Лента", .groceries, ["lentaonline"], [], store: "Лента онлайн"),
        // Parcels
        b("Ozon", .parcel, ["ozon"], ["ozon", "озон"]),
        b("Wildberries", .parcel, ["wildberries"], ["wildberries", "вайлдберриз"]),
        b("СДЭК", .parcel, ["cdek"], ["сдэк", "cdek"]),
        b("Почта России", .parcel, ["pochta"], ["почта россии"]),
        b("Boxberry", .parcel, ["boxberry"], ["boxberry"]),
        b("AliExpress", .parcel, ["aliexpress"], ["aliexpress"]),
        b("Яндекс Маркет", .parcel, ["yandex.market", "beru"], ["яндекс маркет"]),
        b("DPD", .parcel, ["dpd"], [], store: "DPD Russia"),
        b("Авито", .parcel, ["avito"], ["авито доставка"]),
        b("Lamoda", .parcel, ["lamoda"], ["lamoda"]),
    ]

    // Website notifications without a known brand: by what they talk about.
    private static let generic: [(words: [String], service: DeliveryService)] = [
        (["водитель", "такси"], DeliveryService(name: "Такси", category: .taxi, ids: [], words: [], store: nil)),
        (["курьер", "доставка еды"], DeliveryService(name: "Доставка", category: .food, ids: [], words: [], store: nil)),
        (["пункт выдачи", "постамат", "посылка"], DeliveryService(name: "Посылка", category: .parcel, ids: [], words: [], store: nil)),
    ]

    static func service(named name: String) -> DeliveryService? { services.first { $0.name == name } }

    static func isBrowser(_ appID: String) -> Bool {
        let id = appID.lowercased()
        let browsers = ["com.apple.safari", "com.google.chrome", "ru.yandex.desktop.yandex-browser", "yandex.browser",
                        "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware", "company.thebrowser"]
        return browsers.contains(where: { id.contains($0) })
    }

    // Which service a notification belongs to, if any.
    static func match(appID: String, text: String) -> DeliveryService? {
        let id = appID.lowercased()
        if !isBrowser(id), let s = services.first(where: { s in s.ids.contains(where: { id.contains($0) }) }) { return s }
        // Website notifications come from the browser: look at the words.
        guard isBrowser(id) || id.contains("mirroring") else { return nil }
        let lower = text.lowercased()
        if let s = services.first(where: { s in s.words.contains(where: { lower.contains($0) }) }) { return s }
        return generic.first(where: { g in g.words.contains(where: { lower.contains($0) }) })?.service
    }

    // One line for the island: the body when it is short, else the title.
    static func line(title: String, subtitle: String, body: String) -> String {
        let candidates = [body, subtitle, title].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = candidates.first(where: { !$0.isEmpty && $0.count <= 26 })
            ?? candidates.first(where: { !$0.isEmpty }) ?? ""
        return text.count > 28 ? String(text.prefix(26)) + "…" : text
    }
}

final class DeliveryNotificationWatch {
    var onUpdate: ((DeliveryService, String, String) -> Void)?
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
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(service, line, app) }
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

// 4.16.1: the real app icon instead of a coloured symbol. A Mac app gives its
// own icon; an iPhone app (notifications via iPhone Mirroring) or a website
// gets the icon from the public App Store catalogue — once, then it is kept
// in ~/Library/Caches. Only the app's name or identifier is sent, never the
// text of the notification. If nothing is found, the coloured symbol stays.
final class DeliveryIcons {
    static let shared = DeliveryIcons()
    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Ovira/DeliveryIcons", isDirectory: true)
    }()

    func icon(for service: DeliveryService, appID: String, completion: @escaping (NSImage?) -> Void) {
        let key = service.store == nil ? "" : service.name
        // A real Mac app (not a browser): its own icon, no network.
        if !appID.isEmpty, !DeliveryCatalog.isBrowser(appID),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            completion(NSWorkspace.shared.icon(forFile: url.path)); return
        }
        guard !key.isEmpty, !missing.contains(key) else { completion(nil); return }
        if let image = memory[key] { completion(image); return }
        let file = folder.appendingPathComponent(Self.fileName(key))
        if let image = NSImage(contentsOf: file) { memory[key] = image; completion(image); return }

        let mirrored = !appID.isEmpty && !DeliveryCatalog.isBrowser(appID) && appID.contains(".")
        var parts = URLComponents(string: "https://itunes.apple.com/" + (mirrored ? "lookup" : "search"))!
        parts.queryItems = mirrored
            ? [URLQueryItem(name: "bundleId", value: appID), URLQueryItem(name: "country", value: "ru")]
            : [URLQueryItem(name: "term", value: service.store), URLQueryItem(name: "entity", value: "software"),
               URLQueryItem(name: "country", value: "ru"), URLQueryItem(name: "limit", value: "1")]
        var finished = false
        let finish: (NSImage?) -> Void = { [weak self] image in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                if let image { self?.memory[key] = image }
                completion(image)
            }
        }
        // Never keep a notification waiting for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
        fetchArtwork(parts.url!) { [weak self] data in
            guard let self, let data, let image = NSImage(data: data) else {
                if mirrored { self?.retryBySearch(service, key: key, finish: finish) } else { finish(nil) }
                return
            }
            self.save(data, key: key)
            finish(image)
        }
    }

    // Mirrored app not in the Russian catalogue by its id: try by name.
    private func retryBySearch(_ service: DeliveryService, key: String, finish: @escaping (NSImage?) -> Void) {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [URLQueryItem(name: "term", value: service.store), URLQueryItem(name: "entity", value: "software"),
                            URLQueryItem(name: "country", value: "ru"), URLQueryItem(name: "limit", value: "1")]
        fetchArtwork(parts.url!) { [weak self] data in
            guard let self, let data, let image = NSImage(data: data) else {
                DispatchQueue.main.async { self?.missing.insert(key) }
                finish(nil); return
            }
            self.save(data, key: key)
            finish(image)
        }
    }

    private func fetchArtwork(_ url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Ovira", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let art = (first["artworkUrl512"] ?? first["artworkUrl100"]) as? String,
                  let artURL = URL(string: art) else { completion(nil); return }
            URLSession.shared.dataTask(with: URLRequest(url: artURL, timeoutInterval: 8)) { image, _, _ in
                completion(image)
            }.resume()
        }.resume()
    }

    private func save(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(Self.fileName(key)))
    }

    private static func fileName(_ key: String) -> String {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return safe + ".img"
    }
}
