using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Ovira.Services
{
    // 0.4.8 — Caps Lock and the keyboard layout, for the island. Five times a
    // second it asks Windows two things: is Caps Lock on, and which language
    // the window in front types in. No keyboard hook — what is typed is never
    // seen, only these two states.
    public sealed class KeyboardWatch
    {
        [DllImport("user32.dll")] private static extern short GetKeyState(int key);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
        [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint thread);

        private const int VK_CAPITAL = 0x14;
        private readonly DispatcherTimer _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(200) };
        private bool? _caps;
        private string? _layout;
        private IntPtr _window;

        public event Action<bool>? CapsLockChanged;
        public event Action<string>? LayoutChanged;

        public void Start()
        {
            _timer.Tick += (_, _) => Poll();
            _timer.Start();
        }

        public void Stop() => _timer.Stop();

        public static bool CapsLock() => (GetKeyState(VK_CAPITAL) & 1) != 0;

        public static string CurrentLayout() => Layout(GetForegroundWindow());

        private static string Layout(IntPtr window)
        {
            try
            {
                var thread = GetWindowThreadProcessId(window, IntPtr.Zero);
                int lang = (int)((long)GetKeyboardLayout(thread) & 0xFFFF);
                if (lang == 0) return "";
                return new CultureInfo(lang).TwoLetterISOLanguageName.ToUpperInvariant();
            }
            catch { return ""; }
        }

        private void Poll()
        {
            var caps = CapsLock();
            if (_caps.HasValue && caps != _caps.Value) CapsLockChanged?.Invoke(caps);
            _caps = caps;

            var window = GetForegroundWindow();
            var layout = Layout(window);
            // Only a switch inside the same window counts — moving to another
            // window with its own language is not a change.
            if (window == _window && _layout != null && layout.Length > 0 && layout != _layout) LayoutChanged?.Invoke(layout);
            _window = window;
            if (layout.Length > 0) _layout = layout;
        }
    }
}
