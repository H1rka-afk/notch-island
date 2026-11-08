using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace Ovira.Core
{
    // 0.3.0 — filled icons drawn like Apple's SF Symbols (rounded, solid),
    // instead of the thin Windows line icons. Every icon is designed on a
    // 24×24 grid and drawn by IconView at any size, with rounded joins.
    public static class Icons
    {
        private static readonly Dictionary<string, Geometry> Cache = new();

        public static Geometry Get(string name)
        {
            if (Cache.TryGetValue(name, out var g)) return g;
            g = Build(name);
            g.Freeze();
            Cache[name] = g;
            return g;
        }

        private static Geometry Build(string name) => name switch
        {
            "play" => Parse("M7,4.6 C7,3.9 7.8,3.5 8.4,3.9 L19.6,11.1 C20.1,11.5 20.1,12.5 19.6,12.9 L8.4,20.1 C7.8,20.5 7,20.1 7,19.4 Z"),
            "pause" => Parse("M6.2,4 H9.4 C10,4 10.4,4.4 10.4,5 V19 C10.4,19.6 10,20 9.4,20 H6.2 C5.6,20 5.2,19.6 5.2,19 V5 C5.2,4.4 5.6,4 6.2,4 Z " +
                             "M14.6,4 H17.8 C18.4,4 18.8,4.4 18.8,5 V19 C18.8,19.6 18.4,20 17.8,20 H14.6 C14,20 13.6,19.6 13.6,19 V5 C13.6,4.4 14,4 14.6,4 Z"),
            "triangle" => Parse("M1,1.6 C1,0.9 1.8,0.5 2.4,0.9 L11.4,6.5 C11.9,6.9 11.9,7.7 11.4,8.1 L2.4,13.7 C1.8,14.1 1,13.7 1,13 Z"),
            "speaker" => Parse("M3.5,9 H7 L11.6,5 C12.2,4.5 13,4.9 13,5.7 V18.3 C13,19.1 12.2,19.5 11.6,19 L7,15 H3.5 C2.9,15 2.5,14.6 2.5,14 V10 C2.5,9.4 2.9,9 3.5,9 Z"),
            "speaker.wave" => Group(Get("speaker"),
                Parse("M15.4,8.6 C16.4,9.5 16.9,10.7 16.9,12 C16.9,13.3 16.4,14.5 15.4,15.4 L14.5,14.4 C15.2,13.8 15.6,12.9 15.6,12 C15.6,11.1 15.2,10.2 14.5,9.6 Z " +
                      "M17.8,6.2 C19.4,7.6 20.4,9.7 20.4,12 C20.4,14.3 19.4,16.4 17.8,17.8 L16.9,16.8 C18.2,15.6 19.1,13.9 19.1,12 C19.1,10.1 18.2,8.4 16.9,7.2 Z")),
            "speaker.slash" => Group(Get("speaker"),
                Parse("M15.2,9.2 L16.1,8.3 L18.3,10.5 L20.5,8.3 L21.4,9.2 L19.2,11.4 L21.4,13.6 L20.5,14.5 L18.3,12.3 L16.1,14.5 L15.2,13.6 L17.4,11.4 Z")),
            "headphones" => Parse("M12,3 C7,3 3.5,6.6 3.5,11.4 V17 C3.5,18.7 4.8,20 6.5,20 H7.5 C8.3,20 9,19.3 9,18.5 V14 C9,13.2 8.3,12.5 7.5,12.5 H5.4 V11.4 C5.4,7.7 8.2,5 12,5 C15.8,5 18.6,7.7 18.6,11.4 V12.5 H16.5 C15.7,12.5 15,13.2 15,14 V18.5 C15,19.3 15.7,20 16.5,20 H17.5 C19.2,20 20.5,18.7 20.5,17 V11.4 C20.5,6.6 17,3 12,3 Z"),
            "display" => Parse("M4,4 H20 C21.1,4 22,4.9 22,6 V15 C22,16.1 21.1,17 20,17 H13.2 V19 H16.5 V20.5 H7.5 V19 H10.8 V17 H4 C2.9,17 2,16.1 2,15 V6 C2,4.9 2.9,4 4,4 Z"),
            "laptop" => Parse("M5,5 H19 C19.8,5 20.4,5.6 20.4,6.4 V16 H3.6 V6.4 C3.6,5.6 4.2,5 5,5 Z M1.5,17.2 H22.5 C22.5,18.3 21.6,19 20.6,19 H3.4 C2.4,19 1.5,18.3 1.5,17.2 Z"),
            "bolt" => Parse("M13.4,2.3 C13.6,1.9 14.2,2.1 14.1,2.5 L12.9,10 H18.3 C18.8,10 19.1,10.6 18.8,11 L10.6,21.7 C10.4,22.1 9.8,21.9 9.9,21.5 L11.1,14 H5.7 C5.2,14 4.9,13.4 5.2,13 Z"),
            "battery" => Parse("M3.5,7 H18 C19.1,7 20,7.9 20,9 V15 C20,16.1 19.1,17 18,17 H3.5 C2.4,17 1.5,16.1 1.5,15 V9 C1.5,7.9 2.4,7 3.5,7 Z M3.5,8.3 C3.1,8.3 2.8,8.6 2.8,9 V15 C2.8,15.4 3.1,15.7 3.5,15.7 H18 C18.4,15.7 18.7,15.4 18.7,15 V9 C18.7,8.6 18.4,8.3 18,8.3 Z M21,10.3 C21.8,10.4 22.5,11.1 22.5,12 C22.5,12.9 21.8,13.6 21,13.7 Z M4.2,9.7 H9 V14.3 H4.2 Z"),
            "music.note" => Parse("M19,3.2 V15.8 C19,17.6 17.5,19 15.6,19 C13.8,19 12.4,17.8 12.4,16.3 C12.4,14.8 13.9,13.5 15.8,13.5 C16.3,13.5 16.8,13.6 17.2,13.8 V7.2 L9.4,8.9 V17.8 C9.4,19.6 7.9,21 6,21 C4.2,21 2.8,19.8 2.8,18.3 C2.8,16.8 4.3,15.5 6.2,15.5 C6.7,15.5 7.2,15.6 7.6,15.8 V6.2 C7.6,5.6 8,5.1 8.6,5 L17.8,3 C18.4,2.9 19,3.3 19,3.2 Z"),
            "bell" => Parse("M12,2.5 C12.8,2.5 13.4,3.1 13.4,3.9 V4.4 C16.2,5 18.2,7.5 18.2,10.4 V14.6 L19.9,16.6 C20.4,17.2 20,18 19.3,18 H4.7 C4,18 3.6,17.2 4.1,16.6 L5.8,14.6 V10.4 C5.8,7.5 7.8,5 10.6,4.4 V3.9 C10.6,3.1 11.2,2.5 12,2.5 Z M9.5,19.2 H14.5 C14.5,20.6 13.4,21.6 12,21.6 C10.6,21.6 9.5,20.6 9.5,19.2 Z"),
            "gear" => Gear(),
            "star" => Parse("M12,2.8 L14.6,8.4 L20.7,9.1 L16.2,13.3 L17.4,19.4 L12,16.4 L6.6,19.4 L7.8,13.3 L3.3,9.1 L9.4,8.4 Z"),
            "waveform" => Parse("M3,10 H5 V14 H3 Z M7,7 H9 V17 H7 Z M11,4 H13 V20 H11 Z M15,8 H17 V16 H15 Z M19,10.5 H21 V13.5 H19 Z"),
            "sparkles" => Parse("M10,2.5 L11.6,7.9 L17,9.5 L11.6,11.1 L10,16.5 L8.4,11.1 L3,9.5 L8.4,7.9 Z M18,13 L18.9,15.6 L21.5,16.5 L18.9,17.4 L18,20 L17.1,17.4 L14.5,16.5 L17.1,15.6 Z"),
            "info" => Parse("M12,2.5 C17.2,2.5 21.5,6.8 21.5,12 C21.5,17.2 17.2,21.5 12,21.5 C6.8,21.5 2.5,17.2 2.5,12 C2.5,6.8 6.8,2.5 12,2.5 Z M10.9,10.5 V17 H13.1 V10.5 Z M12,6.4 C11.3,6.4 10.7,7 10.7,7.7 C10.7,8.4 11.3,9 12,9 C12.7,9 13.3,8.4 13.3,7.7 C13.3,7 12.7,6.4 12,6.4 Z"),
            "windows" => Parse("M3,5.5 L10.5,4.5 V11.3 H3 Z M11.6,4.3 L21,3 V11.3 H11.6 Z M3,12.6 H10.5 V19.4 L3,18.4 Z M11.6,12.6 H21 V21 L11.6,19.7 Z"),
            "magnifier" => Parse("M10.5,3.5 C14.4,3.5 17.5,6.6 17.5,10.5 C17.5,12.1 17,13.6 16.1,14.7 L20.7,19.3 L19.3,20.7 L14.7,16.1 C13.6,17 12.1,17.5 10.5,17.5 C6.6,17.5 3.5,14.4 3.5,10.5 C3.5,6.6 6.6,3.5 10.5,3.5 Z M10.5,5.5 C7.7,5.5 5.5,7.7 5.5,10.5 C5.5,13.3 7.7,15.5 10.5,15.5 C13.3,15.5 15.5,13.3 15.5,10.5 C15.5,7.7 13.3,5.5 10.5,5.5 Z"),
            "chevron.left" => Parse("M14.8,4.6 L16.2,6 L10.2,12 L16.2,18 L14.8,19.4 L7.4,12 Z"),
            "xmark" => Parse("M6.3,4.9 L12,10.6 L17.7,4.9 L19.1,6.3 L13.4,12 L19.1,17.7 L17.7,19.1 L12,13.4 L6.3,19.1 L4.9,17.7 L10.6,12 L4.9,6.3 Z"),
            "minus" => Parse("M5,11 H19 V13 H5 Z"),
            "checkmark" => Parse("M9.2,15.6 L19.1,5.7 L20.5,7.1 L9.2,18.4 L3.5,12.7 L4.9,11.3 Z"),
            _ => Parse("M12,6 C15.3,6 18,8.7 18,12 C18,15.3 15.3,18 12,18 C8.7,18 6,15.3 6,12 C6,8.7 8.7,6 12,6 Z")
        };

        private static Geometry Parse(string data) => Geometry.Parse("F1 " + data);

        private static Geometry Group(params Geometry[] parts)
        {
            var g = new GeometryGroup { FillRule = FillRule.Nonzero };
            foreach (var p in parts) g.Children.Add(p);
            return g;
        }

        // gearshape.fill: eight rounded teeth and a hole.
        private static Geometry Gear()
        {
            var g = new StreamGeometry { FillRule = FillRule.EvenOdd };
            using (var ctx = g.Open())
            {
                const int teeth = 8;
                double cx = 12, cy = 12, rOuter = 10, rInner = 7.6;
                for (int i = 0; i < teeth * 4; i++)
                {
                    double a = (i / (double)(teeth * 4)) * Math.PI * 2 - Math.PI / 2;
                    bool outer = (i % 4) == 1 || (i % 4) == 2;
                    double r = outer ? rOuter : rInner;
                    var p = new Point(cx + r * Math.Cos(a), cy + r * Math.Sin(a));
                    if (i == 0) ctx.BeginFigure(p, true, true);
                    else ctx.LineTo(p, true, true);
                }
                // the hole
                ctx.BeginFigure(new Point(cx + 3.2, cy), true, true);
                ctx.ArcTo(new Point(cx - 3.2, cy), new Size(3.2, 3.2), 0, false, SweepDirection.Clockwise, true, true);
                ctx.ArcTo(new Point(cx + 3.2, cy), new Size(3.2, 3.2), 0, false, SweepDirection.Clockwise, true, true);
            }
            return g;
        }
    }

    // Draws one icon from Icons at its size, filled, with softly rounded corners.
    public sealed class IconView : FrameworkElement
    {
        public static readonly DependencyProperty IconProperty = DependencyProperty.Register(
            nameof(Icon), typeof(string), typeof(IconView),
            new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
            nameof(Fill), typeof(Brush), typeof(IconView),
            new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

        public string Icon { get => (string)GetValue(IconProperty); set => SetValue(IconProperty, value); }
        public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }

        protected override Size MeasureOverride(Size availableSize) =>
            new Size(double.IsNaN(Width) ? 16 : Width, double.IsNaN(Height) ? 16 : Height);

        protected override void OnRender(DrawingContext dc)
        {
            if (string.IsNullOrEmpty(Icon)) return;
            var geometry = Icons.Get(Icon);
            double size = Math.Min(ActualWidth, ActualHeight);
            if (size <= 0) return;
            double k = size / 24.0;
            dc.PushTransform(new TranslateTransform((ActualWidth - size) / 2, (ActualHeight - size) / 2));
            dc.PushTransform(new ScaleTransform(k, k));
            var pen = new Pen(Fill, 0.9) { LineJoin = PenLineJoin.Round };
            dc.DrawGeometry(Fill, pen, geometry);
            dc.Pop();
            dc.Pop();
        }
    }
}
