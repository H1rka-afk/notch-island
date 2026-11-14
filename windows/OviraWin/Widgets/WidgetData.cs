using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using Ovira.Core;

namespace Ovira.Widgets
{
    // What the system widgets measure: processor, memory, network.
    public static class Meters
    {
        [StructLayout(LayoutKind.Sequential)] private struct FileTime { public uint Low, High; public ulong Value => ((ulong)High << 32) | Low; }
        [DllImport("kernel32.dll")] private static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatus
        {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtended;
        }
        [DllImport("kernel32.dll")] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

        private static ulong _idle, _total;
        private static DateTime _cpuAt, _netAt;
        private static double _cpu;
        private static long _down, _up;
        private static double _downRate, _upRate;
        public static readonly List<double> CpuHistory = new(), MemoryHistory = new();

        // Sampled at most once a second, whoever asks.
        public static double Cpu()
        {
            if ((DateTime.Now - _cpuAt).TotalSeconds < 0.9) return _cpu;
            _cpuAt = DateTime.Now;
            if (GetSystemTimes(out var idle, out var kernel, out var user))
            {
                ulong total = kernel.Value + user.Value;
                if (_total != 0 && total > _total) _cpu = Math.Clamp(1.0 - (double)(idle.Value - _idle) / (total - _total), 0, 1);
                _idle = idle.Value; _total = total;
            }
            Push(CpuHistory, _cpu);
            Push(MemoryHistory, Memory().Used);
            return _cpu;
        }

        private static void Push(List<double> list, double value)
        {
            list.Add(value);
            if (list.Count > 40) list.RemoveAt(0);
        }

        public static (double Used, double TotalGb, double UsedGb) Memory()
        {
            var m = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            if (!GlobalMemoryStatusEx(ref m) || m.TotalPhys == 0) return (0, 0, 0);
            double total = m.TotalPhys / 1e9, used = (m.TotalPhys - m.AvailPhys) / 1e9;
            return (used / total, total, used);
        }

        public static (double Down, double Up) Network()
        {
            var now = DateTime.Now;
            double dt = (now - _netAt).TotalSeconds;
            if (dt < 0.9) return (_downRate, _upRate);
            long down = 0, up = 0;
            try
            {
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                    var s = nic.GetIPStatistics();
                    down += s.BytesReceived; up += s.BytesSent;
                }
            }
            catch { }
            if (_netAt != default && dt < 10)
            {
                _downRate = Math.Max(0, down - _down) / dt;
                _upRate = Math.Max(0, up - _up) / dt;
            }
            _netAt = now; _down = down; _up = up;
            return (_downRate, _upRate);
        }
    }

    // Weather (open-meteo.com) and exchange rates (the Bank of Russia's daily
    // table via cbr-xml-daily.ru). Asked only while such a widget is on the
    // desktop: weather every 30 minutes, rates every 3 hours. Only the city
    // name from Settings is sent, nothing about the computer or the user.
    public static class Online
    {
        private static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };

        // 0.8.1: hours for the iPhone-style card, today's low and high, and
        // a weather «kind» drawn as an icon (WeatherIcon) instead of an emoji.
        public sealed record Day(string Name, string Kind, int Max, int Min);
        public sealed record Hour(string Label, string Kind, int Temp);
        public sealed record WeatherNow(string City, int Temp, string Text, string Kind, int Min, int Max, List<Hour> Hours, List<Day> Days, DateTime At);

        public static WeatherNow? Weather { get; private set; }
        public static string WeatherNote { get; private set; } = "Загружаю…";
        private static DateTime _weatherAt = DateTime.MinValue;
        private static string _weatherCity = "";
        private static bool _weatherBusy;
        private static int _fails;
        private static bool _hooked;

        // 0.8.1: the last forecast is kept on disk, so after a restart (or
        // while the network wakes up after sleep) the card shows it at once
        // instead of «Нет связи»; a failed try is repeated soon (15 s, 30 s,
        // 1 min… up to 5 min) and as soon as Windows says the network is back.
        private static string CacheFile => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ovira", "weather.json");

        private static DateTime _okAt = DateTime.MinValue;
        private static string _cacheTried = "";

        public static void NeedWeather()
        {
            var city = (Settings.Current.WeatherCity ?? "").Trim();
            if (city.Length == 0) { Weather = null; WeatherNote = "Укажи город в настройках виджетов"; return; }
            if (!_hooked)
            {
                _hooked = true;
                System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += (_, e) => { if (e.IsAvailable) _weatherAt = DateTime.MinValue; };
            }
            if (_cacheTried != city) { _cacheTried = city; if (city != _weatherCity) { Weather = null; _okAt = DateTime.MinValue; } LoadCache(city); }
            if (_weatherBusy) return;
            double wait;
            if (city != _weatherCity) wait = 0;
            else if (_fails > 0) wait = Math.Min(300, 15 * Math.Pow(2, _fails - 1));        // 15 s, 30 s, 1 min … 5 min
            else wait = _okAt == DateTime.MinValue ? 0 : 30 * 60;
            var since = (DateTime.Now - (_fails > 0 ? _weatherAt : (_okAt == DateTime.MinValue ? DateTime.MinValue : _okAt))).TotalSeconds;
            if (city == _weatherCity && since < wait) return;
            if (city != _weatherCity) _fails = 0;
            _weatherBusy = true;
            _weatherCity = city;
            _weatherAt = DateTime.Now;
            _ = LoadWeather(city);
        }

        private sealed record Cached(string Query, WeatherNow Data, double Lat, double Lon);
        private static (string Query, double Lat, double Lon)? _place;

        private static void LoadCache(string city)
        {
            try
            {
                if (!System.IO.File.Exists(CacheFile)) return;
                var c = JsonSerializer.Deserialize<Cached>(System.IO.File.ReadAllText(CacheFile));
                if (c == null || !string.Equals(c.Query, city, StringComparison.OrdinalIgnoreCase)) return;
                _place = (c.Query, c.Lat, c.Lon);
                if ((DateTime.Now - c.Data.At).TotalHours < 12) { Weather = c.Data; WeatherNote = ""; }
            }
            catch { }
        }

        private static async Task LoadWeather(string city)
        {
            try
            {
                var inv = System.Globalization.CultureInfo.InvariantCulture;
                double lat, lon;
                string name = city;
                if (_place is { } p && string.Equals(p.Query, city, StringComparison.OrdinalIgnoreCase)) { lat = p.Lat; lon = p.Lon; name = Weather?.City ?? city; }
                else
                {
                    var geo = JsonDocument.Parse(await Http.GetStringAsync(
                        "https://geocoding-api.open-meteo.com/v1/search?count=1&language=ru&name=" + Uri.EscapeDataString(city)));
                    if (!geo.RootElement.TryGetProperty("results", out var results) || results.GetArrayLength() == 0)
                    {
                        Weather = null; WeatherNote = "Город не найден"; _fails = 0; return;
                    }
                    var place = results[0];
                    lat = place.GetProperty("latitude").GetDouble();
                    lon = place.GetProperty("longitude").GetDouble();
                    name = place.TryGetProperty("name", out var n) ? n.GetString() ?? city : city;
                    _place = (city, lat, lon);
                }
                var doc = JsonDocument.Parse(await Http.GetStringAsync(
                    "https://api.open-meteo.com/v1/forecast?latitude=" + lat.ToString(inv) + "&longitude=" + lon.ToString(inv) +
                    "&current=temperature_2m,weather_code,is_day&hourly=temperature_2m,weather_code,is_day" +
                    "&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=6"));
                var root = doc.RootElement;
                var current = root.GetProperty("current");
                int code = current.GetProperty("weather_code").GetInt32();
                bool day = !current.TryGetProperty("is_day", out var isDay) || isDay.GetInt32() == 1;
                int offset = root.TryGetProperty("utc_offset_seconds", out var off) ? off.GetInt32() : 0;
                var localNow = DateTime.UtcNow.AddSeconds(offset);

                var hourly = root.GetProperty("hourly");
                var hours = new List<Hour>();
                var times = hourly.GetProperty("time");
                for (int i = 0; i < times.GetArrayLength() && hours.Count < 6; i++)
                {
                    var t = DateTime.Parse(times[i].GetString()!, inv);
                    if (t <= localNow) continue;
                    bool hDay = hourly.GetProperty("is_day")[i].GetInt32() == 1;
                    hours.Add(new Hour(t.Hour.ToString(), Describe(hourly.GetProperty("weather_code")[i].GetInt32(), hDay).Kind,
                                       (int)Math.Round(hourly.GetProperty("temperature_2m")[i].GetDouble())));
                }

                var daily = root.GetProperty("daily");
                var days = new List<Day>();
                var ru = new System.Globalization.CultureInfo("ru-RU");
                int min = 0, max = 0;
                for (int i = 0; i < daily.GetProperty("time").GetArrayLength(); i++)
                {
                    var date = DateTime.Parse(daily.GetProperty("time")[i].GetString()!, inv);
                    int dMax = (int)Math.Round(daily.GetProperty("temperature_2m_max")[i].GetDouble());
                    int dMin = (int)Math.Round(daily.GetProperty("temperature_2m_min")[i].GetDouble());
                    if (i == 0) { min = dMin; max = dMax; }
                    var label = i == 0 ? "Сегодня" : ru.TextInfo.ToTitleCase(ru.DateTimeFormat.GetAbbreviatedDayName(date.DayOfWeek));
                    days.Add(new Day(label, Describe(daily.GetProperty("weather_code")[i].GetInt32(), true).Kind, dMax, dMin));
                }
                var (text, kind) = Describe(code, day);
                Weather = new WeatherNow(name, (int)Math.Round(current.GetProperty("temperature_2m").GetDouble()), text, kind, min, max, hours, days, DateTime.Now);
                WeatherNote = "";
                _fails = 0;
                _okAt = DateTime.Now;
                try
                {
                    System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(CacheFile)!);
                    System.IO.File.WriteAllText(CacheFile, JsonSerializer.Serialize(new Cached(city, Weather, lat, lon)));
                }
                catch { }
            }
            catch
            {
                _fails++;
                // keep showing the last forecast; only an empty card says so
                if (Weather == null) WeatherNote = _fails < 3 ? "Загружаю…" : "Нет связи";
            }
            finally { _weatherBusy = false; }
        }

        // WMO weather codes → words (as the iPhone says them) and an icon.
        public static (string Text, string Kind) Describe(int code, bool day)
        {
            string sky = day ? "sun" : "moon";
            return code switch
            {
                0 => ("Ясно", sky),
                1 => ("Преимущественно ясно", "cloud." + sky),
                2 => ("Переменная облачность", "cloud." + sky),
                3 => ("Облачно", "cloud"),
                45 or 48 => ("Туман", "fog"),
                51 or 53 => ("Изморось", "cloud." + sky + ".rain"),
                55 => ("Изморось", "cloud.drizzle"),
                56 or 57 => ("Ледяная изморось", "cloud.sleet"),
                61 => ("Небольшой дождь", "cloud." + sky + ".rain"),
                63 => ("Дождь", "cloud.rain"),
                65 => ("Сильный дождь", "cloud.heavyrain"),
                66 or 67 => ("Ледяной дождь", "cloud.sleet"),
                71 => ("Небольшой снег", "cloud.snow"),
                73 => ("Снег", "cloud.snow"),
                75 => ("Сильный снег", "cloud.snow"),
                77 => ("Снежная крупа", "cloud.snow"),
                80 => ("Ливни", "cloud." + sky + ".rain"),
                81 or 82 => ("Ливень", "cloud.heavyrain"),
                85 or 86 => ("Снегопад", "cloud.snow"),
                95 => ("Гроза", "cloud.bolt"),
                >= 96 => ("Гроза с градом", "cloud.bolt"),
                _ => ("Облачно", "cloud"),
            };
        }

        public sealed record Rate(string Code, double Value, double Change);
        public static List<Rate> Rates { get; private set; } = new();
        public static string RatesNote { get; private set; } = "Загружаю…";
        private static DateTime _ratesAt;
        private static bool _ratesBusy;

        public static void NeedRates()
        {
            if (_ratesBusy || (DateTime.Now - _ratesAt).TotalHours < 3) return;
            _ratesBusy = true;
            _ratesAt = DateTime.Now;
            _ = LoadRates();
        }

        private static async Task LoadRates()
        {
            try
            {
                var doc = JsonDocument.Parse(await Http.GetStringAsync("https://www.cbr-xml-daily.ru/daily_json.js"));
                var valute = doc.RootElement.GetProperty("Valute");
                var list = new List<Rate>();
                foreach (var code in new[] { "USD", "EUR", "CNY" })
                {
                    if (!valute.TryGetProperty(code, out var v)) continue;
                    double nominal = v.TryGetProperty("Nominal", out var nom) ? nom.GetDouble() : 1;
                    double value = v.GetProperty("Value").GetDouble() / nominal, previous = v.GetProperty("Previous").GetDouble() / nominal;
                    list.Add(new Rate(code, value, value - previous));
                }
                Rates = list;
                RatesNote = list.Count == 0 ? "Нет данных" : "";
            }
            catch
            {
                if (Rates.Count == 0) RatesNote = "Нет связи";
                _ratesAt = DateTime.Now.AddHours(-3).AddMinutes(5);
            }
            finally { _ratesBusy = false; }
        }
    }
}
