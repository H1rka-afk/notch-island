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
        public static string Version => "0.4.13";

        public UpdateService Updates { get; } = new UpdateService();
        public EyeBreakService EyeBreak { get; } = new EyeBreakService();
        public KeyboardWatch Keyboard { get; } = new KeyboardWatch();

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
            await Media.StartAsync();

            SetUpTray();
            if (updated) _island.ShowUpdated(Version);
            Updates.Ready += OnUpdateReady;
            Updates.Start();
            EyeBreak.Start(_island);
            Keyboard.CapsLockChanged += on => _island?.ShowCapsLock(on);
            Keyboard.LayoutChanged += code => _island?.ShowLayout(code);
            Keyboard.Start();
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
