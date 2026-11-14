using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Ovira.Core;

namespace Ovira.Taskbar
{
    public sealed class TaskWindow
    {
        public IntPtr Handle;
        public string Title = "";
        public string App = "";          // the exe path, lower case — the group
        public uint Pid;
        public string AppId = "";        // 0.7.6: the app's AppUserModelID, if it has one
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
                    var id = AppIdOf(h);
                    if (id.Length > 0) AppIds[app] = id;
                    list.Add(new TaskWindow { Handle = h, Title = title, App = app, Pid = pid, AppId = id });
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

        // 0.7.6: icons the way Windows' own taskbar and Start show them —
        // through the shell, large (the 256 px «jumbo» image scaled down), with
        // soft edges. Store apps such as «Параметры» get their real round
        // icon from their package instead of a small square from the .exe.
        public static ImageSource? IconOf(string app, IntPtr window)
        {
            if (Icons.TryGetValue(app, out var cached) && cached != null) return cached;
            ImageSource? image = null;
            var exe = app.Split('|')[0];
            AppIds.TryGetValue(app, out var id);
            if (string.IsNullOrEmpty(id) && Settings.Current.TaskbarAppIds.TryGetValue(app, out var saved)) id = saved;
            if (!string.IsNullOrEmpty(id)) image = ShellIcon.Get("shell:AppsFolder\\" + id, 96);
            if (image == null && !exe.EndsWith("\\applicationframehost.exe", StringComparison.Ordinal) && File.Exists(exe))
                image = ShellIcon.Get(exe, 96);
            if (image == null && !exe.EndsWith("\\applicationframehost.exe", StringComparison.Ordinal))
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

        // ---- AppUserModelID of a window ----

        public static readonly Dictionary<string, string> AppIds = new();
        private static readonly Dictionary<IntPtr, string> IdCache = new();

        private static string AppIdOf(IntPtr hwnd)
        {
            if (IdCache.TryGetValue(hwnd, out var id)) return id;
            id = "";
            try
            {
                var iid = new Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
                if (SHGetPropertyStoreForWindow(hwnd, ref iid, out var store) == 0 && store != null)
                {
                    var key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
                    if (store.GetValue(ref key, out var pv) == 0)
                    {
                        if (pv.vt == 31 /* VT_LPWSTR */ && pv.p != IntPtr.Zero) id = System.Runtime.InteropServices.Marshal.PtrToStringUni(pv.p) ?? "";
                        PropVariantClear(ref pv);
                    }
                    System.Runtime.InteropServices.Marshal.ReleaseComObject(store);
                }
            }
            catch { }
            if (IdCache.Count > 500) IdCache.Clear();
            IdCache[hwnd] = id;
            return id;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct PropertyKey { public Guid fmtid; public uint pid; }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct PropVariant { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

        [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
         System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [System.Runtime.InteropServices.PreserveSig] int GetCount(out uint count);
            [System.Runtime.InteropServices.PreserveSig] int GetAt(uint index, out PropertyKey key);
            [System.Runtime.InteropServices.PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [System.Runtime.InteropServices.PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [System.Runtime.InteropServices.PreserveSig] int Commit();
        }

        [System.Runtime.InteropServices.DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Interface)] out IPropertyStore store);

        [System.Runtime.InteropServices.DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant pv);

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

        // Store apps can't be started from their .exe — they open through the
        // shell by their AppUserModelID, the way Start opens them.
        public static bool CanLaunch(string app) => !app.Contains('|') || IdFor(app).Length > 0;

        private static string IdFor(string app)
        {
            if (AppIds.TryGetValue(app, out var id) && id.Length > 0) return id;
            return Settings.Current.TaskbarAppIds.TryGetValue(app, out var saved) ? saved : "";
        }

        private static bool Packaged(string app) =>
            app.Contains('|') || app.Contains("\\windowsapps\\") || app.Contains("\\systemapps\\") || app.EndsWith("\\applicationframehost.exe");

        public static void Launch(string app)
        {
            var exe = app.Split('|')[0];
            var id = IdFor(app);
            if (id.Length > 0 && (Packaged(app) || !File.Exists(exe)))
            {
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", "shell:AppsFolder\\" + id) { UseShellExecute = true }); } catch { }
                return;
            }
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
