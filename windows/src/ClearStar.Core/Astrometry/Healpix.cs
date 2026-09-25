namespace ClearStar.Core.Astrometry;

/// <summary>
/// Minimal HEALPix (NESTED scheme) support: pixel centres for a given order and cone queries by
/// pixel centre distance. Enough to read Siril's HEALPix-ordered catalogue files.
/// </summary>
public sealed class Healpix
{
    private static readonly int[] Jrll = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4];
    private static readonly int[] Jpll = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7];

    public int Order { get; }
    public int Nside { get; }
    public int Npix { get; }
    /// <summary>Unit vectors of every pixel centre (x, y, z interleaved).</summary>
    private readonly float[] _centres;
    /// <summary>Angular radius (rad) that certainly contains a whole pixel around its centre.</summary>
    public double PixelRadius { get; }

    private static readonly Dictionary<int, Healpix> Cache = new();

    public static Healpix ForOrder(int order)
    {
        lock (Cache)
        {
            if (!Cache.TryGetValue(order, out var h)) Cache[order] = h = new Healpix(order);
            return h;
        }
    }

    private Healpix(int order)
    {
        Order = order; Nside = 1 << order; Npix = 12 * Nside * Nside;
        _centres = new float[Npix * 3];
        Parallel.For(0, Npix, p =>
        {
            var (z, phi) = PixToZPhi(p);
            double s = Math.Sqrt(Math.Max(0, 1 - z * z));
            _centres[p * 3] = (float)(s * Math.Cos(phi));
            _centres[p * 3 + 1] = (float)(s * Math.Sin(phi));
            _centres[p * 3 + 2] = (float)z;
        });
        // A pixel's farthest corner is at most ~1.362·(pixel "side") from its centre; use a safe bound.
        PixelRadius = 1.362 * Math.Sqrt(4 * Math.PI / Npix);
    }

    /// <summary>(z = cos θ, φ) of a NESTED pixel centre (from the HEALPix reference implementation).</summary>
    public (double z, double phi) PixToZPhi(long pix)
    {
        long npface = (long)Nside * Nside;
        int face = (int)(pix / npface);
        long ipf = pix & (npface - 1);
        long ix = CompressBits(ipf), iy = CompressBits(ipf >> 1);
        long nl4 = 4L * Nside;
        double fact2 = 4.0 / Npix;
        long jr = Jrll[face] * (long)Nside - ix - iy - 1;
        long nr, kshift; double z;
        if (jr < Nside) { nr = jr; z = 1 - nr * nr * fact2; kshift = 0; }
        else if (jr > 3L * Nside) { nr = nl4 - jr; z = nr * nr * fact2 - 1; kshift = 0; }
        else { double fact1 = (Nside << 1) * fact2; nr = Nside; z = (2L * Nside - jr) * fact1; kshift = (jr - Nside) & 1; }
        long jp = (Jpll[face] * nr + ix - iy + 1 + kshift) / 2;
        if (jp > nl4) jp -= nl4;
        if (jp < 1) jp += nl4;
        double phi = (jp - (kshift + 1) * 0.5) * (Math.PI / 2 / nr);
        return (z, phi);
    }

    private static long CompressBits(long v)
    {
        v &= 0x5555555555555555L;
        v = (v | (v >> 1)) & 0x3333333333333333L;
        v = (v | (v >> 2)) & 0x0f0f0f0f0f0f0f0fL;
        v = (v | (v >> 4)) & 0x00ff00ff00ff00ffL;
        v = (v | (v >> 8)) & 0x0000ffff0000ffffL;
        v = (v | (v >> 16)) & 0x00000000ffffffffL;
        return v;
    }

    /// <summary>Pixels whose area may intersect the cone (inclusive query), in increasing order.</summary>
    public List<int> QueryDiscInclusive(double raDeg, double decDeg, double radiusDeg)
    {
        double ra = raDeg * Math.PI / 180, dec = decDeg * Math.PI / 180;
        double cx = Math.Cos(dec) * Math.Cos(ra), cy = Math.Cos(dec) * Math.Sin(ra), cz = Math.Sin(dec);
        double limit = Math.Cos(Math.Min(Math.PI, radiusDeg * Math.PI / 180 + PixelRadius));
        var result = new List<int>();
        for (int p = 0; p < Npix; p++)
        {
            double dot = _centres[p * 3] * cx + _centres[p * 3 + 1] * cy + _centres[p * 3 + 2] * cz;
            if (dot >= limit) result.Add(p);
        }
        return result;
    }
}
