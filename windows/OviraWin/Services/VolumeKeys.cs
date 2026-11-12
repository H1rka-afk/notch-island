using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using Ovira.Core;

namespace Ovira.Services
{
    // 0.4.21 — the island instead of Windows' own volume indicator. Ovira
    // takes over just the three volume keys (louder, quieter, mute) as
    // system hot keys; Windows then gets no key press and shows no
    // indicator, and Ovira changes the volume itself in the same 2 % steps —
    // the island shows it. Only these three keys are seen; nothing else
    // typed reaches Ovira. Switched off → the keys are given back at once.
    public sealed class VolumeKeys
    {
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        private const int WM_HOTKEY = 0x0312;
        private const uint VK_VOLUME_MUTE = 0xAD, VK_VOLUME_DOWN = 0xAE, VK_VOLUME_UP = 0xAF;
        private const int IdMute = 0xB101, IdDown = 0xB102, IdUp = 0xB103;

        private readonly AudioService _audio;
        private IntPtr _hwnd;
        private bool _registered;

        // How it went — for Settings.
        public bool Working { get; private set; }
        public event Action? Changed;

        public VolumeKeys(AudioService audio) { _audio = audio; }

        public void Attach(IntPtr hwnd)
        {
            _hwnd = hwnd;
            HwndSource.FromHwnd(hwnd)?.AddHook(Hook);
            Settings.Current.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Settings.ReplaceVolumeOsd)) Apply(); };
            Apply();
        }

        public void Apply()
        {
            if (_hwnd == IntPtr.Zero) return;
            Release();
            if (Settings.Current.ReplaceVolumeOsd)
            {
                bool up = RegisterHotKey(_hwnd, IdUp, 0, VK_VOLUME_UP);
                bool down = RegisterHotKey(_hwnd, IdDown, 0, VK_VOLUME_DOWN);
                bool mute = RegisterHotKey(_hwnd, IdMute, 0, VK_VOLUME_MUTE);
                _registered = up || down || mute;
                Working = up && down;
                // Half a takeover would be confusing: all or nothing.
                if (!Working) Release();
            }
            Changed?.Invoke();
        }

        public void Release()
        {
            if (_hwnd == IntPtr.Zero) return;
            UnregisterHotKey(_hwnd, IdUp);
            UnregisterHotKey(_hwnd, IdDown);
            UnregisterHotKey(_hwnd, IdMute);
            _registered = false;
            Working = false;
        }

        private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg != WM_HOTKEY || !_registered) return IntPtr.Zero;
            switch (wParam.ToInt32())
            {
                case IdUp: Step(+1); handled = true; break;
                case IdDown: Step(-1); handled = true; break;
                case IdMute: _audio.ToggleMute(); handled = true; break;
            }
            return IntPtr.Zero;
        }

        // The same 2 % steps as Windows; louder also unmutes.
        private void Step(int direction)
        {
            var level = Math.Round(_audio.Volume * 50) + direction;
            if (direction > 0 && _audio.Muted) _audio.ToggleMute();
            _audio.Volume = (float)(Math.Clamp(level, 0, 50) / 50.0);
        }
    }
}
