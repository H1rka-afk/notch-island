using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Ovira.SettingsUi
{
    // 0.4.2 — the living background of the Mac settings
    // (SettingsAuroraBackground): soft clouds of the two theme colours drift
    // in slow loops and flow into each other. Drawn into a tiny picture
    // (about 1/10 of the window) and stretched — it is a blur anyway, so
    // it costs almost nothing. 30 frames a second, 12 when the window is in
    // the background, none when minimised or switched off in Settings.
    public partial class SettingsWindow
    {
        private const int AuroraW = 96, AuroraH = 72;
        private WriteableBitmap? _auroraBitmap;
        private readonly uint[] _auroraPixels = new uint[AuroraW * AuroraH];
        private readonly DispatcherTimer _auroraTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(42) };
        private readonly System.Diagnostics.Stopwatch _auroraClock = System.Diagnostics.Stopwatch.StartNew();
        private double _auroraLast, _auroraT;
        private Color _auroraA = Color.FromRgb(0x5C, 0x59, 0xE6), _auroraB = Color.FromRgb(0xFF, 0x45, 0x66);
        private double[] _curA = { 0x5C, 0x59, 0xE6 }, _curB = { 0xFF, 0x45, 0x66 };
        private bool _auroraFirst = true;

        private void StartAurora()
        {
            _auroraBitmap = new WriteableBitmap(AuroraW, AuroraH, 96, 96, PixelFormats.Pbgra32, null);
            Aurora.Source = _auroraBitmap;
            _auroraTimer.Tick += (_, _) => AuroraFrame();
            Loaded += (_, _) => { TintAurora(); AuroraFrame(); UpdateAuroraClock(); };
            Activated += (_, _) => UpdateAuroraClock();
            Deactivated += (_, _) => UpdateAuroraClock();
            StateChanged += (_, _) => UpdateAuroraClock();
            IsVisibleChanged += (_, _) => UpdateAuroraClock();
            Closed += (_, _) => _auroraTimer.Stop();
        }

        private void UpdateAuroraClock()
        {
            bool run = IsVisible && WindowState != WindowState.Minimized && S.AnimatedBackground;
            // 0.4.12: 24 frames a second is plenty for slow clouds; 8 in the background.
            _auroraTimer.Interval = TimeSpan.FromMilliseconds(IsActive ? 42 : 125);
            if (run && !_auroraTimer.IsEnabled) { _auroraLast = _auroraClock.Elapsed.TotalSeconds; _auroraTimer.Start(); }
            else if (!run) { _auroraTimer.Stop(); AuroraFrame(); }
        }

        // The two colours: the theme's palette, or the section's colour and
        // the playing cover's — they glide to new values, never jump.
        private void TintAurora()
        {
            _auroraA = s_palette.Length > 0
                ? (_current == null ? s_palette[0] : _current.Accent)
                : (_current?.Accent ?? Color.FromRgb(0x5C, 0x59, 0xE6));
            _auroraB = s_palette.Length > 1 && S.Theme != "cover" ? s_palette[1] : CoverTint;
            Aurora.Opacity = (_theme?.IsDark ?? true) ? 0.72 : 0.5;
            if (_auroraFirst)
            {
                _auroraFirst = false;
                _curA = new double[] { _auroraA.R, _auroraA.G, _auroraA.B };
                _curB = new double[] { _auroraB.R, _auroraB.G, _auroraB.B };
            }
            if (!_auroraTimer.IsEnabled) AuroraFrame();
        }

        private void AuroraFrame()
        {
            if (_auroraBitmap == null) return;
            var now = _auroraClock.Elapsed.TotalSeconds;
            var dt = Math.Clamp(now - _auroraLast, 0, 0.2);
            _auroraLast = now;
            if (_auroraTimer.IsEnabled) _auroraT += dt;
            double ease = _auroraTimer.IsEnabled ? 1 - Math.Exp(-dt / 0.45) : 1;
            Glide(_curA, _auroraA, ease);
            Glide(_curB, _auroraB, ease);

            double t = _auroraT;
            double D = Math.Max(AuroraW, AuroraH);
            double k3 = 0.5 + 0.5 * Math.Sin(t * 0.35), k4 = 0.5 + 0.5 * Math.Sin(t * 0.35 + 2.6);
            // x, y, radius (px), opacity, colour — the Mac's four blobs.
            var blobs = new (double x, double y, double r, double o, double[] c)[]
            {
                ((0.78 + 0.2 * Math.Sin(t * 0.55)) * AuroraW, (0.18 + 0.18 * Math.Cos(t * 0.47)) * AuroraH, D * 0.85 / 2, 1.0, _curA),
                ((0.22 + 0.22 * Math.Cos(t * 0.51 + 1.2)) * AuroraW, (0.82 + 0.16 * Math.Sin(t * 0.6)) * AuroraH, D * 0.75 / 2, 1.0, _curB),
                ((0.30 + 0.24 * Math.Sin(t * 0.43 + 2.0)) * AuroraW, (0.30 + 0.22 * Math.Cos(t * 0.66 + 0.5)) * AuroraH, D * 0.55 / 2, 0.8, Mix(_curA, _curB, k3)),
                ((0.85 + 0.16 * Math.Cos(t * 0.62 + 2.6)) * AuroraW, (0.78 + 0.2 * Math.Sin(t * 0.5 + 1.1)) * AuroraH, D * 0.5 / 2, 0.85, Mix(_curB, _curA, k4)),
            };
            int i = 0;
            for (int y = 0; y < AuroraH; y++)
            {
                for (int x = 0; x < AuroraW; x++, i++)
                {
                    // Premultiplied «over», blob after blob.
                    double r = 0, g = 0, b = 0, a = 0;
                    foreach (var blob in blobs)
                    {
                        double dx = (x - blob.x) / blob.r, dy = (y - blob.y) / blob.r;
                        double d2 = dx * dx + dy * dy;
                        if (d2 > 4) continue;
                        double w = Math.Exp(-d2 * 1.6) * blob.o;
                        r = blob.c[0] * w + r * (1 - w);
                        g = blob.c[1] * w + g * (1 - w);
                        b = blob.c[2] * w + b * (1 - w);
                        a = w + a * (1 - w);
                    }
                    _auroraPixels[i] = ((uint)(a * 255) << 24) | ((uint)Math.Min(255, r) << 16) | ((uint)Math.Min(255, g) << 8) | (uint)Math.Min(255, b);
                }
            }
            _auroraBitmap.WritePixels(new Int32Rect(0, 0, AuroraW, AuroraH), _auroraPixels, AuroraW * 4, 0);
        }

        private static void Glide(double[] cur, Color target, double k)
        {
            cur[0] += (target.R - cur[0]) * k;
            cur[1] += (target.G - cur[1]) * k;
            cur[2] += (target.B - cur[2]) * k;
        }

        private static double[] Mix(double[] a, double[] b, double k) =>
            new[] { a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k };
    }
}
