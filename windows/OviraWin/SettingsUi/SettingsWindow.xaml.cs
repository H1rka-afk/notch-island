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
using System.Windows.Shapes;
using System.Windows.Threading;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.SettingsUi
{
    // 0.2.0 — the settings window drawn like the Mac one: a living colour
    // background, a floating glass sidebar with coloured tiles and a glossy
    // selection pill, a big banner per section with the island acting it
    // out, UPPERCASE groups on glass cards, and search.
    public partial class SettingsWindow : Window
    {
        private sealed record Section(string Key, string Title, string Subtitle, string Glyph, Color Colour, int Group)
        {
            public Color Accent => Key == "general" ? Color.FromRgb(0x3D, 0x85, 0xFF) : Colour;
        }

        private sealed record Entry(string Section, string Title, string Keywords);

        private static readonly Section[] Sections =
        {
            new("general", "Основные", "Запуск, обслуживание и сброс", "", Color.FromRgb(0x8C, 0x8F, 0x99), 0),
            new("island", "Островок", "Вид, размер и поведение островка", "", Color.FromRgb(0x33, 0x7A, 0xFF), 1),
            new("media", "Медиаплеер", "Плеер, спектрограмма, звук и обложки", "", Color.FromRgb(0xFF, 0x45, 0x66), 1),
            new("notifications", "Уведомления", "Громкость и звук — короткие баннеры в островке", "", Color.FromRgb(0xFF, 0x45, 0x3A), 1),
            new("devices", "Устройства", "Батарея и зарядка ноутбука", "", Color.FromRgb(0x33, 0xBF, 0x59), 2),
        };

        private static string GroupTitle(int g) => g switch { 0 => "OVIRA", 1 => "ОСТРОВОК И ЭКРАН", _ => "УСТРОЙСТВА" };

        private readonly Dictionary<string, Border> _navItems = new();
        private readonly List<Entry> _entries = new();
        private readonly Dictionary<string, FrameworkElement> _rows = new();
        private Section _current = Sections[1];
        private Settings S => Settings.Current;

        public SettingsWindow()
        {
            InitializeComponent();
            VersionText.Text = "Версия " + App.Version + " · Windows";
            SourceInitialized += (_, _) =>
            {
                try { Native.DarkTitleBar(new WindowInteropHelper(this).Handle); } catch { }
            };
            BuildSidebar();
            StartAurora();
            BuildPreviewBars();

            var app = App.Current;
            Action<TrackInfo?> onTrack = _ => Dispatcher.BeginInvoke(new Action(() => { UpdatePreview(); TintAurora(); }));
            app.Media.Changed += onTrack;
            Closed += (_, _) => { app.Media.Changed -= onTrack; _previewTimer.Stop(); };

            var start = Sections.FirstOrDefault(s => s.Key == S.Section) ?? Sections[1];
            Open(start, animated: false);
            _previewTimer.Tick += (_, _) => PreviewTick();
            _previewTimer.Start();
        }

        // ---------------------------------------------------------- sidebar

        private void BuildSidebar()
        {
            int lastGroup = -1;
            foreach (var section in Sections)
            {
                if (section.Group != lastGroup)
                {
                    NavList.Children.Add(new TextBlock { Text = GroupTitle(section.Group), Style = (Style)FindResource("SideHeader") });
                    lastGroup = section.Group;
                }
                var item = NavItem(section);
                _navItems[section.Key] = item;
                NavList.Children.Add(item);
            }
            // Every row of every page, for the search.
            foreach (var section in Sections) BuildPage(section, collectOnly: true);
        }

        private Border NavItem(Section section)
        {
            var tile = IconTile(section.Glyph, section.Colour, 24);
            var title = new TextBlock { Text = section.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(tile);
            row.Children.Add(title);
            var pill = new Border
            {
                CornerRadius = new CornerRadius(15),
                Padding = new Thickness(7, 5, 7, 5),
                Margin = new Thickness(0, 1, 0, 1),
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0.8),
                BorderBrush = Brushes.Transparent,
                Child = row,
                Cursor = Cursors.Hand,
                Tag = title
            };
            pill.MouseEnter += (_, _) => { if (_current.Key != section.Key) pill.Background = new SolidColorBrush(Color.FromArgb(0x10, 0xFF, 0xFF, 0xFF)); };
            pill.MouseLeave += (_, _) => { if (_current.Key != section.Key) pill.Background = Brushes.Transparent; };
            pill.MouseLeftButtonUp += (_, _) => Open(section, animated: true);
            return pill;
        }

        private void PaintNav()
        {
            foreach (var section in Sections)
            {
                var pill = _navItems[section.Key];
                var title = (TextBlock)pill.Tag;
                if (section.Key == _current.Key)
                {
                    // A bright glossy pill in the section's colour.
                    var a = section.Accent;
                    var fill = new LinearGradientBrush(Color.FromArgb(0xF2, a.R, a.G, a.B), Color.FromArgb(0xB8, a.R, a.G, a.B), 90);
                    var visual = new DrawingBrush(new DrawingGroup
                    {
                        Children =
                        {
                            new GeometryDrawing(fill, null, new RectangleGeometry(new Rect(0, 0, 1, 1))),
                            new GeometryDrawing(new LinearGradientBrush(Color.FromArgb(0x47, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF), 90),
                                                null, new RectangleGeometry(new Rect(0, 0, 1, 0.5)))
                        }
                    }) { Stretch = Stretch.Fill };
                    pill.Background = visual;
                    pill.BorderBrush = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF));
                    pill.Effect = new DropShadowEffect { Color = a, BlurRadius = 14, ShadowDepth = 3, Direction = 270, Opacity = 0.5 };
                    title.FontWeight = FontWeights.SemiBold;
                }
                else
                {
                    pill.Background = Brushes.Transparent;
                    pill.BorderBrush = Brushes.Transparent;
                    pill.Effect = null;
                    title.FontWeight = FontWeights.Normal;
                }
            }
        }

        // Rounded colour tile with a glossy top — the section icons.
        private static FrameworkElement IconTile(string glyph, Color colour, double size)
        {
            var radius = new CornerRadius(size * 0.28);
            var lighter = Color.FromRgb((byte)Math.Min(255, colour.R + 30), (byte)Math.Min(255, colour.G + 30), (byte)Math.Min(255, colour.B + 30));
            var grid = new Grid { Width = size, Height = size };
            grid.Children.Add(new Border { CornerRadius = radius, Background = new LinearGradientBrush(lighter, colour, 90) });
            grid.Children.Add(new Border
            {
                CornerRadius = radius,
                Background = new LinearGradientBrush(new GradientStopCollection
                {
                    new GradientStop(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF), 0),
                    new GradientStop(Color.FromArgb(0, 0xFF, 0xFF, 0xFF), 0.5)
                }, 90),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(0.8)
            });
            grid.Children.Add(new TextBlock
            {
                Text = glyph,
                FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
                FontSize = size * 0.46,
                Foreground = Brushes.White,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
            grid.Effect = new DropShadowEffect { Color = colour, BlurRadius = size * 0.3, ShadowDepth = size * 0.05, Direction = 270, Opacity = 0.35 };
            return grid;
        }

        // ---------------------------------------------------------- sections

        private void Open(Section section, bool animated)
        {
            _current = section;
            S.Section = section.Key;
            Resources["SectionAccent"] = new SolidColorBrush(section.Accent);
            PaintNav();

            HeroTitle.Text = section.Title;
            HeroSubtitle.Text = section.Subtitle;
            HeroIcon.Text = section.Glyph;
            var a = section.Accent;
            var colours = new (GradientStop stop, Color colour)[]
            {
                (HeroA, Color.FromArgb(0xEB, a.R, a.G, a.B)),
                (HeroB, Color.FromArgb(0x8C, a.R, a.G, a.B)),
            };
            foreach (var (stop, colour) in colours)
            {
                if (animated) stop.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(colour, TimeSpan.FromSeconds(0.35)));
                else { stop.BeginAnimation(GradientStop.ColorProperty, null); stop.Color = colour; }
            }
            HeroTileFill.Background = new LinearGradientBrush(
                Color.FromRgb((byte)Math.Min(255, section.Colour.R + 30), (byte)Math.Min(255, section.Colour.G + 30), (byte)Math.Min(255, section.Colour.B + 30)),
                section.Colour, 90);
            HeroGlow.Color = a;
            HeroTileGlow.Color = a;
            TintAurora();

            PageHost.Children.Clear();
            _rows.Clear();
            PageHost.Children.Add(BuildPage(section, collectOnly: false)!);
            DetailScroll.ScrollToTop();
            if (animated)
            {
                Detail.Opacity = 0;
                Detail.RenderTransform = new ScaleTransform(0.97, 0.97);
                Detail.RenderTransformOrigin = new Point(0.5, 0);
                var d = TimeSpan.FromSeconds(0.32);
                var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
                Detail.BeginAnimation(OpacityProperty, new DoubleAnimation(1, d) { EasingFunction = ease });
                ((ScaleTransform)Detail.RenderTransform).BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, d) { EasingFunction = ease });
                ((ScaleTransform)Detail.RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, d) { EasingFunction = ease });
            }
            _previewStep = 0;
            UpdatePreview();
        }

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
                        TextRow("Что уже есть", "Островок с пружинными анимациями, медиаплеер для любой музыки и видео, громкость, вывод звука и зарядка."),
                        TextRow("Чего на Windows не будет", "Свой экран блокировки (Windows не пускает программы на экран входа) и отклик трекпада."),
                        TextRow("Дальше", "Такси и доставка с живыми активностями, таймер, отдых для глаз, исправление раскладки, полка файлов.")));
                    break;

                case "island":
                    page.Children.Add(Group("Открытие", "При наведении островок раскрывается сам; по нажатию — только когда нажмёшь, а при наведении лишь чуть увеличивается.",
                        SegmentRow("Открывать плеер", null, "По нажатию", nameof(Settings.OpenOnClick), "При наведении", nameof(Settings.OpenOnHover), "открытие клик наведение нажатие"),
                        ToggleRow("Откликаться на курсор", "Островок чуть увеличивается, когда наводишь на него", nameof(Settings.HoverPeek), "отклик курсор увеличение")));
                    page.Children.Add(Group("Вид", null,
                        SliderRow("Размер островка", nameof(Settings.IslandScale), 0.85, 1.15, 0.05, "размер ширина больше меньше"),
                        ToggleRow("Капсула, когда ничего не играет", "Маленький чёрный островок вверху экрана всегда на месте", nameof(Settings.ShowIdlePill), "капсула пусто ничего"),
                        ToggleRow("Прятать в полноэкранном режиме", "Игры, видео на весь экран и презентации", nameof(Settings.HideInFullscreen), "полноэкранный игра видео презентация прятать")));
                    break;

                case "media":
                    page.Children.Add(Group("Плеер", "Spotify, Яндекс Музыка, браузер — всё, что показывает Windows в окне громкости.",
                        ToggleRow("Показывать медиаплеер", null, nameof(Settings.ShowMedia), "музыка плеер spotify яндекс"),
                        ToggleRow("Название трека в свёрнутом островке", "Между обложкой и спектрограммой", nameof(Settings.CompactTitle), "название трек песня"),
                        ToggleRow("Выбор устройства вывода звука", "Кнопка в плеере: динамики, наушники, монитор", nameof(Settings.OutputPicker), "вывод звук наушники динамики устройство"),
                        ButtonRow("Открыть плеер", "Показать, как он выглядит прямо сейчас", "Показать", () => App.Current.IslandWindow?.DemoOpen(), "показать открыть плеер")));
                    page.Children.Add(Group("Спектрограмма", null,
                        ToggleRow("Полоски в такт музыке", "Шесть полосок по настоящей громкости, в цвет обложки", nameof(Settings.LiveBars), "спектрограмма полоски эквалайзер волна")));
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

        // ---------------------------------------------------------- builders

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

        private FrameworkElement TextRow(string title, string text)
        {
            var row = Row(title, text, new Border());
            return row;
        }

        private FrameworkElement SegmentRow(string title, string? subtitle, string a, string aProperty, string b, string bProperty, string keywords)
        {
            var box = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(2), Background = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)) };
            var stack = new StackPanel { Orientation = Orientation.Horizontal };
            var group = "seg" + aProperty;
            var ra = new RadioButton { Content = a, GroupName = group, Style = (Style)FindResource("MacSegment") };
            ra.SetBinding(ToggleButton.IsCheckedProperty, Bind(aProperty));
            var rb = new RadioButton { Content = b, GroupName = group, Style = (Style)FindResource("MacSegment") };
            rb.SetBinding(ToggleButton.IsCheckedProperty, Bind(bProperty));
            stack.Children.Add(ra);
            stack.Children.Add(rb);
            box.Child = stack;
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
            slider.ValueChanged += (_, _) => { Show(); UpdatePreview(); };
            Show();
            var both = new StackPanel { Orientation = Orientation.Horizontal };
            both.Children.Add(slider);
            both.Children.Add(value);
            var row = Row(title, null, both);
            Remember(title, keywords, row);
            return row;
        }

        // ---------------------------------------------------------- search

        private void OnSearch(object sender, TextChangedEventArgs e)
        {
            var q = SearchBox.Text.Trim().ToLowerInvariant();
            SearchPlaceholder.Visibility = q.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (q.Length == 0)
            {
                SearchResults.Visibility = Visibility.Collapsed;
                NavList.Visibility = Visibility.Visible;
                return;
            }
            NavList.Visibility = Visibility.Collapsed;
            SearchResults.Visibility = Visibility.Visible;
            SearchResults.Children.Clear();
            var hits = _entries.Where(x => x.Title.ToLowerInvariant().Contains(q) || x.Keywords.Contains(q)).ToList();
            if (hits.Count == 0)
            {
                SearchResults.Children.Add(new TextBlock { Text = "Ничего не нашлось", FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(10, 6, 0, 0) });
                return;
            }
            foreach (var hit in hits)
            {
                var section = Sections.First(s => s.Key == hit.Section);
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(IconTile(section.Glyph, section.Colour, 22));
                var text = new StackPanel { Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBlock { Text = hit.Title, FontSize = 12.5, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 170 });
                text.Children.Add(new TextBlock { Text = section.Title, FontSize = 10.5, Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)) });
                row.Children.Add(text);
                var item = new Border { Child = row, Padding = new Thickness(7, 5, 7, 5), CornerRadius = new CornerRadius(10), Background = Brushes.Transparent, Cursor = Cursors.Hand };
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
            if (!_rows.TryGetValue(title, out var row)) return;
            row.BringIntoView();
            if (row is Panel panel)
            {
                var a = _current.Accent;
                var brush = new SolidColorBrush(Color.FromArgb(0, a.R, a.G, a.B));
                panel.Background = brush;
                var anim = new ColorAnimation(Color.FromArgb(0x40, a.R, a.G, a.B), TimeSpan.FromSeconds(0.25))
                {
                    AutoReverse = true,
                    RepeatBehavior = new RepeatBehavior(2)
                };
                brush.BeginAnimation(SolidColorBrush.ColorProperty, anim);
            }
        }

        // ---------------------------------------------------------- living background

        private void StartAurora()
        {
            Loaded += (_, _) =>
            {
                Drift(BlobA, -160, 420, -200, 260, 17);
                Drift(BlobB, 380, 760, 220, 420, 21);
                Drift(BlobC, 120, 560, -120, 380, 26);
            };
        }

        private static void Drift(UIElement blob, double x1, double x2, double y1, double y2, double seconds)
        {
            var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
            Canvas.SetLeft(blob, x1);
            Canvas.SetTop(blob, y1);
            blob.BeginAnimation(Canvas.LeftProperty, new DoubleAnimation(x1, x2, TimeSpan.FromSeconds(seconds))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease });
            blob.BeginAnimation(Canvas.TopProperty, new DoubleAnimation(y1, y2, TimeSpan.FromSeconds(seconds * 0.77))
            { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease });
        }

        private void TintAurora()
        {
            var a = _current.Accent;
            var cover = App.Current.Media.Track?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);
            var d = TimeSpan.FromSeconds(0.8);
            BlobAColor.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(a, d));
            BlobBColor.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(cover, d));
            BlobCColor.BeginAnimation(GradientStop.ColorProperty,
                new ColorAnimation(Color.FromRgb((byte)((a.R + cover.R) / 2), (byte)((a.G + cover.G) / 2), (byte)((a.B + 255) / 2)), d));
        }

        // ---------------------------------------------------------- the island in the banner

        private readonly DispatcherTimer _previewTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        private readonly Spring _pw = new Spring(170);
        private readonly Rectangle[] _pbars = new Rectangle[6];
        private readonly double[] _plevels = new double[6];
        private readonly Random _random = new Random();
        private int _previewStep;
        private double _previewClock;

        private void BuildPreviewBars()
        {
            for (int i = 0; i < 6; i++)
            {
                _pbars[i] = new Rectangle { Width = 1.8, Height = 3, RadiusX = 0.9, RadiusY = 0.9, Margin = new Thickness(0.7, 0, 0.7, 0), VerticalAlignment = VerticalAlignment.Center };
                PreviewBars.Children.Add(_pbars[i]);
            }
        }

        // Which little scene the banner plays.
        private string Scene()
        {
            switch (_current.Key)
            {
                case "media": return "music";
                case "notifications": return _previewStep % 2 == 0 ? "volume" : "output";
                case "devices": return "charging";
                case "general": return "ovira";
                default:
                    var cycle = new[] { "music", "volume", "charging", "output" };
                    return cycle[_previewStep % cycle.Length];
            }
        }

        private void UpdatePreview()
        {
            if (PreviewText == null) return;
            var scene = Scene();
            var track = App.Current.Media.Track;
            PreviewArtBox.Visibility = scene == "music" ? Visibility.Visible : Visibility.Collapsed;
            PreviewIcon.Visibility = scene == "music" ? Visibility.Collapsed : Visibility.Visible;
            PreviewBars.Visibility = scene == "music" ? Visibility.Visible : Visibility.Collapsed;
            double width;
            switch (scene)
            {
                case "music":
                    PreviewArt.Source = track?.Artwork;
                    PreviewText.Text = track?.Title ?? "Ничего не играет";
                    var tint = new SolidColorBrush(track?.Tint ?? Color.FromRgb(0xFF, 0x5A, 0x7A));
                    foreach (var b in _pbars) b.Fill = tint;
                    width = 176;
                    break;
                case "volume":
                    PreviewIcon.Text = ""; PreviewIcon.Foreground = Brushes.White;
                    PreviewText.Text = "Громкость 60 %";
                    width = 190;
                    break;
                case "output":
                    PreviewIcon.Text = ""; PreviewIcon.Foreground = new SolidColorBrush(Color.FromRgb(0x4C, 0x8D, 0xFF));
                    PreviewText.Text = "Наушники";
                    width = 160;
                    break;
                case "charging":
                    PreviewIcon.Text = ""; PreviewIcon.Foreground = new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59));
                    PreviewText.Text = "Зарядка · 76 %";
                    width = 186;
                    break;
                default:
                    PreviewIcon.Text = ""; PreviewIcon.Foreground = Brushes.White;
                    PreviewText.Text = "Ovira " + App.Version;
                    width = 150;
                    break;
            }
            _pw.To(width * S.IslandScale * 0.9, Motion.GrowResponse, Motion.GrowDamping);
        }

        private void PreviewTick()
        {
            const double dt = 0.033;
            _pw.Step(dt);
            _previewClock += dt;
            // The island section and notifications play their scenes in turn.
            if ((_current.Key == "island" || _current.Key == "notifications") && _previewClock > 2.6)
            {
                _previewClock = 0;
                _previewStep++;
                UpdatePreview();
            }
            DrawPreview();
            var playing = App.Current.Media.Track?.Playing == true;
            var t = Environment.TickCount64 / 1000.0;
            double[] shape = { 0.55, 0.85, 1.0, 0.9, 0.72, 0.5 };
            for (int i = 0; i < 6; i++)
            {
                var target = playing ? Math.Clamp(shape[i] * (0.6 + 0.4 * Math.Sin(t * (7 + i * 1.8) + i)) * (0.8 + _random.NextDouble() * 0.4), 0.15, 1) : 0.15;
                _plevels[i] += (target - _plevels[i]) * (target > _plevels[i] ? 0.5 : 0.2);
                _pbars[i].Height = 2 + 10 * _plevels[i];
            }
        }

        private void DrawPreview()
        {
            double w = _pw.Value, h = 26, r = 11, flare = 6, cx = 118;
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
            PreviewShape.Data = g;
            PreviewContent.Width = Math.Max(0, w);
            Canvas.SetLeft(PreviewContent, l);
        }

        // ---------------------------------------------------------- actions

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
