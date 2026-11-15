using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;

namespace Ovira.Services
{
    // 0.5.0 — a call in the island, as on the iPhone: a green handset and the
    // call's time. Ovira notices a call by the microphone being in use (the
    // same list Windows keeps for its privacy indicator) by Discord or VK
    // Messenger — the apps, or a browser tab with Discord or VK. Open the
    // island to switch the microphone off (the Windows microphone itself, so
    // nothing can hear you, whatever the app) or to hang up: Ovira presses
    // the app's own «Отключиться» / «Завершить звонок» button through
    // Windows accessibility. Nothing about the call itself is read.
    public sealed class CallService
    {
        public sealed record Call(string App, DateTime Since, string Process);

        private readonly DispatcherTimer _poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        public Call? Current { get; private set; }
        public event Action? Changed;

        public void Start()
        {
            _poll.Tick += (_, _) => Poll();
            _poll.Start();
        }

        // 0.6.2: «Показать» in Settings — a pretend call for 12 seconds.
        private DateTime _demoUntil;
        public void StartDemo()
        {
            _demoUntil = DateTime.Now.AddSeconds(12);
            Current = new Call("Discord · показ", DateTime.Now.AddSeconds(-75), "demo");
            Changed?.Invoke();
        }

        private bool _busy;

        // 0.7.9: the look-up runs off the UI thread (it asks the audio system)
        private async void Poll()
        {
            if (DateTime.Now < _demoUntil || _busy) return;
            if (!Ovira.Core.Settings.Current.CallActivity) { Apply(null); return; }
            _busy = true;
            Call? found = null;
            try { found = await Task.Run(Detect); } catch { }
            finally { _busy = false; }
            if (DateTime.Now < _demoUntil) return;
            Apply(found);
        }

        private int _misses;

        private void Apply(Call? found)
        {
            // a short gap in the microphone (a muted moment) doesn't end the call
            if (found == null && Current != null && Current.Process != "demo" && ++_misses < 3) return;
            _misses = 0;
            bool changed = (found == null) != (Current == null) || (found != null && Current != null && found.App != Current.App);
            if (found != null && Current != null && found.App == Current.App) found = Current;   // keep the start time
            Current = found;
            if (changed) Changed?.Invoke();
        }

        // ---- who uses the microphone ----

        private static Call? Detect()
        {
            // 0.7.9: first ask the sound system which programs are recording
            // from a microphone right now — more reliable than the privacy
            // list, which some Windows builds fill late or not at all.
            try
            {
                var fromAudio = DetectFromAudio();
                if (fromAudio != null) return fromAudio;
            }
            catch { }
            try
            {
                using var root = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone");
                if (root == null) return null;
                var users = new List<(string Key, DateTime Since)>();
                Collect(root, users);
                using (var np = root.OpenSubKey("NonPackaged")) if (np != null) Collect(np, users);
                foreach (var (key, since) in users.OrderBy(u => u.Since))
                {
                    var exe = key.Replace('#', '\\');
                    var name = System.IO.Path.GetFileNameWithoutExtension(exe).ToLowerInvariant();
                    var app = AppFor(name, key.ToLowerInvariant());
                    if (app != null) return new Call(app, since, name);
                    if (IsBrowser(name))
                    {
                        var tab = BrowserCallTab(name);
                        if (tab != null) return new Call(tab, since, name);
                    }
                }
            }
            catch { }
            return null;
        }

        private static Call? DetectFromAudio()
        {
            using var en = new MMDeviceEnumerator();
            var seen = new HashSet<uint>();
            foreach (var device in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                try
                {
                    var manager = device.AudioSessionManager;
                    manager.RefreshSessions();
                    var sessions = manager.Sessions;
                    for (int i = 0; i < sessions.Count; i++)
                    {
                        var session = sessions[i];
                        if (session.State != NAudio.CoreAudioApi.Interfaces.AudioSessionState.AudioSessionStateActive) continue;
                        uint pid = session.GetProcessID;
                        if (pid == 0 || !seen.Add(pid)) continue;
                        string name;
                        try { using var proc = Process.GetProcessById((int)pid); name = proc.ProcessName.ToLowerInvariant(); }
                        catch { continue; }
                        var app = AppFor(name, name);
                        if (app != null) return new Call(app, DateTime.Now, name);
                        if (IsBrowser(name))
                        {
                            var tab = BrowserCallTab(name);
                            if (tab != null) return new Call(tab, DateTime.Now, name);
                        }
                    }
                }
                catch { }
                finally { device.Dispose(); }
            }
            return null;
        }

        private static void Collect(RegistryKey key, List<(string, DateTime)> into)
        {
            foreach (var name in key.GetSubKeyNames())
            {
                if (name == "NonPackaged") continue;
                using var app = key.OpenSubKey(name);
                if (app?.GetValue("LastUsedTimeStart") is long start && start > 0 && app.GetValue("LastUsedTimeStop") is long stop && stop == 0)
                {
                    DateTime since;
                    try { since = DateTime.FromFileTime(start); } catch { since = DateTime.Now; }
                    into.Add((name, since));
                }
            }
        }

        private static string? AppFor(string exe, string key)
        {
            if (exe.StartsWith("discord")) return "Discord";
            // 0.7.9: more messengers
            if (exe.StartsWith("telegram") || key.Contains("telegramdesktop")) return "Telegram";
            if (exe.StartsWith("whatsapp") || key.Contains("whatsappdesktop")) return "WhatsApp";
            if (exe is "zoom" or "zoom.us" || key.Contains("#zoom#")) return "Zoom";
            if (exe is "ms-teams" or "teams" || key.Contains("msteams")) return "Teams";
            if (exe.StartsWith("skype") || key.Contains("skype")) return "Skype";
            if (exe.StartsWith("viber")) return "Viber";
            if (exe == "slack") return "Slack";
            if (exe.Contains("telemost") || key.Contains("telemost")) return "Телемост";
            if ((exe.Contains("vk") && (exe.Contains("messenger") || exe.Contains("call") || exe.Contains("мессенджер"))) ||
                key.Contains("vk messenger") || key.Contains("vkmessenger") || key.Contains("vk.messenger") || key.Contains("vkcalls"))
                return "VK Мессенджер";
            return null;
        }

        private static bool IsBrowser(string exe) => exe is "chrome" or "msedge" or "browser" or "opera" or "firefox" or "brave" or "vivaldi" or "yandex";

        private static string? BrowserCallTab(string exe)
        {
            string? result = null;
            foreach (var (hwnd, title, proc) in TopWindows())
            {
                if (proc != exe) continue;
                var t = title.ToLowerInvariant();
                if (t.Contains("discord")) { result = "Discord"; break; }
                if (t.Contains("google meet") || t.StartsWith("meet -") || t.Contains("meet.google")) { result = "Google Meet"; break; }
                if (t.Contains("zoom")) { result = "Zoom"; break; }
                if (t.Contains("telegram")) { result = "Telegram"; break; }
                if (t.Contains("whatsapp")) { result = "WhatsApp"; break; }
                if (t.Contains("телемост")) { result = "Телемост"; break; }
                if (t.Contains("microsoft teams")) { result = "Teams"; break; }
                if (t.Contains("вконтакте") || t.Contains("vk звонки") || t.Contains("vk мессенджер") || t.Contains("vk messenger") || t.Contains(" | vk") || t.EndsWith(" vk"))
                { result = "VK"; break; }
            }
            return result;
        }

        // ---- the microphone (Windows' own, for every app) ----

        public bool MicMuted
        {
            get
            {
                try
                {
                    using var e = new MMDeviceEnumerator();
                    return e.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).AudioEndpointVolume.Mute;
                }
                catch { return false; }
            }
        }

        public void ToggleMic()
        {
            try
            {
                using var e = new MMDeviceEnumerator();
                var mic = e.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
                mic.AudioEndpointVolume.Mute = !mic.AudioEndpointVolume.Mute;
            }
            catch { }
            Changed?.Invoke();
        }

        // ---- hang up: the app's own button ----

        private static readonly string[] HangUpWords =
        {
            "отключиться", "disconnect", "покинуть звонок", "leave call", "завершить звонок", "end call",
            "положить трубку", "выйти из звонка", "покинуть", "hang up", "завершить"
        };

        // 0.8.7: sturdier. Discord, Telegram and browsers are Chromium inside:
        // they build the list of their buttons for others only after being
        // asked (and only for the page itself, a child window) — so Ovira
        // asks both and waits a little longer, tries hidden and minimised
        // windows of the app too, and presses through the app's own
        // accessibility if the button has no ordinary «press».
        public Task<bool> HangUpAsync() => Task.Run(() =>
        {
            var call = Current;
            if (call == null) return false;
            if (call.Process == "demo") { _demoUntil = DateTime.MinValue; return true; }
            var windows = Windows(call).ToList();
            int[] waits = { 0, 700, 1500 };
            foreach (var wait in waits)
            {
                if (wait > 0)
                {
                    foreach (var hwnd in windows) Wake(hwnd);
                    Thread.Sleep(wait);
                }
                foreach (var hwnd in windows)
                {
                    var button = FindHangUp(hwnd);
                    if (button == null) continue;
                    if (Press(button)) return true;
                }
            }
            return false;
        });

        private static bool Press(AutomationElement button)
        {
            try
            {
                if (button.TryGetCurrentPattern(InvokePattern.Pattern, out var p)) { ((InvokePattern)p).Invoke(); return true; }
                if (button.TryGetCurrentPattern(TogglePattern.Pattern, out var t)) { ((TogglePattern)t).Toggle(); return true; }
                if (button.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var si)) { ((SelectionItemPattern)si).Select(); return true; }
            }
            catch { }
            return false;
        }

        private static AutomationElement? FindHangUp(IntPtr hwnd)
        {
            try
            {
                var root = AutomationElement.FromHandle(hwnd);
                var buttons = root.FindAll(TreeScope.Descendants, new OrCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Hyperlink),
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem)));
                AutomationElement? best = null;
                int bestScore = 0;
                foreach (AutomationElement b in buttons)
                {
                    string label;
                    try { label = (b.Current.Name + " " + b.Current.HelpText).ToLowerInvariant().Trim(); } catch { continue; }
                    if (label.Length == 0 || label.Length > 60) continue;
                    for (int i = 0; i < HangUpWords.Length; i++)
                    {
                        if (!label.Contains(HangUpWords[i])) continue;
                        int score = HangUpWords.Length - i + (label == HangUpWords[i] ? 20 : 0);
                        if (score > bestScore) { bestScore = score; best = b; }
                    }
                }
                return best;
            }
            catch { return null; }
        }

        // ---- windows ----

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr param);
        private delegate bool EnumProc(IntPtr hwnd, IntPtr param);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object? obj);

        private static List<(IntPtr Hwnd, string Title, string Process)> TopWindows()
        {
            var names = new Dictionary<uint, string>();
            var list = new List<(IntPtr, string, string)>();
            EnumWindows((hwnd, _) =>
            {
                if (!IsWindowVisible(hwnd)) return true;
                GetWindowThreadProcessId(hwnd, out var pid);
                if (!names.TryGetValue(pid, out var name))
                {
                    try { using var p = Process.GetProcessById((int)pid); name = p.ProcessName.ToLowerInvariant(); } catch { name = ""; }
                    names[pid] = name;
                }
                var title = new StringBuilder(512);
                GetWindowText(hwnd, title, 512);
                if (title.Length > 0) list.Add((hwnd, title.ToString(), name));
                return true;
            }, IntPtr.Zero);
            return list;
        }

        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr param);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);

        private static readonly Dictionary<string, string[]> TabWords = new()
        {
            ["Discord"] = new[] { "discord" },
            ["VK"] = new[] { "вконтакте", "vk" },
            ["VK Мессенджер"] = new[] { "вконтакте", "vk" },
            ["Google Meet"] = new[] { "meet" },
            ["Zoom"] = new[] { "zoom" },
            ["Telegram"] = new[] { "telegram" },
            ["WhatsApp"] = new[] { "whatsapp" },
            ["Телемост"] = new[] { "телемост", "telemost" },
            ["Teams"] = new[] { "teams" },
        };

        // The app's windows — visible ones first, then hidden or minimised
        // ones (Discord keeps running in the tray).
        private static IEnumerable<IntPtr> Windows(Call call)
        {
            var visible = new List<IntPtr>();
            var hidden = new List<IntPtr>();
            var names = new Dictionary<uint, string>();
            EnumWindows((hwnd, _) =>
            {
                GetWindowThreadProcessId(hwnd, out var pid);
                if (!names.TryGetValue(pid, out var name))
                {
                    try { using var p = Process.GetProcessById((int)pid); name = p.ProcessName.ToLowerInvariant(); } catch { name = ""; }
                    names[pid] = name;
                }
                if (name != call.Process) return true;
                var title = new StringBuilder(512);
                GetWindowText(hwnd, title, 512);
                if (title.Length == 0) return true;
                if (IsBrowser(name))
                {
                    var t = title.ToString().ToLowerInvariant();
                    var words = TabWords.TryGetValue(call.App, out var w) ? w : new[] { call.App.ToLowerInvariant() };
                    if (!words.Any(t.Contains)) return true;
                }
                (IsWindowVisible(hwnd) ? visible : hidden).Add(hwnd);
                return true;
            }, IntPtr.Zero);
            return visible.Concat(hidden);
        }

        private static void Wake(IntPtr hwnd)
        {
            try
            {
                var iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
                AccessibleObjectFromWindow(hwnd, 0xFFFFFFFC, ref iid, out var obj);
                if (obj != null) Marshal.ReleaseComObject(obj);
                // the page itself lives in a child window — ask it too
                EnumChildWindows(hwnd, (child, _) =>
                {
                    var cls = new StringBuilder(64);
                    GetClassName(child, cls, 64);
                    if (cls.ToString().StartsWith("Chrome_RenderWidgetHostHWND", StringComparison.Ordinal))
                    {
                        var iid2 = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
                        AccessibleObjectFromWindow(child, 0xFFFFFFFC, ref iid2, out var o2);
                        if (o2 != null) Marshal.ReleaseComObject(o2);
                    }
                    return true;
                }, IntPtr.Zero);
            }
            catch { }
        }
    }
}
