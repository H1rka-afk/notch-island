using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Ovira.Taskbar
{
    public sealed class TaskWindow
    {
        public IntPtr Handle;
        public string Title = "";
        public string App = "";          // the exe path, lower case — the group
        public uint Pid;
    }

    // The windows that belong on a taskbar — the same rules as Alt+Tab:
    // visible, not owned by another window, not a tool palette, not hidden by
    // Windows (other virtual desktops, suspended Store apps).
    internal static class AppWindows
    {
        private static readonly Dictionary<uint, string> PathCache = new();
        private static readonly uint Self = (uint)Environment.ProcessId;

        public static List<TaskWindow> List(IntPtr own1, IntPtr own2)
        {
            var list = new List<TaskWindow>();
            var seenPids = new HashSet<uint>();
            TB.EnumWindows((h, _) =>
            {
                try
                {
                    if (h == own1 || h == own2 || !Belongs(h)) return true;
                    TB.GetWindowThreadProcessId(h, out var pid);
                    var title = TB.Text(h);
                    var app = AppOf(h, pid);
                    if (app.Length == 0) return true;
                    list.Add(new TaskWindow { Handle = h, Title = title, App = app, Pid = pid });
                }
                catch { }
                return true;
            }, IntPtr.Zero);
            // forget processes that are gone
            if (PathCache.Count > 300) PathCache.Clear();
            return list;
        }

        private static bool Belongs(IntPtr h)
        {
            if (!TB.IsWindowVisible(h)) return false;
            long ex = TB.ExStyle(h);
            bool appWindow = (ex & TB.WS_EX_APPWINDOW) != 0;
            if (!appWindow)
            {
                if (TB.GetWindow(h, TB.GW_OWNER) != IntPtr.Zero) return false;
                if ((ex & TB.WS_EX_TOOLWINDOW) != 0) return false;
                if ((ex & TB.WS_EX_NOACTIVATE) != 0) return false;
            }
            if (TB.Cloaked(h)) return false;
            if (TB.GetWindowTextLength(h) == 0) return false;
            var cls = TB.Class(h);
            if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "Windows.UI.Core.CoreWindow") return false;
            return true;
        }

        // Store apps live inside ApplicationFrameHost; the real app is the
        // child window from another process.
        private static string AppOf(IntPtr h, uint pid)
        {
            var path = PathOf(pid);
            if (path.EndsWith("\\applicationframehost.exe", StringComparison.Ordinal))
            {
                string inner = "";
                TB.EnumChildWindows(h, (c, _) =>
                {
                    TB.GetWindowThreadProcessId(c, out var cp);
                    if (cp != pid) { inner = PathOf(cp); return false; }
                    return true;
                }, IntPtr.Zero);
                if (inner.Length > 0) return inner;
                return path + "|" + TB.Text(h).ToLowerInvariant();   // keep different Store apps apart
            }
            return path;
        }

        private static string PathOf(uint pid)
        {
            if (PathCache.TryGetValue(pid, out var p)) return p;
            p = TB.ExePath(pid).ToLowerInvariant();
            PathCache[pid] = p;
            return p;
        }

        // ---- names and icons ----

        private static readonly Dictionary<string, ImageSource?> Icons = new();
        private static readonly Dictionary<string, string> Names = new();

        public static string NameOf(string app)
        {
            if (Names.TryGetValue(app, out var n)) return n;
            n = "";
            var exe = app.Split('|')[0];
            try
            {
                var info = System.Diagnostics.FileVersionInfo.GetVersionInfo(exe);
                n = info.FileDescription?.Trim() ?? "";
                if (n.Length == 0) n = info.ProductName?.Trim() ?? "";
            }
            catch { }
            if (n.Length == 0) n = Path.GetFileNameWithoutExtension(exe);
            if (n.Length > 0) n = char.ToUpperInvariant(n[0]) + n.Substring(1);
            Names[app] = n;
            return n;
        }

        // The app's own icon from its .exe, large; the window's icon if the
        // file has none (Store apps).
        public static ImageSource? IconOf(string app, IntPtr window)
        {
            if (Icons.TryGetValue(app, out var cached) && cached != null) return cached;
            ImageSource? image = null;
            var exe = app.Split('|')[0];
            if (!exe.EndsWith("\\applicationframehost.exe", StringComparison.Ordinal))
            {
                try
                {
                    if (TB.SHDefExtractIcon(exe, 0, 0, out var large, IntPtr.Zero, 48) == 0 && large != IntPtr.Zero)
                    {
                        image = FromIcon(large);
                        TB.DestroyIcon(large);
                    }
                }
                catch { }
            }
            if (image == null && window != IntPtr.Zero)
            {
                var h = IntPtr.Zero;
                TB.SendMessageTimeout(window, TB.WM_GETICON, new IntPtr(1) /* ICON_BIG */, IntPtr.Zero, 0x2 /* ABORTIFHUNG */, 120, out h);
                if (h == IntPtr.Zero) h = TB.GetClassLongPtr(window, TB.GCLP_HICON);
                if (h == IntPtr.Zero) TB.SendMessageTimeout(window, TB.WM_GETICON, new IntPtr(2) /* ICON_SMALL2 */, IntPtr.Zero, 0x2, 120, out h);
                if (h == IntPtr.Zero) h = TB.GetClassLongPtr(window, TB.GCLP_HICONSM);
                if (h != IntPtr.Zero) image = FromIcon(h);
            }
            Icons[app] = image;
            return image;
        }

        private static ImageSource? FromIcon(IntPtr h)
        {
            try
            {
                var s = Imaging.CreateBitmapSourceFromHIcon(h, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                s.Freeze();
                return s;
            }
            catch { return null; }
        }

        // ---- actions ----

        public static void Activate(IntPtr h)
        {
            if (TB.IsIconic(h)) TB.ShowWindow(h, TB.SW_RESTORE);
            TB.SetForegroundWindow(h);
        }

        public static void Minimize(IntPtr h) => TB.ShowWindow(h, TB.SW_MINIMIZE);

        // 0.7.5: the same «close» Windows' own taskbar sends (SC_CLOSE) —
        // some apps ignore a bare WM_CLOSE from another program.
        public static void Close(IntPtr h) => TB.PostMessage(h, TB.WM_SYSCOMMAND, new IntPtr(0xF060 /* SC_CLOSE */), IntPtr.Zero);

        // «Завершить задачу»: every process of this app is ended. Explorer
        // (the desktop itself), Ovira and Store-app frames only get their
        // windows closed instead.
        public static void EndTask(string app, List<TaskWindow> windows)
        {
            var exe = app.Split('|')[0];
            var name = Path.GetFileNameWithoutExtension(exe);
            bool protect = app.Contains('|') ||
                           name.Equals("explorer", StringComparison.OrdinalIgnoreCase) ||
                           name.Equals("applicationframehost", StringComparison.OrdinalIgnoreCase) ||
                           exe.Equals((Environment.ProcessPath ?? "").ToLowerInvariant(), StringComparison.Ordinal);
            if (protect)
            {
                foreach (var w in windows) Close(w.Handle);
                return;
            }
            int ended = 0;
            foreach (var p in System.Diagnostics.Process.GetProcessesByName(name))
            {
                try
                {
                    if (p.Id == Environment.ProcessId) continue;
                    if (!TB.ExePath((uint)p.Id).Equals(exe, StringComparison.OrdinalIgnoreCase)) continue;
                    p.Kill();
                    ended++;
                }
                catch { }
                finally { p.Dispose(); }
            }
            // could not end it (e.g. it runs as administrator) — at least close the windows
            if (ended == 0) foreach (var w in windows) Close(w.Handle);
        }

        public static void Launch(string app)
        {
            var exe = app.Split('|')[0];
            if (!File.Exists(exe)) return;
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe)
                {
                    UseShellExecute = true,
                    WorkingDirectory = Path.GetDirectoryName(exe) ?? "",
                });
            }
            catch { }
        }
    }
}
