using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ovira.Core
{
    // 0.4.0 — profiles, as on the Mac (IslandProfiles.swift): a profile is
    // only a set of feature switches. «Как на iPhone», «Тихий», «Максимум»,
    // «Свой» (remembered), and the user's own named profiles that can be
    // saved to a .notchprofile file (same format as on the Mac).
    public enum IslandProfile { Iphone, Quiet, Extended, Custom }

    public sealed class UserProfile
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Summary { get; set; } = "";
        public Dictionary<string, bool> Values { get; set; } = new();
        public DateTime Created { get; set; } = DateTime.Now;
        [JsonIgnore] public int EnabledCount => Values.Values.Count(v => v);
    }

    public static class Profiles
    {
        // Switches managed by profiles. Names shared with the Mac where the
        // feature is the same (volume, output, hideFullscreen, playerNew).
        public static readonly (string Key, string Title, Func<Settings, bool> Get, Action<Settings, bool> Set)[] Switches =
        {
            ("media", "Сейчас играет", s => s.ShowMedia, (s, v) => s.ShowMedia = v),
            ("playerNew", "Новый плеер", s => s.PlayerNew, (s, v) => s.PlayerNew = v),
            ("volumeRow", "Громкость в плеере", s => s.VolumeRow, (s, v) => s.VolumeRow = v),
            ("outputPicker", "Выбор звука", s => s.OutputPicker, (s, v) => s.OutputPicker = v),
            ("charging", "Зарядка", s => s.ChargingBanner, (s, v) => s.ChargingBanner = v),
            ("lowBattery", "Низкий заряд", s => s.LowBatteryBanner, (s, v) => s.LowBatteryBanner = v),
            ("volume", "Громкость", s => s.VolumeBanner, (s, v) => s.VolumeBanner = v),
            ("output", "Устройство вывода", s => s.OutputBanner, (s, v) => s.OutputBanner = v),
            ("hideFullscreen", "Прятать в полноэкранном", s => s.HideInFullscreen, (s, v) => s.HideInFullscreen = v),
            ("idlePill", "Капсула без музыки", s => s.ShowIdlePill, (s, v) => s.ShowIdlePill = v),
            ("peek", "Отклик на курсор", s => s.HoverPeek, (s, v) => s.HoverPeek = v),
        };

        public static IEnumerable<string> Keys => Switches.Select(x => x.Key);

        public static string Title(string key) => Switches.FirstOrDefault(x => x.Key == key).Title ?? key;

        public static Dictionary<string, bool> Current(Settings s) => Switches.ToDictionary(x => x.Key, x => x.Get(s));

        public static void Apply(Settings s, Dictionary<string, bool> values)
        {
            foreach (var sw in Switches)
                if (values.TryGetValue(sw.Key, out var v)) sw.Set(s, v);
        }

        public static Dictionary<string, bool>? Preset(IslandProfile p)
        {
            Dictionary<string, bool> Only(params string[] on) => Keys.ToDictionary(k => k, k => on.Contains(k));
            return p switch
            {
                IslandProfile.Iphone => Only("media", "playerNew", "volumeRow", "outputPicker", "charging", "lowBattery", "hideFullscreen"),
                IslandProfile.Quiet => Only("media", "playerNew", "hideFullscreen"),
                IslandProfile.Extended => Keys.ToDictionary(k => k, _ => true),
                _ => null
            };
        }

        public static IslandProfile Match(Dictionary<string, bool> current)
        {
            foreach (var p in new[] { IslandProfile.Iphone, IslandProfile.Quiet, IslandProfile.Extended })
            {
                var preset = Preset(p)!;
                if (Keys.All(k => current.GetValueOrDefault(k) == preset.GetValueOrDefault(k))) return p;
            }
            return IslandProfile.Custom;
        }

        // Choosing a preset remembers the current «Свой» first.
        public static void Choose(Settings s, IslandProfile p)
        {
            var current = Current(s);
            if (Match(current) == IslandProfile.Custom && UserMatch(current, s.UserProfiles) == null)
                s.CustomProfile = current;
            var values = Preset(p) ?? s.CustomProfile ?? current;
            Apply(s, values);
        }

        public static string? UserMatch(Dictionary<string, bool> current, List<UserProfile> list) =>
            list.FirstOrDefault(p => p.Values.Count > 0 && p.Values.All(kv => current.GetValueOrDefault(kv.Key) == kv.Value))?.Id;

        public static UserProfile Make(string name, string summary, Dictionary<string, bool> values, List<UserProfile> existing)
        {
            var clean = (name ?? "").Trim();
            if (clean.Length == 0) clean = "Мой профиль";
            if (clean.Length > 40) clean = clean.Substring(0, 40);
            var taken = new HashSet<string>(existing.Select(p => p.Name.ToLowerInvariant()));
            if (taken.Contains(clean.ToLowerInvariant()))
            {
                int k = 2;
                while (taken.Contains((clean + " " + k).ToLowerInvariant())) k++;
                clean = clean + " " + k;
            }
            var text = (summary ?? "").Trim();
            if (text.Length > 160) text = text.Substring(0, 160);
            var known = new HashSet<string>(Keys);
            return new UserProfile
            {
                Id = Guid.NewGuid().ToString(),
                Name = clean,
                Summary = text,
                Values = values.Where(kv => known.Contains(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value),
                Created = DateTime.Now
            };
        }

        // ---- .notchprofile files ----

        private sealed class ExportFile
        {
            [JsonPropertyName("format")] public string Format { get; set; } = "notch-island-profile";
            [JsonPropertyName("version")] public int Version { get; set; } = 1;
            [JsonPropertyName("name")] public string Name { get; set; } = "";
            [JsonPropertyName("description")] public string Description { get; set; } = "";
            [JsonPropertyName("values")] public Dictionary<string, bool> Values { get; set; } = new();
        }

        public static string Export(UserProfile p) => JsonSerializer.Serialize(
            new ExportFile { Name = p.Name, Description = p.Summary, Values = p.Values },
            new JsonSerializerOptions { WriteIndented = true });

        public static UserProfile? Import(string json, List<UserProfile> existing)
        {
            try
            {
                var file = JsonSerializer.Deserialize<ExportFile>(json);
                if (file == null || file.Format != "notch-island-profile" || file.Version < 1) return null;
                var known = new HashSet<string>(Keys);
                var values = file.Values.Where(kv => known.Contains(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);
                if (values.Count == 0) return null;
                return Make(file.Name, file.Description, values, existing);
            }
            catch { return null; }
        }

        public static string FileName(UserProfile p)
        {
            var safe = new string(p.Name.Select(c => "/:\\?%*|\"<>".Contains(c) ? '-' : c).ToArray());
            return safe + ".notchprofile";
        }
    }
}
