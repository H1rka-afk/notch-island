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

        public sealed record Day(string Name, string Symbol, int Max, int Min);
        public sealed record WeatherNow(string City, int Temp, string Text, string Symbol, List<Day> Days);

        public static WeatherNow? Weather { get; private set; }
        public static string WeatherNote { get; private set; } = "Загружаю…";
        private static DateTime _weatherAt;
        private static string _weatherCity = "";
        private static bool _weatherBusy;

        public static void NeedWeather()
        {
            var city = (Settings.Current.WeatherCity ?? "").Trim();
            if (city.Length == 0) { Weather = null; WeatherNote = "Укажи город в настройках виджетов"; return; }
            if (_weatherBusy) return;
            if (city == _weatherCity && (DateTime.Now - _weatherAt).TotalMinutes < 30) return;
            _weatherBusy = true;
            _weatherCity = city;
            _weatherAt = DateTime.Now;
            _ = LoadWeather(city);
        }

        private static async Task LoadWeather(string city)
        {
            try
            {
                var geo = JsonDocument.Parse(await Http.GetStringAsync(
                    "https://geocoding-api.open-meteo.com/v1/search?count=1&language=ru&name=" + Uri.EscapeDataString(city)));
                if (!geo.RootElement.TryGetProperty("results", out var results) || results.GetArrayLength() == 0)
                {
                    Weather = null; WeatherNote = "Город не найден"; return;
                }
                var place = results[0];
                var inv = System.Globalization.CultureInfo.InvariantCulture;
                var lat = place.GetProperty("latitude").GetDouble().ToString(inv);
                var lon = place.GetProperty("longitude").GetDouble().ToString(inv);
                var name = place.TryGetProperty("name", out var n) ? n.GetString() ?? city : city;
                var doc = JsonDocument.Parse(await Http.GetStringAsync(
                    "https://api.open-meteo.com/v1/forecast?latitude=" + lat + "&longitude=" + lon +
                    "&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=4"));
                var root = doc.RootElement;
                var current = root.GetProperty("current");
                int code = current.GetProperty("weather_code").GetInt32();
                var daily = root.GetProperty("daily");
                var days = new List<Day>();
                var ru = new System.Globalization.CultureInfo("ru-RU");
                for (int i = 1; i < daily.GetProperty("time").GetArrayLength() && days.Count < 3; i++)
                {
                    var date = DateTime.Parse(daily.GetProperty("time")[i].GetString()!, inv);
                    days.Add(new Day(ru.DateTimeFormat.GetAbbreviatedDayName(date.DayOfWeek), Describe(daily.GetProperty("weather_code")[i].GetInt32()).Symbol,
                                     (int)Math.Round(daily.GetProperty("temperature_2m_max")[i].GetDouble()),
                                     (int)Math.Round(daily.GetProperty("temperature_2m_min")[i].GetDouble())));
                }
                var (text, symbol) = Describe(code);
                Weather = new WeatherNow(name, (int)Math.Round(current.GetProperty("temperature_2m").GetDouble()), text, symbol, days);
                WeatherNote = "";
            }
            catch
            {
                if (Weather == null) WeatherNote = "Нет связи";
                _weatherAt = DateTime.Now.AddMinutes(-25);     // try again in 5 minutes
            }
            finally { _weatherBusy = false; }
        }

        // WMO weather codes.
        private static (string Text, string Symbol) Describe(int code) => code switch
        {
            0 => ("Ясно", "☀"),
            1 or 2 => ("Малооблачно", "⛅"),
            3 => ("Пасмурно", "☁"),
            45 or 48 => ("Туман", "🌫"),
            >= 51 and <= 57 => ("Морось", "🌦"),
            >= 61 and <= 67 => ("Дождь", "🌧"),
            >= 71 and <= 77 => ("Снег", "❄"),
            >= 80 and <= 82 => ("Ливень", "🌧"),
            85 or 86 => ("Снегопад", "❄"),
            >= 95 => ("Гроза", "⛈"),
            _ => ("Облачно", "☁")
        };

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
