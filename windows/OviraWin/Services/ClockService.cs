using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Threading;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.5.0 — timer, stopwatch and alarms. Shown in the island like the
    // iPhone's live activities: an icon on the left and the time on the right;
    // open the island for the buttons. A finished timer or an alarm rings
    // (a soft chime every 2 s, at most a minute) until you stop it.
    public sealed class ClockService
    {
        private readonly DispatcherTimer _tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };

        // Timer
        public TimeSpan TimerTotal { get; private set; }
        private DateTime? _timerEnd;
        private TimeSpan? _timerPausedLeft;
        public bool TimerRunning => _timerEnd != null;
        public bool TimerPaused => _timerPausedLeft != null;
        public bool TimerActive => TimerRunning || TimerPaused;
        public TimeSpan TimerLeft => _timerEnd is DateTime end ? Max0(end - DateTime.Now) : _timerPausedLeft ?? TimeSpan.Zero;

        // Stopwatch
        private DateTime? _swStart;
        private TimeSpan _swBefore;
        public bool StopwatchRunning => _swStart != null;
        public bool StopwatchActive => StopwatchRunning || _swBefore > TimeSpan.Zero;
        public TimeSpan StopwatchTime => _swBefore + (_swStart is DateTime s ? DateTime.Now - s : TimeSpan.Zero);

        // Ringing: a finished timer or an alarm.
        public string? Ringing { get; private set; }          // what rings: «Таймер» or the alarm's label
        public string RingingTime { get; private set; } = "";
        private DateTime _ringSince, _lastChime;
        private readonly HashSet<string> _firedToday = new();
        private DateTime _today = DateTime.Today;
        private DateTime? _snoozeUntil;
        private string _snoozeLabel = "";

        public event Action? Changed;

        private static TimeSpan Max0(TimeSpan t) => t < TimeSpan.Zero ? TimeSpan.Zero : t;

        public void Start()
        {
            _tick.Tick += (_, _) => Tick();
            _tick.Start();
        }

        public void StartTimer(TimeSpan length)
        {
            if (length <= TimeSpan.Zero) return;
            TimerTotal = length;
            _timerEnd = DateTime.Now + length;
            _timerPausedLeft = null;
            Changed?.Invoke();
        }

        public void PauseTimer()
        {
            if (_timerEnd is not DateTime end) return;
            _timerPausedLeft = Max0(end - DateTime.Now);
            _timerEnd = null;
            Changed?.Invoke();
        }

        public void ResumeTimer()
        {
            if (_timerPausedLeft is not TimeSpan left) return;
            _timerEnd = DateTime.Now + left;
            _timerPausedLeft = null;
            Changed?.Invoke();
        }

        public void CancelTimer()
        {
            _timerEnd = null;
            _timerPausedLeft = null;
            Changed?.Invoke();
        }

        public void StartStopwatch()
        {
            if (_swStart != null) return;
            _swStart = DateTime.Now;
            Changed?.Invoke();
        }

        public void PauseStopwatch()
        {
            if (_swStart is not DateTime s) return;
            _swBefore += DateTime.Now - s;
            _swStart = null;
            Changed?.Invoke();
        }

        public void ResetStopwatch()
        {
            _swStart = null;
            _swBefore = TimeSpan.Zero;
            Changed?.Invoke();
        }

        public void StopRinging()
        {
            if (Ringing == null) return;
            Ringing = null;
            Changed?.Invoke();
        }

        public void Snooze(int minutes = 5)
        {
            if (Ringing == null) return;
            _snoozeLabel = Ringing;
            _snoozeUntil = DateTime.Now.AddMinutes(minutes);
            Ringing = null;
            Changed?.Invoke();
        }

        private void Ring(string what, string time)
        {
            Ringing = what;
            RingingTime = time;
            _ringSince = DateTime.Now;
            _lastChime = DateTime.MinValue;
            Changed?.Invoke();
        }

        private void Tick()
        {
            var now = DateTime.Now;
            if (_timerEnd is DateTime end && now >= end)
            {
                _timerEnd = null;
                Ring("Таймер", Format(TimerTotal));
            }
            if (_snoozeUntil is DateTime snooze && now >= snooze)
            {
                _snoozeUntil = null;
                Ring(_snoozeLabel, now.ToString("HH:mm"));
            }
            if (now.Date != _today) { _today = now.Date; _firedToday.Clear(); }
            var hm = now.ToString("HH:mm");
            foreach (var alarm in Settings.Current.Alarms.Where(a => a.On && a.Time == hm))
            {
                var key = alarm.Id + hm;
                if (_firedToday.Contains(key)) continue;
                _firedToday.Add(key);
                Ring(string.IsNullOrWhiteSpace(alarm.Label) ? "Будильник" : alarm.Label, hm);
                if (!alarm.Daily) Settings.Current.Alarms = Settings.Current.Alarms.Select(a => a.Id == alarm.Id ? a.With(on: false) : a).ToList();
            }
            if (Ringing != null)
            {
                if ((now - _ringSince).TotalSeconds > 60) StopRinging();
                else if ((now - _lastChime).TotalSeconds >= 2)
                {
                    _lastChime = now;
                    Chime.Play(start: false, force: true);
                }
            }
        }

        public static string Format(TimeSpan t)
        {
            if (t < TimeSpan.Zero) t = TimeSpan.Zero;
            return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
        }

        public static string FormatPrecise(TimeSpan t) =>
            t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes:00}:{t.Seconds:00},{t.Milliseconds / 100}";
    }

    public sealed class Alarm
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        public string Time { get; set; } = "07:30";
        public string Label { get; set; } = "";
        public bool On { get; set; } = true;
        public bool Daily { get; set; } = true;
        public Alarm With(bool on) => new Alarm { Id = Id, Time = Time, Label = Label, On = on, Daily = Daily };
    }
}
