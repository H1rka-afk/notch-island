using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.SettingsUi
{
    // 0.4.0: profiles, themes and the theme editor live in the
    // SettingsWindow.Profiles.cs and SettingsWindow.Themes.cs parts.
    // 0.3.0 — Settings ported from the Mac (NotchSettingsWindow.swift):
    // a top bar (Ovira or «‹ Все настройки», search, the live island), a home
    // screen with a stage where the island acts out the tile under the
    // pointer and a bento grid of bright tiles, and per section a glossy
    // banner with UPPERCASE groups on glass cards. Living colour background.
    public partial class SettingsWindow : Window
    {
        private sealed record Section(string Key, string Title, string Subtitle, string Status, string Icon, Color Colour, string Demo)
        {
            public Color Accent => AccentFor(this);
        }

        private sealed record Entry(string Section, string Title, string Keywords);

        private static readonly Section[] Sections =
        {
            new("general", "Основные", "Оформление, обновления и запуск", "Темы и обновления", "gear", Color.FromRgb(0x8C, 0x8F, 0x99), "ovira"),
            new("profiles", "Профили", "Готовые наборы функций и свои профили", "iPhone, Тихий, Максимум", "stack", Color.FromRgb(0x5C, 0x59, 0xE6), "music"),
            new("island", "Островок", "Вид, размер и поведение островка", "Открытие и размер", "laptop", Color.FromRgb(0x33, 0x7A, 0xFF), "music"),
            new("media", "Медиаплеер", "Плеер, звук и обложки", "Любая музыка в Windows", "play", Color.FromRgb(0xFF, 0x45, 0x66), "music"),
            new("spectrum", "Спектрограмма", "Шесть полосок по настоящему звуку: вид, размытие и плавность", "Обложка, размытие, кадры", "waveform", Color.FromRgb(0xA8, 0x5C, 0xF2), "music"),
            new("notifications", "Уведомления", "Громкость, звук и клавиатура — короткие баннеры в островке", "Громкость, Caps Lock, раскладка", "bell", Color.FromRgb(0xFF, 0x45, 0x3A), "volume"),
            new("devices", "Устройства", "Батарея и зарядка ноутбука", "Зарядка и низкий заряд", "bolt", Color.FromRgb(0x33, 0xBF, 0x59), "charging"),
            new("stats", "Статистика", "Твой день за компьютером: работа, музыка, перерывы", "Сегодня и неделя", "chart", Color.FromRgb(0x1A, 0xB8, 0x9E), "music"),
            new("clock", "Часы", "Таймер, секундомер и будильник", "Таймер, будильник", "timer", Color.FromRgb(0xFF, 0x9F, 0x0A), "timer"),
            new("helper", "Помощник", "Отдых для глаз по правилу 20-20-20", "Отдых для глаз", "eye", Color.FromRgb(0x26, 0xB5, 0xC9), "eye"),
        };

        private readonly List<Entry> _entries = new();
        private readonly Dictionary<string, FrameworkElement> _rows = new();
        private Section? _current;              // null = home
        private Section? _hovered;
        private Settings S => Settings.Current;
        private static Section Find(string key) => Sections.First(s => s.Key == key);

        public SettingsWindow()
        {
            InitializeComponent();
            VersionText.Text = "Версия " + App.Version + " · Windows";
            SourceInitialized += (_, _) =>
            {
                try { Native.DarkTitleBar(new WindowInteropHelper(this).Handle, _theme?.IsDark ?? true); } catch { }
            };
            foreach (var section in Sections) BuildPage(section, collectOnly: true);
            CacheStatic(Stage);
            CacheStatic(Hero);
            Loaded += (_, _) => UpdateCacheScale();
            DpiChanged += (_, _) => UpdateCacheScale();
            StartAurora();
            ApplyTheme();

            var app = App.Current;
            // 0.4.16: after the island's own work and its animations (low priority).
            Action<TrackInfo?> onTrack = _ => Dispatcher.BeginInvoke(new Action(() => { ShowTrack(); TintAurora(); CoverChanged(); }),
                                                                     DispatcherPriority.Background);
            app.Media.Changed += onTrack;
            S.PropertyChanged += OnSettingChanged;
            Action statsChanged = () => Dispatcher.BeginInvoke(new Action(RefreshStatsTile), DispatcherPriority.Background);
            app.Stats.Changed += statsChanged;
            Closed += (_, _) => app.Stats.Changed -= statsChanged;
            Action updates = () => Dispatcher.BeginInvoke(new Action(ShowUpdateState));
            app.Updates.Changed += updates;
            Closed += (_, _) => { app.Media.Changed -= onTrack; app.Updates.Changed -= updates; S.PropertyChanged -= OnSettingChanged; _stageTimer.Stop(); _stageCycle.Stop(); };
            KeyDown += (_, e) => { if (e.Key == Key.Escape && _current != null) GoHome(); };

            ShowTrack();
            ShowUpdateCard();
            Stage.SizeChanged += (_, _) => DrawStage();
            _stageTimer.Tick += (_, _) => StageTick();
            _stageCycle.Tick += (_, _) => { if (_hovered == null && HomeView.Visibility == Visibility.Visible && WindowState != WindowState.Minimized) { _stageStep++; UpdateStage(); } };
            _stageCycle.Start();
            var start = Sections.FirstOrDefault(s => s.Key == S.Section);
            if (start != null && S.Section != "home") Open(start, animated: false); else GoHome(animated: false);
        }

        private void OnSettingChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(Settings.Section)) return;
            if (e.PropertyName is nameof(Settings.Theme) or nameof(Settings.CustomThemes))
            {
                CrossFade(ApplyTheme);
                return;
            }
            if (e.PropertyName == nameof(Settings.AnimatedBackground)) UpdateAuroraClock();
            if (e.PropertyName == nameof(Settings.StatsEnabled)) { FillStats(); _statsTileKey = ""; if (_current == null) RefreshStatsTile(); }
            if (e.PropertyName == nameof(Settings.IslandStyle)) DrawStage();
            if (e.PropertyName == nameof(Settings.SavedTracks)) FillSaved();
            if (_current?.Key == "profiles") ScheduleProfiles();
        }

        // ================================================================ navigation

        private void GoHome(bool animated = true)
        {
            _current = null;
            S.Section = "home";
            Resources["SectionAccent"] = new SolidColorBrush(AccentFor(Sections[0]));
            HomeHeader.Visibility = Visibility.Visible;
            BackButton.Visibility = Visibility.Collapsed;
            DetailView.Visibility = Visibility.Collapsed;
            HomeView.Visibility = Visibility.Visible;
            if (animated) Appear(HomeView, 1.03);
            TintAurora();
            UpdateStage();
        }

        private void OnBack(object sender, MouseButtonEventArgs e) => GoHome();

        private void Open(Section section, bool animated)
        {
            _current = section;
            S.Section = section.Key;
            SearchBox.Text = "";
            HomeHeader.Visibility = Visibility.Collapsed;
            BackButton.Visibility = Visibility.Visible;
            ColourSection(section);
            HeroTitle.Text = section.Title;
            HeroSubtitle.Text = section.Subtitle;

            PageHost.Children.Clear();
            _rows.Clear();
            PageHost.Children.Add(BuildPage(section, collectOnly: false)!);
            HomeView.Visibility = Visibility.Collapsed;
            DetailView.Visibility = Visibility.Visible;
            DetailView.ScrollToTop();
            if (animated) Appear(DetailView, 0.94);
            TintAurora();
        }

        private void ColourSection(Section section)
        {
            var a = section.Accent;
            Resources["SectionAccent"] = new SolidColorBrush(a);
            BackA.Color = Lighter(a, 25);
            BackB.Color = a;
            BackGlow.Color = a;
            HeroTileHost.Child = IconTile(section.Icon, a, 60);
            HeroA.Color = Color.FromArgb(0xEB, a.R, a.G, a.B);
            HeroB.Color = Color.FromArgb(0x8C, a.R, a.G, a.B);
            HeroGlow.Color = a;
        }

        private static void Appear(FrameworkElement view, double fromScale)
        {
            view.Opacity = 0;
            var scale = new ScaleTransform(fromScale, fromScale);
            view.RenderTransform = scale;
            view.RenderTransformOrigin = new Point(0.5, 0.1);
            var d = TimeSpan.FromSeconds(0.42);
            var spring = new ElasticEase { Oscillations = 1, Springiness = 9, EasingMode = EasingMode.EaseOut };
            view.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.28)));
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, d) { EasingFunction = spring });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, d) { EasingFunction = spring });
        }

        // ================================================================ home tiles

        private void BuildTiles()
        {
            Tiles.Children.Clear();
            var nowPlaying = NowPlayingTile();
            Grid.SetColumnSpan(nowPlaying, 2);
            Tiles.Children.Add(nowPlaying);
            Place(Tile(Find("general")), 0, 2);
            Place(Tile(Find("profiles")), 0, 3);
            Place(Tile(Find("island")), 1, 0);
            Place(Tile(Find("media")), 1, 1);
            Place(Tile(Find("spectrum")), 1, 2);
            Place(Tile(Find("notifications")), 1, 3);
            Place(Tile(Find("devices")), 2, 0);
            Place(Tile(Find("helper")), 2, 1);
            Place(Tile(Find("clock")), 2, 2);
            Place(ThemeTile(), 2, 3);
            var stats = StatsTile();
            Grid.SetColumnSpan(stats, 4);
            Place(stats, 3, 0);
        }

        // 0.4.12: each tile (with its glow) is kept as a ready picture. The
        // living background behind it changes 24 times a second; without the
        // picture every tile, shadow and text was drawn again each time.
        private void Place(FrameworkElement tile, int row, int column)
        {
            var host = new Grid { CacheMode = NewCache() };
            Grid.SetColumnSpan(host, Grid.GetColumnSpan(tile));
            host.Children.Add(tile);
            Grid.SetRow(host, row);
            Grid.SetColumn(host, column);
            Tiles.Children.Add(host);
        }

        private double _dpiScale = 1;
        private BitmapCache NewCache() => new BitmapCache { RenderAtScale = _dpiScale, SnapsToDevicePixels = true };

        // The stage and the section header get the same treatment once.
        private void CacheStatic(FrameworkElement element)
        {
            if (element.Parent is not Panel parent) return;
            int index = parent.Children.IndexOf(element);
            parent.Children.RemoveAt(index);
            var host = new Grid { CacheMode = NewCache(), Margin = element.Margin, VerticalAlignment = element.VerticalAlignment };
            element.Margin = new Thickness(0);
            host.Children.Add(element);
            parent.Children.Insert(index, host);
        }

        private void UpdateCacheScale()
        {
            var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            if (Math.Abs(scale - _dpiScale) < 0.01) return;
            _dpiScale = scale;
            foreach (var host in new FrameworkElement?[] { Stage.Parent as FrameworkElement, Hero.Parent as FrameworkElement })
                if (host?.CacheMode is BitmapCache cache) host.CacheMode = NewCache();
            BuildTiles();
            ShowTrack();
        }

        // A bright tile: circle icon at the top, title and status at the bottom
        // (the status wraps to two lines and never spills out). Light follows
        // the pointer, the tile lifts a little and glows in its colour.
        private FrameworkElement Tile(Section section) =>
            TileCore(section.Title, section.Status, section.Icon, section.Accent, null,
                     () => { _hovered = section; UpdateStage(); },
                     () => { if (_hovered == section) { _hovered = null; UpdateStage(); } },
                     () => Open(section, animated: true));

        private FrameworkElement TileCore(string title, string status, string icon, Color c, Brush? background,
                                          Action enter, Action leave, Action click, FrameworkElement? extra = null)
        {
            var shape = new CornerRadius(22);
            var light = new RadialGradientBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF))
            {
                Center = new Point(0.15, 0.1), GradientOrigin = new Point(0.15, 0.1), RadiusX = 0.8, RadiusY = 0.9
            };
            var content = new Grid();
            content.Children.Add(new Border { CornerRadius = shape, Background = background ?? new LinearGradientBrush(Color.FromArgb(0xFA, c.R, c.G, c.B), Color.FromArgb(0xA8, c.R, c.G, c.B), 45) });
            content.Children.Add(new Border { CornerRadius = shape, Background = Gloss(0x2E) });
            content.Children.Add(new Border { CornerRadius = shape, Background = light });

            var inner = new Grid { Margin = new Thickness(14, 14, 14, 12) };
            var circle = new Grid { Width = 38, Height = 38, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            circle.Children.Add(new Border { CornerRadius = new CornerRadius(19), Background = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)) });
            circle.Children.Add(new IconView { Icon = icon, Width = 18, Height = 18 });
            inner.Children.Add(circle);
            if (extra != null)
            {
                extra.HorizontalAlignment = HorizontalAlignment.Right;
                extra.VerticalAlignment = VerticalAlignment.Top;
                inner.Children.Add(extra);
            }
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
            text.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.Black, FontFamily = DisplayFont, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock
            {
                Text = status, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Color.FromArgb(0xD6, 0xFF, 0xFF, 0xFF)),
                Margin = new Thickness(0, 2, 0, 0), TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                MaxHeight = 30, LineHeight = 14.5, LineStackingStrategy = LineStackingStrategy.BlockLineHeight
            });
            inner.Children.Add(text);
            content.Children.Add(inner);

            var tile = new Border
            {
                CornerRadius = shape,
                Margin = new Thickness(7),
                Child = content,
                Cursor = Cursors.Hand,
                BorderThickness = new Thickness(1),
                BorderBrush = new LinearGradientBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF), Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF), 90),
                RenderTransformOrigin = new Point(0.5, 0.5),
                RenderTransform = new ScaleTransform(1, 1),
                Effect = new DropShadowEffect { Color = c, BlurRadius = 10, ShadowDepth = 4, Direction = 270, Opacity = 0.3 }
            };
            TextElement.SetForeground(tile, Brushes.White);
            Hover(tile, light, c, enter, leave);
            tile.MouseLeftButtonUp += (_, _) => click();
            return tile;
        }

        // Wide tile: the current theme and a strip of the others.
        private FrameworkElement ThemeTile()
        {
            var t = _theme ?? Themes.Find(S.Theme, CoverTint);
            var all = Themes.All(CoverTint);
            var colours = t.Palette.Length > 0 ? t.Palette.Take(3).ToList() : t.Preview.ToList();
            var accent = colours[0];
            var bg = new LinearGradientBrush(new GradientStopCollection(colours.Select((c, i) =>
                new GradientStop(Color.FromArgb(0xF2, c.R, c.G, c.B), colours.Count == 1 ? 0 : (double)i / (colours.Count - 1)))), 20);
            if (IsLight(accent))
                bg = new LinearGradientBrush(new GradientStopCollection(colours.Select((c, i) =>
                    new GradientStop(Themes.Scale(c, 0.62), colours.Count == 1 ? 0 : (double)i / (colours.Count - 1)))), 20);
            var strip = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var other in all.Take(3))
            {
                var dot = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Margin = new Thickness(4, 0, 0, 0), Background = PreviewBrush(other.Preview),
                                       BorderThickness = new Thickness(other.Id == t.Id ? 2 : 1), BorderBrush = new SolidColorBrush(Color.FromArgb(other.Id == t.Id ? (byte)0xFF : (byte)0x66, 0xFF, 0xFF, 0xFF)) };
                strip.Children.Add(dot);
            }
            int custom = S.CustomThemes.Count;
            var status = "Тема «" + t.Name + "» · " + (custom == 0 ? "можно создать свою" : "своих: " + custom);
            return TileCore("Оформление", status, "palette", accent, bg,
                            () => { _hovered = Find("general"); UpdateStage(); },
                            () => { _hovered = null; UpdateStage(); },
                            () =>
                            {
                                Open(Find("general"), animated: true);
                                Dispatcher.BeginInvoke(new Action(() => Highlight("Тема")), DispatcherPriority.Loaded);
                            }, strip);
        }

        private static void Hover(Border tile, RadialGradientBrush light, Color c, Action enter, Action leave)
        {
            var scale = (ScaleTransform)tile.RenderTransform;
            var shadow = (DropShadowEffect)tile.Effect;
            void To(double s, double glow, double blur)
            {
                var d = TimeSpan.FromSeconds(0.28);
                var ease = new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut };
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(s, d) { EasingFunction = ease });
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(s, d) { EasingFunction = ease });
                shadow.BeginAnimation(DropShadowEffect.OpacityProperty, new DoubleAnimation(glow, d));
                shadow.BeginAnimation(DropShadowEffect.BlurRadiusProperty, new DoubleAnimation(blur, d));
            }
            tile.MouseEnter += (_, _) => { To(1.035, 0.55, 18); enter(); };
            tile.MouseLeave += (_, _) =>
            {
                To(1, 0.3, 10);
                light.Center = light.GradientOrigin = new Point(0.15, 0.1);
                light.GradientStops[0].Color = Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF);
                leave();
            };
            tile.MouseMove += (_, e) =>
            {
                var p = e.GetPosition(tile);
                if (tile.ActualWidth <= 0 || tile.ActualHeight <= 0) return;
                var u = new Point(Math.Clamp(p.X / tile.ActualWidth, 0, 1), Math.Clamp(p.Y / tile.ActualHeight, 0, 1));
                light.Center = light.GradientOrigin = u;
                light.GradientStops[0].Color = Color.FromArgb(0x61, 0xFF, 0xFF, 0xFF);
            };
        }

        private Border? _npArt;
        private TextBlock? _npLabel, _npTitle, _npArtist;
        private Border? _npBack, _npBlur;
        private DropShadowEffect? _npShadow;

        // Wide tile: what plays right now, on its own blurred cover.
        private FrameworkElement NowPlayingTile()
        {
            var shape = new CornerRadius(24);
            _npBack = new Border { CornerRadius = shape };
            _npBlur = new Border { CornerRadius = shape, Opacity = 0.55, Effect = new BlurEffect { Radius = 30 } };
            var grid = new Grid();
            grid.Children.Add(_npBack);
            grid.Children.Add(_npBlur);
            grid.Children.Add(new Border { CornerRadius = shape, Background = Gloss(0x2E) });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16), VerticalAlignment = VerticalAlignment.Center };
            _npArt = new Border { Width = 84, Height = 84, CornerRadius = new CornerRadius(16), Background = new SolidColorBrush(Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF)),
                                  Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Direction = 270, Opacity = 0.3 } };
            row.Children.Add(_npArt);
            var text = new StackPanel { Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, MaxWidth = 230 };
            _npLabel = new TextBlock { FontSize = 10, FontWeight = FontWeights.Black, Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)) };
            _npTitle = new TextBlock { FontSize = 19, FontWeight = FontWeights.Black, FontFamily = DisplayFont, Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
            _npArtist = new TextBlock { FontSize = 12, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
            text.Children.Add(_npLabel); text.Children.Add(_npTitle); text.Children.Add(_npArtist);
            row.Children.Add(text);
            grid.Children.Add(row);
            _npShadow = new DropShadowEffect { BlurRadius = 12, ShadowDepth = 5, Direction = 270, Opacity = 0.4 };
            var tile = new Border
            {
                CornerRadius = shape, Margin = new Thickness(7), Child = grid, Cursor = Cursors.Hand, ClipToBounds = true,
                BorderThickness = new Thickness(1), BorderBrush = new SolidColorBrush(Color.FromArgb(0x47, 0xFF, 0xFF, 0xFF)),
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(1, 1), Effect = _npShadow
            };
            var light = new RadialGradientBrush(Color.FromArgb(0, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF));
            TextElement.SetForeground(tile, Brushes.White);
            Hover(tile, light, Colors.White, () => { _hovered = Find("media"); UpdateStage(); }, () => { _hovered = null; UpdateStage(); });
            tile.MouseLeftButtonUp += (_, _) => Open(Find("media"), animated: true);
            return tile;
        }

        // The track everywhere: the wide tile, the island in the top bar, the stage.
        private void ShowTrack()
        {
            var t = App.Current.Media.Track;
            var tint = t?.Tint ?? Color.FromRgb(0x5C, 0x59, 0xE6);
            if (_npArt != null && _npLabel != null && _npTitle != null && _npArtist != null && _npBack != null && _npBlur != null && _npShadow != null)
            {
                _npArt.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : new SolidColorBrush(Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF));
                _npLabel.Text = t == null ? "ТИШИНА" : (t.Playing ? "СЕЙЧАС ИГРАЕТ" : "НА ПАУЗЕ");
                _npTitle.Text = t?.Title ?? "Островок ждёт музыку";
                _npArtist.Text = t?.Artist ?? "Включи что-нибудь — плеер появится вверху экрана";
                _npBack.Background = new LinearGradientBrush(Color.FromArgb(0xF2, tint.R, tint.G, tint.B), Color.FromArgb(0xBF, 0, 0, 0), 45);
                _npBlur.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : null;
                _npShadow.Color = tint;
            }
            TopArt.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : new SolidColorBrush(Color.FromArgb(0x99, tint.R, tint.G, tint.B));
            TopTitle.Text = t?.Title ?? "Островок ждёт";
            TopArtist.Text = t?.Artist ?? "";
            TopArtist.Visibility = t == null ? Visibility.Collapsed : Visibility.Visible;
            TopBars.Visibility = t == null ? Visibility.Collapsed : Visibility.Visible;
            TopBars.Playing = t?.Playing == true;
            TopBars.SetCover(t?.Artwork, tint);
            StageBars.Playing = t?.Playing == true;
            StageBars.SetCover(t?.Artwork, tint);
            UpdateStage();
        }

        // ================================================================ the stage

        private readonly DispatcherTimer _stageTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        private readonly Spring _sw = new Spring(255);
        private int _stageStep;
        // 0.4.2: frames only while the island on the stage moves; the scenes
        // change on their own slow clock.
        private readonly DispatcherTimer _stageCycle = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.6) };
        private readonly System.Diagnostics.Stopwatch _stageWatch = System.Diagnostics.Stopwatch.StartNew();
        private double _stageLast;

        // 0.4.9: like real life — music, a banner, music again, the next
        // banner… so the island grows and shrinks between them.
        private static readonly string[] Cycle =
            { "music", "volume", "music", "charging", "music", "eye", "music", "keyboard", "music", "output" };

        private string StageScene() => _hovered?.Demo ?? Cycle[_stageStep % Cycle.Length];

        private string? _stageShown;

        private void UpdateStage()
        {
            if (StageText == null) return;
            var scene = StageScene();
            var t = App.Current.Media.Track;
            bool music = scene == "music";
            string caption, word = "";
            string icon = "sparkles";
            Color colour = Colors.White;
            double? level = null;
            switch (scene)
            {
                case "music":
                    StageArt.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : new SolidColorBrush(Color.FromRgb(0x2A, 0x2A, 0x2A));
                    caption = "Сейчас играет — обложка и полоски в такт музыке";
                    break;
                case "volume":
                    icon = "speaker.wave"; level = 0.6;
                    caption = "Громкость — полоска справа";
                    break;
                case "charging":
                    icon = "bolt"; colour = Color.FromRgb(0x34, 0xC7, 0x59); word = "76 %";
                    caption = "Зарядка — молния и процент";
                    break;
                case "timer":
                    icon = "timer"; colour = Color.FromRgb(0xFF, 0x9F, 0x0A); word = "4:59";
                    caption = "Таймер, секундомер и будильник — время справа в островке";
                    break;
                case "eye":
                    icon = "eye"; colour = Color.FromRgb(0x40, 0xCC, 0xD9); word = "Вдаль";
                    caption = "Помощник — 20 секунд отдыха для глаз";
                    break;
                case "keyboard":
                    icon = "keyboard"; word = KeyboardWord();
                    caption = "Раскладка и Caps Lock";
                    break;
                case "output":
                    icon = "headphones"; colour = Color.FromRgb(0x4C, 0x8D, 0xFF); word = "Наушники";
                    caption = "Звук переключился — островок покажет куда";
                    break;
                default:
                    icon = "sparkles"; word = App.Version;
                    caption = "Островок вверху экрана — как на Mac";
                    break;
            }

            bool changed = _stageShown != scene;
            bool wasMusic = _stageShown == null || _stageShown == "music";
            _stageShown = scene;

            if (changed)
            {
                // Contents: the old ones are gone at once, the new ones come in
                // a beat later from slightly smaller and transparent — the
                // island's own animation.
                StageArt.Visibility = music ? Visibility.Visible : Visibility.Collapsed;
                StageBars.Visibility = music ? Visibility.Visible : Visibility.Collapsed;
                StageIcon.Visibility = music ? Visibility.Collapsed : Visibility.Visible;
                StageText.Visibility = word.Length > 0 && !music ? Visibility.Visible : Visibility.Collapsed;
                StageLevel.Visibility = level.HasValue ? Visibility.Visible : Visibility.Collapsed;
                StageIcon.Icon = icon;
                StageIcon.Fill = new SolidColorBrush(colour);
                StageText.Text = word;
                ArriveStage(StageContent);
                if (level.HasValue)
                {
                    StageLevelFill.Background = new SolidColorBrush(colour);
                    StageLevelScale.BeginAnimation(ScaleTransform.ScaleXProperty,
                        new DoubleAnimation(0, level.Value, TimeSpan.FromSeconds(0.6)) { BeginTime = TimeSpan.FromSeconds(0.12), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
                }
                FadeCaption(caption);
            }

            double width = music ? 255 : 305;   // the island's compact and banner widths
            bool growing = width * S.IslandScale > _sw.Target + 0.5 || (!music && wasMusic);
            _sw.To(width * S.IslandScale, growing ? Motion.GrowResponse : Motion.ShrinkResponse, growing ? Motion.GrowDamping : Motion.ShrinkDamping);
            if (!_stageTimer.IsEnabled) { _stageLast = _stageWatch.Elapsed.TotalSeconds; _stageTimer.Start(); }
            var accent = _hovered?.Accent ?? Color.FromRgb(0x5C, 0x59, 0xE6);
            var d = TimeSpan.FromSeconds(0.5);
            StageA.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(Color.FromArgb(0xD9, accent.R, accent.G, accent.B), d));
            StageGlow.BeginAnimation(DropShadowEffect.ColorProperty, new ColorAnimation(accent, d));
            var tint = t?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);
            StageTintColor.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(Color.FromArgb(0x99, tint.R, tint.G, tint.B), d));
        }

        private static string KeyboardWord()
        {
            var code = Ovira.Services.KeyboardWatch.CurrentLayout();
            return string.IsNullOrEmpty(code) ? "RU" : code;
        }

        private static void ArriveStage(FrameworkElement e)
        {
            e.RenderTransformOrigin = new Point(0.5, 0.5);
            if (e.RenderTransform is not ScaleTransform scale || scale.IsFrozen) { scale = new ScaleTransform(1, 1); e.RenderTransform = scale; }
            var fade = new DoubleAnimationUsingKeyFrames();
            fade.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            fade.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.08))));
            fade.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.34)), new CubicEase { EasingMode = EasingMode.EaseOut }));
            e.BeginAnimation(OpacityProperty, fade);
            var grow = new DoubleAnimationUsingKeyFrames();
            grow.KeyFrames.Add(new DiscreteDoubleKeyFrame(0.86, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            grow.KeyFrames.Add(new DiscreteDoubleKeyFrame(0.86, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.08))));
            grow.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.5)), new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut }));
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        }

        // The caption under the island changes softly, too.
        private void FadeCaption(string text)
        {
            if (StageCaption.Text == text) return;
            var fade = new DoubleAnimationUsingKeyFrames();
            fade.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.15))));
            fade.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.45)), new CubicEase { EasingMode = EasingMode.EaseOut }));
            var swap = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(0.15) };
            swap.Tick += (_, _) => { swap.Stop(); StageCaption.Text = text; };
            swap.Start();
            StageCaption.BeginAnimation(OpacityProperty, fade);
        }

        private void StageTick()
        {
            var now = _stageWatch.Elapsed.TotalSeconds;
            var dt = Math.Clamp(now - _stageLast, 0.001, 0.05);
            _stageLast = now;
            bool moving = _sw.Step(dt);
            DrawStage();
            if (!moving) _stageTimer.Stop();
        }

        private void DrawStage()
        {
            double width = Stage.ActualWidth;
            if (width <= 0) return;
            double w = _sw.Value, h = 35, r = 13, flare = 7, cx = width / 2;
            double l = cx - w / 2, rt = cx + w / 2;
            // 0.4.18: the iPhone style floats below the stage's edge as a capsule.
            bool floating = S.IslandStyle == "island";
            Canvas.SetTop(StageContent, floating ? 12 : 0);
            if (floating)
            {
                var pill = new RectangleGeometry(new Rect(l, 12, w, h), h / 2, h / 2);
                pill.Freeze();
                StageShape.Data = pill;
                StageCanvas.Clip = new RectangleGeometry(new Rect(0, 0, width, Stage.ActualHeight), 26, 26);
                StageContent.Width = Math.Max(0, w);
                Canvas.SetLeft(StageContent, l);
                return;
            }
            var g = new StreamGeometry();
            using (var ctx = g.Open())
            {
                ctx.BeginFigure(new Point(l - flare, 0), true, true);
                ctx.QuadraticBezierTo(new Point(l, 0), new Point(l, flare), true, true);
                ctx.LineTo(new Point(l, h - r), true, true);
                ctx.ArcTo(new Point(l + r, h), new Size(r, r), 0, false, SweepDirection.Counterclockwise, true, true);
                ctx.LineTo(new Point(rt - r, h), true, true);
                ctx.ArcTo(new Point(rt, h - r), new Size(r, r), 0, false, SweepDirection.Counterclockwise, true, true);
                ctx.LineTo(new Point(rt, flare), true, true);
                ctx.QuadraticBezierTo(new Point(rt, 0), new Point(rt + flare, 0), true, true);
            }
            g.Freeze();
            StageShape.Data = g;
            // 0.4.9: nothing may stick out of the stage — the island, its
            // flares and its shadow are cut to the stage's rounded frame.
            StageCanvas.Clip = new RectangleGeometry(new Rect(0, 0, width, Stage.ActualHeight), 26, 26);
            StageContent.Width = Math.Max(0, w);
            Canvas.SetLeft(StageContent, l);
        }

        // ================================================================ pages

        private FrameworkElement? BuildPage(Section section, bool collectOnly)
        {
            _collecting = collectOnly;
            _collectSection = section.Key;
            var page = new StackPanel();
            switch (section.Key)
            {
                case "general":
                    page.Children.Add(Group("Запуск", "Ovira добавляется в автозагрузку только для твоей учётной записи — права администратора не нужны. Это же переключатель есть в меню значка Ovira в области уведомлений и в Диспетчере задач → «Автозагрузка».",
                        ToggleRow("Запускать вместе с Windows", "Островок появляется сразу после входа в систему", nameof(Settings.StartWithWindows), "автозапуск автозагрузка старт вход запуск windows")));
                    page.Children.Add(Group("Оформление", "Темы те же, что у Ovira на Mac. «Обложка» берёт цвета играющей музыки. Своя тема — название, светлая или тёмная и 2–4 цвета.",
                        ThemeGroupContent(),
                        ToggleRow("Живой фон", "Цвета плавно перетекают друг в друга, как на Mac", nameof(Settings.AnimatedBackground), "фон живой анимация переливы цвета")));
                    page.Children.Add(Group("Обновления", "Ovira сама смотрит страницу выпусков на GitHub, скачивает новую версию в фоне и предлагает установить — в островке и в области уведомлений. Установка заменяет Ovira.exe в той же папке, права администратора не нужны.",
                        ToggleRow("Проверять обновления", null, nameof(Settings.CheckUpdates), "обновления проверять версия"),
                        SegmentRow("Как часто проверять", null, new (string, object)[] { ("1 ч", 1.0), ("3 ч", 3.0), ("6 ч", 6.0), ("День", 24.0), ("Неделя", 168.0) },
                                   nameof(Settings.UpdateIntervalHours), "интервал обновления часто проверка"),
                        ToggleRow("Устанавливать сами", "Скачанное обновление ставится без вопроса, когда островок свободен", nameof(Settings.AutoInstallUpdates), "автоматически установка обновления"),
                        UpdateStatusRow()));
                    page.Children.Add(Group("Обслуживание", "Ovira для Windows " + App.Version + ". Всё работает на самом компьютере и никуда не отправляется.",
                        ButtonRow("Папка настроек", "settings.json и журнал ошибок errors.log", "Открыть", OpenFolder, "папка журнал лог ошибки"),
                        ButtonRow("Сбросить все настройки", "Вернуть всё как после установки", "Сбросить", ResetAll, "сброс по умолчанию"),
                        ButtonRow("Выйти из Ovira", "Островок исчезнет до следующего запуска", "Выйти", () => App.Current.Quit(), "закрыть выход")));
                    page.Children.Add(Group("Версия для Windows", null,
                        TextRow("Что уже есть", "Островок с пружинными анимациями, медиаплеер для любой музыки, настоящая спектрограмма, громкость, вывод звука и зарядка."),
                        TextRow("Чего на Windows не будет", "Свой экран блокировки (Windows не пускает программы на экран входа) и отклик трекпада."),
                        TextRow("Дальше", "Такси и доставка с живыми активностями, таймер, исправление раскладки, полка файлов.")));
                    break;

                case "profiles":
                    page.Children.Add(ProfilesPage());
                    break;

                case "clock":
                    BuildClockPage(page);
                    break;

                case "stats":
                    BuildStatsPage(page);
                    break;

                case "helper":
                    page.Children.Add(Group("Отдых для глаз", "Считается только время за компьютером — клавиатура или мышь в последнюю минуту. Пять минут без компьютера — глаза уже отдохнули, счёт начинается заново. Во время звонка (заняты микрофон или камера) перерыв подождёт; поверх игры или видео на весь экран — тоже, если не включено «Поверх игр». Нажми на островок, чтобы пропустить перерыв.",
                        ToggleRow("Напоминать об отдыхе", "Островок попросит 20 секунд посмотреть вдаль", nameof(Settings.EyeBreak), "отдых глаза перерыв 20-20-20 помощник",
                                  () => App.Current.IslandWindow?.DemoEyeBreak()),
                        SegmentRow("Как часто", "Сколько работать до перерыва", new (string, object)[] { ("20 мин", 20), ("30 мин", 30), ("45 мин", 45), ("1 ч", 60) },
                                   nameof(Settings.EyeBreakMinutes), "интервал отдых минуты как часто"),
                        ToggleRow("Звук", "Тихий сигнал в начале и в конце перерыва", nameof(Settings.EyeBreakSound), "звук сигнал отдых"),
                        ToggleRow("Поверх игр", "Напоминать и в игре или видео на весь экран", nameof(Settings.GameEyeBreak), "игра полноэкранный поверх отдых глаза")));
                    break;

                case "island":
                    page.Children.Add(Group("Открытие", "При наведении островок раскрывается сам; по нажатию — только когда нажмёшь, а при наведении лишь чуть увеличивается.",
                        SegmentRow("Открывать плеер", null, new (string, object)[] { ("По нажатию", true), ("При наведении", false) }, nameof(Settings.OpenOnClick), "открытие клик наведение нажатие"),
                        ToggleRow("Откликаться на курсор", "Островок чуть увеличивается, когда наводишь на него", nameof(Settings.HoverPeek), "отклик курсор увеличение")));
                    page.Children.Add(Group("Вид", "«Вырез» прилегает к верхнему краю экрана, как на MacBook. «Как на iPhone» — отдельная капсула чуть ниже края, скруглённая со всех сторон, как Dynamic Island.",
                        SegmentRow("Стиль островка", null, new (string, object)[] { ("Вырез", "notch"), ("Как на iPhone", "island") }, nameof(Settings.IslandStyle),
                                   "стиль островка вырез notch айфон iphone dynamic island капсула отдельный"),
                        SliderRow("Размер островка", nameof(Settings.IslandScale), 0.85, 1.15, 0.05, "размер ширина больше меньше"),
                        ToggleRow("Капсула, когда ничего не играет", "Маленький чёрный островок вверху экрана всегда на месте", nameof(Settings.ShowIdlePill), "капсула пусто ничего"),
                        ToggleRow("Прятать в полноэкранном режиме", "Игры, видео на весь экран и презентации", nameof(Settings.HideInFullscreen), "полноэкранный игра видео презентация прятать")));
                    break;

                case "media":
                    page.Children.Add(Group("Плеер", "Spotify, Яндекс Музыка, браузер — всё, что Windows показывает в окне громкости.",
                        ToggleRow("Показывать медиаплеер", null, nameof(Settings.ShowMedia), "музыка плеер spotify яндекс"),
                        SegmentRow("Вид плеера", "Новый — большая обложка со свечением и громкость, как на Mac сейчас; классический — компактный, как раньше",
                                   new (string, object)[] { ("Новый", true), ("Классический", false) }, nameof(Settings.PlayerNew), "вид плеера новый классический старый островок"),
                        ToggleRow("Громкость в плеере", "Ползунок громкости под кнопками, как на Mac", nameof(Settings.VolumeRow), "громкость ползунок"),
                        ToggleRow("Выбор устройства вывода звука", "Кнопка в плеере: динамики, наушники, монитор", nameof(Settings.OutputPicker), "вывод звук наушники динамики устройство"),
                        ToggleRow("Живая обложка", "Обложка в раскрытом плеере медленно приближается и отдаляется, пока играет музыка", nameof(Settings.LivingCover), "живая анимированная обложка движение"),
                        ToggleRow("Кнопка «Сохранить»", "Звёздочка слева в плеере. В Яндекс Музыке — настоящее «Мне нравится», в остальных плеерах песня попадает в список ниже", nameof(Settings.SaveButton), "сохранить звезда избранное лайк нравится яндекс"),
                        ButtonRow("Открыть плеер", "Показать, как он выглядит прямо сейчас", "Показать", () => App.Current.IslandWindow?.DemoOpen(), "показать открыть плеер")));
                    page.Children.Add(YandexGroup());
                    page.Children.Add(SavedGroup());
                    break;

                case "spectrum":
                    page.Children.Add(Group("Движение", "«Как на iPhone» — снято по кадрам с записи экрана iPhone: первая полоска — бас, почти всегда высокая, вторая — самая тихая, остальные живут посередине; вверх и вниз с одной быстрой мягкой скоростью. «Точный спектр» — прежнее поведение: быстрый взлёт, медленное опадание.",
                        SegmentRow("Движение полосок", null, new (string, object)[] { ("Как на iPhone", "iphone"), ("Точный спектр", "precise") },
                                   nameof(Settings.SpectrumMotion), "движение полосок айфон iphone точный спектр плавно")));
                    page.Children.Add(Group("Вид полос", null,
                        SegmentRow("Внутри полос", null, new (string, object)[] { ("Обложка", "artwork"), ("Размытая обложка", "blurred"), ("Цвет обложки", "tint") },
                                   nameof(Settings.SpectrumStyle), "обложка размытая цвет вид полос спектрограмма"),
                        SliderRow("Размытие обложки", nameof(Settings.SpectrumBlur), 0, 1, 0.05, "размытие блюр обложка"),
                        SliderRow("Размер спектрограммы", nameof(Settings.SpectrumSize), 0.7, 1.3, 0.05, "размер полосок спектрограмма")));
                    page.Children.Add(Group("Плавность", "Полоски двигаются по настоящему звуку Windows: шесть полос частот, как на Mac. Звук только анализируется и сразу забывается — ничего не записывается.",
                        SegmentRow("Кадров в секунду", "Больше 60 — для экранов 120–144 Гц; нагрузка чуть выше",
                                   new (string, object)[] { ("30", 30), ("60", 60), ("90", 90), ("120", 120), ("144", 144) },
                                   nameof(Settings.SpectrumFps), "кадры fps плавность частота герцы")));
                    break;

                case "notifications":
                    page.Children.Add(Group("Звук", "«Вместо индикатора Windows»: Ovira забирает себе только три клавиши громкости (тише, громче, без звука) и меняет громкость сама теми же шагами по 2 %, поэтому системная плашка Windows не появляется. Другие клавиши Ovira не видит. Кнопки громкости на Bluetooth-наушниках и фирменные утилиты ноутбуков могут всё равно показывать свой индикатор.",
                        ToggleRow("Громкость", "Уровень и «Без звука»", nameof(Settings.VolumeBanner), "громкость звук баннер",
                                  () => App.Current.IslandWindow?.DemoVolume()),
                        VolumeKeysRow(),
                        ToggleRow("Устройство вывода звука", "Когда звук переключился на наушники или динамики", nameof(Settings.OutputBanner), "наушники динамики вывод",
                                  () => App.Current.IslandWindow?.DemoOutput())));
                    page.Children.Add(Group("Звонки", "Ovira замечает звонок по тому, что Discord или VK Мессенджер (приложение или вкладка в браузере) включили микрофон. В островке — зелёная трубка и время звонка; нажми на островок: «Микрофон» выключает микрофон Windows целиком — тебя не слышно ни в одной программе, «Отключиться» нажимает кнопку завершения в самом Discord или VK.",
                        ToggleRow("Звонки в островке", "Discord и VK Мессенджер: время, микрофон и «Отключиться»", nameof(Settings.CallActivity), "звонок discord дискорд vk вк мессенджер микрофон отключиться")));
                    page.Children.Add(Group("Steam", "Пока Steam качает игру, островок показывает процент; нажми на островок — прошло, осталось, скорость сейчас и пиковая, запись на диск, как на странице загрузок Steam. Ovira только читает то, что Steam сам записывает (отметку «обновляется» и файл игры в библиотеке), и ничего в Steam не меняет. Скорость — это всё, что компьютер получает из сети: если одновременно идёт видео, цифра чуть выше, чем в Steam.",
                        ToggleRow("Загрузки Steam", "Процент в островке и подробности в раскрытом", nameof(Settings.SteamActivity), "steam стим загрузка скачивание игра скорость")));
                    page.Children.Add(Group("Клавиатура", "Ovira только спрашивает у Windows, включён ли Caps Lock и какой язык ввода у окна впереди. Нажатые клавиши она не видит и не записывает.",
                        ToggleRow("Caps Lock", "Справа «Вкл» или «Выкл»", nameof(Settings.CapsLockBanner), "капс caps lock заглавные",
                                  () => App.Current.IslandWindow?.DemoCapsLock()),
                        ToggleRow("Раскладка", "Справа язык: RU, EN…", nameof(Settings.LayoutBanner), "раскладка язык ввода ru en клавиатура",
                                  () => App.Current.IslandWindow?.DemoLayout())));
                    page.Children.Add(Group("Поверх игр", "В игре или видео на весь экран островок прячется, но отмеченные уведомления всё равно появятся на пару секунд и исчезнут; клики проходят в игру. Если игра в эксклюзивном полноэкранном режиме, Windows не даёт ничему показаться поверх — выбери в игре «Оконный без рамки» (Borderless).",
                        ToggleRow("Медиаплеер", "Островок с музыкой остаётся поверх игры, пока музыка играет; клик раскрывает плеер, игра не теряет фокус", nameof(Settings.GameMedia), "игра полноэкранный поверх медиаплеер музыка плеер"),
                        ToggleRow("Уровень громкости", "Видно, сколько сейчас", nameof(Settings.GameVolume), "игра полноэкранный поверх громкость"),
                        ToggleRow("Зарядка и низкий заряд", "Чтобы не пропустить, что ноутбук садится", nameof(Settings.GameBattery), "игра полноэкранный поверх батарея зарядка"),
                        ToggleRow("Смена устройства звука", "Наушники или динамики", nameof(Settings.GameOutput), "игра полноэкранный поверх наушники вывод"),
                        ToggleRow("Отдых для глаз", "Перерыв напомнит и во время игры", nameof(Settings.GameEyeBreak), "игра полноэкранный поверх отдых глаза"),
                        ToggleRow("Caps Lock и раскладка", "Обычно в играх не нужно", nameof(Settings.GameKeyboard), "игра полноэкранный поверх капс раскладка")));
                    break;

                case "devices":
                    page.Children.Add(Group("Батарея", "На компьютере без батареи эти баннеры не появляются.",
                        ToggleRow("Зарядка", "Подключение и отключение зарядки", nameof(Settings.ChargingBanner), "зарядка батарея питание",
                                  () => App.Current.IslandWindow?.DemoCharging()),
                        ToggleRow("Низкий заряд", "При 20 % и 10 %", nameof(Settings.LowBatteryBanner), "низкий заряд батарея",
                                  () => App.Current.IslandWindow?.DemoLowBattery())));
                    break;
            }
            _collecting = false;
            return collectOnly ? null : page;
        }

        private bool _collecting;
        private string _collectSection = "";

        private void Remember(string title, string keywords, FrameworkElement row)
        {
            if (_collecting) _entries.Add(new Entry(_collectSection, title, keywords));
            else _rows[title] = row;
        }

        // ================================================================ builders

        private FrameworkElement Group(string title, string? footer, params FrameworkElement[] rows)
        {
            var panel = new StackPanel { Style = (Style)FindResource("Group") };
            panel.Children.Add(new TextBlock { Text = title.ToUpperInvariant(), Style = (Style)FindResource("GroupTitle") });
            var list = new StackPanel();
            for (int i = 0; i < rows.Length; i++)
            {
                if (i > 0) list.Children.Add(new Border { Style = (Style)FindResource("RowDivider") });
                list.Children.Add(rows[i]);
            }
            panel.Children.Add(new Border { Style = (Style)FindResource("GlassCard"), Child = list });
            if (footer != null) panel.Children.Add(new TextBlock { Text = footer, Style = (Style)FindResource("Hint") });
            return panel;
        }

        private Grid Row(string title, string? subtitle, FrameworkElement trailing)
        {
            var grid = new Grid { Style = (Style)FindResource("Row") };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
            text.Children.Add(new TextBlock { Text = title, Style = (Style)FindResource("RowTitle") });
            if (!string.IsNullOrEmpty(subtitle)) text.Children.Add(new TextBlock { Text = subtitle, Style = (Style)FindResource("RowSub") });
            grid.Children.Add(text);
            trailing.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(trailing, 1);
            grid.Children.Add(trailing);
            return grid;
        }

        private Binding Bind(string path) => new Binding(path) { Source = Settings.Current, Mode = BindingMode.TwoWay };

        private FrameworkElement ToggleRow(string title, string? subtitle, string property, string keywords, Action? demo = null)
        {
            var toggle = new CheckBox { Style = (Style)FindResource("MacSwitch") };
            toggle.SetBinding(ToggleButton.IsCheckedProperty, Bind(property));
            FrameworkElement trailing = toggle;
            if (demo != null)
            {
                var both = new StackPanel { Orientation = Orientation.Horizontal };
                var show = new Button { Content = "Показать", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 14, 0) };
                show.Click += (_, _) => demo();
                both.Children.Add(show);
                both.Children.Add(toggle);
                trailing = both;
            }
            var row = Row(title, subtitle, trailing);
            Remember(title, keywords, row);
            return row;
        }

        private FrameworkElement ButtonRow(string title, string? subtitle, string button, Action action, string keywords)
        {
            var b = new Button { Content = button, Style = (Style)FindResource("MacButton") };
            b.Click += (_, _) => action();
            var row = Row(title, subtitle, b);
            Remember(title, keywords, row);
            return row;
        }

        private FrameworkElement TextRow(string title, string text) => Row(title, text, new Border());

        // 0.4.21: the switch with a line saying whether the keys were taken.
        private FrameworkElement VolumeKeysRow()
        {
            var row = (Grid)ToggleRow("Вместо индикатора Windows", " ", nameof(Settings.ReplaceVolumeOsd), "индикатор громкости windows системный плашка osd скрыть заменить");
            var sub = row.Children.OfType<StackPanel>().First().Children.OfType<TextBlock>().Last();
            void Show()
            {
                var keys = App.Current.VolumeKeys;
                sub.Text = !S.ReplaceVolumeOsd ? "Выключено — громкость показывает Windows"
                         : keys.Working ? "Клавиши громкости показывают островок, плашки Windows нет"
                         : "Не получилось: клавиши громкости уже заняты другой программой";
            }
            Show();
            if (!_collecting)
            {
                Action changed = () => Dispatcher.BeginInvoke(new Action(Show));
                App.Current.VolumeKeys.Changed += changed;
                Closed += (_, _) => App.Current.VolumeKeys.Changed -= changed;
            }
            return row;
        }

        private TextBlock? _updText;
        private Button? _updButton;

        private FrameworkElement UpdateStatusRow()
        {
            _updButton = new Button { Style = (Style)FindResource("MacButton") };
            _updButton.Click += (_, _) =>
            {
                var u = App.Current.Updates;
                if (u.State == Ovira.Services.UpdateService.UpdateState.Ready) u.Install();
                else _ = u.CheckAsync(force: true);
            };
            var row = Row("Ovira " + App.Version, " ", _updButton);
            _updText = row.Children.OfType<StackPanel>().First().Children.OfType<TextBlock>().Last();
            Remember("Проверить обновления", "обновления версия скачать установить", row);
            ShowUpdateState();
            return row;
        }

        private void ShowUpdateState()
        {
            ShowUpdateCard();
            if (_updText == null || _updButton == null) return;
            var u = App.Current.Updates;
            var last = S.LastUpdateCheck;
            string status = u.State switch
            {
                Ovira.Services.UpdateService.UpdateState.Idle => last == DateTime.MinValue ? "Ещё не проверяли" : "Проверено " + When(last),
                _ => u.Message
            };
            _updText.Text = status;
            bool busy = u.State is Ovira.Services.UpdateService.UpdateState.Checking or Ovira.Services.UpdateService.UpdateState.Downloading
                                 or Ovira.Services.UpdateService.UpdateState.Installing;
            _updButton.Content = u.State == Ovira.Services.UpdateService.UpdateState.Ready ? "Обновить до " + u.NewVersion : "Проверить";
            _updButton.IsEnabled = !busy;
            _updButton.Opacity = busy ? 0.5 : 1;
        }

        private static string When(DateTime t)
        {
            var d = DateTime.Now - t;
            if (d.TotalMinutes < 1) return "только что";
            if (d.TotalHours < 1) return (int)d.TotalMinutes + " мин назад";
            if (t.Date == DateTime.Today) return "сегодня в " + t.ToString("HH:mm");
            if (t.Date == DateTime.Today.AddDays(-1)) return "вчера в " + t.ToString("HH:mm");
            return t.ToString("d MMMM, HH:mm", new System.Globalization.CultureInfo("ru-RU"));
        }

        // Segments bound to one setting: each option has its value.
        private FrameworkElement SegmentRow(string title, string? subtitle, (string label, object value)[] options, string property, string keywords)
        {
            var box = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(2) };
            box.SetResourceReference(Border.BackgroundProperty, "FieldBg");
            var stack = new StackPanel { Orientation = Orientation.Horizontal };
            var prop = typeof(Settings).GetProperty(property)!;
            var buttons = new List<(RadioButton b, object v)>();
            void Refresh()
            {
                var current = prop.GetValue(S);
                foreach (var (b, v) in buttons) b.IsChecked = Equals(current, v);
            }
            foreach (var (label, value) in options)
            {
                var rb = new RadioButton { Content = label, GroupName = "seg" + property + GetHashCode(), Style = (Style)FindResource("MacSegment") };
                rb.Checked += (_, _) => { if (!Equals(prop.GetValue(S), value)) prop.SetValue(S, value); };
                buttons.Add((rb, value));
                stack.Children.Add(rb);
            }
            Refresh();
            box.Child = stack;
            System.ComponentModel.PropertyChangedEventHandler handler = (_, e) => { if (e.PropertyName == property) Refresh(); };
            S.PropertyChanged += handler;
            box.Unloaded += (_, _) => S.PropertyChanged -= handler;
            var row = Row(title, subtitle, box);
            Remember(title, keywords, row);
            return row;
        }

        private FrameworkElement SliderRow(string title, string property, double min, double max, double step, string keywords)
        {
            var value = new TextBlock { FontSize = 12, Width = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            value.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            var slider = new Slider { Width = 200, Minimum = min, Maximum = max, TickFrequency = step, IsSnapToTickEnabled = true, Style = (Style)FindResource("MacSlider"), VerticalAlignment = VerticalAlignment.Center };
            slider.SetBinding(RangeBase.ValueProperty, Bind(property));
            void Show() => value.Text = $"{Math.Round(slider.Value * 100)} %";
            slider.ValueChanged += (_, _) => { Show(); UpdateStage(); };
            Show();
            var both = new StackPanel { Orientation = Orientation.Horizontal };
            both.Children.Add(slider);
            both.Children.Add(value);
            var row = Row(title, null, both);
            Remember(title, keywords, row);
            return row;
        }

        // Rounded colour tile with a glossy top — the section icons.
        private static FrameworkElement IconTile(string icon, Color colour, double size)
        {
            var radius = new CornerRadius(size * 0.28);
            var grid = new Grid { Width = size, Height = size };
            grid.Children.Add(new Border { CornerRadius = radius, Background = new LinearGradientBrush(Lighter(colour, 30), colour, 90) });
            grid.Children.Add(new Border
            {
                CornerRadius = radius,
                Background = Gloss(0x59),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(0.8)
            });
            grid.Children.Add(new IconView { Icon = icon, Width = size * 0.5, Height = size * 0.5 });
            grid.Effect = new DropShadowEffect { Color = colour, BlurRadius = size * 0.3, ShadowDepth = size * 0.06, Direction = 270, Opacity = 0.45 };
            return grid;
        }

        private static Brush Gloss(byte alpha) => new LinearGradientBrush(new GradientStopCollection
        {
            new GradientStop(Color.FromArgb(alpha, 0xFF, 0xFF, 0xFF), 0),
            new GradientStop(Color.FromArgb(0, 0xFF, 0xFF, 0xFF), 0.5)
        }, 90);

        private static Color Lighter(Color c, int by) =>
            Color.FromRgb((byte)Math.Min(255, c.R + by), (byte)Math.Min(255, c.G + by), (byte)Math.Min(255, c.B + by));

        private static FontFamily DisplayFont => (FontFamily)Application.Current.FindResource("DisplayFont");

        // ================================================================ search (on the home screen, like the Mac)

        private void OnSearch(object sender, TextChangedEventArgs e)
        {
            var q = SearchBox.Text.Trim().ToLowerInvariant();
            SearchPlaceholder.Visibility = q.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (q.Length > 0 && _current != null) GoHome();
            SearchPanel.Visibility = q.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            HomeContent.Visibility = q.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            SearchResults.Children.Clear();
            if (q.Length == 0) return;
            var hits = _entries.Where(x => x.Title.ToLowerInvariant().Contains(q) || x.Keywords.Contains(q)).ToList();
            if (hits.Count == 0)
            {
                var none = new TextBlock { Text = "Ничего не нашлось", FontSize = 12.5, Margin = new Thickness(8) };
                none.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
                SearchResults.Children.Add(none);
                return;
            }
            foreach (var hit in hits)
            {
                var section = Sections.First(s => s.Key == hit.Section);
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(IconTile(section.Icon, section.Accent, 24));
                var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBlock { Text = hit.Title, FontSize = 13 });
                var where = new TextBlock { Text = section.Title, FontSize = 10.5 };
                where.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
                text.Children.Add(where);
                row.Children.Add(text);
                var item = new Border { Child = row, Padding = new Thickness(8, 6, 8, 6), CornerRadius = new CornerRadius(12), Background = Brushes.Transparent, Cursor = Cursors.Hand };
                item.MouseEnter += (_, _) => item.SetResourceReference(Border.BackgroundProperty, "FieldBg");
                item.MouseLeave += (_, _) => item.Background = Brushes.Transparent;
                var title = hit.Title;
                item.MouseLeftButtonUp += (_, _) =>
                {
                    Open(section, animated: true);
                    Dispatcher.BeginInvoke(new Action(() => Highlight(title)), DispatcherPriority.Loaded);
                };
                SearchResults.Children.Add(item);
            }
        }

        private void Highlight(string title)
        {
            if (!_rows.TryGetValue(title, out var row) || _current == null) return;
            row.BringIntoView();
            if (row is Panel panel)
            {
                var a = _current.Accent;
                var brush = new SolidColorBrush(Color.FromArgb(0, a.R, a.G, a.B));
                panel.Background = brush;
                brush.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(Color.FromArgb(0x40, a.R, a.G, a.B), TimeSpan.FromSeconds(0.25))
                {
                    AutoReverse = true,
                    RepeatBehavior = new RepeatBehavior(2)
                });
            }
        }

        // ================================================================ actions

        private void OpenFolder()
        {
            try
            {
                System.IO.Directory.CreateDirectory(Settings.Folder);
                Process.Start(new ProcessStartInfo("explorer.exe", "\"" + Settings.Folder + "\"") { UseShellExecute = true });
            }
            catch { }
        }

        private void ResetAll()
        {
            var answer = MessageBox.Show(this, "Вернуть все настройки Ovira как после установки?", "Ovira",
                                         MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (answer == MessageBoxResult.OK) S.ResetAll();
        }

        private void OnMinimize(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
        private void OnClose(object sender, RoutedEventArgs e) => Close();
    }
}
