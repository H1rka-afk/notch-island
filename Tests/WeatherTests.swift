import Foundation

// swiftc -parse-as-library Source/LockWeather.swift Tests/WeatherTests.swift -o wt && ./wt
@main
struct WeatherTests {
    static func main() {
        let forecast = """
        {"current":{"time":"2026-10-30T20:00","temperature_2m":6.6,"weather_code":3},
         "daily":{"time":["2026-10-30"],"temperature_2m_max":[9.4],"temperature_2m_min":[2.6]}}
        """.data(using: .utf8)!
        let snapshot = WeatherCodes.parseForecast(forecast, place: "Москва")!
        precondition(snapshot.temperature == 7 && snapshot.code == 3)
        precondition(snapshot.high == 9 && snapshot.low == 3 && snapshot.place == "Москва")
        precondition(WeatherCodes.parseForecast("{}".data(using: .utf8)!, place: "x") == nil)

        let geo = """
        {"results":[{"name":"Москва","latitude":55.75,"longitude":37.62}]}
        """.data(using: .utf8)!
        let place = WeatherCodes.parseGeocoding(geo)!
        precondition(place.0 == 55.75 && place.1 == 37.62 && place.2 == "Москва")
        precondition(WeatherCodes.parseGeocoding("{\"generationtime_ms\":0.1}".data(using: .utf8)!) == nil)

        precondition(WeatherCodes.symbol(0) == "sun.max.fill" && WeatherCodes.symbol(0, night: true) == "moon.stars.fill")
        precondition(WeatherCodes.symbol(71) == "cloud.snow.fill" && WeatherCodes.text(3) == "Облачно")
        // 3.12.0: sunrise / sunset in the place's own time (UTC+3 here).
        let sunny = """
        {"utc_offset_seconds":10800,"current":{"temperature_2m":1,"weather_code":0},
         "daily":{"temperature_2m_max":[3],"temperature_2m_min":[-1],
                  "sunrise":["2026-10-31T07:41","2026-11-01T07:43"],
                  "sunset":["2026-10-31T16:53","2026-11-01T16:51"]}}
        """.data(using: .utf8)!
        let sun = WeatherCodes.parseForecast(sunny, place: "Москва")!
        precondition(sun.sunrises.count == 2 && sun.sunsets.count == 2)
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        precondition(cal.component(.hour, from: sun.sunrises[0]) == 4 && cal.component(.minute, from: sun.sunrises[0]) == 41)
        // 12:00 Moscow (09:00 UTC) → next is today's sunset; 20:00 → tomorrow's sunrise.
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 17))!
        let a = WeatherCodes.nextSunEvent(sun, now: noon)!
        precondition(!a.isSunrise && a.time == sun.sunsets[0])
        precondition(Int(a.dayLength!) == (9 * 60 + 12) * 60)
        let b = WeatherCodes.nextSunEvent(sun, now: evening)!
        precondition(b.isSunrise && b.time == sun.sunrises[1])
        let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        precondition(WeatherCodes.nextSunEvent(sun, now: late) == nil)
        // Old snapshots without the fields still parse.
        precondition(snapshot.sunrises.isEmpty)
        print("WeatherTests: OK")
    }
}
