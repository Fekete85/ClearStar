using System.Globalization;
using System.Net.Http;
using ClearStar.Core.Astrometry;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Step 7: plate solving. The approximate centre comes from the FITS header (RA/DEC written by the
/// telescope), or from an object name resolved online; the pixel scale from FOCALLEN/XPIXSZ or the
/// user. Catalogue stars (Gaia DR3 via VizieR, cached on disk) are matched to the image and the
/// resulting TAN WCS is written into the image header for the colour calibration step.
/// </summary>
public sealed class PlateSolveStep : StepBase
{
    public const string ObjectKey = "object";
    public const string ScaleKey = "scale";
    public const string MagLimitKey = "maglimit";
    private const string S = "platesolve";

    /// <summary>The most recent successful solve (for overlays and the colour calibration).</summary>
    public static PlateSolveResult? LastResult { get; private set; }

    /// <summary>The catalogue cone used by the most recent solve (centre, radius, stars) – reused by the colour calibration.</summary>
    public static (double ra, double dec, double radius, float magLimit, List<CatalogStar> stars)? LastCatalog { get; private set; }

    /// <summary>Catalogue stars around a position, from the last solve's cone when it covers it, otherwise a fresh (cached) query.</summary>
    public static async Task<List<CatalogStar>> CatalogAroundAsync(double ra, double dec, double radius, float magLimit, CancellationToken ct)
    {
        if (LastCatalog is { } c && c.magLimit >= magLimit)
        {
            var d = Wcs.Project(ra, dec, c.ra, c.dec);
            if (d is not null && Math.Sqrt(d.Value.xi * d.Value.xi + d.Value.eta * d.Value.eta) + radius <= c.radius + 1e-6) return c.stars;
        }
        var stars = await Catalog.ConeAsync(ra, dec, radius, magLimit, 4000, ct);
        LastCatalog = (ra, dec, radius, magLimit, stars);
        return stars;
    }

    public static IStarCatalog Catalog { get; set; } = new AutoStarCatalog();

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.PlateSolve, StepGroup.Basics, S,
        [
            Text(S, ObjectKey),
            new(ScaleKey, L.T("step.platesolve.scale.label"), ParameterKind.Text, "", Advanced: true, Help: L.T("step.platesolve.scale.help")),
            Slider(S, MagLimitKey, 14.0, 11, 16, advanced: true),
        ]);

    public override async Task<StepResult> RunAsync(WorkflowContext context)
    {
        var input = context.RequireInput();
        var p = context.Parameters;
        var ct = context.CancellationToken;
        var header = input.Header;

        // 1. Centre hint: object name typed by the user → online resolver; otherwise the header.
        string objectName = p.GetString(ObjectKey).Trim();
        string headerObject = header.TryGetValue("OBJECT", out var ho) ? ho.Trim() : "";
        // A name the user typed (different from the header's own OBJECT) overrides the header direction.
        bool userOverride = objectName.Length > 0 && !string.Equals(objectName, headerObject, StringComparison.OrdinalIgnoreCase);
        double ra, dec;
        try
        {
            if (userOverride || (objectName.Length > 0 && HeaderCentre(header) is null))
            {
                context.Report(0.02, L.F("msg.platesolve.resolving", objectName));
                var pos = await NameResolver.ResolveAsync(objectName, ct) ?? throw new InvalidOperationException(L.F("msg.platesolve.unknownObject", objectName));
                (ra, dec) = pos;
            }
            else if (HeaderCentre(header) is { } centre) (ra, dec) = centre;
            else if (header.TryGetValue("OBJECT", out var obj) && obj.Trim().Length > 0)
            {
                context.Report(0.02, L.F("msg.platesolve.resolving", obj.Trim()));
                var pos = await NameResolver.ResolveAsync(obj.Trim(), ct) ?? throw new InvalidOperationException(L.T("msg.platesolve.noCentre"));
                (ra, dec) = pos;
            }
            else throw new InvalidOperationException(L.T("msg.platesolve.noCentre"));
        }
        catch (HttpRequestException ex) { throw new InvalidOperationException(L.F("msg.platesolve.offline", ex.Message)); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new InvalidOperationException(L.F("msg.platesolve.offline", "timeout")); }

        // 2. Pixel scale hint.
        double scale = ParseDouble(p.GetString(ScaleKey)) ?? HeaderScale(header) ?? throw new InvalidOperationException(L.T("msg.platesolve.noScale"));

        // 3. Catalogue cone around the centre, generous enough for a wrong hint of ~half a field.
        double fovDiagDeg = Math.Sqrt((double)input.Width * input.Width + (double)input.Height * input.Height) * scale / 3600.0;
        double radius = Math.Clamp(0.5 * fovDiagDeg + 0.3, 0.3, 6.0);
        float magLimit = p.GetFloat(MagLimitKey, 14f);
        context.Report(0.1, L.F("msg.platesolve.catalog", Catalog.Name));
        List<CatalogStar> stars;
        try { stars = await CatalogAroundAsync(ra, dec, radius, magLimit, ct); }
        catch (HttpRequestException ex) { throw new InvalidOperationException(L.F("msg.platesolve.offline", ex.Message)); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new InvalidOperationException(L.F("msg.platesolve.offline", "timeout")); }
        if (stars.Count < 10) throw new InvalidOperationException(L.T("msg.platesolve.fewCatalogStars"));

        // 4. Solve.
        context.Report(0.3, L.T("msg.platesolve.solving"));
        var result = await Task.Run(() => PlateSolver.Solve(input, stars, ra, dec, scale, ct, f => context.Report(0.3 + 0.65 * f, L.T("msg.platesolve.solving"))), ct)
                     ?? throw new InvalidOperationException(L.T("msg.platesolve.failed"));
        LastResult = result;

        var output = input.Clone();
        result.Wcs.WriteTo(output.Header, output.Height);
        output.Header["OBJCTRA"] = Wcs.FormatRa(result.Wcs.Ra);
        output.Header["OBJCTDEC"] = Wcs.FormatDec(result.Wcs.Dec);
        string summary = L.F("msg.platesolve.summary", Wcs.FormatRa(result.Wcs.Ra), Wcs.FormatDec(result.Wcs.Dec),
            result.Wcs.ScaleArcsec, result.Wcs.RotationDegrees, result.MatchedStars, result.RmsArcsec);
        return new StepResult(output, summary);
    }

    /// <summary>RA/DEC in degrees, or OBJCTRA/OBJCTDEC in sexagesimal, from the header.</summary>
    public static (double ra, double dec)? HeaderCentre(IReadOnlyDictionary<string, string> h)
    {
        if (h.TryGetValue("RA", out var r) && h.TryGetValue("DEC", out var d) && ParseDouble(r) is { } ra && ParseDouble(d) is { } dec)
            return (ra, dec);
        if (h.TryGetValue("OBJCTRA", out r) && h.TryGetValue("OBJCTDEC", out d) && Sexagesimal(r, 15.0) is { } ra2 && Sexagesimal(d, 1.0) is { } dec2)
            return (ra2, dec2);
        if (h.TryGetValue("CRVAL1", out r) && h.TryGetValue("CRVAL2", out d) && ParseDouble(r) is { } ra3 && ParseDouble(d) is { } dec3)
            return (ra3, dec3);
        return null;
    }

    /// <summary>Arcseconds per pixel from FOCALLEN (mm) and XPIXSZ (µm), or an existing WCS.</summary>
    public static double? HeaderScale(IReadOnlyDictionary<string, string> h)
    {
        if (h.TryGetValue("FOCALLEN", out var f) && h.TryGetValue("XPIXSZ", out var px)
            && ParseDouble(f) is { } focal && ParseDouble(px) is { } pixel && focal > 0 && pixel > 0)
            return 206.265 * pixel / focal;
        if (h.TryGetValue("CDELT2", out var c) && ParseDouble(c) is { } cdelt && cdelt != 0) return Math.Abs(cdelt) * 3600.0;
        return null;
    }

    private static double? ParseDouble(string? s) =>
        s is not null && double.TryParse(s.Trim().Trim('\''), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    /// <summary>"00 42 44.3" or "+41 16 08" (also with ':' separators) → degrees; hours are scaled by 15.</summary>
    public static double? Sexagesimal(string s, double hourFactor)
    {
        var parts = s.Trim().Trim('\'').Split([' ', ':'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;
        bool negative = parts[0].StartsWith('-');
        double value = 0, factor = 1;
        foreach (var part in parts)
        {
            if (!double.TryParse(part.TrimStart('+', '-'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
            value += v * factor; factor /= 60.0;
        }
        return (negative ? -value : value) * hourFactor;
    }
}
