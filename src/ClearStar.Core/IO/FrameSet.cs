namespace ClearStar.Core.IO;

public enum FrameType { Light, Dark, Flat, Bias, Unknown }

public sealed record FrameInfo(string Path, FrameType Type, double ExposureSeconds, int Width, int Height, string? Filter)
{
    public string FileName => System.IO.Path.GetFileName(Path);
}

/// <summary>Egy mappa képei típusonként szétválogatva.</summary>
public sealed class FrameSet
{
    public string Folder { get; }
    public IReadOnlyList<FrameInfo> Frames { get; }

    public FrameSet(string folder, IReadOnlyList<FrameInfo> frames)
    {
        Folder = folder;
        Frames = frames;
    }

    public IEnumerable<FrameInfo> Lights => Frames.Where(f => f.Type == FrameType.Light);
    public IEnumerable<FrameInfo> Darks => Frames.Where(f => f.Type == FrameType.Dark);
    public IEnumerable<FrameInfo> Flats => Frames.Where(f => f.Type == FrameType.Flat);
    public IEnumerable<FrameInfo> Biases => Frames.Where(f => f.Type == FrameType.Bias);

    public int Count(FrameType type) => Frames.Count(f => f.Type == type);

    public double TotalLightExposure => Lights.Sum(f => f.ExposureSeconds);

    private static readonly string[] FrameFolders = ["lights", "light", "darks", "dark", "flats", "flat", "bias", "biases", "offset"];

    /// <summary>
    /// Mappa beolvasása: FITS-nél a fejléc IMAGETYP kulcsa dönt, egyébként a fájlnév/almappa neve.
    /// Csak a mappa és a képtípus nevű almappák (lights, darks, flats, bias) számítanak – más
    /// programok munkamappái (pl. a Siril process/ mappája) nem, mert azok közbenső fájlokat tartalmaznak.
    /// </summary>
    public static FrameSet Scan(string folder, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        var roots = Directory.EnumerateDirectories(folder)
            .Where(d => FrameFolders.Contains(Path.GetFileName(d), StringComparer.OrdinalIgnoreCase))
            .ToList();
        // Ha vannak képtípus-almappák, csak azok számítanak (a gyökérben lévő kész eredmények nem).
        if (roots.Count == 0) roots.Add(folder);
        var files = roots
            .SelectMany(r => Directory.EnumerateFiles(r, "*.*", SearchOption.TopDirectoryOnly))
            .Where(ImageFiles.IsSupported)
            .OrderBy(f => f, StringComparer.OrdinalIgnoreCase)
            .ToList();
        var frames = new List<FrameInfo>(files.Count);
        for (int i = 0; i < files.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            frames.Add(Inspect(files[i], folder));
            progress?.Report((i + 1) / (double)files.Count);
        }
        return new FrameSet(folder, frames);
    }

    public static FrameInfo Inspect(string path, string? rootFolder = null)
    {
        FrameType type = FrameType.Unknown;
        double exposure = 0;
        int w = 0, h = 0;
        string? filter = null;

        if (FitsReader.IsFits(path))
        {
            try
            {
                var header = FitsReader.ReadHeader(path);
                if (header.TryGetValue("IMAGETYP", out var t)) type = ParseType(t);
                if (header.TryGetValue("EXPTIME", out var e) || header.TryGetValue("EXPOSURE", out e))
                    double.TryParse(e, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out exposure);
                if (header.TryGetValue("NAXIS1", out var n1)) int.TryParse(n1, out w);
                if (header.TryGetValue("NAXIS2", out var n2)) int.TryParse(n2, out h);
                if (header.TryGetValue("FILTER", out var f)) filter = f;
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException)
            {
                // Sérült fejléc: a fájlnév alapján próbálkozunk tovább.
            }
        }

        if (type == FrameType.Unknown)
        {
            string relative = rootFolder is null ? Path.GetFileName(path) : Path.GetRelativePath(rootFolder, path);
            type = ParseType(relative);
            // Ha semmi nem utal a típusra, fényképnek vesszük – ez a leggyakoribb eset egy kezdőnél.
            if (type == FrameType.Unknown) type = FrameType.Light;
        }
        return new FrameInfo(path, type, exposure, w, h, filter);
    }

    private static FrameType ParseType(string text)
    {
        string s = text.ToLowerInvariant();
        if (s.Contains("bias") || s.Contains("offset")) return FrameType.Bias;
        if (s.Contains("dark")) return FrameType.Dark;
        if (s.Contains("flat")) return FrameType.Flat;
        if (s.Contains("light") || s.Contains("object") || s.Contains("science")) return FrameType.Light;
        return FrameType.Unknown;
    }
}
