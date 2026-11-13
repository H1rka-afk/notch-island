using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Ovira.Core;
using Ovira.Widgets;

namespace Ovira.Taskbar
{
    // The live pictures of an app's windows above its button, like Windows'
    // own: a click brings the window, the cross closes it. The pictures are
    // drawn by Windows itself (DWM thumbnails) — nothing is captured.
    internal sealed class TaskPreview : Window
    {
        private const double ThumbW = 208, ThumbH = 124;

        private readonly List<(Border slot, IntPtr thumb, IntPtr source)> _thumbs = new();
        private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal };
        private readonly Border _frame;
        private IntPtr _hwnd;
        public string App { get; private set; } = "";
        public event Action? Picked;

        public TaskPreview()
        {
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            SizeToContent = SizeToContent.WidthAndHeight;
            UseLayoutRounding = true;
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            _frame = new Border { Padding = new Thickness(6), Child = _row };
            Content = _frame;
            SourceInitialized += (_, _) =>
            {
                _hwnd = new WindowInteropHelper(this).Handle;
                Native.AddExStyle(_hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
                int round = 2; TB.DwmSetWindowAttribute(_hwnd, 33, ref round, sizeof(int));
                int dark = 1; TB.DwmSetWindowAttribute(_hwnd, 20, ref dark, sizeof(int));
            };
        }

        public bool Showing => IsVisible && App.Length > 0;

        public void ShowFor(string app, List<TaskWindow> windows, Look look, Rect button, double barTop)
        {
            bool light = look.Fg is SolidColorBrush f && f.Color.R < 0x80;
            Background = light ? new SolidColorBrush(Color.FromRgb(0xF3, 0xF3, 0xF5)) : new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x28));
            App = app;
            Clear();
            _row.Children.Clear();
            foreach (var w in windows.Take(6)) _row.Children.Add(Card(w, look));
            if (!IsVisible)
            {
                Left = -10000; Top = -10000;
                Show();
            }
            UpdateLayout();
            Left = Math.Max(SystemParameters.VirtualScreenLeft + 6, button.Left + button.Width / 2 - ActualWidth / 2);
            Top = barTop - ActualHeight - 8;
            // slide up a little
            var shift = new TranslateTransform(0, 8);
            _row.RenderTransform = shift;
            shift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.22)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            Dispatcher.BeginInvoke(new Action(Register), System.Windows.Threading.DispatcherPriority.Loaded);
        }

        private FrameworkElement Card(TaskWindow w, Look look)
        {
            var fg = look.Fg is SolidColorBrush b && b.Color.R < 0x80 ? b : Brushes.White;
            var hover = new SolidColorBrush(fg.Color == Colors.White ? Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x14, 0, 0, 0));
            var card = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 6, 8, 8), Margin = new Thickness(2), Background = Brushes.Transparent, Cursor = Cursors.Hand };
            var stack = new StackPanel();
            var head = new Grid { Height = 24, Margin = new Thickness(0, 0, 0, 6) };
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition());
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new Image { Width = 16, Height = 16, Source = AppWindows.IconOf(w.App, w.Handle), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
            head.Children.Add(icon);
            var title = new TextBlock { Text = w.Title, Foreground = fg, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, MaxWidth = ThumbW - 54 };
            Grid.SetColumn(title, 1);
            head.Children.Add(title);
            var close = new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(5), Background = Brushes.Transparent, Opacity = 0, Child = new IconView { Icon = "xmark", Width = 10, Height = 10, Fill = fg } };
            close.MouseEnter += (_, _) => close.Background = new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C));
            close.MouseLeave += (_, _) => close.Background = Brushes.Transparent;
            close.MouseLeftButtonUp += (_, e) => { e.Handled = true; AppWindows.Close(w.Handle); Picked?.Invoke(); };
            Grid.SetColumn(close, 2);
            head.Children.Add(close);
            stack.Children.Add(head);
            var slot = new Border { Width = ThumbW, Height = ThumbH, Background = Brushes.Transparent };
            stack.Children.Add(slot);
            card.Child = stack;
            card.MouseEnter += (_, _) => { card.Background = hover; close.Opacity = 1; };
            card.MouseLeave += (_, _) => { card.Background = Brushes.Transparent; close.Opacity = 0; };
            card.MouseLeftButtonUp += (_, _) => { AppWindows.Activate(w.Handle); Picked?.Invoke(); };
            _thumbs.Add((slot, IntPtr.Zero, w.Handle));
            return card;
        }

        private void Register()
        {
            if (_hwnd == IntPtr.Zero || !IsVisible) return;
            var dpi = VisualTreeHelper.GetDpi(this);
            for (int i = 0; i < _thumbs.Count; i++)
            {
                var (slot, thumb, source) = _thumbs[i];
                if (thumb == IntPtr.Zero && TB.DwmRegisterThumbnail(_hwnd, source, out var t) == 0) thumb = t;
                if (thumb == IntPtr.Zero) continue;
                _thumbs[i] = (slot, thumb, source);
                Point p;
                try { p = slot.TransformToAncestor(this).Transform(new Point(0, 0)); } catch { continue; }
                // keep the window's shape inside the slot
                TB.DwmQueryThumbnailSourceSize(thumb, out var size);
                double sw = Math.Max(1, size.X), sh = Math.Max(1, size.Y);
                double k = Math.Min(ThumbW / sw, ThumbH / sh) * dpi.DpiScaleX;
                double w = sw * k, h = sh * k;
                double x = p.X * dpi.DpiScaleX + (ThumbW * dpi.DpiScaleX - w) / 2;
                double y = p.Y * dpi.DpiScaleY + (ThumbH * dpi.DpiScaleY - h) / 2;
                var props = new TB.ThumbProps
                {
                    dwFlags = TB.DWM_TNP_RECTDESTINATION | TB.DWM_TNP_VISIBLE | TB.DWM_TNP_OPACITY | TB.DWM_TNP_SOURCECLIENTAREAONLY,
                    rcDestination = new TB.RECT { Left = (int)x, Top = (int)y, Right = (int)(x + w), Bottom = (int)(y + h) },
                    opacity = 255,
                    fVisible = true,
                    fSourceClientAreaOnly = false,
                };
                TB.DwmUpdateThumbnailProperties(thumb, ref props);
            }
        }

        private void Clear()
        {
            foreach (var (_, thumb, _) in _thumbs)
                if (thumb != IntPtr.Zero) TB.DwmUnregisterThumbnail(thumb);
            _thumbs.Clear();
        }

        public void HideNow()
        {
            Clear();
            App = "";
            if (IsVisible) Hide();
        }
    }
}
