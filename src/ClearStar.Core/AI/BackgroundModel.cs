using ClearStar.Core.Imaging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace ClearStar.Core.AI;

/// <summary>
/// A GraXpert háttérkivonó hálójának futtatása. A háló egy 256×256-os, csatornánként normált
/// képből becsüli meg a háttér (gradiens) modelljét; a lépések a GraXpert kódját követik:
/// kicsinyítés 240×240-re, 8 px szélső ismétlés, (x−medián)/MAD·0,04 normálás és [−1,1] vágás,
/// inferencia, visszanormálás, opcionális simítás, Gauss(σ=3), felnagyítás az eredeti méretre.
/// </summary>
public static class BackgroundModel
{
    private const int NetSize = 256;
    private const int Padding = 8;
    private const float Scale = 0.04f;

    /// <summary>A becsült háttér az eredeti kép méretében.</summary>
    public static AstroImage EstimateBackground(AstroImage image, string modelPath, float smoothing = 0f, CancellationToken ct = default)
    {
        int inner = NetSize - 2 * Padding;
        int w = image.Width, h = image.Height, ch = image.Channels;

        // Kicsinyítés csatornánként, majd szélső pixel ismétlése a padding sávban.
        var small = new float[3][];
        var median = new float[3];
        var mad = new float[3];
        for (int c = 0; c < 3; c++)
        {
            int src = Math.Min(c, ch - 1);
            // Az üres (0) területeket – elforgatott képek sarkai – a csatorna mediánjával töltjük ki,
            // hogy ne rántsák le a becsült hátteret a széleken.
            var channel = image.Channel(src).ToArray();
            float fill = ImageStats.Compute(channel).Median;
            for (int i = 0; i < channel.Length; i++) if (channel[i] <= 0f) channel[i] = fill;
            var shrunk = Resample.Resize(channel, w, h, inner, inner);
            var padded = new float[NetSize * NetSize];
            for (int y = 0; y < NetSize; y++)
            {
                int sy = Math.Clamp(y - Padding, 0, inner - 1);
                for (int x = 0; x < NetSize; x++)
                    padded[y * NetSize + x] = shrunk[sy * inner + Math.Clamp(x - Padding, 0, inner - 1)];
            }
            var sorted = (float[])padded.Clone();
            median[c] = ImageStats.Median(sorted);
            for (int i = 0; i < sorted.Length; i++) sorted[i] = Math.Abs(padded[i] - median[c]);
            mad[c] = Math.Max(ImageStats.Median(sorted), 1e-6f);
            small[c] = padded;
        }
        ct.ThrowIfCancellationRequested();

        // NHWC bemenet: [1, 256, 256, 3]
        var input = new DenseTensor<float>([1, NetSize, NetSize, 3]);
        for (int y = 0; y < NetSize; y++)
            for (int x = 0; x < NetSize; x++)
                for (int c = 0; c < 3; c++)
                    input[0, y, x, c] = Math.Clamp((small[c][y * NetSize + x] - median[c]) / mad[c] * Scale, -1f, 1f);

        using var session = new InferenceSession(modelPath);
        string inputName = session.InputMetadata.Keys.First();
        using var results = session.Run([NamedOnnxValue.CreateFromTensor(inputName, input)]);
        var output = results.First().AsTensor<float>();
        ct.ThrowIfCancellationRequested();

        var background = new AstroImage(w, h, ch, null, new Dictionary<string, string>(image.Header, StringComparer.OrdinalIgnoreCase));
        for (int c = 0; c < ch; c++)
        {
            var net = new float[NetSize * NetSize];
            for (int y = 0; y < NetSize; y++)
                for (int x = 0; x < NetSize; x++)
                    net[y * NetSize + x] = output[0, y, x, c] / Scale * mad[c] + median[c];
            if (smoothing > 0f) net = Resample.GaussianBlur(net, NetSize, NetSize, smoothing * 20f);

            // Padding levágása, majd Gauss(σ=3) és felnagyítás.
            var core = new float[inner * inner];
            for (int y = 0; y < inner; y++)
                Array.Copy(net, (y + Padding) * NetSize + Padding, core, y * inner, inner);
            core = Resample.GaussianBlur(core, inner, inner, 3f);
            var full = Resample.Resize(core, inner, inner, w, h);
            full.AsSpan().CopyTo(background.Channel(c));
        }
        return background;
    }

    /// <summary>Kivonás: kép − háttér + a háttér átlaga (minden csatornán a közös átlag, mint a GraXpertben).</summary>
    public static AstroImage Subtract(AstroImage image, AstroImage background)
    {
        var result = image.CreateEmptyLike();
        double sum = 0; foreach (var v in background.Data) sum += v;
        float mean = (float)(sum / background.Data.Length);
        var src = image.Data; var bg = background.Data; var dst = result.Data;
        Parallel.For(0, image.Height, y =>
        {
            for (int c = 0; c < image.Channels; c++)
            {
                int start = c * image.PixelsPerChannel + y * image.Width;
                for (int i = start; i < start + image.Width; i++) dst[i] = src[i] - bg[i] + mean;
            }
        });
        result.Clamp01();
        return result;
    }

    /// <summary>Osztás (flat-szerű korrekció): kép / háttér · a csatorna átlaga.</summary>
    public static AstroImage Divide(AstroImage image, AstroImage background)
    {
        var result = image.CreateEmptyLike();
        var src = image.Data; var bg = background.Data; var dst = result.Data;
        for (int c = 0; c < image.Channels; c++)
        {
            var chn = image.Channel(c);
            double sum = 0; foreach (var v in chn) sum += v;
            float mean = (float)(sum / chn.Length);
            int off = c * image.PixelsPerChannel;
            Parallel.For(0, image.Height, y =>
            {
                for (int i = off + y * image.Width; i < off + (y + 1) * image.Width; i++)
                    dst[i] = bg[i] > 1e-6f ? src[i] / bg[i] * mean : src[i];
            });
        }
        result.Clamp01();
        return result;
    }
}
