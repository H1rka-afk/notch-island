using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.4.17 — the optional Yandex account link, as on the Mac
    // (YandexAccountFavorites.swift): with the user's own OAuth token (not
    // the password) the star reads and changes «Мне нравится» directly in
    // the account — for the app and for the browser. The token is kept
    // encrypted for this Windows user only (DPAPI) and is sent only to
    // api.music.yandex.net.
    public static class YandexAccount
    {
        private const string Api = "https://api.music.yandex.net";
        private static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(9) };
        private static string? _uid;
        private static HashSet<string>? _likes;
        private static DateTime _likesAt;
        private static readonly Dictionary<string, string> Resolved = new();
        private static readonly SemaphoreSlim Gate = new SemaphoreSlim(1, 1);

        public static bool Connected => Token != null;

        private static string? Token
        {
            get
            {
                var stored = Settings.Current.YandexToken;
                if (string.IsNullOrEmpty(stored)) return null;
                try
                {
                    var bytes = ProtectedData.Unprotect(Convert.FromBase64String(stored), Entropy, DataProtectionScope.CurrentUser);
                    return Encoding.UTF8.GetString(bytes);
                }
                catch { return null; }
            }
        }

        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Ovira.YandexMusic");

        // Checks the token with Yandex; keeps it only if it works.
        public static async Task<bool> ConnectAsync(string token)
        {
            token = (token ?? "").Trim();
            if (token.Length < 10 || token.Length > 400) return false;
            var uid = await AccountUid(token);
            if (uid == null) return false;
            var sealedToken = ProtectedData.Protect(Encoding.UTF8.GetBytes(token), Entropy, DataProtectionScope.CurrentUser);
            Settings.Current.YandexToken = Convert.ToBase64String(sealedToken);
            _uid = uid;
            _likes = null;
            Resolved.Clear();
            return true;
        }

        public static void Disconnect()
        {
            Settings.Current.YandexToken = "";
            _uid = null;
            _likes = null;
            Resolved.Clear();
        }

        private static async Task<JsonElement?> Query(string path, string token, HttpMethod? method = null, string? form = null)
        {
            try
            {
                using var request = new HttpRequestMessage(method ?? HttpMethod.Get, Api + path);
                request.Headers.TryAddWithoutValidation("Authorization", "OAuth " + token);
                request.Headers.UserAgent.ParseAdd("Ovira-Windows/" + App.Version);
                if (form != null) request.Content = new StringContent(form, Encoding.UTF8, "application/x-www-form-urlencoded");
                using var response = await Http.SendAsync(request);
                if (!response.IsSuccessStatusCode) return null;
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                var root = doc.RootElement;
                if (root.TryGetProperty("error", out _)) return null;
                return (root.TryGetProperty("result", out var result) ? result : root).Clone();
            }
            catch { return null; }
        }

        private static string? Id(JsonElement e) => e.ValueKind switch
        {
            JsonValueKind.String => e.GetString(),
            JsonValueKind.Number => e.GetRawText(),
            _ => null
        };

        private static async Task<string?> AccountUid(string token)
        {
            var r = await Query("/account/status", token);
            if (r is not JsonElement body || !body.TryGetProperty("account", out var account) || !account.TryGetProperty("uid", out var uid)) return null;
            return Id(uid);
        }

        private static string Norm(string s)
        {
            var b = new StringBuilder();
            foreach (var c in (s ?? "").ToLowerInvariant().Replace('ё', 'е')) b.Append(char.IsLetterOrDigit(c) ? c : ' ');
            return string.Join(' ', b.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
        }

        // The song by title AND artist; several different matches → no guess.
        private static async Task<string?> TrackId(TrackInfo t, string token)
        {
            var key = Norm(t.Title) + "|" + Norm(t.Artist);
            if (Resolved.TryGetValue(key, out var known)) return known;
            if (Norm(t.Artist).Length == 0) return null;
            var r = await Query("/search?type=track&page=0&text=" + Uri.EscapeDataString(t.Title + " " + t.Artist), token);
            if (r is not JsonElement body || !body.TryGetProperty("tracks", out var block) || !block.TryGetProperty("results", out var results)) return null;
            var ids = new HashSet<string>();
            foreach (var c in results.EnumerateArray())
            {
                var title = c.TryGetProperty("title", out var tt) ? tt.GetString() ?? "" : "";
                if (Norm(title) != Norm(t.Title)) continue;
                bool artist = c.TryGetProperty("artists", out var artists) && artists.EnumerateArray().Any(a =>
                {
                    var n = Norm(a.TryGetProperty("name", out var nn) ? nn.GetString() ?? "" : "");
                    return n.Length > 0 && (n == Norm(t.Artist) || Norm(t.Artist).Contains(n));
                });
                if (!artist || !c.TryGetProperty("id", out var idEl)) continue;
                var id = Id(idEl);
                if (id != null) ids.Add(id);
            }
            if (ids.Count != 1) return null;
            Resolved[key] = ids.First();
            return ids.First();
        }

        private static async Task<HashSet<string>?> Likes(string token, string uid, bool fresh = false)
        {
            if (!fresh && _likes != null && (DateTime.Now - _likesAt).TotalSeconds < 30) return _likes;
            var r = await Query("/users/" + uid + "/likes/tracks", token);
            if (r is not JsonElement body || !body.TryGetProperty("library", out var library) || !library.TryGetProperty("tracks", out var tracks)) return null;
            var set = new HashSet<string>(tracks.EnumerateArray().Select(x => x.TryGetProperty("id", out var i) ? Id(i) : null).Where(x => x != null)!);
            _likes = set;
            _likesAt = DateTime.Now;
            return set;
        }

        public static async Task<bool?> ReadAsync(TrackInfo t)
        {
            var token = Token;
            if (token == null) return null;
            await Gate.WaitAsync();
            try
            {
                var uid = _uid ??= await AccountUid(token);
                if (uid == null) return null;
                var id = await TrackId(t, token);
                if (id == null) return null;
                var likes = await Likes(token, uid);
                return likes?.Contains(id);
            }
            finally { Gate.Release(); }
        }

        public static async Task<bool?> WriteAsync(TrackInfo t, bool target)
        {
            var token = Token;
            if (token == null) return null;
            await Gate.WaitAsync();
            try
            {
                var uid = _uid ??= await AccountUid(token);
                if (uid == null) return null;
                var id = await TrackId(t, token);
                if (id == null) return null;
                var likes = await Likes(token, uid);
                if (likes == null) return null;
                if (likes.Contains(id) == target) return true;
                var route = target ? "add-multiple" : "remove";
                var r = await Query("/users/" + uid + "/likes/tracks/" + route, token, HttpMethod.Post, "track-ids=" + Uri.EscapeDataString(id));
                if (r == null) return false;
                var verified = await Likes(token, uid, fresh: true);
                return verified != null && verified.Contains(id) == target;
            }
            finally { Gate.Release(); }
        }
    }
}
