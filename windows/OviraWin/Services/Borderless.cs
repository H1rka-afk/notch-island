using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Threading;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.8.8 — «Без рамки на весь экран». Some games (Minecraft Java in F11)
    // take the screen over completely: nothing can be drawn above them, not
    // the island, not even Windows' own volume. In a window they don't — so
    // Ovira takes the game's ordinary window, removes its frame and stretches
    // it over the whole screen. It looks and plays like full screen, and the
    // island stays visible. Turning it off gives the window its frame back.
    public static class Borderless
    {
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetLong(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO info);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr p);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder s, int max);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        private delegate bool EnumProc(IntPtr h, IntPtr p);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

        [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int cbSize; public RECT Monitor, Work; public uint Flags; }

        private const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
        private const long WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000, WS_SYSMENU = 0x00080000, WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000;
        private const long WS_EX_DLGMODALFRAME = 0x1, WS_EX_CLIENTEDGE = 0x200, WS_EX_STATICEDGE = 0x20000, WS_EX_WINDOWEDGE = 0x100;
        private const uint SWP_FRAMECHANGED = 0x20, SWP_NOZORDER = 0x4, SWP_NOOWNERZORDER = 0x200, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;

        private sealed record Saved(long Style, long Ex, RECT Rect, bool Maximized);
        private static readonly Dictionary<IntPtr, Saved> Done = new();

        public static bool IsOn(IntPtr hwnd) => Done.ContainsKey(hwnd);

        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();

        // A window Ovira stretched is not «a game in full screen» for the
        // island: it stays visible there, as on the desktop.
        public static bool ForegroundIsOurs() => Done.Count > 0 && Done.ContainsKey(GetForegroundWindow());

        public static bool HasFrame(IntPtr hwnd) => (GetLong(hwnd, GWL_STYLE).ToInt64() & WS_CAPTION) == WS_CAPTION;

        public static void Toggle(IntPtr hwnd)
        {
            if (Done.ContainsKey(hwnd)) Restore(hwnd); else Apply(hwnd);
        }

        public static void Apply(IntPtr hwnd)
        {
            if (!IsWindow(hwnd) || Done.ContainsKey(hwnd)) return;
            long style = GetLong(hwnd, GWL_STYLE).ToInt64(), ex = GetLong(hwnd, GWL_EXSTYLE).ToInt64();
            bool max = IsZoomed(hwnd);
            if (max || IsIconic(hwnd)) ShowWindow(hwnd, 9 /* SW_RESTORE */);
            GetWindowRect(hwnd, out var rect);
            Done[hwnd] = new Saved(style, ex, rect, max);
            SetLong(hwnd, GWL_STYLE, new IntPtr(style & ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)));
            SetLong(hwnd, GWL_EXSTYLE, new IntPtr(ex & ~(WS_EX_DLGMODALFRAME | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE | WS_EX_WINDOWEDGE)));
            var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            GetMonitorInfo(MonitorFromWindow(hwnd, 2), ref info);
            var m = info.Monitor;
            SetWindowPos(hwnd, IntPtr.Zero, m.Left, m.Top, m.Right - m.Left, m.Bottom - m.Top, SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
        }

        public static void Restore(IntPtr hwnd)
        {
            if (!Done.TryGetValue(hwnd, out var s)) return;
            Done.Remove(hwnd);
            if (!IsWindow(hwnd)) return;
            SetLong(hwnd, GWL_STYLE, new IntPtr(s.Style));
            SetLong(hwnd, GWL_EXSTYLE, new IntPtr(s.Ex));
            var r = s.Rect;
            SetWindowPos(hwnd, IntPtr.Zero, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
            if (s.Maximized) ShowWindow(hwnd, 3 /* SW_MAXIMIZE */);
        }

        // ---- Minecraft, automatically ----

        private static DispatcherTimer? _watch;

        public static void Start()
        {
            Settings.Current.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Settings.MinecraftBorderless)) Sync(); };
            Sync();
        }

        private static void Sync()
        {
            if (Settings.Current.MinecraftBorderless)
            {
                _watch ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                _watch.Tick -= Look;
                _watch.Tick += Look;
                _watch.Start();
                Look(null, EventArgs.Empty);
            }
            else
            {
                _watch?.Stop();
                foreach (var h in new List<IntPtr>(Done.Keys)) if (IsMinecraft(h)) Restore(h);
            }
        }

        // The game's window: Java (javaw.exe) drawing through GLFW.
        // 0.9.0: in F11 the game is asked to leave its own full screen (the
        // same F11 a player presses, sent to the game's window), and the
        // window it comes back with is stretched frameless — so it works
        // without changing anything in the game.
        private static readonly Dictionary<IntPtr, DateTime> Asked = new();

        private static void Look(object? sender, EventArgs e)
        {
            foreach (var h in new List<IntPtr>(Done.Keys)) if (!IsWindow(h)) Done.Remove(h);
            EnumWindows((h, _) =>
            {
                if (!IsWindowVisible(h) || IsIconic(h) || Done.ContainsKey(h)) return true;
                if (!IsMinecraft(h)) return true;
                if (HasFrame(h)) { Note("frame → borderless", h); Apply(h); return true; }
                // no frame and not ours: the game's own full screen
                if (Asked.TryGetValue(h, out var at) && (DateTime.Now - at).TotalSeconds < 6) return true;
                Asked[h] = DateTime.Now;
                Note("F11 full screen → asking the game to leave it", h);
                const uint WM_KEYDOWN = 0x100, WM_KEYUP = 0x101;
                long scan = 0x57L << 16;                         // F11's scan code, as GLFW reads it
                PostMessage(h, WM_KEYDOWN, new IntPtr(0x7A), new IntPtr(1 | scan));
                PostMessage(h, WM_KEYUP, new IntPtr(0x7A), new IntPtr(unchecked((int)(1 | scan | 0xC0000000L))));
                return true;
            }, IntPtr.Zero);
        }

        // What happened, for a bug report (window class and size only).
        private static void Note(string what, IntPtr h)
        {
            try
            {
                GetWindowRect(h, out var r);
                var file = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ovira", "borderless.log");
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(file)!);
                System.IO.File.AppendAllText(file, DateTime.Now.ToString("s") + " " + what + $" ({r.Right - r.Left}×{r.Bottom - r.Top})" + Environment.NewLine);
            }
            catch { }
        }

        private static bool IsMinecraft(IntPtr h)
        {
            var cls = new StringBuilder(64);
            GetClassName(h, cls, 64);
            if (!cls.ToString().StartsWith("GLFW", StringComparison.Ordinal)) return false;
            GetWindowThreadProcessId(h, out var pid);
            try
            {
                using var p = Process.GetProcessById((int)pid);
                var n = p.ProcessName.ToLowerInvariant();
                return n is "javaw" or "java" || n.Contains("minecraft");
            }
            catch { return false; }
        }
    }
}
