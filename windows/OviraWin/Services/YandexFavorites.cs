using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace Ovira.Services
{
    // 0.4.15 — the real «Мне нравится» of Yandex Music, as on the Mac
    // (YandexDesktopFavorites.swift), through Windows UI Automation — the
    // same accessibility interface screen readers use. Ovira looks only at
    // the player bar at the bottom of the Yandex Music window (the desktop
    // app, or a browser tab with music.yandex.ru), makes sure the song there
    // is the one playing, finds its like button and reads or presses it.
    // If anything is unclear — two buttons, no state, another song — it
    // refuses rather than guesses.
    public static class YandexFavorites
    {
        private sealed record Target(AutomationElement Element, bool Saved);

        private static readonly SemaphoreSlim Gate = new SemaphoreSlim(1, 1);

        public static bool MightBeYandex(TrackInfo t) =>
            t.Source is "Яндекс Музыка" or "Chrome" or "Edge" or "Яндекс Браузер" or "Opera" or "Firefox";

        public static async Task<bool?> ReadAsync(TrackInfo t)
        {
            await Gate.WaitAsync();
            try { return await Task.Run(() => FindWithRetry(t)?.Saved); }
            catch { return null; }
            finally { Gate.Release(); }
        }

        // Returns the state the app really has afterwards, or null if the
        // button could not be found.
        public static async Task<bool?> WriteAsync(TrackInfo t, bool target)
        {
            await Gate.WaitAsync();
            try
            {
                return await Task.Run(() =>
                {
                    var control = FindWithRetry(t);
                    if (control == null) return (bool?)null;
                    if (control.Saved == target) return target;
                    if (!Press(control.Element)) return control.Saved;
                    for (int i = 0; i < 8; i++)
                    {
                        Thread.Sleep(170);
                        var now = Find(t);
                        if (now != null && now.Saved == target) return target;
                    }
                    return Find(t)?.Saved;
                });
            }
            catch { return null; }
            finally { Gate.Release(); }
        }

        private static bool Press(AutomationElement e)
        {
            try
            {
                if (e.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke)) { ((InvokePattern)invoke).Invoke(); return true; }
                if (e.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle)) { ((TogglePattern)toggle).Toggle(); return true; }
            }
            catch { }
            return false;
        }

        // Chromium switches its accessibility tree on at the first request,
        // so an empty first look is tried once more.
        private static Target? FindWithRetry(TrackInfo t)
        {
            var found = Find(t);
            if (found != null) return found;
            Thread.Sleep(450);
            return Find(t);
        }

        private static Target? Find(TrackInfo t)
        {
            if (Normalize(t.Title).Length == 0) return null;
            foreach (var hwnd in Candidates(t).Take(6))
            {
                AutomationElement root;
                try { root = AutomationElement.FromHandle(hwnd); }
                catch { continue; }
                var box = root.Current.BoundingRectangle;
                if (box.IsEmpty || box.Height < 200 || box.Width < 300) continue;
                // Only the player bar: the lowest quarter, at most ~260 px.
                double footerTop = box.Bottom - Math.Min(260, box.Height * 0.24);
                var condition = new OrCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.CheckBox),
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text),
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Hyperlink));
                AutomationElementCollection all;
                try { all = root.FindAll(TreeScope.Descendants, condition); }
                catch { continue; }

                var footer = new List<AutomationElement>();
                foreach (AutomationElement node in all)
                {
                    try
                    {
                        var r = node.Current.BoundingRectangle;
                        if (r.IsEmpty) continue;
                        double midY = r.Top + r.Height / 2, midX = r.Left + r.Width / 2;
                        if (midY >= footerTop && midY <= box.Bottom + 3 && midX >= box.Left && midX <= box.Right) footer.Add(node);
                    }
                    catch { }
                }
                var texts = footer.Select(n => SafeName(n)).Where(s => s.Length > 0).ToList();
                if (!texts.Any(x => Matches(x, t.Title))) continue;
                if (Normalize(t.Artist).Length > 0 && !texts.Any(x => Matches(x, t.Artist))) continue;

                var matches = new List<(AutomationElement El, bool Saved, double Y)>();
                foreach (var node in footer)
                {
                    try
                    {
                        var type = node.Current.ControlType;
                        if (type != ControlType.Button && type != ControlType.CheckBox) continue;
                        var text = Label(node);
                        if (text.Contains("не нравится") || text.Contains("dislike") || text.Contains("skip song")) continue;
                        if (!(text.Contains("нрав") || text.Contains("лайк") || text.Contains("любим") || text.Contains("liked") ||
                              text.Contains("favorite") || text.Contains("like"))) continue;
                        var state = LikeStatus(node, text);
                        if (state == null) continue;
                        var r = node.Current.BoundingRectangle;
                        matches.Add((node, state.Value, r.Top + r.Height / 2));
                    }
                    catch { }
                }
                var ordered = matches.OrderByDescending(m => m.Y).ToList();
                if (ordered.Count == 0) continue;
                if (ordered.Count > 1 && Math.Abs(ordered[0].Y - ordered[1].Y) < 8) continue;   // two on one line: do not guess
                return new Target(ordered[0].El, ordered[0].Saved);
            }
            return null;
        }

        private static string SafeName(AutomationElement e)
        {
            try { return e.Current.Name ?? ""; } catch { return ""; }
        }

        private static string Label(AutomationElement e)
        {
            try { return (e.Current.Name + " " + e.Current.HelpText + " " + e.Current.AutomationId).ToLowerInvariant(); }
            catch { return ""; }
        }

        // Same rules as the Mac: words first, then the button's own pressed state.
        private static bool? LikeStatus(AutomationElement e, string text)
        {
            if (text.Contains("удалить из") || text.Contains("убрать из") || text.Contains("снять лайк") || text.Contains("remove from") ||
                text.Contains("unlike") || text.Contains("already liked") || text.Contains("убрать лайк")) return true;
            if (text.Contains("добавить в") || text.Contains("поставить лайк") || text.Contains("add to") || text.Contains("like song") ||
                text.Contains("like track") || text.Contains("поставить нравится")) return false;
            try
            {
                if (e.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle))
                {
                    var s = ((TogglePattern)toggle).Current.ToggleState;
                    if (s == ToggleState.On) return true;
                    if (s == ToggleState.Off) return false;
                }
                if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var sel))
                    return ((SelectionItemPattern)sel).Current.IsSelected;
            }
            catch { }
            return null;
        }

        private static string Normalize(string s)
        {
            var b = new StringBuilder();
            foreach (var c in (s ?? "").ToLowerInvariant().Replace('ё', 'е'))
                b.Append(char.IsLetterOrDigit(c) ? c : ' ');
            return string.Join(' ', b.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
        }

        private static bool Matches(string text, string expected)
        {
            var t = Normalize(text);
            var q = Normalize(expected);
            if (q.Length == 0 || t.Length == 0) return false;
            return t == q || (" " + t + " ").Contains(" " + q + " ");
        }

        // ---- the windows to look in ----

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr param);
        private delegate bool EnumProc(IntPtr hwnd, IntPtr param);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

        private static IEnumerable<IntPtr> Candidates(TrackInfo t)
        {
            var names = new Dictionary<uint, string>();
            string ProcessName(uint pid)
            {
                if (names.TryGetValue(pid, out var n)) return n;
                try { using var p = Process.GetProcessById((int)pid); n = p.ProcessName.ToLowerInvariant(); }
                catch { n = ""; }
                names[pid] = n;
                return n;
            }
            var app = new List<IntPtr>();
            var tabs = new List<IntPtr>();
            EnumWindows((hwnd, _) =>
            {
                if (!IsWindowVisible(hwnd)) return true;
                GetWindowThreadProcessId(hwnd, out var pid);
                var name = ProcessName(pid);
                var title = new StringBuilder(512);
                GetWindowText(hwnd, title, 512);
                var caption = title.ToString().ToLowerInvariant();
                if (name.Contains("яндекс музыка") || name.Contains("yandexmusic") || name.Contains("yandex music") || name.Contains("yandex.music"))
                    app.Add(hwnd);
                else if ((caption.Contains("яндекс музык") || caption.Contains("yandex music")) &&
                         (name is "chrome" or "msedge" or "browser" or "opera" or "firefox" or "brave" or "vivaldi"))
                    tabs.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            return t.Source == "Яндекс Музыка" ? app.Concat(tabs) : tabs.Concat(app);
        }
    }
}
