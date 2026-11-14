using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Ovira.Core;
using Ovira.Taskbar;

namespace Ovira.SettingsUi
{
    // 0.7.2 — «Панель задач»: on/off, the dock's background (small live
    // pictures to pick from), its main colour (theme, music or your own),
    // the Start icon and the magnification.
    public partial class SettingsWindow
    {
        private void BuildTaskbarGroups(StackPanel page)
        {
            page.Children.Add(Group("Панель задач", "Своя панель внизу экрана вместо панели Windows: «Пуск», поиск, закреплённые и открытые приложения с живыми миниатюрами окон, справа раскладка, звук, батарея и часы. Колёсико над звуком меняет громкость, средняя кнопка открывает новое окно, правая — меню. Панель Windows прячется, пока включена панель Ovira, и всегда возвращается. Значки системного трея (Discord, Steam) Windows чужим панелям не отдаёт — их видно, если выключить «Прятать панель Windows».",
                ToggleRow("Своя панель задач", "Док Ovira внизу основного экрана", nameof(Settings.TaskbarEnabled), "панель задач таскбар taskbar пуск снизу док"),
                ToggleRow("Прятать панель Windows", "Иначе док встанет над ней", nameof(Settings.TaskbarHideSystem), "прятать скрыть системная панель windows"),
                SegmentRow("Вид", "Док внизу или боковая панель у левого края", new (string, object)[] { ("Док", "dock"), ("Боковая", "side") },
                           nameof(Settings.TaskbarLayout), "вид панели задач док боковая слева вертикальная"),
                ToggleRow("Прятать боковую к краю", "Уезжает за левый край и выезжает, когда подводишь мышь", nameof(Settings.TaskbarSideHide), "прятать боковая панель автоскрытие край выезжает"),
                SegmentRow("Где значки", null, new (string, object)[] { ("По центру", "center"), ("Слева", "left") },
                           nameof(Settings.TaskbarAlign), "значки центр слева выравнивание панель задач"),
                SegmentRow("Размер", null, new (string, object)[] { ("Маленький", "small"), ("Средний", "medium"), ("Большой", "large") },
                           nameof(Settings.TaskbarSize), "размер панели задач маленький уменьшить док"),
                ToggleRow("Увеличение под курсором", "Значки растут, когда ведёшь по ним мышкой, как в Dock на Mac", nameof(Settings.TaskbarMagnify), "увеличение под курсором лупа рост значков док"),
                StartIconRow(),
                ToggleRow("Секунды в часах", null, nameof(Settings.TaskbarSeconds), "секунды часы панель задач")));

            page.Children.Add(Group("Вид панели задач", "Основной цвет красит кнопку «Пуск», полоску под открытым окном и фон «Цвет». «Обложка» берёт цвет играющей музыки, «Свой» — любой цвет. Фон «Обложка» кладёт под док размытую обложку песни.",
                BackgroundRow(),
                SegmentRow("Основной цвет", null, new (string, object)[] { ("Тема", "theme"), ("Обложка", "cover"), ("Свой", "custom") },
                           nameof(Settings.TaskbarColor), "основной цвет панели задач тема обложка свой акцент"),
                CustomColorRow()));
        }

        // The dock's background: a row of small pictures, one per style.
        private FrameworkElement BackgroundRow()
        {
            var wrap = new WrapPanel { Margin = new Thickness(16, 10, 10, 6) };
            var title = new TextBlock { Text = "Фон панели", Style = (Style)FindResource("RowTitle"), Margin = new Thickness(16, 10, 0, 0) };
            var stack = new StackPanel();
            stack.Children.Add(title);
            stack.Children.Add(wrap);
            var options = new (string label, string value)[] { ("Стекло", "glass"), ("Цвет", "theme"), ("Обложка", "cover"), ("Белый", "white"), ("Монолит", "mono"), ("Прозрачный", "clear") };
            void Fill()
            {
                wrap.Children.Clear();
                foreach (var (label, value) in options) wrap.Children.Add(StyleCard(label, value, S.TaskbarStyle == value));
            }
            Fill();
            System.ComponentModel.PropertyChangedEventHandler handler = (_, e) =>
            {
                if (e.PropertyName is nameof(Settings.TaskbarStyle) or nameof(Settings.TaskbarColor) or nameof(Settings.TaskbarCustomColor) or nameof(Settings.Theme)) Fill();
            };
            S.PropertyChanged += handler;
            stack.Unloaded += (_, _) => S.PropertyChanged -= handler;
            Remember("Фон панели", "фон панели задач стекло цвет обложка белый монолит прозрачный задний", stack);
            return stack;
        }

        private FrameworkElement StyleCard(string label, string value, bool selected)
        {
            var d = DockLook.For(value);
            var box = new StackPanel { Margin = new Thickness(0, 0, 10, 8), Cursor = Cursors.Hand };
            // a bit of «wallpaper» so glass and clear show what they are
            var scene = new Grid { Width = 96, Height = 52 };
            scene.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(12),
                Background = new LinearGradientBrush(Color.FromRgb(0x2B, 0x4C, 0xD8), Color.FromRgb(0x8E, 0x3B, 0xD9), new Point(0, 0), new Point(1, 1)),
            });
            var dock = new Grid { Width = 74, Height = 22, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 6) };
            if (value == "cover" && d.Art != null)
                dock.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = new ImageBrush(d.Art) { Stretch = Stretch.UniformToFill } });
            dock.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = d.Back, BorderBrush = d.Rim, BorderThickness = new Thickness(1) });
            var dots = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var first = new LinearGradientBrush(Themes.MixWhite(d.Main, 0.18), d.Palette.Length > 1 ? d.Palette[1] : d.Main, 45);
            for (int i = 0; i < 4; i++)
                dots.Children.Add(new Border { Width = 11, Height = 11, CornerRadius = new CornerRadius(3.5), Margin = new Thickness(2, 0, 2, 0), Background = i == 0 ? first : d.Fg is SolidColorBrush f && f.Color.R < 0x80 ? new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)) : new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)) });
            dock.Children.Add(dots);
            scene.Children.Add(dock);
            var ring = new Border { CornerRadius = new CornerRadius(14), Margin = new Thickness(-3), BorderThickness = new Thickness(2.5), BorderBrush = selected ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent };
            scene.Children.Add(ring);
            box.Children.Add(scene);
            var text = new TextBlock { Text = label, FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0), FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal };
            text.SetResourceReference(TextBlock.ForegroundProperty, selected ? "Fg" : "Fg2");
            box.Children.Add(text);
            box.MouseLeftButtonUp += (_, _) => S.TaskbarStyle = value;
            return box;
        }

        private FrameworkElement StartIconRow()
        {
            var stack = new StackPanel { Orientation = Orientation.Horizontal };
            void Fill()
            {
                stack.Children.Clear();
                var palette = DockLook.For(S.TaskbarStyle).Palette;
                foreach (var (kind, tip) in new[] { ("ovira", "Ovira"), ("tiles", "Плитки"), ("dots", "Точки") })
                {
                    bool on = S.TaskbarStartIcon == kind;
                    var cell = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(12), Margin = new Thickness(6, 0, 0, 0), Cursor = Cursors.Hand, ToolTip = tip, BorderThickness = new Thickness(2), BorderBrush = on ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : Brushes.Transparent };
                    cell.SetResourceReference(Border.BackgroundProperty, "FieldBg");
                    cell.Child = new StartGlyph { Kind = kind, Colours = palette, Width = 26, Height = 26 };
                    cell.MouseLeftButtonUp += (_, _) => S.TaskbarStartIcon = kind;
                    stack.Children.Add(cell);
                }
            }
            Fill();
            System.ComponentModel.PropertyChangedEventHandler handler = (_, e) =>
            {
                if (e.PropertyName is nameof(Settings.TaskbarStartIcon) or nameof(Settings.TaskbarColor) or nameof(Settings.TaskbarCustomColor) or nameof(Settings.Theme)) Fill();
            };
            S.PropertyChanged += handler;
            stack.Unloaded += (_, _) => S.PropertyChanged -= handler;
            var row = Row("Значок «Пуск»", "В основном цвете панели", stack);
            Remember("Значок «Пуск»", "значок пуск start виндовс windows иконка", row);
            return row;
        }

        // «Свой» colour: ready colours and a rainbow slider; shown only for «Свой».
        private FrameworkElement CustomColorRow()
        {
            var panel = new StackPanel { Margin = new Thickness(16, 4, 14, 12) };
            var dots = new WrapPanel();
            foreach (var argb in PaletteColors)
            {
                var c = C(argb);
                var dot = new Ellipse { Width = 22, Height = 22, Fill = new SolidColorBrush(c), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand, StrokeThickness = 1 };
                dot.SetResourceReference(Shape.StrokeProperty, "FieldBorder");
                dot.MouseLeftButtonUp += (_, _) => S.TaskbarCustomColor = Themes.ToHex(c);
                dots.Children.Add(dot);
            }
            panel.Children.Add(dots);

            var line = new Grid { Margin = new Thickness(0, 2, 0, 0) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var swatch = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Margin = new Thickness(0, 0, 12, 0), BorderThickness = new Thickness(1) };
            swatch.SetResourceReference(Border.BorderBrushProperty, "FieldBorder");
            line.Children.Add(swatch);
            var sliders = new StackPanel();
            Grid.SetColumn(sliders, 1);
            line.Children.Add(sliders);
            var hue = TaskbarSlider(sliders);
            var bri = TaskbarSlider(sliders);
            var rainbow = new GradientStopCollection();
            for (int i = 0; i <= 6; i++) rainbow.Add(new GradientStop(Themes.FromHsv(i / 6.0, 1, 1), i / 6.0));
            hue.Background = new LinearGradientBrush(rainbow, 0);
            panel.Children.Add(line);

            bool sync = false;
            void Show()
            {
                Color c;
                try { c = Themes.ParseHex(S.TaskbarCustomColor); } catch { c = Color.FromRgb(0x3D, 0x85, 0xFF); }
                swatch.Background = new SolidColorBrush(c);
                Themes.ToHsv(c, out var h, out var sat, out var v);
                sync = true;
                hue.Value = h;
                bri.Value = v;
                sync = false;
                bri.Background = new LinearGradientBrush(Colors.Black, Themes.FromHsv(h, Math.Max(sat, 0.6), 1), 0);
                panel.Visibility = S.TaskbarColor == "custom" ? Visibility.Visible : Visibility.Collapsed;
            }
            void FromSliders()
            {
                if (sync) return;
                Color old;
                try { old = Themes.ParseHex(S.TaskbarCustomColor); } catch { old = Color.FromRgb(0x3D, 0x85, 0xFF); }
                Themes.ToHsv(old, out _, out var sat, out _);
                S.TaskbarCustomColor = Themes.ToHex(Themes.FromHsv(hue.Value, Math.Max(sat, 0.55), Math.Max(bri.Value, 0.15)));
            }
            hue.ValueChanged += (_, _) => FromSliders();
            bri.ValueChanged += (_, _) => FromSliders();
            Show();
            System.ComponentModel.PropertyChangedEventHandler handler = (_, e) =>
            {
                if (e.PropertyName is nameof(Settings.TaskbarCustomColor) or nameof(Settings.TaskbarColor)) Show();
            };
            S.PropertyChanged += handler;
            panel.Unloaded += (_, _) => S.PropertyChanged -= handler;
            Remember("Свой цвет панели", "свой цвет панели задач палитра оттенок", panel);
            return panel;
        }

        private Slider TaskbarSlider(Panel host)
        {
            var slider = new Slider { Minimum = 0, Maximum = 1, Style = (Style)FindResource("GradientSlider"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 3, 0, 3) };
            host.Children.Add(slider);
            return slider;
        }
    }
}
