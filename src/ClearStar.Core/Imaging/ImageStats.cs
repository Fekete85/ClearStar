namespace ClearStar.Core.Imaging;

/// <summary>Egy csatorna robusztus statisztikái (medián, MAD).</summary>
public readonly record struct ChannelStats(float Min, float Max, float Median, float Mad, float Mean)
{
    /// <summary>MAD normálva a szórásra (normál eloszlás esetén ~sigma).</summary>
    public float Sigma => Mad * 1.4826f;
}

public static class ImageStats
{
    /// <summary>
    /// Ritkított mintavétellel számol, hogy nagy képen is gyors legyen (alapból max 300k minta – a medián
    /// így is pontos). A pontosan 0 értékű pixelek nem számítanak: azok az elforgatott képek üres sarkai,
    /// nem valódi ég – így a vágás előtti és utáni kép statisztikája (és előnézete) ugyanaz.
    /// </summary>
    public static ChannelStats Compute(ReadOnlySpan<float> data, int maxSamples = 300_000)
    {
        if (data.IsEmpty) return default;
        int stride = Math.Max(1, data.Length / maxSamples);
        var samples = new float[(data.Length + stride - 1) / stride];
        float min = float.MaxValue, max = float.MinValue;
        double sum = 0;
        int n = 0;
        for (int i = 0; i < data.Length; i += stride)
        {
            float v = data[i];
            if (v <= 0f) continue;
            samples[n++] = v;
            if (v < min) min = v;
            if (v > max) max = v;
            sum += v;
        }
        if (n == 0) return default;
        if (n < samples.Length) Array.Resize(ref samples, n);
        float median = Median(samples);
        for (int i = 0; i < samples.Length; i++) samples[i] = Math.Abs(samples[i] - median);
        float mad = Median(samples);
        return new ChannelStats(min, max, median, mad, (float)(sum / n));
    }

    public static ChannelStats[] ComputeAll(AstroImage image)
    {
        var result = new ChannelStats[image.Channels];
        for (int c = 0; c < image.Channels; c++) result[c] = Compute(image.Channel(c));
        return result;
    }

    /// <summary>Medián helyben rendezéssel (a tömb módosul).</summary>
    public static float Median(float[] values)
    {
        if (values.Length == 0) return 0f;
        Array.Sort(values);
        int mid = values.Length / 2;
        return values.Length % 2 == 1 ? values[mid] : 0.5f * (values[mid - 1] + values[mid]);
    }
}
