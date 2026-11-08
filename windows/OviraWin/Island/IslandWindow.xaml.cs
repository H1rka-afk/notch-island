using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.Island
{
    // The island: a black shape hanging from the top edge of the screen,
    // growing and shrinking on springs — the Mac island, on Windows.
    //   Idle      — a small pill (or nothing), when nothing plays
    //   Compact   — cover · (camera space) · six live bars
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
        private readonly Spring _w = new Spring(120), _h = new Spring(0), _r = new Spring(13), _peek = new Spring(1);
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private double _lastFrame;
        private bool _animating;

        private bool _pointerInside;
        private bool _hiddenForFullscreen;
        private bool _seeking, _settingVolume;
        private readonly DispatcherTimer _hoverOpen = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.25) };
        private readonly DispatcherTimer _hoverClose = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.45) };
        private readonly DispatcherTimer _bannerTimer = new DispatcherTimer();
        private readonly DispatcherTimer _progressTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.1) };
        private readonly DispatcherTimer _housekeeping = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };

        private const double CanvasWidth = 720;

        public IslandWindow(MediaService media, AudioService audio, PowerService power)
        {
            _media = media;
            _audio = audio;
            _power = power;
            InitializeComponent();

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
            _progressTimer.Tick += (_, _) => { UpdateProgress(); UpdateVolume(); };
            _housekeeping.Tick += (_, _) => Housekeeping();
            _housekeeping.Start();

            _media.Changed += _ => OnTrack();
            _audio.VolumeChanged += OnVolume;
            _audio.DefaultDeviceChanged += OnOutputChanged;
            _power.Changed += OnPower;
            S.PropertyChanged += OnSettingChanged;
            SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(new Action(Position));
            ApplySpectrumSize();
        }

        // ---- placement ----

        private void Position()
        {
            Left = (SystemParameters.PrimaryScreenWidth - Width) / 2;
            Top = 0;
        }

        private void Housekeeping()
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            if (hwnd != IntPtr.Zero)
                Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0,
                                    Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
            var hide = S.HideInFullscreen && Native.FullscreenAppInFront();
            if (hide != _hiddenForFullscreen)
            {
                _hiddenForFullscreen = hide;
                Root.BeginAnimation(OpacityProperty, new DoubleAnimation(hide ? 0 : 1, TimeSpan.FromSeconds(0.25)));
                Root.IsHitTestVisible = !hide;
                UpdateBarsActivity();
            }
        }

        // ---- sizes (DIPs) — the Mac island's: wings of 35, a camera-sized middle ----

        private double Scale => S.IslandScale;
        private double Middle => 185;                              // where the Mac has its camera
        private double CompactW => (Middle + 70) * Scale;
        private const double CompactH = 35;
        private double BannerW => (Middle + 150) * Scale;
        private double ExpandedW => 353 * Scale;
        private double ExpandedH => !S.PlayerNew ? 168 : (S.VolumeRow ? 206 : 186);
        private double IdleW => Middle * 0.8 * Scale;
        private const double IdleH = 30;

        private bool HasTrack => S.ShowMedia && _media.Track != null;
        private Mode RestingMode => HasTrack ? Mode.Compact : (S.ShowIdlePill ? Mode.Idle : Mode.Hidden);

        // ---- state changes ----

        // Busy = the player is open or a banner is showing (eye breaks and
        // updates wait for it).
        public bool Busy => _mode is Mode.Expanded or Mode.Banner;

        // 0.4.2: the transparent window is only as tall as it must be — the
        // processor redraws every pixel of it, so 720×64 instead of 720×320
        // while the island is closed.
        private const double TallHeight = 320, ShortHeight = 64;

        private void FitWindow()
        {
            bool tall = _mode == Mode.Expanded || _h.Value > ShortHeight - 8 || _h.Target > ShortHeight - 8;
            var height = tall ? TallHeight : ShortHeight;
            if (Math.Abs(Height - height) > 0.5) Height = height;
        }

        private void SetMode(Mode mode, bool animated = true)
        {
            var old = _mode;
            _mode = mode;
            if (mode != Mode.Banner) _bannerTap = null;
            Relayout(animated, growing: Area(mode) > Area(old));
            FitWindow();
            Fade(CompactLayer, mode == Mode.Compact);
            Fade(BannerLayer, mode == Mode.Banner);
            Fade(ExpandedLayer, mode == Mode.Expanded);
            _progressTimer.IsEnabled = mode == Mode.Expanded;
            if (mode == Mode.Expanded) { UpdateProgress(); UpdateVolume(); }
            if (mode != Mode.Expanded) OutputList.Visibility = Visibility.Collapsed;
            UpdateBarsActivity();
        }

        private static double Area(Mode m) => m switch
        {
            Mode.Expanded => 3, Mode.Banner => 2, Mode.Compact => 1.5, Mode.Idle => 1, _ => 0
        };

        private void Relayout(bool animated, bool growing = true)
        {
            (double w, double h, double r) = _mode switch
            {
                Mode.Expanded => (ExpandedW, ExpandedH, 26.0),
                Mode.Banner => (BannerW, CompactH, 13.0),
                Mode.Compact => (CompactW, CompactH, 13.0),
                Mode.Idle => (IdleW, IdleH, 12.0),
                _ => (IdleW * 0.8, 0.0, 12.0)
            };
            if (!animated)
            {
                _w.Snap(w); _h.Snap(h); _r.Snap(r);
                DrawFrame();
                return;
            }
            var resp = growing ? Motion.GrowResponse : Motion.ShrinkResponse;
            var damp = growing ? Motion.GrowDamping : Motion.ShrinkDamping;
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
                FitWindow();
            }
        }

        // Square to the top edge, small concave «flares» into the screen edge,
        // round bottom corners — the Mac silhouette.
        private void DrawFrame()
        {
            double w = Math.Max(0, _w.Value), h = Math.Max(0, _h.Value);
            double cx = CanvasWidth / 2;
            double r = Math.Max(0, Math.Min(_r.Value, Math.Min(h / 2, w / 2)));
            double flare = Math.Max(0, Math.Min(_mode == Mode.Expanded ? 13 : 7, h - r));
            double l = cx - w / 2, rt = cx + w / 2;

            if (h < 0.5)
            {
                Shape.Data = Geometry.Empty;
            }
            else
            {
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
                Shape.Data = g;
            }

            // ContentHost is in a Grid: placed by its margin.
            ContentHost.Margin = new Thickness(l, 0, 0, 0);
            ContentHost.Width = w;
            ContentHost.Height = h;
            ContentHost.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);

            Place(CompactLayer, CompactW, w);
            Place(BannerLayer, BannerW, w);
            Place(ExpandedLayer, ExpandedW, w);
            ExpandedLayer.Height = ExpandedH;

            PeekScale.ScaleX = _peek.Value;
            PeekScale.ScaleY = _peek.Value;
        }

        private static void Place(FrameworkElement layer, double width, double hostWidth)
        {
            layer.Width = width;
            Canvas.SetLeft(layer, (hostWidth - width) / 2);
        }

        // Contents arrive from a soft blur, slightly smaller — and leave at once.
        private static void Fade(FrameworkElement layer, bool show)
        {
            layer.IsHitTestVisible = show;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            layer.BeginAnimation(OpacityProperty, new DoubleAnimation(show ? 1 : 0, TimeSpan.FromSeconds(show ? 0.24 : 0.12))
            {
                BeginTime = TimeSpan.FromSeconds(show ? 0.08 : 0),
                EasingFunction = ease
            });
            if (layer.RenderTransform is not ScaleTransform)
            {
                layer.RenderTransform = new ScaleTransform(1, 1);
                layer.RenderTransformOrigin = new Point(0.5, 0);
            }
            var scale = (ScaleTransform)layer.RenderTransform;
            var s = new DoubleAnimation(show ? 1 : 0.86, TimeSpan.FromSeconds(show ? 0.32 : 0.12))
            {
                BeginTime = TimeSpan.FromSeconds(show ? 0.05 : 0),
                EasingFunction = ease
            };
            if (show) scale.ScaleX = scale.ScaleY = 0.86;
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, s);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, s);
            if (show)
            {
                var blur = new System.Windows.Media.Effects.BlurEffect { Radius = 6 };
                layer.Effect = blur;
                var unblur = new DoubleAnimation(0, TimeSpan.FromSeconds(0.3)) { BeginTime = TimeSpan.FromSeconds(0.06), EasingFunction = ease };
                unblur.Completed += (_, _) => { if (layer.Effect == blur) layer.Effect = null; };
                blur.BeginAnimation(System.Windows.Media.Effects.BlurEffect.RadiusProperty, unblur);
            }
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
            if (_mode == Mode.Expanded && !_seeking && !_settingVolume) _hoverClose.Start();
        }

        private void OnIslandClick(object sender, MouseButtonEventArgs e)
        {
            if (_mode == Mode.Banner && _bannerTap != null)
            {
                var tap = _bannerTap;
                _bannerTap = null;
                e.Handled = true;
                tap();
                return;
            }
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

        private BitmapSource? _shownArtwork;

        private void OnTrack()
        {
            var t = _media.Track;
            if (t != null)
            {
                if (!ReferenceEquals(t.Artwork, _shownArtwork))
                {
                    _shownArtwork = t.Artwork;
                    SetArt(CompactArt, CompactArtPlaceholder, t.Artwork);
                    SetArt(ExpandedArt, ExpandedArtPlaceholder, t.Artwork);
                    Glow.Background = t.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : null;
                    if (Glow.Background != null)
                        Glow.Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 24 };
                }
                ArtGlow.Color = t.Tint;
                CompactBars.SetCover(t.Artwork, t.Tint);
                ExpandedBars.SetCover(t.Artwork, t.Tint);
                CompactBars.Playing = ExpandedBars.Playing = t.Playing;
                PlayGlyph.Set(t.Playing);
                FillExpanded();
            }
            else
            {
                CompactBars.Playing = ExpandedBars.Playing = false;
            }
            if (_mode == Mode.Banner) return;            // the banner returns to the right place itself
            if (_mode == Mode.Expanded && t == null) { SetMode(RestingMode); return; }
            if (_mode != Mode.Expanded && _mode != RestingMode) SetMode(RestingMode);
        }

        // Rounded covers: the picture is the border's background, so the
        // corners really are round (an Image inside would stay square).
        private static void SetArt(Border box, FrameworkElement placeholder, BitmapSource? image)
        {
            if (image != null)
            {
                box.Background = new ImageBrush(image) { Stretch = Stretch.UniformToFill };
                placeholder.Visibility = Visibility.Collapsed;
            }
            else
            {
                box.Background = new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x20));
                placeholder.Visibility = Visibility.Visible;
            }
            var fade = new DoubleAnimation(0.4, 1, TimeSpan.FromSeconds(0.35)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            box.BeginAnimation(OpacityProperty, fade);
        }

        private void FillExpanded()
        {
            var t = _media.Track;
            if (t == null) return;
            SongTitle.Text = t.Title;
            SongArtist.Text = t.Artist;
            var output = _audio.Current;
            if (output != null) OutputIcon.Icon = output.Glyph;
            OutputButton.Visibility = S.OutputPicker ? Visibility.Visible : Visibility.Hidden;
            ApplyPlayerStyle();
            UpdateProgress();
            UpdateVolume();
        }

        // 0.4.0: the new player (Mac today) or the classic one (Mac before 4.0).
        private void ApplyPlayerStyle()
        {
            bool modern = S.PlayerNew;
            ExpandedArt.Width = ExpandedArt.Height = modern ? 72 : 55;
            ExpandedArt.CornerRadius = new CornerRadius(modern ? 13 : 12);
            ExpandedArt.Effect = modern ? ArtGlow : null;
            SongTitle.FontSize = modern ? 15 : 14;
            SongTitle.FontWeight = modern ? FontWeights.Bold : FontWeights.SemiBold;
            SongTitle.FontFamily = (FontFamily)FindResource(modern ? "DisplayFont" : "UiFont");
            SongArtist.FontSize = modern ? 12.5 : 12;
            Glow.Visibility = modern ? Visibility.Visible : Visibility.Collapsed;
            VolumeRow.Visibility = modern && S.VolumeRow ? Visibility.Visible : Visibility.Collapsed;
            ApplySpectrumSize();
        }

        private void UpdateBarsActivity()
        {
            CompactBars.Active = _mode == Mode.Compact && !_hiddenForFullscreen;
            ExpandedBars.Active = _mode == Mode.Expanded && !_hiddenForFullscreen;
        }

        private void ApplySpectrumSize()
        {
            var k = S.SpectrumSize;
            CompactBars.BarWidth = 2.2 * k; CompactBars.BarSpacing = 1.7 * k; CompactBars.BarMaxHeight = 16 * k;
            if (S.PlayerNew) { ExpandedBars.BarWidth = 2.8 * k; ExpandedBars.BarSpacing = 2.1 * k; ExpandedBars.BarMaxHeight = 26 * k; }
            else { ExpandedBars.BarWidth = 2.9 * k; ExpandedBars.BarSpacing = 2.3 * k; ExpandedBars.BarMaxHeight = 32 * k; }
            CompactBars.InvalidateMeasure(); ExpandedBars.InvalidateMeasure();
            var t = _media.Track;
            CompactBars.SetCover(t?.Artwork, t?.Tint ?? Color.FromRgb(0xFF, 0x5A, 0x7A));
            ExpandedBars.SetCover(t?.Artwork, t?.Tint ?? Color.FromRgb(0xFF, 0x5A, 0x7A));
        }

        // ---- progress and seeking ----

        private void UpdateProgress()
        {
            var t = _media.Track;
            if (t == null || _seeking) return;
            var pos = t.LivePosition;
            ShowProgress(pos, t.Duration);
        }

        private void ShowProgress(TimeSpan pos, TimeSpan duration)
        {
            TimeElapsed.Text = Format(pos);
            TimeTotal.Text = duration > TimeSpan.Zero ? "-" + Format(duration - pos) : "";
            var fraction = duration > TimeSpan.Zero ? Math.Clamp(pos.TotalSeconds / duration.TotalSeconds, 0, 1) : 0;
            ProgressFill.Width = Math.Max(0, ProgressTrack.ActualWidth * fraction);
        }

        private static string Format(TimeSpan t)
        {
            if (t < TimeSpan.Zero) t = TimeSpan.Zero;
            return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : $"{(int)t.TotalMinutes}:{t.Seconds:00}";
        }

        private TimeSpan SeekPosition(MouseEventArgs e)
        {
            var t = _media.Track;
            if (t == null || t.Duration <= TimeSpan.Zero || ProgressTrack.ActualWidth <= 0) return TimeSpan.Zero;
            var f = Math.Clamp(e.GetPosition(ProgressTrack).X / ProgressTrack.ActualWidth, 0, 1);
            return TimeSpan.FromSeconds(t.Duration.TotalSeconds * f);
        }

        private void OnSeekDown(object sender, MouseButtonEventArgs e)
        {
            if (_media.Track == null) return;
            _seeking = true;
            ProgressTrack.CaptureMouse();
            ShowProgress(SeekPosition(e), _media.Track.Duration);
            e.Handled = true;
        }

        private void OnSeekMove(object sender, MouseEventArgs e)
        {
            if (_seeking && _media.Track != null) ShowProgress(SeekPosition(e), _media.Track.Duration);
        }

        private void OnSeekUp(object sender, MouseButtonEventArgs e)
        {
            if (!_seeking) return;
            _seeking = false;
            ProgressTrack.ReleaseMouseCapture();
            var t = _media.Track;
            if (t == null) return;
            var pos = SeekPosition(e);
            _media.Seek(pos);
            t.Position = pos;
            t.PositionUpdated = DateTimeOffset.Now;
            UpdateProgress();
            e.Handled = true;
        }

        // ---- volume row ----

        private void UpdateVolume()
        {
            if (_settingVolume || VolumeTrack.ActualWidth <= 0) return;
            VolumeFill.Width = VolumeTrack.ActualWidth * Math.Clamp(_audio.Muted ? 0 : _audio.Volume, 0, 1);
        }

        private void SetVolumeFrom(MouseEventArgs e)
        {
            if (VolumeTrack.ActualWidth <= 0) return;
            var f = Math.Clamp(e.GetPosition(VolumeTrack).X / VolumeTrack.ActualWidth, 0, 1);
            VolumeFill.Width = VolumeTrack.ActualWidth * f;
            _audio.Volume = (float)f;
        }

        private void OnVolumeDown(object sender, MouseButtonEventArgs e)
        {
            _settingVolume = true;
            VolumeTrack.CaptureMouse();
            SetVolumeFrom(e);
            e.Handled = true;
        }

        private void OnVolumeMove(object sender, MouseEventArgs e)
        {
            if (_settingVolume) SetVolumeFrom(e);
        }

        private void OnVolumeUp(object sender, MouseButtonEventArgs e)
        {
            if (!_settingVolume) return;
            SetVolumeFrom(e);
            _settingVolume = false;
            VolumeTrack.ReleaseMouseCapture();
            e.Handled = true;
        }

        // ---- buttons ----

        private void OnPlayPause(object sender, RoutedEventArgs e)
        {
            _media.PlayPause();
            if (_media.Track != null)
            {
                _media.Track.Playing = !_media.Track.Playing;
                PlayGlyph.Set(_media.Track.Playing);
                CompactBars.Playing = ExpandedBars.Playing = _media.Track.Playing;
            }
        }

        private void OnNext(object sender, RoutedEventArgs e) { NextGlyph.Pulse(); _media.Next(); }
        private void OnPrevious(object sender, RoutedEventArgs e) { PrevGlyph.Pulse(); _media.Previous(); }

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
                var icon = new IconView { Icon = d.Glyph, Width = 17, Height = 17, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
                var name = new TextBlock { Text = d.Name, FontSize = 13, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
                Grid.SetColumn(name, 1);
                row.Children.Add(icon);
                row.Children.Add(name);
                if (d.IsDefault)
                {
                    var check = new IconView { Icon = "checkmark", Width = 14, Height = 14, Fill = new SolidColorBrush(Color.FromRgb(0x4C, 0x8D, 0xFF)), VerticalAlignment = VerticalAlignment.Center };
                    Grid.SetColumn(check, 2);
                    row.Children.Add(check);
                }
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
            border.SetValue(Border.CornerRadiusProperty, new CornerRadius(9));
            border.SetValue(Border.PaddingProperty, new Thickness(8, 0, 8, 0));
            border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
            border.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
            t.VisualTree = border;
            var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)), "Bg"));
            t.Triggers.Add(hover);
            return t;
        }

        private void OnOutputsClose(object sender, RoutedEventArgs e) => OutputList.Visibility = Visibility.Collapsed;

        // ---- banners ----

        private Action? _bannerTap;

        private void ShowBanner(string icon, string text, Color colour, double? level, double seconds, Action? tap = null)
        {
            BannerIcon.Icon = icon;
            BannerIcon.Fill = new SolidColorBrush(colour);
            BannerText.Text = text;
            BannerLevel.Visibility = level.HasValue ? Visibility.Visible : Visibility.Collapsed;
            if (level.HasValue)
            {
                BannerLevelFill.Background = new SolidColorBrush(colour);
                BannerLevelFill.BeginAnimation(WidthProperty,
                    new DoubleAnimation(86 * Math.Clamp(level.Value, 0, 1), TimeSpan.FromSeconds(0.15)));
            }
            _bannerTimer.Stop();
            _bannerTimer.Interval = TimeSpan.FromSeconds(seconds);
            _bannerTimer.Start();
            if (_mode != Mode.Banner) SetMode(Mode.Banner);
            _bannerTap = tap;
            Island.Cursor = tap != null ? Cursors.Hand : null;
        }

        // ---- the helper and updates (0.4.2) ----

        private static readonly Color EyeColour = Color.FromRgb(0x40, 0xCC, 0xD9);

        public void ShowEyeBreak(string text, double level, Action skip) => ShowBanner("eye", text, EyeColour, level, 2.5, skip);
        public void ShowEyeBreakDone() => ShowBanner("checkmark", "Готово — можно продолжать", Color.FromRgb(0x34, 0xC7, 0x59), null, 1.8);
        public void ShowEyeBreakSkipped() => ShowBanner("xmark", "Перерыв пропущен", Color.FromRgb(0x8E, 0x8E, 0x93), null, 1.3);

        public void ShowUpdateReady(string version) =>
            ShowBanner("arrow.down", $"Ovira {version} — нажми, чтобы обновить", Color.FromRgb(0x4C, 0x8D, 0xFF), null, 7,
                       () => App.Current.Updates.Install());

        public void ShowUpdated(string version) =>
            ShowBanner("checkmark", $"Ovira обновлена до {version}", Color.FromRgb(0x34, 0xC7, 0x59), null, 3);

        private void EndBanner()
        {
            if (_mode != Mode.Banner) return;
            Island.Cursor = null;
            SetMode(_pointerInside && HasTrack && S.OpenOnHover ? Mode.Expanded : RestingMode);
        }

        private void OnVolume(float level, bool muted)
        {
            if (_mode == Mode.Expanded) { UpdateVolume(); return; }
            if (!S.VolumeBanner) return;
            var percent = (int)Math.Round(level * 100);
            ShowBanner(muted ? "speaker.slash" : "speaker.wave", muted ? "Без звука" : $"Громкость {percent} %",
                       Colors.White, muted ? 0 : level, 1.6);
        }

        private void OnOutputChanged(OutputDevice device)
        {
            OutputIcon.Icon = device.Glyph;
            if (!S.OutputBanner) return;
            ShowBanner(device.Glyph, device.Name, Color.FromRgb(0x4C, 0x8D, 0xFF), null, 2.4);
        }

        private void OnPower(PowerEvent e, int percent)
        {
            switch (e)
            {
                case PowerEvent.Plugged when S.ChargingBanner:
                    ShowBanner("bolt", $"Зарядка · {percent} %", Color.FromRgb(0x34, 0xC7, 0x59), percent / 100.0, 2.6);
                    break;
                case PowerEvent.Unplugged when S.ChargingBanner:
                    ShowBanner("battery", $"От батареи · {percent} %", Colors.White, percent / 100.0, 2.2);
                    break;
                case PowerEvent.Low when S.LowBatteryBanner:
                    ShowBanner("battery", $"Низкий заряд · {percent} %", Color.FromRgb(0xFF, 0x9F, 0x0A), percent / 100.0, 4);
                    break;
                case PowerEvent.Critical when S.LowBatteryBanner:
                    ShowBanner("battery", $"Почти разряжен · {percent} %", Color.FromRgb(0xFF, 0x45, 0x3A), percent / 100.0, 5);
                    break;
            }
        }

        // ---- demonstrations for the settings window ----

        public void DemoVolume() => ShowBanner("speaker.wave", "Громкость 60 %", Colors.White, 0.6, 2);
        public void DemoCharging() => ShowBanner("bolt", "Зарядка · 76 %", Color.FromRgb(0x34, 0xC7, 0x59), 0.76, 2.6);
        public void DemoLowBattery() => ShowBanner("battery", "Низкий заряд · 20 %", Color.FromRgb(0xFF, 0x9F, 0x0A), 0.2, 3);
        public void DemoEyeBreak() => App.Current.EyeBreak.Begin();
        public void DemoOutput() => ShowBanner("headphones", "Наушники", Color.FromRgb(0x4C, 0x8D, 0xFF), null, 2.4);
        public void DemoOpen()
        {
            if (HasTrack) { Expand(); _hoverClose.Stop(); if (!_pointerInside) _hoverClose.Start(); }
            else ShowBanner("music.note", "Включи музыку — плеер появится здесь", Colors.White, null, 3);
        }

        // ---- settings ----

        private void OnSettingChanged(object? sender, PropertyChangedEventArgs e)
        {
            switch (e.PropertyName)
            {
                case nameof(Settings.IslandScale):
                case nameof(Settings.VolumeRow):
                case nameof(Settings.PlayerNew):
                    FillExpanded();
                    Relayout(animated: true);
                    break;
                case nameof(Settings.ShowMedia):
                case nameof(Settings.ShowIdlePill):
                    if (_mode != Mode.Banner && _mode != Mode.Expanded) SetMode(RestingMode);
                    else if (_mode == Mode.Expanded && !HasTrack) SetMode(RestingMode);
                    break;
                case nameof(Settings.OutputPicker):
                    OutputButton.Visibility = S.OutputPicker ? Visibility.Visible : Visibility.Hidden;
                    break;
                case nameof(Settings.SpectrumSize):
                case nameof(Settings.SpectrumStyle):
                case nameof(Settings.SpectrumBlur):
                    ApplySpectrumSize();
                    break;
            }
        }

        public void Begin() => SetMode(RestingMode, animated: true);
    }
}
