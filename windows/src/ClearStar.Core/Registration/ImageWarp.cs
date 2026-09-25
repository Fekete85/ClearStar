using ClearStar.Core.Imaging;

namespace ClearStar.Core.Registration;

/// <summary>Kép átmintavételezése a referencia koordinátarendszerébe (bilineáris interpoláció).</summary>
public static class ImageWarp
{
    /// <summary>
    /// A referencia minden (x,y) pixeléhez a kép megfelelő pontját mintavételezi.
    /// <paramref name="toFrame"/> a referencia → kép transzformáció. A képen kívülre eső pixelek
    /// súlya 0 (a sor utolsó szakasza a súly), így az átlagolás helyes marad.
    /// </summary>
    public static void Resample(AstroImage frame, SimilarityTransform toFrame, int outWidth, int outHeight,
        Action<int, int, ReadOnlySpan<float>> rowSink, CancellationToken ct = default)
    {
        int fw = frame.Width, fh = frame.Height, fn = frame.PixelsPerChannel, ch = frame.Channels;
        float a = toFrame.A, b = toFrame.B, tx = toFrame.Tx, ty = toFrame.Ty;
        var src = frame.Data;

        Parallel.For(0, outHeight, new ParallelOptions { CancellationToken = ct }, y =>
        {
            // Sor: [csatorna0 ... | csatorna1 ... | ... | súly ...]
            var row = new float[outWidth * (ch + 1)];
            int wOff = outWidth * ch;
            for (int x = 0; x < outWidth; x++)
            {
                float sx = a * x - b * y + tx;
                float sy = b * x + a * y + ty;
                if (sx < 0 || sy < 0 || sx > fw - 1.001f || sy > fh - 1.001f) continue;
                int x0 = (int)sx, y0 = (int)sy;
                float fx = sx - x0, fy = sy - y0;
                int i00 = y0 * fw + x0;
                float w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy;
                for (int c = 0; c < ch; c++)
                {
                    int o = c * fn + i00;
                    row[c * outWidth + x] = w00 * src[o] + w10 * src[o + 1] + w01 * src[o + fw] + w11 * src[o + fw + 1];
                }
                row[wOff + x] = 1f;
            }
            rowSink(y, outWidth, row);
        });
    }
}
