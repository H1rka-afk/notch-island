using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
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

        // 0.4.4: the Windows builds are found by their tags («win-v…») — the
        // plain list of releases starts with the many Mac versions, and the
        // Windows ones did not fit on its first page («последняя версия»).
        private const string Repo = "https://api.github.com/repos/H1rka-afk/notch-island-releases";
        private const string TagsApi = Repo + "/git/matching-refs/tags/win-v";
        public const string ReleasesPage = "https://github.com/H1rka-afk/notch-island-releases/releases";

        public UpdateState State { get; private set; } = UpdateState.Idle;
        public string? NewVersion { get; private set; }
        public string Message { get; private set; } = "";
        public event Action? Changed;
        public event Action<string>? Ready;

        private string? _zip;
        private readonly DispatcherTimer _timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(10) };
        private static readonly HttpClient Http = MakeClient();

        // 0.4.13: no overall time limit — a 90 MB archive on a slow line took
        // longer than the old 5 minutes and was thrown away. Instead a download
        // only gives up when nothing arrives for a minute, and continues from
        // where it stopped next time.
        private static HttpClient MakeClient()
        {
            var http = new HttpClient { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Ovira-Windows/" + App.Version);
            return http;
        }

        public System.Collections.Generic.List<string> Notes { get; private set; } = new();
        public double Progress { get; private set; }
        private DateTime _lastAttempt = DateTime.MinValue;

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

        // The interval counts from the last check that worked; after a failure
        // (no internet, GitHub busy) it tries again in 10 minutes.
        private bool Due
        {
            get
            {
                if (!S.CheckUpdates) return false;
                if (State == UpdateState.Failed) return (DateTime.Now - _lastAttempt).TotalMinutes >= 10;
                return (DateTime.Now - S.LastUpdateCheck).TotalHours >= S.UpdateIntervalHours;
            }
        }

        private void Set(UpdateState state, string message)
        {
            State = state;
            Message = message;
            Changed?.Invoke();
        }

        private static async Task<JsonDocument> GetJson(string url)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            using var response = await Http.SendAsync(request, cts.Token);
            response.EnsureSuccessStatusCode();
            return JsonDocument.Parse(await response.Content.ReadAsStringAsync(cts.Token));
        }

        public async Task CheckAsync(bool force = false)
        {
            if (State is UpdateState.Checking or UpdateState.Downloading or UpdateState.Installing) return;
            if (State == UpdateState.Ready && !force) return;
            _lastAttempt = DateTime.Now;
            Set(UpdateState.Checking, "Проверяю…");
            try
            {
                Version? best = null;
                using (var tags = await GetJson(TagsApi))
                {
                    foreach (var tag in tags.RootElement.EnumerateArray())
                    {
                        var name = (tag.GetProperty("ref").GetString() ?? "").Replace("refs/tags/win-v", "");
                        if (Version.TryParse(name, out var v) && (best == null || v > best)) best = v;
                    }
                }
                var current = Version.Parse(App.Version);
                if (best == null || best <= current)
                {
                    S.LastUpdateCheck = DateTime.Now;
                    Set(UpdateState.UpToDate, "У тебя последняя версия · " + App.Version);
                    return;
                }
                var version = best.ToString(3);
                JsonElement asset = default;
                bool found = false;
                using (var release = await GetJson(Repo + "/releases/tags/win-v" + version))
                {
                    foreach (var a in release.RootElement.GetProperty("assets").EnumerateArray())
                    {
                        var n = a.GetProperty("name").GetString() ?? "";
                        if (n.StartsWith("Ovira-Windows", StringComparison.Ordinal) && n.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                        {
                            asset = a.Clone();
                            found = true;
                            break;
                        }
                    }
                    var text = release.RootElement.TryGetProperty("body", out var b) && b.ValueKind == JsonValueKind.String ? b.GetString() : null;
                    Notes = ParseNotes(text, version);
                }
                if (!found) throw new IOException("у версии " + version + " ещё нет архива");

                var assetName = asset.GetProperty("name").GetString()!;
                var url = asset.GetProperty("browser_download_url").GetString()!;
                long size = asset.TryGetProperty("size", out var sz) ? sz.GetInt64() : 0;
                string? digest = asset.TryGetProperty("digest", out var dg) && dg.ValueKind == JsonValueKind.String ? dg.GetString() : null;

                Directory.CreateDirectory(Folder);
                var target = Path.Combine(Folder, assetName);
                bool have = File.Exists(target) && (size == 0 || new FileInfo(target).Length == size) &&
                            await Task.Run(() => DigestMatches(target, digest));
                if (!have)
                {
                    foreach (var old in Directory.GetFiles(Folder, "*.zip")) TryDelete(old);
                    foreach (var old in Directory.GetFiles(Folder, "*.part"))
                        if (!string.Equals(old, target + ".part", StringComparison.OrdinalIgnoreCase)) TryDelete(old);
                    await Download(url, target + ".part", size, version);
                    if (size > 0 && new FileInfo(target + ".part").Length != size)
                        throw new IOException("файл скачался не полностью");
                    if (!await Task.Run(() => DigestMatches(target + ".part", digest)))
                    {
                        TryDelete(target + ".part");
                        throw new IOException("файл повреждён при скачивании — скачаю заново");
                    }
                    File.Move(target + ".part", target, true);
                }
                _zip = target;
                NewVersion = version;
                S.LastUpdateCheck = DateTime.Now;
                Set(UpdateState.Ready, "Готово к установке: " + version);
                Ready?.Invoke(version);
            }
            catch (Exception e)
            {
                Set(UpdateState.Failed, "Не получилось: " + Short(e) + ". Попробую снова через 10 минут");
            }
        }

        // Continues a broken download (HTTP Range) and shows the percent.
        private async Task Download(string url, string partial, long size, string version)
        {
            long have = File.Exists(partial) ? new FileInfo(partial).Length : 0;
            if (size > 0 && have > size) { TryDelete(partial); have = 0; }
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Accept.ParseAdd("application/octet-stream");
            if (have > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);
            using var start = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, start.Token);
            response.EnsureSuccessStatusCode();
            bool append = have > 0 && response.StatusCode == System.Net.HttpStatusCode.PartialContent;
            if (!append) have = 0;
            await using var stream = await response.Content.ReadAsStreamAsync();
            await using var file = new FileStream(partial, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true);
            var buffer = new byte[1 << 16];
            long done = have;
            int lastPercent = -1;
            while (true)
            {
                using var stall = new CancellationTokenSource(TimeSpan.FromSeconds(60));
                int read = await stream.ReadAsync(buffer, stall.Token);
                if (read <= 0) break;
                await file.WriteAsync(buffer.AsMemory(0, read));
                done += read;
                int percent = size > 0 ? (int)(done * 100 / size) : 0;
                if (percent != lastPercent)
                {
                    lastPercent = percent;
                    Progress = percent / 100.0;
                    Set(UpdateState.Downloading, size > 0 ? $"Скачиваю {version} · {percent} %" : $"Скачиваю {version}…");
                }
            }
        }

        // «Что нового в 0.4.13» from the release text: the dash lines of that block.
        private static System.Collections.Generic.List<string> ParseNotes(string? text, string version)
        {
            var list = new System.Collections.Generic.List<string>();
            if (string.IsNullOrEmpty(text)) return list;
            var lines = text.Replace("\r", "").Split('\n');
            int i = Array.FindIndex(lines, l => l.TrimStart().StartsWith("Что нового в " + version, StringComparison.Ordinal));
            if (i < 0) return list;
            for (i++; i < lines.Length; i++)
            {
                var line = lines[i].Trim();
                if (line.Length == 0) { if (list.Count > 0) break; continue; }
                if (line.StartsWith("Что нового", StringComparison.Ordinal)) break;
                if (line.StartsWith("- ")) list.Add(line.Substring(2).Trim());
                else if (list.Count > 0) list[^1] += " " + line;
            }
            return list;
        }

        private static string Short(Exception e) => e switch
        {
            HttpRequestException => "нет связи с GitHub",
            OperationCanceledException => "GitHub не отвечает",
            _ => e.Message.TrimEnd('.')
        };

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
        public async void Install()
        {
            if (State != UpdateState.Ready || _zip == null || NewVersion == null) return;
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            var dir = Path.GetDirectoryName(exe)!;
            var old = exe + ".old";
            var version = NewVersion;
            var zip = _zip;
            Set(UpdateState.Installing, "Устанавливаю " + version + "…");
            bool moved = false;
            try
            {
                // Unpacking 90 MB takes a few seconds — not on the window's thread.
                var source = await Task.Run(() =>
                {
                    var staging = Path.Combine(Folder, "staging");
                    if (Directory.Exists(staging)) Directory.Delete(staging, true);
                    ZipFile.ExtractToDirectory(zip, staging);
                    var newExe = Directory.GetFiles(staging, "Ovira.exe", SearchOption.AllDirectories).FirstOrDefault()
                                 ?? throw new IOException("в архиве нет Ovira.exe");
                    var info = FileVersionInfo.GetVersionInfo(newExe);
                    if (!(info.ProductVersion ?? "").StartsWith(version, StringComparison.Ordinal))
                        throw new IOException("в архиве другая версия");
                    return Path.GetDirectoryName(newExe)!;
                });

                // An Ovira.exe.old still held by an earlier copy gets a fresh name.
                if (File.Exists(old))
                {
                    try { File.Delete(old); }
                    catch { old = exe + "." + DateTime.Now.Ticks + ".old"; }
                }
                File.Move(exe, old);
                moved = true;
                foreach (var file in Directory.GetFiles(source))
                    File.Copy(file, Path.Combine(dir, Path.GetFileName(file)), true);

                Settings.Current.Save();
                var started = Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = false, WorkingDirectory = dir });
                if (started == null) throw new IOException("новая версия не запустилась");
                App.Current.Quit();
                // Whatever still runs in the background must not keep this
                // copy alive — the new one waits for it.
                var bye = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
                bye.Tick += (_, _) => Environment.Exit(0);
                bye.Start();
                _ = Task.Delay(5000).ContinueWith(_ => Environment.Exit(0));
            }
            catch (Exception e)
            {
                if (moved)
                {
                    // Put the old Ovira.exe back, even over a half-copied new one.
                    try { if (File.Exists(exe)) File.Delete(exe); File.Move(old, exe); } catch { }
                }
                var reason = e is UnauthorizedAccessException
                    ? "нет доступа к папке Ovira — перенеси её, например, в «Документы»"
                    : e.Message.TrimEnd('.');
                Set(UpdateState.Ready, "Не получилось установить: " + reason);
            }
        }

        // On start: the previous Ovira.exe and the unpacked copy are not needed.
        // The old copy may still be closing — try again a bit later.
        public static void CleanUp()
        {
            void Sweep()
            {
                var exe = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exe))
                {
                    var dir = Path.GetDirectoryName(exe)!;
                    var name = Path.GetFileName(exe);
                    try { foreach (var f in Directory.GetFiles(dir, name + "*.old")) TryDelete(f); } catch { }
                }
                try
                {
                    var staging = Path.Combine(Folder, "staging");
                    if (Directory.Exists(staging)) Directory.Delete(staging, true);
                }
                catch { }
            }
            Sweep();
            var later = new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
            later.Tick += (_, _) => { later.Stop(); Sweep(); };
            later.Start();
        }

        // Started with --updated but the old copy did not let go: close it.
        // Only our own previous Ovira (renamed to *.old next to us) is touched.
        public static void CloseOldCopy()
        {
            try
            {
                var exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return;
                var me = Environment.ProcessId;
                foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe)))
                {
                    try
                    {
                        if (p.Id == me) continue;
                        var path = p.MainModule?.FileName ?? "";
                        // Windows may report it under its old or its new (.old) name.
                        if (string.Equals(path, exe, StringComparison.OrdinalIgnoreCase) ||
                            (path.StartsWith(exe, StringComparison.OrdinalIgnoreCase) && path.EndsWith(".old", StringComparison.OrdinalIgnoreCase)))
                        {
                            p.Kill();
                            p.WaitForExit(3000);
                        }
                    }
                    catch { }
                    finally { p.Dispose(); }
                }
            }
            catch { }
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }
}
