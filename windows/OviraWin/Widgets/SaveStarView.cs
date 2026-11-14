using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Ovira.Core;

namespace Ovira.Widgets
{
    // 0.8.3 — the island's «Сохранить» star for the music widget, with the
    // same motion: saving springs it out of a squeeze, turning back from −10°,
    // while a thin ring in the cover's colour spreads and fades; removing
    // collapses it inwards and back to the outline.
    public sealed class SaveStarView : Grid
    {
        private readonly IconView _star;
        private readonly Ellipse _ring = new() { Width = 27, Height = 27, StrokeThickness = 1.5, Stroke = Brushes.White, Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
        private readonly ScaleTransform _ringScale = new(0.55, 0.55);
        private readonly ScaleTransform _scale = new(1, 1);
        private readonly RotateTransform _turn = new(0);
        private readonly Brush _off;

        public SaveStarView(Look look)
        {
            Width = 30; Height = 30;
            _off = look.Fg2;
            _ring.RenderTransform = _ringScale;
            _star = new IconView { Icon = "star.outline", Width = 19, Height = 19, Fill = _off, RenderTransformOrigin = new Point(0.5, 0.5) };
            var group = new TransformGroup();
            group.Children.Add(_scale);
            group.Children.Add(_turn);
            _star.RenderTransform = group;
            Children.Add(_ring);
            Children.Add(_star);
        }

        private static Color Readable(Color c)
        {
            double l = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
            return l >= 110 ? c : Themes.MixWhite(c, Math.Min(0.6, (110 - l) / 160 + 0.15));
        }

        public void Show(bool saved, bool animated, bool justSaved, Color cover)
        {
            var tint = Readable(cover);
            _star.Icon = saved ? "star.fill" : "star.outline";
            _star.Fill = saved ? new SolidColorBrush(tint) : _off;
            if (!animated) return;
            var press = new BackEase { Amplitude = 0.55, EasingMode = EasingMode.EaseOut };
            if (justSaved)
            {
                var grow = new DoubleAnimationUsingKeyFrames();
                grow.KeyFrames.Add(new DiscreteDoubleKeyFrame(0.68, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                grow.KeyFrames.Add(new EasingDoubleKeyFrame(1.32, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.16)), new CubicEase { EasingMode = EasingMode.EaseOut }));
                grow.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.5)), press));
                _scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
                _scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
                _turn.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-10, 0, TimeSpan.FromSeconds(0.4)) { EasingFunction = press });
                _ring.Stroke = new SolidColorBrush(Color.FromArgb(0xCC, tint.R, tint.G, tint.B));
                var ring = new DoubleAnimation(0.55, 1.65, TimeSpan.FromSeconds(0.32)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                _ringScale.BeginAnimation(ScaleTransform.ScaleXProperty, ring);
                _ringScale.BeginAnimation(ScaleTransform.ScaleYProperty, ring);
                _ring.BeginAnimation(OpacityProperty, new DoubleAnimation(0.95, 0, TimeSpan.FromSeconds(0.32)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            }
            else
            {
                var shrink = new DoubleAnimationUsingKeyFrames();
                shrink.KeyFrames.Add(new DiscreteDoubleKeyFrame(1.16, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                shrink.KeyFrames.Add(new EasingDoubleKeyFrame(0.6, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.13)), new CubicEase { EasingMode = EasingMode.EaseIn }));
                shrink.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.5)), press));
                _scale.BeginAnimation(ScaleTransform.ScaleXProperty, shrink);
                _scale.BeginAnimation(ScaleTransform.ScaleYProperty, shrink);
                _turn.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(10, 0, TimeSpan.FromSeconds(0.4)) { EasingFunction = press });
                _ring.BeginAnimation(OpacityProperty, null);
                _ring.Opacity = 0;
            }
        }
    }
}
