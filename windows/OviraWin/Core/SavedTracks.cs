using System;
using System.Linq;

namespace Ovira.Core
{
    // 0.4.14 — songs saved with the star in the player.
    public sealed class SavedTrack
    {
        public string Title { get; set; } = "";
        public string Artist { get; set; } = "";
        public string Source { get; set; } = "";
        public DateTime Saved { get; set; } = DateTime.Now;
        public override string ToString() => string.IsNullOrWhiteSpace(Artist) ? Title : Artist + " — " + Title;
    }

    public static class SavedTracks
    {
        private static bool Same(SavedTrack s, string title, string artist) =>
            string.Equals(s.Title, title, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(s.Artist, artist, StringComparison.OrdinalIgnoreCase);

        public static bool Contains(string title, string artist) =>
            Settings.Current.SavedTracks.Any(s => Same(s, title, artist));

        // Returns true when the song is now saved.
        public static bool Toggle(string title, string artist, string source)
        {
            var list = Settings.Current.SavedTracks;
            if (list.Any(s => Same(s, title, artist)))
            {
                Settings.Current.SavedTracks = list.Where(s => !Same(s, title, artist)).ToList();
                return false;
            }
            var fresh = list.ToList();
            fresh.Insert(0, new SavedTrack { Title = title, Artist = artist, Source = source, Saved = DateTime.Now });
            Settings.Current.SavedTracks = fresh;
            return true;
        }

        public static void Remove(SavedTrack track) =>
            Settings.Current.SavedTracks = Settings.Current.SavedTracks.Where(s => !ReferenceEquals(s, track)).ToList();
    }
}
