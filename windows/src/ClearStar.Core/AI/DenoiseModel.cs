using ClearStar.Core.Imaging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace ClearStar.Core.AI;

/// <summary>
/// Runs the GraXpert denoising network. The image is normalised per channel with the global
/// median and MAD ((x − median) / MAD · 0.04), cut into 256×256 RGB tiles with a 128 px stride,
/// and the net returns the denoised tile. Pixels above the model threshold (bright stars, cores)
/// keep their original values; the result is blended with the original by the strength.
/// Follows GraXpert's <c>denoising.py</c>.
/// </summary>
public static class DenoiseModel
{
    public const int Window = 256;
    public const int Stride = 128;
    private const float Scale = 0.04f;
    private const int Batch = 8;

    /// <summary>Old (1.x) models were trained on a ±1 range, the current ones on ±10.</summary>
    public static float ThresholdFor(string modelVersion) =>
        modelVersion.Contains("1.0.0") || modelVersion.Contains("1.1.0") ? 1f : 10f;

    public static AstroImage Denoise(AstroImage image, string modelPath, float strength, Action<double>? progress = null, CancellationToken ct = default)
    {
        int w = image.Width, h = image.Height, ch = image.Channels;
        string version = Path.GetFileName(Path.GetDirectoryName(modelPath) ?? "") ?? "";
        float threshold = ThresholdFor(version);
        strength = Math.Clamp(strength, 0f, 1f);

        // Per-channel median / MAD of the whole image (empty rotation corners excluded).
        var stats = ImageStats.ComputeAll(image);
        var median = new float[3]; var mad = new float[3];
        for (int c = 0; c < 3; c++)
        {
            var s = stats[Math.Min(c, ch - 1)];
            median[c] = s.Median; mad[c] = Math.Max(s.Mad, 1e-6f);
        }

        var tiling = new Tiling(Window, Stride, w, h);
        int pw = tiling.PaddedWidth, off = tiling.Offset;
        var rowMap = tiling.RowMap(); var colMap = tiling.ColMap();
        // The net always takes three channels: a mono image is fed as grey RGB.
        var padded = new float[3][];
        for (int c = 0; c < 3; c++) padded[c] = tiling.Pad(image.Data, Math.Min(c, ch - 1) * image.PixelsPerChannel, rowMap, colMap);
        var output = new float[3][];
        for (int c = 0; c < 3; c++) output[c] = (float[])padded[c].Clone();

        using var session = OnnxSessions.Create(modelPath);
        int total = tiling.TileCount, done = 0;
        var tiles = new List<(int x0, int y0)>();
        for (int i = 0; i < tiling.Rows; i++)
            for (int j = 0; j < tiling.Cols; j++) tiles.Add((i * Stride, j * Stride));

        for (int b = 0; b < tiles.Count; b += Batch)
        {
            ct.ThrowIfCancellationRequested();
            int n = Math.Min(Batch, tiles.Count - b);
            var input = new DenseTensor<float>([n, Window, Window, 3]);      // NHWC
            var raw = new float[n, Window, Window, 3];                       // unclipped normalised values
            for (int t = 0; t < n; t++)
            {
                var (x0, y0) = tiles[b + t];
                for (int c = 0; c < 3; c++)
                {
                    var p = padded[c];
                    for (int y = 0; y < Window; y++)
                    {
                        int row = (x0 + y) * pw + y0;
                        for (int x = 0; x < Window; x++)
                        {
                            float v = (p[row + x] - median[c]) / mad[c] * Scale;
                            raw[t, y, x, c] = v;
                            input[t, y, x, c] = Math.Clamp(v, -threshold, threshold);
                        }
                    }
                }
            }
            using var results = session.Run([NamedOnnxValue.CreateFromTensor("gen_input_image", input)]);
            var res = results.First().AsTensor<float>();

            for (int t = 0; t < n; t++)
            {
                var (x0, y0) = tiles[b + t];
                for (int c = 0; c < 3; c++)
                {
                    var dst = output[c];
                    for (int y = off; y < off + Stride; y++)
                    {
                        int row = (x0 + y) * pw + y0;
                        for (int x = off; x < off + Stride; x++)
                        {
                            float v = raw[t, y, x, c] < threshold ? res[t, y, x, c] : raw[t, y, x, c];
                            dst[row + x] = v / Scale * mad[c] + median[c];
                        }
                    }
                }
            }
            done += n;
            progress?.Invoke(done / (double)total);
        }

        // Blend: bright pixels stay original, the rest is mixed by the strength.
        var result = new AstroImage(w, h, ch, null, new Dictionary<string, string>(image.Header, StringComparer.OrdinalIgnoreCase));
        for (int c = 0; c < ch; c++)
        {
            var denoised = new float[w * h];
            tiling.Unpad(output[c], denoised);
            float absThreshold = threshold / Scale * mad[c] + median[c];
            var src = image.Channel(c); var dst = result.Channel(c);
            for (int i = 0; i < denoised.Length; i++)
            {
                float o = src[i];
                float d = o < absThreshold ? denoised[i] : o;
                dst[i] = Math.Clamp(d * strength + o * (1f - strength), 0f, 1f);
            }
        }
        return result;
    }
}
