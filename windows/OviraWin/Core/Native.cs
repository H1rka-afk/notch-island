using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Ovira.Core
{
    internal static class Native
    {
        public const int GWL_EXSTYLE = -20;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_LAYERED = 0x00080000;

        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
        public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        private static extern IntPtr GetTopWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int max);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        // 0.6.4: a desktop widget sits right on top of the wallpaper — just
        // above the desktop window (Progman, or the WorkerW that some wallpaper
        // apps put in front of it), under every ordinary window. HWND_BOTTOM
        // used to push it *under* the desktop, so it was invisible until
        // something reordered the windows.
        public static void PlaceOnDesktop(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            const uint GW_HWNDNEXT = 2, GW_HWNDPREV = 3;
            var name = new System.Text.StringBuilder(64);
            IntPtr desktop = IntPtr.Zero;
            for (var w = GetTopWindow(IntPtr.Zero); w != IntPtr.Zero; w = GetWindow(w, GW_HWNDNEXT))
            {
                if (w == hwnd || !IsWindowVisible(w)) continue;
                name.Clear();
                GetClassName(w, name, name.Capacity);
                var cls = name.ToString();
                if (cls == "Progman" || cls == "WorkerW") { desktop = w; break; }
            }
            if (desktop == IntPtr.Zero) return;
            var above = GetWindow(desktop, GW_HWNDPREV);
            if (above == hwnd) return;                          // already there
            var after = above == IntPtr.Zero ? IntPtr.Zero /* HWND_TOP */ : above;
            SetWindowPos(hwnd, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }

        public static void AddExStyle(IntPtr hwnd, int flags)
        {
            var style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(style | flags));
        }

        public static void RemoveExStyle(IntPtr hwnd, int flags)
        {
            var style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(style & ~(long)flags));
        }

        // Full-screen game, video or presentation in front?
        [DllImport("shell32.dll")]
        private static extern int SHQueryUserNotificationState(out int state);

        public static bool FullscreenAppInFront()
        {
            if (SHQueryUserNotificationState(out var state) != 0) return false;
            // 2 = busy (full-screen app), 3 = Direct3D full screen, 4 = presentation mode
            return state == 2 || state == 3 || state == 4;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

        [StructLayout(LayoutKind.Sequential)]
        private struct WinRect { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetWindowRect(IntPtr hWnd, out WinRect rect);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

        [StructLayout(LayoutKind.Sequential)]
        private struct MonitorInfo { public int cbSize; public WinRect Monitor, Work; public uint Flags; }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

        // 0.6.4: stricter than FullscreenAppInFront for the desktop widgets.
        // Windows also says «busy» while the desktop itself (a full-screen
        // window too) has the focus, and the widgets used to hide right then —
        // they came back only when another window, e.g. the settings, opened.
        public static bool GameCoversDesktop()
        {
            if (SHQueryUserNotificationState(out var state) != 0) return false;
            if (state == 3 || state == 4) return true;
            if (state != 2) return false;
            var fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return false;
            GetWindowThreadProcessId(fg, out var pid);
            if (pid == (uint)Environment.ProcessId) return false;
            var name = new System.Text.StringBuilder(64);
            GetClassName(fg, name, name.Capacity);
            var cls = name.ToString();
            if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return false;
            if (!GetWindowRect(fg, out var r)) return false;
            var info = new MonitorInfo { cbSize = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(MonitorFromWindow(fg, 2), ref info)) return false;
            var m = info.Monitor;
            return r.Left <= m.Left && r.Top <= m.Top && r.Right >= m.Right && r.Bottom >= m.Bottom;
        }

        // Windows 11 window backdrop (Mica) and dark title bar.
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [StructLayout(LayoutKind.Sequential)]
        public struct Margins { public int Left, Right, Top, Bottom; }

        [DllImport("dwmapi.dll")]
        private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

        public static void UseMica(IntPtr hwnd, bool dark)
        {
            int on = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));          // DWMWA_USE_IMMERSIVE_DARK_MODE
            int mica = 2;                                                    // DWMSBT_MAINWINDOW
            DwmSetWindowAttribute(hwnd, 38, ref mica, sizeof(int));         // DWMWA_SYSTEMBACKDROP_TYPE
            int round = 2;                                                   // DWMWCP_ROUND
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));        // DWMWA_WINDOW_CORNER_PREFERENCE
            var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            DwmExtendFrameIntoClientArea(hwnd, ref margins);
        }

        public static void DarkTitleBar(IntPtr hwnd, bool dark = true)
        {
            int on = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));
            int round = 2;
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
        }

        // 0.4.3: Ovira is a window app and never opens a console; if one was
        // attached anyway (started from a script), it is closed at once.
        [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll")] private static extern bool FreeConsole();
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);

        public static void DropConsole()
        {
            try
            {
                var console = GetConsoleWindow();
                if (console == IntPtr.Zero) return;
                FreeConsole();
            }
            catch { }
        }

        public static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;
    }

    // «Запускать вместе с Windows» — the per-user Run key, no admin rights.
    internal static class Autostart
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string Name = "Ovira";

        // Task Manager → «Автозагрузка» keeps its own on/off next to the Run key.
        private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

        // Switched off by hand in Task Manager?
        public static bool DisabledInTaskManager()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(ApprovedKey);
                return key?.GetValue(Name) is byte[] flags && flags.Length > 0 && (flags[0] & 1) == 1;
            }
            catch { return false; }
        }

        public static bool IsOn()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(Name) is string && !DisabledInTaskManager();
            }
            catch { return false; }
        }

        public static void Apply(bool on)
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true)
                                ?? Registry.CurrentUser.CreateSubKey(RunKey);
                if (on)
                {
                    var exe = Environment.ProcessPath;
                    if (!string.IsNullOrEmpty(exe)) key.SetValue(Name, "\"" + exe + "\"");
                    // Turned on in Ovira's settings = also on in Task Manager.
                    using var approved = Registry.CurrentUser.CreateSubKey(ApprovedKey);
                    approved?.SetValue(Name, new byte[12] { 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);
                }
                else
                {
                    key.DeleteValue(Name, throwOnMissingValue: false);
                    using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
                    approved?.DeleteValue(Name, throwOnMissingValue: false);
                }
            }
            catch { }
        }
    }
}
