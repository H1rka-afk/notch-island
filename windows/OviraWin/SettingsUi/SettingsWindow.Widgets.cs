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
            // 0.6.1: the editor — your desktop with the grid and the gallery.
            var open = new Button { Content = "Добавить виджеты", Style = (Style)FindResource("MacButton"), FontWeight = FontWeights.SemiBold, Padding = new Thickness(18, 6, 18, 6) };
            open.Click += (_, _) => WidgetEditor.Open();
            var editor = Group("Рабочий стол", "Откроется твой рабочий стол с сеткой, на весь экран. Справа — все виджеты: нажми на размер или перетащи на стол. Виджеты на столе покачиваются, как на iPhone, — их можно двигать по сетке, нажать для смены размера или убрать минусом. «Готово» сохраняет, Esc отменяет.",
                Row("Расставить виджеты", "Сетка, перетаскивание и галерея", open),
                ToggleRow("Сетка и прилипание", "Виджеты прилипают к ячейкам, краям экрана и друг к другу", nameof(Settings.WidgetsSnap), "сетка прилипание выравнивание магнит виджеты"));
            page.Children.Add(editor);
            Remember("Добавить виджеты", "добавить виджеты рабочий стол сетка галерея расставить", editor);

            page.Children.Add(Group("Вид", "«Стекло» — полупрозрачная тёмная карточка, сквозь которую видны обои. «Цвета темы» — градиент выбранной темы настроек. «Белый» — светлая карточка с тёмным текстом. «Монолит» — сплошная тёмная, как тёмные виджеты на iPhone.",
                SegmentRow("Фон виджетов", null, new (string, object)[] { ("Стекло", "glass"), ("Цвета темы", "theme"), ("Белый", "white"), ("Монолит", "mono") },
                           nameof(Settings.WidgetStyle), "фон виджетов стекло стеклянный тема белый монолит"),
                ToggleRow("Закрепить на месте", "Виджеты нельзя случайно сдвинуть", nameof(Settings.WidgetsLocked), "закрепить виджеты перетаскивание")));

            var list = new StackPanel();
            void Fill()
            {
                list.Children.Clear();
                bool first = true;
                foreach (var kind in WidgetCatalog.All)
                {
                    if (!first) list.Children.Add(new Border { Style = (Style)FindResource("RowDivider") });
                    first = false;
                    int count = WidgetManager.Count(kind.Id);
                    var buttons = new StackPanel { Orientation = Orientation.Horizontal };
                    if (count > 0)
                    {
                        var remove = new Button { Content = "Убрать", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 6, 0) };
                        remove.Click += (_, _) =>
                        {
                            var last = S.Widgets.LastOrDefault(w => w.Kind == kind.Id);
                            if (last != null) WidgetManager.Remove(last.Id);
                            Fill();
                        };
                        buttons.Children.Add(remove);
                    }
                    var add = new Button { Content = count == 0 ? "Добавить" : "Ещё один", Style = (Style)FindResource("MacButton"), FontWeight = count == 0 ? FontWeights.SemiBold : FontWeights.Normal };
                    add.Click += (_, _) => { WidgetManager.Add(kind.Id); Fill(); };
                    buttons.Children.Add(add);
                    var sizes = string.Join(", ", kind.Sizes.Select(WidgetCatalog.SizeName)).ToLowerInvariant();
                    var row = Row(kind.Title, kind.About + " · " + sizes + (count > 0 ? " · на столе: " + count : ""), buttons);
                    list.Children.Add(row);
                }
            }
            if (!_collecting) Fill();
            var catalog = Group("Виджеты", "Виджет появляется на рабочем столе справа — перетащи его куда нужно. Правый клик по виджету: размер, «Убрать», а у часов — стрелочные. Виджеты лежат под окнами и не перекрывают программы; в игре на весь экран они не рисуются. По Win+D (показать рабочий стол) Windows прячет их вместе с остальными окнами — они вернутся, когда снова откроешь любое окно.",
                list);
            page.Children.Add(catalog);
            Remember("Виджеты на рабочий стол", "виджеты рабочий стол добавить часы погода заметка музыка батарея календарь", catalog);

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
