using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Media.Control;

namespace Ovira.Services
{
    public sealed class TrackInfo
    {
        public string Title = "";
        public string Artist = "";
        public string Album = "";
        public string Source = "";            // «Spotify», «Яндекс Музыка», «Chrome»…
        public bool Playing;
        public BitmapSource? Artwork;
        public Color Tint = Color.FromRgb(0xFF, 0x5A, 0x7A);
        public TimeSpan Position;
        public TimeSpan Duration;
        public DateTimeOffset PositionUpdated = DateTimeOffset.Now;

        public TimeSpan LivePosition
        {
            get
            {
                if (!Playing) return Position;
                var p = Position + (DateTimeOffset.Now - PositionUpdated);
                return Duration > TimeSpan.Zero && p > Duration ? Duration : p;
            }
        }
    }

    // Whatever plays music on Windows — Spotify, Яндекс Музыка, a browser —
    // through the system media sessions (the same ones the volume flyout uses).
    public sealed class MediaService
    {
        public event Action<TrackInfo?>? Changed;
        public event Action<TrackInfo>? TimelineChanged;
        public TrackInfo? Track { get; private set; }

        private GlobalSystemMediaTransportControlsSessionManager? _manager;
        private GlobalSystemMediaTransportControlsSession? _session;
        private string _artKey = "";

        public async Task StartAsync()
        {
            try
            {
                _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
                _manager.CurrentSessionChanged += (_, _) => OnUi(Attach);
                _manager.SessionsChanged += (_, _) => OnUi(Attach);
                Attach();
            }
            catch
            {
                Track = null;
                Changed?.Invoke(null);
            }
        }

        private static void OnUi(Action action) =>
            Application.Current?.Dispatcher.BeginInvoke(action);

        private void Attach()
        {
            if (_manager == null) return;
            var next = _manager.GetCurrentSession()
                       ?? _manager.GetSessions().FirstOrDefault(s =>
                              s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing);
            if (!ReferenceEquals(next, _session))
            {
                if (_session != null)
                {
                    _session.MediaPropertiesChanged -= OnMediaChanged;
                    _session.PlaybackInfoChanged -= OnPlaybackChanged;
                    _session.TimelinePropertiesChanged -= OnTimelineChanged;
                }
                _session = next;
                if (_session != null)
                {
                    _session.MediaPropertiesChanged += OnMediaChanged;
                    _session.PlaybackInfoChanged += OnPlaybackChanged;
                    _session.TimelinePropertiesChanged += OnTimelineChanged;
                }
            }
            _ = RefreshAsync();
        }

        private void OnMediaChanged(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) => OnUi(() => _ = RefreshAsync());
        private void OnPlaybackChanged(GlobalSystemMediaTransportControlsSession s, PlaybackInfoChangedEventArgs e) => OnUi(() => _ = RefreshAsync());
        private void OnTimelineChanged(GlobalSystemMediaTransportControlsSession s, TimelinePropertiesChangedEventArgs e) => OnUi(RefreshTimeline);

        private async Task RefreshAsync()
        {
            var session = _session;
            if (session == null)
            {
                Track = null;
                Changed?.Invoke(null);
                return;
            }
            try
            {
                var props = await session.TryGetMediaPropertiesAsync();
                if (!ReferenceEquals(session, _session)) return;
                if (props == null || string.IsNullOrWhiteSpace(props.Title))
                {
                    Track = null;
                    Changed?.Invoke(null);
                    return;
                }
                var info = Track ?? new TrackInfo();
                bool newSong = info.Title != props.Title || info.Artist != props.Artist;
                info.Title = props.Title;
                info.Artist = string.IsNullOrWhiteSpace(props.Artist) ? props.AlbumArtist ?? "" : props.Artist;
                info.Album = props.AlbumTitle ?? "";
                info.Source = AppName(session.SourceAppUserModelId);
                info.Playing = session.GetPlaybackInfo()?.PlaybackStatus ==
                               GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
                ApplyTimeline(info, session);

                var key = info.Title + "|" + info.Artist + "|" + info.Album;
                if (newSong || key != _artKey || info.Artwork == null)
                {
                    _artKey = key;
                    info.Artwork = null;
                    if (props.Thumbnail != null)
                    {
                        var image = await LoadArtwork(props.Thumbnail);
                        if (image != null)
                        {
                            info.Artwork = image;
                            // 0.4.16: off the window's thread (it is busy animating the buttons).
                            info.Tint = await Task.Run(() => AverageColour(image));
                        }
                    }
                }
                Track = info;
                Changed?.Invoke(info);
            }
            catch
            {
                // A player that went away between two calls — try again later.
            }
        }

        private void RefreshTimeline()
        {
            if (_session == null || Track == null) return;
            try
            {
                // 0.4.12: only the position moved — no «Changed» for the whole
                // app (browsers report it every second); the island reads the
                // position by itself while the player is open.
                ApplyTimeline(Track, _session);
                TimelineChanged?.Invoke(Track);
            }
            catch { }
        }

        private static void ApplyTimeline(TrackInfo info, GlobalSystemMediaTransportControlsSession session)
        {
            var t = session.GetTimelineProperties();
            if (t == null) return;
            info.Duration = t.EndTime - t.StartTime;
            info.Position = t.Position - t.StartTime;
            info.PositionUpdated = t.LastUpdatedTime;
            if (info.PositionUpdated.Year < 2000) info.PositionUpdated = DateTimeOffset.Now;
        }

        private static async Task<BitmapSource?> LoadArtwork(Windows.Storage.Streams.IRandomAccessStreamReference reference)
        {
            try
            {
                using var stream = await reference.OpenReadAsync();
                using var net = stream.AsStreamForRead();
                var memory = new MemoryStream();
                await net.CopyToAsync(memory);
                memory.Position = 0;
                // 0.4.16: the picture is decoded in the background — decoding on
                // the window's thread made the skip buttons stutter.
                return await Task.Run(() =>
                {
                    var bitmap = new BitmapImage();
                    bitmap.BeginInit();
                    bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.DecodePixelWidth = 200;
                    bitmap.StreamSource = memory;
                    bitmap.EndInit();
                    bitmap.Freeze();
                    return (BitmapSource)bitmap;
                });
            }
            catch { return null; }
        }

        // The cover's average colour, a little brighter — for the bars and glow.
        private static Color AverageColour(BitmapSource image)
        {
            try
            {
                var small = new TransformedBitmap(image, new ScaleTransform(16.0 / image.PixelWidth, 16.0 / image.PixelHeight));
                var converted = new FormatConvertedBitmap(small, PixelFormats.Bgra32, null, 0);
                int w = converted.PixelWidth, h = converted.PixelHeight;
                var pixels = new byte[w * h * 4];
                converted.CopyPixels(pixels, w * 4, 0);
                double r = 0, g = 0, b = 0, n = 0;
                for (int i = 0; i < pixels.Length; i += 4)
                {
                    double pb = pixels[i], pg = pixels[i + 1], pr = pixels[i + 2];
                    double max = Math.Max(pr, Math.Max(pg, pb)), min = Math.Min(pr, Math.Min(pg, pb));
                    double weight = 0.2 + (max - min) / 255.0;           // prefer colourful pixels
                    r += pr * weight; g += pg * weight; b += pb * weight; n += weight;
                }
                if (n <= 0) return Color.FromRgb(0xFF, 0x5A, 0x7A);
                r /= n; g /= n; b /= n;
                double top = Math.Max(r, Math.Max(g, b));
                double lift = top < 150 ? 150 / Math.Max(1, top) : 1;
                return Color.FromRgb((byte)Math.Min(255, r * lift), (byte)Math.Min(255, g * lift), (byte)Math.Min(255, b * lift));
            }
            catch { return Color.FromRgb(0xFF, 0x5A, 0x7A); }
        }

        private static string AppName(string id)
        {
            var s = (id ?? "").ToLowerInvariant();
            if (s.Contains("spotify")) return "Spotify";
            if (s.Contains("yandex.music") || s.Contains("yandexmusic") || (s.Contains("yandex") && s.Contains("music")) ||
                s.Contains("яндекс музыка")) return "Яндекс Музыка";
            if (s.Contains("chrome")) return "Chrome";
            if (s.Contains("msedge") || s.Contains("microsoftedge")) return "Edge";
            if (s.Contains("firefox")) return "Firefox";
            if (s.Contains("yandex")) return "Яндекс Браузер";
            if (s.Contains("opera")) return "Opera";
            if (s.Contains("zunemusic") || s.Contains("media player")) return "Медиаплеер";
            if (s.Contains("vlc")) return "VLC";
            if (s.Contains("applemusic") || s.Contains("itunes")) return "Apple Music";
            if (s.Contains("telegram")) return "Telegram";
            if (s.Contains("vk")) return "VK";
            var name = Path.GetFileNameWithoutExtension(id ?? "");
            return string.IsNullOrEmpty(name) ? "Музыка" : name;
        }

        // 0.8.3: «по кругу» — the player's own repeat setting (if it has one)
        public bool? RepeatOne
        {
            get
            {
                try { return _session?.GetPlaybackInfo()?.AutoRepeatMode is { } m ? m == global::Windows.Media.MediaPlaybackAutoRepeatMode.Track : null; }
                catch { return null; }
            }
        }

        // Many players (Spotify, Yandex Music in the browser…) don't let others
        // change their repeat; then Ovira loops the song itself: a moment
        // before the end it jumps back to the start (and if the player still
        // moved on, it steps back to the song).
        // 0.8.4: the button shows what was asked for, not what the player
        // reports — some players say «done» and ignore it, others never say.
        // Ovira's own loop always runs while repeat is on (harmless if the
        // player repeats by itself too).
        public bool RepeatWanted { get; private set; }
        private System.Windows.Threading.DispatcherTimer? _loop;
        private string _loopKey = "";
        private bool _loopNearEnd;
        private DateTime _loopJump = DateTime.MinValue;

        public bool Looping => RepeatWanted;

        public async System.Threading.Tasks.Task<bool> SetRepeatAsync(bool one)
        {
            RepeatWanted = one;
            _loopKey = Track != null ? Track.Title + "\u0001" + Track.Artist : "";
            _loopNearEnd = false;
            _loop ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            _loop.Tick -= LoopTick;
            _loop.Tick += LoopTick;
            if (one) _loop.Start(); else _loop.Stop();
            try
            {
                if (_session != null)
                    await _session.TryChangeAutoRepeatModeAsync(one ? global::Windows.Media.MediaPlaybackAutoRepeatMode.Track : global::Windows.Media.MediaPlaybackAutoRepeatMode.None);
            }
            catch { }
            return true;
        }

        private void LoopTick(object? sender, EventArgs e)
        {
            var t = Track;
            if (t == null || !RepeatWanted) return;
            var key = t.Title + "\u0001" + t.Artist;
            if (key != _loopKey)
            {
                // the player moved on by itself right at the end — go back
                if (_loopNearEnd && _loopKey.Length > 0 && (DateTime.Now - _loopJump).TotalSeconds > 2)
                {
                    _loopJump = DateTime.Now;
                    Previous();
                    return;
                }
                if ((DateTime.Now - _loopJump).TotalSeconds > 4) { _loopKey = key; _loopNearEnd = false; }   // a song picked by hand loops from now on
                return;
            }
            if (t.Duration.TotalSeconds < 5) return;
            var left = t.Duration - t.LivePosition;
            if (t.Playing) _loopNearEnd = left.TotalSeconds < 4;
            if (t.Playing && left.TotalSeconds < 1.0 && (DateTime.Now - _loopJump).TotalSeconds > 2)
            {
                _loopJump = DateTime.Now;
                Seek(TimeSpan.Zero);
            }
        }

        public async void PlayPause() { try { if (_session != null) await _session.TryTogglePlayPauseAsync(); } catch { } }
        public async void Next() { try { if (_session != null) await _session.TrySkipNextAsync(); } catch { } }
        public async void Previous() { try { if (_session != null) await _session.TrySkipPreviousAsync(); } catch { } }

        public async void Seek(TimeSpan position)
        {
            try
            {
                if (_session == null) return;
                var start = _session.GetTimelineProperties()?.StartTime ?? TimeSpan.Zero;
                await _session.TryChangePlaybackPositionAsync((start + position).Ticks);
            }
            catch { }
        }
    }
}
