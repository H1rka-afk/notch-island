using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Ovira.Core;
using Ovira.Island;
using Ovira.Services;

namespace Ovira.Widgets
{
    // What each widget shows. Every builder returns the content and a small
    // «update» that refreshes the figures in place (called once a second and
    // when something changes).
    public static class WidgetViews
    {
        private static readonly FontFamily Display = new FontFamily("Segoe UI Variable Display, Segoe UI");
        private static readonly System.Globalization.CultureInfo Ru = new System.Globalization.CultureInfo("ru-RU");

        public static (FrameworkElement, Action) Build(WidgetState st, Look L, WidgetWindow? w) => st.Kind switch
        {
            "nowplaying" => NowPlaying(st, L),
            "cover" => Cover(st, L),
            "saved" => Saved(st, L),
            "calendar" => Calendar(st, L),
            "timer" => Timer(st, L),
            "alarms" => Alarms(st, L),
            "stats" => Stats(st, L),
            "eyes" => Eyes(st, L),
            "battery" => Battery(st, L),
            "load" => Load(st, L),
            "disks" => Disks(st, L),
            "network" => Network(st, L),
            "steam" => Steam(st, L),
            "note" => Note(st, L),
            "todo" => Todo(st, L, w),
            "weather" => Weather(st, L),
            "currency" => Currency(st, L),
            _ => Clock(st, L),
        };

        // ---- small helpers ----

        private static TextBlock T(string text, double size, FontWeight weight, Brush brush, bool display = false) => new TextBlock
        {
            Text = text, FontSize = size, FontWeight = weight, Foreground = brush, TextTrimming = TextTrimming.CharacterEllipsis,
            FontFamily = display ? Display : new FontFamily("Segoe UI Variable Text, Segoe UI")
        };

        private static TextBlock Caption(string text, Look L) => T(text.ToUpperInvariant(), 10, FontWeights.Bold, L.Fg2);

        private static IconView Icon(string name, double size, Brush fill) => new IconView { Icon = name, Width = size, Height = size, Fill = fill };

        private static TElement Click<TElement>(TElement element, Action action) where TElement : FrameworkElement
        {
            element.Tag = "click";
            element.Cursor = Cursors.Hand;
            element.MouseLeftButtonUp += (_, e) => { e.Handled = true; action(); };
            return element;
        }

        private static FrameworkElement Header(string icon, string title, Look L)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(Icon(icon, 13, L.Accent));
            var t = Caption(title, L);
            t.Margin = new Thickness(6, 0, 0, 0);
            t.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(t);
            return row;
        }

        // A round button with an icon.
        private static FrameworkElement RoundButton(string icon, Look L, Action action, double size = 34, bool filled = false)
        {
            var glyph = Icon(icon, size * 0.46, L.Fg);
            var circle = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = filled ? L.Accent : L.Faint, Child = glyph };
            if (filled) glyph.Fill = L.AccentColor == Colors.White ? new SolidColorBrush(Color.FromRgb(0x1C, 0x1C, 0x1E)) : Brushes.White;
            return Click(circle, action);
        }

        // A thin progress bar; returns the setter (0…1).
        private static (FrameworkElement, Action<double>) Bar(Look L, double height = 5, Brush? fill = null)
        {
            var scale = new ScaleTransform(0, 1);
            var grid = new Grid { Height = height };
            grid.Children.Add(new Border { CornerRadius = new CornerRadius(height / 2), Background = L.Faint });
            grid.Children.Add(new Border { CornerRadius = new CornerRadius(height / 2), Background = fill ?? L.Accent, RenderTransformOrigin = new Point(0, 0.5), RenderTransform = scale });
            return (grid, v => scale.ScaleX = Math.Clamp(double.IsNaN(v) ? 0 : v, 0, 1));
        }

        // A ring that fills clockwise from the top; returns the setter (0…1).
        private static (Grid, Action<double>) Ring(double d, double thick, Look L, Brush? fill = null)
        {
            var grid = new Grid { Width = d, Height = d };
            grid.Children.Add(new Ellipse { Stroke = L.Faint, StrokeThickness = thick });
            var arc = new System.Windows.Shapes.Path { Stroke = fill ?? L.Accent, StrokeThickness = thick, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
            grid.Children.Add(arc);
            void Set(double v)
            {
                v = Math.Clamp(double.IsNaN(v) ? 0 : v, 0, 1);
                if (v <= 0.001) { arc.Data = null; return; }
                double r = (d - thick) / 2, c = d / 2, a = Math.Min(v, 0.9999) * 2 * Math.PI;
                var figure = new PathFigure { StartPoint = new Point(c, c - r), IsClosed = false };
                figure.Segments.Add(new ArcSegment(new Point(c + r * Math.Sin(a), c - r * Math.Cos(a)), new Size(r, r), 0, v > 0.5, SweepDirection.Clockwise, true));
                arc.Data = new PathGeometry(new[] { figure });
            }
            return (grid, Set);
        }

        private static Grid Pad(double all = 14) => new Grid { Margin = new Thickness(all) };

        private static string Hm(TimeSpan t) => t.TotalHours >= 1 ? $"{(int)t.TotalHours} ч {t.Minutes} мин" : $"{Math.Max(1, t.Minutes)} мин";

        // ---- 1. Сейчас играет ----

        private static (FrameworkElement, Action) NowPlaying(WidgetState st, Look L)
        {
            bool small = st.Size == "s";
            var media = App.Current.Media;
            var art = new Border { Width = small ? 60 : 72, Height = small ? 60 : 72, CornerRadius = new CornerRadius(14), Background = L.Faint, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            var note = Icon("music.note", 24, L.Fg2);
            art.Child = note;
            var title = T("Ничего не играет", small ? 13 : 15, FontWeights.Bold, L.Fg, true);
            var artist = T("", 12, FontWeights.Medium, L.Fg2);
            var bars = new SpectrumBars { BarWidth = 3, BarSpacing = 2.3, BarMaxHeight = 22, Width = 6 * 3 + 5 * 2.3, Height = 22, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
            var play = Icon("play", 22, L.Fg);
            var (bar, setBar) = Bar(L, 4, L.Fg);
            var root = Pad();
            if (small)
            {
                root.Children.Add(art);
                root.Children.Add(bars);
                var text = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 34, 0) };
                text.Children.Add(title); text.Children.Add(artist);
                root.Children.Add(text);
                var button = Click(new Border { Width = 30, Height = 30, Background = Brushes.Transparent, Child = play, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom }, media.PlayPause);
                root.Children.Add(button);
            }
            else
            {
                root.Children.Add(art);
                root.Children.Add(bars);
                var text = new StackPanel { Margin = new Thickness(84, 4, 40, 0), VerticalAlignment = VerticalAlignment.Top };
                text.Children.Add(title); text.Children.Add(artist);
                root.Children.Add(text);
                var bottom = new Grid { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(84, 0, 0, 0) };
                bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                bar.Margin = new Thickness(0, 0, 0, 10);
                bottom.Children.Add(bar);
                var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
                Grid.SetRow(controls, 1);
                FrameworkElement Hit(FrameworkElement glyph, Action a) => Click(new Border { Width = 44, Height = 28, Background = Brushes.Transparent, Child = glyph }, a);
                controls.Children.Add(Hit(Icon("backward", 20, L.Fg), media.Previous));
                controls.Children.Add(Hit(play, media.PlayPause));
                controls.Children.Add(Hit(Icon("forward", 20, L.Fg), media.Next));
                bottom.Children.Add(controls);
                root.Children.Add(bottom);
            }
            object? shown = null;
            void Update()
            {
                var t = media.Track;
                title.Text = t?.Title is { Length: > 0 } name ? name : "Ничего не играет";
                artist.Text = t?.Artist ?? "";
                play.Icon = t?.Playing == true ? "pause" : "play";
                bars.Playing = t?.Playing == true;
                bars.Visibility = t != null ? Visibility.Visible : Visibility.Hidden;
                if (!ReferenceEquals(shown, t?.Artwork))
                {
                    shown = t?.Artwork;
                    art.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : L.Faint;
                    note.Visibility = t?.Artwork != null ? Visibility.Collapsed : Visibility.Visible;
                    bars.SetCover(t?.Artwork, t?.Tint ?? Colors.White);
                }
                setBar(t != null && t.Duration.TotalSeconds > 1 ? t.LivePosition.TotalSeconds / t.Duration.TotalSeconds : 0);
            }
            return (root, Update);
        }

        // ---- 2. Обложка ----

        private static (FrameworkElement, Action) Cover(WidgetState st, Look L)
        {
            var media = App.Current.Media;
            var picture = new Border { CornerRadius = new CornerRadius(24), Background = L.Faint };
            var empty = Icon("music.note", 40, L.Fg2);
            var badge = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12) };
            var play = Icon("play", 15, Brushes.White);
            badge.Child = play;
            var root = new Grid();
            root.Children.Add(picture);
            root.Children.Add(empty);
            root.Children.Add(badge);
            Click(root, media.PlayPause);
            object? shown = "none";
            void Update()
            {
                var t = media.Track;
                play.Icon = t?.Playing == true ? "pause" : "play";
                if (ReferenceEquals(shown, t?.Artwork)) return;
                shown = t?.Artwork;
                picture.Background = t?.Artwork != null ? new ImageBrush(t.Artwork) { Stretch = Stretch.UniformToFill } : L.Faint;
                empty.Visibility = t?.Artwork != null ? Visibility.Collapsed : Visibility.Visible;
            }
            return (root, Update);
        }

        // ---- 3. Сохранённые песни ----

        private static (FrameworkElement, Action) Saved(WidgetState st, Look L)
        {
            var root = Pad();
            var stack = new StackPanel();
            stack.Children.Add(Header("star.fill", "Сохранённые песни", L));
            var list = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
            stack.Children.Add(list);
            root.Children.Add(stack);
            string key = "?";
            void Update()
            {
                var tracks = Settings.Current.SavedTracks.Take(st.Size == "l" ? 9 : 3).ToList();
                var now = string.Join("|", tracks.Select(t => t.ToString()));
                if (now == key) return;
                key = now;
                list.Children.Clear();
                if (tracks.Count == 0) { list.Children.Add(T("Нажми на звёздочку в плеере", 12, FontWeights.Medium, L.Fg2)); return; }
                foreach (var track in tracks)
                {
                    var row = new StackPanel { Margin = new Thickness(0, 0, 0, 7), Background = Brushes.Transparent, ToolTip = "Скопировать" };
                    row.Children.Add(T(track.Title, 13, FontWeights.SemiBold, L.Fg));
                    row.Children.Add(T(track.Artist, 11, FontWeights.Medium, L.Fg2));
                    Click(row, () => { try { Clipboard.SetText(track.ToString()); } catch { } });
                    list.Children.Add(row);
                }
            }
            return (root, Update);
        }

        // ---- 4. Часы ----

        private static (FrameworkElement, Action) Clock(WidgetState st, Look L)
        {
            var root = Pad();
            if (st.Variant == "analog")
            {
                double d = 124;
                var face = new Canvas { Width = d, Height = d, HorizontalAlignment = st.Size == "m" ? HorizontalAlignment.Left : HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                face.Children.Add(new Ellipse { Width = d, Height = d, Stroke = L.Faint, StrokeThickness = 3 });
                for (int i = 0; i < 12; i++)
                {
                    double a = i * Math.PI / 6, r1 = d / 2 - 6, r2 = d / 2 - (i % 3 == 0 ? 15 : 11);
                    face.Children.Add(new Line { X1 = d / 2 + r1 * Math.Sin(a), Y1 = d / 2 - r1 * Math.Cos(a), X2 = d / 2 + r2 * Math.Sin(a), Y2 = d / 2 - r2 * Math.Cos(a), Stroke = i % 3 == 0 ? L.Fg : L.Fg2, StrokeThickness = i % 3 == 0 ? 2.4 : 1.4, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
                }
                RotateTransform Hand(double length, double thick, Brush brush)
                {
                    var turn = new RotateTransform(0, d / 2, d / 2);
                    face.Children.Add(new Line { X1 = d / 2, Y1 = d / 2 + 8, X2 = d / 2, Y2 = d / 2 - length, Stroke = brush, StrokeThickness = thick, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, RenderTransform = turn });
                    return turn;
                }
                var hour = Hand(30, 4.5, L.Fg);
                var minute = Hand(46, 3.2, L.Fg);
                var second = Hand(50, 1.4, L.Accent);
                var dot = new Ellipse { Width = 8, Height = 8, Fill = L.Accent };
                Canvas.SetLeft(dot, d / 2 - 4); Canvas.SetTop(dot, d / 2 - 4);
                face.Children.Add(dot);
                root.Children.Add(face);
                var side = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(146, 0, 0, 0), Visibility = st.Size == "m" ? Visibility.Visible : Visibility.Collapsed };
                var weekday = T("", 13, FontWeights.Bold, L.Accent);
                var date = T("", 22, FontWeights.Bold, L.Fg, true);
                side.Children.Add(weekday); side.Children.Add(date);
                root.Children.Add(side);
                return (root, () =>
                {
                    var now = DateTime.Now;
                    hour.Angle = (now.Hour % 12 + now.Minute / 60.0) * 30;
                    minute.Angle = (now.Minute + now.Second / 60.0) * 6;
                    second.Angle = now.Second * 6;
                    weekday.Text = Ru.DateTimeFormat.GetDayName(now.DayOfWeek);
                    date.Text = now.ToString("d MMMM", Ru);
                });
            }
            var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var day = T("", 13, FontWeights.Bold, L.Accent);
            var time = T("", st.Size == "m" ? 62 : 46, FontWeights.SemiBold, L.Fg, true);
            time.Margin = new Thickness(-2, -6, 0, -4);
            Typography.SetNumeralAlignment(time, FontNumeralAlignment.Tabular);
            var full = T("", 13, FontWeights.Medium, L.Fg2);
            stack.Children.Add(day); stack.Children.Add(time); stack.Children.Add(full);
            root.Children.Add(stack);
            return (root, () =>
            {
                var now = DateTime.Now;
                day.Text = Ru.DateTimeFormat.GetDayName(now.DayOfWeek);
                time.Text = now.ToString("HH:mm");
                full.Text = now.ToString("d MMMM", Ru);
            });
        }

        // ---- 5. Календарь ----

        private static (FrameworkElement, Action) Calendar(WidgetState st, Look L)
        {
            bool large = st.Size == "l";
            var root = Pad(large ? 18 : 11);
            var stack = new StackPanel();
            var month = T("", large ? 20 : 12, FontWeights.Bold, L.Accent, true);
            month.Margin = new Thickness(2, 0, 0, large ? 10 : 4);
            stack.Children.Add(month);
            var grid = new UniformGrid { Columns = 7 };
            stack.Children.Add(grid);
            root.Children.Add(stack);
            string key = "";
            void Update()
            {
                var today = DateTime.Today;
                var k = today.ToString("yyyyMMdd");
                if (k == key) return;
                key = k;
                month.Text = Ru.TextInfo.ToTitleCase(today.ToString("MMMM", Ru)) + (large ? " " + today.Year : "");
                grid.Children.Clear();
                double cell = large ? 40 : 19.5, font = large ? 15 : 10.5;
                foreach (var name in new[] { "пн", "вт", "ср", "чт", "пт", "сб", "вс" })
                {
                    var head = T(name, large ? 11 : 8.5, FontWeights.Bold, L.Fg2);
                    head.TextAlignment = TextAlignment.Center;
                    head.Height = large ? 22 : 13;
                    grid.Children.Add(head);
                }
                var first = new DateTime(today.Year, today.Month, 1);
                int offset = ((int)first.DayOfWeek + 6) % 7;
                for (int i = 0; i < offset; i++) grid.Children.Add(new Border { Height = cell });
                for (int dayNumber = 1; dayNumber <= DateTime.DaysInMonth(today.Year, today.Month); dayNumber++)
                {
                    bool isToday = dayNumber == today.Day;
                    var number = T(dayNumber.ToString(), font, isToday ? FontWeights.Bold : FontWeights.Medium,
                                   isToday ? (L.AccentColor == Colors.White ? new SolidColorBrush(Color.FromRgb(0x1C, 0x1C, 0x1E)) : Brushes.White) : L.Fg);
                    number.HorizontalAlignment = HorizontalAlignment.Center;
                    number.VerticalAlignment = VerticalAlignment.Center;
                    double dot = cell - (large ? 6 : 1.5);
                    grid.Children.Add(new Border { Height = cell, Child = new Border { Width = dot, Height = dot, CornerRadius = new CornerRadius(dot / 2), Background = isToday ? L.Accent : Brushes.Transparent, Child = number } });
                }
            }
            return (root, Update);
        }

        // ---- 6. Таймер и секундомер ----

        private static (FrameworkElement, Action) Timer(WidgetState st, Look L)
        {
            var clock = App.Current.Clock;
            var root = Pad();
            var label = Caption("Таймер", L);
            var time = T("0:00", st.Size == "m" ? 44 : 34, FontWeights.SemiBold, L.Fg, true);
            Typography.SetNumeralAlignment(time, FontNumeralAlignment.Tabular);
            time.Margin = new Thickness(0, 2, 0, 0);
            var top = new StackPanel();
            top.Children.Add(label); top.Children.Add(time);
            var (bar, setBar) = Bar(L, 4);
            bar.Margin = new Thickness(0, 6, 0, 0);
            top.Children.Add(bar);
            root.Children.Add(top);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Bottom };
            var playGlyph = Icon("play", 15, L.Fg);
            var playButton = Click(new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), Background = L.Faint, Child = playGlyph, Margin = new Thickness(0, 0, 6, 0) }, () =>
            {
                if (clock.TimerActive) { if (clock.TimerPaused) clock.ResumeTimer(); else clock.PauseTimer(); }
                else if (clock.StopwatchRunning) clock.PauseStopwatch();
                else if (clock.StopwatchActive) clock.StartStopwatch();
                else clock.StartTimer(TimeSpan.FromMinutes(5));
            });
            buttons.Children.Add(playButton);
            var reset = RoundButton("xmark", L, () => { if (clock.Ringing != null) clock.StopRinging(); else if (clock.TimerActive) clock.CancelTimer(); else clock.ResetStopwatch(); });
            reset.Margin = new Thickness(0, 0, 6, 0);
            buttons.Children.Add(reset);
            var extra = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var minutes in st.Size == "m" ? new[] { 1, 5, 15, 25 } : new[] { 5 })
            {
                var chip = new Border { CornerRadius = new CornerRadius(17), Height = 34, Padding = new Thickness(11, 0, 11, 0), Background = L.Faint, Margin = new Thickness(0, 0, 6, 0) };
                var text = T(minutes + " мин", 12, FontWeights.SemiBold, L.Fg);
                text.VerticalAlignment = VerticalAlignment.Center;
                chip.Child = text;
                int m = minutes;
                extra.Children.Add(Click(chip, () => clock.StartTimer(TimeSpan.FromMinutes(m))));
            }
            if (st.Size == "m")
            {
                var sw = new Border { CornerRadius = new CornerRadius(17), Height = 34, Padding = new Thickness(11, 0, 11, 0), Background = L.Faint };
                var swText = T("Секундомер", 12, FontWeights.SemiBold, L.Fg);
                swText.VerticalAlignment = VerticalAlignment.Center;
                sw.Child = swText;
                extra.Children.Add(Click(sw, () => { if (!clock.TimerActive) clock.StartStopwatch(); }));
            }
            buttons.Children.Add(extra);
            root.Children.Add(buttons);
            void Update()
            {
                bool idle = !clock.TimerActive && !clock.StopwatchActive && clock.Ringing == null;
                extra.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
                reset.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
                if (clock.Ringing != null) { label.Text = clock.Ringing.ToUpperInvariant(); time.Text = "Готово"; setBar(1); playGlyph.Icon = "play"; }
                else if (clock.TimerActive)
                {
                    label.Text = clock.TimerPaused ? "ТАЙМЕР · ПАУЗА" : "ТАЙМЕР";
                    time.Text = ClockService.Format(clock.TimerLeft);
                    setBar(clock.TimerTotal.TotalSeconds > 0 ? 1 - clock.TimerLeft.TotalSeconds / clock.TimerTotal.TotalSeconds : 0);
                    playGlyph.Icon = clock.TimerPaused ? "play" : "pause";
                }
                else if (clock.StopwatchActive)
                {
                    label.Text = clock.StopwatchRunning ? "СЕКУНДОМЕР" : "СЕКУНДОМЕР · ПАУЗА";
                    time.Text = ClockService.Format(clock.StopwatchTime);
                    setBar(0);
                    playGlyph.Icon = clock.StopwatchRunning ? "pause" : "play";
                }
                else { label.Text = "ТАЙМЕР"; time.Text = "5:00"; setBar(0); playGlyph.Icon = "play"; }
            }
            return (root, Update);
        }

        // ---- 7. Будильник ----

        private static (FrameworkElement, Action) Alarms(WidgetState st, Look L)
        {
            var root = Pad();
            root.Children.Add(Header("bell", "Будильник", L));
            var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
            var time = T("—", 40, FontWeights.SemiBold, L.Fg, true);
            var label = T("", 12, FontWeights.SemiBold, L.Fg);
            var left = T("", 11.5, FontWeights.Medium, L.Fg2);
            stack.Children.Add(time); stack.Children.Add(label); stack.Children.Add(left);
            root.Children.Add(stack);
            void Update()
            {
                var now = DateTime.Now;
                var next = Settings.Current.Alarms.Where(a => a.On).Select(a =>
                {
                    var parts = a.Time.Split(':');
                    var at = now.Date.AddHours(int.Parse(parts[0])).AddMinutes(int.Parse(parts[1]));
                    if (at <= now) at = at.AddDays(1);
                    return (Alarm: a, At: at);
                }).OrderBy(x => x.At).FirstOrDefault();
                if (next.Alarm == null) { time.Text = "—"; label.Text = "Нет будильников"; left.Text = "Добавь в «Часах»"; return; }
                time.Text = next.Alarm.Time;
                label.Text = string.IsNullOrWhiteSpace(next.Alarm.Label) ? "Будильник" : next.Alarm.Label;
                left.Text = "через " + Hm(next.At - now);
            }
            return (root, Update);
        }

        // ---- 8. Статистика ----

        private static (FrameworkElement, Action) Stats(WidgetState st, Look L)
        {
            var stats = App.Current.Stats;
            var root = Pad();
            root.Children.Add(Header("chart", "Сегодня", L));
            var active = T("", 22, FontWeights.Bold, L.Fg, true);
            var music = T("", 22, FontWeights.Bold, L.Fg, true);
            var left = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
            left.Children.Add(active); left.Children.Add(Caption("за компьютером", L));
            var mid = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(128, 0, 0, 0) };
            mid.Children.Add(music); mid.Children.Add(Caption("музыка", L));
            root.Children.Add(left); root.Children.Add(mid);
            var bars = new Grid { Width = 92, Height = 86, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
            root.Children.Add(bars);
            string key = "";
            void Update()
            {
                var today = stats.Today;
                active.Text = StatsService.Duration(today.ActiveSeconds).Replace("меньше минуты", "0 мин");
                music.Text = StatsService.Duration(today.MusicSeconds).Replace("меньше минуты", "0 мин");
                var week = stats.Week;
                var k = string.Join(",", week.Select(d => (int)(d.ActiveSeconds / 300)));
                if (k == key) return;
                key = k;
                bars.Children.Clear();
                bars.ColumnDefinitions.Clear();
                double peak = Math.Max(3600, week.Max(d => d.ActiveSeconds));
                for (int i = 0; i < week.Count; i++)
                {
                    bars.ColumnDefinitions.Add(new ColumnDefinition());
                    var column = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center };
                    bool isToday = i == week.Count - 1;
                    column.Children.Add(new Border { Width = 7, Height = Math.Max(3, 66 * week[i].ActiveSeconds / peak), CornerRadius = new CornerRadius(3.5), Background = isToday ? L.Accent : L.Faint });
                    var name = T(StatsService.Weekday(week[i].Day), 8, isToday ? FontWeights.Bold : FontWeights.Medium, L.Fg2);
                    name.HorizontalAlignment = HorizontalAlignment.Center;
                    name.Margin = new Thickness(0, 3, 0, 0);
                    column.Children.Add(name);
                    Grid.SetColumn(column, i);
                    bars.Children.Add(column);
                }
            }
            return (root, Update);
        }

        // ---- 9. Отдых для глаз ----

        private static (FrameworkElement, Action) Eyes(WidgetState st, Look L)
        {
            var root = Pad();
            var (ring, setRing) = Ring(104, 9, L);
            ring.VerticalAlignment = VerticalAlignment.Top;
            var middle = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            var minutes = T("", 26, FontWeights.Bold, L.Fg, true);
            minutes.HorizontalAlignment = HorizontalAlignment.Center;
            var unit = T("мин", 10.5, FontWeights.SemiBold, L.Fg2);
            unit.HorizontalAlignment = HorizontalAlignment.Center;
            middle.Children.Add(minutes); middle.Children.Add(unit);
            ring.Children.Add(middle);
            root.Children.Add(ring);
            var note = T("", 11, FontWeights.SemiBold, L.Fg2);
            note.VerticalAlignment = VerticalAlignment.Bottom;
            note.HorizontalAlignment = HorizontalAlignment.Center;
            root.Children.Add(note);
            void Update()
            {
                var s = Settings.Current;
                if (!s.EyeBreak) { minutes.Text = "—"; unit.Text = "выкл"; setRing(0); note.Text = "Отдых для глаз выключен"; return; }
                double worked = App.Current.EyeBreak.WorkedMinutes, total = s.EyeBreakMinutes;
                minutes.Text = Math.Max(0, (int)Math.Ceiling(total - worked)).ToString();
                unit.Text = "мин";
                setRing(worked / total);
                int done = App.Current.Stats.Today.EyeBreaks;
                note.Text = "Сегодня: " + done + " " + StatsService.Plural(done, "перерыв", "перерыва", "перерывов");
            }
            return (root, Update);
        }

        // ---- 10. Батарея ----

        private static (FrameworkElement, Action) Battery(WidgetState st, Look L)
        {
            var root = Pad();
            var green = new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59));
            var (ring, setRing) = Ring(104, 9, L, green);
            ring.VerticalAlignment = VerticalAlignment.Top;
            var percent = T("", 26, FontWeights.Bold, L.Fg, true);
            percent.HorizontalAlignment = HorizontalAlignment.Center;
            percent.VerticalAlignment = VerticalAlignment.Center;
            ring.Children.Add(percent);
            root.Children.Add(ring);
            var note = T("", 11, FontWeights.SemiBold, L.Fg2);
            note.VerticalAlignment = VerticalAlignment.Bottom;
            note.HorizontalAlignment = HorizontalAlignment.Center;
            root.Children.Add(note);
            void Update()
            {
                var power = System.Windows.Forms.SystemInformation.PowerStatus;
                if (power.BatteryChargeStatus.HasFlag(System.Windows.Forms.BatteryChargeStatus.NoSystemBattery) || power.BatteryLifePercent > 1)
                {
                    percent.Text = "⚡"; setRing(1); note.Text = "От сети, батареи нет"; return;
                }
                percent.Text = (int)Math.Round(power.BatteryLifePercent * 100) + "%";
                setRing(power.BatteryLifePercent);
                bool plugged = power.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online;
                note.Text = plugged ? "Заряжается" : power.BatteryLifeRemaining > 0 ? "Хватит на " + Hm(TimeSpan.FromSeconds(power.BatteryLifeRemaining)) : "От батареи";
            }
            return (root, Update);
        }

        // ---- 11. Нагрузка ----

        private static Polyline Spark(Brush brush) => new Polyline { Stroke = brush, StrokeThickness = 1.8, StrokeLineJoin = PenLineJoin.Round, Height = 26, Stretch = Stretch.None };

        private static void Draw(Polyline line, List<double> values, double width)
        {
            var points = new PointCollection();
            for (int i = 0; i < values.Count; i++) points.Add(new Point(width * i / 39.0, 24 - 22 * Math.Clamp(values[i], 0, 1) + 1));
            line.Points = points;
        }

        private static (FrameworkElement, Action) Load(WidgetState st, Look L)
        {
            bool wide = st.Size == "m";
            var root = Pad();
            double width = wide ? 150 : 136;
            FrameworkElement Block(string title, out TextBlock value, out Polyline line, out TextBlock note, Brush brush)
            {
                var stack = new StackPanel { Width = width };
                stack.Children.Add(Caption(title, L));
                value = T("", wide ? 26 : 20, FontWeights.Bold, L.Fg, true);
                stack.Children.Add(value);
                line = Spark(brush);
                stack.Children.Add(line);
                note = T("", 10.5, FontWeights.Medium, L.Fg2);
                if (wide) stack.Children.Add(note);
                return stack;
            }
            var pink = new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x8E));
            var cpu = Block("Процессор", out var cpuValue, out var cpuLine, out var cpuNote, L.Accent);
            var mem = Block("Память", out var memValue, out var memLine, out var memNote, pink);
            if (wide) { cpu.HorizontalAlignment = HorizontalAlignment.Left; mem.HorizontalAlignment = HorizontalAlignment.Right; root.Children.Add(cpu); root.Children.Add(mem); }
            else
            {
                var both = new StackPanel();
                ((StackPanel)cpu).Margin = new Thickness(0, 0, 0, 2);
                both.Children.Add(cpu); both.Children.Add(mem);
                root.Children.Add(both);
            }
            void Update()
            {
                double c = Meters.Cpu();
                var m = Meters.Memory();
                cpuValue.Text = (int)Math.Round(c * 100) + " %";
                memValue.Text = (int)Math.Round(m.Used * 100) + " %";
                cpuNote.Text = Environment.ProcessorCount + " потоков";
                memNote.Text = m.UsedGb.ToString("0.0", Ru) + " из " + m.TotalGb.ToString("0", Ru) + " ГБ";
                Draw(cpuLine, Meters.CpuHistory, width);
                Draw(memLine, Meters.MemoryHistory, width);
            }
            return (root, Update);
        }

        // ---- 12. Диски ----

        private static (FrameworkElement, Action) Disks(WidgetState st, Look L)
        {
            var root = Pad();
            var stack = new StackPanel();
            stack.Children.Add(Header("display", "Диски", L));
            var list = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
            stack.Children.Add(list);
            root.Children.Add(stack);
            DateTime at = DateTime.MinValue;
            void Update()
            {
                if ((DateTime.Now - at).TotalSeconds < 30) return;
                at = DateTime.Now;
                list.Children.Clear();
                try
                {
                    foreach (var drive in DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady).Take(3))
                    {
                        double total = drive.TotalSize, free = drive.AvailableFreeSpace;
                        var row = new Grid { Margin = new Thickness(0, 0, 0, 3) };
                        row.Children.Add(T(drive.Name.TrimEnd('\\'), 13, FontWeights.Bold, L.Fg));
                        var info = T("свободно " + SteamService.Size((long)free), 11, FontWeights.Medium, L.Fg2);
                        info.HorizontalAlignment = HorizontalAlignment.Right;
                        info.VerticalAlignment = VerticalAlignment.Bottom;
                        row.Children.Add(info);
                        list.Children.Add(row);
                        double used = total > 0 ? 1 - free / total : 0;
                        var (bar, set) = Bar(L, 5, used > 0.9 ? new SolidColorBrush(Color.FromRgb(0xFF, 0x45, 0x3A)) : null);
                        bar.Margin = new Thickness(0, 0, 0, 9);
                        set(used);
                        list.Children.Add(bar);
                    }
                }
                catch { }
            }
            return (root, Update);
        }

        // ---- 13. Сеть ----

        private static (FrameworkElement, Action) Network(WidgetState st, Look L)
        {
            var root = Pad();
            root.Children.Add(Header("arrow.down", "Сеть", L));
            var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
            var down = T("", 24, FontWeights.Bold, L.Fg, true);
            var up = T("", 24, FontWeights.Bold, L.Fg, true);
            stack.Children.Add(Caption("↓ загрузка", L)); stack.Children.Add(down);
            var upCaption = Caption("↑ отдача", L);
            upCaption.Margin = new Thickness(0, 6, 0, 0);
            stack.Children.Add(upCaption); stack.Children.Add(up);
            root.Children.Add(stack);
            return (root, () =>
            {
                var (d, u) = Meters.Network();
                down.Text = SteamService.Rate(d);
                up.Text = SteamService.Rate(u);
            });
        }

        // ---- 14. Steam ----

        private static (FrameworkElement, Action) Steam(WidgetState st, Look L)
        {
            var root = Pad();
            var top = new StackPanel();
            top.Children.Add(Header("arrow.down", "Steam", L));
            var name = T("", 16, FontWeights.Bold, L.Fg, true);
            name.Margin = new Thickness(0, 6, 0, 0);
            top.Children.Add(name);
            var state = T("", 12, FontWeights.Medium, L.Fg2);
            top.Children.Add(state);
            root.Children.Add(top);
            var bottom = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
            var figures = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            var speed = T("", 20, FontWeights.Bold, L.Fg, true);
            var left = T("", 12.5, FontWeights.SemiBold, L.Fg2);
            left.HorizontalAlignment = HorizontalAlignment.Right;
            left.VerticalAlignment = VerticalAlignment.Bottom;
            figures.Children.Add(speed); figures.Children.Add(left);
            bottom.Children.Add(figures);
            var (bar, setBar) = Bar(L, 6);
            bottom.Children.Add(bar);
            root.Children.Add(bottom);
            void Update()
            {
                var d = App.Current.Steam.Current;
                if (d == null)
                {
                    name.Text = "Нет загрузок"; state.Text = Settings.Current.SteamActivity ? "Появится, когда Steam начнёт качать" : "Выключено в «Уведомлениях»";
                    speed.Text = ""; left.Text = ""; setBar(0);
                    return;
                }
                name.Text = d.Name;
                state.Text = (d.Installing ? "Установка" : d.Paused ? "Пауза" : (int)Math.Floor(d.Progress * 100) + " %") +
                             (d.Total > 0 ? " · " + SteamService.Size(d.Done) + " из " + SteamService.Size(d.Total) : "");
                speed.Text = d.Installing ? SteamService.Rate(d.Disk) : SteamService.Rate(d.Speed);
                left.Text = d.Left is { } t ? "осталось " + ClockService.Format(t) : "";
                setBar(d.Progress);
            }
            return (root, Update);
        }

        // ---- 15. Заметка ----

        private static TextBox Editor(Look L, double size) => new TextBox
        {
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = L.Fg, CaretBrush = L.Fg, FontSize = size,
            SelectionBrush = L.Accent, Padding = new Thickness(0)
        };

        private static (FrameworkElement, Action) Note(WidgetState st, Look L)
        {
            var root = Pad();
            var box = Editor(L, st.Size == "s" ? 13 : 14.5);
            box.AcceptsReturn = true;
            box.TextWrapping = TextWrapping.Wrap;
            box.VerticalScrollBarVisibility = ScrollBarVisibility.Hidden;
            box.Text = st.Text;
            var hint = T("Заметка…", box.FontSize, FontWeights.Normal, L.Fg2);
            hint.IsHitTestVisible = false;
            hint.Margin = new Thickness(2, 0, 0, 0);
            hint.Visibility = st.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            box.TextChanged += (_, _) =>
            {
                st.Text = box.Text;
                hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
                Settings.Current.SaveSoon();
            };
            root.Children.Add(box);
            root.Children.Add(hint);
            return (root, () => { });
        }

        // ---- 16. Список дел ----  (one line each; «[x] » in front means done)

        private static (FrameworkElement, Action) Todo(WidgetState st, Look L, WidgetWindow? w)
        {
            var root = Pad();
            var dock = new DockPanel();
            var head = Header("checkmark", "Дела", L);
            DockPanel.SetDock(head, Dock.Top);
            dock.Children.Add(head);
            var add = Editor(L, 12.5);
            var addHost = new Border { CornerRadius = new CornerRadius(9), Background = L.Faint, Padding = new Thickness(8, 5, 8, 5), Margin = new Thickness(0, 6, 0, 0) };
            var addGrid = new Grid();
            var hint = T("Новое дело и Enter", 12.5, FontWeights.Normal, L.Fg2);
            hint.IsHitTestVisible = false;
            addGrid.Children.Add(add); addGrid.Children.Add(hint);
            addHost.Child = addGrid;
            DockPanel.SetDock(addHost, Dock.Bottom);
            dock.Children.Add(addHost);
            var list = new StackPanel { Margin = new Thickness(0, 7, 0, 0) };
            dock.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Content = list });
            root.Children.Add(dock);

            List<string> Lines() => st.Text.Split('\n').Select(x => x.TrimEnd('\r')).Where(x => x.Trim().Length > 0).ToList();
            void Store(List<string> lines) { st.Text = string.Join("\n", lines); Settings.Current.SaveSoon(); Fill(); }
            void Fill()
            {
                list.Children.Clear();
                var lines = Lines();
                for (int i = 0; i < lines.Count; i++)
                {
                    int index = i;
                    bool done = lines[i].StartsWith("[x] ");
                    var text = done ? lines[i].Substring(4) : lines[i];
                    var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6), Background = Brushes.Transparent };
                    var box = new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1.5), BorderBrush = done ? L.Accent : L.Fg2, Background = done ? L.Accent : Brushes.Transparent, Margin = new Thickness(0, 1, 8, 0), VerticalAlignment = VerticalAlignment.Top };
                    if (done) box.Child = Icon("checkmark", 9, L.AccentColor == Colors.White ? new SolidColorBrush(Color.FromRgb(0x1C, 0x1C, 0x1E)) : Brushes.White);
                    row.Children.Add(box);
                    var remove = Click(new Border { Width = 16, Height = 16, Background = Brushes.Transparent, Child = Icon("xmark", 8, L.Fg2), ToolTip = "Убрать" },
                                       () => { var l = Lines(); if (index < l.Count) { l.RemoveAt(index); Store(l); } });
                    DockPanel.SetDock(remove, Dock.Right);
                    row.Children.Add(remove);
                    var label = T(text, 13, FontWeights.Medium, done ? L.Fg2 : L.Fg);
                    label.TextWrapping = TextWrapping.Wrap;
                    if (done) label.TextDecorations = TextDecorations.Strikethrough;
                    row.Children.Add(label);
                    Click(row, () =>
                    {
                        var l = Lines();
                        if (index >= l.Count) return;
                        l[index] = l[index].StartsWith("[x] ") ? l[index].Substring(4) : "[x] " + l[index];
                        Store(l);
                    });
                    list.Children.Add(row);
                }
            }
            add.TextChanged += (_, _) => hint.Visibility = add.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            add.KeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter) return;
                var text = add.Text.Trim();
                if (text.Length == 0) return;
                var l = Lines();
                l.Add(text.Length > 120 ? text.Substring(0, 120) : text);
                add.Text = "";
                Store(l);
                e.Handled = true;
            };
            Fill();
            return (root, () => { });
        }

        // ---- 17. Погода ----

        private static (FrameworkElement, Action) Weather(WidgetState st, Look L)
        {
            var root = Pad();
            var left = new StackPanel();
            var city = Caption("Погода", L);
            var temp = T("", 44, FontWeights.SemiBold, L.Fg, true);
            temp.Margin = new Thickness(0, -2, 0, -4);
            var text = T("", 13, FontWeights.SemiBold, L.Fg2);
            text.TextWrapping = TextWrapping.Wrap;
            left.Children.Add(city); left.Children.Add(temp); left.Children.Add(text);
            root.Children.Add(left);
            var symbol = new TextBlock { FontSize = 30, Foreground = L.Accent, FontFamily = new FontFamily("Segoe UI Symbol, Segoe UI Emoji"), HorizontalAlignment = st.Size == "m" ? HorizontalAlignment.Left : HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = st.Size == "m" ? new Thickness(0) : new Thickness(0, 0, 0, -4) };
            root.Children.Add(symbol);
            var days = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Visibility = st.Size == "m" ? Visibility.Visible : Visibility.Collapsed };
            root.Children.Add(days);
            string key = "?";
            void Update()
            {
                Online.NeedWeather();
                var now = Online.Weather;
                var k = now == null ? Online.WeatherNote : now.City + now.Temp + now.Text + now.Days.Count;
                if (k == key) return;
                key = k;
                if (now == null) { city.Text = "ПОГОДА"; temp.Text = "—"; text.Text = Online.WeatherNote; symbol.Text = ""; days.Children.Clear(); return; }
                city.Text = now.City.ToUpperInvariant();
                temp.Text = (now.Temp > 0 ? "+" : "") + now.Temp + "°";
                text.Text = now.Text;
                symbol.Text = now.Symbol;
                days.Children.Clear();
                foreach (var day in now.Days)
                {
                    var column = new StackPanel { Width = 50 };
                    TextBlock Center(TextBlock t) { t.HorizontalAlignment = HorizontalAlignment.Center; return t; }
                    column.Children.Add(Center(Caption(day.Name, L)));
                    column.Children.Add(Center(new TextBlock { Text = day.Symbol, FontSize = 20, Foreground = L.Fg, FontFamily = new FontFamily("Segoe UI Symbol, Segoe UI Emoji"), Margin = new Thickness(0, 4, 0, 4) }));
                    column.Children.Add(Center(T((day.Max > 0 ? "+" : "") + day.Max + "°", 13, FontWeights.Bold, L.Fg)));
                    column.Children.Add(Center(T((day.Min > 0 ? "+" : "") + day.Min + "°", 11.5, FontWeights.Medium, L.Fg2)));
                    days.Children.Add(column);
                }
            }
            return (root, Update);
        }

        // ---- 18. Курсы валют ----

        private static (FrameworkElement, Action) Currency(WidgetState st, Look L)
        {
            var root = Pad();
            var stack = new StackPanel();
            stack.Children.Add(Header("chart", "Курс ЦБ", L));
            var list = new StackPanel { Margin = new Thickness(0, 9, 0, 0) };
            stack.Children.Add(list);
            root.Children.Add(stack);
            string key = "?";
            void Update()
            {
                Online.NeedRates();
                var rates = Online.Rates;
                var k = rates.Count == 0 ? Online.RatesNote : string.Join("|", rates.Select(r => r.Code + r.Value.ToString("0.00")));
                if (k == key) return;
                key = k;
                list.Children.Clear();
                if (rates.Count == 0) { list.Children.Add(T(Online.RatesNote, 12, FontWeights.Medium, L.Fg2)); return; }
                foreach (var rate in rates)
                {
                    var row = new Grid { Margin = new Thickness(0, 0, 0, 9) };
                    row.Children.Add(T(rate.Code, 13, FontWeights.Bold, L.Fg2));
                    var value = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                    value.Children.Add(T(rate.Value.ToString("0.00", Ru) + " ₽", 15, FontWeights.Bold, L.Fg, true));
                    var change = T(rate.Change >= 0 ? " ▲" : " ▼", 9, FontWeights.Bold,
                                   new SolidColorBrush(rate.Change >= 0 ? Color.FromRgb(0x34, 0xC7, 0x59) : Color.FromRgb(0xFF, 0x45, 0x3A)));
                    change.VerticalAlignment = VerticalAlignment.Center;
                    value.Children.Add(change);
                    row.Children.Add(value);
                    list.Children.Add(row);
                }
            }
            return (root, Update);
        }
    }
}
