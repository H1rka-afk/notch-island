using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using Ovira.Core;
using Ovira.Widgets;

namespace Ovira.Taskbar
{
    // 0.7.1 — Ovira's own right-click menu instead of the grey Windows one:
    // a rounded card in the taskbar's colours with a header (the app's icon,
    // name and how many windows), items with icons, a red «close», and the
    // island's spring when it opens.
    internal sealed class OviraMenu
    {
        private readonly Popup _popup = new()
        {
            AllowsTransparency = true,
            StaysOpen = false,
            Placement = PlacementMode.Top,
            PopupAnimation = PopupAnimation.None,
        };
        private readonly StackPanel _items = new() { Margin = new Thickness(6) };
        private readonly Border _card;
        private readonly Brush _fg, _fg2, _hover, _line;
        private const double Pad = 18;            // room for the shadow
        private bool _closing;

        public OviraMenu(Look look)
        {
            bool light = look.Fg is SolidColorBrush f && f.Color.R < 0x80;
            _fg = light ? new SolidColorBrush(Color.FromRgb(0x1C, 0x1C, 0x1E)) : Brushes.White;
            _fg2 = light ? new SolidColorBrush(Color.FromArgb(0x99, 0x3C, 0x3C, 0x43)) : new SolidColorBrush(Color.FromArgb(0x99, 0xEB, 0xEB, 0xF5));
            _hover = light ? new SolidColorBrush(Color.FromArgb(0x14, 0, 0, 0)) : new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF));
            _line = light ? new SolidColorBrush(Color.FromArgb(0x14, 0, 0, 0)) : new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF));
            var back = light ? new SolidColorBrush(Color.FromArgb(0xF7, 0xF8, 0xF8, 0xFA)) : new SolidColorBrush(Color.FromArgb(0xF5, 0x1E, 0x1E, 0x22));
            var border = light ? new SolidColorBrush(Color.FromArgb(0x1A, 0, 0, 0)) : new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));

            var host = new Grid { Margin = new Thickness(Pad) };
            var shadow = new Border
            {
                CornerRadius = new CornerRadius(14),
                Background = Brushes.Black,
                Effect = new DropShadowEffect { BlurRadius = 26, ShadowDepth = 6, Direction = 270, Opacity = 0.4 },
                CacheMode = new BitmapCache(),
                Opacity = 0.6,
            };
            _card = new Border
            {
                CornerRadius = new CornerRadius(14),
                Background = back,
                BorderBrush = border,
                BorderThickness = new Thickness(1),
                MinWidth = 230,
                Child = _items,
            };
            host.Children.Add(shadow);
            host.Children.Add(_card);
            host.RenderTransformOrigin = new Point(0.5, 1);
            host.RenderTransform = new ScaleTransform(1, 1);
            TextOptions.SetTextFormattingMode(host, TextFormattingMode.Display);
            _popup.Child = host;
            _popup.Closed += (_, _) => _closing = false;
        }

        public OviraMenu Header(ImageSource? icon, string? glyph, string title, string? subtitle)
        {
            var row = new Grid { Margin = new Thickness(8, 6, 8, 8) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            FrameworkElement pic = icon != null
                ? new Image { Source = icon, Width = 32, Height = 32 }
                : new IconView { Icon = glyph ?? "gear", Width = 26, Height = 26, Fill = _fg, Margin = new Thickness(3) };
            if (pic is Image im) RenderOptions.SetBitmapScalingMode(im, BitmapScalingMode.HighQuality);
            pic.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(pic);
            var text = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = title, Foreground = _fg, FontSize = 14, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 220 });
            if (!string.IsNullOrEmpty(subtitle))
                text.Children.Add(new TextBlock { Text = subtitle, Foreground = _fg2, FontSize = 12, Margin = new Thickness(0, 1, 0, 0) });
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            _items.Children.Add(row);
            Separator();
            return this;
        }

        public OviraMenu Item(string icon, string title, Action action, bool danger = false, bool? check = null)
        {
            var red = new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A));
            var fg = danger ? red : _fg;
            var highlight = new Border { CornerRadius = new CornerRadius(8), Background = danger ? new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0x45, 0x3A)) : _hover, Opacity = 0 };
            var row = new Grid { Height = 34, Background = Brushes.Transparent, Cursor = Cursors.Hand };
            row.Children.Add(highlight);
            var line = new Grid { Margin = new Thickness(10, 0, 10, 0) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
            line.ColumnDefinitions.Add(new ColumnDefinition());
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new IconView { Icon = icon, Width = 16, Height = 16, Fill = fg, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center });
            var text = new TextBlock { Text = title, Foreground = fg, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, 1);
            line.Children.Add(text);
            if (check != null)
            {
                // a small switch, like the settings
                var track = new Border { Width = 30, Height = 18, CornerRadius = new CornerRadius(9), Background = check.Value ? new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59)) : _line, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
                track.Child = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Brushes.White, HorizontalAlignment = check.Value ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(2, 0, 2, 0) };
                Grid.SetColumn(track, 2);
                line.Children.Add(track);
            }
            row.Children.Add(line);
            row.MouseEnter += (_, _) => highlight.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.1)));
            row.MouseLeave += (_, _) => highlight.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.18)));
            row.MouseLeftButtonUp += (_, e) => { e.Handled = true; Close(action); };
            _items.Children.Add(row);
            return this;
        }

        public OviraMenu Separator()
        {
            _items.Children.Add(new Border { Height = 1, Background = _line, Margin = new Thickness(10, 4, 10, 4) });
            return this;
        }

        // Above the target, centred on it (or on «atX» inside it).
        public void Open(FrameworkElement target, double? atX = null)
        {
            var host = (FrameworkElement)_popup.Child;
            host.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double w = host.DesiredSize.Width;
            double x = atX ?? target.ActualWidth / 2;
            _popup.PlacementTarget = target;
            _popup.HorizontalOffset = x - w / 2;
            _popup.VerticalOffset = Pad - 8;
            Show(host);
        }

        private void Show(FrameworkElement host)
        {
            _popup.IsOpen = true;
            Watch();
            var scale = (ScaleTransform)host.RenderTransform;
            var spring = new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.9, 1, TimeSpan.FromSeconds(0.26)) { EasingFunction = spring });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.9, 1, TimeSpan.FromSeconds(0.26)) { EasingFunction = spring });
            host.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.14)));
        }

        // At the mouse, inside the target (widgets).
        public void OpenAt(FrameworkElement target, Point at)
        {
            var host = (FrameworkElement)_popup.Child;
            host.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            _popup.PlacementTarget = target;
            _popup.Placement = PlacementMode.Relative;
            _popup.HorizontalOffset = at.X - Pad + 2;
            _popup.VerticalOffset = at.Y - Pad + 2;
            host.RenderTransformOrigin = new Point(0, 0);
            Show(host);
        }

        // 0.7.3: Windows doesn't tell a window that never takes the focus
        // (the dock, the widgets) about clicks elsewhere, so the menu looks
        // itself: a mouse button pressed outside the card closes it. Only the
        // mouse buttons are read, never the keyboard.
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
        private struct POINT { public int X, Y; }
        private System.Windows.Threading.DispatcherTimer? _watch;
        private bool _wasDown = true;

        private void Watch()
        {
            _wasDown = true;
            _watch = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
            _watch.Tick += (_, _) =>
            {
                if (!_popup.IsOpen) { _watch?.Stop(); return; }
                bool down = (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 || (GetAsyncKeyState(0x04) & 0x8000) != 0;
                if (down && !_wasDown && !OverCard()) { _watch?.Stop(); Close(null); }
                _wasDown = down;
            };
            _watch.Start();
        }

        private bool OverCard()
        {
            if (!GetCursorPos(out var p)) return true;
            try
            {
                var topLeft = _card.PointToScreen(new Point(0, 0));
                var bottomRight = _card.PointToScreen(new Point(_card.ActualWidth, _card.ActualHeight));
                return p.X >= topLeft.X && p.X <= bottomRight.X && p.Y >= topLeft.Y && p.Y <= bottomRight.Y;
            }
            catch { return true; }
        }

        private void Close(Action? then)
        {
            if (_closing) return;
            _closing = true;
            var host = (FrameworkElement)_popup.Child;
            var fade = new DoubleAnimation(0, TimeSpan.FromSeconds(0.1));
            fade.Completed += (_, _) => { _popup.IsOpen = false; _watch?.Stop(); then?.Invoke(); };
            host.BeginAnimation(UIElement.OpacityProperty, fade);
        }
    }
}
