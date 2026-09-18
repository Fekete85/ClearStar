using System.Buffers.Binary;

namespace ClearStar.Core.Astrometry;

/// <summary>
/// Offline Gaia DR3 catalogue in the Siril HEALPix Catalog Format 1.0.0 (the
/// <c>siril_cat_healpix8_astro.dat</c> file Siril downloads, ~1.5 GB): 128-byte header, a
/// cumulative uint32 record-count index per HEALPix pixel (NESTED, level 8), then 16-byte records
/// (RA/Dec scaled int32, proper motions, T_eff, G magnitude ×1000) sorted by pixel.
/// Colours for the colour calibration are derived from T_eff.
/// </summary>
public sealed class LocalGaiaCatalog : IStarCatalog
{
    public const string PathSettingKey = "catalog.gaiaAstro";
    public const string DefaultFileName = "siril_cat_healpix8_astro.dat";
    private const int HeaderSize = 128, RecordSize = 16;
    private const double RaDecScale = 360.0 / int.MaxValue;

    public string Name => "Gaia DR3 (offline)";
    public string FilePath { get; }
    public int Level { get; }
    private readonly Healpix _healpix;
    private readonly uint[] _index;

    private LocalGaiaCatalog(string path, int level)
    {
        FilePath = path; Level = level;
        _healpix = Healpix.ForOrder(level);
        _index = new uint[_healpix.Npix];
        using var f = File.OpenRead(path);
        f.Seek(HeaderSize, SeekOrigin.Begin);
        var bytes = new byte[_healpix.Npix * 4];
        f.ReadExactly(bytes);
        for (int i = 0; i < _index.Length; i++) _index[i] = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(i * 4));
    }

    /// <summary>Opens a catalogue file after validating its header; null when it is not a monolithic astro catalogue.</summary>
    public static LocalGaiaCatalog? Open(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var f = File.OpenRead(path);
            var header = new byte[HeaderSize];
            if (f.Read(header, 0, HeaderSize) < HeaderSize) return null;
            int level = header[49], catType = header[50], chunked = header[51];
            if (level < 1 || level > 12 || catType != 1 || chunked != 0) return null;
            long npix = 12L * (1 << level) * (1 << level);
            if (f.Length < HeaderSize + npix * 4) return null;
            return new LocalGaiaCatalog(path, level);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>Candidate file locations: ClearStar setting, Siril's configuration, Siril's and ClearStar's data folders.</summary>
    public static IEnumerable<string> Candidates()
    {
        if (UserSettings.Get(PathSettingKey) is { Length: > 0 } own) yield return own;
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string sirilDir = Path.Combine(local, "siril");
        if (Directory.Exists(sirilDir))
        {
            foreach (var ini in Directory.EnumerateFiles(sirilDir, "config*.ini").OrderByDescending(f => f))
            {
                string? path = null;
                try
                {
                    foreach (var line in File.ReadLines(ini))
                        if (line.StartsWith("catalogue_gaia_astro=", StringComparison.OrdinalIgnoreCase))
                        { path = line["catalogue_gaia_astro=".Length..].Trim().Replace("\\\\", "\\"); break; }
                }
                catch (IOException) { }
                if (!string.IsNullOrEmpty(path)) yield return path;
            }
            yield return Path.Combine(sirilDir, DefaultFileName);
        }
        yield return Path.Combine(local, "ClearStar", "catalogs", DefaultFileName);
    }

    public static string? Locate() => Candidates().FirstOrDefault(p => Open(p) is not null);

    private static LocalGaiaCatalog? _cached;

    /// <summary>The first usable catalogue on this machine (kept open), or null.</summary>
    public static LocalGaiaCatalog? Default()
    {
        if (_cached is not null && File.Exists(_cached.FilePath)) return _cached;
        foreach (var c in Candidates())
        {
            var cat = Open(c);
            if (cat is not null) return _cached = cat;
        }
        return null;
    }

    public Task<List<CatalogStar>> ConeAsync(double ra, double dec, double radiusDeg, float magLimit, int maxStars, CancellationToken ct) =>
        Task.Run(() => Cone(ra, dec, radiusDeg, magLimit, maxStars, ct), ct);

    public List<CatalogStar> Cone(double ra, double dec, double radiusDeg, float magLimit, int maxStars, CancellationToken ct = default)
    {
        var pixels = _healpix.QueryDiscInclusive(ra, dec, radiusDeg);
        var result = new List<CatalogStar>();
        long dataStart = HeaderSize + (long)_index.Length * 4;
        short magScaledLimit = (short)Math.Min(short.MaxValue, Math.Round(magLimit * 1000));
        double cosRadius = Math.Cos(radiusDeg * Math.PI / 180);
        double ra0 = ra * Math.PI / 180, dec0 = dec * Math.PI / 180;
        double cx = Math.Cos(dec0) * Math.Cos(ra0), cy = Math.Cos(dec0) * Math.Sin(ra0), cz = Math.Sin(dec0);

        using var f = File.OpenRead(FilePath);
        int i = 0;
        while (i < pixels.Count)
        {
            ct.ThrowIfCancellationRequested();
            // Merge runs of consecutive pixels into one read.
            int j = i;
            while (j + 1 < pixels.Count && pixels[j + 1] == pixels[j] + 1) j++;
            uint first = pixels[i] == 0 ? 0 : _index[pixels[i] - 1], last = _index[pixels[j]];
            if (last > first)
            {
                long count = last - first;
                var buffer = new byte[count * RecordSize];
                f.Seek(dataStart + (long)first * RecordSize, SeekOrigin.Begin);
                f.ReadExactly(buffer);
                for (long r = 0; r < count; r++)
                {
                    var rec = buffer.AsSpan((int)(r * RecordSize), RecordSize);
                    short magScaled = BinaryPrimitives.ReadInt16LittleEndian(rec[14..]);
                    if (magScaled > magScaledLimit) continue;
                    double sra = BinaryPrimitives.ReadInt32LittleEndian(rec) * RaDecScale;
                    double sdec = BinaryPrimitives.ReadInt32LittleEndian(rec[4..]) * RaDecScale;
                    double dr = sra * Math.PI / 180, dd = sdec * Math.PI / 180;
                    double dot = Math.Cos(dd) * Math.Cos(dr) * cx + Math.Cos(dd) * Math.Sin(dr) * cy + Math.Sin(dd) * cz;
                    if (dot < cosRadius) continue;
                    ushort teff = BinaryPrimitives.ReadUInt16LittleEndian(rec[12..]);
                    float g = magScaled / 1000f;
                    float colour = teff > 0 ? BpRpFromTeff(teff) : float.NaN;
                    result.Add(new CatalogStar(sra, sdec, g, float.IsNaN(colour) ? float.NaN : g + colour / 2, float.IsNaN(colour) ? float.NaN : g - colour / 2));
                }
            }
            i = j + 1;
        }
        result.Sort((a, b) => a.G.CompareTo(b.G));
        if (result.Count > maxStars) result.RemoveRange(maxStars, result.Count - maxStars);
        return result;
    }

    // Approximate dwarf-star relation between Gaia BP−RP and effective temperature (Pecaut & Mamajek style table).
    private static readonly (float bpRp, float teff)[] ColourTable =
    [
        (-0.30f, 20000f), (-0.20f, 15000f), (-0.10f, 12000f), (0.00f, 9700f), (0.20f, 8000f), (0.40f, 7200f),
        (0.60f, 6450f), (0.82f, 5770f), (1.00f, 5270f), (1.20f, 4900f), (1.40f, 4450f), (1.60f, 4250f),
        (1.84f, 3850f), (2.20f, 3550f), (2.60f, 3350f), (3.00f, 3200f), (3.50f, 3000f),
    ];

    /// <summary>BP−RP colour for an effective temperature by interpolating the table (clamped at the ends).</summary>
    public static float BpRpFromTeff(float teff)
    {
        if (teff >= ColourTable[0].teff) return ColourTable[0].bpRp;
        for (int k = 1; k < ColourTable.Length; k++)
        {
            if (teff >= ColourTable[k].teff)
            {
                var (c0, t0) = ColourTable[k - 1]; var (c1, t1) = ColourTable[k];
                return c0 + (c1 - c0) * (t0 - teff) / (t0 - t1);
            }
        }
        return ColourTable[^1].bpRp;
    }
}
