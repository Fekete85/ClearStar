using ClearStar.Core.Imaging;

namespace ClearStar.Core.Pipeline;

/// <summary>
/// Hands the star layer from the star-removal step to the later steps (the workflow itself carries
/// only one image per step). Every layer is tagged with a fingerprint of the image it belongs to, so
/// a stale layer from another session or folder is never applied to the wrong image.
/// </summary>
public static class StarLayerStore
{
    /// <summary>Linear star layer (original − starless) and the fingerprint of the linear starless image.</summary>
    public static AstroImage? StarsLinear { get; private set; }
    private static string? _starlessLinearKey;

    /// <summary>The stretched starless image (set by the nebula stretch) and the stretched stars (set by the star stretch).</summary>
    public static AstroImage? StarlessStretched { get; private set; }
    public static AstroImage? StarsStretched { get; private set; }
    private static string? _starlessStretchedKey;

    public static void Clear()
    {
        StarsLinear = null; StarlessStretched = null; StarsStretched = null;
        _starlessLinearKey = _starlessStretchedKey = null;
    }

    public static void SetLinear(AstroImage starless, AstroImage stars)
    {
        Clear();
        StarsLinear = stars;
        _starlessLinearKey = Fingerprint(starless);
    }

    /// <summary>True when <paramref name="image"/> is the starless image the star layer was made for.</summary>
    public static bool HasStarsFor(AstroImage image) => StarsLinear is not null && _starlessLinearKey == Fingerprint(image);

    public static void SetStarlessStretched(AstroImage starlessStretched)
    {
        StarlessStretched = starlessStretched;
        _starlessStretchedKey = Fingerprint(starlessStretched);
        StarsStretched = null;
    }

    public static bool HasStretchedFor(AstroImage image) => StarlessStretched is not null && _starlessStretchedKey == Fingerprint(image);

    public static void SetStarsStretched(AstroImage stars) => StarsStretched = stars;

    /// <summary>Cheap identity: size plus a strided checksum of the pixel data.</summary>
    public static string Fingerprint(AstroImage image)
    {
        double sum = 0;
        var d = image.Data;
        for (int i = 0; i < d.Length; i += 97) sum += d[i] * (1 + (i % 7));
        return $"{image.Width}x{image.Height}x{image.Channels}:{sum:R}";
    }
}
