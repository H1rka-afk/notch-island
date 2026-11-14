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

        // 0.8.6: a sturdier connection. .NET tries a site's IPv6 address first
        // and waits a long time if IPv6 doesn't really work on the network —
        // the forecast then timed out («нет погоды»). Now IPv4 goes first and
        // each address gets 5 seconds. And if Open-Meteo can't be reached,
        // the forecast comes from the Norwegian Met Institute (yr.no) instead.
        private static readonly HttpClient Http = MakeHttp();

        private static HttpClient MakeHttp()
        {
            var handler = new System.Net.Http.SocketsHttpHandler
            {
                ConnectTimeout = TimeSpan.FromSeconds(12),
                PooledConnectionLifetime = TimeSpan.FromMinutes(10),
                ConnectCallback = async (ctx, token) =>
                {
                    var addresses = await System.Net.Dns.GetHostAddressesAsync(ctx.DnsEndPoint.Host, token);
                    Exception? last = null;
                    foreach (var ip in addresses.OrderBy(x => x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork ? 0 : 1))
                    {
                        var socket = new System.Net.Sockets.Socket(ip.AddressFamily, System.Net.Sockets.SocketType.Stream, System.Net.Sockets.ProtocolType.Tcp) { NoDelay = true };
                        try
                        {
                            using var each = System.Threading.CancellationTokenSource.CreateLinkedTokenSource(token);
                            each.CancelAfter(TimeSpan.FromSeconds(5));
                            await socket.ConnectAsync(new System.Net.IPEndPoint(ip, ctx.DnsEndPoint.Port), each.Token);
                            return new System.Net.Sockets.NetworkStream(socket, ownsSocket: true);
                        }
                        catch (Exception e) { last = e; socket.Dispose(); }
                    }
                    throw last ?? new System.Net.Http.HttpRequestException("no address");
                },
            };
            var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Ovira/" + App.Version + " (+https://github.com/H1rka-afk/notch-island-releases)");
            return http;
        }

        private static void Log(string what, Exception e)
        {
            try
            {
                var file = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(CacheFile)!, "weather.log");
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(file)!);
                var lines = System.IO.File.Exists(file) ? System.IO.File.ReadAllLines(file).TakeLast(40).ToList() : new List<string>();
                lines.Add(DateTime.Now.ToString("s") + " " + what + ": " + e.GetType().Name + " — " + e.Message);
                System.IO.File.WriteAllLines(file, lines);
            }
            catch { }
        }

        private static readonly System.Globalization.CultureInfo Inv = System.Globalization.CultureInfo.InvariantCulture;
        private static readonly System.Globalization.CultureInfo Ru = new("ru-RU");

        private static async Task<(double Lat, double Lon, string Name)?> Geocode(string city)
        {
            try
            {
                var geo = JsonDocument.Parse(await Http.GetStringAsync(
                    "https://geocoding-api.open-meteo.com/v1/search?count=1&language=ru&name=" + Uri.EscapeDataString(city)));
                if (!geo.RootElement.TryGetProperty("results", out var results) || results.GetArrayLength() == 0) return null;
                var place = results[0];
                return (place.GetProperty("latitude").GetDouble(), place.GetProperty("longitude").GetDouble(),
                        place.TryGetProperty("name", out var n) ? n.GetString() ?? city : city);
            }
            catch (Exception e)
            {
                Log("geocoding open-meteo", e);
                // OpenStreetMap's search as a second way to find the city
                var osm = JsonDocument.Parse(await Http.GetStringAsync(
                    "https://nominatim.openstreetmap.org/search?format=json&limit=1&accept-language=ru&q=" + Uri.EscapeDataString(city)));
                if (osm.RootElement.GetArrayLength() == 0) return null;
                var place = osm.RootElement[0];
                var name = place.TryGetProperty("name", out var n) ? n.GetString() ?? city : city;
                return (double.Parse(place.GetProperty("lat").GetString()!, Inv), double.Parse(place.GetProperty("lon").GetString()!, Inv), name);
            }
        }

        private static async Task LoadWeather(string city)
        {
            try
            {
                double lat, lon;
                string name;
                if (_place is { } p && string.Equals(p.Query, city, StringComparison.OrdinalIgnoreCase)) { lat = p.Lat; lon = p.Lon; name = Weather?.City ?? city; }
                else
                {
                    var found = await Geocode(city);
                    if (found == null) { Weather = null; WeatherNote = "Город не найден"; _fails = 0; return; }
                    (lat, lon, name) = found.Value;
                    _place = (city, lat, lon);
                }
                WeatherNow now;
                try { now = await OpenMeteo(lat, lon, name); }
                catch (Exception e)
                {
                    Log("forecast open-meteo", e);
                    now = await MetNo(lat, lon, name);
                }
                Weather = now;
                WeatherNote = "";
                _fails = 0;
                _okAt = DateTime.Now;
                try
                {
                    System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(CacheFile)!);
                    System.IO.File.WriteAllText(CacheFile, JsonSerializer.Serialize(new Cached(city, now, lat, lon)));
                }
                catch { }
            }
            catch (Exception e)
            {
                Log("weather", e);
                _fails++;
                // keep showing the last forecast; only an empty card says so
                if (Weather == null) WeatherNote = _fails < 3 ? "Загружаю…" : "Нет связи";
            }
            finally { _weatherBusy = false; }
        }

        private static async Task<WeatherNow> OpenMeteo(double lat, double lon, string name)
        {
            var doc = JsonDocument.Parse(await Http.GetStringAsync(
                "https://api.open-meteo.com/v1/forecast?latitude=" + lat.ToString(Inv) + "&longitude=" + lon.ToString(Inv) +
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
                var t = DateTime.Parse(times[i].GetString()!, Inv);
                if (t <= localNow) continue;
                bool hDay = hourly.GetProperty("is_day")[i].GetInt32() == 1;
                hours.Add(new Hour(t.Hour.ToString(), Describe(hourly.GetProperty("weather_code")[i].GetInt32(), hDay).Kind,
                                   (int)Math.Round(hourly.GetProperty("temperature_2m")[i].GetDouble())));
            }
            var daily = root.GetProperty("daily");
            var days = new List<Day>();
            int min = 0, max = 0;
            for (int i = 0; i < daily.GetProperty("time").GetArrayLength(); i++)
            {
                var date = DateTime.Parse(daily.GetProperty("time")[i].GetString()!, Inv);
                int dMax = (int)Math.Round(daily.GetProperty("temperature_2m_max")[i].GetDouble());
                int dMin = (int)Math.Round(daily.GetProperty("temperature_2m_min")[i].GetDouble());
                if (i == 0) { min = dMin; max = dMax; }
                days.Add(new Day(DayName(date, i), Describe(daily.GetProperty("weather_code")[i].GetInt32(), true).Kind, dMax, dMin));
            }
            var (text, kind) = Describe(code, day);
            return new WeatherNow(name, (int)Math.Round(current.GetProperty("temperature_2m").GetDouble()), text, kind, min, max, hours, days, DateTime.Now);
        }

        private static string DayName(DateTime date, int index) =>
            index == 0 ? "Сегодня" : Ru.TextInfo.ToTitleCase(Ru.DateTimeFormat.GetAbbreviatedDayName(date.DayOfWeek));

        // The Norwegian Met Institute (the forecast behind yr.no).
        private static async Task<WeatherNow> MetNo(double lat, double lon, string name)
        {
            var doc = JsonDocument.Parse(await Http.GetStringAsync(
                "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=" + Math.Round(lat, 4).ToString(Inv) + "&lon=" + Math.Round(lon, 4).ToString(Inv)));
            var series = doc.RootElement.GetProperty("properties").GetProperty("timeseries");
            var points = new List<(DateTime At, double Temp, string Symbol)>();
            foreach (var item in series.EnumerateArray())
            {
                var at = DateTime.Parse(item.GetProperty("time").GetString()!, Inv, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal).ToLocalTime();
                var data = item.GetProperty("data");
                double temp = data.GetProperty("instant").GetProperty("details").GetProperty("air_temperature").GetDouble();
                string symbol = "";
                foreach (var key in new[] { "next_1_hours", "next_6_hours", "next_12_hours" })
                    if (data.TryGetProperty(key, out var next) && next.TryGetProperty("summary", out var sum) && sum.TryGetProperty("symbol_code", out var sc)) { symbol = sc.GetString() ?? ""; break; }
                points.Add((at, temp, symbol));
            }
            if (points.Count == 0) throw new InvalidOperationException("empty forecast");
            var nowPoint = points.Where(x => x.At <= DateTime.Now.AddMinutes(30)).DefaultIfEmpty(points[0]).Last();
            var hours = points.Where(x => x.At > DateTime.Now).Take(6)
                              .Select(x => new Hour(x.At.Hour.ToString(), FromSymbol(x.Symbol).Kind, (int)Math.Round(x.Temp))).ToList();
            var days = points.GroupBy(x => x.At.Date).Take(6).Select((g, i) =>
            {
                var noon = g.OrderBy(x => Math.Abs((x.At.TimeOfDay - TimeSpan.FromHours(13)).TotalHours)).First();
                var sym = FromSymbol(noon.Symbol.Replace("_night", "_day")).Kind;
                return new Day(DayName(g.Key, i), sym, (int)Math.Round(g.Max(x => x.Temp)), (int)Math.Round(g.Min(x => x.Temp)));
            }).ToList();
            var (text, kind) = FromSymbol(nowPoint.Symbol);
            var today = days.FirstOrDefault();
            return new WeatherNow(name, (int)Math.Round(nowPoint.Temp), text, kind, today?.Min ?? 0, today?.Max ?? 0, hours, days, DateTime.Now);
        }

        private static (string Text, string Kind) FromSymbol(string symbol)
        {
            bool night = symbol.EndsWith("_night") || symbol.EndsWith("_polartwilight");
            string sky = night ? "moon" : "sun";
            var s = symbol.Split('_')[0];
            if (s.Contains("thunder")) return ("Гроза", "cloud.bolt");
            if (s.Contains("sleet")) return ("Мокрый снег", "cloud.sleet");
            if (s.Contains("snow")) return (s.StartsWith("heavy") ? "Сильный снег" : s.StartsWith("light") ? "Небольшой снег" : "Снег", "cloud.snow");
            if (s.Contains("rainshowers")) return ("Ливни", s.StartsWith("heavy") ? "cloud.heavyrain" : "cloud." + sky + ".rain");
            if (s.Contains("rain")) return s.StartsWith("heavy") ? ("Сильный дождь", "cloud.heavyrain") : s.StartsWith("light") ? ("Небольшой дождь", "cloud." + sky + ".rain") : ("Дождь", "cloud.rain");
            return s switch
            {
                "clearsky" => ("Ясно", sky),
                "fair" => ("Преимущественно ясно", "cloud." + sky),
                "partlycloudy" => ("Переменная облачность", "cloud." + sky),
                "fog" => ("Туман", "fog"),
                _ => ("Облачно", "cloud"),
            };
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
