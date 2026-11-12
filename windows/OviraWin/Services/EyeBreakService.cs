using System;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Ovira.Core;
using Ovira.Island;

namespace Ovira.Services
{
    // 0.4.2 — the helper from the Mac (EyeBreak.swift, EyeBreakPolicy.swift):
    // counts the time you actually work at the computer (keyboard or mouse in
    // the last minute) and every 20 minutes asks for a 20-second look into the
    // distance, right in the island. Five minutes away from the computer
    // already rested the eyes, so the count starts over. Never during a call
    // (microphone or camera in use) or over a full-screen game or video —
    // then it waits and tries again in 30 seconds.
    // Only the time since the last input is read, never what was pressed.
    public sealed class EyeBreakService
    {
        public const int RestSeconds = 20;
        private const double NaturalBreak = 5 * 60;
        private const double WorkingIdleLimit = 60;

        private readonly DispatcherTimer _check = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        private readonly DispatcherTimer _second = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private DateTime _lastCheck = DateTime.Now;
        private double _worked;
        private int _secondIndex;
        private IslandWindow? _island;

        public bool Running => _second.IsEnabled;
        public double WorkedMinutes => _worked / 60;

        private static Settings S => Settings.Current;

        public void Start(IslandWindow island)
        {
            _island = island;
            _check.Tick += (_, _) => Check();
            _second.Tick += (_, _) => NextSecond();
            _check.Start();
            S.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Settings.EyeBreak)) _worked = 0; };
        }

        public void Stop()
        {
            _check.Stop();
            _second.Stop();
        }

        private void Check()
        {
            var now = DateTime.Now;
            var elapsed = (now - _lastCheck).TotalSeconds;
            _lastCheck = now;
            if (!S.EyeBreak || Running) return;
            var idle = IdleSeconds();
            if (idle >= NaturalBreak) { _worked = 0; return; }
            if (idle < WorkingIdleLimit) _worked += Math.Max(0, Math.Min(elapsed, 120));
            if (_worked < S.EyeBreakMinutes * 60) return;
            if (!CanRemindNow()) return;          // try again in 30 s
            _worked = 0;
            Begin(counts: true);
        }

        private bool CanRemindNow() =>
            (S.GameEyeBreak || !Native.FullscreenAppInFront()) && !(_island?.Busy ?? false) && !InUse("microphone") && !InUse("webcam");

        // The break itself: «Посмотри вдаль», a countdown with a bar, «Готово».
        // A click on the island skips it.
        public void Begin(bool counts = false)
        {
            if (_island == null) return;
            _secondIndex = 0;
            Chime.Play(start: true);
            Present();
            _second.Start();
        }

        private void NextSecond()
        {
            _secondIndex++;
            if (_secondIndex >= RestSeconds)
            {
                _second.Stop();
                Chime.Play(start: false);
                _island?.ShowEyeBreakDone();
                App.Current.Stats.Record(StatEvent.EyeBreak);
                return;
            }
            Present();
        }

        private void Present()
        {
            int left = RestSeconds - _secondIndex;
            _island?.ShowEyeBreak(_secondIndex, RestSeconds, Skip);
        }

        public void Skip()
        {
            if (!Running) return;
            _second.Stop();
            _island?.ShowEyeBreakSkipped();
            App.Current.Stats.Record(StatEvent.EyeSkipped);
        }

        // ---- the system ----

        [StructLayout(LayoutKind.Sequential)]
        private struct LastInputInfo { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LastInputInfo info);

        private static double IdleSeconds()
        {
            var info = new LastInputInfo { cbSize = (uint)Marshal.SizeOf<LastInputInfo>() };
            if (!GetLastInputInfo(ref info)) return 0;
            return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
        }

        // Windows notes which apps use the microphone or camera right now
        // (the same list as the privacy indicator on the taskbar).
        private static bool InUse(string capability)
        {
            try
            {
                using var root = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\" + capability);
                if (root == null) return false;
                if (AnyActive(root)) return true;
                using var nonPackaged = root.OpenSubKey("NonPackaged");
                return nonPackaged != null && AnyActive(nonPackaged);
            }
            catch { return false; }
        }

        private static bool AnyActive(RegistryKey key)
        {
            foreach (var name in key.GetSubKeyNames())
            {
                if (name == "NonPackaged") continue;
                using var app = key.OpenSubKey(name);
                if (app?.GetValue("LastUsedTimeStart") is long start && start > 0 &&
                    app.GetValue("LastUsedTimeStop") is long stop && stop == 0)
                    return true;
            }
            return false;
        }
    }

    // A short, soft chime for the start and the end of the break (the Mac
    // plays the quiet «Purr» and «Glass»). Made on the fly, nothing to ship.
    internal static class Chime
    {
        public static void Play(bool start, bool force = false)
        {
            if (!force && !Settings.Current.EyeBreakSound) return;
            try
            {
                // The device's own rate and channels, so Windows needs no converter.
                int rate = 48000, channels = 2;
                try
                {
                    using var enumerator = new MMDeviceEnumerator();
                    var mix = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).AudioClient.MixFormat;
                    rate = mix.SampleRate;
                    channels = Math.Max(1, mix.Channels);
                }
                catch { }
                var player = new WasapiOut(AudioClientShareMode.Shared, 120);
                player.Init(new ChimeProvider(start, rate, channels));
                player.PlaybackStopped += (_, _) => player.Dispose();
                player.Play();
            }
            catch { }
        }

        private sealed class ChimeProvider : ISampleProvider
        {
            private readonly double[] _notes;
            private readonly double _length;
            private int _index;
            private readonly int _rate, _channels;
            public WaveFormat WaveFormat { get; }

            public ChimeProvider(bool start, int rate, int channels)
            {
                _rate = rate;
                _channels = channels;
                WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(rate, channels);
                // Start: two warm low notes going up; end: one clear high bell.
                _notes = start ? new[] { 523.25, 783.99 } : new[] { 1318.5 };
                _length = start ? 0.75 : 0.9;
            }

            public int Read(float[] buffer, int offset, int count)
            {
                int total = (int)(_length * _rate);
                int n = 0;
                for (; n + _channels <= count && _index < total; n += _channels, _index++)
                {
                    double t = _index / (double)_rate;
                    double v = 0;
                    for (int k = 0; k < _notes.Length; k++)
                    {
                        double begin = k * 0.14;
                        if (t < begin) continue;
                        double u = t - begin;
                        double attack = Math.Min(1, u / 0.012);
                        double decay = Math.Exp(-u * (_notes.Length > 1 ? 5.5 : 4.2));
                        v += Math.Sin(2 * Math.PI * _notes[k] * u) * attack * decay
                           + 0.25 * Math.Sin(4 * Math.PI * _notes[k] * u) * attack * decay * decay;
                    }
                    for (int c = 0; c < _channels; c++) buffer[offset + n + c] = (float)(v * 0.11);
                }
                return n;
            }
        }
    }
}
