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

        private static void Open()
        {
            if (_bar != null) return;
            try
            {
                if (Settings.Current.TaskbarHideSystem) SystemTaskbar.Hide();
                _bar = new TaskbarWindow();
                _bar.Show();
            }
            catch
            {
                _bar = null;
                SafeRestore();
            }
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
