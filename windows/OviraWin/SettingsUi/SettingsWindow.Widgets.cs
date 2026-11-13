using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Ovira.Core;
using Ovira.Widgets;

namespace Ovira.SettingsUi
{
    // 0.6.0 — «Виджеты»: the background, what to put on the desktop, the
    // city for the weather.
    public partial class SettingsWindow
    {
        private void BuildWidgetsPage(StackPanel page)
        {
            // 0.7.0: Ovira's own taskbar.
            page.Children.Add(Group("Панель задач", "Своя панель внизу экрана вместо панели Windows: «Пуск», поиск, закреплённые и открытые приложения с живыми миниатюрами окон, раскладка, звук, батарея и часы. Колёсико над значком звука меняет громкость, средняя кнопка открывает новое окно, правая — меню приложения. Панель Windows прячется, пока включена панель Ovira, и всегда возвращается — при выключении, при выходе из Ovira и при следующем запуске, если Ovira закрылась аварийно. Значки из системного трея (Discord, Steam) Windows чужим панелям не отдаёт — их видно, если выключить «Прятать панель Windows».",
                ToggleRow("Своя панель задач", "Панель Ovira внизу основного экрана", nameof(Settings.TaskbarEnabled), "панель задач таскбар taskbar пуск снизу док"),
                ToggleRow("Прятать панель Windows", "Иначе панель Ovira встанет над ней", nameof(Settings.TaskbarHideSystem), "прятать скрыть системная панель windows"),
                SegmentRow("Значки", null, new (string, object)[] { ("По центру", "center"), ("Слева", "left") },
                           nameof(Settings.TaskbarAlign), "значки центр слева выравнивание панель задач"),
                SegmentRow("Фон панели", null, new (string, object)[] { ("Стекло", "glass"), ("Цвета темы", "theme"), ("Белый", "white"), ("Монолит", "mono") },
                           nameof(Settings.TaskbarStyle), "фон панели задач стекло тема белый монолит"),
                ToggleRow("Секунды в часах", null, nameof(Settings.TaskbarSeconds), "секунды часы панель задач")));

            // 0.6.1: the editor — your desktop with the grid and the gallery.
            var open = new Button { Content = "Добавить виджеты", Style = (Style)FindResource("MacButton"), FontWeight = FontWeights.SemiBold, Padding = new Thickness(18, 6, 18, 6) };
            open.Click += (_, _) => WidgetEditor.Open();
            var editor = Group("Рабочий стол", "Откроется твой рабочий стол с сеткой, на весь экран. Нажми на стрелочку у правого края — выедет вкладка со всеми виджетами: зажми размер и перетащи виджет на стол. Там же «Сетка и прилипание». Виджеты на столе покачиваются, как на iPhone, — их можно двигать, нажать для смены размера или убрать минусом. «Готово» сохраняет, Esc отменяет.",
                Row("Расставить виджеты", "Сетка, перетаскивание и вкладка с виджетами", open));
            page.Children.Add(editor);
            Remember("Добавить виджеты", "добавить виджеты рабочий стол сетка галерея расставить", editor);

            page.Children.Add(Group("Вид", "«Стекло» — полупрозрачная тёмная карточка, сквозь которую видны обои. «Цвета темы» — градиент выбранной темы настроек. «Белый» — светлая карточка с тёмным текстом. «Монолит» — сплошная тёмная, как тёмные виджеты на iPhone.",
                SegmentRow("Фон виджетов", null, new (string, object)[] { ("Стекло", "glass"), ("Цвета темы", "theme"), ("Белый", "white"), ("Монолит", "mono") },
                           nameof(Settings.WidgetStyle), "фон виджетов стекло стеклянный тема белый монолит")));

            var city = new TextBox { Style = (Style)FindResource("Field"), Tag = "Например, Москва", Width = 220, Text = S.WeatherCity };
            var save = new Button { Content = "Сохранить", Style = (Style)FindResource("MacButton"), Margin = new Thickness(8, 0, 0, 0) };
            save.Click += (_, _) => S.WeatherCity = city.Text.Trim();
            var cityRow = new StackPanel { Orientation = Orientation.Horizontal };
            cityRow.Children.Add(city);
            cityRow.Children.Add(save);
            page.Children.Add(Group("Погода и курсы", "Погода берётся у open-meteo.com, курсы — из ежедневной таблицы Банка России. Запросы идут, только пока такой виджет лежит на столе; отправляется только название города.",
                Row("Город для погоды", null, cityRow)));

            page.Children.Add(Group("Порядок", null,
                ButtonRow("Вернуть виджеты на место", "Все виджеты встанут справа на основном экране", "Сбросить положение", () => WidgetManager.ResetPositions(), "сбросить положение виджетов потерялся"),
                ButtonRow("Убрать все виджеты", "Заметки и списки дел в них тоже удалятся", "Убрать все", () =>
                {
                    var answer = MessageBox.Show(this, "Убрать все виджеты с рабочего стола? Тексты заметок и списков дел удалятся.", "Ovira", MessageBoxButton.OKCancel, MessageBoxImage.Question);
                    if (answer == MessageBoxResult.OK) { WidgetManager.RemoveAll(); if (_current?.Key == "widgets") Open(_current, animated: false); }
                }, "убрать удалить все виджеты")));
        }
    }
}
