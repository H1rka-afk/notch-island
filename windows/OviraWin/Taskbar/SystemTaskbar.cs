using System;
using Ovira.Core;

namespace Ovira.Taskbar
{
    // Windows' own taskbar while Ovira's is on: switched to auto-hide (so the
    // screen space is free) and hidden. Everything is put back exactly as it
    // was — when Ovira's taskbar is turned off, when Ovira quits, and on the
    // next start if Ovira ever closed without being able to do it.
    internal static class SystemTaskbar
    {
        private static IntPtr Tray => TB.FindWindow("Shell_TrayWnd", null);

        public static bool Hidden => Settings.Current.SystemTaskbarHidden;

        private static int GetState()
        {
            var data = new TB.APPBARDATA { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<TB.APPBARDATA>(), hWnd = Tray };
            return (int)TB.SHAppBarMessage(TB.ABM_GETSTATE, ref data).ToUInt32();
        }

        private static void SetState(int state)
        {
            var data = new TB.APPBARDATA
            {
                cbSize = System.Runtime.InteropServices.Marshal.SizeOf<TB.APPBARDATA>(),
                hWnd = Tray,
                lParam = new IntPtr(state),
            };
            TB.SHAppBarMessage(TB.ABM_SETSTATE, ref data);
        }

        public static void Hide()
        {
            var tray = Tray;
            if (tray == IntPtr.Zero) return;
            var s = Settings.Current;
            if (!s.SystemTaskbarHidden)
            {
                s.SystemTaskbarState = GetState();
                s.SystemTaskbarHidden = true;
                s.Save();                                   // at once: a crash must still be able to undo it
            }
            if ((GetState() & TB.ABS_AUTOHIDE) == 0) SetState(TB.ABS_AUTOHIDE);
            TB.ShowWindow(tray, TB.SW_HIDE);
        }

        // Explorer shows its taskbar again now and then (after Start, after a
        // restart of Explorer) — hide it again unless Start or search is open.
        public static void KeepHidden()
        {
            if (!Hidden) return;
            var tray = Tray;
            if (tray == IntPtr.Zero || !TB.IsWindowVisible(tray)) return;
            var fg = TB.GetForegroundWindow();
            if (fg != IntPtr.Zero && (TB.Class(fg) == "Windows.UI.Core.CoreWindow" || fg == tray)) return;
            Hide();
        }

        public static void Restore()
        {
            var s = Settings.Current;
            if (!s.SystemTaskbarHidden) return;
            var tray = Tray;
            if (tray == IntPtr.Zero) return;            // Explorer is not up yet — next time
            int state = s.SystemTaskbarState >= 0 ? s.SystemTaskbarState : TB.ABS_ALWAYSONTOP;
            SetState(state);
            TB.ShowWindow(tray, TB.SW_SHOWNA);
            s.SystemTaskbarHidden = false;
            s.Save();
        }
    }
}
