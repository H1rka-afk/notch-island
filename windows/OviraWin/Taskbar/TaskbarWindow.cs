using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Ovira.Core;
using Ovira.Services;
using Ovira.Widgets;

namespace Ovira.Taskbar
{
    // 0.7.0 — Ovira's own taskbar. A strip along the bottom of the main
    // screen that Windows keeps free for it (an «app bar», like the real
    // taskbar): Start, search, pinned and running apps with live previews,
    // and on the right the keyboard layout, sound, battery and the clock.
    // Buttons move with the island's springs.
    internal sealed class TaskbarWindow : Window
    {
        public const double BarHeight = 48;

        private IntPtr _hwnd;
        private uint _abMsg, _shellMsg, _createdMsg;
        private bool _registered;
        private double _barTop;                    // DIPs, for the previews
        private bool _fullscreen;
        private Look L = Look.For(Settings.Current.TaskbarStyle);

        private readonly Grid _root = new();
        private readonly Border _back = new();
        private readonly StackPanel _center = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        private readonly StackPanel _apps = new() { Orientation = Orientation.Horizontal };
        private readonly StackPanel _tray = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Stretch };
        private readonly Dictionary<string, AppButton> _buttons = new();
        private readonly List<string> _seenApps = new();
        private readonly List<IntPtr> _seenWindows = new();
        private readonly HashSet<IntPtr> _flashing = new();
        private List<TaskWindow> _windows = new();
        private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };
        private readonly DispatcherTimer _hoverTimer = new() { Interval = TimeSpan.FromSeconds(0.45) };
        private readonly DispatcherTimer _leaveTimer = new() { Interval = TimeSpan.FromSeconds(0.35) };
        private readonly TaskPreview _preview = new();
        private AppButton? _hovered;
        private bool _refreshQueued;

        private TextBlock _time = null!, _date = null!, _lang = null!, _batteryText = null!;
        private IconView _speaker = null!, _battery = null!;
        private FrameworkElement _batteryHost = null!;

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
            Title = "Ovira — панель задач";
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            Left = 0; Top = SystemParameters.PrimaryScreenHeight - BarHeight;
            Width = SystemParameters.PrimaryScreenWidth; Height = BarHeight;

            _root.Children.Add(_back);
            _root.Children.Add(_center);
            _root.Children.Add(_tray);
            Content = _root;

            _center.Children.Add(BarButton("windows", StartMenu, accent: true));
            _center.Children.Add(BarButton("magnifier", () => TB.Shortcut(TB.VK_LWIN, 0x53 /* S */)));
            _center.Children.Add(_apps);
            BuildTray();
            ApplyLook();

            _root.MouseRightButtonUp += (_, e) => { if (!e.Handled) { BarMenu().IsOpen = true; e.Handled = true; } };
            _poll.Tick += (_, _) => { Refresh(); Tick(); SystemTaskbar.KeepHidden(); UpdateFullscreen(); };
            _hoverTimer.Tick += (_, _) => { _hoverTimer.Stop(); if (_hovered != null) ShowPreview(_hovered); };
            _leaveTimer.Tick += (_, _) =>
            {
                _leaveTimer.Stop();
                if (_preview.IsMouseOver || (_hovered != null && _hovered.IsMouseOver)) return;
                _preview.HideNow();
            };
            _preview.MouseEnter += (_, _) => _leaveTimer.Stop();
            _preview.MouseLeave += (_, _) => _leaveTimer.Start();
            _preview.Picked += () => { _preview.HideNow(); Dispatcher.BeginInvoke(new Action(Refresh), DispatcherPriority.Background); };

            SourceInitialized += (_, _) => Attach();
            Loaded += (_, _) =>
            {
                Refresh();
                Tick();
                _poll.Start();
                // rise from the bottom edge
                var lift = new TranslateTransform(0, BarHeight);
                _root.RenderTransform = lift;
                lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.42)) { EasingFunction = new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut } });
            };
            Closed += (_, _) => Detach();
        }

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
            ApplyBlur();
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

        private void Place()
        {
            if (_hwnd == IntPtr.Zero) return;
            var screen = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;      // device pixels
            var dpi = VisualTreeHelper.GetDpi(this);
            int h = (int)Math.Round(BarHeight * dpi.DpiScaleY);
            var d = Data();
            d.rc = new TB.RECT { Left = screen.Left, Right = screen.Right, Top = screen.Bottom - h, Bottom = screen.Bottom };
            TB.SHAppBarMessage(TB.ABM_QUERYPOS, ref d);
            d.rc.Top = d.rc.Bottom - h;
            TB.SHAppBarMessage(TB.ABM_SETPOS, ref d);
            TB.SetWindowPos(_hwnd, TB.HWND_TOPMOST, d.rc.Left, d.rc.Top, d.rc.Right - d.rc.Left, h, TB.SWP_NOACTIVATE | TB.SWP_SHOWWINDOW);
            _barTop = d.rc.Top / dpi.DpiScaleY;
        }

        private void Detach()
        {
            _poll.Stop();
            _preview.HideNow();
            try { _preview.Close(); } catch { }
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
                // Explorer started again: it forgot the app bar and shows its taskbar.
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
            if (fs) Visibility = Visibility.Hidden;
            else
            {
                Visibility = Visibility.Visible;
                Place();
            }
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
            L = Look.For(Settings.Current.TaskbarStyle);
            _back.Background = L.Card;
            _back.BorderBrush = L.Border;
            _back.BorderThickness = new Thickness(0, 1, 0, 0);
            bool left = Settings.Current.TaskbarAlign == "left";
            _center.HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Center;
            _center.Margin = new Thickness(left ? 8 : 0, 0, 0, 0);
            foreach (var b in _buttons.Values) b.Restyle(L);
            foreach (var b in _center.Children.OfType<BarIconButton>()) b.Restyle(L);
            foreach (var b in _tray.Children.OfType<BarIconButton>()) b.Restyle(L);
            if (_time != null)
            {
                _time.Foreground = L.Fg; _date.Foreground = L.Fg; _lang.Foreground = L.Fg;
                _batteryText.Foreground = L.Fg; _speaker.Fill = L.Fg; _battery.Fill = L.Fg;
            }
            ApplyBlur();
        }

        private void ApplyBlur()
        {
            if (_hwnd != IntPtr.Zero) TB.Blur(_hwnd, Settings.Current.TaskbarStyle == "glass");
        }

        // ================================================================ start, search, tray

        private void StartMenu() => TB.Shortcut(TB.VK_LWIN);

        private BarIconButton BarButton(string icon, Action click, bool accent = false)
        {
            var b = new BarIconButton(icon, accent, L);
            b.Clicked += click;
            return b;
        }

        private void BuildTray()
        {
            // keyboard layout — click: next layout (Win+Space)
            _lang = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            var lang = new BarIconButton(_lang, L) { Width = 40 };
            lang.Clicked += () => TB.Shortcut(TB.VK_LWIN, TB.VK_SPACE);
            _tray.Children.Add(lang);

            // sound — click: quick settings (Win+A); wheel: volume
            _speaker = new IconView { Icon = "speaker.wave", Width = 18, Height = 18 };
            var sound = new BarIconButton(_speaker, L) { Width = 40 };
            sound.Clicked += () => TB.Shortcut(TB.VK_LWIN, 0x41 /* A */);
            sound.MouseWheel += (_, e) =>
            {
                var audio = App.Current.Audio;
                audio.Volume = (float)Math.Round(audio.Volume + (e.Delta > 0 ? 0.02 : -0.02), 2);
                Tick();
                e.Handled = true;
            };
            _tray.Children.Add(sound);

            // battery (laptops)
            _battery = new IconView { Icon = "battery", Width = 20, Height = 20 };
            _batteryText = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
            var bstack = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            bstack.Children.Add(_battery);
            bstack.Children.Add(_batteryText);
            var battery = new BarIconButton(bstack, L) { Width = 64 };
            battery.Clicked += () => TB.Shortcut(TB.VK_LWIN, 0x41);
            _batteryHost = battery;
            _tray.Children.Add(battery);

            // clock — click: notifications and calendar (Win+N)
            _time = new TextBlock { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Right };
            _date = new TextBlock { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Right };
            var cstack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
            cstack.Children.Add(_time);
            cstack.Children.Add(_date);
            var clock = new BarIconButton(cstack, L) { MinWidth = 70, Width = double.NaN };
            clock.Clicked += () => TB.Shortcut(TB.VK_LWIN, 0x4E /* N */);
            _tray.Children.Add(clock);

            // the sliver at the very edge — show the desktop (Win+D)
            var edge = new Border { Width = 10, Background = Brushes.Transparent, Cursor = Cursors.Hand, Margin = new Thickness(4, 0, 0, 0) };
            var line = new Border { Width = 1, Height = 18, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent };
            edge.Child = line;
            edge.MouseEnter += (_, _) => line.Background = L.Fg2;
            edge.MouseLeave += (_, _) => line.Background = Brushes.Transparent;
            edge.MouseLeftButtonUp += (_, e) => { e.Handled = true; TB.Shortcut(TB.VK_LWIN, 0x44 /* D */); };
            _tray.Children.Add(edge);
        }

        private void Tick()
        {
            var now = DateTime.Now;
            _time.Text = now.ToString(Settings.Current.TaskbarSeconds ? "HH:mm:ss" : "HH:mm");
            _date.Text = now.ToString("dd.MM.yyyy");
            var layout = KeyboardWatch.CurrentLayout();
            _lang.Text = layout switch { "RU" => "РУС", "EN" => "ENG", "UK" => "УКР", "BE" => "БЕЛ", "KK" => "ҚАЗ", "" => _lang.Text, _ => layout };
            var audio = App.Current.Audio;
            _speaker.Icon = audio.Muted || audio.Volume < 0.005 ? "speaker.slash" : "speaker.wave";
            var power = App.Current.Power;
            bool has = false;
            try { has = power.HasBattery; } catch { }
            _batteryHost.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
            if (has)
            {
                int pct = power.Percent;
                _battery.Icon = power.Charging ? "bolt" : "battery";
                _batteryText.Text = pct + "%";
            }
        }

        // ================================================================ apps

        private void Refresh()
        {
            if (_hwnd == IntPtr.Zero) return;
            var previewHwnd = new WindowInteropHelper(_preview).Handle;
            _windows = AppWindows.List(_hwnd, previewHwnd);
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

            // gone
            foreach (var key in _buttons.Keys.Where(k => !order.Contains(k)).ToList())
            {
                var b = _buttons[key];
                _buttons.Remove(key);
                b.Leave(() => _apps.Children.Remove(b));
            }
            // new and changed
            for (int i = 0; i < order.Count; i++)
            {
                var app = order[i];
                groups.TryGetValue(app, out var list);
                list ??= new List<TaskWindow>();
                if (!_buttons.TryGetValue(app, out var b))
                {
                    b = new AppButton(app, L);
                    b.Click += OnAppClick;
                    b.MiddleClick += a => AppWindows.Launch(a.App);
                    b.MenuWanted += a => AppMenu(a).IsOpen = true;
                    b.MouseEnter += (_, _) => OnHover(b);
                    b.MouseLeave += (_, _) => { if (_hovered == b) _hovered = null; _hoverTimer.Stop(); _leaveTimer.Start(); };
                    _buttons[app] = b;
                    _apps.Children.Add(b);
                    b.Enter(animated: IsLoaded);
                }
                b.Windows = list;
                b.Pinned = pinned.Contains(app);
                b.SetState(list.Count, list.Any(w => w.Handle == fg), list.Any(w => _flashing.Contains(w.Handle)));
                if (b.IconSource == null) b.IconSource = AppWindows.IconOf(app, list.FirstOrDefault()?.Handle ?? IntPtr.Zero);
                // keep the order
                int at = _apps.Children.IndexOf(b);
                int want = Math.Min(i, _apps.Children.Count - 1);
                if (at != want && at >= 0) { _apps.Children.RemoveAt(at); _apps.Children.Insert(Math.Min(want, _apps.Children.Count), b); }
            }
            if (_preview.Showing && _buttons.TryGetValue(_preview.App, out var shown) && shown.Windows.Count == 0) _preview.HideNow();
        }

        private void OnHover(AppButton b)
        {
            _hovered = b;
            _leaveTimer.Stop();
            if (_preview.Showing) { if (_preview.App != b.App) ShowPreview(b); }
            else _hoverTimer.Start();
        }

        private void ShowPreview(AppButton b)
        {
            if (b.Windows.Count == 0) { _preview.HideNow(); return; }
            var dpi = VisualTreeHelper.GetDpi(this);
            var p = b.PointToScreen(new Point(0, 0));
            var rect = new Rect(p.X / dpi.DpiScaleX, p.Y / dpi.DpiScaleY, b.ActualWidth, b.ActualHeight);
            _preview.ShowFor(b.App, b.Windows.ToList(), L, rect, _barTop);
        }

        private void OnAppClick(AppButton b)
        {
            _hoverTimer.Stop();
            _preview.HideNow();
            var list = b.Windows.Where(w => TB.IsWindow(w.Handle)).ToList();
            if (list.Count == 0) { b.Bounce(); AppWindows.Launch(b.App); return; }
            var fg = TB.GetForegroundWindow();
            int at = list.FindIndex(w => w.Handle == fg);
            if (list.Count == 1)
            {
                if (at == 0 && !TB.IsIconic(fg)) AppWindows.Minimize(fg);
                else AppWindows.Activate(list[0].Handle);
            }
            else
            {
                // several windows: each click brings the next one
                AppWindows.Activate(list[at < 0 ? 0 : (at + 1) % list.Count].Handle);
            }
            QueueRefresh();
        }

        private ContextMenu AppMenu(AppButton b)
        {
            var menu = new ContextMenu();
            bool real = !b.App.Contains('|');
            if (real)
            {
                var name = new MenuItem { Header = AppWindows.NameOf(b.App), IsEnabled = false };
                menu.Items.Add(name);
                var open = new MenuItem { Header = b.Windows.Count > 0 ? "Новое окно" : "Открыть" };
                open.Click += (_, _) => { b.Bounce(); AppWindows.Launch(b.App); };
                menu.Items.Add(open);
                var pin = new MenuItem { Header = b.Pinned ? "Открепить от панели задач" : "Закрепить на панели задач" };
                pin.Click += (_, _) => TogglePin(b.App, !b.Pinned);
                menu.Items.Add(pin);
            }
            if (b.Windows.Count > 0)
            {
                if (menu.Items.Count > 0) menu.Items.Add(new Separator());
                var close = new MenuItem { Header = b.Windows.Count == 1 ? "Закрыть окно" : $"Закрыть все окна ({b.Windows.Count})" };
                close.Click += (_, _) => { foreach (var w in b.Windows) AppWindows.Close(w.Handle); };
                menu.Items.Add(close);
            }
            return menu;
        }

        private static void TogglePin(string app, bool pin)
        {
            var list = Settings.Current.TaskbarPinned.ToList();
            list.RemoveAll(p => string.Equals(p, app, StringComparison.OrdinalIgnoreCase));
            if (pin) list.Add(app);
            Settings.Current.TaskbarPinned = list;
        }

        public void PinnedChanged() => Refresh();

        private ContextMenu BarMenu()
        {
            var menu = new ContextMenu();
            var settings = new MenuItem { Header = "Настройки панели задач…" };
            settings.Click += (_, _) => { Settings.Current.Section = "widgets"; App.Current.OpenSettings(); };
            menu.Items.Add(settings);
            var system = new MenuItem { Header = "Прятать панель Windows", IsCheckable = true, IsChecked = Settings.Current.TaskbarHideSystem };
            system.Click += (_, _) => Settings.Current.TaskbarHideSystem = !Settings.Current.TaskbarHideSystem;
            menu.Items.Add(system);
            var task = new MenuItem { Header = "Диспетчер задач" };
            task.Click += (_, _) => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("taskmgr.exe") { UseShellExecute = true }); } catch { } };
            menu.Items.Add(task);
            menu.Items.Add(new Separator());
            var off = new MenuItem { Header = "Выключить панель Ovira" };
            off.Click += (_, _) => Settings.Current.TaskbarEnabled = false;
            menu.Items.Add(off);
            return menu;
        }
    }

    // ==================================================================== buttons

    // Start, search and the tray items: a soft rounded highlight on hover and
    // the island's press — a dip and a spring back.
    internal sealed class BarIconButton : Grid
    {
        private readonly Border _hover = new() { CornerRadius = new CornerRadius(6), Margin = new Thickness(2, 4, 2, 4), Opacity = 0 };
        private readonly FrameworkElement _content;
        private readonly ScaleTransform _scale = new(1, 1);
        private readonly bool _accent;
        private bool _down;
        public event Action? Clicked;

        public BarIconButton(string icon, bool accent, Look look)
            : this(new IconView { Icon = icon, Width = 22, Height = 22 }, look, accent) { }

        public BarIconButton(FrameworkElement content, Look look, bool accent = false)
        {
            _content = content;
            _accent = accent;
            Width = 44;
            Background = Brushes.Transparent;
            Cursor = Cursors.Hand;
            Children.Add(_hover);
            content.RenderTransformOrigin = new Point(0.5, 0.5);
            content.RenderTransform = _scale;
            Children.Add(content);
            Restyle(look);
            MouseEnter += (_, _) => _hover.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.12)));
            MouseLeave += (_, _) => { _hover.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.2))); if (_down) { _down = false; Spring(1); } };
            MouseLeftButtonDown += (_, e) => { _down = true; Spring(0.84, fast: true); e.Handled = true; };
            MouseLeftButtonUp += (_, e) =>
            {
                if (!_down) return;
                _down = false;
                Spring(1);
                e.Handled = true;
                Clicked?.Invoke();
            };
        }

        public void Restyle(Look look)
        {
            _hover.Background = look.Faint;
            if (_content is IconView v) v.Fill = _accent ? look.Accent : look.Fg;
        }

        private void Spring(double to, bool fast = false)
        {
            var a = fast ? new DoubleAnimation(to, TimeSpan.FromSeconds(0.1))
                         : new DoubleAnimation(to, TimeSpan.FromSeconds(0.42)) { EasingFunction = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut } };
            _scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            _scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
    }

    // One app: its icon, the highlight and the small pill under it — a dot
    // when it runs, a wide accent pill when it is in front. Springs in when
    // it starts, shrinks away when it closes, hops when launched.
    internal sealed class AppButton : Grid
    {
        public const double Size = 44;

        public string App { get; }
        public List<TaskWindow> Windows = new();
        public bool Pinned;

        private readonly Border _hover = new() { CornerRadius = new CornerRadius(6), Margin = new Thickness(2, 4, 2, 4) };
        private readonly Image _icon = new() { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        private readonly Border _pill = new() { Height = 3, CornerRadius = new CornerRadius(1.5), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 3), Width = 0 };
        private readonly ScaleTransform _scale = new(1, 1);
        private readonly TranslateTransform _lift = new(0, 0);
        private Look _look;
        private bool _down, _active, _flash;
        private int _count = -1;

        public event Action<AppButton>? Click, MiddleClick, MenuWanted;

        public ImageSource? IconSource { get => _icon.Source; set => _icon.Source = value; }

        public AppButton(string app, Look look)
        {
            App = app;
            _look = look;
            Width = Size;
            Background = Brushes.Transparent;
            Cursor = Cursors.Hand;
            ToolTip = AppWindows.NameOf(app);
            RenderOptions.SetBitmapScalingMode(_icon, BitmapScalingMode.HighQuality);
            var group = new TransformGroup();
            group.Children.Add(_scale);
            group.Children.Add(_lift);
            _icon.RenderTransformOrigin = new Point(0.5, 0.5);
            _icon.RenderTransform = group;
            _hover.Opacity = 0;
            Children.Add(_hover);
            Children.Add(_icon);
            Children.Add(_pill);
            Restyle(look);

            MouseEnter += (_, _) => Highlight();
            MouseLeave += (_, _) => { Highlight(); if (_down) { _down = false; Spring(1); } };
            MouseLeftButtonDown += (_, e) => { _down = true; Spring(0.82, fast: true); e.Handled = true; };
            MouseLeftButtonUp += (_, e) =>
            {
                if (!_down) return;
                _down = false;
                Spring(1);
                e.Handled = true;
                Click?.Invoke(this);
            };
            MouseUp += (_, e) => { if (e.ChangedButton == MouseButton.Middle) { e.Handled = true; Bounce(); MiddleClick?.Invoke(this); } };
            MouseRightButtonUp += (_, e) => { e.Handled = true; MenuWanted?.Invoke(this); };
        }

        public void Restyle(Look look)
        {
            _look = look;
            _hover.Background = look.Faint;
            ApplyPill(false);
        }

        public void SetState(int count, bool active, bool flash)
        {
            if (count == _count && active == _active && flash == _flash) return;
            _count = count; _active = active; _flash = flash;
            ApplyPill(true);
            Highlight();
        }

        private void ApplyPill(bool animated)
        {
            double width = _count <= 0 ? 0 : _active ? 16 : 6;
            _pill.Background = _flash ? new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)) : _active ? _look.Accent : _look.Fg2;
            if (!animated) { _pill.BeginAnimation(WidthProperty, null); _pill.Width = width; return; }
            _pill.BeginAnimation(WidthProperty, new DoubleAnimation(width, TimeSpan.FromSeconds(0.34)) { EasingFunction = new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut } });
        }

        private void Highlight()
        {
            double to = IsMouseOver ? 1 : _active ? 0.7 : _flash ? 0.9 : 0;
            if (_flash) _hover.Background = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0x9F, 0x0A));
            else _hover.Background = _look.Faint;
            _hover.BeginAnimation(OpacityProperty, new DoubleAnimation(to, TimeSpan.FromSeconds(0.15)));
        }

        private void Spring(double to, bool fast = false)
        {
            var a = fast ? new DoubleAnimation(to, TimeSpan.FromSeconds(0.1))
                         : new DoubleAnimation(to, TimeSpan.FromSeconds(0.42)) { EasingFunction = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut } };
            _scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            _scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }

        // a small hop, like an app starting in the Dock
        public void Bounce()
        {
            var hop = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.6) };
            hop.KeyFrames.Add(new EasingDoubleKeyFrame(-7, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.18)), new QuadraticEase { EasingMode = EasingMode.EaseOut }));
            hop.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.6)), new BounceEase { Bounces = 1, Bounciness = 3, EasingMode = EasingMode.EaseOut }));
            _lift.BeginAnimation(TranslateTransform.YProperty, hop);
        }

        public void Enter(bool animated)
        {
            if (!animated) return;
            Width = 0;
            BeginAnimation(WidthProperty, new DoubleAnimation(0, Size, TimeSpan.FromSeconds(0.32)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            _icon.Opacity = 0;
            _icon.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.25)) { BeginTime = TimeSpan.FromSeconds(0.08) });
            _lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(12, 0, TimeSpan.FromSeconds(0.5)) { EasingFunction = new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut } });
        }

        public void Leave(Action done)
        {
            IsHitTestVisible = false;
            Spring(0.6, fast: false);
            _icon.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.18)));
            var shrink = new DoubleAnimation(ActualWidth, 0, TimeSpan.FromSeconds(0.28)) { BeginTime = TimeSpan.FromSeconds(0.08), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } };
            shrink.Completed += (_, _) => done();
            BeginAnimation(WidthProperty, shrink);
        }
    }
}
