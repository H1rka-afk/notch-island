using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
    // 0.3.0 — Settings ported from the Mac (NotchSettingsWindow.swift):
    // a top bar (Ovira or «‹ Все настройки», search, the live island), a home
    // screen with a stage where the island acts out the tile under the
    // pointer and a bento grid of bright tiles, and per section a glossy
    // banner with UPPERCASE groups on glass cards. Living colour background.
    public partial class SettingsWindow : Window
    {
        private sealed record Section(string Key, string Title, string Subtitle, string Status, string Icon, Color Colour, string Demo)
        {
            public Color Accent => Key == "general" ? Color.FromRgb(0x3D, 0x85, 0xFF) : Colour;
        }

        private sealed record Entry(string Section, string Title, string Keywords);

        private static readonly Section[] Sections =
        {
            new("general", "Основные", "Запуск, обслуживание и сброс", "Запуск и обслуживание", "gear", Color.FromRgb(0x8C, 0x8F, 0x99), "ovira"),
            new("island", "Островок", "Вид, размер и поведение островка", "Открытие и размер", "laptop", Color.FromRgb(0x33, 0x7A, 0xFF), "music"),
            new("media", "Медиаплеер", "Плеер, звук и обложки", "Любая музыка в Windows", "play", Color.FromRgb(0xFF, 0x45, 0x66), "music"),
            new("spectrum", "Спектрограмма", "Шесть полосок по настоящему звуку: вид, размытие и плавность", "Обложка, размытие, кадры", "waveform", Color.FromRgb(0xA8, 0x5C, 0xF2), "music"),
            new("notifications", "Уведомления", "Громкость и звук — короткие баннеры в островке", "Громкость и вывод звука", "bell", Color.FromRgb(0xFF, 0x45, 0x3A), "volume"),
            new("devices", "Устройства", "Батарея и зарядка ноутбука", "Зарядка и низкий заряд", "bolt", Color.FromRgb(0x33, 0xBF, 0x59), "charging"),
        };

        private readonly List<Entry> _entries = new();
        private readonly Dictionary<string, FrameworkElement> _rows = new();
        private Section? _current;              // null = home
        private Section? _hovered;
        private Settings S => Settings.Current;

        public SettingsWindow()
        {
            InitializeComponent();
            VersionText.Text = "Версия " + App.Version + " · Windows";
            SourceInitialized += (_, _) =>
            {
                try { Native.DarkTitleBar(new WindowInteropHelper(this).Handle); } catch { }
            };
            foreach (var section in Sections) BuildPage(section, collectOnly: true);
            BuildTiles();
            StartAurora();

            var app = App.Current;
            Action<TrackInfo?> onTrack = _ => Dispatcher.BeginInvoke(new Action(() => { ShowTrack(); TintAurora(); }));
            app.Media.Changed += onTrack;
            Closed += (_, _) => { app.Media.Changed -= onTrack; _stageTimer.Stop(); };
            KeyDown += (_, e) => { if (e.Key == Key.Escape && _current != null) GoHome(); };

            ShowTrack();
            _stageTimer.Tick += (_, _) => StageTick();
            _stageTimer.Start();
            var start = Sections.FirstOrDefault(s => s.Key == S.Section);
            if (start != null && S.Section != "home") Open(start, animated: false); else GoHome(animated: false);
        }

        // ================================================================ navigation

        private void GoHome(bool animated = true)
        {
            _current = null;
            S.Section = "home";
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
            Resources["SectionAccent"] = new SolidColorBrush(section.Accent);
            HomeHeader.Visibility = Visibility.Collapsed;
            BackButton.Visibility = Visibility.Visible;
            var a = section.Accent;
            BackA.Color = Lighter(a, 25);
            BackB.Color = a;
            BackGlow.Color = a;

            HeroTitle.Text = section.Title;
            HeroSubtitle.Text = section.Subtitle;
            HeroTileHost.Child = IconTile(section.Icon, section.Colour, 60);
            HeroA.Color = Color.FromArgb(0xEB, a.R, a.G, a.B);
            HeroB.Color = Color.FromArgb(0x8C, a.R, a.G, a.B);
            HeroGlow.Color = a;

            PageHost.Children.Clear();
            _rows.Clear();
            PageHost.Children.Add(BuildPage(section, collectOnly: false)!);
            HomeView.Visibility = Visibility.Collapsed;
            DetailView.Visibility = Visibility.Visible;
            DetailView.ScrollToTop();
            if (animated) Appear(DetailView, 0.94);
            TintAurora();
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
            Place(Tile(Sections[0]), 0, 2);
            Place(Tile(Sections[1]), 0, 3);
            Place(Tile(Sections[2]), 1, 0);
            Place(Tile(Sections[3]), 1, 1);
            Place(Tile(Sections[4]), 1, 2);
            Place(Tile(Sections[5]), 1, 3);
        }

        private void Place(FrameworkElement tile, int row, int column)
        {
            Grid.SetRow(tile, row);
            Grid.SetColumn(tile, column);
            Tiles.Children.Add(tile);
        }

        // A bright tile: circle icon, title, status. Light follows the pointer,
        // the tile lifts a little and glows in its colour.
        private FrameworkElement Tile(Section section)
        {
            var c = section.Accent;
            var shape = new CornerRadius(22);
            var light = new RadialGradientBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF))
            {
                Center = new Point(0.15, 0.1), GradientOrigin = new Point(0.15, 0.1), RadiusX = 0.8, RadiusY = 0.9
            };
            var content = new Grid();
            content.Children.Add(new Border { CornerRadius = shape, Background = new LinearGradientBrush(Color.FromArgb(0xFA, c.R, c.G, c.B), Color.FromArgb(0xA8, c.R, c.G, c.B), 45) });
            content.Children.Add(new Border { CornerRadius = shape, Background = Gloss(0x2E) });
            content.Children.Add(new Border { CornerRadius = shape, Background = light });

            var stack = new StackPanel { Margin = new Thickness(14) };
            var circle = new Grid { Width = 38, Height = 38, HorizontalAlignment = HorizontalAlignment.Left };
            circle.Children.Add(new Border { CornerRadius = new CornerRadius(19), Background = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)) });
            circle.Children.Add(new IconView { Icon = section.Icon, Width = 18, Height = 18 });
            stack.Children.Add(circle);
            stack.Children.Add(new TextBlock { Text = section.Title, FontSize = 15, FontWeight = FontWeights.Black, FontFamily = DisplayFont, Margin = new Thickness(0, 22, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis });
            stack.Children.Add(new TextBlock { Text = section.Status, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Color.FromArgb(0xD6, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(0, 3, 0, 0), TextWrapping = TextWrapping.Wrap });
            content.Children.Add(stack);

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
            content.Clip = null;
            Hover(tile, light, c, () => { _hovered = section; UpdateStage(); }, () => { if (_hovered == section) { _hovered = null; UpdateStage(); } });
            tile.MouseLeftButtonUp += (_, _) => Open(section, animated: true);
            return tile;
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
            Hover(tile, light, Colors.White, () => { _hovered = Sections[2]; UpdateStage(); }, () => { _hovered = null; UpdateStage(); });
            tile.MouseLeftButtonUp += (_, _) => Open(Sections[2], animated: true);
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
        private double _stageClock;

        private static readonly string[] Cycle = { "music", "volume", "charging", "output" };

        private string StageScene() => _hovered?.Demo ?? Cycle[_stageStep % Cycle.Length];

        private void UpdateStage()
        {
            if (StageText == null) return;
            var scene = StageScene();
            var t = App.Current.Media.Track;
            StageArt.Visibility = scene == "music" ? Visibility.Visible : Visibility.Collapsed;
            StageIcon.Visibility = scene == "music" ? Visibility.Collapsed : Visibility.Visible;
            StageBars.Visibility = scene == "music" ? Visibility.Visible : Visibility.Collapsed;
            string caption;
            double width;
            switch (scene)
            {
                case "music":
                    StageArt.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : new SolidColorBrush(Color.FromRgb(0x2A, 0x2A, 0x2A));
                    StageText.Text = "";
                    caption = "Сейчас играет — обложка и полоски в такт музыке";
                    width = 255;
                    break;
                case "volume":
                    StageIcon.Icon = "speaker.wave"; StageIcon.Fill = Brushes.White;
                    StageText.Text = "Громкость 60 %";
                    caption = "Громкость и вывод звука — короткие баннеры";
                    width = 300;
                    break;
                case "charging":
                    StageIcon.Icon = "bolt"; StageIcon.Fill = new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59));
                    StageText.Text = "Зарядка · 76 %";
                    caption = "Зарядка — молния и процент прямо в островке";
                    width = 300;
                    break;
                case "output":
                    StageIcon.Icon = "headphones"; StageIcon.Fill = new SolidColorBrush(Color.FromRgb(0x4C, 0x8D, 0xFF));
                    StageText.Text = "Наушники";
                    caption = "Звук переключился — островок покажет куда";
                    width = 280;
                    break;
                default:
                    StageIcon.Icon = "sparkles"; StageIcon.Fill = Brushes.White;
                    StageText.Text = "Ovira " + App.Version;
                    caption = "Островок вверху экрана — как на Mac";
                    width = 260;
                    break;
            }
            StageCaption.Text = caption;
            _sw.To(width * S.IslandScale, Motion.GrowResponse, Motion.GrowDamping);
            var accent = _hovered?.Accent ?? Color.FromRgb(0x5C, 0x59, 0xE6);
            var d = TimeSpan.FromSeconds(0.5);
            StageA.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(Color.FromArgb(0xD9, accent.R, accent.G, accent.B), d));
            StageGlow.BeginAnimation(DropShadowEffect.ColorProperty, new ColorAnimation(accent, d));
            var tint = t?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);
            StageTintColor.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(Color.FromArgb(0x99, tint.R, tint.G, tint.B), d));
        }

        private void StageTick()
        {
            const double dt = 0.016;
            if (HomeView.Visibility != Visibility.Visible) return;
            _sw.Step(dt);
            _stageClock += dt;
            if (_hovered == null && _stageClock > 3.2)
            {
                _stageClock = 0;
                _stageStep++;
                UpdateStage();
            }
            DrawStage();
        }

        private void DrawStage()
        {
            double width = Stage.ActualWidth;
            if (width <= 0) return;
            double w = _sw.Value, h = 35, r = 13, flare = 7, cx = width / 2;
            double l = cx - w / 2, rt = cx + w / 2;
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
                    page.Children.Add(Group("Запуск", null,
                        ToggleRow("Запускать вместе с Windows", "Островок появляется сразу после входа", nameof(Settings.StartWithWindows), "автозапуск старт вход")));
                    page.Children.Add(Group("Обслуживание", "Ovira для Windows " + App.Version + ". Всё работает на самом компьютере и никуда не отправляется.",
                        ButtonRow("Папка настроек", "settings.json и журнал ошибок errors.log", "Открыть", OpenFolder, "папка журнал лог ошибки"),
                        ButtonRow("Сбросить все настройки", "Вернуть всё как после установки", "Сбросить", ResetAll, "сброс по умолчанию"),
                        ButtonRow("Выйти из Ovira", "Островок исчезнет до следующего запуска", "Выйти", () => App.Current.Quit(), "закрыть выход")));
                    page.Children.Add(Group("Версия для Windows", null,
                        TextRow("Что уже есть", "Островок с пружинными анимациями, медиаплеер для любой музыки, настоящая спектрограмма, громкость, вывод звука и зарядка."),
                        TextRow("Чего на Windows не будет", "Свой экран блокировки (Windows не пускает программы на экран входа) и отклик трекпада."),
                        TextRow("Дальше", "Такси и доставка с живыми активностями, таймер, отдых для глаз, исправление раскладки, полка файлов.")));
                    break;

                case "island":
                    page.Children.Add(Group("Открытие", "При наведении островок раскрывается сам; по нажатию — только когда нажмёшь, а при наведении лишь чуть увеличивается.",
                        SegmentRow("Открывать плеер", null, new (string, object)[] { ("По нажатию", true), ("При наведении", false) }, nameof(Settings.OpenOnClick), "открытие клик наведение нажатие"),
                        ToggleRow("Откликаться на курсор", "Островок чуть увеличивается, когда наводишь на него", nameof(Settings.HoverPeek), "отклик курсор увеличение")));
                    page.Children.Add(Group("Вид", null,
                        SliderRow("Размер островка", nameof(Settings.IslandScale), 0.85, 1.15, 0.05, "размер ширина больше меньше"),
                        ToggleRow("Капсула, когда ничего не играет", "Маленький чёрный островок вверху экрана всегда на месте", nameof(Settings.ShowIdlePill), "капсула пусто ничего"),
                        ToggleRow("Прятать в полноэкранном режиме", "Игры, видео на весь экран и презентации", nameof(Settings.HideInFullscreen), "полноэкранный игра видео презентация прятать")));
                    break;

                case "media":
                    page.Children.Add(Group("Плеер", "Spotify, Яндекс Музыка, браузер — всё, что Windows показывает в окне громкости.",
                        ToggleRow("Показывать медиаплеер", null, nameof(Settings.ShowMedia), "музыка плеер spotify яндекс"),
                        ToggleRow("Громкость в плеере", "Ползунок громкости под кнопками, как на Mac", nameof(Settings.VolumeRow), "громкость ползунок"),
                        ToggleRow("Выбор устройства вывода звука", "Кнопка в плеере: динамики, наушники, монитор", nameof(Settings.OutputPicker), "вывод звук наушники динамики устройство"),
                        ButtonRow("Открыть плеер", "Показать, как он выглядит прямо сейчас", "Показать", () => App.Current.IslandWindow?.DemoOpen(), "показать открыть плеер")));
                    break;

                case "spectrum":
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
                    page.Children.Add(Group("Звук", "Такси, доставка и живые активности появятся в следующей версии для Windows.",
                        ToggleRow("Громкость", "Уровень и «Без звука»", nameof(Settings.VolumeBanner), "громкость звук баннер",
                                  () => App.Current.IslandWindow?.DemoVolume()),
                        ToggleRow("Устройство вывода звука", "Когда звук переключился на наушники или динамики", nameof(Settings.OutputBanner), "наушники динамики вывод",
                                  () => App.Current.IslandWindow?.DemoOutput())));
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

        // Segments bound to one setting: each option has its value.
        private FrameworkElement SegmentRow(string title, string? subtitle, (string label, object value)[] options, string property, string keywords)
        {
            var box = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(2), Background = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)) };
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
            var value = new TextBlock { FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)), Width = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
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
                SearchResults.Children.Add(new TextBlock { Text = "Ничего не нашлось", FontSize = 12.5, Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(8) });
                return;
            }
            foreach (var hit in hits)
            {
                var section = Sections.First(s => s.Key == hit.Section);
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(IconTile(section.Icon, section.Colour, 24));
                var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBlock { Text = hit.Title, FontSize = 13 });
                text.Children.Add(new TextBlock { Text = section.Title, FontSize = 10.5, Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)) });
                row.Children.Add(text);
                var item = new Border { Child = row, Padding = new Thickness(8, 6, 8, 6), CornerRadius = new CornerRadius(12), Background = Brushes.Transparent, Cursor = Cursors.Hand };
                item.MouseEnter += (_, _) => item.Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF));
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

        // ================================================================ living background

        private void StartAurora()
        {
            Loaded += (_, _) =>
            {
                Drift(BlobA, -180, 440, -220, 260, 17);
                Drift(BlobB, 380, 780, 220, 440, 21);
                Drift(BlobC, 120, 580, -140, 400, 26);
                TintAurora();
            };
        }

        private static void Drift(UIElement blob, double x1, double x2, double y1, double y2, double seconds)
        {
            var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
            blob.BeginAnimation(Canvas.LeftProperty, new DoubleAnimation(x1, x2, TimeSpan.FromSeconds(seconds))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease });
            blob.BeginAnimation(Canvas.TopProperty, new DoubleAnimation(y1, y2, TimeSpan.FromSeconds(seconds * 0.77))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease });
        }

        private void TintAurora()
        {
            var a = _current?.Accent ?? Color.FromRgb(0x5C, 0x59, 0xE6);
            var cover = App.Current.Media.Track?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);
            var d = TimeSpan.FromSeconds(0.8);
            BlobAColor.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(a, d));
            BlobBColor.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(cover, d));
            BlobCColor.BeginAnimation(GradientStop.ColorProperty,
                new ColorAnimation(Color.FromRgb((byte)((a.R + cover.R) / 2), (byte)((a.G + cover.G) / 2), (byte)Math.Min(255, (a.B + 255) / 2)), d));
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
