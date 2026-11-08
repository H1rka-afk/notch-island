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
        public bool Playing { get; set; }
        public bool Active { get; set; } = true;

        private readonly WaveformPhysics _physics = new WaveformPhysics();
        private Color _tint = Color.FromRgb(0xFF, 0x5A, 0x7A);
        private BitmapSource? _artwork;
        private Brush? _brush;
        private string _brushKey = "";

        public SpectrumBars()
        {
            Loaded += (_, _) => SpectrumClock.Register(this);
            Unloaded += (_, _) => SpectrumClock.Unregister(this);
        }

        public void SetCover(BitmapSource? artwork, Color tint)
        {
            _artwork = artwork;
            _tint = tint;
            _brushKey = "";
            InvalidateVisual();
        }

        private double TotalWidth => WaveformPhysics.BarCount * BarWidth + (WaveformPhysics.BarCount - 1) * BarSpacing;

        protected override Size MeasureOverride(Size availableSize) => new Size(TotalWidth, BarMaxHeight);

        // Called by the clock at the chosen frame rate. Returns true when it drew.
        internal bool Tick(double time, double[] levels, bool live)
        {
            if (!Active || !IsVisible) return false;
            bool wasSettled = _physics.Settled;
            _physics.Step(time, levels, Playing, live);
            if (wasSettled && _physics.Settled && !Playing) return false;
            InvalidateVisual();
            return true;
        }

        private Brush CurrentBrush()
        {
            var s = Settings.Current;
            var key = s.SpectrumStyle + "|" + s.SpectrumBlur.ToString("0.00") + "|" + (_artwork?.GetHashCode() ?? 0) + "|" + _tint;
            if (_brush != null && key == _brushKey) return _brush;
            _brushKey = key;
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
            var brush = CurrentBrush();
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

        public static void Register(SpectrumBars bars)
        {
            if (!Bars.Contains(bars)) Bars.Add(bars);
            if (!_hooked) { CompositionTarget.Rendering += OnRendering; _hooked = true; }
        }

        public static void Unregister(SpectrumBars bars)
        {
            Bars.Remove(bars);
            if (Bars.Count == 0 && _hooked) { CompositionTarget.Rendering -= OnRendering; _hooked = false; }
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
            foreach (var bars in Bars.ToArray()) bars.Tick(now, levels, live);
        }
    }
}
