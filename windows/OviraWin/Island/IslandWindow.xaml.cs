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
using System.Threading.Tasks;

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
                App.Current.VolumeKeys.Attach(hwnd);
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
            // 0.4.15: «Медиаплеер поверх игр» — while music plays the island
            // stays over games and full-screen video.
            // 0.5.0: on pause too — the player does not vanish from the game.
            var hide = S.HideInFullscreen && Native.FullscreenAppInFront() &&
                       !(S.GameMedia && HasTrack);
            if (hide != _hiddenForFullscreen)
            {
                _hiddenForFullscreen = hide;
                if (!(hide && _overGame && _mode == Mode.Banner))
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
        // 0.4.5: the eye break is a short, lopsided banner like on the Mac —
        // an icon on the left, a word or the countdown on the right, nothing
        // in the middle.
        private bool _wing;
        private double BannerW => (Middle + (_wing ? 120 : 150)) * Scale;
        private double ExpandedW => 353 * Scale;
        private double ExpandedH => _activityOpen ? (_shownActivity?.Details != null ? 104 + 19 + 46 * Math.Ceiling(_shownActivity.Details.Length / 3.0) : 104)
                                    : !S.PlayerNew ? 168 : (S.VolumeRow ? 206 : 186);
        private double IdleW => Middle * 0.8 * Scale;
        private const double IdleH = 30;

        private bool HasTrack => S.ShowMedia && _media.Track != null;
        private Mode RestingMode => HasTrack ? Mode.Compact : (S.ShowIdlePill ? Mode.Idle : Mode.Hidden);

        // ---- state changes ----

        // Busy = the player is open or a banner is showing (eye breaks and
        // updates wait for it).
        public bool Busy => _mode == Mode.Expanded || (_mode == Mode.Banner && !_activityBanner);

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
            Fade(ExpandedLayer, mode == Mode.Expanded && !_activityOpen);
            Fade(ActivityLayer, mode == Mode.Expanded && _activityOpen);
            LivingCover(mode == Mode.Expanded && !_activityOpen);
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
            // 0.4.18: the iPhone style is a capsule when small and a card
            // with big round corners when open.
            if (Floating) r = _mode == Mode.Expanded ? 40.0 : Math.Max(h, CompactH) / 2;
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

        // 0.4.18: two styles. «Вырез» — square to the top edge, small concave
        // «flares» into the screen edge, round bottom corners (the Mac).
        // «Как на iPhone» — the Dynamic Island: a separate capsule floating a
        // little below the edge, round on all sides.
        private bool Floating => S.IslandStyle == "island";
        private double TopGap => Floating ? 9 : 0;

        private void DrawFrame()
        {
            double w = Math.Max(0, _w.Value), h = Math.Max(0, _h.Value);
            double cx = CanvasWidth / 2;
            double r = Math.Max(0, Math.Min(_r.Value, Math.Min(h / 2, w / 2)));
            double flare = Math.Max(0, Math.Min(_mode == Mode.Expanded ? 13 : 7, h - r));
            double l = cx - w / 2, rt = cx + w / 2;
            double top = TopGap;
            Island.RenderTransformOrigin = new Point(0.5, Floating ? (top + h / 2) / Island.Height : 0);

            if (h < 0.5)
            {
                Shape.Data = Geometry.Empty;
            }
            else if (Floating)
            {
                var g = new RectangleGeometry(new Rect(l, top, w, h), r, r);
                g.Freeze();
                Shape.Data = g;
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
            ContentHost.Margin = new Thickness(l, top, 0, 0);
            ContentHost.Width = w;
            ContentHost.Height = h;
            ContentHost.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);

            Place(CompactLayer, CompactW, w);
            // 0.4.6: banner contents ride on the island's edges while it grows,
            // so the icon never trails behind the shape.
            Place(BannerLayer, w, w);
            Place(ExpandedLayer, ExpandedW, w);
            Place(ActivityLayer, ExpandedW, w);
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
            RefreshFavorite(force: true);
            FillExpanded();
            SetMode(Mode.Expanded);
        }

        private void Collapse()
        {
            if (_mode != Mode.Expanded) return;
            bool wasActivity = _activityOpen;
            _activityOpen = false;
            SetMode(RestingMode);
            if (ActivitySource?.Invoke() != null) RefreshActivity();
        }

        // ---- media ----

        private BitmapSource? _shownArtwork;

        private void OnTrack()
        {
            var wait = _quietUntil - DateTime.Now;
            if (wait > TimeSpan.Zero)
            {
                if (_trackPending) return;
                _trackPending = true;
                var later = new DispatcherTimer { Interval = wait };
                later.Tick += (_, _) => { later.Stop(); _trackPending = false; OnTrack(); };
                later.Start();
                return;
            }
            if (S.Theme == "cover") ApplyIslandTheme();
            var t = _media.Track;
            if (t != null)
            {
                if (!ReferenceEquals(t.Artwork, _shownArtwork))
                {
                    _shownArtwork = t.Artwork;
                    SetArt(CompactArt, CompactArtPlaceholder, t.Artwork);
                    SetArt(ExpandedArt, ExpandedArtPlaceholder, t.Artwork);
                    _livingBrush = null;
                    Glow.Background = t.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : null;
                    if (Glow.Background != null)
                        Glow.Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 24 };
                }
                ArtGlow.Color = t.Tint;
                CompactBars.SetCover(t.Artwork, t.Tint);
                ExpandedBars.SetCover(t.Artwork, t.Tint);
                CompactBars.Playing = ExpandedBars.Playing = t.Playing;
                PlayGlyph.Set(t.Playing);
                ShowSaved(animated: false);
                RefreshFavorite();
                LivingCover(_mode == Mode.Expanded && !_activityOpen);
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

        // 0.4.16: the new song's cover, colours and blurred bars are built only
        // after the step animation — building them in the middle made it stutter.
        private DateTime _quietUntil;
        private bool _trackPending;

        private void HoldTrackWork() => _quietUntil = DateTime.Now.AddSeconds(0.34);

        private void OnNext(object sender, RoutedEventArgs e) { HoldTrackWork(); NextGlyph.Pulse(); _media.Next(); }

        // ---- «Сохранить» (0.4.14) ----
        // Windows gives no way to «like» a song inside a music app, so the
        // star keeps the song in Ovira's own list (Settings → Медиаплеер →
        // «Сохранённые песни»). The motion is the Mac's AnimatedFavoriteStar.

        // 0.4.15: for Yandex Music the star is the app's real «Мне нравится»
        // (read and pressed through Windows accessibility, see
        // YandexFavorites); other players keep Ovira's own list.
        private string _favKey = "";
        private bool? _favRemote;          // the app's state, when it could be read
        private bool _favBusy;

        private static string FavKey(TrackInfo t) => t.Title + "\u0001" + t.Artist;

        private async void RefreshFavorite(bool force = false)
        {
            var t = _media.Track;
            if (t == null) return;
            var key = FavKey(t);
            bool changed = key != _favKey;
            if (changed) { _favKey = key; _favRemote = null; ShowSaved(animated: false); }
            else if (!force) return;                     // a pause or a position — nothing to read
            if (!S.SaveButton || !YandexFavorites.MightBeYandex(t) || _favBusy) return;
            await Task.Delay(700);                       // the app's player bar updates a moment later
            if (_media.Track == null || FavKey(_media.Track) != key) return;
            var state = await YandexFavorites.ReadAsync(_media.Track);
            if (_media.Track == null || FavKey(_media.Track) != key || _favBusy) return;
            if (state != _favRemote) { _favRemote = state; ShowSaved(animated: false); }
        }

        // 0.4.17: the star answers at once — Yandex Music is asked afterwards.
        private async void OnSave(object sender, RoutedEventArgs e)
        {
            var t = _media.Track;
            if (t == null || _favBusy) return;
            var key = FavKey(t);
            bool before = _favRemote ?? SavedTracks.Contains(t.Title, t.Artist);
            bool target = !before;
            if (!YandexFavorites.MightBeYandex(t))
            {
                SavedTracks.Toggle(t.Title, t.Artist, t.Source);
                ShowSaved(animated: true, justSaved: target);
                return;
            }
            _favBusy = true;
            if (_favRemote != null) _favRemote = target;
            else if (SavedTracks.Contains(t.Title, t.Artist) != target) SavedTracks.Toggle(t.Title, t.Artist, t.Source);
            ShowSaved(animated: true, justSaved: target);
            var result = await YandexFavorites.WriteAsync(t, target);
            _favBusy = false;
            if (_media.Track == null || FavKey(_media.Track) != key) return;
            switch (result)
            {
                case YandexFavorites.WriteResult.Done:
                    // In Yandex now — the local copy is not needed.
                    if (SavedTracks.Contains(t.Title, t.Artist)) SavedTracks.Toggle(t.Title, t.Artist, t.Source);
                    _favRemote = target;
                    ShowSaved(animated: false);
                    break;
                case YandexFavorites.WriteResult.Refused:
                    _favRemote = before;
                    if (SavedTracks.Contains(t.Title, t.Artist)) SavedTracks.Toggle(t.Title, t.Artist, t.Source);
                    ShowSaved(animated: false);
                    ShowBanner("xmark", "", Grey, null, 1.6, right: "Не вышло");
                    break;
                default:
                    // Yandex Music's button was not found: kept in Ovira's list.
                    if (_favRemote != null) { _favRemote = null; if (SavedTracks.Contains(t.Title, t.Artist) != target) SavedTracks.Toggle(t.Title, t.Artist, t.Source); }
                    ShowSaved(animated: false);
                    if (target) ShowBanner("star.fill", "", Grey, null, 1.8, right: "Только в Ovira");
                    break;
            }
        }

        private void ShowSaved(bool animated, bool justSaved = false)
        {
            var t = _media.Track;
            SaveButton.Visibility = S.SaveButton ? Visibility.Visible : Visibility.Hidden;
            bool saved = t != null && (_favRemote ?? SavedTracks.Contains(t.Title, t.Artist));
            SaveStar.Icon = saved ? "star.fill" : "star.outline";
            var tint = t != null ? Readable(t.Tint) : Colors.White;
            SaveStar.Fill = saved ? new SolidColorBrush(tint) : new SolidColorBrush(Color.FromArgb(0xD6, 0xFF, 0xFF, 0xFF));
            SaveButton.ToolTip = _favRemote != null
                ? (saved ? "Убрать из «Мне нравится» в Яндекс Музыке" : "«Мне нравится» в Яндекс Музыке")
                : (saved ? "Убрать из сохранённых" : "Сохранить песню");
            if (!animated) return;

            var press = new BackEase { Amplitude = 0.55, EasingMode = EasingMode.EaseOut };
            void Scale(double from, double to, double seconds, IEasingFunction ease, double delay = 0)
            {
                var a = new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds)) { EasingFunction = ease, BeginTime = TimeSpan.FromSeconds(delay) };
                SaveStarScale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
                SaveStarScale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
            }
            if (justSaved)
            {
                // Add: the star springs out of a squeeze, turning back from
                // −10°, and a thin ring in the cover's colour spreads and fades.
                var grow = new DoubleAnimationUsingKeyFrames();
                grow.KeyFrames.Add(new DiscreteDoubleKeyFrame(0.68, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                grow.KeyFrames.Add(new EasingDoubleKeyFrame(1.32, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.16)), new CubicEase { EasingMode = EasingMode.EaseOut }));
                grow.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.5)), press));
                SaveStarScale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
                SaveStarScale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
                SaveStarTurn.BeginAnimation(RotateTransform.AngleProperty,
                    new DoubleAnimation(-10, 0, TimeSpan.FromSeconds(0.4)) { EasingFunction = press });
                SaveRing.Stroke = new SolidColorBrush(Color.FromArgb(0xCC, tint.R, tint.G, tint.B));
                var ring = new DoubleAnimation(0.55, 1.65, TimeSpan.FromSeconds(0.32)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                SaveRingScale.BeginAnimation(ScaleTransform.ScaleXProperty, ring);
                SaveRingScale.BeginAnimation(ScaleTransform.ScaleYProperty, ring);
                SaveRing.BeginAnimation(OpacityProperty, new DoubleAnimation(0.95, 0, TimeSpan.FromSeconds(0.32)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            }
            else
            {
                // Remove: a short collapse inwards, then back to the outline.
                var shrink = new DoubleAnimationUsingKeyFrames();
                shrink.KeyFrames.Add(new DiscreteDoubleKeyFrame(1.16, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                shrink.KeyFrames.Add(new EasingDoubleKeyFrame(0.6, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.13)), new CubicEase { EasingMode = EasingMode.EaseIn }));
                shrink.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.5)), press));
                SaveStarScale.BeginAnimation(ScaleTransform.ScaleXProperty, shrink);
                SaveStarScale.BeginAnimation(ScaleTransform.ScaleYProperty, shrink);
                SaveStarTurn.BeginAnimation(RotateTransform.AngleProperty,
                    new DoubleAnimation(10, 0, TimeSpan.FromSeconds(0.4)) { EasingFunction = press });
                SaveRing.BeginAnimation(OpacityProperty, null);
                SaveRing.Opacity = 0;
            }
        }
        private void OnPrevious(object sender, RoutedEventArgs e) { HoldTrackWork(); PrevGlyph.Pulse(); _media.Previous(); }

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
        private bool _overGame;

        // ---- live activities (0.5.0): a call, the timer, the stopwatch, an alarm ----
        // Shown as a banner that stays (an icon on the left, the time on the
        // right); a click opens the panel with the buttons. A short banner
        // (volume…) goes over it and then gives the place back.

        public sealed record Activity(string Key, string Icon, Color Colour, string Right, string Title, string Big,
                                      string? IconA, Action? A, bool ARed, string IconB, Action B, bool TapRuns = false,
                                      double? Progress = null, (string Label, string Value)[]? Details = null);

        public Func<Activity?>? ActivitySource;
        private bool _activityBanner, _activityOpen;
        private string _activityKey = "";
        private readonly DispatcherTimer _activityTick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        private Activity? _shownActivity;

        public void RefreshActivity()
        {
            if (!_activityTick.IsEnabled) { _activityTick.Tick -= OnActivityTick; _activityTick.Tick += OnActivityTick; }
            var a = ActivitySource?.Invoke();
            _shownActivity = a;
            if (a == null)
            {
                _activityTick.Stop();
                if (_mode == Mode.Expanded && _activityOpen) { _activityOpen = false; SetMode(RestingMode); }
                else if (_mode == Mode.Banner && _activityBanner) { _activityBanner = false; _bannerTimer.Stop(); EndBanner(); }
                _activityBanner = false;
                return;
            }
            _activityTick.Start();
            if (_mode == Mode.Expanded)
            {
                if (_activityOpen) FillActivity(a);
                return;                                   // the player is open — leave it
            }
            if (_mode == Mode.Banner && !_activityBanner) return;   // a short banner is showing
            if (_mode == Mode.Banner && _activityBanner && _activityKey == a.Key)
            {
                BannerRight.Text = a.Right;
                if (BannerIcon.Icon != a.Icon) { BannerIcon.Icon = a.Icon; Pop(BannerIcon); }
                BannerIcon.Fill = new SolidColorBrush(Tone(a.Icon, a.Colour));
                _bannerTap = a.TapRuns ? a.B : OpenActivity;
                return;
            }
            ShowActivityBanner(a);
        }

        private void OnActivityTick(object? sender, EventArgs e) => RefreshActivity();

        private void ShowActivityBanner(Activity a)
        {
            ShowBanner(a.Icon, "", a.Colour, null, 3600, a.TapRuns ? a.B : OpenActivity, right: a.Right);
            if (_mode != Mode.Banner) return;            // hidden over a game
            _activityBanner = true;
            _activityKey = a.Key;
        }

        private void OpenActivity()
        {
            var a = ActivitySource?.Invoke();
            if (a == null) return;
            _activityBanner = false;
            _bannerTimer.Stop();
            _activityOpen = true;
            _shownActivity = a;
            FillActivity(a);
            _peek.To(1, Motion.PeekResponse, 0.9);
            SetMode(Mode.Expanded);
        }

        private void FillActivity(Activity a)
        {
            var colour = Tone(a.Icon, a.Colour);
            ActivityIcon.Icon = a.Icon;
            ActivityIcon.Fill = new SolidColorBrush(colour);
            ActivityIconBox.Background = new SolidColorBrush(Color.FromArgb(0x33, colour.R, colour.G, colour.B));
            ActivityTitle.Text = a.Title;
            ActivityBig.Text = a.Big;
            ActivityA.Visibility = a.IconA != null ? Visibility.Visible : Visibility.Collapsed;
            if (a.IconA != null) ActivityAIcon.Icon = a.IconA;
            ActivityABg.Background = new SolidColorBrush(a.ARed ? Color.FromRgb(0xFF, 0x3B, 0x30) : Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
            ActivityBIcon.Icon = a.IconB;
            ActivityC.Visibility = HasTrack ? Visibility.Visible : Visibility.Collapsed;
            ActivityBig.FontSize = a.Details != null ? 22 : 30;
            ActivityBBg.Background = new SolidColorBrush(a.Details != null ? Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF) : Color.FromRgb(0xFF, 0x3B, 0x30));
            ActivityDetails.Visibility = a.Details != null ? Visibility.Visible : Visibility.Collapsed;
            if (a.Details != null)
            {
                ActivityProgress.Background = new SolidColorBrush(colour);
                ActivityProgressScale.BeginAnimation(ScaleTransform.ScaleXProperty,
                    new DoubleAnimation(Math.Clamp(a.Progress ?? 0, 0, 1), TimeSpan.FromSeconds(0.5)));
                // Figures: a small grey caption over a white value, three in a row.
                if (ActivityFigures.Children.Count != a.Details.Length)
                {
                    ActivityFigures.Children.Clear();
                    foreach (var _ in a.Details)
                    {
                        var cell = new StackPanel { Height = 46 };
                        cell.Children.Add(new TextBlock { Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)), FontSize = 10.5, FontWeight = FontWeights.SemiBold });
                        cell.Children.Add(new TextBlock { Foreground = Brushes.White, FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 1, 0, 0) });
                        ActivityFigures.Children.Add(cell);
                    }
                }
                for (int i = 0; i < a.Details.Length; i++)
                {
                    var cell = (StackPanel)ActivityFigures.Children[i];
                    ((TextBlock)cell.Children[0]).Text = a.Details[i].Label.ToUpperInvariant();
                    ((TextBlock)cell.Children[1]).Text = a.Details[i].Value;
                }
            }
        }

        private void OnActivityA(object sender, RoutedEventArgs e) { _shownActivity?.A?.Invoke(); RefreshActivity(); }
        private void OnActivityB(object sender, RoutedEventArgs e) { _shownActivity?.B.Invoke(); RefreshActivity(); }

        private void OnActivityC(object sender, RoutedEventArgs e)
        {
            if (!HasTrack) return;
            _activityOpen = false;
            RefreshFavorite(force: true);
            FillExpanded();
            SetMode(Mode.Expanded);
        }

        // «Живая обложка»: Windows gives players only a still picture, so the
        // cover in the open player slowly drifts closer and back, like the
        // moving covers on the iPhone. Only while the player is open.
        private ImageBrush? _livingBrush;
        private bool _livingOn;

        private void LivingCover(bool on)
        {
            if (ExpandedArt.Background is not ImageBrush brush) return;
            bool want = on && S.LivingCover && _media.Track?.Playing == true;
            if (ReferenceEquals(brush, _livingBrush) && want == _livingOn) return;   // already so — do not restart
            if (brush.IsFrozen) { brush = brush.Clone(); ExpandedArt.Background = brush; }
            _livingBrush = brush;
            _livingOn = want;
            if (brush.RelativeTransform is not ScaleTransform zoom || zoom.IsFrozen)
            {
                zoom = new ScaleTransform(1, 1, 0.5, 0.5);
                brush.RelativeTransform = zoom;
            }
            if (!want)
            {
                zoom.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                zoom.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                return;
            }
            var drift = new DoubleAnimation(1, 1.13, TimeSpan.FromSeconds(7))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
            };
            Timeline.SetDesiredFrameRate(drift, 30);
            zoom.BeginAnimation(ScaleTransform.ScaleXProperty, drift);
            zoom.BeginAnimation(ScaleTransform.ScaleYProperty, drift);
        }
        private int _rightKind;   // 0 — nothing, 1 — a word, 2 — the countdown

        private static readonly IEasingFunction Out = new CubicEase { EasingMode = EasingMode.EaseOut };

        private static TranslateTransform Shift(UIElement e)
        {
            if (e.RenderTransform is TranslateTransform t && !t.IsFrozen) return t;
            t = new TranslateTransform();
            e.RenderTransform = t;
            return t;
        }

        private static void Settle(UIElement e, bool shown)
        {
            e.BeginAnimation(OpacityProperty, null);
            Shift(e).BeginAnimation(TranslateTransform.YProperty, null);
            e.Opacity = shown ? 1 : 0;
            Shift(e).Y = 0;
        }

        private static void SlideIn(UIElement e)
        {
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.3)) { EasingFunction = Out });
            Shift(e).BeginAnimation(TranslateTransform.YProperty,
                new DoubleAnimation(9, 0, TimeSpan.FromSeconds(0.42)) { EasingFunction = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut } });
        }

        private static void SlideOut(UIElement e)
        {
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.18)) { EasingFunction = Out });
            Shift(e).BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-9, TimeSpan.FromSeconds(0.22)) { EasingFunction = Out });
        }

        private static void Roll(UIElement e)
        {
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(0.25, 1, TimeSpan.FromSeconds(0.28)) { EasingFunction = Out });
            Shift(e).BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(6, 0, TimeSpan.FromSeconds(0.32)) { EasingFunction = Out });
        }

        // A new icon in the same banner (the eye becoming the tick) pops in.
        private static void Pop(FrameworkElement e)
        {
            e.RenderTransformOrigin = new Point(0.5, 0.5);
            if (e.RenderTransform is not ScaleTransform s || s.IsFrozen) { s = new ScaleTransform(1, 1); e.RenderTransform = s; }
            var grow = new DoubleAnimation(0.35, 1, TimeSpan.FromSeconds(0.45)) { EasingFunction = new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut } };
            s.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            s.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = Out });
        }

        // 0.4.3: over a game or a full-screen video the island is hidden, but
        // the banners chosen in Settings («Поверх игр») still come out for a
        // moment and go away again. Clicks pass through to the game.
        private void ShowBanner(string icon, string text, Color colour, double? level, double seconds, Action? tap = null, bool inGame = false,
                                int? countdown = null, int countdownTotal = 20, string? right = null)
        {
            // 0.4.8: every banner is lopsided like on the Mac — an icon on the
            // left, a short word, a level or the countdown on the right, and
            // never any text in the middle.
            bool wing = true;
            _activityBanner = false;
            bool timerWasShown = BannerTimer.Visibility == Visibility.Visible && _mode == Mode.Banner;
            if (_hiddenForFullscreen)
            {
                if (!inGame) return;
                _overGame = true;
                Root.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.15)));
                var hwnd = new WindowInteropHelper(this).Handle;
                if (hwnd != IntPtr.Zero)
                    Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0,
                                        Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
            }
            else _overGame = false;
            colour = Tone(icon, colour);
            bool iconChanged = _mode == Mode.Banner && BannerIcon.Icon != icon;
            BannerIcon.Icon = icon;
            if (iconChanged) Pop(BannerIcon);
            BannerIcon.Fill = new SolidColorBrush(colour);
            BannerText.Text = wing ? "" : text;
            BannerText.Visibility = wing ? Visibility.Hidden : Visibility.Visible;
            // 0.4.7: the right side of the eye break — the word («Вдаль»,
            // «Готово») and the countdown share one place and hand over to
            // each other: the old one floats up and fades, the new one rises in.
            int kind = countdown.HasValue ? 2 : right != null ? 1 : 0;
            bool inBanner = _mode == Mode.Banner;
            BannerLevel.Visibility = level.HasValue && countdown == null ? Visibility.Visible : Visibility.Collapsed;
            if (kind == 0)
            {
                BannerRight.Visibility = Visibility.Collapsed;
                BannerTimer.Visibility = Visibility.Collapsed;
            }
            else
            {
                BannerRight.Visibility = Visibility.Visible;
                BannerTimer.Visibility = Visibility.Visible;
                var incoming = kind == 1 ? (UIElement)BannerRight : BannerTimer;
                var outgoing = kind == 1 ? (UIElement)BannerTimer : BannerRight;
                bool wordChanged = kind == 1 && BannerRight.Text != right;
                if (kind == 1) BannerRight.Text = right!;
                if (!inBanner || _rightKind == 0)
                {
                    Settle(incoming, true);
                    Settle(outgoing, false);
                }
                else if (_rightKind != kind || wordChanged)
                {
                    SlideOut(outgoing);
                    SlideIn(incoming);
                }
            }
            if (countdown.HasValue)
            {
                int left = countdown.Value;
                var number = left.ToString();
                // The number rolls like the Mac's numeric text.
                if (BannerSeconds.Text != number && timerWasShown && _rightKind == 2) Roll(BannerSeconds);
                BannerSeconds.Text = number;
                BannerTimerFill.Background = new SolidColorBrush(colour);
                // The bar is shrunk by a transform, not by its width: the width
                // snaps to whole pixels and made the bar move in steps.
                if (_rightKind != 2)
                {
                    BannerTimerScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                    BannerTimerScale.ScaleX = (double)left / countdownTotal;
                    BannerTimerScale.BeginAnimation(ScaleTransform.ScaleXProperty,
                        new DoubleAnimation(0, TimeSpan.FromSeconds(left)));
                }
            }
            _rightKind = kind;
            if (level.HasValue)
            {
                BannerLevelFill.Background = new SolidColorBrush(colour);
                BannerLevelFill.BeginAnimation(WidthProperty,
                    new DoubleAnimation(86 * Math.Clamp(level.Value, 0, 1), TimeSpan.FromSeconds(0.15)));
            }
            _bannerTimer.Stop();
            _bannerTimer.Interval = TimeSpan.FromSeconds(seconds);
            _bannerTimer.Start();
            bool resized = wing != _wing;
            _wing = wing;
            if (_mode != Mode.Banner) SetMode(Mode.Banner);
            else if (resized) { Relayout(true, growing: !wing); FitWindow(); }
            _bannerTap = tap;
            Island.Cursor = tap != null ? Cursors.Hand : null;
        }

        // ---- the helper and updates (0.4.2) ----

        private static readonly Color EyeColour = Color.FromRgb(0x40, 0xCC, 0xD9);

        // «Вдаль» for the first two seconds, then the countdown with its bar.
        public void ShowEyeBreak(int second, int total, Action skip)
        {
            if (second < 2) ShowBanner("eye", "", EyeColour, null, 2.5, skip, inGame: S.GameEyeBreak, right: "Вдаль");
            else ShowBanner("eye", "", EyeColour, null, 2.5, skip, inGame: S.GameEyeBreak, countdown: total - second, countdownTotal: total);
        }

        // ---- colours from the settings theme (0.4.4) ----
        // Icons, bars and buttons take the theme's colours; text stays white.
        // Themes without colours (Системная, Светлая, Тёмная) keep the usual
        // ones, and warnings (low battery) stay orange and red.

        private Color[] ThemePalette => Themes.Find(S.Theme, _media.Track?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66)).Palette;

        private static readonly Color Grey = Color.FromRgb(0x8E, 0x8E, 0x93);
        private static readonly Color DoneGreen = Color.FromRgb(0x33, 0xCC, 0x73);
        private static readonly Color Orange = Color.FromRgb(0xFF, 0x9F, 0x0A), Red = Color.FromRgb(0xFF, 0x45, 0x3A);

        private Color Tone(string icon, Color fallback)
        {
            if (fallback == Orange || fallback == Red || fallback == DoneGreen || fallback == Grey) return fallback;
            var p = ThemePalette;
            if (p.Length == 0) return fallback;
            int role = icon switch
            {
                "speaker" or "speaker.wave" or "speaker.slash" => 0,
                "headphones" or "display" or "laptop" => 1,
                "bolt" or "battery" => 2,
                "capslock" or "keyboard" => 1,
                "eye" => 3,
                _ => 0
            };
            return Readable(p[role % p.Length]);
        }

        // Bright enough on black.
        private static Color Readable(Color c)
        {
            double l = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
            return l >= 110 ? c : Themes.MixWhite(c, Math.Min(0.6, (110 - l) / 160 + 0.15));
        }

        private void ApplyIslandTheme()
        {
            var p = ThemePalette;
            Brush main = p.Length == 0 ? Brushes.White : new SolidColorBrush(Readable(p[0]));
            Brush second = p.Length == 0 ? new SolidColorBrush(Color.FromArgb(0xD6, 0xFF, 0xFF, 0xFF)) : new SolidColorBrush(Readable(p[1 % p.Length]));
            Brush volume = p.Length == 0 ? new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)) : new SolidColorBrush(Readable(p[Math.Min(2, p.Length - 1)]));
            // 0.4.14: the buttons, the time line and the output button stay
            // white, as on the Mac; only the volume takes the theme's colour.
            ProgressFill.Background = Brushes.White;
            VolumeFill.Background = volume;
            OutputIcon.Fill = Brushes.White;
            PrevGlyph.GlyphFill = Brushes.White;
            NextGlyph.GlyphFill = Brushes.White;
            PlayGlyph.GlyphFill = Brushes.White;
        }
        public void ShowEyeBreakDone() => ShowBanner("checkmark.circle", "", DoneGreen, null, 1.6, inGame: S.GameEyeBreak, right: "Готово");
        public void ShowEyeBreakSkipped() => ShowBanner("xmark", "", Color.FromRgb(0x8E, 0x8E, 0x93), null, 1.3, inGame: S.GameEyeBreak, right: "Пропуск");

        public void ShowUpdateReady(string version) =>
            ShowBanner("arrow.down", "", Color.FromRgb(0x4C, 0x8D, 0xFF), null, 7,
                       () => App.Current.Updates.Install(), right: "Обновить");

        public void ShowNote(string icon, string word) =>
            ShowBanner(icon, "", Color.FromRgb(0x8E, 0x8E, 0x93), null, 1.8, right: word);

        public void ShowUpdated(string version) =>
            ShowBanner("checkmark.circle", "", DoneGreen, null, 3, right: version);

        private void EndBanner()
        {
            if (_mode != Mode.Banner) return;
            Island.Cursor = null;
            _rightKind = 0;
            if (_overGame && _hiddenForFullscreen)
                Root.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.3)));
            _overGame = false;
            // 0.5.0: back to the running activity (a call, the timer…), if any.
            if (ActivitySource?.Invoke() is Activity running)
            {
                _activityBanner = false;
                ShowActivityBanner(running);
                return;
            }
            _activityBanner = false;
            SetMode(_pointerInside && HasTrack && S.OpenOnHover ? Mode.Expanded : RestingMode);
        }

        private void OnVolume(float level, bool muted)
        {
            if (_mode == Mode.Expanded) { UpdateVolume(); return; }
            if (!S.VolumeBanner) return;
            var percent = (int)Math.Round(level * 100);
            ShowBanner(muted ? "speaker.slash" : "speaker.wave", muted ? "Без звука" : $"Громкость {percent} %",
                       Colors.White, muted ? 0 : level, 1.6, inGame: S.GameVolume);
        }

        private void OnOutputChanged(OutputDevice device)
        {
            OutputIcon.Icon = device.Glyph;
            if (!S.OutputBanner) return;
            ShowBanner(device.Glyph, "", Color.FromRgb(0x4C, 0x8D, 0xFF), null, 2.4, inGame: S.GameOutput, right: ShortName(device.Name));
        }

        private void OnPower(PowerEvent e, int percent)
        {
            switch (e)
            {
                case PowerEvent.Plugged when S.ChargingBanner:
                    ShowBanner("bolt", "", Color.FromRgb(0x34, 0xC7, 0x59), null, 2.6, inGame: S.GameBattery, right: $"{percent} %");
                    break;
                case PowerEvent.Unplugged when S.ChargingBanner:
                    ShowBanner("battery", "", Colors.White, null, 2.2, inGame: S.GameBattery, right: $"{percent} %");
                    break;
                case PowerEvent.Low when S.LowBatteryBanner:
                    ShowBanner("battery", "", Orange, null, 4, inGame: S.GameBattery, right: $"{percent} %");
                    break;
                case PowerEvent.Critical when S.LowBatteryBanner:
                    ShowBanner("battery", "", Red, null, 5, inGame: S.GameBattery, right: $"{percent} %");
                    break;
            }
        }

        // ---- demonstrations for the settings window ----

        public void DemoVolume() => ShowBanner("speaker.wave", "", Colors.White, 0.6, 2);
        public void DemoCharging() => ShowBanner("bolt", "", Color.FromRgb(0x34, 0xC7, 0x59), null, 2.6, right: "76 %");
        public void DemoLowBattery() => ShowBanner("battery", "", Orange, null, 3, right: "20 %");
        public void DemoCapsLock() => ShowCapsLock(true);
        public void DemoLayout() => ShowLayout(KeyboardWatch.CurrentLayout());
        public void DemoEyeBreak() => App.Current.EyeBreak.Begin();
        public void DemoOutput() => ShowBanner("headphones", "", Color.FromRgb(0x4C, 0x8D, 0xFF), null, 2.4, right: "Наушники");

        // A device name short enough for the right side.
        private static string ShortName(string name)
        {
            var n = (name ?? "").Trim();
            int cut = n.IndexOfAny(new[] { '(', ',' });
            if (cut > 2) n = n.Substring(0, cut).Trim();
            return n.Length > 14 ? n.Substring(0, 13).TrimEnd() + "…" : n;
        }

        // ---- Caps Lock and the keyboard layout (0.4.8) ----

        public void ShowCapsLock(bool on)
        {
            if (!S.CapsLockBanner) return;
            ShowBanner("capslock", "", on ? Color.FromRgb(0x34, 0xC7, 0x59) : Color.FromRgb(0x8E, 0x8E, 0x93), null, 1.4, inGame: S.GameKeyboard,
                       right: on ? "Вкл" : "Выкл");
        }

        public void ShowLayout(string code)
        {
            if (!S.LayoutBanner || string.IsNullOrEmpty(code)) return;
            ShowBanner("keyboard", "", Colors.White, null, 1.2, inGame: S.GameKeyboard, right: code);
        }
        public void DemoOpen()
        {
            if (HasTrack) { Expand(); _hoverClose.Stop(); if (!_pointerInside) _hoverClose.Start(); }
            else ShowBanner("music.note", "", Colors.White, null, 3, right: "Нет музыки");
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
                case nameof(Settings.Theme):
                case nameof(Settings.CustomThemes):
                    ApplyIslandTheme();
                    break;
                case nameof(Settings.IslandStyle):
                    Relayout(animated: true, growing: true);
                    break;
                case nameof(Settings.LivingCover):
                    LivingCover(_mode == Mode.Expanded && !_activityOpen);
                    break;
                case nameof(Settings.SaveButton):
                case nameof(Settings.SavedTracks):
                    ShowSaved(animated: false);
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

        public void Begin()
        {
            ApplyIslandTheme();
            SetMode(RestingMode, animated: true);
        }
    }
}
