using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Ovira.Core;

namespace Ovira.SettingsUi
{
    // 0.4.0 — themes from the Mac: the ready themes, «Обложка», the user's
    // own themes and the inline theme editor (name, light/dark, 2–4 colours,
    // a palette and hue/saturation/brightness sliders).
    public partial class SettingsWindow
    {
        private static Color[] s_palette = Array.Empty<Color>();
        private Theme? _theme;
        private Color _lastTint;

        // Section colour: the theme's palette by section index, like the Mac.
        private static Color AccentFor(Section section)
        {
            if (s_palette.Length > 0)
            {
                int i = Array.IndexOf(Sections, section);
                return s_palette[Math.Max(0, i) % s_palette.Length];
            }
            return section.Key == "general" ? Color.FromRgb(0x3D, 0x85, 0xFF) : section.Colour;
        }

        private static Color C(uint argb) =>
            Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

        private Color CoverTint => App.Current.Media.Track?.Tint ?? Color.FromRgb(0xFF, 0x45, 0x66);

        private void ApplyTheme()
        {
            var tint = CoverTint;
            _lastTint = tint;
            var t = Themes.Find(S.Theme, tint);
            _theme = t;
            s_palette = t.Palette;
            bool dark = t.IsDark;
            void Set(string key, uint argb)
            {
                var b = new SolidColorBrush(C(argb));
                b.Freeze();
                Resources[key] = b;
            }
            if (dark)
            {
                Set("Fg", 0xFFFFFFFF); Set("Fg2", 0x8CFFFFFF); Set("Fg3", 0x73FFFFFF);
                Set("CardBg", 0x10FFFFFF); Set("Divider", 0x12FFFFFF); Set("FieldBg", 0x1AFFFFFF);
                Set("FieldBorder", 0x26FFFFFF); Set("ButtonBg", 0x2EFFFFFF); Set("ButtonHover", 0x40FFFFFF);
                Set("ButtonPressed", 0x1FFFFFFF); Set("SwitchOff", 0x3DFFFFFF); Set("TrackBg", 0x33FFFFFF);
            }
            else
            {
                Set("Fg", 0xFF1C1C1E); Set("Fg2", 0x993C3C43); Set("Fg3", 0x733C3C43);
                Set("CardBg", 0xB3FFFFFF); Set("Divider", 0x14000000); Set("FieldBg", 0x0F000000);
                Set("FieldBorder", 0x1F000000); Set("ButtonBg", 0xFFFFFFFF); Set("ButtonHover", 0xFFF5F5F7);
                Set("ButtonPressed", 0xFFE5E5EA); Set("SwitchOff", 0x29000000); Set("TrackBg", 0x1F000000);
            }
            if (t.Background.Length > 0)
            {
                var stops = new GradientStopCollection();
                for (int i = 0; i < t.Background.Length; i++)
                    stops.Add(new GradientStop(t.Background[i], t.Background.Length == 1 ? 0 : (double)i / (t.Background.Length - 1)));
                var g = new LinearGradientBrush(stops, new Point(0, 0), new Point(1, 1));
                g.Freeze();
                Resources["Base"] = g;
                Set("Dim", dark ? 0x40000000u : 0x40FFFFFFu);
            }
            else
            {
                Set("Base", dark ? 0xFF0E0E12u : 0xFFF2F2F7u);
                Set("Dim", dark ? 0x99101014u : 0x8CF2F2F7u);
            }
            try
            {
                var hwnd = new WindowInteropHelper(this).Handle;
                if (hwnd != IntPtr.Zero) Native.DarkTitleBar(hwnd, dark);
            }
            catch { }

            Resources["SectionAccent"] = new SolidColorBrush(_current != null ? _current.Accent : AccentFor(Sections[0]));
            BuildTiles();
            ShowTrack();
            TintAurora();
            if (_current != null) ColourSection(_current);
            RefreshThemePicker();
        }

        // «Обложка» follows the playing track.
        private void CoverChanged()
        {
            if (S.Theme != "cover") return;
            var tint = CoverTint;
            if (tint == _lastTint) return;
            CrossFade(ApplyTheme);
        }

        // A theme never switches abruptly: the window as it looked a moment
        // ago is laid over the new theme and slowly fades away.
        private void CrossFade(Action change)
        {
            if (!IsLoaded || Frame.ActualWidth < 1 || Frame.ActualHeight < 1) { change(); return; }
            try
            {
                var dpi = VisualTreeHelper.GetDpi(this);
                var shot = new System.Windows.Media.Imaging.RenderTargetBitmap(
                    (int)Math.Ceiling(Frame.ActualWidth * dpi.DpiScaleX), (int)Math.Ceiling(Frame.ActualHeight * dpi.DpiScaleY),
                    dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                ThemeFade.BeginAnimation(OpacityProperty, null);
                ThemeFade.Opacity = 0;            // keep the previous snapshot out of the new one
                shot.Render(Frame);
                shot.Freeze();
                ThemeFade.Source = shot;
                ThemeFade.Opacity = 1;
                ThemeFade.Visibility = Visibility.Visible;
            }
            catch
            {
                change();
                return;
            }
            change();
            var fade = new System.Windows.Media.Animation.DoubleAnimation(1, 0, TimeSpan.FromSeconds(0.55))
            {
                EasingFunction = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseInOut }
            };
            fade.Completed += (_, _) =>
            {
                if (ThemeFade.Opacity > 0.01) return;   // a newer fade has started
                ThemeFade.Visibility = Visibility.Collapsed;
                ThemeFade.Source = null;
            };
            ThemeFade.BeginAnimation(OpacityProperty, fade);
        }

        private static bool IsLight(Color c) => 0.299 * c.R + 0.587 * c.G + 0.114 * c.B > 165;

        private static Brush PreviewBrush(IReadOnlyList<Color> colors)
        {
            if (colors.Count == 0) return Brushes.Gray;
            if (colors.Count == 1) return new SolidColorBrush(colors[0]);
            var stops = new GradientStopCollection();
            for (int i = 0; i < colors.Count; i++) stops.Add(new GradientStop(colors[i], (double)i / (colors.Count - 1)));
            return new LinearGradientBrush(stops, new Point(0, 0), new Point(1, 1));
        }

        // ================================================================ picker

        private Border? _themeHost;

        private FrameworkElement ThemeGroupContent()
        {
            _themeHost = new Border { Padding = new Thickness(14, 12, 14, 14) };
            var panel = new StackPanel();
            panel.Children.Add(_themeHost);
            RefreshThemePicker();
            Remember("Тема", "тема оформление цвет светлая тёмная своя палитра обложка", panel);
            return panel;
        }

        private void RefreshThemePicker()
        {
            if (_themeHost == null) return;
            var stack = new StackPanel();
            var wrap = new WrapPanel();
            foreach (var t in Themes.All(CoverTint)) wrap.Children.Add(Swatch(t, t.Id == (_theme?.Id ?? S.Theme)));
            wrap.Children.Add(AddThemeButton());
            stack.Children.Add(wrap);
            if (_editing) stack.Children.Add(Editor());
            _themeHost.Child = stack;
        }

        private FrameworkElement Swatch(Theme t, bool selected)
        {
            var preview = new Grid { Height = 54 };
            preview.Children.Add(new Border { CornerRadius = new CornerRadius(11), Background = PreviewBrush(t.Preview) });
            preview.Children.Add(new Border { CornerRadius = new CornerRadius(11), Background = Gloss(0x33) });
            bool light = IsLight(t.Preview[0]);
            if (t.Palette.Length > 0)
            {
                var dots = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(7, 0, 0, 7) };
                foreach (var c in t.Palette.Take(4))
                    dots.Children.Add(new Ellipse { Width = 9, Height = 9, Fill = new SolidColorBrush(c), Stroke = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)), StrokeThickness = 1, Margin = new Thickness(0, 0, 3, 0) });
                preview.Children.Add(dots);
            }
            var icon = new IconView
            {
                Icon = t.Icon, Width = 17, Height = 17, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 7, 7, 0),
                Fill = new SolidColorBrush(light ? Color.FromArgb(0xB3, 0, 0, 0) : Colors.White)
            };
            preview.Children.Add(icon);
            if (selected)
            {
                var check = new Grid { Width = 18, Height = 18, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(6, 6, 0, 0) };
                var dot = new Ellipse();
                dot.SetResourceReference(Shape.FillProperty, "SectionAccent");
                check.Children.Add(dot);
                check.Children.Add(new IconView { Icon = "checkmark", Width = 11, Height = 11 });
                preview.Children.Add(check);
            }

            Border? delete = null;
            if (t.IsCustom)
            {
                delete = new Border
                {
                    Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(Color.FromArgb(0xCC, 0, 0, 0)),
                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 6, 6),
                    Child = new IconView { Icon = "trash", Width = 11, Height = 11 }, Visibility = Visibility.Collapsed, Cursor = Cursors.Hand, ToolTip = "Удалить тему"
                };
                var id = t.Id;
                delete.MouseLeftButtonUp += (_, e) =>
                {
                    e.Handled = true;
                    var answer = MessageBox.Show(this, $"Удалить тему «{t.Name}»?", "Ovira", MessageBoxButton.OKCancel, MessageBoxImage.Question);
                    if (answer == MessageBoxResult.OK) Themes.DeleteCustom(id);
                };
                preview.Children.Add(delete);
            }

            var frame = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(2), BorderThickness = new Thickness(2), Child = preview };
            if (selected) frame.SetResourceReference(Border.BorderBrushProperty, "SectionAccent");
            else frame.BorderBrush = Brushes.Transparent;

            var stack = new StackPanel { Width = 96, Margin = new Thickness(0, 0, 8, 10), Cursor = Cursors.Hand, Background = Brushes.Transparent };
            stack.Children.Add(frame);
            var name = new TextBlock { Text = t.Name, FontSize = 11, FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 92 };
            if (!selected) name.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            stack.Children.Add(name);
            stack.MouseEnter += (_, _) => { if (delete != null) delete.Visibility = Visibility.Visible; if (!selected) frame.BorderBrush = (Brush)FindResource("FieldBorder"); };
            stack.MouseLeave += (_, _) => { if (delete != null) delete.Visibility = Visibility.Collapsed; if (!selected) frame.BorderBrush = Brushes.Transparent; };
            var themeId = t.Id;
            stack.MouseLeftButtonUp += (_, _) => { if (S.Theme != themeId) S.Theme = themeId; };
            return stack;
        }

        private FrameworkElement AddThemeButton()
        {
            var grid = new Grid { Height = 54 };
            var dash = new Rectangle { RadiusX = 11, RadiusY = 11, StrokeThickness = 1.4, StrokeDashArray = new DoubleCollection { 4, 3 } };
            dash.SetResourceReference(Shape.StrokeProperty, "Fg3");
            grid.Children.Add(dash);
            var plus = new IconView { Icon = "plus", Width = 18, Height = 18 };
            plus.SetResourceReference(IconView.FillProperty, "Fg2");
            grid.Children.Add(plus);
            var frame = new Border { Padding = new Thickness(4), Child = grid };
            var stack = new StackPanel { Width = 96, Margin = new Thickness(0, 0, 8, 10), Cursor = Cursors.Hand, Background = Brushes.Transparent };
            stack.Children.Add(frame);
            var name = new TextBlock { Text = "Своя тема", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
            name.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            stack.Children.Add(name);
            stack.MouseLeftButtonUp += (_, _) =>
            {
                if (_editing) return;
                _editing = true;
                _edName = "";
                _edDark = true;
                _edColors = new List<Color> { C(0xFF5856D6), C(0xFFFF2D55), C(0xFFFF9500) };
                _edSlot = 0;
                RefreshThemePicker();
            };
            return stack;
        }

        // ================================================================ editor

        private bool _editing;
        private string _edName = "";
        private bool _edDark = true;
        private List<Color> _edColors = new();
        private int _edSlot;
        private bool _syncing;

        private Border? _edPreview;
        private TextBlock? _edPreviewName;
        private StackPanel? _edPreviewDots, _edSlots;
        private Slider? _edHue, _edSat, _edBri;

        private static readonly uint[] PaletteColors =
        {
            0xFFFF3B30, 0xFFFF9500, 0xFFFFCC00, 0xFF34C759, 0xFF00C7BE, 0xFF30B0C7, 0xFF32ADE6,
            0xFF007AFF, 0xFF5856D6, 0xFFAF52DE, 0xFFFF2D55, 0xFFA2845E, 0xFF8E8E93, 0xFF1C1C1E,
        };

        private FrameworkElement Editor()
        {
            var card = new Border { CornerRadius = new CornerRadius(16), Padding = new Thickness(14), Margin = new Thickness(0, 6, 0, 0), BorderThickness = new Thickness(1) };
            card.SetResourceReference(Border.BackgroundProperty, "FieldBg");
            card.SetResourceReference(Border.BorderBrushProperty, "FieldBorder");
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(176) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            // Preview: how the theme will look.
            var preview = new Grid { Height = 120, VerticalAlignment = VerticalAlignment.Top };
            _edPreview = new Border { CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1), BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)) };
            preview.Children.Add(_edPreview);
            preview.Children.Add(new Border { CornerRadius = new CornerRadius(16), Background = Gloss(0x38) });
            var pill = new Border { Width = 70, Height = 16, CornerRadius = new CornerRadius(8), Background = Brushes.Black, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 0, 0) };
            preview.Children.Add(pill);
            var bottom = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12, 0, 12, 11) };
            _edPreviewName = new TextBlock { FontSize = 14, FontWeight = FontWeights.Black, FontFamily = DisplayFont, TextTrimming = TextTrimming.CharacterEllipsis };
            _edPreviewDots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
            bottom.Children.Add(_edPreviewName);
            bottom.Children.Add(_edPreviewDots);
            preview.Children.Add(bottom);
            grid.Children.Add(preview);

            var controls = new StackPanel { Margin = new Thickness(16, 0, 0, 0) };
            Grid.SetColumn(controls, 1);
            grid.Children.Add(controls);

            var name = new TextBox { Style = (Style)FindResource("Field"), Tag = "Название темы", Text = _edName, MaxLength = 24 };
            name.TextChanged += (_, _) => { _edName = name.Text; UpdateEditorPreview(); };
            controls.Children.Add(name);

            // Light / dark and the number of colours.
            var line = new DockPanel { Margin = new Thickness(0, 10, 0, 0), LastChildFill = false };
            var segBox = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(2) };
            segBox.SetResourceReference(Border.BackgroundProperty, "FieldBg");
            var seg = new StackPanel { Orientation = Orientation.Horizontal };
            var group = "edmode" + Guid.NewGuid().ToString("N");
            foreach (var (label, dark) in new[] { ("Тёмная", true), ("Светлая", false) })
            {
                var rb = new RadioButton { Content = label, GroupName = group, Style = (Style)FindResource("MacSegment"), IsChecked = _edDark == dark };
                rb.Checked += (_, _) => { _edDark = dark; UpdateEditorPreview(); };
                seg.Children.Add(rb);
            }
            segBox.Child = seg;
            line.Children.Add(segBox);
            var count = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(count, Dock.Right);
            var countLabel = new TextBlock { Text = "Цветов", FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
            countLabel.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            count.Children.Add(countLabel);
            var minus = new Button { Content = "−", Style = (Style)FindResource("MacButton"), Width = 34 };
            var number = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, Width = 22, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var plus = new Button { Content = "+", Style = (Style)FindResource("MacButton"), Width = 34 };
            void ShowCount()
            {
                number.Text = _edColors.Count.ToString();
                minus.IsEnabled = _edColors.Count > 2;
                plus.IsEnabled = _edColors.Count < 4;
                minus.Opacity = minus.IsEnabled ? 1 : 0.4;
                plus.Opacity = plus.IsEnabled ? 1 : 0.4;
            }
            minus.Click += (_, _) =>
            {
                if (_edColors.Count <= 2) return;
                _edColors.RemoveAt(_edColors.Count - 1);
                _edSlot = Math.Min(_edSlot, _edColors.Count - 1);
                ShowCount(); SyncSliders(); UpdateEditorPreview();
            };
            plus.Click += (_, _) =>
            {
                if (_edColors.Count >= 4) return;
                Themes.ToHsv(_edColors[^1], out var h, out var s, out var v);
                _edColors.Add(Themes.FromHsv(h + 0.12, Math.Max(0.45, s), Math.Max(0.55, v)));
                _edSlot = _edColors.Count - 1;
                ShowCount(); SyncSliders(); UpdateEditorPreview();
            };
            count.Children.Add(minus);
            count.Children.Add(number);
            count.Children.Add(plus);
            ShowCount();
            line.Children.Add(count);
            controls.Children.Add(line);

            // The colour slots: click one, then pick its colour.
            _edSlots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
            controls.Children.Add(_edSlots);

            var palette = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
            foreach (var argb in PaletteColors)
            {
                var c = C(argb);
                var dot = new Ellipse { Width = 20, Height = 20, Fill = new SolidColorBrush(c), Margin = new Thickness(0, 0, 6, 6), Cursor = Cursors.Hand, StrokeThickness = 1 };
                dot.SetResourceReference(Shape.StrokeProperty, "FieldBorder");
                dot.MouseLeftButtonUp += (_, _) => { _edColors[_edSlot] = c; SyncSliders(); UpdateEditorPreview(); };
                palette.Children.Add(dot);
            }
            controls.Children.Add(palette);

            _edHue = EditorSlider(controls, "Оттенок");
            _edSat = EditorSlider(controls, "Насыщенность");
            _edBri = EditorSlider(controls, "Яркость");
            var rainbow = new GradientStopCollection();
            for (int i = 0; i <= 6; i++) rainbow.Add(new GradientStop(Themes.FromHsv(i / 6.0, 1, 1), i / 6.0));
            _edHue.Background = new LinearGradientBrush(rainbow, 0);

            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
            var cancel = new Button { Content = "Отмена", Style = (Style)FindResource("MacButton"), Margin = new Thickness(0, 0, 8, 0) };
            cancel.Click += (_, _) => { _editing = false; RefreshThemePicker(); };
            var save = new Button { Content = "Сохранить тему", Style = (Style)FindResource("MacButton"), FontWeight = FontWeights.SemiBold };
            save.Click += (_, _) =>
            {
                _editing = false;
                var created = Themes.AddCustom(_edName, _edDark, _edColors);
                S.Theme = created.Id;
                RefreshThemePicker();
            };
            buttons.Children.Add(cancel);
            buttons.Children.Add(save);
            controls.Children.Add(buttons);

            card.Child = grid;
            SyncSliders();
            UpdateEditorPreview();
            return card;
        }

        private Slider EditorSlider(Panel host, string title)
        {
            var row = new Grid { Margin = new Thickness(0, 6, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var label = new TextBlock { Text = title, FontSize = 11.5, VerticalAlignment = VerticalAlignment.Center };
            label.SetResourceReference(TextBlock.ForegroundProperty, "Fg2");
            row.Children.Add(label);
            var slider = new Slider { Minimum = 0, Maximum = 1, Style = (Style)FindResource("GradientSlider"), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(slider, 1);
            row.Children.Add(slider);
            slider.ValueChanged += (_, _) => OnEditorSlider();
            host.Children.Add(row);
            return slider;
        }

        private void OnEditorSlider()
        {
            if (_syncing || _edHue == null || _edSat == null || _edBri == null || _edColors.Count == 0) return;
            _edColors[_edSlot] = Themes.FromHsv(_edHue.Value, _edSat.Value, _edBri.Value);
            PaintSliders();
            UpdateEditorPreview();
        }

        private void SyncSliders()
        {
            if (_edHue == null || _edSat == null || _edBri == null || _edColors.Count == 0) return;
            _syncing = true;
            Themes.ToHsv(_edColors[_edSlot], out var h, out var s, out var v);
            _edHue.Value = h;
            _edSat.Value = s;
            _edBri.Value = v;
            _syncing = false;
            PaintSliders();
        }

        private void PaintSliders()
        {
            if (_edHue == null || _edSat == null || _edBri == null) return;
            _edSat.Background = new LinearGradientBrush(Themes.FromHsv(_edHue.Value, 0, _edBri.Value), Themes.FromHsv(_edHue.Value, 1, _edBri.Value), 0);
            _edBri.Background = new LinearGradientBrush(Colors.Black, Themes.FromHsv(_edHue.Value, _edSat.Value, 1), 0);
        }

        private void UpdateEditorPreview()
        {
            if (_edPreview == null || _edPreviewName == null || _edPreviewDots == null || _edSlots == null) return;
            var custom = new CustomTheme { Id = Themes.CustomPrefix + "preview", Name = _edName, Dark = _edDark, Colors = _edColors.Select(Themes.ToHex).ToList() };
            var t = Themes.FromCustom(custom);
            _edPreview.Background = PreviewBrush(t.Background.Concat(new[] { t.Palette[0] }).ToList());
            _edPreviewName.Text = string.IsNullOrWhiteSpace(_edName) ? "Моя тема" : _edName.Trim();
            _edPreviewName.Foreground = new SolidColorBrush(_edDark ? Colors.White : C(0xFF1C1C1E));
            _edPreviewDots.Children.Clear();
            foreach (var c in _edColors)
                _edPreviewDots.Children.Add(new Border { Width = 22, Height = 10, CornerRadius = new CornerRadius(5), Background = new SolidColorBrush(c), Margin = new Thickness(0, 0, 4, 0) });

            _edSlots.Children.Clear();
            for (int i = 0; i < _edColors.Count; i++)
            {
                int index = i;
                var ring = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), BorderThickness = new Thickness(2), Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(2), Cursor = Cursors.Hand };
                if (i == _edSlot) ring.SetResourceReference(Border.BorderBrushProperty, "Fg");
                else ring.BorderBrush = Brushes.Transparent;
                ring.Child = new Ellipse { Fill = new SolidColorBrush(_edColors[i]) };
                ring.ToolTip = "Цвет " + (i + 1);
                ring.MouseLeftButtonUp += (_, _) => { _edSlot = index; SyncSliders(); UpdateEditorPreview(); };
                _edSlots.Children.Add(ring);
            }
        }
    }
}
