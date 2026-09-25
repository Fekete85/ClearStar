namespace ClearStar.Core.Imaging;

/// <summary>Átméretezés és simítás egy csatornára (síkonként tárolt float képekhez).</summary>
public static class Resample
{
    /// <summary>Kicsinyítés területi átlagolással (tetszőleges arány), nagyításnál bilineáris.</summary>
    public static float[] Resize(ReadOnlySpan<float> src, int sw, int sh, int dw, int dh)
    {
        var dst = new float[dw * dh];
        if (dw <= sw && dh <= sh)
        {
            // Területi átlag: minden célpixel a forrás egy téglalapjának átlaga (súlyozott a részpixelekkel).
            double sx = sw / (double)dw, sy = sh / (double)dh;
            for (int y = 0; y < dh; y++)
            {
                double y0 = y * sy, y1 = (y + 1) * sy;
                int iy0 = (int)y0, iy1 = Math.Min(sh - 1, (int)Math.Ceiling(y1) - 1);
                for (int x = 0; x < dw; x++)
                {
                    double x0 = x * sx, x1 = (x + 1) * sx;
                    int ix0 = (int)x0, ix1 = Math.Min(sw - 1, (int)Math.Ceiling(x1) - 1);
                    double sum = 0, wsum = 0;
                    for (int yy = iy0; yy <= iy1; yy++)
                    {
                        double wy = Math.Min(y1, yy + 1) - Math.Max(y0, yy);
                        if (wy <= 0) continue;
                        int row = yy * sw;
                        for (int xx = ix0; xx <= ix1; xx++)
                        {
                            double wx = Math.Min(x1, xx + 1) - Math.Max(x0, xx);
                            if (wx <= 0) continue;
                            sum += src[row + xx] * wx * wy;
                            wsum += wx * wy;
                        }
                    }
                    dst[y * dw + x] = wsum > 0 ? (float)(sum / wsum) : 0f;
                }
            }
            return dst;
        }

        // Bilineáris nagyítás (a pixelközéppontokat egymásra illesztve).
        var s = src.ToArray();
        Parallel.For(0, dh, y =>
        {
            double fy = (y + 0.5) * sh / dh - 0.5;
            int y0 = Math.Clamp((int)Math.Floor(fy), 0, sh - 1), y1 = Math.Min(y0 + 1, sh - 1);
            float ty = (float)Math.Clamp(fy - y0, 0, 1);
            for (int x = 0; x < dw; x++)
            {
                double fx = (x + 0.5) * sw / dw - 0.5;
                int x0 = Math.Clamp((int)Math.Floor(fx), 0, sw - 1), x1 = Math.Min(x0 + 1, sw - 1);
                float tx = (float)Math.Clamp(fx - x0, 0, 1);
                float a = s[y0 * sw + x0] * (1 - tx) + s[y0 * sw + x1] * tx;
                float b = s[y1 * sw + x0] * (1 - tx) + s[y1 * sw + x1] * tx;
                dst[y * dw + x] = a * (1 - ty) + b * ty;
            }
        });
        return dst;
    }

    /// <summary>Szeparábilis Gauss-simítás, a széleken tükrözéssel.</summary>
    public static float[] GaussianBlur(ReadOnlySpan<float> src, int w, int h, float sigma)
    {
        if (sigma <= 0f) return src.ToArray();
        int radius = Math.Max(1, (int)Math.Ceiling(sigma * 3));
        var kernel = new float[2 * radius + 1];
        float sum = 0;
        for (int i = -radius; i <= radius; i++) { kernel[i + radius] = MathF.Exp(-i * i / (2 * sigma * sigma)); sum += kernel[i + radius]; }
        for (int i = 0; i < kernel.Length; i++) kernel[i] /= sum;

        var tmp = new float[w * h];
        var s = src.ToArray();
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                float acc = 0;
                for (int k = -radius; k <= radius; k++)
                {
                    int xx = x + k;
                    if (xx < 0) xx = -xx; if (xx >= w) xx = 2 * w - xx - 2;
                    acc += s[y * w + Math.Clamp(xx, 0, w - 1)] * kernel[k + radius];
                }
                tmp[y * w + x] = acc;
            }
        var dst = new float[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                float acc = 0;
                for (int k = -radius; k <= radius; k++)
                {
                    int yy = y + k;
                    if (yy < 0) yy = -yy; if (yy >= h) yy = 2 * h - yy - 2;
                    acc += tmp[Math.Clamp(yy, 0, h - 1) * w + x] * kernel[k + radius];
                }
                dst[y * w + x] = acc;
            }
        return dst;
    }
}
