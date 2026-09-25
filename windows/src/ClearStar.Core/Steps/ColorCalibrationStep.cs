using System.Net.Http;
using ClearStar.Core.Astrometry;
using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Step 8: photometric colour calibration. Needs the WCS written by the plate-solve step: the Gaia
/// stars on the image are measured in R, G and B, and the channels are scaled so that a star of the
/// chosen white reference colour comes out neutral. The background is neutralised at the same time.
/// </summary>
public sealed class ColorCalibrationStep : StepBase
{
    public const string WhiteKey = "white";
    public const string NeutralKey = "neutral";
    public const string WhiteGalaxy = "galaxy";
    public const string WhiteVega = "vega";
    private const string S = "colorcal";

    /// <summary>The most recent calibration (for the UI).</summary>
    public static ColorCalibrationResult? LastResult { get; private set; }

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.ColorCalibration, StepGroup.Basics, S,
        [
            Choice(S, WhiteKey, WhiteGalaxy, [WhiteGalaxy, WhiteVega]),
            Toggle(S, NeutralKey, true, advanced: true),
        ]);

    public override async Task<StepResult> RunAsync(WorkflowContext context)
    {
        var input = context.RequireInput();
        var p = context.Parameters;
        var ct = context.CancellationToken;
        if (!input.IsColor) return StepResult.Unchanged(input, L.T("msg.colorcal.mono"));
        var wcs = Wcs.TryRead(input.Header, input.Height) ?? throw new InvalidOperationException(L.T("msg.colorcal.noWcs"));

        // Catalogue stars over the field (normally the plate solve's own cone, so no network access).
        double fovDiagDeg = Math.Sqrt((double)input.Width * input.Width + (double)input.Height * input.Height) * wcs.ScaleArcsec / 3600.0;
        var centre = wcs.PixelToSky((input.Width - 1) / 2.0, (input.Height - 1) / 2.0);
        context.Report(0.05, L.T("msg.colorcal.catalog"));
        // Measured BP/RP colours (online) include interstellar reddening, which T_eff-derived colours of the
        // offline catalogue do not; so try the online archive briefly first, then fall back to whatever
        // catalogue the plate solve used.
        List<CatalogStar> stars;
        double radius = 0.5 * fovDiagDeg + 0.05;
        try
        {
            var online = new GaiaOnlineCatalog(useVizierFallback: false, timeout: TimeSpan.FromSeconds(10));
            stars = await online.ConeAsync(centre.ra, centre.dec, radius, 14f, 4000, ct);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            try { stars = await PlateSolveStep.CatalogAroundAsync(centre.ra, centre.dec, radius, 14f, ct); }
            catch (HttpRequestException ex2) { throw new InvalidOperationException(L.F("msg.platesolve.offline", ex2.Message)); }
        }

        context.Report(0.2, L.T("msg.colorcal.measuring"));
        var result = await Task.Run(() =>
        {
            float fwhm = PsfMeasure.EstimateFwhm(input, ct);
            var samples = ColorCalibration.Measure(input, wcs, stars, fwhm, ct);
            float white = p.GetString(WhiteKey, WhiteGalaxy) == WhiteVega ? ColorCalibration.VegaBpRp : ColorCalibration.GalaxyBpRp;
            return ColorCalibration.Fit(samples, white);
        }, ct) ?? throw new InvalidOperationException(L.T("msg.colorcal.fewStars"));
        LastResult = result;

        context.Report(0.8, L.T("msg.colorcal.applying"));
        var output = ColorCalibration.Apply(input, result.RedFactor, result.BlueFactor, p.GetBool(NeutralKey, true));
        output.Header["CLRCAL"] = "T";
        return new StepResult(output, L.F("msg.colorcal.summary", result.RedFactor, result.BlueFactor, result.StarsUsed));
    }
}
