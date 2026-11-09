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
        // Saved is null when the app does not say whether the button is on.
        private sealed record Target(AutomationElement Element, bool? Saved);

        private static readonly SemaphoreSlim Gate = new SemaphoreSlim(1, 1);

        public static bool MightBeYandex(TrackInfo t) =>
            t.Source is "Яндекс Музыка" or "Chrome" or "Edge" or "Яндекс Браузер" or "Opera" or "Firefox";

        // 0.4.17: the Yandex account (if connected) answers first — it works
        // for the app and the browser alike; then the button in the window.
        public static async Task<bool?> ReadAsync(TrackInfo t)
        {
            if (YandexAccount.Connected)
            {
                var viaAccount = await YandexAccount.ReadAsync(t);
                if (viaAccount != null) return viaAccount;
            }
            await Gate.WaitAsync();
            try { return await Task.Run(() => FindWithRetry(t)?.Saved); }
            catch { return null; }
            finally { Gate.Release(); }
        }

        public enum WriteResult { Done, Refused, NotFound }

        // «shown» is what the star showed before the click; it is used only
        // when the app does not tell the button's state.
        public static async Task<WriteResult> WriteAsync(TrackInfo t, bool target)
        {
            if (YandexAccount.Connected)
            {
                var viaAccount = await YandexAccount.WriteAsync(t, target);
                if (viaAccount == true) return WriteResult.Done;
            }
            await Gate.WaitAsync();
            try
            {
                return await Task.Run(() =>
                {
                    var control = FindWithRetry(t);
                    if (control == null) return WriteResult.NotFound;
                    if (control.Saved == target) return WriteResult.Done;
                    if (!Press(control.Element)) return WriteResult.Refused;
                    if (control.Saved == null) return WriteResult.Done;   // pressed; the app does not report more
                    for (int i = 0; i < 8; i++)
                    {
                        Thread.Sleep(170);
                        var now = Find(t);
                        if (now != null && now.Saved == target) return WriteResult.Done;
                    }
                    return Find(t)?.Saved == target ? WriteResult.Done : WriteResult.Refused;
                });
            }
            catch { return WriteResult.NotFound; }
            finally { Gate.Release(); }
        }

        // What Ovira sees — for «Проверить» in Settings.
        public static Task<string> DiagnoseAsync(TrackInfo? t) => Task.Run(() =>
        {
            if (t == null) return "Сейчас ничего не играет — включи песню в Яндекс Музыке.";
            var lines = new List<string>();
            var windows = Candidates(t).ToList();
            if (windows.Count == 0)
                return "Окно Яндекс Музыки не найдено. Нужны приложение «Яндекс Музыка» или вкладка music.yandex.ru (открытая, не свёрнутая в фон).";
            lines.Add("Окон Яндекс Музыки: " + windows.Count + ".");
            var target = FindWithRetry(t, out var report);
            lines.Add(report);
            if (target != null)
                lines.Add(target.Saved == null
                    ? "Кнопка найдена, но приложение не сообщает, нажата ли она: звёздочка будет нажимать её вслепую."
                    : "Кнопка найдена, сейчас: " + (target.Saved.Value ? "в «Мне нравится»." : "не в «Мне нравится»."));
            return string.Join(" ", lines);
        });

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
        private static Target? FindWithRetry(TrackInfo t) => FindWithRetry(t, out _);

        private static Target? FindWithRetry(TrackInfo t, out string report)
        {
            var found = Find(t, out report);
            if (found != null) return found;
            WakeChromium(t);
            Thread.Sleep(600);
            return Find(t, out report);
        }

        private static Target? Find(TrackInfo t) => Find(t, out _);

        private static Target? Find(TrackInfo t, out string report)
        {
            report = "Панель плеера не найдена.";
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
                if (footer.Count == 0) { report = "Окно найдено, но Windows не показывает его содержимое (элементов: " + all.Count + ")."; continue; }
                if (!texts.Any(x => Matches(x, t.Title)))
                {
                    report = "В панели плеера не видно «" + t.Title + "». Видно: " + string.Join(", ", texts.Take(8).Select(x => "«" + x + "»")) + ".";
                    continue;
                }
                if (Normalize(t.Artist).Length > 0 && !texts.Any(x => Matches(x, t.Artist)))
                {
                    report = "Песня в панели есть, но исполнитель «" + t.Artist + "» не совпал.";
                    continue;
                }
                var buttonNames = footer.Where(n => { try { var c = n.Current.ControlType; return c == ControlType.Button || c == ControlType.CheckBox; } catch { return false; } })
                                        .Select(SafeName).Where(x => x.Length > 0).Distinct().Take(14).ToList();

                var matches = new List<(AutomationElement El, bool? Saved, double Y)>();
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
                        var r = node.Current.BoundingRectangle;
                        matches.Add((node, state, r.Top + r.Height / 2));
                    }
                    catch { }
                }
                // Buttons that tell their state win over silent ones.
                var ordered = matches.OrderByDescending(m => m.Saved.HasValue).ThenByDescending(m => m.Y).ToList();
                if (ordered.Count == 0)
                {
                    report = "Песня в панели есть, но кнопки «Мне нравится» нет. Кнопки: " + string.Join(", ", buttonNames.Select(x => "«" + x + "»")) + ".";
                    continue;
                }
                if (ordered.Count > 1 && ordered[0].Saved.HasValue == ordered[1].Saved.HasValue && Math.Abs(ordered[0].Y - ordered[1].Y) < 8)
                {
                    report = "В панели две похожие кнопки — Ovira не будет угадывать.";
                    continue;   // two on one line: do not guess
                }
                report = "Панель плеера и песня найдены.";
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

        // Chromium (the app is built on it, and so are the browsers) builds
        // its accessibility tree only once something asks for it the classic
        // way — this asks.
        [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object? obj);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr param);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);

        private static void WakeChromium(TrackInfo t)
        {
            foreach (var top in Candidates(t).Take(6))
            {
                Ask(top);
                EnumChildWindows(top, (child, _) =>
                {
                    var cls = new StringBuilder(64);
                    GetClassName(child, cls, 64);
                    if (cls.ToString().StartsWith("Chrome_RenderWidgetHostHWND", StringComparison.Ordinal)) Ask(child);
                    return true;
                }, IntPtr.Zero);
            }

            static void Ask(IntPtr hwnd)
            {
                try
                {
                    var iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");   // IAccessible
                    AccessibleObjectFromWindow(hwnd, 0xFFFFFFFC, ref iid, out var obj);  // OBJID_CLIENT
                    if (obj != null) Marshal.ReleaseComObject(obj);
                }
                catch { }
            }
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
