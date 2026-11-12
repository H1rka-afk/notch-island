using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Threading;
using Microsoft.Win32;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.5.1 — statistics for the day, as on the Mac (DayStats.swift,
    // DayStatsStore.swift): one record per calendar day, the last 7 days.
    // Counted every 30 s: time at the computer (keyboard or mouse within the
    // last minute, screen not locked) and time with music playing. Songs,
    // eye breaks, timers, unlocks and calls are recorded as they happen.
    // Kept in %APPDATA%\Ovira\stats.json and never sent anywhere.
    public sealed class DayStats
    {
        public string Day { get; set; } = "";
        public double ActiveSeconds { get; set; }
        public double MusicSeconds { get; set; }
        public int Tracks { get; set; }
        public int EyeBreaks { get; set; }
        public int EyeSkipped { get; set; }
        public int Timers { get; set; }
        public int Unlocks { get; set; }
        public int Calls { get; set; }
        public double CallSeconds { get; set; }
    }

    public enum StatEvent { Track, EyeBreak, EyeSkipped, Timer, Unlock, Call }

    public sealed class StatsService
    {
        public const int KeepDays = 7;
        private const double MaxTick = 120, WorkingIdleLimit = 60;

        private static string FilePath => Path.Combine(Settings.Folder, "stats.json");

        private List<DayStats> _history = new();
        private readonly DispatcherTimer _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        private DateTime _lastTick = DateTime.Now, _lastSave = DateTime.MinValue;
        private bool _locked, _dirty;
        private string? _lastCountedTrack;

        public Func<bool>? IsPlaying;
        public Func<string?>? CurrentTrack;
        public Func<bool>? InCall;
        public event Action? Changed;

        public static string DayKey(DateTime date) => date.ToString("yyyy-MM-dd");

        public DayStats Today
        {
            get
            {
                var key = DayKey(DateTime.Now);
                return _history.LastOrDefault(d => d.Day == key) ?? new DayStats { Day = key };
            }
        }

        // Seven days, oldest first, empty days filled in.
        public List<DayStats> Week
        {
            get
            {
                var list = new List<DayStats>();
                for (int back = KeepDays - 1; back >= 0; back--)
                {
                    var key = DayKey(DateTime.Now.AddDays(-back));
                    list.Add(_history.FirstOrDefault(d => d.Day == key) ?? new DayStats { Day = key });
                }
                return list;
            }
        }

        public void Start()
        {
            try
            {
                if (File.Exists(FilePath))
                    _history = JsonSerializer.Deserialize<List<DayStats>>(File.ReadAllText(FilePath)) ?? new();
            }
            catch { _history = new(); }
            Roll();
            _timer.Tick += (_, _) => Tick();
            _timer.Start();
            try
            {
                SystemEvents.SessionSwitch += (_, e) =>
                {
                    if (e.Reason == SessionSwitchReason.SessionLock) _locked = true;
                    else if (e.Reason == SessionSwitchReason.SessionUnlock) { _locked = false; Record(StatEvent.Unlock); }
                };
            }
            catch { }
        }

        public void Stop()
        {
            Tick();
            _timer.Stop();
            Save(force: true);
        }

        private DayStats Roll()
        {
            var key = DayKey(DateTime.Now);
            _history = _history.Where(d => !string.IsNullOrEmpty(d.Day)).OrderBy(d => d.Day).ToList();
            if (_history.Count == 0 || _history[^1].Day != key) _history.Add(new DayStats { Day = key });
            if (_history.Count > KeepDays) _history = _history.Skip(_history.Count - KeepDays).ToList();
            return _history[^1];
        }

        private void Tick()
        {
            var now = DateTime.Now;
            double elapsed = Math.Min(Math.Max(0, (now - _lastTick).TotalSeconds), MaxTick);
            _lastTick = now;
            if (!Settings.Current.StatsEnabled) return;
            var today = Roll();
            if (!_locked && IdleSeconds() < WorkingIdleLimit) today.ActiveSeconds += elapsed;
            if (IsPlaying?.Invoke() == true)
            {
                today.MusicSeconds += elapsed;
                // A song counts once it has really been heard (a tick with it playing).
                var track = CurrentTrack?.Invoke();
                if (!string.IsNullOrEmpty(track) && track != _lastCountedTrack) { _lastCountedTrack = track; today.Tracks++; }
            }
            if (InCall?.Invoke() == true) today.CallSeconds += elapsed;
            _dirty = true;
            Save(force: false);
            Changed?.Invoke();
        }

        public void Record(StatEvent e)
        {
            if (!Settings.Current.StatsEnabled) return;
            var today = Roll();
            switch (e)
            {
                case StatEvent.Track: today.Tracks++; break;
                case StatEvent.EyeBreak: today.EyeBreaks++; break;
                case StatEvent.EyeSkipped: today.EyeSkipped++; break;
                case StatEvent.Timer: today.Timers++; break;
                case StatEvent.Unlock: today.Unlocks++; break;
                case StatEvent.Call: today.Calls++; break;
            }
            _dirty = true;
            Save(force: false);
            Changed?.Invoke();
        }

        public void Reset()
        {
            _history = new();
            Roll();
            _dirty = true;
            Save(force: true);
            Changed?.Invoke();
        }

        private void Save(bool force)
        {
            if (!_dirty) return;
            if (!force && (DateTime.Now - _lastSave).TotalSeconds < 120) return;
            try
            {
                Directory.CreateDirectory(Settings.Folder);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(_history));
                _dirty = false;
                _lastSave = DateTime.Now;
            }
            catch { }
        }

        // «3 ч 25 мин», «45 мин», «меньше минуты».
        public static string Duration(double seconds)
        {
            int minutes = (int)(seconds / 60);
            if (minutes < 1) return "меньше минуты";
            int h = minutes / 60, m = minutes % 60;
            if (h == 0) return m + " мин";
            return m == 0 ? h + " ч" : h + " ч " + m + " мин";
        }

        public static string Weekday(string dayKey)
        {
            if (!DateTime.TryParse(dayKey, out var d)) return "";
            return new[] { "вс", "пн", "вт", "ср", "чт", "пт", "сб" }[(int)d.DayOfWeek];
        }

        public static string Plural(int n, string one, string few, string many)
        {
            int m10 = n % 10, m100 = n % 100;
            if (m10 == 1 && m100 != 11) return one;
            if (m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14)) return few;
            return many;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LastInputInfo { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LastInputInfo info);

        private static double IdleSeconds()
        {
            var info = new LastInputInfo { cbSize = (uint)Marshal.SizeOf<LastInputInfo>() };
            if (!GetLastInputInfo(ref info)) return 0;
            return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
        }
    }
}
