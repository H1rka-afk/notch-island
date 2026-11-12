using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.SettingsUi
{
    // 0.5.1 — «Статистика», as in the Mac settings: the wide tile on the home
    // screen (today at a glance and the week in small bars) and the page —
    // cards for today, the week's chart, the switch and «Сбросить».
    public partial class SettingsWindow
    {
        private static readonly Color MusicPink = Color.FromRgb(0xFF, 0x45, 0x66);
        private StatsService Stats => App.Current.Stats;

        // ---- the wide tile on the home screen ----

        private FrameworkElement StatsTile()
        {
            var section = Find("stats");
            var c = section.Accent;
            var shape = new CornerRadius(24);
            var light = new RadialGradientBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF), Color.FromArgb(0, 0xFF, 0xFF, 0xFF))
            {
                Center = new Point(0.1, 0.1), GradientOrigin = new Point(0.1, 0.1), RadiusX = 0.5, RadiusY = 0.9
            };
            var bg = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
            bg.GradientStops.Add(new GradientStop(c, 0));
            bg.GradientStops.Add(new GradientStop(Color.FromArgb(0x8C, c.R, c.G, c.B), 0.55));
            bg.GradientStops.Add(new GradientStop(Color.FromRgb(0x0D, 0x40, 0x73), 1));

            var row = new Grid { Margin = new Thickness(18, 14, 18, 14) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(124) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var header = new Grid();
            header.Children.Add(new IconView { Icon = "chart", Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top });
            var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
            titles.Children.Add(new TextBlock { Text = "СЕГОДНЯ", FontSize = 10, FontWeight = FontWeights.Black, Opacity = 0.7 });
            titles.Children.Add(new TextBlock { Text = "Статистика", FontSize = 17, FontWeight = FontWeights.Black, FontFamily = DisplayFont });
            header.Children.Add(titles);
            row.Children.Add(header);

            var metrics = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(metrics, 1);
            var today = Stats.Today;
            if (S.StatsEnabled)
            {
                metrics.Children.Add(TileMetric("За компьютером", StatsService.Duration(today.ActiveSeconds), "display"));
                metrics.Children.Add(TileMetric("Музыка", StatsService.Duration(today.MusicSeconds), "music.note"));
                metrics.Children.Add(TileMetric("Треки", today.Tracks.ToString(), "waveform"));
                metrics.Children.Add(TileMetric("Отдых глазам", today.EyeBreaks.ToString(), "eye"));
            }
            else metrics.Children.Add(new TextBlock { Text = "Статистика выключена", FontSize = 13, FontWeight = FontWeights.Medium, Opacity = 0.85 });
            row.Children.Add(metrics);

            if (S.StatsEnabled)
            {
                var bars = WeekBars(58, compact: true);
                bars.Width = 150;
                bars.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(bars, 2);
                row.Children.Add(bars);
            }

            var content = new Grid();
            content.Children.Add(new Border { CornerRadius = shape, Background = bg });
            content.Children.Add(new Border { CornerRadius = shape, Background = Gloss(0x2E) });
            content.Children.Add(new Border { CornerRadius = shape, Background = light });
            content.Children.Add(row);
            var tile = new Border
            {
                CornerRadius = shape, Margin = new Thickness(7), Child = content, Cursor = Cursors.Hand, BorderThickness = new Thickness(1),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x4D, 0xFF, 0xFF, 0xFF)),
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(1, 1),
                Effect = new DropShadowEffect { Color = c, BlurRadius = 12, ShadowDepth = 5, Direction = 270, Opacity = 0.35 }
            };
            TextElement.SetForeground(tile, Brushes.White);
            Hover(tile, light, c, () => { _hovered = section; UpdateStage(); }, () => { if (_hovered == section) { _hovered = null; UpdateStage(); } });
            tile.MouseLeftButtonUp += (_, _) => Open(section, animated: true);
            return tile;
        }

        private static FrameworkElement TileMetric(string title, string value, string icon)
        {
            var stack = new StackPanel { MinWidth = 92, Margin = new Thickness(0, 0, 14, 0) };
            stack.Children.Add(new IconView { Icon = icon, Width = 13, Height = 13, HorizontalAlignment = HorizontalAlignment.Left, Opacity = 0.8 });
            stack.Children.Add(new TextBlock { Text = value, FontSize = 17, FontWeight = FontWeights.Black, FontFamily = DisplayFont, Margin = new Thickness(0, 3, 0, 1) });
            stack.Children.Add(new TextBlock { Text = title.ToUpperInvariant(), FontSize = 9, FontWeight = FontWeights.Black, Opacity = 0.7 });
            return stack;
        }

        // Seven days: the bar is the time at the computer, the pink part
        // inside it is how much of that music played.
        private Grid WeekBars(double height, bool compact)
        {
            var week = Stats.Week;
            double peak = Math.Max(3600, week.Max(d => d.ActiveSeconds));
            var accent = Find("stats").Accent;
            var grid = new Grid();
            for (int i = 0; i < week.Count; i++)
            {
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var day = week[i];
                bool isToday = i == week.Count - 1;
                var column = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
                var slot = new Grid { Height = height, Width = compact ? 10 : 30 };
                if (!compact)
                {
                    var track = new Border { CornerRadius = new CornerRadius(15) };
                    track.SetResourceReference(Border.BackgroundProperty, "FieldBg");
                    slot.Children.Add(track);
                }
                double h = Math.Max(3, height * day.ActiveSeconds / peak);
                var bar = new Border
                {
                    Height = h, VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new CornerRadius(compact ? 5 : Math.Min(15, h / 2)),
                    Background = compact ? new SolidColorBrush(Color.FromArgb(isToday ? (byte)0xF2 : (byte)0x80, 0xFF, 0xFF, 0xFF))
                                         : new SolidColorBrush(Color.FromArgb(isToday ? (byte)0xFF : (byte)0x8C, accent.R, accent.G, accent.B)),
                    RenderTransformOrigin = new Point(0.5, 1), RenderTransform = new ScaleTransform(1, compact ? 1 : 0)
                };
                // On the page the bars grow in, one after another.
                if (!compact)
                    ((ScaleTransform)bar.RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty,
                        new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.55)) { BeginTime = TimeSpan.FromSeconds(0.04 * i), EasingFunction = new BackEase { Amplitude = 0.25, EasingMode = EasingMode.EaseOut } });
                slot.Children.Add(bar);
                if (!compact)
                {
                    double mh = height * Math.Min(day.MusicSeconds, day.ActiveSeconds) / peak;
                    if (mh >= 2)
                        slot.Children.Add(new Border
                        {
                            Height = mh, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(6, 0, 6, 0),
                            CornerRadius = new CornerRadius(Math.Min(9, mh / 2)), Background = new SolidColorBrush(Color.FromArgb(0xD9, MusicPink.R, MusicPink.G, MusicPink.B))
                        });
                }
                column.Children.Add(slot);
                var name = new TextBlock { Text = StatsService.Weekday(day.Day), FontSize = compact ? 8.5 : 11, FontWeight = isToday ? FontWeights.Black : FontWeights.Medium, Opacity = isToday ? 1 : 0.7, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
                column.Children.Add(name);
                if (!compact)
                {
                    var time = new TextBlock
                    {
                        Text = day.ActiveSeconds >= 60 ? StatsService.Duration(day.ActiveSeconds).Replace(" мин", "м").Replace(" ч", "ч") : "—",
                        FontSize = 9.5, FontWeight = FontWeights.Medium, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 0)
                    };
                    time.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
                    column.Children.Add(time);
                }
                column.ToolTip = StatsService.Weekday(day.Day) + ": за компьютером " + StatsService.Duration(day.ActiveSeconds) + ", музыка " + StatsService.Duration(day.MusicSeconds);
                Grid.SetColumn(column, i);
                grid.Children.Add(column);
            }
            return grid;
        }

        // ---- the page ----

        private StackPanel? _statsHost;

        private void BuildStatsPage(StackPanel page)
        {
            _statsHost = new StackPanel();
            page.Children.Add(_statsHost);
            Remember("Статистика за сегодня", "статистика день время музыка треки перерывы неделя", _statsHost);
            page.Children.Add(Group("Настройки", "Считается только на этом компьютере и никуда не отправляется. Хранятся последние 7 дней. Время за компьютером — когда ты печатал или двигал мышью в последнюю минуту; что именно ты делал, Ovira не знает.",
                ToggleRow("Вести статистику", null, nameof(Settings.StatsEnabled), "статистика вести включить"),
                ButtonRow("Сбросить статистику", "Сегодня и вся неделя обнулятся", "Сбросить", () => Stats.Reset(), "сбросить статистику")));
            if (_collecting) return;
            FillStats();
            Action changed = () => Dispatcher.BeginInvoke(new Action(() => { if (_current?.Key == "stats") FillStats(animate: false); }));
            Stats.Changed += changed;
            Closed += (_, _) => Stats.Changed -= changed;
        }

        private string _statsKey = "", _statsTileKey = "";

        // The home tile follows the figures (once a minute at most).
        private void RefreshStatsTile()
        {
            if (_current != null) return;
            var t = Stats.Today;
            var key = S.StatsEnabled + "|" + (int)(t.ActiveSeconds / 60) + "|" + (int)(t.MusicSeconds / 60) + "|" + t.Tracks + "|" + t.EyeBreaks;
            if (key == _statsTileKey) return;
            _statsTileKey = key;
            BuildTiles();
            ShowTrack();
        }

        private void FillStats(bool animate = true)
        {
            if (_statsHost == null) return;
            var today = Stats.Today;
            var week = Stats.Week;
            // Rebuild only when a figure changed (the bars would re-animate).
            var key = S.StatsEnabled + "|" + (int)(today.ActiveSeconds / 60) + "|" + (int)(today.MusicSeconds / 60) + "|" + today.Tracks + "|" + today.EyeBreaks + "|" +
                      today.EyeSkipped + "|" + today.Timers + "|" + today.Unlocks + "|" + today.Calls + "|" + (int)(today.CallSeconds / 60) + "|" + S.Theme;
            if (!animate && key == _statsKey && _statsHost.Children.Count > 0) return;
            _statsKey = key;
            _statsHost.Children.Clear();
            if (!S.StatsEnabled) return;
            var p = (Func<int, string, string, string, string>)StatsService.Plural;
            var accent = Find("stats").Accent;

            var title = new TextBlock { Text = "СЕГОДНЯ", Style = (Style)FindResource("GroupTitle") };
            _statsHost.Children.Add(title);
            var cards = new UniformGrid { Columns = 3, Margin = new Thickness(-6, 0, -6, 14) };
            cards.Children.Add(StatsCard("За компьютером", StatsService.Duration(today.ActiveSeconds), "Когда ты печатал или двигал мышью", "display", accent));
            cards.Children.Add(StatsCard("Музыка", StatsService.Duration(today.MusicSeconds), today.Tracks + " " + p(today.Tracks, "трек", "трека", "треков"), "music.note", MusicPink));
            cards.Children.Add(StatsCard("Отдых глазам", today.EyeBreaks.ToString(), today.EyeSkipped > 0 ? "Пропущено: " + today.EyeSkipped : "Перерывов по правилу 20-20-20", "eye", Color.FromRgb(0x40, 0xCC, 0xD9)));
            cards.Children.Add(StatsCard("Разблокировки", today.Unlocks.ToString(), "Сколько раз входил в Windows", "lock.open", Color.FromRgb(0x8C, 0x8F, 0x99)));
            cards.Children.Add(StatsCard("Таймеры", today.Timers.ToString(), "Запущено в «Часах»", "timer", Color.FromRgb(0xFF, 0x94, 0x00)));
            cards.Children.Add(StatsCard("Звонки", today.Calls.ToString(), today.CallSeconds >= 60 ? "Всего " + StatsService.Duration(today.CallSeconds) : "Discord и VK", "phone.fill", Color.FromRgb(0x34, 0xC7, 0x59)));
            _statsHost.Children.Add(cards);

            double weekActive = week.Sum(d => d.ActiveSeconds);
            int activeDays = Math.Max(1, week.Count(d => d.ActiveSeconds >= 60));
            var bars = WeekBars(120, compact: false);
            bars.Margin = new Thickness(16, 14, 16, 14);
            _statsHost.Children.Add(Group("Неделя", "Столбик — время за компьютером, розовая часть внутри — сколько из него играла музыка. В среднем " +
                                                    StatsService.Duration(weekActive / activeDays) + " в день.", bars));
        }

        private FrameworkElement StatsCard(string title, string value, string detail, string icon, Color color)
        {
            var stack = new StackPanel { Margin = new Thickness(14) };
            var head = new StackPanel { Orientation = Orientation.Horizontal };
            head.Children.Add(new IconView { Icon = icon, Width = 14, Height = 14, Fill = new SolidColorBrush(color), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
            var name = new TextBlock { Text = title, FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
            name.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            head.Children.Add(name);
            stack.Children.Add(head);
            stack.Children.Add(new TextBlock { Text = value, FontSize = 24, FontWeight = FontWeights.Black, FontFamily = DisplayFont, Margin = new Thickness(0, 6, 0, 4), TextTrimming = TextTrimming.CharacterEllipsis });
            var note = new TextBlock { Text = detail, FontSize = 11, TextWrapping = TextWrapping.Wrap, MaxHeight = 30 };
            note.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            stack.Children.Add(note);
            return new Border { Style = (Style)FindResource("GlassCard"), Padding = new Thickness(0), Margin = new Thickness(6), MinHeight = 108, Child = stack };
        }
    }
}
