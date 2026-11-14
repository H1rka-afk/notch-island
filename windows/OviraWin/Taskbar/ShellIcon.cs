using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Ovira.Taskbar
{
    // 0.7.6 — an icon exactly as the shell draws it (Start, Explorer, the
    // taskbar): IShellItemImageFactory, which picks the biggest image the app
    // has and keeps its transparency.
    internal static class ShellIcon
    {
        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItemImageFactory
        {
            [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr bitmap);
        }

        [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx, cy; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

        [StructLayout(LayoutKind.Sequential)]
        private struct BITMAPINFOHEADER
        {
            public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount;
            public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }

        [DllImport("gdi32.dll")] private static extern int GetObject(IntPtr h, int size, out BITMAP bmp);
        [DllImport("gdi32.dll")] private static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, [Out] byte[] bits, ref BITMAPINFOHEADER info, uint usage);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr h);
        [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

        public static ImageSource? Get(string path, int size)
        {
            IShellItemImageFactory? factory = null;
            var hbm = IntPtr.Zero;
            try
            {
                var iid = typeof(IShellItemImageFactory).GUID;
                if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out factory) != 0 || factory == null) return null;
                // SIIGBF_BIGGERSIZEOK | SIIGBF_ICONONLY
                if (factory.GetImage(new SIZE { cx = size, cy = size }, 0x1 | 0x4, out hbm) != 0 || hbm == IntPtr.Zero) return null;
                if (GetObject(hbm, Marshal.SizeOf<BITMAP>(), out var bmp) == 0) return null;
                int w = bmp.bmWidth, h = Math.Abs(bmp.bmHeight);
                if (w <= 0 || h <= 0) return null;
                var info = new BITMAPINFOHEADER { biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
                var pixels = new byte[w * h * 4];
                var dc = GetDC(IntPtr.Zero);
                try { if (GetDIBits(dc, hbm, 0, (uint)h, pixels, ref info, 0) == 0) return null; }
                finally { ReleaseDC(IntPtr.Zero, dc); }
                // icons without any transparency information come back fully clear
                bool anyAlpha = false;
                for (int i = 3; i < pixels.Length; i += 4) if (pixels[i] != 0) { anyAlpha = true; break; }
                if (!anyAlpha) for (int i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
                var source = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, pixels, w * 4);
                source.Freeze();
                return source;
            }
            catch { return null; }
            finally
            {
                if (hbm != IntPtr.Zero) DeleteObject(hbm);
                if (factory != null) Marshal.ReleaseComObject(factory);
            }
        }
    }
}
