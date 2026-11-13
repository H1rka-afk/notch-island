using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Ovira.Widgets
{
    // 0.7.3 — the graphics card for the «Нагрузка» widget, read the way
    // Task Manager reads it: the load from the «GPU Engine» counters (the 3D
    // engines of every app added up), the temperature from the display
    // driver (dedicated cards on Windows 10 2004 and newer; integrated
    // graphics usually report none). Read only while the widget is on the
    // desktop, at most once a second.
    public static class GpuMeter
    {
        public static readonly List<double> History = new();
        private static DateTime _at;
        private static double _load;
        private static double _temp = double.NaN;
        private static IntPtr _query, _counter;
        private static bool _pdhFailed, _tempFailed;

        public static (double Load, double Temperature) Read()
        {
            if ((DateTime.Now - _at).TotalSeconds < 0.9) return (_load, _temp);
            _at = DateTime.Now;
            try { _load = Load(); } catch { _load = 0; }
            try { _temp = Temperature(); } catch { _temp = double.NaN; }
            History.Add(_load);
            if (History.Count > 40) History.RemoveAt(0);
            return (_load, _temp);
        }

        // ---- load: PDH «\GPU Engine(*engtype_3D)\Utilization Percentage» ----

        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhOpenQuery(string? source, IntPtr user, out IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr user, out IntPtr counter);
        [DllImport("pdh.dll")] private static extern uint PdhCollectQueryData(IntPtr query);
        [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bufferSize, out uint count, IntPtr buffer);

        private const uint PDH_FMT_DOUBLE = 0x200, PDH_FMT_NOCAP100 = 0x8000, PDH_MORE_DATA = 0x800007D2;

        private static double Load()
        {
            if (_pdhFailed) return 0;
            if (_query == IntPtr.Zero)
            {
                if (PdhOpenQuery(null, IntPtr.Zero, out _query) != 0 ||
                    PdhAddEnglishCounter(_query, @"\GPU Engine(*engtype_3D)\Utilization Percentage", IntPtr.Zero, out _counter) != 0)
                {
                    _pdhFailed = true;
                    return 0;
                }
                PdhCollectQueryData(_query);       // the first sample only sets the start
                return 0;
            }
            if (PdhCollectQueryData(_query) != 0) return _load;
            uint size = 0;
            uint status = PdhGetFormattedCounterArray(_counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out var count, IntPtr.Zero);
            if (status != PDH_MORE_DATA || size == 0) return 0;
            var buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                if (PdhGetFormattedCounterArray(_counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out count, buffer) != 0) return _load;
                // PDH_FMT_COUNTERVALUE_ITEM_W: name pointer, then { status, (pad), double }
                int item = IntPtr.Size + 16;
                double sum = 0;
                for (int i = 0; i < count; i++)
                {
                    var at = buffer + i * item;
                    uint cstatus = (uint)Marshal.ReadInt32(at + IntPtr.Size);
                    if (cstatus != 0 && cstatus != 1) continue;          // PDH_CSTATUS_VALID_DATA / NEW_DATA
                    double v = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(at + IntPtr.Size + 8));
                    if (v > 0 && !double.IsNaN(v)) sum += v;
                }
                return Math.Clamp(sum / 100.0, 0, 1);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        // ---- temperature: D3DKMT adapter performance data ----

        [StructLayout(LayoutKind.Sequential)]
        private struct AdapterInfo { public uint Handle; public uint LuidLow; public int LuidHigh; public uint Sources; public int Precise; }

        [StructLayout(LayoutKind.Sequential)]
        private struct EnumAdapters2 { public uint Count; public IntPtr Adapters; }

        [StructLayout(LayoutKind.Sequential)]
        private struct QueryAdapterInfo { public uint Adapter; public int Type; public IntPtr Data; public uint Size; }

        [StructLayout(LayoutKind.Sequential)]
        private struct PerfData
        {
            public uint PhysicalAdapterIndex;
            public ulong MemoryFrequency, MaxMemoryFrequency, MaxMemoryFrequencyOC, MemoryBandwidth, PCIEBandwidth;
            public uint FanRPM, Power, Temperature;      // temperature in tenths of a degree
            public byte PowerStateOverride;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CloseAdapter { public uint Adapter; }

        [DllImport("gdi32.dll")] private static extern int D3DKMTEnumAdapters2(ref EnumAdapters2 data);
        [DllImport("gdi32.dll")] private static extern int D3DKMTQueryAdapterInfo(ref QueryAdapterInfo data);
        [DllImport("gdi32.dll")] private static extern int D3DKMTCloseAdapter(ref CloseAdapter data);

        private static double Temperature()
        {
            if (_tempFailed) return double.NaN;
            var e = new EnumAdapters2();
            if (D3DKMTEnumAdapters2(ref e) != 0 || e.Count == 0) { _tempFailed = true; return double.NaN; }
            int infoSize = Marshal.SizeOf<AdapterInfo>();
            e.Adapters = Marshal.AllocHGlobal(infoSize * (int)e.Count);
            var perf = Marshal.AllocHGlobal(Marshal.SizeOf<PerfData>());
            double best = double.NaN;
            try
            {
                if (D3DKMTEnumAdapters2(ref e) != 0) return double.NaN;
                for (int i = 0; i < e.Count; i++)
                {
                    var a = Marshal.PtrToStructure<AdapterInfo>(e.Adapters + i * infoSize);
                    var pd = new PerfData();
                    Marshal.StructureToPtr(pd, perf, false);
                    var q = new QueryAdapterInfo { Adapter = a.Handle, Type = 62 /* KMTQAITYPE_ADAPTERPERFDATA */, Data = perf, Size = (uint)Marshal.SizeOf<PerfData>() };
                    if (D3DKMTQueryAdapterInfo(ref q) == 0)
                    {
                        pd = Marshal.PtrToStructure<PerfData>(perf);
                        double t = pd.Temperature / 10.0;
                        if (t > 1 && t < 130 && (double.IsNaN(best) || t > best)) best = t;
                    }
                    var c = new CloseAdapter { Adapter = a.Handle };
                    D3DKMTCloseAdapter(ref c);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(e.Adapters);
                Marshal.FreeHGlobal(perf);
            }
            return best;
        }
    }
}
