using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Ovira.Core;

namespace Ovira.Island
{
    // ⏩ / ⏪ drawn from three triangles so they can step, like the iPhone
    // player (ported from PlayerButtons.swift): the front triangle shrinks
    // away, the back one slides into its place and a new one grows behind it.
    public sealed class SkipGlyph : FrameworkElement
    {
        public bool Forward { get; set; } = true;
        public double GlyphSize { get; set; } = 21;

        private double _step;            // 0 at rest → 1 stepped
        private readonly Stopwatch _watch = new Stopwatch();
        private bool _running;

        public void Pulse()
        {
            _watch.Restart();
            if (!_running) { CompositionTarget.Rendering += OnFrame; _running = true; }
        }

        private void OnFrame(object? sender, EventArgs e)
        {
            double t = _watch.Elapsed.TotalSeconds / 0.3;
            if (t >= 1)
            {
                _step = 0;                       // same picture as at rest
                CompositionTarget.Rendering -= OnFrame;
                _running = false;
            }
            else
            {
                _step = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;    // ease in-out
            }
            InvalidateVisual();
        }

        protected override Size MeasureOverride(Size availableSize) =>
            new Size(GlyphSize * 1.2, GlyphSize * 0.7);

        protected override void OnRender(DrawingContext dc)
        {
            double w = GlyphSize * 0.6, h = GlyphSize * 0.7;
            double ox = (ActualWidth - w * 2) / 2, oy = (ActualHeight - h) / 2;
            if (!Forward)
            {
                dc.PushTransform(new ScaleTransform(-1, 1, ActualWidth / 2, 0));
            }
            var fill = Brushes.White;
            // the new one, growing in at the back (anchored on its right edge)
            Triangle(dc, fill, ox, oy, w, h, _step, anchorRight: true, opacity: _step);
            // the back one slides into the front place
            Triangle(dc, fill, ox + _step * w, oy, w, h, 1, anchorRight: false, opacity: 1);
            // the front one shrinks away
            Triangle(dc, fill, ox + w + _step * w * 0.25, oy, w, h, 1 - _step * 0.9, anchorRight: false, opacity: 1 - _step);
            if (!Forward) dc.Pop();
        }

        private static void Triangle(DrawingContext dc, Brush fill, double x, double y, double w, double h,
                                     double scale, bool anchorRight, double opacity)
        {
            if (scale <= 0.01 || opacity <= 0.01) return;
            double sw = w * scale, sh = h * scale;
            double left = anchorRight ? x + w - sw : x;
            double top = y + (h - sh) / 2;
            double r = Math.Min(sw, sh) * 0.16;
            var g = new StreamGeometry();
            using (var ctx = g.Open())
            {
                ctx.BeginFigure(new Point(left + r * 0.6, top + r * 0.7), true, true);
                ctx.LineTo(new Point(left + sw - r * 0.6, top + sh / 2), true, true);
                ctx.LineTo(new Point(left + r * 0.6, top + sh - r * 0.7), true, true);
            }
            g.Freeze();
            dc.PushOpacity(opacity);
            dc.DrawGeometry(fill, new Pen(fill, r * 1.2) { LineJoin = PenLineJoin.Round }, g);
            dc.Pop();
        }
    }

    // ⏯ — pause shrinks away while play grows in (and back), with a spring.
    public sealed class PlayPauseGlyph : System.Windows.Controls.Grid
    {
        private readonly IconView _pause = new IconView { Icon = "pause" };
        private readonly IconView _play = new IconView { Icon = "play" };
        private bool? _playing;

        public PlayPauseGlyph()
        {
            foreach (var v in new[] { _pause, _play })
            {
                v.RenderTransformOrigin = new Point(0.5, 0.5);
                v.RenderTransform = new ScaleTransform(1, 1);
                Children.Add(v);
            }
            SizeChanged += (_, _) =>
            {
                var s = Math.Min(ActualWidth, ActualHeight);
                _pause.Width = _pause.Height = _play.Width = _play.Height = s;
            };
            Set(false, animated: false);
        }

        public void Set(bool playing, bool animated = true)
        {
            if (_playing == playing) return;
            _playing = playing;
            Show(_pause, playing, animated);
            Show(_play, !playing, animated);
        }

        private static void Show(IconView v, bool on, bool animated)
        {
            var scale = (ScaleTransform)v.RenderTransform;
            if (!animated)
            {
                v.BeginAnimation(OpacityProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                v.Opacity = on ? 1 : 0;
                scale.ScaleX = scale.ScaleY = on ? 1 : 0.3;
                return;
            }
            var d = TimeSpan.FromSeconds(0.38);
            var ease = new BackEase { Amplitude = on ? 0.35 : 0, EasingMode = EasingMode.EaseOut };
            v.BeginAnimation(OpacityProperty, new DoubleAnimation(on ? 1 : 0, TimeSpan.FromSeconds(on ? 0.22 : 0.14)));
            var a = new DoubleAnimation(on ? 1 : 0.3, d) { EasingFunction = ease };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
    }
}
