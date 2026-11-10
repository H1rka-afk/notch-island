using System;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Ovira.Services
{
    // 0.3.0 — the REAL spectrogram, ported from the Mac (SystemAudioAnalyzer
    // + SpectrumTuning): what Windows actually plays (WASAPI loopback), split
    // into six bands by cascaded low-pass filters (75 Hz … 9.5 kHz), each band
    // normalised against its own recent peak, attack fast / release slower.
    // Samples are analysed in memory and thrown away — nothing is recorded.
    public sealed class SpectrumService : IDisposable
    {
        public const int Bands = 6;

        // Read by the island on every frame (no events — like the Mac store).
        public double[] Levels { get; } = new double[Bands];
        public bool Live { get; private set; }

        private WasapiLoopbackCapture? _capture;
        private readonly object _gate = new object();
        private readonly double[] _lowpass = new double[12];
        private readonly double[] _peaks = new double[Bands];
        private readonly double[] _targets = new double[Bands];
        private readonly double[] _smooth = new double[Bands];
        private double[] _coefficients = new double[Bands];
        private double _coefficientRate;
        private DateTime _lastPresentation = DateTime.MinValue;
        private DateTime _lastSound = DateTime.MinValue;
        private readonly MMDeviceEnumerator _enumerator = new MMDeviceEnumerator();
        private Timer? _watchdog;

        // Same defaults as «Как на iPhone» on the Mac.
        public double Sensitivity = 1.0, Attack = 1.0, Release = 1.0, BassBoost = 1.0, NoiseGate = 1.0;

        public SpectrumService()
        {
            for (int i = 0; i < Bands; i++) _peaks[i] = 0.004;
        }

        public void Start()
        {
            // 0.4.2: nothing is opened until music plays (see Wanted).
            // The default output can change (headphones in): re-open then.
            _watchdog = new Timer(_ => CheckDevice(), null, TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(3));
        }

        private volatile bool _wanted;

        // 0.4.2: listen only while something plays; in silence the capture
        // is closed and the processor rests.
        public bool Wanted
        {
            get => _wanted;
            set
            {
                if (_wanted == value) return;
                _wanted = value;
                ThreadPool.QueueUserWorkItem(_ => { if (_wanted) Restart(); else Close(); });
            }
        }

        private void Close()
        {
            lock (_gate)
            {
                if (_wanted) return;
                try
                {
                    _capture?.StopRecording();
                    _capture?.Dispose();
                }
                catch { }
                _capture = null;
                _deviceId = "";
                Live = false;
                Array.Clear(Levels, 0, Levels.Length);
            }
        }

        private string _deviceId = "";

        private void CheckDevice()
        {
            if (!_wanted) return;
            try
            {
                var id = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
                if (id != _deviceId) Restart();
            }
            catch { }
        }

        private void Restart()
        {
            lock (_gate)
            {
                if (!_wanted) return;
                try
                {
                    _capture?.StopRecording();
                    _capture?.Dispose();
                }
                catch { }
                _capture = null;
                try
                {
                    var device = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                    _deviceId = device.ID;
                    var capture = new WasapiLoopbackCapture(device);
                    capture.DataAvailable += OnData;
                    capture.RecordingStopped += (_, _) => { Live = false; };
                    capture.StartRecording();
                    _capture = capture;
                    Live = true;
                    Array.Clear(_lowpass, 0, _lowpass.Length);
                    _coefficientRate = 0;
                }
                catch
                {
                    Live = false;
                }
            }
        }

        private void OnData(object? sender, WaveInEventArgs e)
        {
            var capture = _capture;
            if (capture == null || e.BytesRecorded <= 0) return;
            var format = capture.WaveFormat;
            int channels = Math.Max(1, format.Channels);
            bool isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat ||
                           (format.Encoding == WaveFormatEncoding.Extensible && format.BitsPerSample == 32);
            int bytesPerSample = format.BitsPerSample / 8;
            if (bytesPerSample <= 0) return;
            int frameCount = e.BytesRecorded / (bytesPerSample * channels);
            if (frameCount <= 8) return;

            double sampleRate = format.SampleRate;
            // At most 384 representative samples per buffer, as on the Mac.
            int stride = Math.Max(1, (frameCount + 383) / 384);
            double effectiveRate = sampleRate / stride;
            if (_coefficientRate != effectiveRate)
            {
                double[] cutoffs = { 75, 220, 620, 1600, 4600, 9500 };
                var c = new double[Bands];
                for (int i = 0; i < Bands; i++) c[i] = 1 - Math.Exp(-2 * Math.PI * cutoffs[i] / effectiveRate);
                _coefficients = c;
                _coefficientRate = effectiveRate;
            }
            double c0 = _coefficients[0], c1 = _coefficients[1], c2 = _coefficients[2],
                   c3 = _coefficients[3], c4 = _coefficients[4], c5 = _coefficients[5];
            double e0 = 0, e1 = 0, e2 = 0, e3 = 0, e4 = 0, e5 = 0;
            int frames = 0;
            int readChannels = Math.Min(channels, 2);
            var buffer = e.Buffer;
            var lp = _lowpass;
            for (int i = 0; i < frameCount; i += stride)
            {
                for (int ch = 0; ch < readChannels; ch++)
                {
                    int offset = (i * channels + ch) * bytesPerSample;
                    double x;
                    if (isFloat && bytesPerSample == 4) x = BitConverter.ToSingle(buffer, offset);
                    else if (bytesPerSample == 2) x = BitConverter.ToInt16(buffer, offset) / 32768.0;
                    else if (bytesPerSample == 4) x = BitConverter.ToInt32(buffer, offset) / 2147483648.0;
                    else continue;
                    if (double.IsNaN(x) || double.IsInfinity(x)) continue;
                    int o = ch * 6;
                    lp[o] += c0 * (x - lp[o]);
                    lp[o + 1] += c1 * (x - lp[o + 1]);
                    lp[o + 2] += c2 * (x - lp[o + 2]);
                    lp[o + 3] += c3 * (x - lp[o + 3]);
                    lp[o + 4] += c4 * (x - lp[o + 4]);
                    lp[o + 5] += c5 * (x - lp[o + 5]);
                    double b0 = lp[o], b1 = lp[o + 1] - lp[o], b2 = lp[o + 2] - lp[o + 1];
                    double b3 = lp[o + 3] - lp[o + 2], b4 = lp[o + 4] - lp[o + 3], b5 = x - lp[o + 4];
                    e0 += b0 * b0; e1 += b1 * b1; e2 += b2 * b2;
                    e3 += b3 * b3; e4 += b4 * b4; e5 += b5 * b5;
                    frames++;
                }
            }
            if (frames == 0) return;
            double[] energy = { e0, e1, e2, e3, e4, e5 };
            bool audible = false;
            for (int k = 0; k < Bands; k++)
            {
                double rms = Math.Sqrt(energy[k] / frames);
                if (rms > 0.00012) audible = true;
                _peaks[k] = Math.Max(0.003, Math.Max(rms, _peaks[k] * 0.988));
                _targets[k] = Amplitude(rms, _peaks[k], k);
            }
            if (audible) _lastSound = DateTime.Now;

            var now = DateTime.Now;
            if ((now - _lastPresentation).TotalSeconds >= 0.045)
            {
                _lastPresentation = now;
                for (int k = 0; k < Bands; k++)
                {
                    double target = _targets[k];
                    double response = Smoothing(target > _smooth[k]);
                    _smooth[k] += (target - _smooth[k]) * response;
                    if (target == 0 && _smooth[k] < 0.008) _smooth[k] = 0;
                    Levels[k] = _smooth[k];
                }
            }
        }

        // Silence lasts until Windows sends sound again; stop drawing old levels.
        public bool HearingSound => (DateTime.Now - _lastSound).TotalSeconds < 0.6;

        private double Amplitude(double rms, double peak, int band)
        {
            if (double.IsNaN(rms) || rms <= 0.00006 * NoiseGate) return 0;
            double bassWeight = band == 0 ? BassBoost : (band == 1 ? 1 + (BassBoost - 1) * 0.25 : 1);
            double normalized = Math.Max(0, rms) / (Math.Max(0.003, peak) * 1.15);
            return Math.Min(1, Math.Max(0, Math.Pow(normalized, 0.82) * Sensitivity * bassWeight));
        }

        private double Smoothing(bool rising) =>
            rising ? 1 - Math.Pow(1 - 0.78, Attack) : 1 - Math.Pow(1 - 0.17, 1 / Release);

        public void Dispose()
        {
            _watchdog?.Dispose();
            lock (_gate)
            {
                try { _capture?.StopRecording(); _capture?.Dispose(); } catch { }
                _capture = null;
            }
        }
    }

    // The bars' own motion, ported from IslandWaveformPhysics: exponential
    // followers, up in 35 ms, down in 110 ms, independent of the frame rate.
    public sealed class WaveformPhysics
    {
        public const int BarCount = 6;
        public readonly double[] Heights = new double[BarCount];
        private double? _last;

        public static double Noise(int i, int k)
        {
            unchecked
            {
                ulong x = (ulong)(k * 7919 + i * 104729 + 17);
                x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9UL;
                x = (x ^ (x >> 27)) * 0x94D049BB133111EBUL;
                x ^= x >> 31;
                return (x % 10000) / 10000.0;
            }
        }

        // Synthetic music when real sound is not available (same as the Mac).
        public static double Synthetic(int i, double t)
        {
            double beat = 60.0 / 126.0;
            double sinceKick = t % beat;
            double kick = Math.Exp(-sinceKick / 0.09);
            switch (i)
            {
                case 0: return Math.Min(1, 0.22 + 0.85 * kick);
                case 1:
                    double sinceOff = (t + beat / 2) % beat;
                    return Math.Min(1, 0.18 + 0.45 * Math.Exp(-sinceOff / 0.12) + 0.25 * Noise(i, (int)(t / 0.13)));
                default:
                    double slot = 0.11 + 0.02 * i;
                    int k = (int)Math.Floor(t / slot);
                    double accent = Noise(i, k);
                    double sinceSlot = t - k * slot;
                    return Math.Min(1, 0.2 + 0.7 * accent * Math.Exp(-sinceSlot / 0.16) + 0.15 * kick);
            }
        }

        // 0.4.19 — the iPhone's waveform: the bars breathe together with the
        // loudness, each with its own slow sway and a little of its own
        // frequency band; never drop below a third while music plays; rise
        // and fall at the same soft pace; settle to dots on pause. Measured
        // from a screen recording of the iPhone player.
        private static readonly double[] SwaySpeed = { 7.3, 9.1, 8.2, 10.4, 7.8, 9.7 };
        private static readonly double[] SwayPhase = { 0.0, 1.9, 4.1, 0.8, 2.9, 5.2 };
        private double _energy;

        private void StepIphone(double time, double dt, double[] levels, bool playing, bool live)
        {
            double loud = 0;
            if (playing)
            {
                if (live)
                {
                    double sum = 0;
                    for (int i = 0; i < BarCount && i < levels.Length; i++) sum += Math.Clamp(levels[i], 0, 1);
                    loud = Math.Clamp(Math.Pow(sum / BarCount, 0.7) * 1.35, 0, 1);
                }
                else loud = 0.55 + 0.25 * Synthetic(0, time);
            }
            // The overall loudness itself is smoothed, so the bars swell and ease.
            _energy += (loud - _energy) * (1 - Math.Exp(-dt / 0.12));
            for (int i = 0; i < BarCount; i++)
            {
                double target;
                if (!playing) target = 0;
                else
                {
                    double band = live && i < levels.Length ? Math.Clamp(Math.Pow(Math.Clamp(levels[i], 0, 1), 0.9) * 1.1, 0, 1) : Synthetic(i, time) * 0.7;
                    double sway = 0.5 + 0.5 * Math.Sin(time * SwaySpeed[i] + SwayPhase[i]) * Math.Sin(time * SwaySpeed[i] * 0.37 + SwayPhase[i] * 1.7);
                    double mix = 0.5 * _energy + 0.3 * band + 0.45 * _energy * (sway - 0.5) + 0.12 * sway;
                    target = 0.34 + 0.66 * Math.Clamp(mix, 0, 1);
                }
                double tau = !playing ? 0.18 : target > Heights[i] ? 0.06 : 0.085;
                Heights[i] += (target - Heights[i]) * (1 - Math.Exp(-dt / tau));
                if (!playing && Heights[i] < 0.003) Heights[i] = 0;
            }
        }

        public void Step(double time, double[] levels, bool playing, bool live)
        {
            double previous = _last ?? time;
            _last = time;
            double dt = Math.Min(0.1, Math.Max(0, time - previous));
            if (dt <= 0) return;
            if (Ovira.Core.Settings.Current.SpectrumMotion == "iphone") { StepIphone(time, dt, levels, playing, live); return; }
            for (int i = 0; i < BarCount; i++)
            {
                double target;
                if (!playing) target = 0;
                else if (live)
                {
                    double measured = i < levels.Length ? Math.Clamp(levels[i], 0, 1) : 0;
                    target = measured <= 0.015 ? 0 : Math.Min(1, Math.Pow(measured, 1.25) * 1.12);
                }
                else target = Synthetic(i, time);
                double tau = target > Heights[i] ? 0.035 : 0.11;
                Heights[i] += (target - Heights[i]) * (1 - Math.Exp(-dt / tau));
                if (target == 0 && Heights[i] < 0.003) Heights[i] = 0;
            }
        }

        public bool Settled
        {
            get { foreach (var h in Heights) if (h >= 0.004) return false; return true; }
        }
    }
}
