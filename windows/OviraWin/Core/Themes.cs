using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Media;
using Microsoft.Win32;

namespace Ovira.Core
{
    // 0.4.0 — the Mac settings themes (NotchSettingsWindow.swift →
    // SettingsTheme, CustomThemes.swift): the same fourteen ready themes,
    // «Обложка» built from the playing cover, and the user's own themes
    // (a name, light or dark, 2–4 colours).
    public sealed record Theme(string Id, string Name, string Icon, bool? Dark,
                               Color[] Background, Color[] Palette, Color[] Preview)
    {
        public bool IsCustom => Id.StartsWith(Themes.CustomPrefix, StringComparison.Ordinal);

        // nil on the Mac = follow the system; here: Windows' app mode.
        public bool IsDark => Dark ?? Themes.WindowsIsDark();
    }

    public sealed class CustomTheme
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public bool Dark { get; set; } = true;
        public List<string> Colors { get; set; } = new();
    }

    public static class Themes
    {
        public const string CustomPrefix = "custom-";

        private static Color Rgb(double r, double g, double b) =>
            Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

        private static readonly Theme[] Fixed =
        {
            new("system", "Системная", "halfcircle", null, Array.Empty<Color>(), Array.Empty<Color>(), new[] { Rgb(0.93, 0.93, 0.95), Rgb(0.16, 0.16, 0.19) }),
            new("light", "Светлая", "sun", false, Array.Empty<Color>(), Array.Empty<Color>(), new[] { Rgb(0.98, 0.98, 1.0), Rgb(0.86, 0.88, 0.93) }),
            new("dark", "Тёмная", "moon", true, Array.Empty<Color>(), Array.Empty<Color>(), new[] { Rgb(0.22, 0.22, 0.26), Rgb(0.06, 0.06, 0.08) }),
            new("ocean", "Океан", "waves", true,
                new[] { Rgb(0.02, 0.18, 0.36), Rgb(0.0, 0.33, 0.45), Rgb(0.02, 0.1, 0.22) },
                new[] { Rgb(0.0, 0.6, 0.95), Rgb(0.0, 0.78, 0.78), Rgb(0.25, 0.45, 1.0), Rgb(0.1, 0.85, 0.65) },
                new[] { Rgb(0.0, 0.55, 0.9), Rgb(0.0, 0.25, 0.45) }),
            new("sunset", "Закат", "sun", true,
                new[] { Rgb(0.42, 0.08, 0.32), Rgb(0.62, 0.2, 0.18), Rgb(0.2, 0.05, 0.25) },
                new[] { Rgb(1.0, 0.45, 0.25), Rgb(1.0, 0.3, 0.5), Rgb(1.0, 0.68, 0.2), Rgb(0.85, 0.3, 0.75) },
                new[] { Rgb(1.0, 0.55, 0.25), Rgb(0.75, 0.15, 0.45) }),
            new("forest", "Лес", "leaf", true,
                new[] { Rgb(0.03, 0.22, 0.14), Rgb(0.1, 0.3, 0.12), Rgb(0.02, 0.12, 0.09) },
                new[] { Rgb(0.2, 0.78, 0.4), Rgb(0.55, 0.82, 0.25), Rgb(0.1, 0.65, 0.55), Rgb(0.85, 0.75, 0.25) },
                new[] { Rgb(0.3, 0.8, 0.4), Rgb(0.05, 0.3, 0.18) }),
            new("lavender", "Лаванда", "sparkles", false,
                new[] { Rgb(0.9, 0.86, 1.0), Rgb(0.97, 0.85, 0.95), Rgb(0.84, 0.88, 1.0) },
                new[] { Rgb(0.55, 0.4, 0.95), Rgb(0.85, 0.4, 0.8), Rgb(0.4, 0.5, 0.95), Rgb(0.95, 0.5, 0.65) },
                new[] { Rgb(0.85, 0.78, 1.0), Rgb(0.6, 0.45, 0.95) }),
            new("neon", "Неон", "bolt", true,
                new[] { Rgb(0.05, 0.02, 0.12), Rgb(0.12, 0.02, 0.2), Rgb(0.02, 0.05, 0.12) },
                new[] { Rgb(1.0, 0.15, 0.75), Rgb(0.1, 0.9, 1.0), Rgb(0.65, 0.3, 1.0), Rgb(0.2, 1.0, 0.55) },
                new[] { Rgb(1.0, 0.15, 0.75), Rgb(0.1, 0.9, 1.0) }),
            new("peach", "Персик", "heart", false,
                new[] { Rgb(1.0, 0.9, 0.82), Rgb(1.0, 0.84, 0.86), Rgb(1.0, 0.95, 0.85) },
                new[] { Rgb(1.0, 0.5, 0.4), Rgb(1.0, 0.62, 0.3), Rgb(0.95, 0.4, 0.55), Rgb(0.9, 0.55, 0.2) },
                new[] { Rgb(1.0, 0.8, 0.65), Rgb(1.0, 0.5, 0.45) }),
            new("aurora", "Аврора", "sparkles", true,
                new[] { Rgb(0.02, 0.1, 0.16), Rgb(0.04, 0.24, 0.22), Rgb(0.12, 0.06, 0.24) },
                new[] { Rgb(0.15, 0.95, 0.6), Rgb(0.3, 0.75, 1.0), Rgb(0.65, 0.4, 1.0), Rgb(0.1, 0.8, 0.8) },
                new[] { Rgb(0.15, 0.9, 0.6), Rgb(0.5, 0.35, 0.95) }),
            new("cherry", "Вишня", "heart", true,
                new[] { Rgb(0.25, 0.02, 0.08), Rgb(0.4, 0.04, 0.12), Rgb(0.12, 0.02, 0.06) },
                new[] { Rgb(1.0, 0.2, 0.35), Rgb(0.95, 0.35, 0.55), Rgb(1.0, 0.45, 0.3), Rgb(0.85, 0.15, 0.5) },
                new[] { Rgb(1.0, 0.25, 0.4), Rgb(0.35, 0.03, 0.1) }),
            new("mint", "Мята", "leaf", false,
                new[] { Rgb(0.85, 0.98, 0.93), Rgb(0.82, 0.95, 0.98), Rgb(0.9, 0.99, 0.9) },
                new[] { Rgb(0.1, 0.72, 0.6), Rgb(0.15, 0.6, 0.85), Rgb(0.3, 0.75, 0.4), Rgb(0.0, 0.65, 0.75) },
                new[] { Rgb(0.75, 0.97, 0.9), Rgb(0.15, 0.7, 0.6) }),
            new("sand", "Песок", "sun", false,
                new[] { Rgb(0.98, 0.94, 0.85), Rgb(0.96, 0.9, 0.8), Rgb(0.99, 0.96, 0.9) },
                new[] { Rgb(0.85, 0.6, 0.25), Rgb(0.75, 0.45, 0.3), Rgb(0.6, 0.55, 0.3), Rgb(0.9, 0.5, 0.35) },
                new[] { Rgb(0.97, 0.9, 0.75), Rgb(0.8, 0.55, 0.3) }),
        };

        public static IEnumerable<string> BuiltInNames => Fixed.Select(t => t.Name).Append("Обложка");

        // «Обложка»: colours of the playing cover.
        public static Theme Cover(Color tint)
        {
            var p = CoverPalette(tint);
            return new Theme("cover", "Обложка", "music.note", true,
                new[] { Scale(p[0], 0.32), Scale(p[1], 0.22), Rgb(0.05, 0.05, 0.05) },
                p, new[] { p[0], Scale(p[1], 0.45) });
        }

        public static List<Theme> All(Color coverTint) =>
            Fixed.Concat(new[] { Cover(coverTint) }).Concat(Settings.Current.CustomThemes.Select(FromCustom)).ToList();

        public static Theme Find(string id, Color coverTint) =>
            All(coverTint).FirstOrDefault(t => t.Id == id) ?? Fixed[0];

        // A ready theme from the user's colours (CustomThemes.swift).
        public static Theme FromCustom(CustomTheme custom)
        {
            var colors = custom.Colors.Select(ParseHex).ToList();
            if (colors.Count == 0) colors.Add(Rgb(0.36, 0.35, 0.9));
            int n = colors.Count;
            while (colors.Count < 4) colors.Add(colors[colors.Count % n]);
            var a = colors[0];
            var b = colors[1];
            var background = custom.Dark
                ? new[] { Scale(a, 0.3), Scale(b, 0.22), Rgb(0.05, 0.05, 0.05) }
                : new[] { MixWhite(a, 0.82), MixWhite(b, 0.86), MixWhite(a, 0.92) };
            return new Theme(custom.Id, custom.Name, "palette", custom.Dark, background, colors.ToArray(), new[] { a, b });
        }

        public static CustomTheme AddCustom(string name, bool dark, IEnumerable<Color> colors)
        {
            var trimmed = (name ?? "").Trim();
            var title = (trimmed.Length == 0 ? "Моя тема" : trimmed);
            if (title.Length > 24) title = title.Substring(0, 24);
            var taken = new HashSet<string>(Settings.Current.CustomThemes.Select(t => t.Name.ToLowerInvariant())
                                             .Concat(BuiltInNames.Select(x => x.ToLowerInvariant())));
            if (taken.Contains(title.ToLowerInvariant()))
            {
                int k = 2;
                while (taken.Contains((title + " " + k).ToLowerInvariant())) k++;
                title = title + " " + k;
            }
            var theme = new CustomTheme
            {
                Id = CustomPrefix + Guid.NewGuid().ToString("N"),
                Name = title,
                Dark = dark,
                Colors = colors.Take(4).Select(ToHex).ToList()
            };
            var list = Settings.Current.CustomThemes.ToList();
            list.Add(theme);
            Settings.Current.CustomThemes = list;
            return theme;
        }

        public static void DeleteCustom(string id)
        {
            Settings.Current.CustomThemes = Settings.Current.CustomThemes.Where(t => t.Id != id).ToList();
            if (Settings.Current.Theme == id) Settings.Current.Theme = "system";
        }

        // ---- colour helpers ----

        public static Color[] CoverPalette(Color tint)
        {
            ToHsv(tint, out var h, out var s, out var v);
            return new[]
            {
                tint,
                FromHsv((h + 0.08) % 1, Math.Min(1, s * 0.9 + 0.1), Math.Max(0.45, v * 0.8)),
                FromHsv((h + 0.92) % 1, Math.Min(1, s * 0.8 + 0.15), Math.Min(1, v * 1.05 + 0.05)),
                FromHsv((h + 0.5) % 1, s * 0.6, Math.Max(0.5, v * 0.9)),
            };
        }

        public static Color Scale(Color c, double k) => Color.FromRgb((byte)(c.R * k), (byte)(c.G * k), (byte)(c.B * k));

        public static Color MixWhite(Color c, double amount) => Color.FromRgb(
            (byte)(c.R + (255 - c.R) * amount), (byte)(c.G + (255 - c.G) * amount), (byte)(c.B + (255 - c.B) * amount));

        public static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

        public static Color ParseHex(string hex)
        {
            try
            {
                var o = ColorConverter.ConvertFromString(hex);
                if (o is Color c) return Color.FromRgb(c.R, c.G, c.B);
            }
            catch { }
            return Color.FromRgb(0x5C, 0x59, 0xE6);
        }

        public static void ToHsv(Color c, out double h, out double s, out double v)
        {
            double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
            double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
            v = max;
            double d = max - min;
            s = max == 0 ? 0 : d / max;
            if (d == 0) { h = 0; return; }
            if (max == r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
            else if (max == g) h = ((b - r) / d + 2) / 6;
            else h = ((r - g) / d + 4) / 6;
        }

        public static Color FromHsv(double h, double s, double v)
        {
            h = ((h % 1) + 1) % 1;
            int i = (int)Math.Floor(h * 6);
            double f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
            double r, g, b;
            switch (i % 6)
            {
                case 0: r = v; g = t; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = t; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = t; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
            return Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
        }

        // Windows app mode: Settings → Персонализация → Цвета.
        public static bool WindowsIsDark()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return key?.GetValue("AppsUseLightTheme") is int v ? v == 0 : true;
            }
            catch { return true; }
        }
    }
}
