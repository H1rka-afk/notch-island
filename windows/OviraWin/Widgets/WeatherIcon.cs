using System;
using System.Windows;
using System.Windows.Media;

namespace Ovira.Widgets
{
    // 0.8.1 — weather icons drawn as shapes, one colour, like the iPhone's
    // widget: sun, moon, clouds (a sun or moon peeking out from behind with a
    // thin gap), rain, drizzle, snow, sleet, lightning and fog.
    public sealed class WeatherIcon : FrameworkElement
    {
        public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(string), typeof(WeatherIcon),
            new FrameworkPropertyMetadata("sun", FrameworkPropertyMetadataOptions.AffectsRender));
        public static readonly DependencyProperty FillProperty = DependencyProperty.Register(nameof(Fill), typeof(Brush), typeof(WeatherIcon),
            new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

        public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }
        public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }

        protected override void OnRender(DrawingContext dc)
        {
            double s = Math.Min(ActualWidth, ActualHeight);
            if (s <= 0) return;
            dc.PushTransform(new TranslateTransform((ActualWidth - s) / 2, (ActualHeight - s) / 2));
            dc.PushTransform(new ScaleTransform(s / 24, s / 24));
            var kind = Kind ?? "sun";
            if (!Cache.TryGetValue(kind, out var geo))
            {
                geo = Build(kind).GetFlattenedPathGeometry(0.05, ToleranceType.Absolute);
                geo.Freeze();
                Cache[kind] = geo;
            }
            dc.DrawGeometry(Fill, null, geo);
            dc.Pop(); dc.Pop();
        }

        private static readonly System.Collections.Generic.Dictionary<string, Geometry> Cache = new();

        // ---- shapes, on a 24 × 24 grid ----

        private static Geometry Circle(double x, double y, double r) => new EllipseGeometry(new Point(x, y), r, r);

        private static Geometry Union(params Geometry[] parts)
        {
            Geometry g = parts[0];
            for (int i = 1; i < parts.Length; i++) g = new CombinedGeometry(GeometryCombineMode.Union, g, parts[i]);
            return g;
        }

        private static Geometry Line(double x1, double y1, double x2, double y2, double width) =>
            new LineGeometry(new Point(x1, y1), new Point(x2, y2)).GetWidenedPathGeometry(new Pen(Brushes.Black, width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round });

        private static Geometry Sun(double cx, double cy, double k)
        {
            var parts = new System.Collections.Generic.List<Geometry> { Circle(cx, cy, 4.3 * k) };
            for (int i = 0; i < 8; i++)
            {
                double a = i * Math.PI / 4;
                parts.Add(Line(cx + Math.Cos(a) * 6.6 * k, cy + Math.Sin(a) * 6.6 * k, cx + Math.Cos(a) * 9 * k, cy + Math.Sin(a) * 9 * k, 1.8 * k));
            }
            return Union(parts.ToArray());
        }

        private static Geometry Moon(double cx, double cy, double k) =>
            new CombinedGeometry(GeometryCombineMode.Exclude, Circle(cx, cy, 7 * k), Circle(cx + 4.2 * k, cy - 3.4 * k, 6 * k));

        // A cloud whose flat bottom sits at «bottom», «w» wide, centred on cx.
        private static Geometry Cloud(double cx, double bottom, double k)
        {
            double w = 17 * k, h = 6.4 * k;
            var body = new RectangleGeometry(new Rect(cx - w / 2, bottom - h, w, h), h / 2, h / 2);
            return Union(body,
                         Circle(cx - w * 0.17, bottom - h * 0.95, 4.2 * k),
                         Circle(cx + w * 0.12, bottom - h * 1.15, 5.4 * k));
        }

        // Something behind the cloud, cut away with a thin gap round it.
        private static Geometry Behind(Geometry back, Geometry cloud)
        {
            var gap = Union(cloud, cloud.GetWidenedPathGeometry(new Pen(Brushes.Black, 2.6)));
            return new CombinedGeometry(GeometryCombineMode.Exclude, back, gap);
        }

        private static Geometry Build(string kind)
        {
            switch (kind)
            {
                case "sun": return Sun(12, 12, 1.15);
                case "moon": return Moon(11.5, 12.5, 1.25);
                case "fog":
                {
                    var c = Cloud(12, 14.5, 1);
                    return Union(c, Line(5, 18, 19, 18, 1.8), Line(7, 21.2, 17, 21.2, 1.8));
                }
                case "cloud": return Cloud(12, 18.5, 1.15);
            }
            bool falls = kind.EndsWith(".rain") || kind.EndsWith(".drizzle") || kind.EndsWith(".heavyrain") || kind.EndsWith(".snow") || kind.EndsWith(".sleet") || kind.EndsWith(".bolt");
            bool sun = kind.Contains(".sun"), moon = kind.Contains(".moon");
            double bottom = falls ? 15 : 19.5;
            double cx = sun || moon ? 10.5 : 12;
            var cloud = Cloud(cx, bottom, sun || moon ? 0.95 : 1.05);
            var parts = new System.Collections.Generic.List<Geometry> { cloud };
            if (sun) parts.Add(Behind(Sun(16.8, falls ? 6.5 : 8.5, 0.62), cloud));
            if (moon) parts.Add(Behind(Moon(17.6, falls ? 6.0 : 8.0, 0.85), cloud));
            if (kind.EndsWith(".rain") || kind.EndsWith(".heavyrain"))
            {
                bool heavy = kind.EndsWith(".heavyrain");
                double len = heavy ? 4.4 : 2.6;
                foreach (var x in heavy ? new[] { 6.5, 10.5, 14.5, 18.5 } : new[] { 7.5, 11.5, 15.5 })
                    parts.Add(Line(x, 17.6, x - 1.2, 17.6 + len, 1.6));
                if (!heavy)
                    foreach (var x in new[] { 9.0, 13.0 })
                        parts.Add(Line(x, 21.2, x - 0.6, 22.6, 1.6));
            }
            else if (kind.EndsWith(".drizzle"))
            {
                foreach (var (x, y) in new[] { (7.5, 18.0), (11.5, 18.0), (15.5, 18.0), (9.5, 21.4), (13.5, 21.4) })
                    parts.Add(Line(x, y, x - 0.7, y + 1.4, 1.6));
            }
            else if (kind.EndsWith(".snow"))
            {
                foreach (var (x, y) in new[] { (7.5, 18.5), (12.0, 18.5), (16.5, 18.5), (9.7, 21.8), (14.3, 21.8) })
                    parts.Add(Circle(x, y, 1.15));
            }
            else if (kind.EndsWith(".sleet"))
            {
                parts.Add(Line(7.5, 17.6, 6.5, 20.2, 1.6));
                parts.Add(Circle(12, 19.2, 1.15));
                parts.Add(Line(16.5, 17.6, 15.5, 20.2, 1.6));
                parts.Add(Circle(9.8, 22.2, 1.1));
                parts.Add(Circle(14.2, 22.2, 1.1));
            }
            else if (kind.EndsWith(".bolt"))
            {
                var bolt = Geometry.Parse("M12.8,15.4 L8.8,20.6 L11.6,20.6 L10.4,24 L15,18.4 L12.2,18.4 L13.6,15.4 Z");
                parts.Add(bolt);
            }
            return Union(parts.ToArray());
        }
    }
}
