using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Ovira.Services
{
    public sealed class OutputDevice
    {
        public string Id = "";
        public string Name = "";
        public bool IsDefault;
        public string Glyph = "";        // speaker
    }

    // Volume, mute, the default output device and its live level (for the
    // bars in the island). Core Audio through NAudio; switching the default
    // device uses the same COM interface as the Windows sound flyout.
    public sealed class AudioService : IMMNotificationClient, IDisposable
    {
        public event Action<float, bool>? VolumeChanged;       // 0…1, muted
        public event Action<OutputDevice>? DefaultDeviceChanged;

        private readonly MMDeviceEnumerator _enumerator = new MMDeviceEnumerator();
        private MMDevice? _device;
        private string _defaultId = "";
        private DateTime _ownChange = DateTime.MinValue;

        public void Start()
        {
            try { _enumerator.RegisterEndpointNotificationCallback(this); } catch { }
            AttachDefault(announce: false);
        }

        private void AttachDefault(bool announce)
        {
            try
            {
                if (_device != null)
                {
                    try { _device.AudioEndpointVolume.OnVolumeNotification -= OnVolume; } catch { }
                }
                _device = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                _device.AudioEndpointVolume.OnVolumeNotification += OnVolume;
                var changed = _device.ID != _defaultId;
                _defaultId = _device.ID;
                if (announce && changed) DefaultDeviceChanged?.Invoke(Describe(_device, true));
            }
            catch { _device = null; }
        }

        private void OnVolume(AudioVolumeNotificationData data)
        {
            var level = data.MasterVolume;
            var muted = data.Muted;
            Application.Current?.Dispatcher.BeginInvoke(() => VolumeChanged?.Invoke(level, muted));
        }

        public float Volume
        {
            get { try { return _device?.AudioEndpointVolume.MasterVolumeLevelScalar ?? 0; } catch { return 0; } }
            set { try { if (_device != null) _device.AudioEndpointVolume.MasterVolumeLevelScalar = Math.Clamp(value, 0f, 1f); } catch { } }
        }

        public bool Muted
        {
            get { try { return _device?.AudioEndpointVolume.Mute ?? false; } catch { return false; } }
        }

        // What is playing right now, 0…1 — for the live bars.
        public float Peak
        {
            get { try { return _device?.AudioMeterInformation.MasterPeakValue ?? 0; } catch { return 0; } }
        }

        public OutputDevice? Current => _device == null ? null : Describe(_device, true);

        public List<OutputDevice> Outputs()
        {
            try
            {
                return _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
                    .Select(d => Describe(d, d.ID == _defaultId))
                    .OrderByDescending(d => d.IsDefault)
                    .ToList();
            }
            catch { return new List<OutputDevice>(); }
        }

        public void SetDefault(string id)
        {
            try
            {
                var policy = (IPolicyConfig)new CPolicyConfigClient();
                policy.SetDefaultEndpoint(id, ERole.eConsole);
                policy.SetDefaultEndpoint(id, ERole.eMultimedia);
                policy.SetDefaultEndpoint(id, ERole.eCommunications);
                _ownChange = DateTime.Now;
            }
            catch { }
        }

        public bool ChangedByOvira => (DateTime.Now - _ownChange).TotalSeconds < 2;

        private static OutputDevice Describe(MMDevice d, bool isDefault)
        {
            string name;
            try { name = d.FriendlyName; } catch { name = "Устройство"; }
            var lower = name.ToLowerInvariant();
            string glyph = "";                                            // speaker
            if (lower.Contains("airpods") || lower.Contains("buds") || lower.Contains("наушник") ||
                lower.Contains("headphone") || lower.Contains("headset") || lower.Contains("гарнитур") ||
                lower.Contains("wh-") || lower.Contains("wf-"))
                glyph = "";                                               // headphones
            else if (lower.Contains("hdmi") || lower.Contains("display") || lower.Contains("монитор") || lower.Contains("tv"))
                glyph = "";                                               // TV / monitor
            return new OutputDevice { Id = d.ID, Name = ShortName(name), IsDefault = isDefault, Glyph = glyph };
        }

        // «Динамики (Realtek(R) Audio)» → «Динамики»; «Наушники (WH-1000XM4)» → «WH-1000XM4».
        private static string ShortName(string name)
        {
            var open = name.IndexOf(" (", StringComparison.Ordinal);
            if (open <= 0 || !name.EndsWith(")")) return name;
            var head = name.Substring(0, open);
            var inner = name.Substring(open + 2, name.Length - open - 3);
            var generic = new[] { "динамики", "speakers", "наушники", "headphones", "headset", "гарнитура" };
            if (generic.Contains(head.ToLowerInvariant()) && !inner.ToLowerInvariant().Contains("audio") &&
                !inner.ToLowerInvariant().Contains("realtek"))
                return inner;
            return head;
        }

        // IMMNotificationClient
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            if (flow != DataFlow.Render || role != Role.Multimedia) return;
            Application.Current?.Dispatcher.BeginInvoke(() => AttachDefault(announce: true));
        }
        public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }

        public void Dispose()
        {
            try { _enumerator.UnregisterEndpointNotificationCallback(this); } catch { }
            _enumerator.Dispose();
        }

        // ---- default device switching (undocumented, used by every sound switcher) ----
        private enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

        [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPolicyConfig
        {
            [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr format);
            [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, bool def, IntPtr format);
            [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
            [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, bool def, IntPtr defaultPeriod, IntPtr minPeriod);
            [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
            [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
            [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
            [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, bool fxStore, IntPtr key, IntPtr value);
            [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, bool fxStore, IntPtr key, IntPtr value);
            [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, ERole role);
            [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, bool visible);
        }

        [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
        private class CPolicyConfigClient { }
    }
}
