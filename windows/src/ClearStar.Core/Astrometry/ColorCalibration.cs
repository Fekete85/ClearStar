using ClearStar.Core.Imaging;

namespace ClearStar.Core.Astrometry;

/// <summary>One measured star: catalogue colour and the instrumental colour indices (magnitudes).</summary>
public readonly record struct ColorSample(float BpRp, float RminusG, float BminusG);

/// <summary>Result of a photometric colour calibration: the channel factors and the fit quality.</summary>
public sealed record ColorCalibrationResult(float RedFactor, float BlueFactor, int StarsUsed, float SlopeR, float SlopeB, float ScatterR, float ScatterB);

/// <summary>
/// Photometric colour calibration (SPCC-style). Catalogue stars with Gaia BP/RP magnitudes are
/// measured with aperture photometry in the three channels; the instrumental colour indices
/// −2.5·log10(R/G) and −2.5·log10(B/G) are fitted as straight lines against BP−RP, and the fit
/// evaluated at the white reference colour gives the factors that make such a star white.
/// </summary>
public static class ColorCalibration
{
    /// <summary>Gaia BP−RP of the white reference: a Sun-like (G2V) star / average spiral galaxy.</summary>
    public const float GalaxyBpRp = 0.82f;
    /// <summary>Gaia BP−RP of an A0V (Vega-like) star.</summary>
    public const float VegaBpRp = 0.0f;

    /// <summary>Aperture photometry of the catalogue stars that fall on the image. Positions come from the WCS.</summary>
    public static List<ColorSample> Measure(AstroImage image, Wcs wcs, IReadOnlyList<CatalogStar> catalog, float fwhm, CancellationToken ct = default)
    {
        if (image.Channels != 3) return [];
        int w = image.Width, h = image.Height;
        float rAp = Math.Max(3f, 1.5f * fwhm), rIn = Math.Max(rAp + 2f, 3f * fwhm), rOut = rIn + Math.Max(3f, 1.5f * fwhm);
        int reach = (int)Math.Ceiling(rOut) + 1;
        var r = image.Channel(0).ToArray(); var g = image.Channel(1).ToArray(); var b = image.Channel(2).ToArray();
        var samples = new List<ColorSample>();
        var ring = new List<float>();

        // Avoid blended stars: skip a star when another catalogue star lies within the annulus.
        var positions = new List<(double x, double y, int idx)>();
        for (int i = 0; i < catalog.Count; i++)
        {
            var p = wcs.SkyToPixel(catalog[i].Ra, catalog[i].Dec);
            if (p is null) continue;
            positions.Add((p.Value.x, p.Value.y, i));
        }
        var grid = new Dictionary<(int, int), List<int>>();
        float cell = rOut * 2;
        foreach (var (x, y, idx) in positions)
        {
            var key = ((int)MathF.Floor((float)x / cell), (int)MathF.Floor((float)y / cell));
            if (!grid.TryGetValue(key, out var list)) grid[key] = list = [];
            list.Add(idx);
        }
        var posByIdx = positions.ToDictionary(p => p.idx, p => (p.x, p.y));

        foreach (var (x, y, idx) in positions)
        {
            ct.ThrowIfCancellationRequested();
            var star = catalog[idx];
            if (float.IsNaN(star.Bp) || float.IsNaN(star.Rp)) continue;
            int cx = (int)Math.Round(x), cy = (int)Math.Round(y);
            if (cx < reach || cy < reach || cx >= w - reach || cy >= h - reach) continue;

            bool crowded = false;
            var key = ((int)MathF.Floor((float)x / cell), (int)MathF.Floor((float)y / cell));
            for (int i = -1; i <= 1 && !crowded; i++)
            for (int j = -1; j <= 1 && !crowded; j++)
                if (grid.TryGetValue((key.Item1 + i, key.Item2 + j), out var list))
                    foreach (int other in list)
                    {
                        if (other == idx) continue;
                        var (ox, oy) = posByIdx[other];
                        double d2 = (ox - x) * (ox - x) + (oy - y) * (oy - y);
                        if (d2 < rOut * rOut && catalog[other].G < star.G + 3f) { crowded = true; break; }
                    }
            if (crowded) continue;

            float fr = 0, fg = 0, fb = 0, peak = 0;
            bool ok = true;
            for (int c = 0; c < 3 && ok; c++)
            {
                var data = c == 0 ? r : c == 1 ? g : b;
                ring.Clear();
                double sum = 0; int n = 0;
                for (int dy = -reach; dy <= reach; dy++)
                for (int dx = -reach; dx <= reach; dx++)
                {
                    float d = MathF.Sqrt(dx * dx + dy * dy);
                    float v = data[(cy + dy) * w + cx + dx];
                    if (d >= rIn && d <= rOut) ring.Add(v);
                    else if (d <= rAp) { sum += v; n++; peak = Math.Max(peak, v); }
                }
                if (ring.Count < 8 || n < 4) { ok = false; break; }
                float bg = ImageStats.Median(ring.ToArray());
                float mad = ImageStats.Median(ring.Select(v => Math.Abs(v - bg)).ToArray());
                float flux = (float)(sum - n * bg);
                // Signal-to-noise gate: the aperture flux must stand well above the background noise.
                if (flux < 25f * mad * MathF.Sqrt(n)) { ok = false; break; }
                if (c == 0) fr = flux; else if (c == 1) fg = flux; else fb = flux;
            }
            if (!ok || peak > 0.9f || fr <= 0 || fg <= 0 || fb <= 0) continue;
            samples.Add(new ColorSample(star.BpRp, -2.5f * MathF.Log10(fr / fg), -2.5f * MathF.Log10(fb / fg)));
        }
        return samples;
    }

    /// <summary>Robust straight-line fits and the factors for the given white reference.</summary>
    public static ColorCalibrationResult? Fit(IReadOnlyList<ColorSample> samples, float whiteBpRp, int minStars = 12)
    {
        if (samples.Count < minStars) return null;
        var (aR, bR, nR, sR) = RobustLine(samples.Select(s => (s.BpRp, s.RminusG)).ToList());
        var (aB, bB, nB, sB) = RobustLine(samples.Select(s => (s.BpRp, s.BminusG)).ToList());
        if (Math.Min(nR, nB) < minStars) return null;
        float mR = aR * whiteBpRp + bR, mB = aB * whiteBpRp + bB;
        // A white star must end up with R = G = B: scale R and B by their predicted deficit.
        float kR = MathF.Pow(10f, 0.4f * mR), kB = MathF.Pow(10f, 0.4f * mB);
        if (!float.IsFinite(kR) || !float.IsFinite(kB) || kR < 0.2f || kR > 5f || kB < 0.2f || kB > 5f) return null;
        return new ColorCalibrationResult(kR, kB, Math.Min(nR, nB), aR, aB, sR, sB);
    }

    /// <summary>Least squares with three rounds of 2.5σ rejection. Returns slope, intercept, stars kept, scatter.</summary>
    public static (float a, float b, int n, float scatter) RobustLine(List<(float x, float y)> pts)
    {
        var keep = pts.ToList();
        float a = 0, b = 0, scatter = 0;
        for (int round = 0; round < 4; round++)
        {
            if (keep.Count < 3) break;
            double sx = 0, sy = 0, sxx = 0, sxy = 0; int n = keep.Count;
            foreach (var (x, y) in keep) { sx += x; sy += y; sxx += x * x; sxy += x * y; }
            double det = n * sxx - sx * sx;
            if (Math.Abs(det) < 1e-9) { a = 0; b = (float)(sy / n); }
            else { a = (float)((n * sxy - sx * sy) / det); b = (float)((sy - a * sx) / n); }
            var resid = keep.Select(p => p.y - (a * p.x + b)).ToList();
            float med = ImageStats.Median(resid.ToArray());
            float mad = ImageStats.Median(resid.Select(v => Math.Abs(v - med)).ToArray());
            scatter = Math.Max(mad * 1.4826f, 1e-4f);
            var next = keep.Where((p, i) => Math.Abs(resid[i] - med) <= 2.5f * scatter).ToList();
            if (next.Count == keep.Count) break;
            keep = next;
        }
        return (a, b, keep.Count, scatter);
    }

    /// <summary>Applies the factors around a neutral background: (v − bg_c)·k_c + bg, with bg the median channel background.</summary>
    public static AstroImage Apply(AstroImage image, float kR, float kB, bool neutralizeBackground)
    {
        var stats = ImageStats.ComputeAll(image);
        float[] k = [kR, 1f, kB];
        float[] bg = [stats[0].Median, stats[1].Median, stats[2].Median];
        float target = neutralizeBackground ? ImageStats.Median((float[])bg.Clone()) : 0f;
        var result = image.CreateEmptyLike();
        int n = image.PixelsPerChannel;
        for (int c = 0; c < 3; c++)
        {
            float kc = k[c], bgc = neutralizeBackground ? bg[c] : 0f, add = neutralizeBackground ? target : 0f;
            int off = c * n;
            var src = image.Data; var dst = result.Data;
            Parallel.For(0, image.Height, y =>
            {
                for (int i = off + y * image.Width; i < off + (y + 1) * image.Width; i++)
                    dst[i] = Math.Clamp((src[i] - bgc) * kc + add, 0f, 1f);
            });
        }
        return result;
    }
}
