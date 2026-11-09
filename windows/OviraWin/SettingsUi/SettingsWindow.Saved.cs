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
