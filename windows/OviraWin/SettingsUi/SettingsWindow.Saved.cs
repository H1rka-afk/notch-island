using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Ovira.Core;

namespace Ovira.SettingsUi
{
    // 0.4.14 — the songs saved with the star in the player.
    public partial class SettingsWindow
    {
        private StackPanel? _savedHost;

        private FrameworkElement SavedGroup()
        {
            _savedHost = new StackPanel();
            var group = Group("Сохранённые песни", "В Яндекс Музыке (приложение или вкладка music.yandex.ru) звёздочка ставит настоящее «Мне нравится» — Ovira находит кнопку в панели плеера через специальные возможности Windows. Для остальных плееров Windows такого не позволяет, поэтому песня сохраняется здесь; «Копировать» — чтобы найти её в своём плеере.", _savedHost);
            Remember("Сохранённые песни", "сохранённые песни избранное звезда список", group);
            FillSaved();
            return group;
        }

        // 0.4.17 — «Мне нравится» in Yandex Music: a check of what Ovira sees
        // in the Yandex Music window, and the optional account link.
        private FrameworkElement YandexGroup()
        {
            var checkText = new TextBlock { Style = (Style)FindResource("RowSub"), TextWrapping = TextWrapping.Wrap, Text = "Включи песню в Яндекс Музыке и нажми «Проверить»." };
            var check = new Button { Content = "Проверить", Style = (Style)FindResource("MacButton") };
            check.Click += async (_, _) =>
            {
                check.IsEnabled = false;
                checkText.Text = "Смотрю…";
                checkText.Text = await Ovira.Services.YandexFavorites.DiagnoseAsync(App.Current.Media.Track);
                check.IsEnabled = true;
            };
            var checkRow = Row("Кнопка в окне Яндекс Музыки", null, check);
            var checkBox = new StackPanel();
            checkBox.Children.Add(checkRow);
            checkBox.Children.Add(new Border { Padding = new Thickness(14, 0, 14, 12), Child = checkText });

            var accountHost = new StackPanel();
            void ShowAccount(bool form)
            {
                accountHost.Children.Clear();
                bool on = Ovira.Services.YandexAccount.Connected;
                var action = new Button { Content = on ? "Отключить" : form ? "Скрыть" : "Подключить…", Style = (Style)FindResource("MacButton") };
                action.Click += (_, _) =>
                {
                    if (on) { Ovira.Services.YandexAccount.Disconnect(); ShowAccount(false); }
                    else ShowAccount(!form);
                };
                accountHost.Children.Add(Row("Аккаунт Яндекса", on ? "Подключён — звёздочка меняет «Мне нравится» прямо в аккаунте" : "Необязательно: работает и без окна приложения, и в браузере", action));
                if (!on && form)
                {
                    var box = new StackPanel { Margin = new Thickness(14, 0, 14, 12) };
                    var secret = new PasswordBox { Height = 30, Padding = new Thickness(8, 5, 8, 5), BorderThickness = new Thickness(1), FontSize = 12.5 };
                    secret.SetResourceReference(Control.BackgroundProperty, "FieldBg");
                    secret.SetResourceReference(Control.ForegroundProperty, "Fg");
                    secret.SetResourceReference(Control.BorderBrushProperty, "FieldBorder");
                    secret.SetResourceReference(PasswordBox.CaretBrushProperty, "Fg");
                    var note = new TextBlock
                    {
                        Style = (Style)FindResource("RowSub"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(2, 8, 0, 8),
                        Text = "Вставь OAuth-токен Яндекса с доступом к Музыке — это не пароль, пароль не вводи. Токен хранится зашифрованным только на этом компьютере и уходит только в api.music.yandex.net. Никому его не присылай."
                    };
                    var status = new TextBlock { Style = (Style)FindResource("RowSub"), Margin = new Thickness(2, 6, 0, 0) };
                    var connect = new Button { Content = "Подключить", Style = (Style)FindResource("MacButton"), HorizontalAlignment = HorizontalAlignment.Right };
                    connect.Click += async (_, _) =>
                    {
                        connect.IsEnabled = false;
                        status.Text = "Проверяю у Яндекса…";
                        var ok = await Ovira.Services.YandexAccount.ConnectAsync(secret.Password);
                        secret.Clear();
                        connect.IsEnabled = true;
                        if (ok) ShowAccount(false);
                        else status.Text = "Не подошёл: Яндекс не принял токен. Он не сохранён.";
                    };
                    box.Children.Add(secret);
                    box.Children.Add(note);
                    box.Children.Add(connect);
                    box.Children.Add(status);
                    accountHost.Children.Add(box);
                    secret.Loaded += (_, _) => secret.Focus();
                }
            }
            ShowAccount(false);
            var group = Group("Яндекс Музыка — «Мне нравится»",
                "Звёздочка ставит настоящее «Мне нравится»: Ovira находит кнопку в панели плеера окна Яндекс Музыки через специальные возможности Windows. Если не выходит, «Проверить» покажет, что именно Ovira видит.",
                checkBox, accountHost);
            Remember("Яндекс Музыка — «Мне нравится»", "яндекс музыка нравится лайк избранное звезда токен аккаунт проверить", group);
            return group;
        }

        private void FillSaved()
        {
            if (_savedHost == null || _collecting) return;
            _savedHost.Children.Clear();
            var list = S.SavedTracks;
            if (list.Count == 0)
            {
                _savedHost.Children.Add(Row("Пока пусто", "Нажми на звёздочку в раскрытом плеере", new Border()));
                return;
            }
            bool first = true;
            foreach (var track in list.Take(50))
            {
                if (!first) _savedHost.Children.Add(new Border { Style = (Style)FindResource("RowDivider") });
                first = false;
                var buttons = new StackPanel { Orientation = Orientation.Horizontal };
                var copy = new Button { Content = "Копировать", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 6, 0) };
                copy.Click += (_, _) =>
                {
                    try { Clipboard.SetText(track.ToString()); copy.Content = "Скопировано"; } catch { }
                };
                buttons.Children.Add(copy);
                buttons.Children.Add(IconButton("trash", "Убрать", () => SavedTracks.Remove(track)));
                var when = track.Saved.ToString("d MMMM, HH:mm", new System.Globalization.CultureInfo("ru-RU"));
                var sub = string.IsNullOrWhiteSpace(track.Artist) ? when : track.Artist + " · " + when;
                if (!string.IsNullOrWhiteSpace(track.Source)) sub += " · " + track.Source;
                _savedHost.Children.Add(Row(track.Title, sub, buttons));
            }
        }
    }
}
