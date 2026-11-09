using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.SettingsUi
{
    // 0.4.13 — the Mac's update banner on the home screen (updateBanner and
    // updateNotesCard in NotchSettingsWindow.swift): «Доступна версия …» with
    // «Подробнее» and a white «Обновить» capsule, and right under it
    // «Что нового в …» with the points from the release. In the theme's
    // first two colours, green and teal otherwise.
    public partial class SettingsWindow
    {
        private string? _cardShown;

        private (Color A, Color B) UpdateColors =>
            s_palette.Length >= 2 ? (s_palette[0], s_palette[1]) : (Color.FromRgb(0x2E, 0xC2, 0x6B), Color.FromRgb(0x1F, 0xB5, 0xC2));

        private void ShowUpdateCard()
        {
            if (UpdateHost == null) return;
            var u = App.Current.Updates;
            bool installing = u.State == UpdateService.UpdateState.Installing;
            bool ready = u.State == UpdateService.UpdateState.Ready && u.NewVersion != null;
            string key = installing ? "installing" : ready ? "ready " + u.NewVersion + " " + u.Message + " " + S.Theme : "";
            if (key == _cardShown) return;
            bool fresh = string.IsNullOrEmpty(_cardShown) && key.Length > 0;
            _cardShown = key;
            UpdateHost.Children.Clear();
            if (key.Length == 0) return;

            var banner = UpdateBanner(u, installing);
            UpdateHost.Children.Add(banner);
            if (fresh) DropIn(banner, 0);
            if (!installing && u.Notes.Count > 0)
            {
                var notes = NotesCard(u);
                UpdateHost.Children.Add(notes);
                if (fresh) DropIn(notes, 0.08);
            }
        }

        private FrameworkElement UpdateBanner(UpdateService u, bool installing)
        {
            var (green, teal) = UpdateColors;
            var shape = new CornerRadius(22);
            var grid = new Grid { Margin = new Thickness(16, 14, 16, 14) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            // The circle with the arrow that gently pulses.
            var circle = new Grid { Width = 46, Height = 46, VerticalAlignment = VerticalAlignment.Center };
            circle.Children.Add(new Ellipse { Fill = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)) });
            var arrow = new IconView { Icon = installing ? "sparkles" : "arrow.down", Width = 24, Height = 24 };
            circle.Children.Add(arrow);
            arrow.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.45, TimeSpan.FromSeconds(0.9))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
            });
            grid.Children.Add(circle);

            var text = new StackPanel { Margin = new Thickness(14, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, 1);
            text.Children.Add(new TextBlock
            {
                Text = installing ? "Устанавливаю обновление…" : "Доступна версия " + u.NewVersion,
                FontSize = 17, FontWeight = FontWeights.Black, FontFamily = DisplayFont, Foreground = Brushes.White
            });
            bool failed = u.Message.StartsWith("Не получилось", StringComparison.Ordinal);
            text.Children.Add(new TextBlock
            {
                Text = installing ? "Несколько секунд. Ovira закроется и откроется сама."
                     : failed ? u.Message
                     : "Уже скачана. Установка займёт несколько секунд — Ovira закроется и откроется сама; настройки сохранятся.",
                FontSize = 11.5, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Color.FromArgb(0xE0, 0xFF, 0xFF, 0xFF)),
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0)
            });
            grid.Children.Add(text);

            if (!installing)
            {
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(buttons, 2);
                var more = new TextBlock
                {
                    Text = "Подробнее", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Opacity = 0.85,
                    VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0), Cursor = Cursors.Hand
                };
                more.MouseEnter += (_, _) => more.Opacity = 1;
                more.MouseLeave += (_, _) => more.Opacity = 0.85;
                more.MouseLeftButtonUp += (_, _) =>
                {
                    Open(Find("general"), animated: true);
                    Dispatcher.BeginInvoke(new Action(() => Highlight("Проверить обновления")), System.Windows.Threading.DispatcherPriority.Loaded);
                };
                buttons.Children.Add(more);
                var label = new TextBlock { Text = "Обновить", FontSize = 13, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(green) };
                var capsule = new Border
                {
                    CornerRadius = new CornerRadius(17), Background = Brushes.White, Padding = new Thickness(16, 8, 16, 8), Child = label,
                    Cursor = Cursors.Hand, ToolTip = "Установить версию " + u.NewVersion,
                    RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(1, 1),
                    Effect = new DropShadowEffect { BlurRadius = 8, ShadowDepth = 2, Direction = 270, Opacity = 0.15 }
                };
                capsule.MouseLeftButtonDown += (_, _) => Squeeze(capsule, 0.94);
                capsule.MouseLeave += (_, _) => Squeeze(capsule, 1);
                capsule.MouseLeftButtonUp += (_, _) => { Squeeze(capsule, 1); u.Install(); };
                buttons.Children.Add(capsule);
                grid.Children.Add(buttons);
            }

            var content = new Grid();
            content.Children.Add(new Border { CornerRadius = shape, Background = new LinearGradientBrush(green, teal, 0) });
            content.Children.Add(new Border
            {
                CornerRadius = shape,
                Background = new LinearGradientBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF), new Point(0, 0), new Point(0, 0.5))
            });
            content.Children.Add(grid);
            return new Border
            {
                CornerRadius = shape, Child = content, Margin = new Thickness(0, 0, 0, 14),
                BorderThickness = new Thickness(1), BorderBrush = new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)),
                Effect = new DropShadowEffect { Color = green, BlurRadius = 24, ShadowDepth = 5, Direction = 270, Opacity = 0.4 }
            };
        }

        private FrameworkElement NotesCard(UpdateService u)
        {
            var (a, b) = UpdateColors;
            var gradient = new LinearGradientBrush(a, b, 0);
            var stack = new StackPanel { Margin = new Thickness(16) };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
            head.Children.Add(new IconView { Icon = "sparkles", Width = 15, Height = 15, Fill = gradient, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
            head.Children.Add(new TextBlock { Text = "Что нового в " + u.NewVersion, FontSize = 13, FontWeight = FontWeights.Black, FontFamily = DisplayFont, VerticalAlignment = VerticalAlignment.Center });
            stack.Children.Add(head);
            var dot = new LinearGradientBrush(a, b, 90);
            foreach (var item in u.Notes)
            {
                var row = new Grid { Margin = new Thickness(0, 0, 0, 6) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = dot, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) });
                var line = new TextBlock { Text = item, FontSize = 12, TextWrapping = TextWrapping.Wrap };
                Grid.SetColumn(line, 1);
                row.Children.Add(line);
                stack.Children.Add(row);
            }
            var card = new Border
            {
                CornerRadius = new CornerRadius(20), Child = stack, Margin = new Thickness(0, 0, 0, 18), BorderThickness = new Thickness(1),
                Background = new SolidColorBrush(Color.FromArgb(0x1F, a.R, a.G, a.B))
            };
            card.SetResourceReference(Border.BorderBrushProperty, "FieldBorder");
            var glass = new Border { CornerRadius = new CornerRadius(20), Margin = card.Margin };
            glass.SetResourceReference(Border.BackgroundProperty, "CardBg");
            var host = new Grid();
            card.Margin = new Thickness(0);
            host.Margin = new Thickness(0, 0, 0, 18);
            glass.Margin = new Thickness(0);
            host.Children.Add(glass);
            host.Children.Add(card);
            return host;
        }

        // Comes down from the top and fades in, like the Mac's transition.
        private static void DropIn(FrameworkElement e, double delay)
        {
            var shift = new TranslateTransform(0, -14);
            e.RenderTransform = shift;
            e.Opacity = 0;
            var begin = TimeSpan.FromSeconds(delay);
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.35)) { BeginTime = begin, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            shift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-14, 0, TimeSpan.FromSeconds(0.5))
            {
                BeginTime = begin, EasingFunction = new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut }
            });
        }

        private static void Squeeze(FrameworkElement e, double to)
        {
            if (e.RenderTransform is not ScaleTransform s) return;
            var a = new DoubleAnimation(to, TimeSpan.FromSeconds(0.15)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            s.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            s.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
    }
}
