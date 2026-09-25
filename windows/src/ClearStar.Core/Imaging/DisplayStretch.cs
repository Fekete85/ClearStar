namespace ClearStar.Core.Imaging;

/// <summary>
/// Megjelenítéshez való automatikus nyújtás (a Siril/PixInsight autostretch elve):
/// árnyékvágás a medián alatt 2.8 sigmával, majd MTF úgy, hogy a medián a célháttérre kerüljön.
/// Ez csak a képernyőre szól, a képadatot nem módosítja.
/// </summary>
public static class DisplayStretch
{
    public const float DefaultTargetBackground = 0.25f;
    public const float DefaultShadowsClipping = -2.8f;

    /// <summary>
    /// A screen-stretch preset: target background brightness and the shadow clipping point in
    /// MAD units below the median, matching GraXpert's "10% Bg, 3 sigma" style options.
    /// </summary>
    public sealed record Preset(string Key, float Background, float ShadowsMad)
    {
        public bool IsOff => Background <= 0f;
    }

    public static readonly IReadOnlyList<Preset> Presets =
    [
        new("off", 0f, 0f),
        new("bg10", 0.10f, 3f),
        new("bg15", 0.15f, 3f),
        new("bg20", 0.20f, 3f),
        new("bg30", 0.30f, 2f),
    ];

    public const string DefaultPresetKey = "bg20";

    /// <summary>Longer side of the downsampled image the screen stretch is measured on (also used by the wand, so it matches the preview).</summary>
    public const int PreviewWidth = 2400;

    public static Preset PresetByKey(string? key) =>
        Presets.FirstOrDefault(p => p.Key == key) ?? Presets.First(p => p.Key == DefaultPresetKey);

    /// <summary>Midtones transfer function.</summary>
    public static float Mtf(float x, float m)
    {
        if (x <= 0f) return 0f;
        if (x >= 1f) return 1f;
        return (m - 1f) * x / ((2f * m - 1f) * x - m);
    }

    public readonly record struct Params(float Shadows, float Midtones)
    {
        public static readonly Params Identity = new(0f, 0.5f);

        public float Apply(float x)
        {
            float t = (x - Shadows) / (1f - Shadows);
            return Mtf(t, Midtones);
        }

        /// <summary>Exact inverse of <see cref="Apply"/> (the MTF is its own inverse with midtones 1−m).</summary>
        public float Invert(float y)
        {
            float t = Mtf(y, 1f - Midtones);
            return t * (1f - Shadows) + Shadows;
        }
    }

    public static Params Compute(ChannelStats stats, float targetBackground = DefaultTargetBackground, float shadowsClipping = DefaultShadowsClipping)
    {
        float shadows = Math.Clamp(stats.Median + shadowsClipping * stats.Sigma, 0f, 1f);
        float x0 = Math.Clamp((stats.Median - shadows) / (1f - shadows), 1e-6f, 1f);
        // Az a midtones-érték, amely x0-t a célháttérre viszi: m = MTF(x0, target).
        float midtones = Mtf(x0, targetBackground);
        return new Params(shadows, Math.Clamp(midtones, 1e-4f, 1f - 1e-4f));
    }

    /// <summary>
    /// Csatornánként külön paraméter. Az árnyékvágás mindig csatornánként történik (ez semlegesíti a
    /// háttér színét – valódi OSC-képen a csatornák háttere eltér, közös vágás egy csatornát nullára
    /// vinne). Az összekapcsolt (linked) mód a midtones-t osztja meg, így az objektumok
    /// színaránya megmarad.
    /// </summary>
    /// <summary>Per-channel parameters for a preset (shadows = median − ShadowsMad·MAD, like GraXpert).</summary>
    public static Params[] ComputeAll(AstroImage image, Preset preset, bool linked = false)
    {
        var stats = ImageStats.ComputeAll(image);
        var result = new Params[image.Channels];
        for (int c = 0; c < image.Channels; c++)
        {
            float shadows = Math.Clamp(stats[c].Median - preset.ShadowsMad * stats[c].Mad, 0f, 1f);
            float x0 = Math.Clamp((stats[c].Median - shadows) / (1f - shadows), 1e-6f, 1f);
            result[c] = new Params(shadows, Math.Clamp(Mtf(x0, preset.Background), 1e-4f, 1f - 1e-4f));
        }
        if (linked && image.Channels == 3)
        {
            float midtones = result.Average(p => p.Midtones);
            for (int c = 0; c < image.Channels; c++) result[c] = result[c] with { Midtones = midtones };
        }
        return result;
    }

    public static Params[] ComputeAll(AstroImage image, bool linked = false, float targetBackground = DefaultTargetBackground)
    {
        var stats = ImageStats.ComputeAll(image);
        var result = new Params[image.Channels];
        for (int c = 0; c < image.Channels; c++) result[c] = Compute(stats[c], targetBackground);
        if (linked && image.Channels == 3)
        {
            float midtones = result.Average(p => p.Midtones);
            for (int c = 0; c < image.Channels; c++) result[c] = result[c] with { Midtones = midtones };
        }
        return result;
    }

    /// <summary>Nyújtás nélküli (lineáris) keresőtábla.</summary>
    public static byte[] BuildLutLinear(int size = 4096)
    {
        var lut = new byte[size];
        for (int i = 0; i < size; i++) lut[i] = (byte)Math.Round(i / (double)(size - 1) * 255.0);
        return lut;
    }

    /// <summary>Keresőtábla egy csatornához (gyors megjelenítéshez): index = érték * (size-1).</summary>
    public static byte[] BuildLut(Params p, int size = 4096)
    {
        var lut = new byte[size];
        for (int i = 0; i < size; i++)
        {
            float x = i / (float)(size - 1);
            lut[i] = (byte)Math.Clamp(MathF.Round(p.Apply(x) * 255f), 0f, 255f);
        }
        return lut;
    }
}
