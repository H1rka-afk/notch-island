using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.4.2 — updates, as on the Mac (AppUpdater.swift): at the interval
    // chosen in Settings Ovira looks at its public releases page for a newer
    // «win-v…» build, downloads the zip in the background and offers it in
    // the island and the tray. Installing swaps Ovira.exe next to itself
    // (a running .exe may be renamed on Windows) and starts the new one —
    // no installer, no admin rights.
    public sealed class UpdateService
    {
        public enum UpdateState { Idle, Checking, Downloading, Ready, Installing, UpToDate, Failed }

        private const string ReleasesApi = "https://api.github.com/repos/H1rka-afk/notch-island-releases/releases?per_page=30";
        public const string ReleasesPage = "https://github.com/H1rka-afk/notch-island-releases/releases";

        public UpdateState State { get; private set; } = UpdateState.Idle;
        public string? NewVersion { get; private set; }
        public string Message { get; private set; } = "";
        public event Action? Changed;
        public event Action<string>? Ready;

        private string? _zip;
        private readonly DispatcherTimer _timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(10) };
        private static readonly HttpClient Http = MakeClient();

        private static HttpClient MakeClient()
        {
            var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Ovira-Windows/" + App.Version);
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            return http;
        }

        public static string Folder => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ovira", "Updates");

        private static Settings S => Settings.Current;

        public void Start()
        {
            _timer.Tick += (_, _) => { if (Due) _ = CheckAsync(); };
            _timer.Start();
            // Shortly after launch, then at the chosen interval.
            var first = new DispatcherTimer { Interval = TimeSpan.FromSeconds(25) };
            first.Tick += (_, _) => { first.Stop(); if (Due) _ = CheckAsync(); };
            first.Start();
            S.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName is nameof(Settings.UpdateIntervalHours) or nameof(Settings.CheckUpdates) && Due) _ = CheckAsync();
            };
        }

        private static bool Due => S.CheckUpdates && (DateTime.Now - S.LastUpdateCheck).TotalHours >= S.UpdateIntervalHours;

        private void Set(UpdateState state, string message)
        {
            State = state;
            Message = message;
            Changed?.Invoke();
        }

        public async Task CheckAsync(bool force = false)
        {
            if (State is UpdateState.Checking or UpdateState.Downloading or UpdateState.Installing) return;
            if (State == UpdateState.Ready && !force) return;
            Set(UpdateState.Checking, "Проверяю…");
            S.LastUpdateCheck = DateTime.Now;
            try
            {
                var json = await Http.GetStringAsync(ReleasesApi);
                using var doc = JsonDocument.Parse(json);
                Version? best = null;
                JsonElement bestAsset = default;
                foreach (var release in doc.RootElement.EnumerateArray())
                {
                    if (release.TryGetProperty("draft", out var draft) && draft.GetBoolean()) continue;
                    var tag = release.GetProperty("tag_name").GetString() ?? "";
                    if (!tag.StartsWith("win-v", StringComparison.Ordinal)) continue;
                    if (!Version.TryParse(tag.Substring(5), out var v)) continue;
                    if (best != null && v <= best) continue;
                    foreach (var asset in release.GetProperty("assets").EnumerateArray())
                    {
                        var name = asset.GetProperty("name").GetString() ?? "";
                        if (name.StartsWith("Ovira-Windows", StringComparison.Ordinal) && name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                        {
                            best = v;
                            bestAsset = asset.Clone();
                            break;
                        }
                    }
                }
                var current = Version.Parse(App.Version);
                if (best == null || best <= current)
                {
                    Set(UpdateState.UpToDate, "У тебя последняя версия · " + App.Version);
                    return;
                }
                var version = best.ToString(3);
                var assetName = bestAsset.GetProperty("name").GetString()!;
                var url = bestAsset.GetProperty("browser_download_url").GetString()!;
                long size = bestAsset.TryGetProperty("size", out var sz) ? sz.GetInt64() : 0;
                string? digest = bestAsset.TryGetProperty("digest", out var dg) && dg.ValueKind == JsonValueKind.String ? dg.GetString() : null;

                Directory.CreateDirectory(Folder);
                var target = Path.Combine(Folder, assetName);
                if (!(File.Exists(target) && (size == 0 || new FileInfo(target).Length == size) && DigestMatches(target, digest)))
                {
                    Set(UpdateState.Downloading, "Скачиваю " + version + "…");
                    foreach (var old in Directory.GetFiles(Folder, "*.zip")) TryDelete(old);
                    var partial = target + ".part";
                    using (var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
                    {
                        response.EnsureSuccessStatusCode();
                        await using var stream = await response.Content.ReadAsStreamAsync();
                        await using var file = File.Create(partial);
                        await stream.CopyToAsync(file);
                    }
                    if (size > 0 && new FileInfo(partial).Length != size) throw new IOException("размер файла не совпал");
                    if (!DigestMatches(partial, digest)) throw new IOException("контрольная сумма не совпала");
                    File.Move(partial, target, true);
                }
                _zip = target;
                NewVersion = version;
                Set(UpdateState.Ready, "Готово к установке: " + version);
                Ready?.Invoke(version);
            }
            catch (Exception e)
            {
                Set(UpdateState.Failed, "Не удалось проверить: " + Short(e));
            }
        }

        private static string Short(Exception e) => e is HttpRequestException ? "нет связи с GitHub" : e.Message;

        private static bool DigestMatches(string path, string? digest)
        {
            if (string.IsNullOrEmpty(digest) || !digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) return true;
            try
            {
                using var file = File.OpenRead(path);
                var hash = Convert.ToHexString(SHA256.HashData(file));
                return string.Equals(hash, digest.Substring(7), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        // Swap the files and start the new Ovira. If anything fails, the old
        // Ovira.exe is put back and keeps running.
        public void Install()
        {
            if (State != UpdateState.Ready || _zip == null || NewVersion == null) return;
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            var dir = Path.GetDirectoryName(exe)!;
            var old = exe + ".old";
            Set(UpdateState.Installing, "Устанавливаю " + NewVersion + "…");
            bool moved = false;
            try
            {
                var staging = Path.Combine(Folder, "staging");
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
                ZipFile.ExtractToDirectory(_zip, staging);
                var newExe = Directory.GetFiles(staging, "Ovira.exe", SearchOption.AllDirectories).FirstOrDefault()
                             ?? throw new IOException("в архиве нет Ovira.exe");
                var info = FileVersionInfo.GetVersionInfo(newExe);
                if (!(info.ProductVersion ?? "").StartsWith(NewVersion, StringComparison.Ordinal))
                    throw new IOException("в архиве другая версия");
                var source = Path.GetDirectoryName(newExe)!;

                if (File.Exists(old)) File.Delete(old);
                File.Move(exe, old);
                moved = true;
                foreach (var file in Directory.GetFiles(source))
                    File.Copy(file, Path.Combine(dir, Path.GetFileName(file)), true);

                Settings.Current.Save();
                Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = false, WorkingDirectory = dir });
                App.Current.Quit();
            }
            catch (Exception e)
            {
                if (moved && !File.Exists(exe)) { try { File.Move(old, exe); } catch { } }
                var reason = e is UnauthorizedAccessException
                    ? "нет доступа к папке Ovira — перенеси её, например, в «Документы»"
                    : e.Message;
                Set(UpdateState.Ready, "Не получилось установить: " + reason);
            }
        }

        // On start: the previous Ovira.exe and the unpacked copy are not needed.
        public static void CleanUp()
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe)) TryDelete(exe + ".old");
            try
            {
                var staging = Path.Combine(Folder, "staging");
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
            }
            catch { }
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }
}
