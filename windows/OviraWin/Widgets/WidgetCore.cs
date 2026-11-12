using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Ovira.Core;

namespace Ovira.Widgets
{
    // 0.6.0 — desktop widgets. Cards that lie on the desktop under the
    // windows: drag them anywhere, three sizes, four backgrounds (glass, the
    // theme's colours, white, monolith). Every widget is a small window of
    // its own that redraws once a second at most (the music one follows the
    // sound) — and not at all while Ovira hides for a full-screen game.
    public sealed class WidgetState
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        public string Kind { get; set; } = "clock";
        public string Size { get; set; } = "s";       // s — small square, m — wide, l — large
        public double X { get; set; } = double.NaN;
        public double Y { get; set; } = double.NaN;
        public string Text { get; set; } = "";         // the note, the to-do lines
        public string Variant { get; set; } = "";      // e.g. «analog» for the clock
    }

    public sealed record WidgetKind(string Id, string Title, string Icon, string[] Sizes, string About);

    public static class WidgetCatalog
    {
        public static readonly WidgetKind[] All =
        {
            new("nowplaying", "Сейчас играет", "music.note", new[] { "m", "s" }, "Обложка, название, кнопки и полоски"),
            new("cover", "Обложка", "star", new[] { "s", "l" }, "Обложка во всю карточку, клик — пауза"),
            new("saved", "Сохранённые песни", "star.fill", new[] { "m", "l" }, "Последние звёздочки, клик — копировать"),
            new("clock", "Часы", "timer", new[] { "s", "m" }, "Цифровые или стрелочные, с датой"),
            new("calendar", "Календарь", "chart", new[] { "s", "l" }, "Месяц с сегодняшним днём"),
            new("timer", "Таймер и секундомер", "timer", new[] { "s", "m" }, "Тот же таймер, что в островке"),
            new("alarms", "Будильник", "bell", new[] { "s" }, "Ближайший будильник"),
            new("stats", "Статистика", "chart", new[] { "m" }, "Сегодня и неделя столбиками"),
            new("eyes", "Отдых для глаз", "eye", new[] { "s" }, "Сколько до перерыва"),
            new("battery", "Батарея", "battery", new[] { "s" }, "Заряд и питание"),
            new("load", "Нагрузка", "waveform", new[] { "s", "m" }, "Процессор и память"),
            new("disks", "Диски", "display", new[] { "s", "m" }, "Свободное место"),
            new("network", "Сеть", "arrow.down", new[] { "s" }, "Скорость загрузки и отдачи"),
            new("steam", "Steam", "arrow.down", new[] { "m" }, "Текущая загрузка"),
            new("note", "Заметка", "sparkles", new[] { "s", "m", "l" }, "Стикер с текстом"),
            new("todo", "Список дел", "checkmark", new[] { "m", "s", "l" }, "Строки, отмечаются кликом"),
            new("weather", "Погода", "sun", new[] { "s", "m" }, "Сейчас и на 3 дня"),
            new("currency", "Курсы валют", "chart", new[] { "s" }, "Доллар, евро, юань"),
        };

        public static WidgetKind Find(string id) => All.FirstOrDefault(k => k.Id == id) ?? All[3];

        public const double Unit = 164, Gap = 12;

        public static Size Dimensions(string size) => size switch
        {
            "m" => new Size(Unit * 2 + Gap, Unit),
            "l" => new Size(Unit * 2 + Gap, Unit * 2 + Gap),
            _ => new Size(Unit, Unit)
        };

        public static string SizeName(string size) => size switch { "m" => "Широкий", "l" => "Большой", _ => "Маленький" };
    }

    // The colours of a card for the chosen background.
    public sealed class Look
    {
        public Brush Card = Brushes.Black, Border = Brushes.Transparent, Fg = Brushes.White, Fg2 = Brushes.Gray, Faint = Brushes.DimGray, Accent = Brushes.DodgerBlue;
        public Color AccentColor = Colors.DodgerBlue;
        public bool Gloss;

        private static SolidColorBrush B(byte a, byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromArgb(a, r, g, b)); x.Freeze(); return x; }

        public static Look Current()
        {
            var s = Settings.Current;
            var tint = App.Current.Media.Track?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);
            var theme = Themes.Find(s.Theme, tint);
            var accent = theme.Palette.Length > 0 ? theme.Palette[0] : Color.FromRgb(0x3D, 0x85, 0xFF);
            var look = new Look { AccentColor = accent };
            switch (s.WidgetStyle)
            {
                case "theme":
                {
                    // The theme's own colours, a little deeper so white text reads well.
                    var colours = theme.Palette.Length > 0 ? theme.Palette.Take(3).ToArray()
                                                           : new[] { Color.FromRgb(0x3D, 0x85, 0xFF), Color.FromRgb(0x5C, 0x59, 0xE6) };
                    var stops = new GradientStopCollection();
                    for (int i = 0; i < colours.Length; i++)
                        stops.Add(new GradientStop(Themes.Scale(colours[i], 0.82), colours.Length == 1 ? 0 : (double)i / (colours.Length - 1)));
                    var g = new LinearGradientBrush(stops, new Point(0, 0), new Point(1, 1));
                    g.Freeze();
                    look.Card = g;
                    look.Border = B(0x4D, 0xFF, 0xFF, 0xFF);
                    look.Fg = Brushes.White; look.Fg2 = B(0xC7, 0xFF, 0xFF, 0xFF); look.Faint = B(0x38, 0xFF, 0xFF, 0xFF);
                    look.Accent = Brushes.White; look.AccentColor = Colors.White;
                    look.Gloss = true;
                    break;
                }
                case "white":
                    look.Card = B(0xFA, 0xFF, 0xFF, 0xFF);
                    look.Border = B(0x1A, 0, 0, 0);
                    look.Fg = B(0xFF, 0x1C, 0x1C, 0x1E); look.Fg2 = B(0x99, 0x3C, 0x3C, 0x43); look.Faint = B(0x1A, 0, 0, 0);
                    look.Accent = new SolidColorBrush(Themes.Scale(accent, 0.9));
                    look.AccentColor = Themes.Scale(accent, 0.9);
                    break;
                case "mono":
                    // «Монолит»: one solid dark slab, like the iPhone's dark widgets.
                    look.Card = B(0xFF, 0x1C, 0x1C, 0x1E);
                    look.Border = B(0x1F, 0xFF, 0xFF, 0xFF);
                    look.Fg = Brushes.White; look.Fg2 = B(0x99, 0xEB, 0xEB, 0xF5); look.Faint = B(0x29, 0xFF, 0xFF, 0xFF);
                    look.Accent = new SolidColorBrush(accent);
                    break;
                default:
                    // «Стекло»: see-through smoked glass with a bright rim.
                    look.Card = B(0x7A, 0x1A, 0x1A, 0x20);
                    look.Border = B(0x52, 0xFF, 0xFF, 0xFF);
                    look.Fg = Brushes.White; look.Fg2 = B(0xB8, 0xFF, 0xFF, 0xFF); look.Faint = B(0x33, 0xFF, 0xFF, 0xFF);
                    look.Accent = new SolidColorBrush(Themes.MixWhite(accent, 0.25));
                    look.AccentColor = Themes.MixWhite(accent, 0.25);
                    look.Gloss = true;
                    break;
            }
            return look;
        }
    }

    public sealed class WidgetWindow : Window
    {
        public WidgetState State { get; }
        private Action? _update;
        private bool _placing;

        public WidgetWindow(WidgetState state)
        {
            State = state;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            ShowActivated = false;
            UseLayoutRounding = true;
            Title = "Ovira — " + WidgetCatalog.Find(state.Kind).Title;
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            SourceInitialized += (_, _) =>
            {
                var hwnd = new WindowInteropHelper(this).Handle;
                // Notes and to-do lists must take the keyboard; the rest never steal focus.
                int ex = Native.WS_EX_TOOLWINDOW;
                if (!Typing) ex |= Native.WS_EX_NOACTIVATE;
                Native.AddExStyle(hwnd, ex);
                ToBottom();
            };
            Activated += (_, _) => ToBottom();
            Deactivated += (_, _) => ToBottom();
            LocationChanged += (_, _) =>
            {
                if (_placing || !IsLoaded) return;
                State.X = Left; State.Y = Top;
                Settings.Current.SaveSoon();
            };
            Build();
        }

        private bool Typing => State.Kind is "note" or "todo";

        public void ToBottom()
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            if (hwnd != IntPtr.Zero)
                Native.SetWindowPos(hwnd, new IntPtr(1) /* HWND_BOTTOM */, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
        }

        public void Build()
        {
            var kind = WidgetCatalog.Find(State.Kind);
            if (!kind.Sizes.Contains(State.Size)) State.Size = kind.Sizes[0];
            var size = WidgetCatalog.Dimensions(State.Size);
            Width = size.Width;
            Height = size.Height;
            _placing = true;
            if (double.IsNaN(State.X) || double.IsNaN(State.Y))
            {
                var area = SystemParameters.WorkArea;
                int n = Settings.Current.Widgets.IndexOf(State);
                State.X = area.Right - size.Width - 40 - (n % 3) * 28;
                State.Y = area.Top + 70 + (n % 6) * 34;
            }
            // Never lost off-screen (a monitor was unplugged).
            var v = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
            Left = Math.Clamp(State.X, v.Left, Math.Max(v.Left, v.Right - size.Width));
            Top = Math.Clamp(State.Y, v.Top, Math.Max(v.Top, v.Bottom - size.Height));
            _placing = false;

            var look = Look.Current();
            var (content, update) = WidgetViews.Build(State, look, this);
            _update = update;
            var layers = new Grid();
            var shape = new CornerRadius(24);
            layers.Children.Add(new Border { CornerRadius = shape, Background = look.Card });
            if (look.Gloss)
                layers.Children.Add(new Border
                {
                    CornerRadius = shape, IsHitTestVisible = false,
                    Background = new LinearGradientBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF), new Point(0, 0), new Point(0, 0.55))
                });
            layers.Children.Add(new Border { CornerRadius = shape, Child = content, ClipToBounds = true });
            layers.Children.Add(new Border { CornerRadius = shape, BorderBrush = look.Border, BorderThickness = new Thickness(1), IsHitTestVisible = false });
            TextElementForeground(layers, look.Fg);
            Content = layers;
            layers.MouseLeftButtonDown += (_, e) =>
            {
                if (Settings.Current.WidgetsLocked || e.ClickCount > 1) return;
                if (e.OriginalSource is DependencyObject d && IsInteractive(d)) return;
                try { DragMove(); } catch { }
                ToBottom();
            };
            ContextMenu = Menu(kind);
            _update?.Invoke();
        }

        private static void TextElementForeground(DependencyObject o, Brush brush) =>
            System.Windows.Documents.TextElement.SetForeground(o, brush);

        // Buttons, text boxes and anything marked as clickable keep their clicks.
        private static bool IsInteractive(DependencyObject d)
        {
            while (d != null)
            {
                if (d is System.Windows.Controls.Primitives.ButtonBase or System.Windows.Controls.Primitives.TextBoxBase) return true;
                if (d is FrameworkElement f && Equals(f.Tag, "click")) return true;
                d = d is Visual || d is System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
            }
            return false;
        }

        private ContextMenu Menu(WidgetKind kind)
        {
            var menu = new ContextMenu();
            if (kind.Sizes.Length > 1)
                foreach (var size in new[] { "s", "m", "l" }.Where(x => kind.Sizes.Contains(x)))
                {
                    var item = new MenuItem { Header = WidgetCatalog.SizeName(size), IsChecked = State.Size == size };
                    item.Click += (_, _) => { State.Size = size; Settings.Current.SaveSoon(); Build(); };
                    menu.Items.Add(item);
                }
            if (State.Kind == "clock")
            {
                var analog = new MenuItem { Header = "Стрелочные", IsChecked = State.Variant == "analog" };
                analog.Click += (_, _) => { State.Variant = State.Variant == "analog" ? "" : "analog"; Settings.Current.SaveSoon(); Build(); };
                menu.Items.Add(analog);
            }
            if (menu.Items.Count > 0) menu.Items.Add(new Separator());
            var locked = new MenuItem { Header = "Закрепить все виджеты", IsChecked = Settings.Current.WidgetsLocked };
            locked.Click += (_, _) => Settings.Current.WidgetsLocked = !Settings.Current.WidgetsLocked;
            menu.Items.Add(locked);
            var settings = new MenuItem { Header = "Настройки виджетов…" };
            settings.Click += (_, _) => { Settings.Current.Section = "widgets"; App.Current.OpenSettings(); };
            menu.Items.Add(settings);
            var remove = new MenuItem { Header = "Убрать виджет" };
            remove.Click += (_, _) => WidgetManager.Remove(State.Id);
            menu.Items.Add(remove);
            return menu;
        }

        public void Tick() { try { _update?.Invoke(); } catch { } }
    }

    public static class WidgetManager
    {
        private static readonly List<WidgetWindow> Live = new();
        private static readonly DispatcherTimer Clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private static bool _started;
        private static bool _hidden;

        public static void Start()
        {
            if (_started) return;
            _started = true;
            foreach (var state in Settings.Current.Widgets.ToList()) Open(state);
            Clock.Tick += (_, _) => TickAll();
            Clock.Start();
            Settings.Current.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName is nameof(Settings.WidgetStyle) or nameof(Settings.Theme) or nameof(Settings.CustomThemes) or nameof(Settings.WeatherCity))
                    RebuildAll();
            };
            App.Current.Media.Changed += _ => App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Settings.Current.Theme == "cover" && Settings.Current.WidgetStyle != "mono") RebuildKinds(null);
                else TickAll();
            }), DispatcherPriority.Background);
            App.Current.Clock.Changed += TickAll;
            App.Current.Steam.Changed += TickAll;
        }

        private static void Open(WidgetState state)
        {
            try
            {
                var w = new WidgetWindow(state);
                Live.Add(w);
                w.Show();
                w.ToBottom();
            }
            catch { }
        }

        public static int Count(string kind) => Settings.Current.Widgets.Count(w => w.Kind == kind);

        public static void Add(string kind)
        {
            var state = new WidgetState { Kind = kind, Size = WidgetCatalog.Find(kind).Sizes[0] };
            Settings.Current.Widgets = Settings.Current.Widgets.Append(state).ToList();
            Open(state);
        }

        public static void Remove(string id)
        {
            foreach (var w in Live.Where(w => w.State.Id == id).ToList()) { Live.Remove(w); w.Close(); }
            Settings.Current.Widgets = Settings.Current.Widgets.Where(w => w.Id != id).ToList();
        }

        public static void RemoveAll()
        {
            foreach (var w in Live.ToList()) w.Close();
            Live.Clear();
            Settings.Current.Widgets = new List<WidgetState>();
        }

        public static void ResetPositions()
        {
            foreach (var w in Live) { w.State.X = double.NaN; w.State.Y = double.NaN; w.Build(); }
            Settings.Current.SaveSoon();
        }

        public static void RebuildAll() => RebuildKinds(null);

        private static void RebuildKinds(string? kind)
        {
            foreach (var w in Live.ToList())
                if (kind == null || w.State.Kind == kind) { try { w.Build(); } catch { } }
        }

        private static void TickAll()
        {
            // Over a full-screen game nothing is drawn.
            bool hide = Native.FullscreenAppInFront();
            if (hide != _hidden)
            {
                _hidden = hide;
                foreach (var w in Live) w.Visibility = hide ? Visibility.Hidden : Visibility.Visible;
            }
            if (hide) return;
            foreach (var w in Live.ToList()) w.Tick();
        }

        public static void CloseAll()
        {
            Clock.Stop();
            foreach (var w in Live.ToList()) { try { w.Close(); } catch { } }
            Live.Clear();
        }
    }
}
