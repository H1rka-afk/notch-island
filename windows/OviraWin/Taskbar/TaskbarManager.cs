using System;
using Ovira.Core;

namespace Ovira.Taskbar
{
    // Turns Ovira's taskbar on and off with the settings and makes sure
    // Windows' own taskbar always comes back.
    public static class TaskbarManager
    {
        private static TaskbarWindow? _bar;
        private static bool _started;

        public static void Start()
        {
            if (_started) return;
            _started = true;
            var s = Settings.Current;
            // Ovira closed last time without putting Windows' taskbar back.
            if (s.SystemTaskbarHidden && !(s.TaskbarEnabled && s.TaskbarHideSystem)) SystemTaskbar.Restore();
            AppDomain.CurrentDomain.ProcessExit += (_, _) => SafeRestore();
            AppDomain.CurrentDomain.UnhandledException += (_, _) => SafeRestore();
            s.PropertyChanged += (_, e) =>
            {
                switch (e.PropertyName)
                {
                    case nameof(Settings.TaskbarEnabled):
                        if (s.TaskbarEnabled) Open(); else Close();
                        break;
                    case nameof(Settings.TaskbarHideSystem):
                        if (_bar == null) break;
                        if (s.TaskbarHideSystem) SystemTaskbar.Hide(); else SystemTaskbar.Restore();
                        break;
                    case nameof(Settings.TaskbarStyle):
                    case nameof(Settings.TaskbarColor):
                    case nameof(Settings.TaskbarCustomColor):
                    case nameof(Settings.TaskbarStartIcon):
                    case nameof(Settings.TaskbarAlign):
                    case nameof(Settings.Theme):
                    case nameof(Settings.CustomThemes):
                        _bar?.ApplyLook();
                        break;
                    case nameof(Settings.TaskbarLayout):
                    case nameof(Settings.TaskbarSideHide):
                        // a new window for the other look; Windows' taskbar stays hidden
                        if (_bar == null) break;
                        var old = _bar;
                        _bar = null;
                        try { old.Close(); } catch { }
                        Open();
                        break;
                    case nameof(Settings.TaskbarSize):
                        _bar?.ApplySize();
                        break;
                    case nameof(Settings.TaskbarPinned):
                        _bar?.PinnedChanged();
                        break;
                }
            };
            // the music's colour or cover follows the song
            object? lastArt = null;
            var lastTint = System.Windows.Media.Colors.Transparent;
            App.Current.Media.Changed += t => App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_bar == null) return;
                bool follows = s.TaskbarColor == "cover" || s.TaskbarStyle == "cover";
                var tint = t?.Tint ?? System.Windows.Media.Colors.Transparent;
                if (!follows || (ReferenceEquals(lastArt, t?.Artwork) && tint == lastTint)) return;
                lastArt = t?.Artwork;
                lastTint = tint;
                _bar.ApplyLook();
            }), System.Windows.Threading.DispatcherPriority.Background);
            if (s.TaskbarEnabled) Open();
        }

        // 0.7.5: at Windows start-up Ovira can be up before Explorer — then
        // there is no taskbar to hide and no shell to keep a strip free for
        // the dock. Wait for Explorer (and try again if something failed).
        private static System.Windows.Threading.DispatcherTimer? _retry;
        private static int _tries;

        private static void Open()
        {
            if (_bar != null) return;
            if (TB.FindWindow("Shell_TrayWnd", null) == IntPtr.Zero || Environment.TickCount64 < 90_000 && _tries == 0 && !ShellSettled())
            {
                Later();
                return;
            }
            try
            {
                if (Settings.Current.TaskbarHideSystem) SystemTaskbar.Hide();
                _bar = new TaskbarWindow();
                _bar.Show();
                _tries = 0;
            }
            catch (Exception e)
            {
                Log(e);
                try { _bar?.Close(); } catch { }
                _bar = null;
                SafeRestore();
                Later();
            }
        }

        // Explorer has been up for a few seconds already.
        private static DateTime _shellSeen = DateTime.MinValue;
        private static bool ShellSettled()
        {
            if (_shellSeen == DateTime.MinValue) _shellSeen = DateTime.Now;
            return (DateTime.Now - _shellSeen).TotalSeconds >= 4;
        }

        private static void Later()
        {
            if (++_tries > 40) return;                     // ~2 minutes
            _retry ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            _retry.Stop();
            _retry.Tick -= RetryTick;
            _retry.Tick += RetryTick;
            _retry.Start();
        }

        private static void RetryTick(object? sender, EventArgs e)
        {
            _retry?.Stop();
            if (Settings.Current.TaskbarEnabled) Open();
        }

        // What went wrong, for a bug report (no personal data — just the error).
        private static void Log(Exception e)
        {
            try
            {
                var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ovira");
                System.IO.Directory.CreateDirectory(dir);
                System.IO.File.AppendAllText(System.IO.Path.Combine(dir, "taskbar.log"), DateTime.Now.ToString("s") + " " + e + Environment.NewLine);
            }
            catch { }
        }

        private static void Close()
        {
            var bar = _bar;
            _bar = null;
            try { bar?.Close(); } catch { }
            SafeRestore();
        }

        public static void Stop()
        {
            var bar = _bar;
            _bar = null;
            try { bar?.Close(); } catch { }
            SafeRestore();
        }

        private static void SafeRestore()
        {
            try { SystemTaskbar.Restore(); } catch { }
        }
    }
}
