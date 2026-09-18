using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>Step 12: green cast removal (SCNR, "average neutral" method).</summary>
public sealed class GreenRemovalStep : StepBase, ILivePreviewStep
{
    public const string AmountKey = "amount";

    private const string S = "green";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.GreenRemoval, StepGroup.Refinement, S,
        [Slider(S, AmountKey, 1.0)]);

    public AstroImage Preview(AstroImage image, StepParameters p, CancellationToken ct)
    {
        if (!image.IsColor) return image;
        float amount = p.GetFloat(AmountKey, 1f);
        return MapRgb(image, (r, g, b) =>
        {
            float neutral = 0.5f * (r + b);
            float g2 = g > neutral ? Lerp(g, neutral, amount) : g;
            return (r, g2, b);
        }, ct);
    }

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        if (!input.IsColor) return StepResult.Unchanged(input, L.T("msg.green.mono"));
        return new StepResult(Preview(input, context.Parameters, context.CancellationToken), L.T("msg.green.summary"));
    }, context.CancellationToken);
}

/// <summary>
/// Step 13: purple / violet fringing around bright stars (lateral chromatic aberration of the optics).
/// Pixels whose hue lies in the violet–magenta range, are saturated and bright enough are desaturated
/// towards their own luminance, so the fringe melts into the star's white halo while genuinely blue
/// stars (hue nearer cyan) and the dimmer nebulosity are left alone. Inspired by Siril's unpurple filter.
/// </summary>
public sealed class FringeStep : StepBase, ILivePreviewStep
{
    public const string AmountKey = "amount";
    public const string ThresholdKey = "threshold";
    public const string HueWidthKey = "hue";

    private const string S = "fringe";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.ChromaticAberration, StepGroup.Refinement, S,
        [
            Slider(S, AmountKey, 0.7),
            Slider(S, ThresholdKey, 0.3, 0, 0.8, advanced: true),
            Slider(S, HueWidthKey, 0.5, 0, 1, advanced: true),
        ]);

    public AstroImage Preview(AstroImage image, StepParameters p, CancellationToken ct)
    {
        if (!image.IsColor) return image;
        float amount = p.GetFloat(AmountKey, 0.7f);
        float threshold = p.GetFloat(ThresholdKey, 0.3f);
        // Hue window: violet (≈0.72) up to magenta (≈0.92); the width slider widens it towards pure blue / red.
        float width = p.GetFloat(HueWidthKey, 0.5f);
        float hueLo = 0.72f - 0.08f * width, hueHi = 0.92f + 0.06f * width;
        return MapRgb(image, (r, g, b) =>
        {
            float max = MathF.Max(r, MathF.Max(g, b)), min = MathF.Min(r, MathF.Min(g, b));
            float delta = max - min;
            if (delta <= 1e-6f) return (r, g, b);
            float sat = delta / MathF.Max(max, 1e-6f);
            float hue = max == r ? ((g - b) / delta + 6f) % 6f / 6f : max == g ? ((b - r) / delta + 2f) / 6f : ((r - g) / delta + 4f) / 6f;
            float lum = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            float w = amount * Window(hue, hueLo, hueHi, 0.04f) * SmoothStep(0.12f, 0.35f, sat) * SmoothStep(threshold - 0.1f, threshold + 0.1f, lum);
            if (w <= 0f) return (r, g, b);
            return (Lerp(r, lum, w), Lerp(g, lum, w), Lerp(b, lum, w));
        }, ct);
    }

    /// <summary>1 inside [lo, hi], fading to 0 over <paramref name="edge"/> outside it.</summary>
    private static float Window(float x, float lo, float hi, float edge) =>
        SmoothStep(lo - edge, lo, x) * (1f - SmoothStep(hi, hi + edge, x));

    private static float SmoothStep(float a, float b, float x)
    {
        float t = Math.Clamp((x - a) / (b - a), 0f, 1f);
        return t * t * (3f - 2f * t);
    }

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        if (!input.IsColor) return StepResult.Unchanged(input, L.T("msg.fringe.mono"));
        var output = Preview(input, context.Parameters, context.CancellationToken);
        // How much of the image was touched, for the summary.
        long changed = 0;
        var a = input.Data; var o = output.Data; int n = input.PixelsPerChannel;
        for (int i = 0; i < n; i++) if (a[i] != o[i] || a[n + i] != o[n + i] || a[2 * n + i] != o[2 * n + i]) changed++;
        return new StepResult(output, L.F("msg.fringe.summary", changed / (double)n));
    }, context.CancellationToken);
}

/// <summary>Step 14: contrast – an S-curve strengthening the midtones, with an optional black-point lift.</summary>
public sealed class ContrastStep : StepBase, ILivePreviewStep
{
    public const string AmountKey = "amount";
    public const string BlackPointKey = "black";

    private const string S = "contrast";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Contrast, StepGroup.Refinement, S,
        [
            Slider(S, AmountKey, 0.3),
            Slider(S, BlackPointKey, 0.0, 0, 0.15, advanced: true),
        ]);

    public AstroImage Preview(AstroImage image, StepParameters p, CancellationToken ct)
    {
        float amount = p.GetFloat(AmountKey, 0.3f);
        float black = p.GetFloat(BlackPointKey, 0f);
        return MapPixels(image, (v, _) =>
        {
            float x = black > 0 ? (v - black) / (1f - black) : v;
            x = Math.Clamp(x, 0f, 1f);
            float s = x * x * (3f - 2f * x);
            return Lerp(x, s, amount);
        }, ct);
    }

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
        new StepResult(Preview(context.RequireInput(), context.Parameters, context.CancellationToken), L.T("msg.contrast.summary")),
        context.CancellationToken);
}

/// <summary>Step 15: colour saturation with the luminance kept.</summary>
public sealed class SaturationStep : StepBase, ILivePreviewStep
{
    public const string AmountKey = "amount";

    private const string S = "saturation";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Saturation, StepGroup.Refinement, S,
        [Slider(S, AmountKey, 0.25)]);

    public AstroImage Preview(AstroImage image, StepParameters p, CancellationToken ct)
    {
        if (!image.IsColor) return image;
        float gain = 1f + 1.5f * p.GetFloat(AmountKey, 0.25f);
        return MapRgb(image, (r, g, b) =>
        {
            float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            return (Math.Clamp(l + (r - l) * gain, 0f, 1f), Math.Clamp(l + (g - l) * gain, 0f, 1f), Math.Clamp(l + (b - l) * gain, 0f, 1f));
        }, ct);
    }

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        if (!input.IsColor) return StepResult.Unchanged(input, L.T("msg.saturation.mono"));
        return new StepResult(Preview(input, context.Parameters, context.CancellationToken), L.T("msg.saturation.summary"));
    }, context.CancellationToken);
}
