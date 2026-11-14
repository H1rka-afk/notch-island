using System;
using System.Threading;
using System.Windows;
using Ovira.Core;
using Ovira.Island;
using Ovira.Services;
using Ovira.SettingsUi;

namespace Ovira
{
    public partial class App : Application
    {
        private static Mutex? _single;
        private System.Windows.Forms.NotifyIcon? _tray;
        private IslandWindow? _island;
        private SettingsWindow? _settings;

        public MediaService Media { get; } = new MediaService();
        public AudioService Audio { get; } = new AudioService();
        public PowerService Power { get; } = new PowerService();
        public SpectrumService Spectrum { get; } = new SpectrumService();
        public IslandWindow? IslandWindow => _island;

        public static new App Current => (App)Application.Current;

        // 0.4.2: no global 240 fps for every animation any more — it kept the
        // processor busy. The island's springs follow the screen by themselves.
        public static string Version => "0.7.8";

        public UpdateService Updates { get; } = new UpdateService();
        public EyeBreakService EyeBreak { get; } = new EyeBreakService();
        public KeyboardWatch Keyboard { get; } = new KeyboardWatch();
        public ClockService Clock { get; } = new ClockService();
        public CallService Calls { get; } = new CallService();
        public SteamService Steam { get; } = new SteamService();
        public StatsService Stats { get; } = new StatsService();
        private VolumeKeys? _volumeKeys;
        public VolumeKeys VolumeKeys => _volumeKeys ??= new VolumeKeys(Audio);

        protected override async void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // One Ovira at a time.
            bool updated = Array.IndexOf(e.Args, "--updated") >= 0;
            _single = new Mutex(true, "Ovira.Windows.Single", out var first);
            if (!first)
            {
                // Right after an update the old copy is still closing: wait for it.
                bool got = false;
                if (updated)
                {
                    try { got = _single.WaitOne(TimeSpan.FromSeconds(12)); }
                    catch (AbandonedMutexException) { got = true; }
                    if (!got)
                    {
                        // 0.4.13: the old copy hung while closing — close it.
                        UpdateService.CloseOldCopy();
                        try { got = _single.WaitOne(TimeSpan.FromSeconds(5)); }
                        catch (AbandonedMutexException) { got = true; }
                    }
                }
                if (!got)
                {
                    Shutdown();
                    return;
                }
            }
            UpdateService.CleanUp();

            DispatcherUnhandledException += (_, args) =>
            {
                // Log and keep the island alive.
                try
                {
                    System.IO.Directory.CreateDirectory(Settings.Folder);
                    System.IO.File.AppendAllText(System.IO.Path.Combine(Settings.Folder, "errors.log"),
                        DateTime.Now.ToString("s") + "  " + args.Exception + Environment.NewLine);
                }
                catch { }
                args.Handled = true;
            };

            Native.DropConsole();
            Settings.Load();
            var firstRun = !System.IO.File.Exists(System.IO.Path.Combine(Settings.Folder, "settings.json"));
            // Turned off in Task Manager → off in Ovira too; otherwise keep the
            // Run entry pointing at this very Ovira.exe.
            if (Settings.Current.StartWithWindows)
            {
                if (Autostart.DisabledInTaskManager()) Settings.Current.StartWithWindows = false;
                else Autostart.Apply(true);
            }

            Audio.Start();
            Power.Start();
            Spectrum.Start();
            SpectrumClock.Source = Spectrum;
            // The sound is analysed only while music plays — no work in silence.
            Media.Changed += t => Spectrum.Wanted = t != null && t.Playing;
            _island = new IslandWindow(Media, Audio, Power);
            _island.Show();
            _island.Begin();
            // 0.6.4: the desktop widgets come up together with the island,
            // not after the music service has woken up.
            Ovira.Widgets.WidgetManager.Start();
            // 0.7.0: Ovira's own taskbar (off unless turned on in the settings).
            Ovira.Taskbar.TaskbarManager.Start();
            await Media.StartAsync();

            SetUpTray();
            if (updated) _island.ShowUpdated(Version);
            Updates.Ready += OnUpdateReady;
            Updates.Start();
            EyeBreak.Start(_island);
            Keyboard.CapsLockChanged += on => _island?.ShowCapsLock(on);
            Keyboard.LayoutChanged += code => _island?.ShowLayout(code);
            Keyboard.Start();
            // 0.5.0: live activities — a call, the timer, the stopwatch, alarms.
            _island.ActivitySource = CurrentActivity;
            Clock.Changed += () => _island?.RefreshActivity();
            Calls.Changed += () => _island?.RefreshActivity();
            Clock.Start();
            Calls.Start();
            // 0.5.1: Steam downloads and the day's statistics.
            Steam.Changed += () => _island?.RefreshActivity();
            Steam.Finished += name => _island?.ShowNote("checkmark.circle", "Готово");
            Steam.Start();
            Stats.IsPlaying = () => Media.Track?.Playing == true;
            Stats.CurrentTrack = () => Media.Track is { } t ? t.Title + "\u0001" + t.Artist : null;
            Stats.InCall = () => Calls.Current != null;
            Calls.Changed += () => { if (Calls.Current != null && !_inCall) Stats.Record(StatEvent.Call); _inCall = Calls.Current != null; };
            Stats.Start();
            if (firstRun)
            {
                Settings.Current.Save();
                OpenSettings();
            }
        }

        private void SetUpTray()
        {
            System.Drawing.Icon icon;
            try
            {
                var stream = GetResourceStream(new Uri("pack://application:,,,/Assets/Ovira.ico"))?.Stream;
                icon = stream != null ? new System.Drawing.Icon(stream) : System.Drawing.SystemIcons.Application;
            }
            catch { icon = System.Drawing.SystemIcons.Application; }

            var menu = new System.Windows.Forms.ContextMenuStrip();
            menu.Items.Add("Настройки Ovira", null, (_, _) => OpenSettings());
            menu.Items.Add("Открыть плеер", null, (_, _) => _island?.DemoOpen());
            var autostart = new System.Windows.Forms.ToolStripMenuItem("Запускать вместе с Windows") { CheckOnClick = true, Checked = Settings.Current.StartWithWindows };
            autostart.Click += (_, _) => Settings.Current.StartWithWindows = autostart.Checked;
            Settings.Current.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName == nameof(Settings.StartWithWindows)) autostart.Checked = Settings.Current.StartWithWindows;
            };
            menu.Items.Add(autostart);
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add("Выйти", null, (_, _) => Quit());

            _tray = new System.Windows.Forms.NotifyIcon
            {
                Icon = icon,
                Text = "Ovira",
                Visible = true,
                ContextMenuStrip = menu
            };
            _tray.MouseClick += (_, args) =>
            {
                if (args.Button == System.Windows.Forms.MouseButtons.Left) OpenSettings();
            };
        }

        private void OnUpdateReady(string version)
        {
            if (Settings.Current.AutoInstallUpdates && !(_island?.Busy ?? false))
            {
                Updates.Install();
                return;
            }
            _island?.ShowUpdateReady(version);
            try
            {
                if (_tray != null)
                {
                    _tray.BalloonTipClicked -= OnBalloonClicked;
                    _tray.BalloonTipClicked += OnBalloonClicked;
                    _tray.ShowBalloonTip(8000, "Ovira " + version, "Обновление скачано. Нажми, чтобы установить.", System.Windows.Forms.ToolTipIcon.Info);
                }
            }
            catch { }
        }

        private void OnBalloonClicked(object? sender, EventArgs e) => Dispatcher.BeginInvoke(new Action(Updates.Install));

        private bool _inCall;
        private static readonly System.Windows.Media.Color SteamBlue = System.Windows.Media.Color.FromRgb(0x1A, 0x9F, 0xFF);
        private static readonly System.Windows.Media.Color Green = System.Windows.Media.Color.FromRgb(0x34, 0xC7, 0x59);
        private static readonly System.Windows.Media.Color Amber = System.Windows.Media.Color.FromRgb(0xFF, 0x9F, 0x0A);
        private static readonly System.Windows.Media.Color Yellow = System.Windows.Media.Color.FromRgb(0xFF, 0xD6, 0x0A);

        // What the island shows as a live activity: a call first, then a
        // ringing alarm or timer, then the timer, then the stopwatch.
        private Island.IslandWindow.Activity? CurrentActivity()
        {
            if (Calls.Current is { } call)
            {
                var length = ClockService.Format(DateTime.Now - call.Since);
                bool muted = Calls.MicMuted;
                return new Island.IslandWindow.Activity("call", "phone.fill", Green, length, call.App, length,
                    muted ? "mic.slash" : "mic", Calls.ToggleMic, muted, "phone.down", HangUp);
            }
            if (Clock.Ringing is { } what)
            {
                bool alarm = what != "Таймер";
                return new Island.IslandWindow.Activity("ring", "bell", Amber, alarm ? Clock.RingingTime : "Готово", what,
                    alarm ? Clock.RingingTime : "Время вышло", alarm ? "moon" : null, alarm ? () => Clock.Snooze() : null, false,
                    "xmark", Clock.StopRinging, TapRuns: true);
            }
            if (Steam.Current is { } d)
            {
                var percent = (int)Math.Floor(d.Progress * 100) + " %";
                var state = d.Installing ? "Установка" : d.Paused ? "Пауза" : percent;
                var details = new (string, string)[]
                {
                    ("Прошло", ClockService.Format(d.Elapsed)),
                    ("Осталось", d.Installing ? "почти всё" : d.Left is { } left ? ClockService.Format(left) : "—"),
                    ("Скачано", d.Total > 0 ? SteamService.Size(d.Done) + " из " + SteamService.Size(d.Total) : "—"),
                    ("Скорость", SteamService.Rate(d.Speed)),
                    ("Пик", SteamService.Rate(d.Peak)),
                    ("Диск", SteamService.Rate(d.Disk)),
                };
                var steam = new Island.IslandWindow.Activity("steam", "arrow.down", SteamBlue, d.Installing ? "Уст." : d.Paused ? "Пауза" : percent,
                    "Steam · " + state, d.Name, null, null, false, "xmark", Steam.Dismiss, Progress: d.Progress, Details: details);
                // A running timer or stopwatch keeps the small banner; Steam shows when they do not.
                if (!Clock.TimerActive && !Clock.StopwatchActive) return steam;
            }
            if (Clock.TimerActive)
            {
                var left = ClockService.Format(Clock.TimerLeft);
                return new Island.IslandWindow.Activity("timer", "timer", Amber, left, Clock.TimerPaused ? "Таймер · пауза" : "Таймер", left,
                    Clock.TimerPaused ? "play" : "pause", () => { if (Clock.TimerPaused) Clock.ResumeTimer(); else Clock.PauseTimer(); }, false,
                    "xmark", Clock.CancelTimer);
            }
            if (Clock.StopwatchActive)
            {
                var t = Clock.StopwatchTime;
                return new Island.IslandWindow.Activity("stopwatch", "timer", Yellow, ClockService.Format(t),
                    Clock.StopwatchRunning ? "Секундомер" : "Секундомер · пауза", ClockService.FormatPrecise(t),
                    Clock.StopwatchRunning ? "pause" : "play", () => { if (Clock.StopwatchRunning) Clock.PauseStopwatch(); else Clock.StartStopwatch(); }, false,
                    "xmark", Clock.ResetStopwatch);
            }
            return null;
        }

        private async void HangUp()
        {
            var ok = await Calls.HangUpAsync();
            if (!ok) _island?.ShowNote("xmark", "Не нашёл кнопку");
        }

        public void OpenSettings()
        {
            if (_settings == null || !_settings.IsLoaded)
            {
                _settings = new SettingsWindow();
                _settings.Closed += (_, _) => _settings = null;
                _settings.Show();
            }
            if (_settings.WindowState == WindowState.Minimized) _settings.WindowState = WindowState.Normal;
            _settings.Activate();
        }

        public void Quit()
        {
            Settings.Current.Save();
            if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
            Audio.Dispose();
            Spectrum.Dispose();
            EyeBreak.Stop();
            Keyboard.Stop();
            Stats.Stop();
            Ovira.Widgets.WidgetManager.CloseAll();
            Ovira.Taskbar.TaskbarManager.Stop();
            _volumeKeys?.Release();
            Shutdown();
            // 0.4.13: nothing left in the background may keep Ovira running
            // (a stuck audio thread used to block the update from starting).
            _ = System.Threading.Tasks.Task.Delay(4000).ContinueWith(_ => Environment.Exit(0));
        }

        protected override void OnExit(ExitEventArgs e)
        {
            if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
            base.OnExit(e);
        }
    }
}
