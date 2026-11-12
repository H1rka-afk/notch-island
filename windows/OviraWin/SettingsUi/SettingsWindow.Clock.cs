using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Ovira.Core;
using Ovira.Services;

namespace Ovira.SettingsUi
{
    // 0.5.0 — «Часы»: timer, stopwatch and alarms. While they run, the
    // island shows them; this page starts and stops them.
    public partial class SettingsWindow
    {
        private readonly DispatcherTimer _clockUi = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        private Action? _clockRefresh;

        private ClockService Clock => App.Current.Clock;

        private void BuildClockPage(StackPanel page)
        {
            // ---- timer ----
            var presets = new WrapPanel();
            foreach (var minutes in new[] { 1, 3, 5, 10, 15, 25, 30, 60 })
            {
                var b = new Button { Content = minutes < 60 ? minutes + " мин" : "1 ч", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 6, 6) };
                b.Click += (_, _) => Clock.StartTimer(TimeSpan.FromMinutes(minutes));
                presets.Children.Add(b);
            }
            var presetBox = new Border { Padding = new Thickness(14, 10, 8, 6), Child = presets };

            var custom = new TextBox { Style = (Style)FindResource("Field"), Tag = "Минуты, например 7 или 1:30", Width = 210 };
            var go = new Button { Content = "Старт", Style = (Style)FindResource("MacButton"), Margin = new Thickness(8, 0, 0, 0) };
            go.Click += (_, _) =>
            {
                var length = ParseLength(custom.Text);
                if (length > TimeSpan.Zero) { Clock.StartTimer(length); custom.Text = ""; }
            };
            var customRow = new StackPanel { Orientation = Orientation.Horizontal };
            customRow.Children.Add(custom);
            customRow.Children.Add(go);

            var timerPause = new Button { Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 6, 0) };
            timerPause.Click += (_, _) => { if (Clock.TimerPaused) Clock.ResumeTimer(); else Clock.PauseTimer(); };
            var timerCancel = new Button { Content = "Сбросить", Style = (Style)FindResource("MacButton") };
            timerCancel.Click += (_, _) => Clock.CancelTimer();
            var timerButtons = new StackPanel { Orientation = Orientation.Horizontal };
            timerButtons.Children.Add(timerPause);
            timerButtons.Children.Add(timerCancel);
            var timerStatus = (Grid)Row("Сейчас", " ", timerButtons);
            var timerText = timerStatus.Children.OfType<StackPanel>().First().Children.OfType<TextBlock>().Last();

            page.Children.Add(Group("Таймер", "Пока таймер идёт, островок показывает оставшееся время; нажми на островок — пауза и сброс. Когда время выйдет, прозвучит сигнал (до минуты, пока не остановишь).",
                presetBox, Row("Своё время", null, customRow), timerStatus));
            Remember("Таймер", "таймер минуты обратный отсчёт", page);

            // ---- stopwatch ----
            var swStart = new Button { Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 6, 0) };
            swStart.Click += (_, _) => { if (Clock.StopwatchRunning) Clock.PauseStopwatch(); else Clock.StartStopwatch(); };
            var swReset = new Button { Content = "Сбросить", Style = (Style)FindResource("MacButton") };
            swReset.Click += (_, _) => Clock.ResetStopwatch();
            var swButtons = new StackPanel { Orientation = Orientation.Horizontal };
            swButtons.Children.Add(swStart);
            swButtons.Children.Add(swReset);
            var swRow = (Grid)Row("Секундомер", " ", swButtons);
            var swText = swRow.Children.OfType<StackPanel>().First().Children.OfType<TextBlock>().Last();
            page.Children.Add(Group("Секундомер", "Время идёт и в островке — до десятых долей секунды в раскрытом виде.", swRow));
            Remember("Секундомер", "секундомер время круг", page);

            // ---- alarms ----
            var list = new StackPanel();
            void FillAlarms()
            {
                list.Children.Clear();
                if (S.Alarms.Count == 0) list.Children.Add(Row("Будильников нет", "Добавь ниже", new Border()));
                foreach (var alarm in S.Alarms.OrderBy(a => a.Time))
                {
                    var toggle = new CheckBox { Style = (Style)FindResource("MacSwitch"), IsChecked = alarm.On };
                    var id = alarm.Id;
                    toggle.Click += (_, _) => S.Alarms = S.Alarms.Select(a => a.Id == id ? a.With(on: toggle.IsChecked == true) : a).ToList();
                    var trailing = new StackPanel { Orientation = Orientation.Horizontal };
                    trailing.Children.Add(IconButton("trash", "Удалить", () => { S.Alarms = S.Alarms.Where(a => a.Id != id).ToList(); FillAlarms(); }));
                    trailing.Children.Add(toggle);
                    var sub = (string.IsNullOrWhiteSpace(alarm.Label) ? "Будильник" : alarm.Label) + " · " + (alarm.Daily ? "каждый день" : "один раз");
                    var row = Row(alarm.Time, sub, trailing);
                    if (row.Children.OfType<StackPanel>().FirstOrDefault()?.Children.OfType<TextBlock>().FirstOrDefault() is TextBlock big)
                    { big.FontSize = 20; big.FontWeight = FontWeights.SemiBold; }
                    list.Children.Add(row);
                }
            }
            FillAlarms();
            var time = new TextBox { Style = (Style)FindResource("Field"), Tag = "07:30", Width = 80 };
            var label = new TextBox { Style = (Style)FindResource("Field"), Tag = "Подпись, необязательно", Width = 190, Margin = new Thickness(8, 0, 0, 0) };
            var daily = new CheckBox { Content = "Каждый день", IsChecked = true, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            daily.SetResourceReference(Control.ForegroundProperty, "Fg");
            var add = new Button { Content = "Добавить", Style = (Style)FindResource("MacButton"), Margin = new Thickness(10, 0, 0, 0) };
            var error = new TextBlock { Style = (Style)FindResource("RowSub"), Margin = new Thickness(14, 0, 14, 10) };
            add.Click += (_, _) =>
            {
                var m = Regex.Match(time.Text.Trim(), @"^(\d{1,2})[:.\s]?(\d{2})$");
                if (!m.Success || int.Parse(m.Groups[1].Value) > 23 || int.Parse(m.Groups[2].Value) > 59)
                {
                    error.Text = "Время как 07:30 или 7.30";
                    return;
                }
                error.Text = "";
                var hm = $"{int.Parse(m.Groups[1].Value):00}:{m.Groups[2].Value}";
                S.Alarms = S.Alarms.Append(new Alarm { Time = hm, Label = label.Text.Trim(), Daily = daily.IsChecked == true }).ToList();
                time.Text = label.Text = "";
                FillAlarms();
            };
            var form = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(14, 10, 14, 10) };
            form.Children.Add(time);
            form.Children.Add(label);
            form.Children.Add(daily);
            form.Children.Add(add);
            page.Children.Add(Group("Будильник", "Ovira должна быть запущена — будильник звучит из неё: островок раскроется со звонком, «Отложить» на 5 минут или «Стоп».",
                list, form, error));
            Remember("Будильник", "будильник время подъём утро", page);

            // ---- live texts ----
            void Refresh()
            {
                timerText.Text = Clock.Ringing == "Таймер" ? "Время вышло"
                               : Clock.TimerActive ? (Clock.TimerPaused ? "Пауза · " : "Осталось ") + ClockService.Format(Clock.TimerLeft)
                               : "Не запущен";
                timerPause.Content = Clock.TimerPaused ? "Продолжить" : "Пауза";
                timerPause.IsEnabled = timerCancel.IsEnabled = Clock.TimerActive;
                swText.Text = Clock.StopwatchActive ? ClockService.FormatPrecise(Clock.StopwatchTime) + (Clock.StopwatchRunning ? "" : " · пауза") : "00:00,0";
                swStart.Content = Clock.StopwatchRunning ? "Пауза" : Clock.StopwatchActive ? "Продолжить" : "Старт";
                swReset.IsEnabled = Clock.StopwatchActive;
            }
            Refresh();
            if (_collecting) return;
            _clockRefresh = Refresh;
            _clockUi.Tick -= OnClockUi;
            _clockUi.Tick += OnClockUi;
            _clockUi.Start();
        }

        private void OnClockUi(object? sender, EventArgs e)
        {
            if (_current?.Key != "clock") { _clockUi.Stop(); return; }
            _clockRefresh?.Invoke();
        }

        // «7», «7,5», «1:30» (minutes:seconds), «1:30:00».
        private static TimeSpan ParseLength(string text)
        {
            text = (text ?? "").Trim().Replace(',', '.');
            var parts = text.Split(':');
            try
            {
                if (parts.Length == 1 && double.TryParse(parts[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var min))
                    return TimeSpan.FromMinutes(Math.Clamp(min, 0, 24 * 60));
                if (parts.Length == 2) return new TimeSpan(0, int.Parse(parts[0]), int.Parse(parts[1]));
                if (parts.Length == 3) return new TimeSpan(int.Parse(parts[0]), int.Parse(parts[1]), int.Parse(parts[2]));
            }
            catch { }
            return TimeSpan.Zero;
        }
    }
}
