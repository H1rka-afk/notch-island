using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace Ovira.Core
{
    // All settings in one place, saved as JSON in %APPDATA%\Ovira\settings.json
    // a moment after any change. The windows bind to these properties.
    public sealed class Settings : INotifyPropertyChanged
    {
        public static Settings Current { get; private set; } = new Settings();

        public static string Folder =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Ovira");
        private static string FilePath => Path.Combine(Folder, "settings.json");

        public event PropertyChangedEventHandler? PropertyChanged;
        private DispatcherTimer? _saveTimer;
        private static bool s_loading;

        // Island
        private bool _openOnClick = true;
        public bool OpenOnClick { get => _openOnClick; set => Set(ref _openOnClick, value, nameof(OpenOnHover)); }
        [JsonIgnore]
        public bool OpenOnHover { get => !_openOnClick; set => OpenOnClick = !value; }

        private double _islandScale = 1.0;
        public double IslandScale { get => _islandScale; set => Set(ref _islandScale, Math.Clamp(value, 0.85, 1.15)); }

        private bool _showIdlePill = true;
        public bool ShowIdlePill { get => _showIdlePill; set => Set(ref _showIdlePill, value); }

        private bool _hideInFullscreen = true;
        public bool HideInFullscreen { get => _hideInFullscreen; set => Set(ref _hideInFullscreen, value); }

        private bool _hoverPeek = true;
        public bool HoverPeek { get => _hoverPeek; set => Set(ref _hoverPeek, value); }

        // Media
        private bool _showMedia = true;
        public bool ShowMedia { get => _showMedia; set => Set(ref _showMedia, value); }

        private bool _compactTitle = true;
        public bool CompactTitle { get => _compactTitle; set => Set(ref _compactTitle, value); }

        private bool _liveBars = true;
        public bool LiveBars { get => _liveBars; set => Set(ref _liveBars, value); }

        private bool _outputPicker = true;
        public bool OutputPicker { get => _outputPicker; set => Set(ref _outputPicker, value); }

        // Banners
        private bool _volumeBanner = true;
        public bool VolumeBanner { get => _volumeBanner; set => Set(ref _volumeBanner, value); }

        private bool _chargingBanner = true;
        public bool ChargingBanner { get => _chargingBanner; set => Set(ref _chargingBanner, value); }

        private bool _lowBatteryBanner = true;
        public bool LowBatteryBanner { get => _lowBatteryBanner; set => Set(ref _lowBatteryBanner, value); }

        private bool _outputBanner = true;
        public bool OutputBanner { get => _outputBanner; set => Set(ref _outputBanner, value); }

        // General
        private bool _startWithWindows = true;
        public bool StartWithWindows
        {
            get => _startWithWindows;
            set { if (Set(ref _startWithWindows, value) && !s_loading) Autostart.Apply(value); }
        }

        [JsonIgnore] public bool IsLoading => s_loading;

        private string _section = "island";
        public string Section { get => _section; set => Set(ref _section, value); }

        private bool Set<T>(ref T field, T value, string? alsoChanged = null, [CallerMemberName] string? name = null)
        {
            if (Equals(field, value)) return false;
            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
            if (alsoChanged != null) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(alsoChanged));
            if (!s_loading) ScheduleSave();
            return true;
        }

        private void ScheduleSave()
        {
            if (_saveTimer == null)
            {
                _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.6) };
                _saveTimer.Tick += (_, _) => { _saveTimer!.Stop(); Save(); };
            }
            _saveTimer.Stop();
            _saveTimer.Start();
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Folder);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { /* a read-only profile must not crash the island */ }
        }

        public static void Load()
        {
            s_loading = true;
            try
            {
                if (File.Exists(FilePath))
                {
                    var loaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath));
                    if (loaded != null) { Current = loaded; }
                }
            }
            catch { Current = new Settings(); }
            s_loading = false;
        }

        public void ResetAll()
        {
            var fresh = new Settings();
            foreach (var p in typeof(Settings).GetProperties())
            {
                if (p.CanWrite && p.CanRead && p.Name != nameof(Section) && p.Name != nameof(OpenOnHover))
                    p.SetValue(this, p.GetValue(fresh));
            }
        }

    }
}
