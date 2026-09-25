using ClearStar.Core.Registration;

namespace ClearStar.Core.Imaging;

/// <summary>
/// Estimates the typical star size (FWHM, in pixels) of a linear image. Stars are detected at full
/// resolution; for each of the brightest unsaturated ones the local background is taken from an
/// annulus, and the area above half of the peak height gives an equivalent-disc FWHM
/// (FWHM = 2·sqrt(area/π)). The median over the stars is returned. Good enough to drive the
/// sharpening networks, which only need the value to within a pixel or so.
/// </summary>
public static class PsfMeasure
{
    private const int Radius = 7;        // measurement window half-size
    private const int RingInner = 8, RingOuter = 11;

    public static float EstimateFwhm(AstroImage image, CancellationToken ct = default, float fallback = 4f)
    {
        var stars = StarDetector.Detect(image, maxStars: 400, thresholdSigma: 6f, downsample: 1, ct: ct);
        if (stars.Count < 5) return fallback;
        var src = image.Channels == 3 ? image.Channel(1) : image.Channel(0);
        int w = image.Width, h = image.Height;
        var data = src.ToArray();

        var widths = new List<float>();
        foreach (var s in stars.OrderByDescending(s => s.Flux))
        {
            ct.ThrowIfCancellationRequested();
            int cx = (int)MathF.Round(s.X), cy = (int)MathF.Round(s.Y);
            if (cx < RingOuter || cy < RingOuter || cx >= w - RingOuter || cy >= h - RingOuter) continue;

            // Local background: median of an annulus around the star.
            var ring = new List<float>();
            for (int dy = -RingOuter; dy <= RingOuter; dy++)
            for (int dx = -RingOuter; dx <= RingOuter; dx++)
            {
                int r2 = dx * dx + dy * dy;
                if (r2 < RingInner * RingInner || r2 > RingOuter * RingOuter) continue;
                ring.Add(data[(cy + dy) * w + cx + dx]);
            }
            float background = ImageStats.Median(ring.ToArray());

            float peak = float.MinValue;
            for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++)
                peak = Math.Max(peak, data[(cy + dy) * w + cx + dx]);
            if (peak >= 0.98f || peak - background < 1e-4f) continue; // saturated or not really a star

            float half = background + 0.5f * (peak - background);
            int area = 0;
            for (int dy = -Radius; dy <= Radius; dy++)
            for (int dx = -Radius; dx <= Radius; dx++)
                if (data[(cy + dy) * w + cx + dx] >= half) area++;
            if (area < 1) continue;
            widths.Add(2f * MathF.Sqrt(area / MathF.PI));
            if (widths.Count >= 120) break;
        }
        if (widths.Count < 5) return fallback;
        return Math.Clamp(ImageStats.Median(widths.ToArray()), 1.5f, 14f);
    }
}
