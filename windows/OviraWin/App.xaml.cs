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
        public IslandWindow? IslandWindow => _island;

        public static new App Current => (App)Application.Current;
        public static string Version => "0.1.0";

        protected override async void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // One Ovira at a time.
            _single = new Mutex(true, "Ovira.Windows.Single", out var first);
            if (!first)
            {
                Shutdown();
                return;
            }

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

            Settings.Load();
            var firstRun = !System.IO.File.Exists(System.IO.Path.Combine(Settings.Folder, "settings.json"));
            if (Settings.Current.StartWithWindows) Autostart.Apply(true);

            Audio.Start();
            Power.Start();
            _island = new IslandWindow(Media, Audio, Power);
            _island.Show();
            _island.Begin();
            await Media.StartAsync();

            SetUpTray();
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
            Shutdown();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
            base.OnExit(e);
        }
    }
}
