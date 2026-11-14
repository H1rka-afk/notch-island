using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Ovira.Widgets
{
    // 0.8.0 — «Стекло» as the iPhone's Liquid Glass. A widget sits on the
    // wallpaper, and the wallpaper is a known picture — so Ovira draws the
    // glass itself: the piece of wallpaper under the card, lightly frosted,
    // bent like a thick lens towards the rounded edges (with a hint of colour
    // splitting there), a little more saturated, and lit by a bright rim on
    // the side facing the light. Recomputed when the card moves or the
    // wallpaper changes; nothing is read from the screen.
    public static class LiquidGlass
    {
        private static byte[]? _pixels;            // the frosted desktop picture, BGRA
        private static int _w, _h;
        private static Int32Rect _screen;           // where it lies, in device pixels
        private static string _signature = "";
        private static bool _loading;
        public static event Action? Ready;
        public static bool Available => _pixels != null;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool SystemParametersInfo(uint action, uint param, StringBuilder value, uint winIni);

        // Load (again) if the wallpaper or the screen changed.
        public static void Ensure()
        {
            if (_loading) return;
            string sig;
            string? file;
            try
            {
                file = WallpaperFile();
                var s = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
                sig = (file ?? "-") + "|" + (file != null ? File.GetLastWriteTimeUtc(file).Ticks : 0) + "|" + Style() + "|" + s + "|" + SolidColour();
            }
            catch { return; }
            if (sig == _signature) return;
            _signature = sig;
            _loading = true;
            try { Load(file); }
            catch { _loading = false; }
        }

        private static string? WallpaperFile()
        {
            var path = new StringBuilder(520);
            if (SystemParametersInfo(0x0073 /* SPI_GETDESKWALLPAPER */, 520, path, 0) && path.Length > 0 && File.Exists(path.ToString())) return path.ToString();
            var transcoded = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Microsoft\Windows\Themes\TranscodedWallpaper");
            return File.Exists(transcoded) ? transcoded : null;
        }

        private static (string Style, bool Tile) Style()
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop");
            return (key?.GetValue("WallpaperStyle") as string ?? "10", (key?.GetValue("TileWallpaper") as string) == "1");
        }

        private static Color SolidColour()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Control Panel\Colors");
                var parts = (key?.GetValue("Background") as string ?? "0 0 0").Split(' ');
                return Color.FromRgb(byte.Parse(parts[0]), byte.Parse(parts[1]), byte.Parse(parts[2]));
            }
            catch { return Colors.Black; }
        }

        // The desktop as Windows draws it (fill, fit, stretch, centre, tile),
        // at the screen's own resolution, then frosted off the UI thread.
        private static void Load(string? file)
        {
            var screen = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
            int w = screen.Width, h = screen.Height;
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(new SolidColorBrush(SolidColour()), null, new Rect(0, 0, w, h));
                if (file != null)
                {
                    BitmapSource? image = null;
                    try
                    {
                        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                        var bmp = new BitmapImage();
                        bmp.BeginInit();
                        bmp.CacheOption = BitmapCacheOption.OnLoad;
                        bmp.StreamSource = stream;
                        bmp.EndInit();
                        bmp.Freeze();
                        image = bmp;
                    }
                    catch { }
                    if (image != null)
                    {
                        double iw = image.PixelWidth, ih = image.PixelHeight;
                        var (style, tile) = Style();
                        Rect r;
                        switch (style)
                        {
                            case "2": r = new Rect(0, 0, w, h); break;                                   // stretch
                            case "6": { double k = Math.Min(w / iw, h / ih); r = new Rect((w - iw * k) / 2, (h - ih * k) / 2, iw * k, ih * k); break; }   // fit
                            case "0" when tile:
                                for (double y = 0; y < h; y += ih) for (double x = 0; x < w; x += iw) dc.DrawImage(image, new Rect(x, y, iw, ih));
                                r = Rect.Empty; break;
                            case "0": r = new Rect((w - iw) / 2, (h - ih) / 2, iw, ih); break;             // centre
                            default: { double k = Math.Max(w / iw, h / ih); r = new Rect((w - iw * k) / 2, (h - ih * k) / 2, iw * k, ih * k); break; }    // fill / span
                        }
                        if (!r.IsEmpty) dc.DrawImage(image, r);
                    }
                }
            }
            var target = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
            target.Render(visual);
            var raw = new byte[w * h * 4];
            target.CopyPixels(raw, w * 4, 0);
            var dispatcher = Application.Current.Dispatcher;
            Task.Run(() =>
            {
                int radius = Math.Max(2, (int)Math.Round(w / 640.0 * 1.3));      // a light frost, not a fog
                for (int pass = 0; pass < 3; pass++) { BoxH(raw, w, h, radius); BoxV(raw, w, h, radius); }
                dispatcher.BeginInvoke(new Action(() =>
                {
                    _pixels = raw; _w = w; _h = h;
                    _screen = new Int32Rect(screen.Left, screen.Top, w, h);
                    _loading = false;
                    Ready?.Invoke();
                }));
            });
        }

        private static void BoxH(byte[] p, int w, int h, int r)
        {
            var line = new int[w * 4];
            int span = 2 * r + 1;
            for (int y = 0; y < h; y++)
            {
                int row = y * w * 4;
                for (int c = 0; c < 4; c++)
                {
                    int sum = 0;
                    for (int i = -r; i <= r; i++) sum += p[row + Math.Clamp(i, 0, w - 1) * 4 + c];
                    for (int x = 0; x < w; x++)
                    {
                        line[x * 4 + c] = sum / span;
                        int add = Math.Min(w - 1, x + r + 1), sub = Math.Max(0, x - r);
                        sum += p[row + add * 4 + c] - p[row + sub * 4 + c];
                    }
                }
                for (int i = 0; i < w * 4; i++) p[row + i] = (byte)line[i];
            }
        }

        private static void BoxV(byte[] p, int w, int h, int r)
        {
            var col = new int[h];
            int span = 2 * r + 1;
            for (int x = 0; x < w; x++)
                for (int c = 0; c < 4; c++)
                {
                    int sum = 0;
                    for (int i = -r; i <= r; i++) sum += p[Math.Clamp(i, 0, h - 1) * w * 4 + x * 4 + c];
                    for (int y = 0; y < h; y++)
                    {
                        col[y] = sum / span;
                        int add = Math.Min(h - 1, y + r + 1), sub = Math.Max(0, y - r);
                        sum += p[add * w * 4 + x * 4 + c] - p[sub * w * 4 + x * 4 + c];
                    }
                    for (int y = 0; y < h; y++) p[y * w * 4 + x * 4 + c] = (byte)col[y];
                }
        }

        // ---- one card ----

        // card: the card's rectangle on the screen, in device pixels.
        public static BitmapSource? Render(Rect card, double radius, double scale)
        {
            var src = _pixels;
            if (src == null) return null;
            int W = (int)Math.Round(card.Width), H = (int)Math.Round(card.Height);
            if (W < 8 || H < 8 || W > 4000 || H > 4000) return null;
            // only on the main screen, where the wallpaper is known
            if (card.Right < _screen.X || card.Bottom < _screen.Y || card.Left > _screen.X + _screen.Width || card.Top > _screen.Y + _screen.Height) return null;
            double ox = card.X - _screen.X, oy = card.Y - _screen.Y;
            double R = Math.Min(radius, Math.Min(W, H) / 2.0);
            double bezel = 22 * scale;                   // how far in from the edge the glass bends
            double cx = W / 2.0, cy = H / 2.0, hx = cx - R, hy = cy - R;
            const double lx = -0.55, ly = -0.83;         // light from the top left
            var outp = new byte[W * H * 4];
            for (int y = 0; y < H; y++)
            {
                double py = y + 0.5 - cy;
                double qy = Math.Abs(py) - hy;
                for (int x = 0; x < W; x++)
                {
                    double px = x + 0.5 - cx;
                    double qx = Math.Abs(px) - hx;
                    double ax = Math.Max(qx, 0), ay = Math.Max(qy, 0);
                    double outside = Math.Sqrt(ax * ax + ay * ay) + Math.Min(Math.Max(qx, qy), 0) - R;
                    if (outside >= 1) continue;
                    double alpha = Math.Clamp(0.5 - outside, 0, 1);
                    double d = -outside;                 // depth inside the card
                    // the edge's outward direction
                    double nx, ny;
                    if (qx > 0 && qy > 0) { double l = Math.Sqrt(ax * ax + ay * ay); nx = ax / l * Math.Sign(px); ny = ay / l * Math.Sign(py); }
                    else if (qx > qy) { nx = Math.Sign(px); ny = 0; }
                    else { nx = 0; ny = Math.Sign(py); }
                    double t = d < bezel ? 1 - Math.Max(0, d) / bezel : 0;
                    double bend = bezel * 0.75 * t * t * t;          // a lens: the rim pulls the picture inwards
                    double sx = ox + x + 0.5, sy = oy + y + 0.5;
                    double b, g, r;
                    if (bend > 0.05)
                    {
                        // a whisper of colour splitting where the glass bends most
                        r = Sample(src, sx - nx * bend * 1.12, sy - ny * bend * 1.12, 2);
                        g = Sample(src, sx - nx * bend, sy - ny * bend, 1);
                        b = Sample(src, sx - nx * bend * 0.88, sy - ny * bend * 0.88, 0);
                    }
                    else
                    {
                        b = Sample(src, sx, sy, 0); g = Sample(src, sx, sy, 1); r = Sample(src, sx, sy, 2);
                    }
                    // a little more colour, a little less light (white text on top)
                    double lum = 0.299 * r + 0.587 * g + 0.114 * b;
                    r = lum + (r - lum) * 1.28; g = lum + (g - lum) * 1.28; b = lum + (b - lum) * 1.28;
                    r = r * 0.86 + 6; g = g * 0.86 + 6; b = b * 0.86 + 8;
                    // the bevel catches the light on the lit side, softly on the other
                    double facing = nx * lx + ny * ly;
                    double rim = Math.Pow(t, 5) * (facing > 0 ? facing * 150 : -facing * 55);
                    // and a faint inner glow all round
                    rim += Math.Pow(t, 2.2) * 16;
                    r += rim; g += rim; b += rim;
                    int i = (y * W + x) * 4;
                    outp[i] = (byte)(Math.Clamp(b, 0, 255) * alpha);
                    outp[i + 1] = (byte)(Math.Clamp(g, 0, 255) * alpha);
                    outp[i + 2] = (byte)(Math.Clamp(r, 0, 255) * alpha);
                    outp[i + 3] = (byte)(255 * alpha);
                }
            }
            var bmp = BitmapSource.Create(W, H, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, outp, W * 4);
            bmp.Freeze();
            return bmp;
        }

        private static double Sample(byte[] p, double x, double y, int c)
        {
            x = Math.Clamp(x - 0.5, 0, _w - 1.001);
            y = Math.Clamp(y - 0.5, 0, _h - 1.001);
            int x0 = (int)x, y0 = (int)y;
            double fx = x - x0, fy = y - y0;
            int i00 = (y0 * _w + x0) * 4 + c, i10 = i00 + 4, i01 = i00 + _w * 4, i11 = i01 + 4;
            double top = p[i00] + (p[i10] - p[i00]) * fx;
            double bottom = p[i01] + (p[i11] - p[i01]) * fx;
            return top + (bottom - top) * fy;
        }
    }
}
