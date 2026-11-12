using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using Microsoft.Win32;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.5.1 — Steam downloads in the island, with the figures of Steam's own
    // download page: time since the start, time left, the speed now and the
    // peak, and how fast the disk is written.
    //
    // Steam has no interface for this, so Ovira reads what Steam leaves in
    // plain sight (nothing is changed, Steam is not touched):
    //  · which game is updating — Steam's own note in the registry
    //    (HKCU\Software\Valve\Steam\Apps\<id>\Updating);
    //  · its name and how many bytes are done — the game's appmanifest file
    //    in the library;
    //  · the download speed — how fast this computer receives data from the
    //    network (all of it: with a video playing at the same time the figure
    //    is a little higher than Steam's);
    //  · the disk — how fast Steam's process writes.
    public sealed class SteamService
    {
        public sealed record Download(string Name, double Progress, bool Installing, bool Paused, TimeSpan Elapsed, TimeSpan? Left,
                                      double Speed, double Peak, double Disk, long Done, long Total);

        private readonly DispatcherTimer _poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        public Download? Current { get; private set; }
        public event Action? Changed;
        public event Action<string>? Finished;

        private string _appId = "";
        private DateTime _started, _lastTick, _lastProgressAt;
        private long _lastNet, _lastWrite, _lastDone;
        private double _speed, _peak, _disk, _average;
        private bool _dismissed;
        private int _idlePolls;

        public void Start()
        {
            _poll.Tick += (_, _) => Poll();
            _poll.Start();
        }

        // «Скрыть» in the island: this download is no longer shown.
        public void Dismiss()
        {
            _dismissed = true;
            Current = null;
            Changed?.Invoke();
        }

        private void Poll()
        {
            if (!Settings.Current.SteamActivity) { Clear(); return; }
            // Steam closed → look rarely.
            var steam = Process.GetProcessesByName("steam");
            try
            {
                if (steam.Length == 0)
                {
                    Clear();
                    _poll.Interval = TimeSpan.FromSeconds(8);
                    return;
                }
                var found = FindUpdating();
                if (found == null)
                {
                    if (Current != null && !string.IsNullOrEmpty(_appId))
                    {
                        var name = Current.Name;
                        bool wasDone = Current.Progress > 0.98 || Current.Installing;
                        Clear();
                        if (wasDone) Finished?.Invoke(name);
                    }
                    _dismissed = false;
                    _appId = "";
                    _poll.Interval = TimeSpan.FromSeconds(_idlePolls++ > 10 ? 5 : 2);
                    return;
                }
                _idlePolls = 0;
                _poll.Interval = TimeSpan.FromSeconds(1);
                var (id, manifest) = found.Value;
                var now = DateTime.Now;
                long net = NetworkBytes();
                long write = WriteBytes(steam[0]);
                long total = manifest.ToDownload, done = Math.Min(manifest.Downloaded, total);
                if (id != _appId)
                {
                    _appId = id;
                    _started = now;
                    _lastTick = now;
                    _lastNet = net; _lastWrite = write; _lastDone = done; _lastProgressAt = now;
                    _speed = _peak = _disk = _average = 0;
                    _dismissed = false;
                }
                double dt = (now - _lastTick).TotalSeconds;
                if (dt >= 0.5)
                {
                    double rawSpeed = Math.Max(0, net - _lastNet) / dt, rawDisk = Math.Max(0, write - _lastWrite) / dt;
                    _speed += (rawSpeed - _speed) * 0.5;
                    _disk += (rawDisk - _disk) * 0.5;
                    _average = _average <= 0 ? _speed : _average + (_speed - _average) * 0.08;   // calmer, for «осталось»
                    _lastTick = now; _lastNet = net; _lastWrite = write;
                }
                if (done != _lastDone) { _lastDone = done; _lastProgressAt = now; }
                bool installing = total > 0 && done >= total;
                bool downloading = !installing && _speed > 30_000;
                if (downloading) _peak = Math.Max(_peak, _speed);
                bool paused = !installing && _speed < 30_000 && (now - _lastProgressAt).TotalSeconds > 12;
                TimeSpan? left = null;
                if (!installing && !paused && total > done && _average > 50_000)
                    left = TimeSpan.FromSeconds(Math.Min(99 * 3600, (total - done) / _average));
                double progress = total > 0 ? (double)done / total
                                : manifest.ToStage > 0 ? (double)manifest.Staged / manifest.ToStage : 0;
                if (installing && manifest.ToStage > 0) progress = Math.Clamp((double)manifest.Staged / manifest.ToStage, 0, 1);
                if (_dismissed) return;
                Current = new Download(manifest.Name, progress, installing, paused, now - _started, left,
                                       installing || paused ? 0 : _speed, _peak, _disk, done, total);
                Changed?.Invoke();
            }
            catch { }
            finally { foreach (var p in steam) p.Dispose(); }
        }

        private void Clear()
        {
            if (Current == null) return;
            Current = null;
            Changed?.Invoke();
        }

        // ---- Steam's files ----

        private sealed record Manifest(string Name, long ToDownload, long Downloaded, long ToStage, long Staged);

        private static (string Id, Manifest Manifest)? FindUpdating()
        {
            using var apps = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam\Apps");
            if (apps == null) return null;
            var updating = new List<string>();
            foreach (var id in apps.GetSubKeyNames())
            {
                using var app = apps.OpenSubKey(id);
                if (app?.GetValue("Updating") is int u && u == 1) updating.Add(id);
            }
            if (updating.Count == 0) return null;
            var libraries = Libraries();
            (string, Manifest)? fallback = null;
            foreach (var id in updating)
            {
                foreach (var lib in libraries)
                {
                    var file = Path.Combine(lib, "steamapps", "appmanifest_" + id + ".acf");
                    if (!File.Exists(file)) continue;
                    var m = Read(file);
                    if (m == null) continue;
                    if (m.ToDownload > 0 && m.Downloaded < m.ToDownload) return (id, m);   // the one really downloading
                    fallback ??= (id, m);
                }
            }
            return fallback;
        }

        private static Manifest? Read(string file)
        {
            try
            {
                string text;
                using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream))
                    text = reader.ReadToEnd();
                string Value(string key)
                {
                    var m = Regex.Match(text, "\"" + key + "\"\\s+\"([^\"]*)\"", RegexOptions.IgnoreCase);
                    return m.Success ? m.Groups[1].Value : "";
                }
                long Number(string key) => long.TryParse(Value(key), out var n) ? n : 0;
                var name = Value("name");
                return new Manifest(name.Length > 0 ? name : "Steam", Number("BytesToDownload"), Number("BytesDownloaded"),
                                    Number("BytesToStage"), Number("BytesStaged"));
            }
            catch { return null; }
        }

        private static List<string> _libraries = new();
        private static DateTime _librariesAt;

        private static List<string> Libraries()
        {
            if ((DateTime.Now - _librariesAt).TotalSeconds < 60 && _libraries.Count > 0) return _libraries;
            var list = new List<string>();
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
                var root = (key?.GetValue("SteamPath") as string ?? "").Replace('/', '\\');
                if (root.Length > 0)
                {
                    list.Add(root);
                    var vdf = Path.Combine(root, "steamapps", "libraryfolders.vdf");
                    if (File.Exists(vdf))
                        foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                        {
                            var path = m.Groups[1].Value.Replace("\\\\", "\\");
                            if (!list.Contains(path, StringComparer.OrdinalIgnoreCase)) list.Add(path);
                        }
                }
            }
            catch { }
            _libraries = list;
            _librariesAt = DateTime.Now;
            return list;
        }

        // ---- the meters ----

        private static long NetworkBytes()
        {
            long sum = 0;
            try
            {
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                    sum += nic.GetIPStatistics().BytesReceived;
                }
            }
            catch { }
            return sum;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }

        [DllImport("kernel32.dll")] private static extern bool GetProcessIoCounters(IntPtr process, out IoCounters counters);

        private static long WriteBytes(Process steam)
        {
            try { return GetProcessIoCounters(steam.Handle, out var c) ? (long)c.WriteBytes : 0; }
            catch { return 0; }
        }

        // «45,2 МБ/с», «830 КБ/с»; «12,4 ГБ».
        public static string Rate(double bytesPerSecond)
        {
            if (bytesPerSecond < 1000) return "0 КБ/с";
            if (bytesPerSecond < 1_000_000) return (bytesPerSecond / 1000).ToString("0") + " КБ/с";
            return (bytesPerSecond / 1_000_000).ToString("0.0", System.Globalization.CultureInfo.GetCultureInfo("ru-RU")) + " МБ/с";
        }

        public static string Size(long bytes)
        {
            var ru = System.Globalization.CultureInfo.GetCultureInfo("ru-RU");
            if (bytes >= 1_000_000_000) return (bytes / 1e9).ToString("0.0", ru) + " ГБ";
            return (bytes / 1e6).ToString("0", ru) + " МБ";
        }
    }
}
