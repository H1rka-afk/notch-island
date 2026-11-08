using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.Island
{
    // The island: a black shape hanging from the top edge of the screen,
    // growing and shrinking on springs (the same feel as on the Mac).
    //   Idle      — a small pill (or nothing), when nothing plays
    //   Compact   — cover · title · live bars
    //   Banner    — volume, charging, sound output… for a couple of seconds
    //   Expanded  — the media player
    public partial class IslandWindow : Window
    {
        private enum Mode { Hidden, Idle, Compact, Banner, Expanded }

        private readonly MediaService _media;
        private readonly AudioService _audio;
        private readonly PowerService _power;
        private Settings S => Settings.Current;

        private Mode _mode = Mode.Hidden;
        private readonly Spring _w = new Spring(120), _h = new Spring(0), _r = new Spring(14), _peek = new Spring(1);
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private double _lastFrame;
        private bool _animating;

        private bool _pointerInside;
        private bool _hiddenForFullscreen;
        private readonly DispatcherTimer _hoverOpen = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.25) };
        private readonly DispatcherTimer _hoverClose = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.45) };
        private readonly DispatcherTimer _bannerTimer = new DispatcherTimer();
        private readonly DispatcherTimer _barsTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        private readonly DispatcherTimer _progressTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.5) };
        private readonly DispatcherTimer _housekeeping = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };

        private readonly Rectangle[] _bars = new Rectangle[4];
        private readonly Rectangle[] _bigBars = new Rectangle[4];
        private readonly double[] _barLevels = new double[4];
        private readonly Random _random = new Random();
        private bool _lastPlaying;
        private bool _glyphReady;

        private const double CanvasWidth = 720;

        public IslandWindow(MediaService media, AudioService audio, PowerService power)
        {
            _media = media;
            _audio = audio;
            _power = power;
            InitializeComponent();

            for (int i = 0; i < 4; i++)
            {
                _bars[i] = new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Margin = new Thickness(1.2, 0, 1.2, 0), VerticalAlignment = VerticalAlignment.Center };
                Bars.Children.Add(_bars[i]);
                _bigBars[i] = new Rectangle { Width = 3.5, Height = 4, RadiusX = 1.75, RadiusY = 1.75, Margin = new Thickness(1.5, 0, 1.5, 0), VerticalAlignment = VerticalAlignment.Center };
                ExpandedBars.Children.Add(_bigBars[i]);
            }

            SourceInitialized += (_, _) =>
            {
                var hwnd = new WindowInteropHelper(this).Handle;
                Native.AddExStyle(hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
            };
            Loaded += (_, _) => { Position(); Relayout(animated: false); };

            Island.MouseEnter += (_, _) => PointerEntered();
            Island.MouseLeave += (_, _) => PointerLeft();
            Island.MouseLeftButtonUp += OnIslandClick;

            _hoverOpen.Tick += (_, _) => { _hoverOpen.Stop(); if (_pointerInside && S.OpenOnHover) Expand(); };
            _hoverClose.Tick += (_, _) => { _hoverClose.Stop(); if (!_pointerInside) Collapse(); };
            _bannerTimer.Tick += (_, _) => { _bannerTimer.Stop(); EndBanner(); };
            _barsTimer.Tick += (_, _) => UpdateBars();
            _progressTimer.Tick += (_, _) => UpdateProgress();
            _housekeeping.Tick += (_, _) => Housekeeping();
            _housekeeping.Start();

            _media.Changed += _ => OnTrack();
            _audio.VolumeChanged += OnVolume;
            _audio.DefaultDeviceChanged += OnOutputChanged;
            _power.Changed += OnPower;
            S.PropertyChanged += OnSettingChanged;
            SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(new Action(Position));
        }

        // ---- placement ----

        private void Position()
        {
            Left = (SystemParameters.PrimaryScreenWidth - Width) / 2;
            Top = 0;
        }

        private void Housekeeping()
        {
            // Stay above other windows (the taskbar and some apps push in front).
            var hwnd = new WindowInteropHelper(this).Handle;
            if (hwnd != IntPtr.Zero)
                Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0,
                                    Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
            // Full-screen games, videos and presentations: step aside.
            var hide = S.HideInFullscreen && Native.FullscreenAppInFront();
            if (hide != _hiddenForFullscreen)
            {
                _hiddenForFullscreen = hide;
                Root.BeginAnimation(OpacityProperty, new DoubleAnimation(hide ? 0 : 1, TimeSpan.FromSeconds(0.25)));
                Root.IsHitTestVisible = !hide;
            }
        }

        // ---- sizes (DIPs), scaled by «Размер островка» ----

        private double Scale => S.IslandScale;
        private double CompactW => 300 * Scale;
        private double CompactH => 34;
        private double BannerW => 330 * Scale;
        private double ExpandedW => 420 * Scale;
        private double ExpandedH => 190;
        private double IdleW => 140 * Scale;
        private double IdleH => 28;

        private bool HasTrack => S.ShowMedia && _media.Track != null;

        private Mode RestingMode => HasTrack ? Mode.Compact : (S.ShowIdlePill ? Mode.Idle : Mode.Hidden);

        // ---- state changes ----

        private void SetMode(Mode mode, bool animated = true)
        {
            var old = _mode;
            _mode = mode;
            Relayout(animated, growing: Area(mode) > Area(old));
            UpdateLayers(old, mode);
            _progressTimer.IsEnabled = mode == Mode.Expanded;
            if (mode == Mode.Expanded) UpdateProgress();
            if (mode != Mode.Expanded) OutputList.Visibility = Visibility.Collapsed;
            UpdateBarsTimer();
        }

        private double Area(Mode m) => m switch
        {
            Mode.Expanded => 3, Mode.Banner => 2, Mode.Compact => 1.5, Mode.Idle => 1, _ => 0
        };

        private void Relayout(bool animated, bool growing = true)
        {
            (double w, double h, double r) = _mode switch
            {
                Mode.Expanded => (ExpandedW, ExpandedH, 28.0),
                Mode.Banner => (BannerW, CompactH, 14.0),
                Mode.Compact => (CompactW, CompactH, 14.0),
                Mode.Idle => (IdleW, IdleH, 12.0),
                _ => (IdleW * 0.8, 0.0, 12.0)
            };
            var resp = growing ? Motion.GrowResponse : Motion.ShrinkResponse;
            var damp = growing ? Motion.GrowDamping : Motion.ShrinkDamping;
            if (!animated)
            {
                _w.Snap(w); _h.Snap(h); _r.Snap(r);
                DrawFrame();
                return;
            }
            _w.To(w, resp, damp);
            _h.To(h, resp, damp);
            _r.To(r, resp, damp);
            StartAnimating();
        }

        private void StartAnimating()
        {
            if (_animating) return;
            _animating = true;
            _lastFrame = _clock.Elapsed.TotalSeconds;
            CompositionTarget.Rendering += OnFrame;
        }

        private void OnFrame(object? sender, EventArgs e)
        {
            var now = _clock.Elapsed.TotalSeconds;
            var dt = Math.Min(0.05, Math.Max(0.001, now - _lastFrame));
            _lastFrame = now;
            bool moving = _w.Step(dt) | _h.Step(dt) | _r.Step(dt) | _peek.Step(dt);
            DrawFrame();
            if (!moving)
            {
                CompositionTarget.Rendering -= OnFrame;
                _animating = false;
            }
        }

        // The silhouette: square to the top edge, with small concave «flares»
        // into the screen edge and round bottom corners — as on the Mac.
        private void DrawFrame()
        {
            double w = Math.Max(0, _w.Value), h = Math.Max(0, _h.Value);
            double cx = CanvasWidth / 2;
            double r = Math.Max(0, Math.Min(_r.Value, Math.Min(h / 2, w / 2)));
            double flare = Math.Max(0, Math.Min(_mode == Mode.Expanded ? 12 : 8, h - r));

            if (h < 0.5)
            {
                Shape.Data = Geometry.Empty;
            }
            else
            {
                var g = new StreamGeometry();
                using (var ctx = g.Open())
                {
                    double l = cx - w / 2, rt = cx + w / 2;
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
                Shape.Data = g;
            }

            Canvas.SetLeft(ContentHost, cx - w / 2);
            ContentHost.Width = w;
            ContentHost.Height = h;
            ContentHost.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);

            PlaceLayer(CompactLayer, CompactW, w);
            PlaceLayer(BannerLayer, BannerW, w);
            ExpandedLayer.Width = ExpandedW - 44;
            ExpandedLayer.Height = ExpandedH - 36;
            Canvas.SetLeft(ExpandedLayer, (w - ExpandedW) / 2);

            PeekScale.ScaleX = _peek.Value;
            PeekScale.ScaleY = _peek.Value;
        }

        private static void PlaceLayer(FrameworkElement layer, double width, double hostWidth)
        {
            layer.Width = width;
            Canvas.SetLeft(layer, (hostWidth - width) / 2);
        }

        private void UpdateLayers(Mode old, Mode mode)
        {
            Fade(CompactLayer, mode == Mode.Compact);
            Fade(BannerLayer, mode == Mode.Banner);
            Fade(ExpandedLayer, mode == Mode.Expanded);
        }

        // Contents arrive a beat after the shape starts growing, and leave at once.
        private static void Fade(UIElement layer, bool show)
        {
            var anim = new DoubleAnimation(show ? 1 : 0, TimeSpan.FromSeconds(show ? 0.22 : 0.12))
            {
                BeginTime = TimeSpan.FromSeconds(show ? 0.1 : 0),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            layer.BeginAnimation(OpacityProperty, anim);
            layer.IsHitTestVisible = show;
            if (layer.RenderTransform is not ScaleTransform)
            {
                layer.RenderTransform = new ScaleTransform(1, 1);
                layer.RenderTransformOrigin = new Point(0.5, 0);
            }
            var scale = (ScaleTransform)layer.RenderTransform;
            var s = new DoubleAnimation(show ? 1 : 0.92, TimeSpan.FromSeconds(show ? 0.3 : 0.12))
            {
                BeginTime = TimeSpan.FromSeconds(show ? 0.06 : 0),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            if (show) scale.ScaleX = scale.ScaleY = 0.92;
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, s);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, s);
        }

        // ---- opening and closing ----

        private void PointerEntered()
        {
            _pointerInside = true;
            _hoverClose.Stop();
            if (_mode == Mode.Compact || _mode == Mode.Idle)
            {
                if (S.HoverPeek) { _peek.To(1.045, Motion.PeekResponse, Motion.PeekDamping); StartAnimating(); }
                if (S.OpenOnHover && _mode == Mode.Compact) _hoverOpen.Start();
            }
        }

        private void PointerLeft()
        {
            _pointerInside = false;
            _hoverOpen.Stop();
            _peek.To(1, Motion.PeekResponse, 0.9);
            StartAnimating();
            if (_mode == Mode.Expanded) _hoverClose.Start();
        }

        private void OnIslandClick(object sender, MouseButtonEventArgs e)
        {
            if (_mode == Mode.Compact) { Expand(); e.Handled = true; }
        }

        private void Expand()
        {
            if (!HasTrack || _mode == Mode.Banner) return;
            _peek.To(1, Motion.PeekResponse, 0.9);
            FillExpanded();
            SetMode(Mode.Expanded);
        }

        private void Collapse()
        {
            if (_mode != Mode.Expanded) return;
            SetMode(RestingMode);
        }

        // ---- media ----

        private void OnTrack()
        {
            var t = _media.Track;
            if (t != null)
            {
                CompactArtImage.Source = t.Artwork;
                ExpandedArt.Source = t.Artwork;
                CompactTitle.Text = S.CompactTitle ? t.Title : "";
                var tint = new SolidColorBrush(t.Tint);
                tint.Freeze();
                foreach (var b in _bars) b.Fill = tint;
                foreach (var b in _bigBars) b.Fill = tint;
                FillExpanded();
                if (!_glyphReady || t.Playing != _lastPlaying) AnimatePlayPause(t.Playing);
                _glyphReady = true;
                _lastPlaying = t.Playing;
            }
            if (_mode == Mode.Banner) return;            // the banner returns to the right place itself
            if (_mode == Mode.Expanded && t == null) { SetMode(RestingMode); return; }
            if (_mode != Mode.Expanded && _mode != RestingMode) SetMode(RestingMode);
            UpdateBarsTimer();
        }

        private void FillExpanded()
        {
            var t = _media.Track;
            if (t == null) return;
            SongTitle.Text = t.Title;
            SongArtist.Text = t.Artist;
            SongSource.Text = t.Source;
            var output = _audio.Current;
            if (output != null) OutputGlyph.Text = output.Glyph;
            OutputButton.Visibility = S.OutputPicker ? Visibility.Visible : Visibility.Hidden;
            UpdateProgress();
        }

        private void AnimatePlayPause(bool playing)
        {
            Swap(PauseGlyph, playing);
            Swap(PlayGlyph, !playing);
        }

        private static void Swap(TextBlock glyph, bool show)
        {
            var dur = TimeSpan.FromSeconds(0.34);
            var ease = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut };
            glyph.BeginAnimation(OpacityProperty, new DoubleAnimation(show ? 1 : 0, TimeSpan.FromSeconds(0.2)));
            if (glyph.RenderTransform is ScaleTransform st)
            {
                var a = new DoubleAnimation(show ? 1 : 0.3, dur) { EasingFunction = ease };
                st.BeginAnimation(ScaleTransform.ScaleXProperty, a);
                st.BeginAnimation(ScaleTransform.ScaleYProperty, a);
            }
        }

        private void UpdateProgress()
        {
            var t = _media.Track;
            if (t == null) return;
            var pos = t.LivePosition;
            TimeElapsed.Text = Format(pos);
            TimeTotal.Text = t.Duration > TimeSpan.Zero ? "-" + Format(t.Duration - pos) : "";
            var fraction = t.Duration > TimeSpan.Zero ? Math.Clamp(pos.TotalSeconds / t.Duration.TotalSeconds, 0, 1) : 0;
            ProgressFill.Width = Math.Max(0, ProgressTrack.ActualWidth * fraction);
        }

        private static string Format(TimeSpan t) =>
            t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");

        private void OnSeek(object sender, MouseButtonEventArgs e)
        {
            var t = _media.Track;
            if (t == null || t.Duration <= TimeSpan.Zero || ProgressTrack.ActualWidth <= 0) return;
            var f = Math.Clamp(e.GetPosition(ProgressTrack).X / ProgressTrack.ActualWidth, 0, 1);
            _media.Seek(TimeSpan.FromSeconds(t.Duration.TotalSeconds * f));
            t.Position = TimeSpan.FromSeconds(t.Duration.TotalSeconds * f);
            t.PositionUpdated = DateTimeOffset.Now;
            UpdateProgress();
            e.Handled = true;
        }

        private void OnPlayPause(object sender, RoutedEventArgs e)
        {
            _media.PlayPause();
            if (_media.Track != null)
            {
                _media.Track.Playing = !_media.Track.Playing;
                _lastPlaying = _media.Track.Playing;
                AnimatePlayPause(_media.Track.Playing);
            }
        }
        private void OnNext(object sender, RoutedEventArgs e) => _media.Next();
        private void OnPrevious(object sender, RoutedEventArgs e) => _media.Previous();

        // ---- live bars ----

        private void UpdateBarsTimer()
        {
            var visible = (_mode == Mode.Compact || _mode == Mode.Expanded) && !_hiddenForFullscreen;
            _barsTimer.IsEnabled = visible;
            if (!visible) return;
        }

        private void UpdateBars()
        {
            var playing = _media.Track?.Playing == true;
            var peak = S.LiveBars ? Math.Min(1.0, _audio.Peak * 1.6) : 0.55;
            var time = _clock.Elapsed.TotalSeconds;
            for (int i = 0; i < 4; i++)
            {
                double target;
                if (!playing) target = 0.15;
                else
                {
                    var wobble = 0.55 + 0.45 * Math.Sin(time * (6.5 + i * 1.7) + i * 1.3);
                    var jitter = 0.75 + _random.NextDouble() * 0.5;
                    target = Math.Clamp((S.LiveBars ? peak : 0.55) * wobble * jitter + 0.12, 0.12, 1);
                }
                _barLevels[i] += (target - _barLevels[i]) * 0.35;
                _bars[i].Height = 3 + 13 * _barLevels[i];
                _bigBars[i].Height = 4 + 16 * _barLevels[i];
            }
        }

        // ---- sound outputs ----

        private void OnOutputs(object sender, RoutedEventArgs e)
        {
            OutputItems.Children.Clear();
            foreach (var d in _audio.Outputs())
            {
                var row = new Grid { Height = 34 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
                var icon = new TextBlock { Text = d.Glyph, FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 15, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
                var name = new TextBlock { Text = d.Name, FontSize = 13, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
                var check = new TextBlock { Text = d.IsDefault ? "" : "", FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 13, Foreground = new SolidColorBrush(Color.FromRgb(0x4C, 0x8D, 0xFF)), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(name, 1);
                Grid.SetColumn(check, 2);
                row.Children.Add(icon); row.Children.Add(name); row.Children.Add(check);
                var button = new Button
                {
                    Content = row,
                    Template = RowTemplate(),
                    Cursor = Cursors.Hand,
                    Focusable = false,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch
                };
                var id = d.Id;
                button.Click += (_, _) =>
                {
                    _audio.SetDefault(id);
                    OutputList.Visibility = Visibility.Collapsed;
                };
                OutputItems.Children.Add(button);
            }
            OutputList.Visibility = Visibility.Visible;
            OutputList.Opacity = 0;
            OutputList.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.18)));
        }

        private static ControlTemplate RowTemplate()
        {
            var t = new ControlTemplate(typeof(Button));
            var border = new FrameworkElementFactory(typeof(Border));
            border.Name = "Bg";
            border.SetValue(Border.CornerRadiusProperty, new CornerRadius(8));
            border.SetValue(Border.PaddingProperty, new Thickness(8, 0, 8, 0));
            border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
            var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
            border.AppendChild(presenter);
            t.VisualTree = border;
            var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)), "Bg"));
            t.Triggers.Add(hover);
            return t;
        }

        private void OnOutputsClose(object sender, RoutedEventArgs e) => OutputList.Visibility = Visibility.Collapsed;

        // ---- banners ----

        private void ShowBanner(string glyph, string text, Color colour, double? level, double seconds)
        {
            BannerIcon.Text = glyph;
            BannerIcon.Foreground = new SolidColorBrush(colour);
            BannerText.Text = text;
            BannerLevel.Visibility = level.HasValue ? Visibility.Visible : Visibility.Collapsed;
            if (level.HasValue)
            {
                BannerLevelFill.Background = new SolidColorBrush(colour);
                BannerLevelFill.BeginAnimation(WidthProperty,
                    new DoubleAnimation(90 * Math.Clamp(level.Value, 0, 1), TimeSpan.FromSeconds(0.15)));
            }
            _bannerTimer.Stop();
            _bannerTimer.Interval = TimeSpan.FromSeconds(seconds);
            _bannerTimer.Start();
            if (_mode != Mode.Banner) SetMode(Mode.Banner);
        }

        private void EndBanner()
        {
            if (_mode != Mode.Banner) return;
            SetMode(_pointerInside && HasTrack && S.OpenOnHover ? Mode.Expanded : RestingMode);
        }

        private void OnVolume(float level, bool muted)
        {
            if (!S.VolumeBanner || _mode == Mode.Expanded) return;
            var percent = (int)Math.Round(level * 100);
            ShowBanner(muted ? "" : "", muted ? "Без звука" : $"Громкость {percent} %",
                       Colors.White, muted ? 0 : level, 1.6);
        }

        private void OnOutputChanged(OutputDevice device)
        {
            OutputGlyph.Text = device.Glyph;
            if (!S.OutputBanner) return;
            ShowBanner(device.Glyph, device.Name, Color.FromRgb(0x4C, 0x8D, 0xFF), null, 2.4);
        }

        private void OnPower(PowerEvent e, int percent)
        {
            switch (e)
            {
                case PowerEvent.Plugged when S.ChargingBanner:
                    ShowBanner("", $"Зарядка · {percent} %", Color.FromRgb(0x34, 0xC7, 0x59), percent / 100.0, 2.6);
                    break;
                case PowerEvent.Unplugged when S.ChargingBanner:
                    ShowBanner("", $"От батареи · {percent} %", Colors.White, percent / 100.0, 2.2);
                    break;
                case PowerEvent.Low when S.LowBatteryBanner:
                    ShowBanner("", $"Низкий заряд · {percent} %", Color.FromRgb(0xFF, 0x9F, 0x0A), percent / 100.0, 4);
                    break;
                case PowerEvent.Critical when S.LowBatteryBanner:
                    ShowBanner("", $"Почти разряжен · {percent} %", Color.FromRgb(0xFF, 0x45, 0x3A), percent / 100.0, 5);
                    break;
            }
        }

        // ---- demonstrations for the settings window ----

        public void DemoVolume() => ShowBanner("", "Громкость 60 %", Colors.White, 0.6, 2);
        public void DemoCharging() => ShowBanner("", "Зарядка · 76 %", Color.FromRgb(0x34, 0xC7, 0x59), 0.76, 2.6);
        public void DemoLowBattery() => ShowBanner("", "Низкий заряд · 20 %", Color.FromRgb(0xFF, 0x9F, 0x0A), 0.2, 3);
        public void DemoOutput() => ShowBanner("", "Наушники", Color.FromRgb(0x4C, 0x8D, 0xFF), null, 2.4);
        public void DemoOpen()
        {
            if (HasTrack) { Expand(); _hoverClose.Stop(); if (!_pointerInside) _hoverClose.Start(); }
            else ShowBanner("", "Включи музыку — и плеер появится здесь", Colors.White, null, 3);
        }

        // ---- settings ----

        private void OnSettingChanged(object? sender, PropertyChangedEventArgs e)
        {
            switch (e.PropertyName)
            {
                case nameof(Settings.IslandScale):
                    Relayout(animated: true);
                    break;
                case nameof(Settings.ShowMedia):
                case nameof(Settings.ShowIdlePill):
                    if (_mode != Mode.Banner && _mode != Mode.Expanded) SetMode(RestingMode);
                    else if (_mode == Mode.Expanded && !HasTrack) SetMode(RestingMode);
                    break;
                case nameof(Settings.CompactTitle):
                    CompactTitle.Text = S.CompactTitle ? _media.Track?.Title ?? "" : "";
                    break;
                case nameof(Settings.OutputPicker):
                    OutputButton.Visibility = S.OutputPicker ? Visibility.Visible : Visibility.Hidden;
                    break;
            }
        }

        public void Begin()
        {
            SetMode(RestingMode, animated: true);
        }
    }
}
