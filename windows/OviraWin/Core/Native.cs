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

        public static void DarkTitleBar(IntPtr hwnd)
        {
            int on = 1;
            DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));
            int round = 2;
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
        }

        public static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;
    }

    // «Запускать вместе с Windows» — the per-user Run key, no admin rights.
    internal static class Autostart
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string Name = "Ovira";

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
                }
                else
                {
                    key.DeleteValue(Name, throwOnMissingValue: false);
                }
            }
            catch { }
        }
    }
}
