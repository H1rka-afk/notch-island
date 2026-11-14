using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Ovira.Core;

namespace Ovira.Widgets
{
    // 0.6.1 — «Добавить виджеты»: the desktop for arranging widgets, as on
    // the iPhone. Your own wallpaper over the whole screen (the taskbar is
    // covered), the grid of cells, the widgets you have — they wobble and can
    // be dragged, resized and removed — and on the right the gallery to take
    // new ones from (click a size or drag one onto the desktop). «Готово»
    // keeps it all, «Отмена» or Esc leaves everything as it was.
    public sealed class WidgetEditor : Window
    {
        private sealed class Item
        {
            public WidgetState State = null!;
            public Grid Host = null!;
            public FrameworkElement Card = null!;
            public Action? Update;
            public RotateTransform Turn = null!;
            public Size Size => WidgetCatalog.Dimensions(State.Size);
        }

        private readonly List<WidgetState> _work;
        private readonly List<Item> _items = new();
        private readonly Canvas _board = new Canvas { ClipToBounds = true };
        private readonly Canvas _cells = new Canvas { IsHitTestVisible = false };
        private readonly Grid _root = new Grid();
        private readonly Border _panel;
        private readonly StackPanel _drawer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        private readonly TranslateTransform _drawerShift = new TranslateTransform();
        private readonly RotateTransform _arrowTurn = new RotateTransform(0);
        private bool _galleryOpen;
        private static bool Snap => Settings.Current.WidgetsSnap;
        private readonly StackPanel _sizeBar = new StackPanel { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
        private readonly DispatcherTimer _tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private readonly Random _random = new Random();
        private readonly List<Action?> _galleryUpdates = new();
        private Look _look;
        private Item? _selected, _dragged;
        private Point _grab;
        private bool _done;

        // A widget being taken from the gallery.
        private FrameworkElement? _ghost;
        private string _ghostKind = "", _ghostSize = "s";
        private Point _pressAt;
        private bool _pressInGallery;

        public static void Open()
        {
            foreach (Window w in Application.Current.Windows)
                if (w is WidgetEditor e) { e.Activate(); return; }
            new WidgetEditor().Show();
        }

        private WidgetEditor()
        {
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            Topmost = true;
            ShowInTaskbar = false;
            Left = 0; Top = 0;
            Width = SystemParameters.PrimaryScreenWidth;
            Height = SystemParameters.PrimaryScreenHeight;
            // 0.6.3: exactly the screen, whatever its size and scale.
            SourceInitialized += (_, _) => WindowState = WindowState.Maximized;
            Background = Brushes.Black;
            Title = "Ovira — виджеты";
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            UseLayoutRounding = true;

            _look = Look.Current();
            _work = Settings.Current.Widgets.Select(w => w.Copy()).ToList();
            WidgetManager.HideAll();
            Ovira.Taskbar.TaskbarManager.Suspend(true);
            Closed += (_, _) => Ovira.Taskbar.TaskbarManager.Suspend(false);

            // Wallpaper, a slight dim, the cells, the widgets.
            _root.Children.Add(Wallpaper());
            _root.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(0x38, 0, 0, 0)), IsHitTestVisible = false });
            _root.Children.Add(_cells);
            _root.Children.Add(_board);
            _board.Background = Brushes.Transparent;
            _board.Children.Add(_sizeBar);
            Panel.SetZIndex(_sizeBar, 1000);

            // 0.6.2: the gallery hides at the right edge; the arrow on its left opens it.
            _panel = Gallery();
            _drawer.Children.Add(ArrowTab());
            _drawer.Children.Add(_panel);
            _drawer.RenderTransform = _drawerShift;
            _root.Children.Add(_drawer);
            _root.Children.Add(TopBar());
            Content = _root;

            Loaded += (_, _) =>
            {
                DrawCells();
                foreach (var state in _work.Where(s => !double.IsNaN(s.X) && WidgetGrid.InArea(new Point(s.X, s.Y), WidgetCatalog.Dimensions(s.Size))))
                    AddItem(state, appear: false);
                _root.Opacity = 0;
                _root.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.25)));
                _drawerShift.X = _panel.Width + 16;
                _cells.Opacity = Snap ? 1 : 0;
                Activate();
                Focus();
            };
            _tick.Tick += (_, _) =>
            {
                foreach (var i in _items) { try { i.Update?.Invoke(); } catch { } }
                if (_galleryOpen) foreach (var u in _galleryUpdates) { try { u?.Invoke(); } catch { } }
            };
            _tick.Start();
            KeyDown += (_, e) =>
            {
                if (e.Key == Key.Escape) Finish(keep: false);
                else if (e.Key == Key.Enter) Finish(keep: true);
                else if (e.Key == Key.Delete && _selected != null) RemoveItem(_selected);
            };
            Closed += (_, _) => { _tick.Stop(); if (!_done) WidgetManager.ShowAll(); };

            _board.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource == _board) Select(null); };
            MouseMove += OnMove;
            MouseLeftButtonUp += OnUp;
        }

        // ---- the wallpaper ----

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool SystemParametersInfo(uint action, uint param, StringBuilder value, uint winIni);

        private FrameworkElement Wallpaper()
        {
            var image = new Image { Stretch = Stretch.UniformToFill, IsHitTestVisible = false };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
            var candidates = new List<string>();
            try
            {
                var path = new StringBuilder(520);
                if (SystemParametersInfo(0x0073 /* SPI_GETDESKWALLPAPER */, 520, path, 0) && path.Length > 0) candidates.Add(path.ToString());
            }
            catch { }
            candidates.Add(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Microsoft\Windows\Themes\TranscodedWallpaper"));
            foreach (var file in candidates)
            {
                try
                {
                    if (!File.Exists(file)) continue;
                    using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                    var bitmap = new BitmapImage();
                    bitmap.BeginInit();
                    bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.StreamSource = stream;
                    bitmap.DecodePixelWidth = (int)Math.Min(3840, SystemParameters.PrimaryScreenWidth * 2);
                    bitmap.EndInit();
                    bitmap.Freeze();
                    image.Source = bitmap;
                    return image;
                }
                catch { }
            }
            // No picture (a solid colour or a slideshow without a file): a calm gradient.
            return new Border { Background = new LinearGradientBrush(Color.FromRgb(0x1C, 0x2A, 0x4A), Color.FromRgb(0x0B, 0x0F, 0x1A), 60), IsHitTestVisible = false };
        }

        // ---- the grid ----

        private void DrawCells()
        {
            _cells.Children.Clear();
            double unit = WidgetCatalog.Unit;
            foreach (var cell in WidgetGrid.Cells())
            {
                var r = new Rectangle
                {
                    Width = unit, Height = unit, RadiusX = 24, RadiusY = 24,
                    Fill = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
                    Stroke = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)), StrokeThickness = 1,
                    StrokeDashArray = new DoubleCollection { 4, 4 }
                };
                Canvas.SetLeft(r, cell.X); Canvas.SetTop(r, cell.Y);
                _cells.Children.Add(r);
            }
        }

        // 0.6.3: the grid fades in and out with the switch.
        private void FadeCells(bool show) =>
            _cells.BeginAnimation(OpacityProperty, new DoubleAnimation(show ? 1 : 0, TimeSpan.FromSeconds(0.35)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } });

        // ---- the widgets on the board ----

        private void AddItem(WidgetState state, bool appear)
        {
            var item = new Item { State = state };
            item.Host = new Grid { Cursor = Cursors.SizeAll };
            item.Turn = new RotateTransform(0);
            var scale = new ScaleTransform(1, 1);
            var group = new TransformGroup();
            group.Children.Add(scale);
            group.Children.Add(item.Turn);
            item.Host.RenderTransform = group;
            item.Host.RenderTransformOrigin = new Point(0.5, 0.5);
            Fill(item);
            Place(item, state.X, state.Y, animate: false);
            _board.Children.Add(item.Host);
            _items.Add(item);

            // The iPhone's edit-mode wobble: every widget a little out of step.
            var wobble = new DoubleAnimation(-1.1, 1.1, TimeSpan.FromSeconds(0.13 + _random.NextDouble() * 0.04))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(_random.NextDouble() * 0.2)
            };
            item.Turn.BeginAnimation(RotateTransform.AngleProperty, wobble);

            item.Host.MouseLeftButtonDown += (_, e) =>
            {
                if (e.OriginalSource is DependencyObject d && IsDelete(d)) return;
                Select(item);
                _dragged = item;
                _grab = e.GetPosition(item.Host);
                Panel.SetZIndex(item.Host, 500);
                item.Host.CaptureMouse();
                Lift(item, true);
                e.Handled = true;
            };
            if (appear)
            {
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.6, 1, TimeSpan.FromSeconds(0.4)) { EasingFunction = new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut } });
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.6, 1, TimeSpan.FromSeconds(0.4)) { EasingFunction = new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut } });
                item.Host.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.25)));
            }
        }

        private static bool IsDelete(DependencyObject d)
        {
            while (d != null)
            {
                if (d is FrameworkElement f && Equals(f.Tag, "delete")) return true;
                d = VisualTreeHelper.GetParent(d);
            }
            return false;
        }

        // The card (not clickable here) and the round «−» badge in its corner.
        private void Fill(Item item)
        {
            item.Host.Children.Clear();
            var size = item.Size;
            item.Host.Width = size.Width;
            item.Host.Height = size.Height;
            var (card, update) = WidgetCard.Make(item.State, _look, null);
            card.IsHitTestVisible = false;
            item.Card = card;
            item.Update = update;
            update?.Invoke();
            item.Host.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(24), Child = card,
                Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Direction = 270, Opacity = 0.35 }
            });
            item.Host.Children.Add(new Border { Background = Brushes.Transparent });   // the grip

            var delete = new Grid
            {
                Width = 26, Height = 26, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(-9, -9, 0, 0), Cursor = Cursors.Hand, Tag = "delete"
            };
            delete.Children.Add(new Ellipse { Fill = new SolidColorBrush(Color.FromRgb(0xE5, 0xE5, 0xEA)), Effect = new DropShadowEffect { BlurRadius = 6, ShadowDepth = 1, Opacity = 0.3 } });
            delete.Children.Add(new Rectangle { Width = 11, Height = 2.4, RadiusX = 1.2, RadiusY = 1.2, Fill = new SolidColorBrush(Color.FromRgb(0x1C, 0x1C, 0x1E)) });
            delete.MouseLeftButtonUp += (_, e) => { RemoveItem(item); e.Handled = true; };
            item.Host.Children.Add(delete);
        }

        private void Place(Item item, double x, double y, bool animate)
        {
            if (!animate)
            {
                item.Host.BeginAnimation(Canvas.LeftProperty, null);
                item.Host.BeginAnimation(Canvas.TopProperty, null);
                Canvas.SetLeft(item.Host, x);
                Canvas.SetTop(item.Host, y);
            }
            else
            {
                var ease = new BackEase { Amplitude = 0.2, EasingMode = EasingMode.EaseOut };
                item.Host.BeginAnimation(Canvas.LeftProperty, new DoubleAnimation(x, TimeSpan.FromSeconds(0.3)) { EasingFunction = ease });
                item.Host.BeginAnimation(Canvas.TopProperty, new DoubleAnimation(y, TimeSpan.FromSeconds(0.3)) { EasingFunction = ease });
            }
            item.State.X = x;
            item.State.Y = y;
            if (_selected == item) ShowSizeBar(item);
        }

        private void Lift(Item item, bool up)
        {
            if (item.Host.RenderTransform is TransformGroup g && g.Children[0] is ScaleTransform s)
            {
                var a = new DoubleAnimation(up ? 1.05 : 1, TimeSpan.FromSeconds(0.18)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                s.BeginAnimation(ScaleTransform.ScaleXProperty, a);
                s.BeginAnimation(ScaleTransform.ScaleYProperty, a);
            }
        }

        private IList<Rect> OthersThan(Item? item) =>
            _items.Where(i => i != item).Select(i => new Rect(i.State.X, i.State.Y, i.Size.Width, i.Size.Height)).ToList();

        private void RemoveItem(Item item)
        {
            _items.Remove(item);
            _work.Remove(item.State);
            if (_selected == item) Select(null);
            var shrink = new DoubleAnimation(0, TimeSpan.FromSeconds(0.2)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn } };
            shrink.Completed += (_, _) => _board.Children.Remove(item.Host);
            item.Host.BeginAnimation(OpacityProperty, shrink);
        }

        // ---- selection and sizes ----

        private void Select(Item? item)
        {
            _selected = item;
            if (item == null) { _sizeBar.Visibility = Visibility.Collapsed; return; }
            ShowSizeBar(item);
        }

        private void ShowSizeBar(Item item)
        {
            _sizeBar.Children.Clear();
            var kind = WidgetCatalog.Find(item.State.Kind);
            foreach (var size in new[] { "s", "m", "l" }.Where(s => kind.Sizes.Contains(s)))
                _sizeBar.Children.Add(Chip(WidgetCatalog.SizeName(size), item.State.Size == size, () => Resize(item, size)));
            if (item.State.Kind == "clock")
                _sizeBar.Children.Add(Chip("Стрелочные", item.State.Variant == "analog", () =>
                {
                    item.State.Variant = item.State.Variant == "analog" ? "" : "analog";
                    Fill(item);
                    ShowSizeBar(item);
                }));
            _sizeBar.Children.Add(Chip("Убрать", false, () => RemoveItem(item), danger: true));
            _sizeBar.Visibility = Visibility.Visible;
            _sizeBar.UpdateLayout();
            _sizeBar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double w = _sizeBar.DesiredSize.Width;
            double x = item.State.X + item.Size.Width / 2 - w / 2;
            double y = item.State.Y + item.Size.Height + 10;
            if (y + 40 > ActualHeight) y = item.State.Y - 46;
            Canvas.SetLeft(_sizeBar, Math.Max(8, x));
            Canvas.SetTop(_sizeBar, y);
        }

        private static FrameworkElement Chip(string text, bool on, Action click, bool danger = false)
        {
            var label = new TextBlock
            {
                Text = text, FontSize = 12.5, FontWeight = FontWeights.SemiBold,
                Foreground = on ? Brushes.Black : danger ? new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x60)) : Brushes.White
            };
            var chip = new Border
            {
                CornerRadius = new CornerRadius(15), Padding = new Thickness(13, 6, 13, 7), Margin = new Thickness(0, 0, 6, 0), Child = label, Cursor = Cursors.Hand,
                Background = on ? Brushes.White : new SolidColorBrush(Color.FromArgb(0xD9, 0x2C, 0x2C, 0x2E)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(on ? 0 : 1),
                Effect = new DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Opacity = 0.35 }
            };
            chip.MouseLeftButtonDown += (_, e) => e.Handled = true;
            chip.MouseLeftButtonUp += (_, e) => { click(); e.Handled = true; };
            return chip;
        }

        private void Resize(Item item, string size)
        {
            if (item.State.Size == size) return;
            item.State.Size = size;
            Fill(item);
            var p = WidgetGrid.Settle(new Point(item.State.X, item.State.Y), item.Size, OthersThan(item));
            Place(item, p.X, p.Y, animate: true);
            ShowSizeBar(item);
        }

        // ---- dragging (widgets on the board and new ones from the gallery) ----

        private void OnMove(object sender, MouseEventArgs e)
        {
            if (_dragged != null && e.LeftButton == MouseButtonState.Pressed)
            {
                var m = e.GetPosition(_board);
                var raw = new Point(m.X - _grab.X, m.Y - _grab.Y);
                var p = Snap ? WidgetGrid.Magnetic(raw, _dragged.Size, OthersThan(_dragged)) : raw;
                Canvas.SetLeft(_dragged.Host, p.X);
                Canvas.SetTop(_dragged.Host, p.Y);
                _dragged.State.X = p.X; _dragged.State.Y = p.Y;
                _sizeBar.Visibility = Visibility.Collapsed;
                return;
            }
            if (_pressInGallery && e.LeftButton == MouseButtonState.Pressed)
            {
                var m = e.GetPosition(_root);
                if (_ghost == null && (m - _pressAt).Length > 6) StartGhost();
                if (_ghost != null)
                {
                    var size = WidgetCatalog.Dimensions(_ghostSize);
                    Canvas.SetLeft(_ghost, m.X - size.Width / 2);
                    Canvas.SetTop(_ghost, m.Y - size.Height / 2);
                }
            }
        }

        private void OnUp(object sender, MouseButtonEventArgs e)
        {
            if (_dragged != null)
            {
                var item = _dragged;
                _dragged = null;
                item.Host.ReleaseMouseCapture();
                Lift(item, false);
                Panel.SetZIndex(item.Host, 0);
                var p = Snap ? WidgetGrid.Settle(new Point(item.State.X, item.State.Y), item.Size, OthersThan(item)) : new Point(item.State.X, item.State.Y);
                Place(item, p.X, p.Y, animate: Snap);
                Select(item);
                return;
            }
            if (_pressInGallery)
            {
                _pressInGallery = false;
                Mouse.Capture(null);
                if (_ghost != null)
                {
                    var size = WidgetCatalog.Dimensions(_ghostSize);
                    var drop = new Point(Canvas.GetLeft(_ghost), Canvas.GetTop(_ghost));
                    _board.Children.Remove(_ghost);
                    _ghost = null;
                    // Dropped back onto the open gallery — nothing.
                    var m = e.GetPosition(_root);
                    if (!_galleryOpen || m.X < ActualWidth - _panel.ActualWidth - 60)
                        AddNew(_ghostKind, _ghostSize, Snap ? WidgetGrid.Settle(drop, size, OthersThan(null)) : drop);
                }
                // 0.6.2: a plain click adds nothing — widgets are taken by dragging.
            }
        }

        private void StartGhost()
        {
            var state = new WidgetState { Kind = _ghostKind, Size = _ghostSize };
            var (card, update) = WidgetCard.Make(state, _look, null);
            update?.Invoke();
            var size = WidgetCatalog.Dimensions(_ghostSize);
            _ghost = new Border
            {
                Width = size.Width, Height = size.Height, Child = card, Opacity = 0.9, IsHitTestVisible = false,
                Effect = new DropShadowEffect { BlurRadius = 26, ShadowDepth = 8, Direction = 270, Opacity = 0.45 }
            };
            _board.Children.Add(_ghost);
            Panel.SetZIndex(_ghost, 900);
            // The gallery steps aside so the whole desktop is free to drop on.
            ShowGallery(false);
        }

        private void ShowGallery(bool open)
        {
            if (_galleryOpen == open) return;
            _galleryOpen = open;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            _drawerShift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(open ? 0 : _panel.Width + 16, TimeSpan.FromSeconds(0.35)) { EasingFunction = ease });
            _arrowTurn.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(open ? 180 : 0, TimeSpan.FromSeconds(0.3)) { EasingFunction = ease });
        }

        // The arrow at the right edge; on the gallery's left side when it is open.
        private FrameworkElement ArrowTab()
        {
            var icon = new IconView
            {
                Icon = "chevron.left", Width = 18, Height = 18, Fill = Brushes.White,
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = _arrowTurn
            };
            var tab = new Border
            {
                Width = 36, Height = 96, VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand, Margin = new Thickness(0, 0, 8, 0),
                CornerRadius = new CornerRadius(18), Child = icon,
                Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x1C, 0x1C, 0x1E)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(1),
                ToolTip = "Виджеты",
                Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Opacity = 0.4 }
            };
            tab.MouseEnter += (_, _) => tab.Background = new SolidColorBrush(Color.FromArgb(0xF2, 0x3A, 0x3A, 0x3C));
            tab.MouseLeave += (_, _) => tab.Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x1C, 0x1C, 0x1E));
            tab.MouseLeftButtonUp += (_, e) => { ShowGallery(!_galleryOpen); e.Handled = true; };
            return tab;
        }

        // «Сетка и прилипание» — a small switch at the top of the gallery.
        private FrameworkElement SnapSwitch()
        {
            var knob = new Ellipse { Width = 22, Height = 22, Fill = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(2) };
            var knobShift = new TranslateTransform(Snap ? 18 : 0, 0);
            knob.RenderTransform = knobShift;
            var track = new Border { Width = 46, Height = 26, CornerRadius = new CornerRadius(13), Child = knob, Cursor = Cursors.Hand,
                                     Background = new SolidColorBrush(Snap ? Color.FromRgb(0x34, 0xC7, 0x59) : Color.FromArgb(0x52, 0xFF, 0xFF, 0xFF)) };
            track.MouseLeftButtonUp += (_, e) =>
            {
                Settings.Current.WidgetsSnap = !Snap;
                knobShift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(Snap ? 18 : 0, TimeSpan.FromSeconds(0.2)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
                track.Background = new SolidColorBrush(Snap ? Color.FromRgb(0x34, 0xC7, 0x59) : Color.FromArgb(0x52, 0xFF, 0xFF, 0xFF));
                FadeCells(Snap);
                e.Handled = true;
            };
            var row = new Grid { Margin = new Thickness(0, 12, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = "Сетка и прилипание", FontSize = 13.5, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White });
            text.Children.Add(new TextBlock { Text = "Виджеты встают в ячейки и прилипают к краям", FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(0xA6, 0xFF, 0xFF, 0xFF)) });
            row.Children.Add(text);
            Grid.SetColumn(track, 1);
            track.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(track);
            return row;
        }

        private void AddNew(string kind, string size, Point at)
        {
            var state = new WidgetState { Kind = kind, Size = size, X = at.X, Y = at.Y };
            _work.Add(state);
            AddItem(state, appear: true);
            Select(_items[^1]);
        }

        // ---- the gallery on the right ----

        private Border Gallery()
        {
            var list = new StackPanel { Margin = new Thickness(14, 0, 14, 16) };
            foreach (var kind in WidgetCatalog.All) list.Children.Add(GalleryRow(kind));
            var scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };

            var head = new StackPanel { Margin = new Thickness(20, 20, 20, 12) };
            head.Children.Add(new TextBlock { Text = "Виджеты", FontSize = 24, FontWeight = FontWeights.Bold, Foreground = Brushes.White, FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI") });
            head.Children.Add(new TextBlock
            {
                Text = "Зажми виджет и перетащи его на рабочий стол. Нажми на виджет на столе, чтобы сменить размер или убрать.",
                FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0)
            });
            head.Children.Add(SnapSwitch());

            var dock = new DockPanel();
            DockPanel.SetDock(head, Dock.Top);
            dock.Children.Add(head);
            dock.Children.Add(scroll);
            return new Border
            {
                Width = 360, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 16, 16),
                CornerRadius = new CornerRadius(28), Child = dock, ClipToBounds = true,
                Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x1C, 0x1C, 0x1E)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(1),
                Effect = new DropShadowEffect { BlurRadius = 30, ShadowDepth = 6, Direction = 180, Opacity = 0.4 }
            };
        }

        // 0.6.3: each widget as it will look (its first size, scaled to fit
        // the gallery); press it and drag it onto the desktop.
        private FrameworkElement GalleryRow(WidgetKind kind)
        {
            var size = kind.Sizes[0];
            var dims = WidgetCatalog.Dimensions(size);
            var state = new WidgetState { Kind = kind.Id, Size = size };
            var (card, update) = WidgetCard.Make(state, _look, null);
            try { update?.Invoke(); } catch { }
            card.IsHitTestVisible = false;
            double scale = Math.Min(1, 300 / dims.Width);
            var preview = new Border
            {
                Width = dims.Width, Height = dims.Height, Child = card,
                LayoutTransform = new ScaleTransform(scale, scale),
                Effect = new DropShadowEffect { BlurRadius = 14, ShadowDepth = 3, Direction = 270, Opacity = 0.35 }
            };
            var holder = new Grid { Cursor = Cursors.SizeAll, Background = Brushes.Transparent, HorizontalAlignment = HorizontalAlignment.Center };
            holder.Children.Add(preview);
            holder.ToolTip = "Зажми и перетащи на рабочий стол";
            holder.MouseEnter += (_, _) => holder.Opacity = 0.85;
            holder.MouseLeave += (_, _) => holder.Opacity = 1;
            holder.MouseLeftButtonDown += (_, e) =>
            {
                _pressInGallery = true;
                _pressAt = e.GetPosition(_root);
                _ghostKind = kind.Id;
                _ghostSize = size;
                Mouse.Capture(this);
                e.Handled = true;
            };
            _galleryUpdates.Add(update);

            var stack = new StackPanel { Margin = new Thickness(0, 6, 0, 14) };
            stack.Children.Add(holder);
            stack.Children.Add(new TextBlock { Text = kind.Title, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) });
            stack.Children.Add(new TextBlock { Text = kind.About, FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(0xA6, 0xFF, 0xFF, 0xFF)), HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap });
            return stack;
        }

        // ---- «Отмена» / «Готово» ----

        private FrameworkElement TopBar()
        {
            var bar = new StackPanel
            {
                Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(24, 18, 0, 0)
            };
            bar.Children.Add(Capsule("Отмена", false, () => Finish(keep: false)));
            bar.Children.Add(Capsule("Готово", true, () => Finish(keep: true)));
            return bar;
        }

        private static FrameworkElement Capsule(string text, bool primary, Action click)
        {
            var label = new TextBlock { Text = text, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = primary ? Brushes.Black : Brushes.White };
            var b = new Border
            {
                CornerRadius = new CornerRadius(18), Padding = new Thickness(20, 8, 20, 9), Margin = new Thickness(0, 0, 10, 0), Child = label, Cursor = Cursors.Hand,
                Background = primary ? Brushes.White : new SolidColorBrush(Color.FromArgb(0xB3, 0x2C, 0x2C, 0x2E)),
                Effect = new DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.35 }
            };
            b.MouseLeftButtonUp += (_, e) => { click(); e.Handled = true; };
            return b;
        }

        private void Finish(bool keep)
        {
            if (_done) return;
            _done = true;
            if (keep) WidgetManager.Apply(_work);
            else WidgetManager.ShowAll();
            var fade = new DoubleAnimation(0, TimeSpan.FromSeconds(0.2));
            fade.Completed += (_, _) => Close();
            _root.BeginAnimation(OpacityProperty, fade);
        }
    }
}
