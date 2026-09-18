namespace ClearStar.Core.Imaging;

/// <summary>
/// Lebegőpontos, síkonként tárolt kép (planar): a 0. csatorna Width*Height floatja,
/// utána az 1., majd a 2. csatorna. Mono (1 csatorna) vagy RGB (3 csatorna).
/// Az értékek a [0,1] tartományban vannak; a feldolgozás során ideiglenesen kilóghatnak.
/// </summary>
public sealed class AstroImage
{
    public int Width { get; }
    public int Height { get; }
    public int Channels { get; }
    public float[] Data { get; }
    public Dictionary<string, string> Header { get; }

    public int PixelsPerChannel => Width * Height;
    public bool IsColor => Channels == 3;

    public AstroImage(int width, int height, int channels, float[]? data = null, Dictionary<string, string>? header = null)
    {
        if (width <= 0 || height <= 0) throw new ArgumentOutOfRangeException(nameof(width), "A képméretnek pozitívnak kell lennie.");
        if (channels is not (1 or 3)) throw new ArgumentOutOfRangeException(nameof(channels), "Csak 1 vagy 3 csatornás kép támogatott.");
        long count = (long)width * height * channels;
        if (count > int.MaxValue) throw new ArgumentOutOfRangeException(nameof(width), "Túl nagy kép.");
        if (data is not null && data.Length != count) throw new ArgumentException("Az adattömb mérete nem egyezik a képmérettel.", nameof(data));

        Width = width;
        Height = height;
        Channels = channels;
        Data = data ?? new float[count];
        Header = header ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    public Span<float> Channel(int c)
    {
        if ((uint)c >= (uint)Channels) throw new ArgumentOutOfRangeException(nameof(c));
        return Data.AsSpan(c * PixelsPerChannel, PixelsPerChannel);
    }

    public float this[int c, int x, int y]
    {
        get => Data[c * PixelsPerChannel + y * Width + x];
        set => Data[c * PixelsPerChannel + y * Width + x] = value;
    }

    public AstroImage Clone()
    {
        var copy = new float[Data.Length];
        Array.Copy(Data, copy, Data.Length);
        return new AstroImage(Width, Height, Channels, copy, new Dictionary<string, string>(Header, StringComparer.OrdinalIgnoreCase));
    }

    /// <summary>Üres kép ugyanazzal a geometriával és fejléccel.</summary>
    public AstroImage CreateEmptyLike() =>
        new(Width, Height, Channels, null, new Dictionary<string, string>(Header, StringComparer.OrdinalIgnoreCase));

    /// <summary>Minden értéket a [0,1] tartományba szorít.</summary>
    public void Clamp01()
    {
        var d = Data.AsSpan();
        for (int i = 0; i < d.Length; i++)
        {
            float v = d[i];
            d[i] = v < 0f ? 0f : v > 1f ? 1f : v;
        }
    }

    /// <summary>Világosság (Rec.709 súlyozás) egy pixelre; mono képnél maga az érték.</summary>
    public float Luminance(int index)
    {
        if (Channels == 1) return Data[index];
        int n = PixelsPerChannel;
        return 0.2126f * Data[index] + 0.7152f * Data[n + index] + 0.0722f * Data[2 * n + index];
    }

    /// <summary>Box average with an integer factor (the preview's downsampling).</summary>
    public AstroImage Downsample(int factor)
    {
        if (factor <= 1) return this;
        int w = Width / factor, h = Height / factor;
        var outImg = new AstroImage(w, h, Channels);
        float inv = 1f / (factor * factor);
        for (int c = 0; c < Channels; c++)
        {
            var src = Data; var dst = outImg.Data;
            int so = c * PixelsPerChannel, dOff = c * outImg.PixelsPerChannel;
            Parallel.For(0, h, y =>
            {
                for (int x = 0; x < w; x++)
                {
                    float sum = 0f;
                    for (int yy = 0; yy < factor; yy++)
                    {
                        int row = so + (y * factor + yy) * Width + x * factor;
                        for (int xx = 0; xx < factor; xx++) sum += src[row + xx];
                    }
                    dst[dOff + y * w + x] = sum * inv;
                }
            });
        }
        return outImg;
    }

    /// <summary>Integer factor that brings the longer side down to <paramref name="maxSide"/> pixels (1 = no downsampling).</summary>
    public int DownsampleFactor(int maxSide) => Math.Max(1, (int)Math.Ceiling(Math.Max(Width, Height) / (double)maxSide));
}
