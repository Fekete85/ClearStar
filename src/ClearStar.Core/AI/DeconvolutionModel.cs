using ClearStar.Core.Imaging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace ClearStar.Core.AI;

/// <summary>
/// Runs the GraXpert deconvolution (sharpening) networks on a linear image. Two networks exist:
/// a stellar one (tightens stars) and an object one (sharpens nebulae and galaxies). Both take
/// 512×512 single-channel tiles that are log-normalised per tile, plus a two-value condition
/// vector (normalised PSF size, strength). The net predicts a residual that is subtracted from
/// the normalised tile. Tiles overlap by 64 px so that only their 448×448 cores are kept.
/// The tiling, normalisation and PSF mapping follow GraXpert's <c>deconvolution.py</c>.
/// </summary>
public static class DeconvolutionModel
{
    public const int Window = 512;
    public const int Stride = 448;
    public const int Offset = (Window - Stride) / 2;
    private const float Epsilon = 1e-5f;
    private const float NormScale = 0.1f;

    /// <summary>Maps a star FWHM in pixels to the network's 0.05–0.95 condition value (version-specific, as in GraXpert).</summary>
    public static float NormalizedPsf(bool stellar, string modelVersion, float fwhmPx)
    {
        float sigma = fwhmPx / 2.355f;
        float v = stellar ? (sigma - 1.5f) / 3.0f
                : modelVersion.Contains("1.0.0") ? (sigma - 1.0f) / 5.0f
                : (sigma - 0.5f) / 5.5f;
        return Math.Clamp(v, 0.05f, 0.95f);
    }

    /// <summary>
    /// Source row/column of a padded coordinate. The image is first extended to a whole number of
    /// strides by repeating its last rows/columns, then an <see cref="Offset"/>-wide border is added
    /// by repeating the first and last rows/columns of that extended image (GraXpert's scheme).
    /// </summary>
    public static int PadIndex(int padded, int size, int extended)
    {
        int r = padded < Offset ? padded : padded < Offset + extended ? padded - Offset : padded - 2 * Offset;
        r = Math.Clamp(r, 0, extended - 1);
        int d = extended - size;
        if (r < size) return r;
        int m = r - d;                       // repeat the last d rows, as GraXpert does
        return m >= 0 ? m : r % size;        // tiny images (d > size): wrap around instead
    }

    /// <summary>Sharpens the image with the given network. Strength 0..1, FWHM in pixels.</summary>
    public static AstroImage Deconvolve(AstroImage image, string modelPath, bool stellar, float strength, float fwhmPx,
        Action<double>? progress = null, CancellationToken ct = default)
    {
        int w = image.Width, h = image.Height, ch = image.Channels;
        string version = Path.GetFileName(Path.GetDirectoryName(modelPath) ?? "") ?? "";
        float psf = NormalizedPsf(stellar, version, fwhmPx);
        strength = Math.Clamp(strength, 0f, 1f) * 0.95f; // strength 1.0 gives no result in the nets (GraXpert quirk)

        int ith = h / Stride + 1, itw = w / Stride + 1;
        int eh = ith * Stride, ew = itw * Stride;          // extended to whole strides
        int ph = eh + 2 * Offset, pw = ew + 2 * Offset;    // plus border

        // Padded copies of every channel (row/column index maps are shared).
        var rowMap = new int[ph]; for (int y = 0; y < ph; y++) rowMap[y] = PadIndex(y, h, eh);
        var colMap = new int[pw]; for (int x = 0; x < pw; x++) colMap[x] = PadIndex(x, w, ew);
        var padded = new float[ch][];
        for (int c = 0; c < ch; c++)
        {
            var dst = padded[c] = new float[ph * pw];
            int channelOffset = c * image.PixelsPerChannel;
            var data = image.Data;
            Parallel.For(0, ph, y =>
            {
                int srow = channelOffset + rowMap[y] * w;
                for (int x = 0; x < pw; x++) dst[y * pw + x] = data[srow + colMap[x]];
            });
        }
        var output = new float[ch][];
        for (int c = 0; c < ch; c++) output[c] = (float[])padded[c].Clone();

        using var session = OnnxSessions.Create(modelPath);
        bool separateParams = session.InputMetadata.ContainsKey("sigma"); // object model v1.0.0 layout

        int total = ith * itw, done = 0;
        var input = new DenseTensor<float>([ch, 1, Window, Window]);
        var mins = new float[ch];
        for (int i = 0; i < ith; i++)
        for (int j = 0; j < itw; j++)
        {
            ct.ThrowIfCancellationRequested();
            int x0 = i * Stride, y0 = j * Stride; // GraXpert: i walks rows, j walks columns

            // Log-normalise the tile: per-channel minimum, then a shared mean/std over all channels.
            double sum = 0, sumSq = 0;
            for (int c = 0; c < ch; c++)
            {
                float min = float.MaxValue;
                var p = padded[c];
                for (int y = 0; y < Window; y++)
                {
                    int row = (x0 + y) * pw + y0;
                    for (int x = 0; x < Window; x++) min = Math.Min(min, p[row + x]);
                }
                mins[c] = min;
                for (int y = 0; y < Window; y++)
                {
                    int row = (x0 + y) * pw + y0;
                    for (int x = 0; x < Window; x++)
                    {
                        float v = MathF.Log(p[row + x] - min + Epsilon);
                        input[c, 0, y, x] = v;
                        sum += v; sumSq += v * v;
                    }
                }
            }
            int n = ch * Window * Window;
            float mean = (float)(sum / n);
            float std = MathF.Max((float)Math.Sqrt(Math.Max(sumSq / n - (double)mean * mean, 0)), 1e-6f);
            for (int c = 0; c < ch; c++)
                for (int y = 0; y < Window; y++)
                    for (int x = 0; x < Window; x++)
                        input[c, 0, y, x] = (input[c, 0, y, x] - mean) / std * NormScale;

            var feeds = new List<NamedOnnxValue> { NamedOnnxValue.CreateFromTensor("gen_input_image", input) };
            if (separateParams)
            {
                var sigma = new DenseTensor<float>([ch, 1]);
                var str = new DenseTensor<float>([ch, 1]);
                for (int c = 0; c < ch; c++) { sigma[c, 0] = psf; str[c, 0] = strength; }
                feeds.Add(NamedOnnxValue.CreateFromTensor("sigma", sigma));
                feeds.Add(NamedOnnxValue.CreateFromTensor("strenght", str));
            }
            else
            {
                var prm = new DenseTensor<float>([ch, 2]);
                for (int c = 0; c < ch; c++) { prm[c, 0] = psf; prm[c, 1] = strength; }
                feeds.Add(NamedOnnxValue.CreateFromTensor("params", prm));
            }
            using var results = session.Run(feeds);
            var residual = results.First().AsTensor<float>();

            // Residual → de-normalise → exp → back to the original scale; keep only the tile core.
            for (int c = 0; c < ch; c++)
            {
                var dst = output[c];
                for (int y = Offset; y < Offset + Stride; y++)
                {
                    int row = (x0 + y) * pw + y0;
                    for (int x = Offset; x < Offset + Stride; x++)
                    {
                        float v = (input[c, 0, y, x] - residual[c, 0, y, x]) * std / NormScale + mean;
                        dst[row + x] = MathF.Exp(v) + mins[c] - Epsilon;
                    }
                }
            }
            progress?.Invoke(++done / (double)total);
        }

        var result = new AstroImage(w, h, ch, null, new Dictionary<string, string>(image.Header, StringComparer.OrdinalIgnoreCase));
        for (int c = 0; c < ch; c++)
        {
            var src = output[c]; var dst = result.Channel(c);
            for (int y = 0; y < h; y++)
                src.AsSpan((y + Offset) * pw + Offset, w).CopyTo(dst.Slice(y * w, w));
        }
        result.Clamp01();
        return result;
    }
}
