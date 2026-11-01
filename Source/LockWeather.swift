import Foundation
import Combine
import CoreLocation

// 3.7.3 — weather for the lock-screen widget. Open-Meteo (no account, no
// key): the city typed in Settings is geocoded once, then the forecast is
// read at most every 15 minutes. Only the city name / coordinates leave the
// Mac; nothing else is sent.
struct WeatherSnapshot: Equatable {
    var place: String
    var temperature: Int
    var code: Int
    var high: Int?
    var low: Int?
    var fetchedAt: Date
    // 3.12.0: today's and tomorrow's sunrise / sunset (for the «Солнце» widget).
    var sunrises: [Date] = []
    var sunsets: [Date] = []
}

enum WeatherCodes {
    // WMO weather interpretation codes → SF Symbol + Russian description.
    static func symbol(_ code: Int, night: Bool = false) -> String {
        switch code {
        case 0: return night ? "moon.stars.fill" : "sun.max.fill"
        case 1, 2: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: return "cloud.rain.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "Ясно"
        case 1: return "Малооблачно"
        case 2: return "Переменная облачность"
        case 3: return "Облачно"
        case 45, 48: return "Туман"
        case 51, 53, 55: return "Морось"
        case 56, 57: return "Ледяная морось"
        case 61, 80: return "Небольшой дождь"
        case 63, 81: return "Дождь"
        case 65, 82: return "Ливень"
        case 66, 67: return "Ледяной дождь"
        case 71, 85: return "Небольшой снег"
        case 73: return "Снег"
        case 75, 86: return "Снегопад"
        case 77: return "Снежная крупа"
        case 95: return "Гроза"
        case 96, 99: return "Гроза с градом"
        default: return "—"
        }
    }

    // Parses Open-Meteo forecast JSON (pure; covered by tests).
    static func parseForecast(_ data: Data, place: String, now: Date = Date()) -> WeatherSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else { return nil }
        let daily = root["daily"] as? [String: Any]
        let high = ((daily?["temperature_2m_max"] as? [Any])?.first as? NSNumber)?.doubleValue
        let low = ((daily?["temperature_2m_min"] as? [Any])?.first as? NSNumber)?.doubleValue
        // Times are local to the place («2026-10-31T07:41»); the offset says which.
        let offset = (root["utc_offset_seconds"] as? NSNumber)?.intValue ?? TimeZone.current.secondsFromGMT()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let times: (String) -> [Date] = { key in
            ((daily?[key] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(formatter.date(from:)) }
        }
        return WeatherSnapshot(place: place, temperature: Int(temperature.rounded()), code: code,
                               high: high.map { Int($0.rounded()) }, low: low.map { Int($0.rounded()) },
                               fetchedAt: now, sunrises: times("sunrise"), sunsets: times("sunset"))
    }

    // 3.12.0: the next sunrise or sunset after `now`, and the day length.
    static func nextSunEvent(_ snapshot: WeatherSnapshot, now: Date = Date())
        -> (isSunrise: Bool, time: Date, dayLength: TimeInterval?)? {
        let events = snapshot.sunrises.map { (true, $0) } + snapshot.sunsets.map { (false, $0) }
        guard let next = events.filter({ $0.1 > now }).min(by: { $0.1 < $1.1 }) else { return nil }
        var length: TimeInterval?
        if let rise = snapshot.sunrises.first, let set = snapshot.sunsets.first, set > rise {
            length = set.timeIntervalSince(rise)
        }
        return (next.0, next.1, length)
    }

    // First result of Open-Meteo geocoding: (lat, lon, display name).
    static func parseGeocoding(_ data: Data) -> (Double, Double, String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let lat = (first["latitude"] as? NSNumber)?.doubleValue,
              let lon = (first["longitude"] as? NSNumber)?.doubleValue else { return nil }
        let name = first["name"] as? String ?? ""
        return (lat, lon, name)
    }
}

// 3.7.5: the city is found by itself — from the Mac's own location
// (Location Services, the same source the Weather app uses), named with
// Apple's reverse geocoder. The built-in Weather app has no interface other
// apps may read, and Apple's WeatherKit needs a paid developer account, so
// the temperature still comes from Open-Meteo, by coordinates.
final class WeatherLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [(CLLocation?) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    // allowPrompt: false while the Mac is locked — nobody could answer.
    func locate(allowPrompt: Bool, _ completion: @escaping (CLLocation?) -> Void) {
        switch manager.authorizationStatus {
        case .notDetermined:
            guard allowPrompt else { completion(nil); return }
            waiting.append(completion)
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            completion(nil)
        default:
            if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -1800 {
                completion(recent)
            } else {
                waiting.append(completion)
                manager.requestLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !waiting.isEmpty else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: flush(nil)
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        flush(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        flush(manager.location)
    }

    private func flush(_ location: CLLocation?) {
        let callbacks = waiting
        waiting.removeAll()
        DispatchQueue.main.async { callbacks.forEach { $0(location) } }
    }
}

final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var city: String
    @Published private(set) var autoLocate: Bool
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var status = "Ещё не загружено"
    @Published private(set) var locationDenied = false

    private let cityKey = "lockWeatherCityV373"
    private let autoKey = "lockWeatherAutoV375"
    private var location: (lat: Double, lon: Double, name: String, query: String)?
    private var reverseCache: (lat: Double, lon: Double, name: String)?
    private var inFlight = false
    private var lastAttempt: Date?
    private let locator = WeatherLocator()
    private let geocoder = CLGeocoder()

    private init() {
        city = UserDefaults.standard.string(forKey: cityKey) ?? ""
        autoLocate = (UserDefaults.standard.object(forKey: autoKey) as? Bool) ?? true
        locationDenied = locator.isDenied
    }

    func setCity(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != city else { return }
        city = trimmed
        UserDefaults.standard.set(trimmed, forKey: cityKey)
        location = nil
        if !autoLocate { snapshot = nil; status = trimmed.isEmpty ? "Город не указан" : "Загружаю…" }
    }

    func setAutoLocate(_ value: Bool) {
        autoLocate = value
        UserDefaults.standard.set(value, forKey: autoKey)
        snapshot = nil
        lastAttempt = nil
        status = "Загружаю…"
    }

    var isStale: Bool {
        guard let snapshot else { return true }
        // A snapshot from before 3.12.0 has no sunrise/sunset yet.
        return Date().timeIntervalSince(snapshot.fetchedAt) > 15 * 60 || snapshot.sunrises.isEmpty
    }

    // Calls back on the main queue when a new snapshot arrived.
    func refreshIfNeeded(force: Bool = false, allowPrompt: Bool = true, completion: @escaping () -> Void) {
        guard !inFlight, force || isStale else { return }
        // Never hammer the service (e.g. offline): one attempt a minute.
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        if autoLocate {
            lastAttempt = Date()
            inFlight = true
            locator.locate(allowPrompt: allowPrompt) { [weak self] found in
                guard let self else { return }
                self.locationDenied = self.locator.isDenied
                guard let found else {
                    // No location: fall back to the typed city, if any.
                    if !self.city.isEmpty {
                        self.inFlight = false
                        self.fetchByCity(completion)
                    } else {
                        self.finish(nil, status: self.locationDenied
                                    ? "Нет доступа к геопозиции — разреши или впиши город"
                                    : "Не удалось определить место", completion)
                    }
                    return
                }
                self.name(for: found) { name in
                    self.fetch(lat: found.coordinate.latitude, lon: found.coordinate.longitude,
                               place: name, completion)
                }
            }
        } else {
            guard !city.isEmpty else { status = "Город не указан"; return }
            lastAttempt = Date()
            fetchByCity(completion)
        }
    }

    private func fetchByCity(_ completion: @escaping () -> Void) {
        inFlight = true
        let query = city
        resolve(query) { [weak self] place in
            guard let self else { return }
            guard let place else {
                self.finish(nil, status: "Город «\(query)» не найден", completion)
                return
            }
            self.fetch(lat: place.lat, lon: place.lon, place: place.name, completion)
        }
    }

    // City name for coordinates (Apple's geocoder), cached within ~5 km.
    private func name(for location: CLLocation, _ completion: @escaping (String) -> Void) {
        let lat = location.coordinate.latitude, lon = location.coordinate.longitude
        if let cache = reverseCache, abs(cache.lat - lat) < 0.05, abs(cache.lon - lon) < 0.05 {
            completion(cache.name); return
        }
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ru_RU")) { [weak self] marks, _ in
            let mark = marks?.first
            let name = mark?.locality ?? mark?.subAdministrativeArea ?? mark?.administrativeArea ?? "Здесь"
            DispatchQueue.main.async {
                self?.reverseCache = (lat, lon, name)
                completion(name)
            }
        }
    }

    private func fetch(lat: Double, lon: Double, place: String, _ completion: @escaping () -> Void) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            let result = data.flatMap { WeatherCodes.parseForecast($0, place: place) }
            self?.finish(result, status: result == nil ? "Нет связи с сервисом погоды" : "Обновлено: \(place)", completion)
        }.resume()
    }

    private func resolve(_ query: String, completion: @escaping ((lat: Double, lon: Double, name: String)?) -> Void) {
        if let location, location.query == query {
            completion((location.lat, location.lon, location.name))
            return
        }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: query),
                                 URLQueryItem(name: "count", value: "1"),
                                 URLQueryItem(name: "language", value: "ru")]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            guard let found = data.flatMap(WeatherCodes.parseGeocoding) else { completion(nil); return }
            let name = found.2.isEmpty ? query : found.2
            DispatchQueue.main.async { self?.location = (found.0, found.1, name, query) }
            completion((found.0, found.1, name))
        }.resume()
    }

    private func finish(_ result: WeatherSnapshot?, status: String, _ completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.inFlight = false
            self.status = status
            if let result { self.snapshot = result }
            completion()
        }
    }

    static let locationPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
}
