using ClearStar.Core.Imaging;

namespace ClearStar.Core.Registration;

/// <summary>Egy detektált csillag: súlyozott középpont, háttér feletti fluxus és méret.</summary>
public readonly record struct Star(float X, float Y, float Flux, float Size);

/// <summary>
/// Egyszerű, gyors csillagkereső: a háttér + k·σ küszöb feletti összefüggő foltokat gyűjti,
/// és intenzitással súlyozott középpontot számol. Regisztrációhoz bőven elég; a fotometriához
/// később PSF-illesztés kellene.
/// </summary>
public static class StarDetector
{
    public static List<Star> Detect(AstroImage image, int maxStars = 300, float thresholdSigma = 5f, int downsample = 2, CancellationToken ct = default) =>
        Detect(image, out _, maxStars, thresholdSigma, downsample, ct);

    /// <summary>Mint a Detect, de a korlátozás előtti összes talált csillag számát is visszaadja (minőségmérő).</summary>
    public static List<Star> Detect(AstroImage image, out int totalFound, int maxStars = 300, float thresholdSigma = 5f, int downsample = 2, CancellationToken ct = default)
    {
        // Színes képnél a zöld csatorna (legjobb jel), monónál maga a kép.
        var src = image.Channels == 3 ? image.Channel(1) : image.Channel(0);
        int w = image.Width, h = image.Height;
        float[] data;
        int dw, dh;
        if (downsample > 1)
        {
            dw = w / downsample; dh = h / downsample;
            data = new float[dw * dh];
            float inv = 1f / (downsample * downsample);
            for (int y = 0; y < dh; y++)
            for (int x = 0; x < dw; x++)
            {
                float s = 0;
                for (int yy = 0; yy < downsample; yy++)
                for (int xx = 0; xx < downsample; xx++)
                    s += src[(y * downsample + yy) * w + x * downsample + xx];
                data[y * dw + x] = s * inv;
            }
        }
        else { dw = w; dh = h; data = src.ToArray(); }

        var stats = ImageStats.Compute(data);
        float background = stats.Median;
        float threshold = background + thresholdSigma * Math.Max(stats.Sigma, 1e-6f);

        var labels = new int[dw * dh];
        var stars = new List<Star>();
        var stack = new Stack<int>();
        int maxArea = Math.Max(64, dw * dh / 2000);
        for (int i = 0; i < data.Length; i++)
        {
            if (data[i] < threshold || labels[i] != 0) continue;
            ct.ThrowIfCancellationRequested();
            // Összefüggő komponens (8-szomszédság) bejárása.
            int label = stars.Count + 1;
            double sx = 0, sy = 0, sw = 0;
            int minX = int.MaxValue, maxX = -1, minY = int.MaxValue, maxY = -1, area = 0;
            float peak = 0;
            stack.Push(i); labels[i] = label;
            while (stack.Count > 0)
            {
                int p = stack.Pop();
                int px = p % dw, py = p / dw;
                float v = data[p] - background;
                sx += v * px; sy += v * py; sw += v; area++;
                if (data[p] > peak) peak = data[p];
                if (px < minX) minX = px; if (px > maxX) maxX = px;
                if (py < minY) minY = py; if (py > maxY) maxY = py;
                if (area > maxArea) continue;
                for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++)
                {
                    int nx = px + dx, ny = py + dy;
                    if (nx < 0 || ny < 0 || nx >= dw || ny >= dh) continue;
                    int q = ny * dw + nx;
                    if (labels[q] == 0 && data[q] >= threshold) { labels[q] = label; stack.Push(q); }
                }
            }
            int bw = maxX - minX + 1, bh = maxY - minY + 1;
            if (area < 2 || area > maxArea || sw <= 0) continue;
            float aspect = (float)Math.Max(bw, bh) / Math.Min(bw, bh);
            if (aspect > 2.5f) continue;                        // csík, forró pixelsor, műhold
            if (minX == 0 || minY == 0 || maxX == dw - 1 || maxY == dh - 1) continue; // képszélbe lóg
            float cx = (float)(sx / sw), cy = (float)(sy / sw);
            stars.Add(new Star((cx + 0.5f) * downsample - 0.5f, (cy + 0.5f) * downsample - 0.5f, (float)sw, MathF.Sqrt(area)));
        }
        totalFound = stars.Count;
        return stars.OrderByDescending(s => s.Flux).Take(maxStars).ToList();
    }
}
