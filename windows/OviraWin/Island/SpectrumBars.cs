using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.Island
{
    // Six bars like the Mac spectrogram: real band levels from SpectrumService,
    // the same physics, drawn in one pass. Look: the cover inside the bars,
    // the blurred cover, or the cover's colour (Settings → Медиаплеер).
    public sealed class SpectrumBars : FrameworkElement
    {
        public double BarWidth { get; set; } = 2.2;
        public double BarSpacing { get; set; } = 1.7;
        public double BarMaxHeight { get; set; } = 16;
        private bool _playing, _active = true;
        public bool Playing { get => _playing; set { if (_playing != value) { _playing = value; SpectrumClock.Wake(); } } }
        public bool Active { get => _active; set { if (_active != value) { _active = value; SpectrumClock.Wake(); } } }

        private readonly WaveformPhysics _physics = new WaveformPhysics();
        private Color _tint = Color.FromRgb(0xFF, 0x5A, 0x7A);
        private BitmapSource? _artwork;
        private Brush? _brush;
        // What the current brush was made from — compared field by field each
        // frame instead of building a text key (no garbage at 60 fps).
        private string? _brushStyle;
        private double _brushBlur;
        private BitmapSource? _brushArt;
        private Color _brushTint;

        public SpectrumBars()
        {
            Loaded += (_, _) => SpectrumClock.Register(this);
            Unloaded += (_, _) => SpectrumClock.Unregister(this);
            IsVisibleChanged += (_, _) => SpectrumClock.Wake();
        }

        public void SetCover(BitmapSource? artwork, Color tint)
        {
            // 0.4.12: the same cover again (a player reporting its position)
            // must not rebuild the brush — the blurred one is costly.
            if (ReferenceEquals(artwork, _artwork) && tint == _tint && _brush != null) return;
            _artwork = artwork;
            _tint = tint;
            _brushStyle = null;
            try { CurrentBrush(); } catch { _brush = null; }
            InvalidateVisual();
            SpectrumClock.Wake();
        }

        private double TotalWidth => WaveformPhysics.BarCount * BarWidth + (WaveformPhysics.BarCount - 1) * BarSpacing;

        protected override Size MeasureOverride(Size availableSize) => new Size(TotalWidth, BarMaxHeight);

        // Called by the clock at the chosen frame rate. Returns true when it drew.
        internal bool Tick(double time, double[] levels, bool live)
        {
            if (!Active || !IsVisible) return false;
            bool wasSettled = _physics.Settled;
            _physics.Step(time, levels, Playing, live);
            if (wasSettled && _physics.Settled && !Playing && _brush != null) return false;
            try { CurrentBrush(); } catch { _brush = null; }   // outside OnRender: may render the blurred cover
            InvalidateVisual();
            return true;
        }

        private Brush CurrentBrush()
        {
            var s = Settings.Current;
            if (_brush != null && _brushStyle == s.SpectrumStyle && Math.Abs(_brushBlur - s.SpectrumBlur) < 0.005 &&
                ReferenceEquals(_brushArt, _artwork) && _brushTint == _tint)
                return _brush;
            _brushStyle = s.SpectrumStyle;
            _brushBlur = s.SpectrumBlur;
            _brushArt = _artwork;
            _brushTint = _tint;
            Brush brush;
            if (_artwork != null && s.SpectrumStyle == "artwork")
                brush = CoverBrush(_artwork);
            else if (_artwork != null && s.SpectrumStyle == "blurred")
                brush = CoverBrush(Blurred(_artwork, s.SpectrumBlur));
            else
                brush = new SolidColorBrush(Color.FromArgb(0xE6, _tint.R, _tint.G, _tint.B));
            brush.Freeze();
            _brush = brush;
            return brush;
        }

        private ImageBrush CoverBrush(BitmapSource image) => new ImageBrush(image)
        {
            Stretch = Stretch.UniformToFill,
            ViewportUnits = BrushMappingMode.Absolute,
            Viewport = new Rect(0, 0, TotalWidth, BarMaxHeight)
        };

        private static readonly Dictionary<string, BitmapSource> BlurCache = new();

        // The cover softened like on iPhone, rendered once per cover and amount.
        private static BitmapSource Blurred(BitmapSource image, double amount)
        {
            var key = image.GetHashCode() + "|" + amount.ToString("0.00");
            if (BlurCache.TryGetValue(key, out var cached)) return cached;
            if (BlurCache.Count > 12) BlurCache.Clear();
            const int size = 96;
            var visual = new Image
            {
                Source = image,
                Stretch = Stretch.UniformToFill,
                Width = size,
                Height = size,
                Effect = new BlurEffect { Radius = 2 + amount * 26, KernelType = KernelType.Gaussian }
            };
            // Draw a bit larger so the soft edges stay outside.
            var host = new Grid { Width = size, Height = size, ClipToBounds = true };
            visual.Margin = new Thickness(-12);
            visual.Width = size + 24;
            visual.Height = size + 24;
            host.Children.Add(visual);
            host.Measure(new Size(size, size));
            host.Arrange(new Rect(0, 0, size, size));
            var target = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
            target.Render(host);
            target.Freeze();
            BlurCache[key] = target;
            return target;
        }

        protected override void OnRender(DrawingContext dc)
        {
            var brush = _brush ?? new SolidColorBrush(Color.FromArgb(0xE6, _tint.R, _tint.G, _tint.B));
            double w = BarWidth, maxH = BarMaxHeight;
            for (int i = 0; i < WaveformPhysics.BarCount; i++)
            {
                double value = Math.Max(0, _physics.Heights[i]);
                double h = w + value * (maxH - w);           // a dot when silent, as on the Mac
                double x = i * (w + BarSpacing);
                dc.DrawRoundedRectangle(brush, null, new Rect(x, (maxH - h) / 2, w, h), w / 2, w / 2);
            }
        }
    }

    // One clock for every set of bars, at the frame rate chosen in Settings.
    public static class SpectrumClock
    {
        private static readonly List<SpectrumBars> Bars = new();
        private static readonly Stopwatch Watch = Stopwatch.StartNew();
        private static double _lastDraw;
        private static bool _hooked;
        public static SpectrumService? Source;

        private static double _lastBusy;

        public static void Register(SpectrumBars bars)
        {
            if (!Bars.Contains(bars)) Bars.Add(bars);
            Wake();
        }

        public static void Unregister(SpectrumBars bars)
        {
            Bars.Remove(bars);
            if (Bars.Count == 0) Sleep();
        }

        // 0.4.2: the clock runs only while some bars move. A subscription to
        // CompositionTarget.Rendering alone makes WPF redraw at full screen
        // rate, so with nothing playing it is dropped completely.
        public static void Wake()
        {
            _lastBusy = Watch.Elapsed.TotalSeconds;
            if (!_hooked && Bars.Count > 0) { CompositionTarget.Rendering += OnRendering; _hooked = true; }
        }

        private static void Sleep()
        {
            if (_hooked) { CompositionTarget.Rendering -= OnRendering; _hooked = false; }
        }

        private static void OnRendering(object? sender, EventArgs e)
        {
            var now = Watch.Elapsed.TotalSeconds;
            var fps = Math.Clamp(Settings.Current.SpectrumFps, 15, 240);
            // A small allowance so 60 on a 60 Hz screen is really every frame.
            if (now - _lastDraw < 1.0 / fps - 0.002) return;
            _lastDraw = now;
            var source = Source;
            var levels = source?.Levels ?? new double[6];
            bool live = source != null && source.Live;
            bool busy = false;
            foreach (var bars in Bars.ToArray()) busy |= bars.Tick(now, levels, live);
            if (busy) _lastBusy = now;
            else if (now - _lastBusy > 0.6) Sleep();
        }
    }
}
