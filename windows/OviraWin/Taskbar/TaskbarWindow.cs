using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Ovira.Core;
using Ovira.Services;
using Ovira.Widgets;

namespace Ovira.Taskbar
{
    // How the dock and the clock capsule look in each of the four styles.
    internal sealed class DockLook
    {
        public Brush Back = Brushes.Black, Rim = Brushes.Transparent, Fg = Brushes.White, Fg2 = Brushes.Gray, Hover = Brushes.Transparent, Dot = Brushes.Gray, Accent = Brushes.White;
        public Brush? Gloss;
        public Look Base = null!;
        public Color[] Palette = Array.Empty<Color>();

        private static SolidColorBrush B(byte a, byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromArgb(a, r, g, b)); x.Freeze(); return x; }

        public static DockLook Current()
        {
            var s = Settings.Current;
            var L = Look.For(s.TaskbarStyle);
            var tint = App.Current.Media.Track?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);
            var theme = Themes.Find(s.Theme, tint);
            var d = new DockLook { Base = L, Accent = L.Accent, Palette = theme.Palette };
            switch (s.TaskbarStyle)
            {
                case "white":
                    d.Back = B(0xF0, 0xF7, 0xF7, 0xF9); d.Rim = B(0x1F, 0, 0, 0);
                    d.Fg = B(0xFF, 0x1C, 0x1C, 0x1E); d.Fg2 = B(0x8C, 0x3C, 0x3C, 0x43);
                    d.Hover = B(0x12, 0, 0, 0); d.Dot = B(0x73, 0, 0, 0);
                    break;
                case "mono":
                    d.Back = B(0xFF, 0x1C, 0x1C, 0x1E); d.Rim = B(0x1F, 0xFF, 0xFF, 0xFF);
                    d.Fg = Brushes.White; d.Fg2 = B(0x99, 0xEB, 0xEB, 0xF5);
                    d.Hover = B(0x1A, 0xFF, 0xFF, 0xFF); d.Dot = B(0x8C, 0xFF, 0xFF, 0xFF);
                    break;
                case "theme":
                    d.Back = L.Card; d.Rim = B(0x40, 0xFF, 0xFF, 0xFF);
                    d.Fg = Brushes.White; d.Fg2 = B(0xC7, 0xFF, 0xFF, 0xFF);
                    d.Hover = B(0x26, 0xFF, 0xFF, 0xFF); d.Dot = B(0xB3, 0xFF, 0xFF, 0xFF);
                    d.Gloss = GlossBrush();
                    break;
                default:
                    // «Стекло» — smoked glass, darker than the widgets, because
                    // windows pass under it
                    d.Back = B(0xC7, 0x1E, 0x1E, 0x24); d.Rim = B(0x38, 0xFF, 0xFF, 0xFF);
                    d.Fg = Brushes.White; d.Fg2 = B(0xB3, 0xFF, 0xFF, 0xFF);
                    d.Hover = B(0x1F, 0xFF, 0xFF, 0xFF); d.Dot = B(0x99, 0xFF, 0xFF, 0xFF);
                    d.Gloss = GlossBrush();
                    break;
            }
            return d;
        }

        private static Brush GlossBrush()
        {
            var g = new LinearGradientBrush(Color.FromArgb(0x1C, 0xFF, 0xFF, 0xFF), Color.FromArgb(0x00, 0xFF, 0xFF, 0xFF), 90);
            g.Freeze();
            return g;
        }
    }

    // 0.7.1 — Ovira's taskbar, redone as a floating dock: a rounded capsule
    // at the bottom of the screen with Start, search and the apps — icons
    // grow under the cursor like the Mac's Dock, a name bubble above the
    // icon, live window previews — and a second, smaller capsule on the right
    // with the layout, sound, battery and the clock (like the island's split).
    // Windows keeps the strip under it free (an «app bar»).
    internal sealed class TaskbarWindow : Window
    {
        public const double Capsule = 54;          // the dock's height
        public const double BottomGap = 7;
        public const double Reserve = Capsule + BottomGap + 5;     // the strip windows don't cover
        public const double Headroom = 46;         // room above for the grown icons
        public const double Slot = 50;             // one icon's place
        public const double IconSize = 34;
        public const double MaxGrow = 0.38;        // +38 % right under the cursor

        private IntPtr _hwnd;
        private uint _abMsg, _shellMsg, _createdMsg;
        private bool _registered;
        private double _barTop;
        private bool _fullscreen;
        private DockLook D = DockLook.Current();

        private readonly Grid _root = new() { Background = Brushes.Transparent };
        private readonly Grid _dock = new() { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center };
        private readonly Border _shadow = new();
        private readonly Border _capsule = new();
        private readonly Border _gloss = new() { IsHitTestVisible = false };
        private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(7, 0, 7, 0), VerticalAlignment = VerticalAlignment.Bottom };
        private readonly StackPanel _apps = new() { Orientation = Orientation.Horizontal };
        private readonly Border _divider = new() { Width = 1, Height = 30, Margin = new Thickness(6, 0, 6, (Capsule - 30) / 2), VerticalAlignment = VerticalAlignment.Bottom };
        private DockItem _start = null!, _search = null!;
        private readonly Dictionary<string, DockItem> _buttons = new();
        private readonly List<string> _seenApps = new();
        private readonly List<IntPtr> _seenWindows = new();
        private readonly HashSet<IntPtr> _flashing = new();
        private List<TaskWindow> _windows = new();
        private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };
        private readonly DispatcherTimer _hoverTimer = new() { Interval = TimeSpan.FromSeconds(0.5) };
        private readonly DispatcherTimer _leaveTimer = new() { Interval = TimeSpan.FromSeconds(0.35) };
        private readonly TaskPreview _preview = new();
        private readonly Popup _bubble = new() { AllowsTransparency = true, Placement = PlacementMode.Top, IsHitTestVisible = false, PopupAnimation = PopupAnimation.None };
        private readonly TextBlock _bubbleText = new() { FontSize = 12, FontWeight = FontWeights.SemiBold };
        private readonly Border _bubbleCard = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 4, 10, 5) };
        private DockItem? _hovered;
        private bool _refreshQueued, _magnified;
        private TrayWindow? _tray;

        public TaskbarWindow()
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            UseLayoutRounding = true;
            SizeToContent = SizeToContent.Width;
            Height = Capsule + BottomGap + Headroom;
            Title = "Ovira — панель задач";
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            Left = -10000; Top = -10000;

            _dock.Margin = new Thickness(24, 0, 24, BottomGap);
            _shadow.CornerRadius = _capsule.CornerRadius = _gloss.CornerRadius = new CornerRadius(19);
            _shadow.Height = _capsule.Height = _gloss.Height = Capsule;
            _shadow.VerticalAlignment = _capsule.VerticalAlignment = _gloss.VerticalAlignment = VerticalAlignment.Bottom;
            _shadow.Background = Brushes.Black;
            _shadow.Opacity = 0.55;
            _shadow.Effect = new DropShadowEffect { BlurRadius = 22, ShadowDepth = 4, Direction = 270, Opacity = 0.45 };
            _shadow.CacheMode = new BitmapCache();
            _capsule.BorderThickness = new Thickness(1);
            _gloss.Margin = new Thickness(1);
            _dock.Children.Add(_shadow);
            _dock.Children.Add(_capsule);
            _dock.Children.Add(_gloss);
            _dock.Children.Add(_row);

            _start = new DockItem(null, D) { Glyph = new StartGlyph() };
            _start.Click += _ => TB.Shortcut(TB.VK_LWIN);
            _start.Name2 = "Пуск";
            _search = new DockItem(null, D) { Glyph = new IconView { Icon = "magnifier", Width = 24, Height = 24 } };
            _search.Click += _ => TB.Shortcut(TB.VK_LWIN, 0x53 /* S */);
            _search.Name2 = "Поиск";
            foreach (var item in new[] { _start, _search }) WireHover(item);
            _row.Children.Add(_start);
            _row.Children.Add(_search);
            _row.Children.Add(_divider);
            _row.Children.Add(_apps);

            _root.Children.Add(_dock);
            Content = _root;

            _bubbleCard.Child = _bubbleText;
            _bubble.Child = new Border { Padding = new Thickness(0, 0, 0, 6), Child = _bubbleCard };

            // the Dock's magnification follows the cursor along the capsule
            _dock.MouseMove += (_, e) => Magnify(e.GetPosition(_row).X);
            _dock.MouseLeave += (_, _) => Relax();
            _dock.MouseRightButtonUp += (_, e) => { if (e.Handled) return; e.Handled = true; BarMenu(_capsule, e.GetPosition(_capsule).X); };
            _gloss.IsHitTestVisible = false;

            _poll.Tick += (_, _) => { Refresh(); _tray?.Tick(); SystemTaskbar.KeepHidden(); UpdateFullscreen(); };
            _hoverTimer.Tick += (_, _) => { _hoverTimer.Stop(); if (_hovered != null) ShowPreview(_hovered); };
            _leaveTimer.Tick += (_, _) =>
            {
                _leaveTimer.Stop();
                if (_preview.IsMouseOver || (_hovered != null && _hovered.IsMouseOver)) return;
                _preview.HideNow();
            };
            _preview.MouseEnter += (_, _) => _leaveTimer.Stop();
            _preview.MouseLeave += (_, _) => _leaveTimer.Start();
            _preview.Picked += () => { _preview.HideNow(); QueueRefresh(); };

            ApplyLook();
            SourceInitialized += (_, _) => Attach();
            SizeChanged += (_, _) => Position();
            Loaded += (_, _) =>
            {
                Refresh();
                _poll.Start();
                _tray = new TrayWindow(this);
                _tray.Show();
                // rise from the bottom edge
                var lift = new TranslateTransform(0, Capsule + BottomGap + 10);
                _dock.RenderTransform = lift;
                lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.55)) { EasingFunction = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut } });
            };
            Closed += (_, _) => Detach();
        }

        public DockLook Style2 => D;

        // ================================================================ the app bar

        private void Attach()
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            Native.AddExStyle(_hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
            HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
            _abMsg = TB.RegisterWindowMessage("Ovira.AppBar");
            _shellMsg = TB.RegisterWindowMessage("SHELLHOOK");
            _createdMsg = TB.RegisterWindowMessage("TaskbarCreated");
            TB.RegisterShellHookWindow(_hwnd);
            Register();
            Place();
        }

        private TB.APPBARDATA Data() => new TB.APPBARDATA
        {
            cbSize = System.Runtime.InteropServices.Marshal.SizeOf<TB.APPBARDATA>(),
            hWnd = _hwnd,
            uCallbackMessage = _abMsg,
            uEdge = TB.ABE_BOTTOM,
        };

        private void Register()
        {
            var d = Data();
            TB.SHAppBarMessage(TB.ABM_NEW, ref d);
            _registered = true;
        }

        public static System.Drawing.Rectangle Screen => System.Windows.Forms.Screen.PrimaryScreen!.Bounds;

        // Keep the strip along the bottom free for the dock.
        private void Place()
        {
            if (_hwnd == IntPtr.Zero) return;
            var screen = Screen;
            var dpi = VisualTreeHelper.GetDpi(this);
            int h = (int)Math.Round(Reserve * dpi.DpiScaleY);
            var d = Data();
            d.rc = new TB.RECT { Left = screen.Left, Right = screen.Right, Top = screen.Bottom - h, Bottom = screen.Bottom };
            TB.SHAppBarMessage(TB.ABM_QUERYPOS, ref d);
            d.rc.Top = d.rc.Bottom - h;
            TB.SHAppBarMessage(TB.ABM_SETPOS, ref d);
            _bottom = d.rc.Bottom;
            Position();
            _tray?.Position();
        }

        private int _bottom = int.MinValue;
        public int BottomPx => _bottom == int.MinValue ? Screen.Bottom : _bottom;

        // The window is just as wide as the dock; it stays centred (or on the left).
        private void Position()
        {
            if (_hwnd == IntPtr.Zero || ActualWidth <= 0) return;
            var screen = Screen;
            var dpi = VisualTreeHelper.GetDpi(this);
            int w = (int)Math.Round(ActualWidth * dpi.DpiScaleX), h = (int)Math.Round(ActualHeight * dpi.DpiScaleY);
            int x = Settings.Current.TaskbarAlign == "left" ? screen.Left : screen.Left + (screen.Width - w) / 2;
            int y = BottomPx - h;
            TB.SetWindowPos(_hwnd, TB.HWND_TOPMOST, x, y, 0, 0, TB.SWP_NOSIZE | TB.SWP_NOACTIVATE | TB.SWP_SHOWWINDOW);
            _barTop = (BottomPx - (Capsule + BottomGap) * dpi.DpiScaleY) / dpi.DpiScaleY;
        }

        private void Detach()
        {
            _poll.Stop();
            _preview.HideNow();
            _bubble.IsOpen = false;
            try { _preview.Close(); } catch { }
            try { _tray?.Close(); } catch { }
            if (_hwnd == IntPtr.Zero) return;
            TB.DeregisterShellHookWindow(_hwnd);
            if (_registered)
            {
                var d = Data();
                TB.SHAppBarMessage(TB.ABM_REMOVE, ref d);
                _registered = false;
            }
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled)
        {
            if (msg == _abMsg && _abMsg != 0)
            {
                int code = w.ToInt32();
                if (code == TB.ABN_POSCHANGED) Dispatcher.BeginInvoke(new Action(Place));
                else if (code == TB.ABN_FULLSCREENAPP) Dispatcher.BeginInvoke(new Action(UpdateFullscreen));
            }
            else if (msg == _shellMsg && _shellMsg != 0)
            {
                int code = w.ToInt32() & 0x7FFF;
                if (code == 6 && (w.ToInt32() & 0x8000) != 0) _flashing.Add(l);          // HSHELL_FLASH
                else if (code == 4) _flashing.Remove(l);                                      // activated
                QueueRefresh();
            }
            else if (msg == _createdMsg && _createdMsg != 0)
            {
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    Register();
                    Place();
                    if (Settings.Current.TaskbarHideSystem) SystemTaskbar.Hide();
                }));
            }
            else if (msg == 0x007E /* WM_DISPLAYCHANGE */ || msg == 0x02E0 /* WM_DPICHANGED */)
            {
                Dispatcher.BeginInvoke(new Action(Place), DispatcherPriority.Background);
            }
            return IntPtr.Zero;
        }

        private void UpdateFullscreen()
        {
            bool fs = Native.GameCoversDesktop();
            if (fs == _fullscreen) return;
            _fullscreen = fs;
            _preview.HideNow();
            _bubble.IsOpen = false;
            var v = fs ? Visibility.Hidden : Visibility.Visible;
            Visibility = v;
            if (_tray != null) _tray.Visibility = v;
            if (!fs) Place();
        }

        private void QueueRefresh()
        {
            if (_refreshQueued) return;
            _refreshQueued = true;
            Dispatcher.BeginInvoke(new Action(() => { _refreshQueued = false; Refresh(); }), DispatcherPriority.Background);
        }

        // ================================================================ look

        public void ApplyLook()
        {
            D = DockLook.Current();
            _capsule.Background = D.Back;
            _capsule.BorderBrush = D.Rim;
            _gloss.Background = D.Gloss;
            _divider.Background = D.Hover;
            _bubbleCard.Background = D.Fg is SolidColorBrush f && f.Color.R < 0x80 ? new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF)) : new SolidColorBrush(Color.FromArgb(0xF0, 0x26, 0x26, 0x2A));
            _bubbleText.Foreground = D.Fg;
            _start.Restyle(D);
            _search.Restyle(D);
            if (_start.Glyph is StartGlyph sg) sg.Colours = D.Palette;
            if (_search.Glyph is IconView iv) iv.Fill = D.Fg;
            foreach (var b in _buttons.Values) b.Restyle(D);
            _tray?.ApplyLook();
            Position();
        }

        // ================================================================ magnification

        private IEnumerable<DockItem> Items()
        {
            yield return _start;
            yield return _search;
            foreach (var b in _apps.Children.OfType<DockItem>()) yield return b;
        }

        private void Magnify(double x)
        {
            _magnified = true;
            foreach (var b in Items())
            {
                if (!b.IsVisible || b.ActualWidth <= 0) continue;
                double c;
                try { c = b.TransformToAncestor(_row).Transform(new Point(b.ActualWidth / 2, 0)).X; } catch { continue; }
                double d = Math.Abs(x - c) / (Slot * 1.6);
                double grow = d >= 1 ? 0 : MaxGrow * (Math.Cos(d * Math.PI) + 1) / 2;
                b.SetGrow(grow, animated: false);
            }
        }

        private void Relax()
        {
            if (!_magnified) return;
            _magnified = false;
            foreach (var b in Items()) b.SetGrow(0, animated: true);
        }

        // ================================================================ apps

        private void WireHover(DockItem b)
        {
            b.MouseEnter += (_, _) => OnHover(b);
            b.MouseLeave += (_, _) =>
            {
                if (_hovered == b) _hovered = null;
                _hoverTimer.Stop();
                _bubble.IsOpen = false;
                _leaveTimer.Start();
            };
        }

        private void Refresh()
        {
            if (_hwnd == IntPtr.Zero) return;
            var previewHwnd = new WindowInteropHelper(_preview).Handle;
            var trayHwnd = _tray != null ? new WindowInteropHelper(_tray).Handle : IntPtr.Zero;
            _windows = AppWindows.List(_hwnd, previewHwnd).Where(w => w.Handle != trayHwnd).ToList();
            var alive = new HashSet<IntPtr>(_windows.Select(w => w.Handle));
            _seenWindows.RemoveAll(h => !alive.Contains(h));
            foreach (var w in _windows) if (!_seenWindows.Contains(w.Handle)) _seenWindows.Add(w.Handle);
            _flashing.RemoveWhere(h => !alive.Contains(h));
            var fg = TB.GetForegroundWindow();
            _flashing.Remove(fg);

            var groups = _windows.GroupBy(w => w.App)
                                 .ToDictionary(g => g.Key, g => g.OrderBy(w => _seenWindows.IndexOf(w.Handle)).ToList());
            var pinned = Settings.Current.TaskbarPinned.Select(p => p.ToLowerInvariant()).ToList();
            foreach (var app in groups.Keys) if (!_seenApps.Contains(app)) _seenApps.Add(app);
            _seenApps.RemoveAll(a => !groups.ContainsKey(a));
            var order = pinned.Concat(_seenApps.Where(a => !pinned.Contains(a))).Distinct().ToList();

            foreach (var key in _buttons.Keys.Where(k => !order.Contains(k)).ToList())
            {
                var b = _buttons[key];
                _buttons.Remove(key);
                b.Leave(() => _apps.Children.Remove(b));
            }
            var live = new List<DockItem>();
            for (int i = 0; i < order.Count; i++)
            {
                var app = order[i];
                groups.TryGetValue(app, out var list);
                list ??= new List<TaskWindow>();
                if (!_buttons.TryGetValue(app, out var b))
                {
                    b = new DockItem(app, D);
                    b.Click += OnAppClick;
                    b.MiddleClick += a => { a.Bounce(); AppWindows.Launch(a.App!); };
                    b.MenuWanted += AppMenu;
                    WireHover(b);
                    _buttons[app] = b;
                    _apps.Children.Add(b);
                    b.Enter(animated: IsLoaded);
                }
                b.Windows = list;
                b.Pinned = pinned.Contains(app);
                b.SetState(list.Count, list.Any(w => w.Handle == fg), list.Any(w => _flashing.Contains(w.Handle)));
                if (b.IconSource == null) b.IconSource = AppWindows.IconOf(app, list.FirstOrDefault()?.Handle ?? IntPtr.Zero);
                live.Add(b);
            }
            // keep the order (leaving buttons stay where they were)
            int slot = 0;
            foreach (var b in live)
            {
                while (slot < _apps.Children.Count && _apps.Children[slot] is DockItem x && !x.IsHitTestVisible) slot++;
                int at = _apps.Children.IndexOf(b);
                if (at != slot && at >= 0) { _apps.Children.RemoveAt(at); _apps.Children.Insert(Math.Min(slot, _apps.Children.Count), b); }
                slot++;
            }
            _divider.Visibility = order.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (_preview.Showing && _buttons.TryGetValue(_preview.App, out var shown) && shown.Windows.Count == 0) _preview.HideNow();
        }

        private void OnHover(DockItem b)
        {
            _hovered = b;
            _leaveTimer.Stop();
            if (_preview.Showing)
            {
                if (b.App == null || b.Windows.Count == 0) _preview.HideNow();
                else if (_preview.App != b.App) ShowPreview(b);
                return;
            }
            ShowBubble(b);
            if (b.App != null && b.Windows.Count > 0) _hoverTimer.Start();
        }

        private void ShowBubble(DockItem b)
        {
            _bubbleText.Text = b.App != null ? AppWindows.NameOf(b.App) : b.Name2;
            if (_bubbleText.Text.Length == 0) return;
            _bubble.IsOpen = false;
            _bubble.PlacementTarget = b;
            _bubble.Child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            _bubble.HorizontalOffset = (b.ActualWidth - _bubble.Child.DesiredSize.Width) / 2;
            _bubble.VerticalOffset = -(Slot - (Capsule - 6)) - IconSize * MaxGrow - 2;
            _bubble.IsOpen = true;
            _bubble.Child.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.14)));
        }

        private void ShowPreview(DockItem b)
        {
            if (b.App == null || b.Windows.Count == 0) { _preview.HideNow(); return; }
            _bubble.IsOpen = false;
            var dpi = VisualTreeHelper.GetDpi(this);
            var p = b.PointToScreen(new Point(0, 0));
            var rect = new Rect(p.X / dpi.DpiScaleX, p.Y / dpi.DpiScaleY, b.ActualWidth, b.ActualHeight);
            _preview.ShowFor(b.App, b.Windows.ToList(), D.Base, rect, _barTop - IconSize * MaxGrow);
        }

        private void OnAppClick(DockItem b)
        {
            _hoverTimer.Stop();
            _preview.HideNow();
            _bubble.IsOpen = false;
            var list = b.Windows.Where(w => TB.IsWindow(w.Handle)).ToList();
            if (list.Count == 0) { b.Bounce(); AppWindows.Launch(b.App!); return; }
            var fg = TB.GetForegroundWindow();
            int at = list.FindIndex(w => w.Handle == fg);
            if (list.Count == 1)
            {
                if (at == 0 && !TB.IsIconic(fg)) AppWindows.Minimize(fg);
                else AppWindows.Activate(list[0].Handle);
            }
            else AppWindows.Activate(list[at < 0 ? 0 : (at + 1) % list.Count].Handle);
            QueueRefresh();
        }

        private static string WindowCount(int n) =>
            n == 0 ? "Не запущено" :
            n % 10 == 1 && n % 100 != 11 ? $"{n} окно" :
            n % 10 is >= 2 and <= 4 && (n % 100 < 10 || n % 100 >= 20) ? $"{n} окна" : $"{n} окон";

        private void AppMenu(DockItem b)
        {
            _hoverTimer.Stop();
            _preview.HideNow();
            _bubble.IsOpen = false;
            var app = b.App!;
            bool real = !app.Contains('|');
            var menu = new OviraMenu(D.Base).Header(b.IconSource, "grid", AppWindows.NameOf(app), WindowCount(b.Windows.Count));
            if (real)
            {
                menu.Item("plus", b.Windows.Count > 0 ? "Новое окно" : "Открыть", () => { b.Bounce(); AppWindows.Launch(app); });
                menu.Item("pin", b.Pinned ? "Открепить от панели" : "Закрепить на панели", () => TogglePin(app, !b.Pinned));
            }
            if (b.Windows.Count > 0)
            {
                var handles = b.Windows.Select(w => w.Handle).ToList();
                menu.Item("minimize", handles.Count == 1 ? "Свернуть" : "Свернуть все", () => { foreach (var h in handles) AppWindows.Minimize(h); });
                menu.Separator();
                menu.Item("xmark", handles.Count == 1 ? "Закрыть окно" : $"Закрыть все окна ({handles.Count})", () => { foreach (var h in handles) AppWindows.Close(h); }, danger: true);
            }
            menu.Open(b);
        }

        private static void TogglePin(string app, bool pin)
        {
            var list = Settings.Current.TaskbarPinned.ToList();
            list.RemoveAll(p => string.Equals(p, app, StringComparison.OrdinalIgnoreCase));
            if (pin) list.Add(app);
            Settings.Current.TaskbarPinned = list;
        }

        public void PinnedChanged() => Refresh();

        public void BarMenu(FrameworkElement target, double? atX)
        {
            _preview.HideNow();
            _bubble.IsOpen = false;
            new OviraMenu(D.Base)
                .Header(null, "grid", "Панель задач", "Ovira")
                .Item("gear", "Настройки панели", () => { Settings.Current.Section = "widgets"; App.Current.OpenSettings(); })
                .Item("chart", "Диспетчер задач", () => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("taskmgr.exe") { UseShellExecute = true }); } catch { } })
                .Item("eye", "Прятать панель Windows", () => Settings.Current.TaskbarHideSystem = !Settings.Current.TaskbarHideSystem, check: Settings.Current.TaskbarHideSystem)
                .Separator()
                .Item("xmark", "Выключить панель Ovira", () => Settings.Current.TaskbarEnabled = false, danger: true)
                .Open(target, atX);
        }
    }

    // ==================================================================== one icon

    // An app (or Start / search) in the dock: the icon grows under the
    // cursor, dips when pressed and springs back like the island's buttons,
    // hops when an app starts. Under it a dot while the app runs — a wider
    // pill in the theme colour for the window in front, orange when it asks
    // for attention.
    internal sealed class DockItem : Grid
    {
        public string? App { get; }
        public string Name2 = "";
        public List<TaskWindow> Windows = new();
        public bool Pinned;

        private readonly Border _hover = new() { CornerRadius = new CornerRadius(12), Width = 44, Height = 44, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 5), Opacity = 0 };
        private readonly Grid _iconBox = new() { Width = TaskbarWindow.IconSize, Height = TaskbarWindow.IconSize, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, (TaskbarWindow.Capsule - TaskbarWindow.IconSize) / 2 + 1) };
        private readonly Image _image = new();
        private FrameworkElement? _glyph;
        private readonly Border _dot = new() { Height = 4, Width = 0, CornerRadius = new CornerRadius(2), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 3) };
        private readonly ScaleTransform _press = new(1, 1);
        private readonly ScaleTransform _grow = new(1, 1);
        private readonly TranslateTransform _hop = new(0, 0);
        private DockLook _look;
        private bool _down, _active, _flash;
        private int _count = -1;

        public event Action<DockItem>? Click, MiddleClick, MenuWanted;

        public ImageSource? IconSource { get => _image.Source; set => _image.Source = value; }

        public FrameworkElement? Glyph
        {
            get => _glyph;
            set
            {
                if (_glyph != null) _iconBox.Children.Remove(_glyph);
                _glyph = value;
                if (value != null) { value.Width = value.Width is double w && !double.IsNaN(w) ? w : 28; _iconBox.Children.Add(value); value.HorizontalAlignment = HorizontalAlignment.Center; value.VerticalAlignment = VerticalAlignment.Center; }
            }
        }

        public DockItem(string? app, DockLook look)
        {
            App = app;
            _look = look;
            Width = TaskbarWindow.Slot;
            Height = TaskbarWindow.Capsule;
            VerticalAlignment = VerticalAlignment.Bottom;
            Background = Brushes.Transparent;
            Cursor = Cursors.Hand;
            RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);
            _iconBox.Children.Add(_image);
            var group = new TransformGroup();
            group.Children.Add(_press);
            group.Children.Add(_grow);
            group.Children.Add(_hop);
            _iconBox.RenderTransformOrigin = new Point(0.5, 1);
            _iconBox.RenderTransform = group;
            Children.Add(_hover);
            Children.Add(_iconBox);
            Children.Add(_dot);
            ClipToBounds = false;
            Restyle(look);

            MouseEnter += (_, _) => Highlight();
            MouseLeave += (_, _) => { Highlight(); if (_down) { _down = false; Press(1); } };
            MouseLeftButtonDown += (_, e) => { _down = true; Press(0.84, fast: true); e.Handled = true; };
            MouseLeftButtonUp += (_, e) =>
            {
                if (!_down) return;
                _down = false;
                Press(1);
                e.Handled = true;
                Click?.Invoke(this);
            };
            MouseUp += (_, e) => { if (e.ChangedButton == MouseButton.Middle && App != null) { e.Handled = true; MiddleClick?.Invoke(this); } };
            MouseRightButtonUp += (_, e) => { if (App == null) return; e.Handled = true; MenuWanted?.Invoke(this); };
        }

        public void Restyle(DockLook look)
        {
            _look = look;
            _hover.Background = look.Hover;
            ApplyDot(false);
        }

        public void SetState(int count, bool active, bool flash)
        {
            if (count == _count && active == _active && flash == _flash) return;
            _count = count; _active = active; _flash = flash;
            ApplyDot(true);
            Highlight();
        }

        private void ApplyDot(bool animated)
        {
            double width = _count <= 0 ? 0 : _active ? 16 : 5;
            _dot.Background = _flash ? new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)) : _active ? _look.Accent : _look.Dot;
            if (!animated) { _dot.BeginAnimation(WidthProperty, null); _dot.Width = width; return; }
            _dot.BeginAnimation(WidthProperty, new DoubleAnimation(width, TimeSpan.FromSeconds(0.38)) { EasingFunction = new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut } });
        }

        private void Highlight()
        {
            double to = _flash ? 1 : IsMouseOver ? 0 : 0;   // the icon grows instead of a box
            _hover.Background = _flash ? new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0x9F, 0x0A)) : _look.Hover;
            _hover.BeginAnimation(OpacityProperty, new DoubleAnimation(to, TimeSpan.FromSeconds(0.2)));
        }

        public void SetGrow(double grow, bool animated)
        {
            double s = 1 + grow;
            if (!animated)
            {
                _grow.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                _grow.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                _grow.ScaleX = _grow.ScaleY = s;
                return;
            }
            var a = new DoubleAnimation(s, TimeSpan.FromSeconds(0.32)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            _grow.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            _grow.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }

        private void Press(double to, bool fast = false)
        {
            var a = fast ? new DoubleAnimation(to, TimeSpan.FromSeconds(0.1))
                         : new DoubleAnimation(to, TimeSpan.FromSeconds(0.45)) { EasingFunction = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut } };
            _press.CenterX = TaskbarWindow.IconSize / 2;
            _press.CenterY = TaskbarWindow.IconSize / 2;
            _press.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            _press.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }

        // a hop, like an app starting in the Dock
        public void Bounce()
        {
            var hop = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.75) };
            hop.KeyFrames.Add(new EasingDoubleKeyFrame(-14, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.22)), new QuadraticEase { EasingMode = EasingMode.EaseOut }));
            hop.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.75)), new BounceEase { Bounces = 2, Bounciness = 2.5, EasingMode = EasingMode.EaseOut }));
            _hop.BeginAnimation(TranslateTransform.YProperty, hop);
        }

        public void Enter(bool animated)
        {
            if (!animated) return;
            BeginAnimation(WidthProperty, new DoubleAnimation(0, TaskbarWindow.Slot, TimeSpan.FromSeconds(0.34)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            _iconBox.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.25)) { BeginTime = TimeSpan.FromSeconds(0.06) });
            var pop = new DoubleAnimation(0.3, 1, TimeSpan.FromSeconds(0.5)) { EasingFunction = new BackEase { Amplitude = 0.45, EasingMode = EasingMode.EaseOut } };
            _press.CenterX = TaskbarWindow.IconSize / 2;
            _press.CenterY = TaskbarWindow.IconSize / 2;
            _press.BeginAnimation(ScaleTransform.ScaleXProperty, pop);
            _press.BeginAnimation(ScaleTransform.ScaleYProperty, pop);
        }

        public void Leave(Action done)
        {
            IsHitTestVisible = false;
            var away = new DoubleAnimation(0.3, TimeSpan.FromSeconds(0.24)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn } };
            _press.CenterX = TaskbarWindow.IconSize / 2;
            _press.CenterY = TaskbarWindow.IconSize / 2;
            _press.BeginAnimation(ScaleTransform.ScaleXProperty, away);
            _press.BeginAnimation(ScaleTransform.ScaleYProperty, away);
            _iconBox.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.2)));
            _dot.BeginAnimation(WidthProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.15)));
            var shrink = new DoubleAnimation(ActualWidth, 0, TimeSpan.FromSeconds(0.3)) { BeginTime = TimeSpan.FromSeconds(0.12), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } };
            shrink.Completed += (_, _) => done();
            BeginAnimation(WidthProperty, shrink);
        }
    }

    // Start: four rounded tiles in the theme's colours.
    internal sealed class StartGlyph : FrameworkElement
    {
        private Color[] _colours = Array.Empty<Color>();
        public Color[] Colours { get => _colours; set { _colours = value; InvalidateVisual(); } }

        public StartGlyph() { Width = 26; Height = 26; }

        protected override void OnRender(DrawingContext dc)
        {
            double s = Math.Min(ActualWidth, ActualHeight);
            double gap = s * 0.08, t = (s - gap) / 2, r = s * 0.09;
            var a = _colours.Length > 0 ? _colours[0] : Color.FromRgb(0x3D, 0x85, 0xFF);
            var b = _colours.Length > 1 ? _colours[1] : Themes.MixWhite(a, 0.35);
            var brush = new LinearGradientBrush(Themes.MixWhite(a, 0.15), b, new Point(0, 0), new Point(1, 1));
            brush.Freeze();
            for (int i = 0; i < 4; i++)
            {
                double x = (i % 2) * (t + gap), y = (i / 2) * (t + gap);
                dc.DrawRoundedRectangle(brush, null, new Rect(x, y, t, t), r, r);
            }
        }
    }

    // ==================================================================== the clock capsule

    // On the right: layout, sound, battery, the clock, and a thin edge that
    // shows the desktop. Its own small window so the dock's stays narrow.
    internal sealed class TrayWindow : Window
    {
        private const double H = 44;
        private readonly TaskbarWindow _bar;
        private IntPtr _hwnd;
        private readonly Border _shadow = new(), _capsule = new(), _gloss = new() { IsHitTestVisible = false };
        private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0, 4, 0) };
        private readonly List<TrayButton> _buttons = new();
        private TextBlock _time = null!, _date = null!, _lang = null!, _pct = null!;
        private IconView _speaker = null!, _battery = null!;
        private TrayButton _batteryButton = null!;

        public TrayWindow(TaskbarWindow bar)
        {
            _bar = bar;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            UseLayoutRounding = true;
            SizeToContent = SizeToContent.WidthAndHeight;
            Title = "Ovira — часы";
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            Left = -10000; Top = -10000;

            var grid = new Grid { Margin = new Thickness(18, 18, 10, 0), Height = H };
            _shadow.CornerRadius = _capsule.CornerRadius = _gloss.CornerRadius = new CornerRadius(15);
            _shadow.Background = Brushes.Black;
            _shadow.Opacity = 0.55;
            _shadow.Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Direction = 270, Opacity = 0.4 };
            _shadow.CacheMode = new BitmapCache();
            _capsule.BorderThickness = new Thickness(1);
            _gloss.Margin = new Thickness(1);
            grid.Children.Add(_shadow);
            grid.Children.Add(_capsule);
            grid.Children.Add(_gloss);
            grid.Children.Add(_row);
            // the bottom of the capsule lines up with the middle of the dock
            var outer = new Grid { Margin = new Thickness(0, 0, 0, TaskbarWindow.BottomGap + (TaskbarWindow.Capsule - H) / 2) };
            outer.Children.Add(grid);
            Content = outer;

            _lang = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            Add(new TrayButton(_lang, 42), () => TB.Shortcut(TB.VK_LWIN, TB.VK_SPACE));

            _speaker = new IconView { Icon = "speaker.wave", Width = 18, Height = 18 };
            var sound = Add(new TrayButton(_speaker, 38), () => TB.Shortcut(TB.VK_LWIN, 0x41 /* A */));
            sound.MouseWheel += (_, e) =>
            {
                var audio = App.Current.Audio;
                audio.Volume = (float)Math.Round(audio.Volume + (e.Delta > 0 ? 0.02 : -0.02), 2);
                Tick();
                e.Handled = true;
            };

            _battery = new IconView { Icon = "battery", Width = 20, Height = 20 };
            _pct = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
            var bs = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            bs.Children.Add(_battery);
            bs.Children.Add(_pct);
            _batteryButton = Add(new TrayButton(bs, 64), () => TB.Shortcut(TB.VK_LWIN, 0x41));

            _time = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Right };
            _date = new TextBlock { FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, -1, 0, 0) };
            var cs = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
            cs.Children.Add(_time);
            cs.Children.Add(_date);
            Add(new TrayButton(cs, double.NaN), () => TB.Shortcut(TB.VK_LWIN, 0x4E /* N */));

            // show the desktop
            var desk = new IconView { Icon = "minimize", Width = 12, Height = 12 };
            Add(new TrayButton(desk, 26), () => TB.Shortcut(TB.VK_LWIN, 0x44 /* D */));

            _capsule.MouseRightButtonUp += (_, e) => { e.Handled = true; _bar.BarMenu(_capsule, e.GetPosition(_capsule).X); };
            _row.MouseRightButtonUp += (_, e) => { e.Handled = true; _bar.BarMenu(_capsule, e.GetPosition(_capsule).X); };

            ApplyLook();
            Tick();
            SourceInitialized += (_, _) =>
            {
                _hwnd = new WindowInteropHelper(this).Handle;
                Native.AddExStyle(_hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
            };
            SizeChanged += (_, _) => Position();
            Loaded += (_, _) =>
            {
                Position();
                var lift = new TranslateTransform(0, 70);
                grid.RenderTransform = lift;
                lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.6)) { BeginTime = TimeSpan.FromSeconds(0.08), EasingFunction = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut } });
            };
        }

        private TrayButton Add(TrayButton b, Action click)
        {
            b.Clicked += click;
            _buttons.Add(b);
            _row.Children.Add(b);
            return b;
        }

        public void Position()
        {
            if (_hwnd == IntPtr.Zero || ActualWidth <= 0) return;
            var screen = TaskbarWindow.Screen;
            var dpi = VisualTreeHelper.GetDpi(this);
            int w = (int)Math.Round(ActualWidth * dpi.DpiScaleX), h = (int)Math.Round(ActualHeight * dpi.DpiScaleY);
            TB.SetWindowPos(_hwnd, TB.HWND_TOPMOST, screen.Right - w, _bar.BottomPx - h, 0, 0, TB.SWP_NOSIZE | TB.SWP_NOACTIVATE | TB.SWP_SHOWWINDOW);
        }

        public void ApplyLook()
        {
            var d = _bar.Style2;
            _capsule.Background = d.Back;
            _capsule.BorderBrush = d.Rim;
            _gloss.Background = d.Gloss;
            foreach (var b in _buttons) b.Hover = d.Hover;
            _time.Foreground = d.Fg; _date.Foreground = d.Fg2; _lang.Foreground = d.Fg; _pct.Foreground = d.Fg;
            _speaker.Fill = d.Fg; _battery.Fill = d.Fg;
            foreach (var b in _buttons) if (b.Content is IconView v && v.Icon == "minimize") v.Fill = d.Fg2;
        }

        public void Tick()
        {
            var now = DateTime.Now;
            _time.Text = now.ToString(Settings.Current.TaskbarSeconds ? "HH:mm:ss" : "HH:mm");
            _date.Text = now.ToString("d MMM", new System.Globalization.CultureInfo("ru-RU")).TrimEnd('.') + ", " +
                         now.ToString("ddd", new System.Globalization.CultureInfo("ru-RU"));
            var layout = KeyboardWatch.CurrentLayout();
            _lang.Text = layout switch { "RU" => "РУС", "EN" => "ENG", "UK" => "УКР", "BE" => "БЕЛ", "KK" => "ҚАЗ", "" => _lang.Text, _ => layout };
            var audio = App.Current.Audio;
            _speaker.Icon = audio.Muted || audio.Volume < 0.005 ? "speaker.slash" : "speaker.wave";
            bool has = false;
            var power = App.Current.Power;
            try { has = power.HasBattery; } catch { }
            _batteryButton.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
            if (has)
            {
                _battery.Icon = power.Charging ? "bolt" : "battery";
                _pct.Text = power.Percent + "%";
            }
        }
    }

    internal sealed class TrayButton : Grid
    {
        private readonly Border _hover = new() { CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 5, 0, 5), Opacity = 0 };
        private readonly ScaleTransform _scale = new(1, 1);
        private bool _down;
        public FrameworkElement Content { get; }
        public event Action? Clicked;
        public Brush Hover { set => _hover.Background = value; }

        public TrayButton(FrameworkElement content, double width)
        {
            Content = content;
            Width = width;
            if (double.IsNaN(width)) MinWidth = 60;
            Background = Brushes.Transparent;
            Cursor = Cursors.Hand;
            Children.Add(_hover);
            content.HorizontalAlignment = content.HorizontalAlignment == HorizontalAlignment.Stretch ? HorizontalAlignment.Center : content.HorizontalAlignment;
            content.VerticalAlignment = VerticalAlignment.Center;
            content.RenderTransformOrigin = new Point(0.5, 0.5);
            content.RenderTransform = _scale;
            Children.Add(content);
            MouseEnter += (_, _) => _hover.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.12)));
            MouseLeave += (_, _) => { _hover.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.22))); if (_down) { _down = false; Spring(1); } };
            MouseLeftButtonDown += (_, e) => { _down = true; Spring(0.86, true); e.Handled = true; };
            MouseLeftButtonUp += (_, e) =>
            {
                if (!_down) return;
                _down = false;
                Spring(1);
                e.Handled = true;
                Clicked?.Invoke();
            };
        }

        private void Spring(double to, bool fast = false)
        {
            var a = fast ? new DoubleAnimation(to, TimeSpan.FromSeconds(0.1))
                         : new DoubleAnimation(to, TimeSpan.FromSeconds(0.42)) { EasingFunction = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut } };
            _scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            _scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
    }
}
