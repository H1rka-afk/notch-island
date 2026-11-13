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

        public WidgetState Copy() => new WidgetState { Id = Id, Kind = Kind, Size = Size, X = X, Y = Y, Text = Text, Variant = Variant };
    }

    // 0.6.1 — one card (background, gloss, content, rim), for the desktop
    // and for the editor alike.
    public static class WidgetCard
    {
        public static (FrameworkElement Card, Action? Update) Make(WidgetState state, Look look, WidgetWindow? owner)
        {
            var (content, update) = WidgetViews.Build(state, look, owner);
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
            System.Windows.Documents.TextElement.SetForeground(layers, look.Fg);
            return (layers, update);
        }
    }

    // 0.6.1 — the grid and the magnets. The desktop is divided into cells the
    // size of a small widget (with the gap between them), starting 24 px from
    // the edges of the work area. A widget let go near a cell lands in it;
    // while dragging it also sticks to the edges of other widgets and of the
    // screen.
    public static class WidgetGrid
    {
        // 0.6.3: the grid fits the screen — as many whole cells as the work
        // area takes, centred, so the space left over is the same on every side.
        public const double MinMargin = 16, Magnet = 18;
        public static double Cell => WidgetCatalog.Unit + WidgetCatalog.Gap;
        private static double Gap => WidgetCatalog.Gap;

        public static Rect Area => SystemParameters.WorkArea;
        public static int Cols => Math.Max(1, (int)Math.Floor((Area.Width - 2 * MinMargin + Gap) / Cell));
        public static int Rows => Math.Max(1, (int)Math.Floor((Area.Height - 2 * MinMargin + Gap) / Cell));
        public static double OX => Area.Left + (Area.Width - (Cols * Cell - Gap)) / 2;
        public static double OY => Area.Top + (Area.Height - (Rows * Cell - Gap)) / 2;
        private static double Right => OX + Cols * Cell - Gap;
        private static double Bottom => OY + Rows * Cell - Gap;

        public static IEnumerable<Point> Cells()
        {
            for (int r = 0; r < Rows; r++)
                for (int c = 0; c < Cols; c++)
                    yield return new Point(OX + c * Cell, OY + r * Cell);
        }

        // The nearest cell corner to a point, keeping the widget inside the grid.
        public static Point Cellular(Point p, Size size)
        {
            int spanX = (int)Math.Round((size.Width + Gap) / Cell), spanY = (int)Math.Round((size.Height + Gap) / Cell);
            int c = (int)Math.Round((p.X - OX) / Cell), r = (int)Math.Round((p.Y - OY) / Cell);
            c = Math.Clamp(c, 0, Math.Max(0, Cols - spanX));
            r = Math.Clamp(r, 0, Math.Max(0, Rows - spanY));
            return new Point(OX + c * Cell, OY + r * Cell);
        }

        public static bool InArea(Point p, Size size)
        {
            var a = Area;
            return p.X + size.Width / 2 >= a.Left && p.X + size.Width / 2 <= a.Right && p.Y + size.Height / 2 >= a.Top && p.Y + size.Height / 2 <= a.Bottom;
        }

        // While dragging: the cells, the grid's edges and the other widgets'
        // edges pull a widget that comes within 18 px.
        public static Point Magnetic(Point p, Size size, IEnumerable<Rect> others)
        {
            var xs = new List<double> { OX, Right - size.Width };
            var ys = new List<double> { OY, Bottom - size.Height };
            var cell = Cellular(p, size);
            xs.Add(cell.X); ys.Add(cell.Y);
            foreach (var o in others)
            {
                xs.Add(o.Left); xs.Add(o.Right + Gap); xs.Add(o.Left - Gap - size.Width); xs.Add(o.Right - size.Width);
                ys.Add(o.Top); ys.Add(o.Bottom + Gap); ys.Add(o.Top - Gap - size.Height); ys.Add(o.Bottom - size.Height);
            }
            double Pull(double v, List<double> targets)
            {
                double best = v, d = Magnet;
                foreach (var t in targets) if (Math.Abs(t - v) < d) { d = Math.Abs(t - v); best = t; }
                return best;
            }
            return new Point(Pull(p.X, xs), Pull(p.Y, ys));
        }

        private static bool Free(Point q, Size size, IList<Rect> others)
        {
            var r = new Rect(q, size);
            r.Inflate(-2, -2);
            return !others.Any(o => o.IntersectsWith(r));
        }

        private static IEnumerable<Point> Fits(Size size)
        {
            foreach (var q in Cells())
                if (q.X + size.Width <= Right + 0.5 && q.Y + size.Height <= Bottom + 0.5) yield return q;
        }

        // Let go: into a cell; if that cell is taken, the nearest free one.
        public static Point Settle(Point p, Size size, IList<Rect> others)
        {
            if (!InArea(p, size)) return p;
            var start = Cellular(p, size);
            if (Free(start, size, others)) return start;
            Point? best = null;
            double bestDistance = double.MaxValue;
            foreach (var q in Fits(size))
            {
                if (!Free(q, size, others)) continue;
                double d = (q - start).LengthSquared;
                if (d < bestDistance) { bestDistance = d; best = q; }
            }
            return best ?? start;
        }

        // The first free cell from the top right — where a new widget goes.
        public static Point FirstFree(Size size, IList<Rect> others)
        {
            var cells = Fits(size).OrderByDescending(q => q.X).ThenBy(q => q.Y);
            foreach (var q in cells) if (Free(q, size, others)) return q;
            return new Point(Right - size.Width, OY);
        }
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
                // 0.6.2: Windows moves the widget itself (it always follows the
                // cursor); Ovira only bends the path to the magnets and puts it
                // into a cell when let go.
                HwndSource.FromHwnd(hwnd)?.AddHook(MoveHook);
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
            Native.PlaceOnDesktop(hwnd);
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
            var (layers, update) = WidgetCard.Make(State, look, this);
            _update = update;
            Content = layers;
            // A press anywhere on the card (except real buttons and text fields)
            // and a few pixels of movement start the move — so even areas that
            // react to a click (the cover, a song) can be dragged.
            layers.PreviewMouseLeftButtonDown += (_, e) =>
            {
                _pressed = false;
                if (e.ClickCount > 1) return;
                if (e.OriginalSource is DependencyObject d && IsInteractive(d)) return;
                _pressed = true;
                _grab = e.GetPosition(this);
            };
            layers.PreviewMouseMove += (_, e) =>
            {
                if (!_pressed || e.LeftButton != MouseButtonState.Pressed) { _pressed = false; return; }
                if ((e.GetPosition(this) - _grab).Length < 4) return;
                _pressed = false;
                _moving = true;
                try { DragMove(); } catch { }
                _moving = false;
                if (Settings.Current.WidgetsSnap)
                    Glide(WidgetGrid.Settle(new Point(Left, Top), new Size(Width, Height), WidgetManager.OtherRects(State.Id).ToList()));
                State.X = Left; State.Y = Top;
                Settings.Current.SaveSoon();
                ToBottom();
                e.Handled = true;
            };
            layers.PreviewMouseLeftButtonUp += (_, _) => _pressed = false;
            ContextMenu = Menu(kind);
            _update?.Invoke();
        }

        private Point _grab;
        private bool _pressed, _moving;

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct RECT { public int Left, Top, Right, Bottom; }

        private IntPtr MoveHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            const int WM_MOVING = 0x0216;
            if (msg != WM_MOVING || !Settings.Current.WidgetsSnap) return IntPtr.Zero;
            var source = PresentationSource.FromVisual(this);
            if (source?.CompositionTarget == null) return IntPtr.Zero;
            var r = System.Runtime.InteropServices.Marshal.PtrToStructure<RECT>(lParam);
            var toDip = source.CompositionTarget.TransformFromDevice;
            var toPx = source.CompositionTarget.TransformToDevice;
            var p = toDip.Transform(new Point(r.Left, r.Top));
            var size = new Size(Width, Height);
            if (!WidgetGrid.InArea(p, size)) return IntPtr.Zero;
            var m = WidgetGrid.Magnetic(p, size, WidgetManager.OtherRects(State.Id));
            var px = toPx.Transform(m);
            int dx = (int)Math.Round(px.X) - r.Left, dy = (int)Math.Round(px.Y) - r.Top;
            r.Left += dx; r.Right += dx; r.Top += dy; r.Bottom += dy;
            System.Runtime.InteropServices.Marshal.StructureToPtr(r, lParam, false);
            handled = true;
            return new IntPtr(1);
        }

        // Into the cell with a short glide.
        private DispatcherTimer? _glide;
        private void Glide(Point target)
        {
            _glide?.Stop();
            var from = new Point(Left, Top);
            var watch = System.Diagnostics.Stopwatch.StartNew();
            _glide = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(15) };
            _glide.Tick += (_, _) =>
            {
                double t = Math.Min(1, watch.Elapsed.TotalSeconds / 0.18);
                double k = 1 - Math.Pow(1 - t, 3);
                Left = from.X + (target.X - from.X) * k;
                Top = from.Y + (target.Y - from.Y) * k;
                if (t >= 1) _glide!.Stop();
            };
            _glide.Start();
        }

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
            var edit = new MenuItem { Header = "Расставить виджеты…" };
            edit.Click += (_, _) => WidgetEditor.Open();
            menu.Items.Add(edit);
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
        private static Color _lastTint = Colors.Transparent;

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
            // 0.6.3: the cards are rebuilt only when the cover's colour really
            // changes — a pause used to rebuild them, and the music widget's
            // bars dropped to nothing at once instead of settling softly.
            App.Current.Media.Changed += t => App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                var tint = t?.Tint ?? Colors.Transparent;
                if (Settings.Current.Theme == "cover" && Settings.Current.WidgetStyle != "mono" && tint != _lastTint)
                {
                    _lastTint = tint;
                    RebuildKinds(null);
                }
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

        public static IEnumerable<Rect> OtherRects(string id) =>
            Live.Where(w => w.State.Id != id && w.IsVisible).Select(w => new Rect(w.Left, w.Top, w.Width, w.Height));

        // 0.6.1: the editor takes the desktop over for a while.
        public static void HideAll() { foreach (var w in Live) w.Visibility = Visibility.Hidden; }

        public static void ShowAll()
        {
            foreach (var w in Live) w.Visibility = Visibility.Visible;
            foreach (var w in Live) w.ToBottom();
        }

        // After the editor: the windows follow the new list.
        public static void Apply(List<WidgetState> states)
        {
            foreach (var w in Live.ToList()) { try { w.Close(); } catch { } }
            Live.Clear();
            Settings.Current.Widgets = states;
            foreach (var state in states) Open(state);
        }

        public static void Add(string kind)
        {
            var state = new WidgetState { Kind = kind, Size = WidgetCatalog.Find(kind).Sizes[0] };
            var size = WidgetCatalog.Dimensions(state.Size);
            var place = WidgetGrid.FirstFree(size, Live.Select(w => new Rect(w.Left, w.Top, w.Width, w.Height)).ToList());
            state.X = place.X; state.Y = place.Y;
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
            bool hide = Native.GameCoversDesktop();
            if (hide != _hidden)
            {
                _hidden = hide;
                foreach (var w in Live) w.Visibility = hide ? Visibility.Hidden : Visibility.Visible;
                if (!hide) foreach (var w in Live) w.ToBottom();
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
