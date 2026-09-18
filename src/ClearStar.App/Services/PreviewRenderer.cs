using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClearStar.Core.Imaging;

namespace ClearStar.App.Services;

/// <summary>Előnézet (BGRA32) a képből, opcionális automatikus nyújtással. A nagy képet lekicsinyíti a gyors rajzoláshoz.</summary>
public static class PreviewRenderer
{
    public const int MaxPreviewWidth = 2400;

    public sealed record Frame(byte[] Pixels, int Width, int Height, int SourceWidth, int SourceHeight)
    {
        public BitmapSource ToBitmap()
        {
            var bmp = BitmapSource.Create(Width, Height, 96, 96, PixelFormats.Bgra32, null, Pixels, Width * 4);
            bmp.Freeze();
            return bmp;
        }
    }

    /// <summary>The screen-stretch preset used whenever <c>autoStretch</c> is requested (set from the toolbar).</summary>
    public static DisplayStretch.Preset Preset { get; set; } = DisplayStretch.PresetByKey(DisplayStretch.DefaultPresetKey);

    /// <summary>Háttérszálon futtatható: csak byte-tömböt állít elő.</summary>
    /// <param name="transform">Optional live transform (e.g. the stretch being adjusted) applied to the downsampled image.</param>
    /// <param name="smallOut">Receives the (transformed) downsampled image, e.g. for a histogram.</param>
    public static Frame Render(AstroImage image, bool autoStretch, CancellationToken ct = default, int maxWidth = MaxPreviewWidth,
        Func<AstroImage, AstroImage>? transform = null, Action<AstroImage, AstroImage>? smallOut = null)
    {
        var preset = Preset;
        autoStretch &= !preset.IsOff;
        int factor = Math.Max(1, (int)Math.Ceiling(Math.Max(image.Width, image.Height) / (double)maxWidth));
        var small = factor > 1 ? Downsample(image, factor) : image;
        ct.ThrowIfCancellationRequested();
        var before = small;
        if (transform is not null) { small = transform(small); ct.ThrowIfCancellationRequested(); }
        smallOut?.Invoke(before, small);

        // The stretch is evaluated per pixel in float: a linear image's background occupies only a few
        // thousandths of the range, so any lookup table would posterise it into colour blotches.
        var prms = autoStretch ? DisplayStretch.ComputeAll(small, preset, linked: false) : null;
        ct.ThrowIfCancellationRequested();

        int w = small.Width, h = small.Height, n = w * h;
        var pixels = new byte[n * 4];
        var d = small.Data;
        Parallel.For(0, h, y =>
        {
            for (int i = y * w; i < (y + 1) * w; i++)
            {
                byte r, g, b;
                if (small.Channels == 3)
                {
                    r = ToByte(prms is null ? d[i] : prms[0].Apply(d[i]));
                    g = ToByte(prms is null ? d[n + i] : prms[1].Apply(d[n + i]));
                    b = ToByte(prms is null ? d[2 * n + i] : prms[2].Apply(d[2 * n + i]));
                }
                else r = g = b = ToByte(prms is null ? d[i] : prms[0].Apply(d[i]));
                int o = i * 4;
                pixels[o] = b; pixels[o + 1] = g; pixels[o + 2] = r; pixels[o + 3] = 255;
            }
        });
        return new Frame(pixels, w, h, image.Width, image.Height);
    }

    private static byte ToByte(float v) => v <= 0f ? (byte)0 : v >= 1f ? (byte)255 : (byte)(v * 255f + 0.5f);

    /// <summary>Doboz-átlagolás egész szorzóval.</summary>
    public static AstroImage Downsample(AstroImage img, int factor)
    {
        int w = img.Width / factor, h = img.Height / factor;
        var outImg = new AstroImage(w, h, img.Channels);
        float inv = 1f / (factor * factor);
        for (int c = 0; c < img.Channels; c++)
        {
            var src = img.Data; var dst = outImg.Data;
            int so = c * img.PixelsPerChannel, dOff = c * outImg.PixelsPerChannel;
            Parallel.For(0, h, y =>
            {
                for (int x = 0; x < w; x++)
                {
                    float sum = 0f;
                    for (int yy = 0; yy < factor; yy++)
                    {
                        int row = so + (y * factor + yy) * img.Width + x * factor;
                        for (int xx = 0; xx < factor; xx++) sum += src[row + xx];
                    }
                    dst[dOff + y * w + x] = sum * inv;
                }
            });
        }
        return outImg;
    }
}
