using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;

namespace ClearStar.Core.Astrometry;

/// <summary>A catalogue star: ICRS position in degrees and Gaia G / BP / RP magnitudes (NaN when missing).</summary>
public readonly record struct CatalogStar(double Ra, double Dec, float G, float Bp, float Rp)
{
    public float BpRp => Bp - Rp;
}

/// <summary>Source of catalogue stars for plate solving and colour calibration.</summary>
public interface IStarCatalog
{
    string Name { get; }
    /// <summary>Stars within <paramref name="radiusDeg"/> of the centre, brightest first.</summary>
    Task<List<CatalogStar>> ConeAsync(double ra, double dec, double radiusDeg, float magLimit, int maxStars, CancellationToken ct);
}

/// <summary>
/// Gaia DR3 (VizieR I/355) cone search over HTTP. Responses are cached on disk so a field that was
/// solved once can be solved again without network access.
/// </summary>
public sealed class VizierGaiaCatalog : IStarCatalog
{
    public const string BaseUrl = "https://vizier.cds.unistra.fr/viz-bin/asu-tsv";
    public string Name => "Gaia DR3 (VizieR)";

    public static string CacheDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClearStar", "catalog-cache");

    public async Task<List<CatalogStar>> ConeAsync(double ra, double dec, double radiusDeg, float magLimit, int maxStars, CancellationToken ct)
    {
        string query = string.Format(CultureInfo.InvariantCulture,
            "-source=I/355/gaiadr3&-c={0:0.00000} {1:+0.00000;-0.00000}&-c.rd={2:0.000}&-c.eq=J2000&-out=RA_ICRS,DE_ICRS,Gmag,BPmag,RPmag&Gmag=<{3:0.0}&-out.max={4}&-sort=Gmag",
            ra, dec, radiusDeg, magLimit, maxStars);
        string cacheFile = Path.Combine(CacheDir, Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(query)))[..24] + ".tsv");
        if (File.Exists(cacheFile)) return ParseTsv(await File.ReadAllTextAsync(cacheFile, ct));

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ClearStar/0.1 (astrophoto processing; plate solving)");
        string tsv = await http.GetStringAsync(BaseUrl + "?" + query.Replace(" ", "%20").Replace("<", "%3C").Replace("+", "%2B"), ct);
        var stars = ParseTsv(tsv);
        if (stars.Count > 0)
        {
            Directory.CreateDirectory(CacheDir);
            await File.WriteAllTextAsync(cacheFile, tsv, ct);
        }
        return stars;
    }

    /// <summary>VizieR TSV: '#' comments, a column-name line, a units line, a dashes line, then tab-separated rows.</summary>
    public static List<CatalogStar> ParseTsv(string tsv)
    {
        var result = new List<CatalogStar>();
        bool inData = false;
        foreach (var raw in tsv.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0 || line[0] == '#') continue;
            if (!inData) { if (line.StartsWith("---")) inData = true; continue; }
            var f = line.Split('\t');
            if (f.Length < 3) continue;
            if (!double.TryParse(f[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var ra)) continue;
            if (!double.TryParse(f[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var dec)) continue;
            result.Add(new CatalogStar(ra, dec, Mag(f, 2), Mag(f, 3), Mag(f, 4)));
        }
        return result;
    }

    internal static float Mag(string[] f, int i) =>
        i < f.Length && float.TryParse(f[i].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : float.NaN;
}

/// <summary>
/// Gaia DR3 cone search on the ESA Gaia archive (TAP/ADQL, typically 1–3 s), falling back to VizieR
/// (correct but ~40 s per cone). Results are cached on disk by query.
/// </summary>
public sealed class GaiaOnlineCatalog : IStarCatalog
{
    public const string TapUrl = "https://gea.esac.esa.int/tap-server/tap/sync";
    public string Name => "Gaia DR3";
    private readonly VizierGaiaCatalog _fallback = new();

    public async Task<List<CatalogStar>> ConeAsync(double ra, double dec, double radiusDeg, float magLimit, int maxStars, CancellationToken ct)
    {
        string adql = string.Format(CultureInfo.InvariantCulture,
            "SELECT TOP {4} ra,dec,phot_g_mean_mag,phot_bp_mean_mag,phot_rp_mean_mag FROM gaiadr3.gaia_source WHERE 1=CONTAINS(POINT(ra,dec),CIRCLE({0:0.00000},{1:0.00000},{2:0.000})) AND phot_g_mean_mag<{3:0.0} ORDER BY phot_g_mean_mag",
            ra, dec, radiusDeg, magLimit, maxStars);
        string cacheFile = Path.Combine(VizierGaiaCatalog.CacheDir, Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(adql)))[..24] + ".csv");
        if (File.Exists(cacheFile)) return ParseCsv(await File.ReadAllTextAsync(cacheFile, ct));
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("ClearStar/0.1 (astrophoto processing; plate solving)");
            var form = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["REQUEST"] = "doQuery", ["LANG"] = "ADQL", ["FORMAT"] = "csv",
                ["MAXREC"] = maxStars.ToString(CultureInfo.InvariantCulture), ["QUERY"] = adql,
            });
            using var response = await http.PostAsync(TapUrl, form, ct);
            response.EnsureSuccessStatusCode();
            string csv = await response.Content.ReadAsStringAsync(ct);
            var stars = ParseCsv(csv);
            if (stars.Count == 0) throw new HttpRequestException("empty answer");
            Directory.CreateDirectory(VizierGaiaCatalog.CacheDir);
            await File.WriteAllTextAsync(cacheFile, csv, ct);
            return stars;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            return await _fallback.ConeAsync(ra, dec, radiusDeg, magLimit, maxStars, ct);
        }
    }

    /// <summary>TAP csv: header line, then ra,dec,g,bp,rp rows (empty fields when a magnitude is missing).</summary>
    public static List<CatalogStar> ParseCsv(string csv)
    {
        var result = new List<CatalogStar>();
        bool first = true;
        foreach (var raw in csv.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0) continue;
            if (first) { first = false; continue; }
            var f = line.Split(',');
            if (f.Length < 3) continue;
            if (!double.TryParse(f[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var ra)) continue;
            if (!double.TryParse(f[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var dec)) continue;
            result.Add(new CatalogStar(ra, dec, VizierGaiaCatalog.Mag(f, 2), VizierGaiaCatalog.Mag(f, 3), VizierGaiaCatalog.Mag(f, 4)));
        }
        return result;
    }
}

/// <summary>Object name → ICRS position via the CDS Sesame service (Simbad, NED, VizieR).</summary>
public static class NameResolver
{
    public const string BaseUrl = "https://cds.unistra.fr/cgi-bin/nph-sesame/-op/SNV?";

    public static async Task<(double ra, double dec)?> ResolveAsync(string name, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ClearStar/0.1");
        string text = await http.GetStringAsync(BaseUrl + Uri.EscapeDataString(name.Trim()), ct);
        return Parse(text);
    }

    /// <summary>Finds the "%J ra dec" line of a Sesame plain-text answer.</summary>
    public static (double ra, double dec)? Parse(string text)
    {
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith("%J ")) continue;
            var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (f.Length >= 3 && double.TryParse(f[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var ra)
                              && double.TryParse(f[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var dec))
                return (ra, dec);
        }
        return null;
    }
}
