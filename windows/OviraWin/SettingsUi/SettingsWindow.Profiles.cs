using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Ovira.Core;

namespace Ovira.SettingsUi
{
    // 0.4.0 — profiles, as on the Mac: ready sets of features (Как на iPhone,
    // Тихий, Максимум, Свой) and the user's own named profiles, saved to and
    // opened from .notchprofile files.
    public partial class SettingsWindow
    {
        private StackPanel? _profilesHost;
        private bool _profilesPending;
        private bool _newProfileOpen;
        private string _newName = "", _newSummary = "";

        private sealed record PresetInfo(IslandProfile Profile, string Title, string Summary, string Icon, Color Colour);

        private static readonly PresetInfo[] Presets =
        {
            new(IslandProfile.Iphone, "Как на iPhone", "Музыка, зарядка и выбор звука — как Dynamic Island", "phone", Color.FromRgb(0x3D, 0x85, 0xFF)),
            new(IslandProfile.Quiet, "Тихий", "Только музыка, без баннеров", "moon", Color.FromRgb(0x5C, 0x59, 0xE6)),
            new(IslandProfile.Extended, "Максимум", "Всё, что умеет Ovira", "sparkles", Color.FromRgb(0xFF, 0x9F, 0x0A)),
            new(IslandProfile.Custom, "Свой", "Твой набор переключателей", "sliders", Color.FromRgb(0x34, 0xC7, 0x59)),
        };

        private FrameworkElement ProfilesPage()
        {
            _profilesHost = new StackPanel();
            if (_collecting)
            {
                Remember("Готовый набор", "профиль айфон iphone тихий максимум свой набор", _profilesHost);
                Remember("Мои профили", "профиль свой сохранить файл notchprofile поделиться открыть импорт экспорт", _profilesHost);
                Remember("Сейчас включено", "переключатели функции профиль", _profilesHost);
                return _profilesHost;
            }
            FillProfiles();
            return _profilesHost;
        }

        private void ScheduleProfiles()
        {
            if (_profilesPending || _profilesHost == null) return;
            _profilesPending = true;
            Dispatcher.BeginInvoke(new Action(() => { _profilesPending = false; FillProfiles(); }), System.Windows.Threading.DispatcherPriority.Background);
        }

        private void FillProfiles()
        {
            if (_profilesHost == null || _current?.Key != "profiles") return;
            _profilesHost.Children.Clear();
            _rows.Remove("Готовый набор"); _rows.Remove("Мои профили"); _rows.Remove("Сейчас включено");
            var current = Profiles.Current(S);
            var match = Profiles.Match(current);
            var userId = Profiles.UserMatch(current, S.UserProfiles);

            // Ready sets.
            var grid = new UniformGrid { Columns = 2, Margin = new Thickness(8) };
            foreach (var preset in Presets)
            {
                var values = Profiles.Preset(preset.Profile) ?? S.CustomProfile ?? current;
                bool selected = preset.Profile == match && (preset.Profile != IslandProfile.Custom || userId == null);
                grid.Children.Add(PresetCard(preset, values, selected));
            }
            var presets = Group("Готовый набор", "Профиль — это только набор переключателей. «Свой» запоминает твои настройки, когда выбираешь готовый набор.", grid);
            _rows["Готовый набор"] = (FrameworkElement)presets;
            _profilesHost.Children.Add(presets);

            // The user's own profiles.
            var rows = new List<FrameworkElement>();
            var open = new Button { Content = "Открыть файл…", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 8, 0) };
            open.Click += (_, _) => ImportProfile();
            var add = new Button { Content = _newProfileOpen ? "Скрыть" : "Новый профиль", Style = (Style)FindResource("MacButton") };
            add.Click += (_, _) => { _newProfileOpen = !_newProfileOpen; FillProfiles(); };
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            actions.Children.Add(open);
            actions.Children.Add(add);
            int n = S.UserProfiles.Count;
            rows.Add(Row("Свои профили", n == 0 ? "Пока ни одного — сохрани текущие настройки" : Plural(n, "профиль", "профиля", "профилей"), actions));
            if (_newProfileOpen) rows.Add(NewProfileForm());
            foreach (var p in S.UserProfiles) rows.Add(UserProfileRow(p, p.Id == userId));
            var mine = Group("Мои профили", "Профиль сохраняется в файл .notchprofile — тот же формат, что у Ovira на Mac. Файлом можно поделиться.", rows.ToArray());
            _rows["Мои профили"] = (FrameworkElement)mine;
            _profilesHost.Children.Add(mine);

            // What a profile switches, right now.
            var switches = Profiles.Switches.Select(sw =>
            {
                var toggle = new CheckBox { Style = (Style)FindResource("MacSwitch"), IsChecked = sw.Get(S) };
                toggle.Click += (_, _) => sw.Set(S, toggle.IsChecked == true);
                return (FrameworkElement)Row(sw.Title, null, toggle);
            }).ToArray();
            var now = Group("Сейчас включено", Plural(current.Values.Count(v => v), "функция", "функции", "функций") + " из " + current.Count + ". Любое изменение здесь — это уже «Свой» профиль.", switches);
            _rows["Сейчас включено"] = (FrameworkElement)now;
            _profilesHost.Children.Add(now);
        }

        private static string Plural(int n, string one, string few, string many)
        {
            int a = Math.Abs(n) % 100, b = a % 10;
            var word = a is > 10 and < 20 ? many : b == 1 ? one : b is >= 2 and <= 4 ? few : many;
            return n + " " + word;
        }

        private FrameworkElement Chips(Dictionary<string, bool> values)
        {
            var wrap = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            var on = Profiles.Switches.Where(sw => values.GetValueOrDefault(sw.Key)).Select(sw => sw.Title).ToList();
            foreach (var title in on.Take(4)) wrap.Children.Add(Chip(title));
            if (on.Count > 4) wrap.Children.Add(Chip("+" + (on.Count - 4)));
            if (on.Count == 0) wrap.Children.Add(Chip("Всё выключено"));
            return wrap;
        }

        private static FrameworkElement Chip(string text)
        {
            var label = new TextBlock { Text = text, FontSize = 10, FontWeight = FontWeights.Medium };
            label.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            var chip = new Border { CornerRadius = new CornerRadius(7), Padding = new Thickness(7, 2, 7, 3), Margin = new Thickness(0, 0, 4, 4), Child = label };
            chip.SetResourceReference(Border.BackgroundProperty, "FieldBg");
            return chip;
        }

        private FrameworkElement PresetCard(PresetInfo preset, Dictionary<string, bool> values, bool selected)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var icon = IconTile(preset.Icon, preset.Colour, 34);
            icon.VerticalAlignment = VerticalAlignment.Top;
            grid.Children.Add(icon);
            var text = new StackPanel { Margin = new Thickness(11, 0, 0, 0) };
            Grid.SetColumn(text, 1);
            var head = new DockPanel();
            if (selected)
            {
                var check = new Grid { Width = 20, Height = 20 };
                var dot = new Ellipse();
                dot.SetResourceReference(Shape.FillProperty, "SectionAccent");
                check.Children.Add(dot);
                check.Children.Add(new IconView { Icon = "checkmark", Width = 12, Height = 12 });
                DockPanel.SetDock(check, Dock.Right);
                head.Children.Add(check);
            }
            head.Children.Add(new TextBlock { Text = preset.Title, FontSize = 13.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            text.Children.Add(head);
            text.Children.Add(new TextBlock { Text = preset.Summary, Style = (Style)FindResource("RowSub") });
            text.Children.Add(Chips(values));
            grid.Children.Add(text);

            var card = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(12), Margin = new Thickness(5), BorderThickness = new Thickness(1.5), Child = grid, Cursor = Cursors.Hand };
            card.SetResourceReference(Border.BackgroundProperty, "FieldBg");
            if (selected) card.SetResourceReference(Border.BorderBrushProperty, "SectionAccent");
            else card.BorderBrush = Brushes.Transparent;
            card.MouseEnter += (_, _) => { if (!selected) card.BorderBrush = (Brush)FindResource("FieldBorder"); };
            card.MouseLeave += (_, _) => { if (!selected) card.BorderBrush = Brushes.Transparent; };
            card.MouseLeftButtonUp += (_, _) => Profiles.Choose(S, preset.Profile);
            return card;
        }

        private FrameworkElement NewProfileForm()
        {
            var stack = new StackPanel { Margin = new Thickness(14, 10, 14, 12) };
            var name = new TextBox { Style = (Style)FindResource("Field"), Tag = "Название, например «Работа»", Text = _newName, MaxLength = 40 };
            name.TextChanged += (_, _) => _newName = name.Text;
            var summary = new TextBox { Style = (Style)FindResource("Field"), Tag = "Описание — необязательно", Text = _newSummary, MaxLength = 160, Margin = new Thickness(0, 8, 0, 0) };
            summary.TextChanged += (_, _) => _newSummary = summary.Text;
            stack.Children.Add(name);
            stack.Children.Add(summary);
            var hint = new TextBlock { Text = "Сохранятся переключатели, которые включены сейчас: " + Plural(Profiles.Current(S).Values.Count(v => v), "функция", "функции", "функций") + ".", Style = (Style)FindResource("RowSub"), Margin = new Thickness(2, 8, 0, 0) };
            stack.Children.Add(hint);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
            var cancel = new Button { Content = "Отмена", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 8, 0) };
            cancel.Click += (_, _) => { _newProfileOpen = false; FillProfiles(); };
            var save = new Button { Content = "Сохранить текущие", Style = (Style)FindResource("MacButton"), FontWeight = FontWeights.SemiBold };
            save.Click += (_, _) =>
            {
                var profile = Profiles.Make(_newName, _newSummary, Profiles.Current(S), S.UserProfiles);
                _newProfileOpen = false;
                _newName = _newSummary = "";
                S.UserProfiles = S.UserProfiles.Append(profile).ToList();
                FillProfiles();
            };
            buttons.Children.Add(cancel);
            buttons.Children.Add(save);
            stack.Children.Add(buttons);
            name.Loaded += (_, _) => name.Focus();
            return stack;
        }

        private FrameworkElement UserProfileRow(UserProfile p, bool selected)
        {
            var grid = new Grid { Style = (Style)FindResource("Row") };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var accent = AccentFor(Sections.First(s => s.Key == "profiles"));
            var icon = IconTile("person", accent, 30);
            icon.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(icon);
            var text = new StackPanel { Margin = new Thickness(11, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, 1);
            var title = new StackPanel { Orientation = Orientation.Horizontal };
            title.Children.Add(new TextBlock { Text = p.Name, Style = (Style)FindResource("RowTitle"), FontWeight = FontWeights.SemiBold });
            if (selected)
            {
                var badge = new Border { CornerRadius = new CornerRadius(7), Padding = new Thickness(7, 1, 7, 2), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
                                         Child = new TextBlock { Text = "Сейчас", FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White } };
                badge.SetResourceReference(Border.BackgroundProperty, "SectionAccent");
                title.Children.Add(badge);
            }
            text.Children.Add(title);
            var line = Plural(p.EnabledCount, "функция", "функции", "функций") + " из " + p.Values.Count;
            text.Children.Add(new TextBlock { Text = string.IsNullOrWhiteSpace(p.Summary) ? line : p.Summary + " · " + line, Style = (Style)FindResource("RowSub") });
            grid.Children.Add(text);

            var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(actions, 2);
            var apply = new Button { Content = "Применить", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 6, 0), IsEnabled = !selected, Opacity = selected ? 0.5 : 1 };
            apply.Click += (_, _) =>
            {
                var cur = Profiles.Current(S);
                if (Profiles.Match(cur) == IslandProfile.Custom && Profiles.UserMatch(cur, S.UserProfiles) == null) S.CustomProfile = cur;
                Profiles.Apply(S, p.Values);
            };
            actions.Children.Add(apply);
            actions.Children.Add(IconButton("share", "Сохранить в файл", () => ExportProfile(p)));
            actions.Children.Add(IconButton("trash", "Удалить", () =>
            {
                var answer = MessageBox.Show(this, $"Удалить профиль «{p.Name}»?", "Ovira", MessageBoxButton.OKCancel, MessageBoxImage.Question);
                if (answer != MessageBoxResult.OK) return;
                S.UserProfiles = S.UserProfiles.Where(x => x.Id != p.Id).ToList();
                FillProfiles();
            }));
            grid.Children.Add(actions);
            return grid;
        }

        private Button IconButton(string icon, string tip, Action action)
        {
            var glyph = new IconView { Icon = icon, Width = 14, Height = 14 };
            glyph.SetResourceReference(IconView.FillProperty, "Fg");
            var b = new Button { Content = glyph, Style = (Style)FindResource("MacButton"), ToolTip = tip, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(0) };
            b.Click += (_, _) => action();
            return b;
        }

        private void ImportProfile()
        {
            var dialog = new Microsoft.Win32.OpenFileDialog
            {
                Title = "Открыть профиль",
                Filter = "Профиль Ovira (*.notchprofile)|*.notchprofile|JSON (*.json)|*.json",
                CheckFileExists = true
            };
            if (dialog.ShowDialog(this) != true) return;
            UserProfile? profile = null;
            try
            {
                var info = new FileInfo(dialog.FileName);
                if (info.Length < 256 * 1024) profile = Profiles.Import(File.ReadAllText(dialog.FileName), S.UserProfiles);
            }
            catch { }
            if (profile == null)
            {
                MessageBox.Show(this, "Это не файл профиля Ovira или он повреждён.", "Ovira", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            S.UserProfiles = S.UserProfiles.Append(profile).ToList();
            FillProfiles();
        }

        private void ExportProfile(UserProfile p)
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Title = "Сохранить профиль",
                FileName = Profiles.FileName(p),
                DefaultExt = ".notchprofile",
                Filter = "Профиль Ovira (*.notchprofile)|*.notchprofile"
            };
            if (dialog.ShowDialog(this) != true) return;
            try { File.WriteAllText(dialog.FileName, Profiles.Export(p)); }
            catch (Exception e) { MessageBox.Show(this, "Не получилось сохранить файл: " + e.Message, "Ovira", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }
    }
}
