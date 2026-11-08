using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Ovira.Core;

namespace Ovira.SettingsUi
{
    public partial class SettingsWindow : Window
    {
        private sealed record Page(string Key, string Title, string Subtitle, Color Colour, StackPanel Panel);
        private readonly Page[] _pages;

        public SettingsWindow()
        {
            InitializeComponent();
            DataContext = Settings.Current;
            VersionText.Text = "Версия " + App.Version + " для Windows";

            _pages = new[]
            {
                new Page("general", "Основные", "Запуск, обслуживание и сброс", Color.FromRgb(0x8E, 0x8E, 0x93), PageGeneral),
                new Page("island", "Островок", "Как открывается, размер и где прячется", Color.FromRgb(0x34, 0x78, 0xF6), PageIsland),
                new Page("media", "Медиаплеер", "Любая музыка и видео в Windows — прямо в островке", Color.FromRgb(0xFF, 0x45, 0x66), PageMedia),
                new Page("banners", "Уведомления", "Громкость, зарядка и звук — короткие баннеры в островке", Color.FromRgb(0xFF, 0x45, 0x3A), PageBanners),
                new Page("about", "О программе", "Что уже есть и что будет дальше", Color.FromRgb(0x30, 0xB0, 0xC7), PageAbout),
            };

            SourceInitialized += (_, _) =>
            {
                try { Native.DarkTitleBar(new WindowInteropHelper(this).Handle); } catch { }
            };

            var app = App.Current;
            Action<Services.TrackInfo?> onTrack = _ => Dispatcher.BeginInvoke(new Action(UpdatePreview));
            app.Media.Changed += onTrack;
            Closed += (_, _) => app.Media.Changed -= onTrack;
            UpdateScaleText();

            var start = Settings.Current.Section;
            var nav = start switch
            {
                "general" => NavGeneral,
                "media" => NavMedia,
                "banners" => NavBanners,
                "about" => NavAbout,
                _ => NavIsland
            };
            nav.IsChecked = true;
            ShowPage(start, animated: false);
        }

        private void OnNav(object sender, RoutedEventArgs e)
        {
            if (_pages == null) return;
            string key = sender == NavGeneral ? "general" : sender == NavMedia ? "media" :
                         sender == NavBanners ? "banners" : sender == NavAbout ? "about" : "island";
            Settings.Current.Section = key;
            ShowPage(key, animated: true);
        }

        private void ShowPage(string key, bool animated)
        {
            if (_pages == null) return;
            Page? current = null;
            foreach (var p in _pages)
            {
                bool on = p.Key == key;
                p.Panel.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
                if (on) current = p;
            }
            current ??= _pages[1];
            current.Panel.Visibility = Visibility.Visible;
            HeroTitle.Text = current.Title;
            HeroSubtitle.Text = current.Subtitle;
            var a = current.Colour;
            var b = Color.FromArgb(0x99, a.R, a.G, a.B);
            if (animated)
            {
                var d = TimeSpan.FromSeconds(0.35);
                HeroColorA.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(a, d));
                HeroColorB.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(b, d));
                current.Panel.Opacity = 0;
                current.Panel.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.25)));
            }
            else
            {
                HeroColorA.Color = a;
                HeroColorB.Color = b;
            }
            UpdatePreview();
        }

        // The little island in the header acts out the current section.
        private void UpdatePreview()
        {
            var key = Settings.Current.Section;
            var track = App.Current.Media.Track;
            PreviewArtBox.Visibility = Visibility.Collapsed;
            PreviewIcon.Visibility = Visibility.Collapsed;
            PreviewRight.Text = "";
            switch (key)
            {
                case "banners":
                    PreviewIcon.Visibility = Visibility.Visible;
                    PreviewIcon.Text = "";
                    PreviewIcon.Foreground = new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59));
                    PreviewText.Text = "Зарядка · 76 %";
                    break;
                case "general":
                case "about":
                    PreviewIcon.Visibility = Visibility.Visible;
                    PreviewIcon.Text = "";
                    PreviewIcon.Foreground = Brushes.White;
                    PreviewText.Text = "Ovira " + App.Version;
                    break;
                default:
                    PreviewArtBox.Visibility = Visibility.Visible;
                    PreviewArt.Source = track?.Artwork;
                    PreviewText.Text = track?.Title ?? "Ничего не играет";
                    PreviewRight.Text = track?.Playing == true ? " ▮▮" : "";
                    PreviewRight.Foreground = track != null ? new SolidColorBrush(track.Tint) : Brushes.White;
                    break;
            }
            PreviewPill.Width = 190 * Settings.Current.IslandScale;
        }

        private void OnScaleChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            UpdateScaleText();
            if (IsLoaded) UpdatePreview();
        }

        private void UpdateScaleText()
        {
            if (ScaleText != null) ScaleText.Text = $"{Math.Round(Settings.Current.IslandScale * 100)} %";
        }

        private void OnOpenFolder(object sender, RoutedEventArgs e)
        {
            try
            {
                System.IO.Directory.CreateDirectory(Settings.Folder);
                Process.Start(new ProcessStartInfo("explorer.exe", "\"" + Settings.Folder + "\"") { UseShellExecute = true });
            }
            catch { }
        }

        private void OnReset(object sender, RoutedEventArgs e)
        {
            var answer = MessageBox.Show(this, "Вернуть все настройки Ovira как после установки?", "Ovira",
                                         MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (answer == MessageBoxResult.OK) Settings.Current.ResetAll();
        }

        private void OnQuit(object sender, RoutedEventArgs e) => App.Current.Quit();

        private void OnDemoOpen(object sender, RoutedEventArgs e) => App.Current.IslandWindow?.DemoOpen();
        private void OnDemoVolume(object sender, RoutedEventArgs e) => App.Current.IslandWindow?.DemoVolume();
        private void OnDemoCharging(object sender, RoutedEventArgs e) => App.Current.IslandWindow?.DemoCharging();
        private void OnDemoLow(object sender, RoutedEventArgs e) => App.Current.IslandWindow?.DemoLowBattery();
        private void OnDemoOutput(object sender, RoutedEventArgs e) => App.Current.IslandWindow?.DemoOutput();
    }
}
