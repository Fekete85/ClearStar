using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Step 10: generalised hyperbolic stretch of the (starless) image with Siril's GHS controls.
/// The step works like Siril's dialog: the sliders describe the next stretch, previewed live by the
/// app; "Apply" commits it to a history of stretches (hidden parameter) and resets the sliders, so
/// several gentle stretches can be layered. Running the step replays the whole history on the input.
/// </summary>
public sealed class StarlessStretchStep : StepBase
{
    public const string TypeKey = "type";
    public const string LnDKey = "lnD";
    public const string BKey = "b";
    public const string SpKey = "sp";
    public const string LpKey = "lp";
    public const string HpKey = "hp";
    public const string BpKey = "bp";
    public const string ColourKey = "colour";
    public const string HistoryKey = "history";
    private const string S = "ghs";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.StarlessStretch, StepGroup.Stars, S,
        [
            new(LnDKey, L.T("step.ghs.lnD.label"), ParameterKind.Slider, 0.0, 0, 10, L.A("step.ghs.lnD.ticks"), Help: L.T("step.ghs.lnD.help"), ValueFormat: "{0:0.00}"),
            new(BKey, L.T("step.ghs.b.label"), ParameterKind.Slider, 0.0, -5, 15, L.A("step.ghs.b.ticks"), Help: L.T("step.ghs.b.help"), ValueFormat: "{0:0.0}"),
            new(SpKey, L.T("step.ghs.sp.label"), ParameterKind.Slider, 0.0, 0, 1, L.A("step.ghs.sp.ticks"), Help: L.T("step.ghs.sp.help"), ValueFormat: "{0:0.000}"),
            new(LpKey, L.T("step.ghs.lp.label"), ParameterKind.Slider, 0.0, 0, 1, L.A("step.ghs.lp.ticks"), Help: L.T("step.ghs.lp.help"), ValueFormat: "{0:0.000}"),
            new(HpKey, L.T("step.ghs.hp.label"), ParameterKind.Slider, 1.0, 0, 1, L.A("step.ghs.hp.ticks"), Help: L.T("step.ghs.hp.help"), ValueFormat: "{0:0.000}"),
            Choice(S, TypeKey, "ghs", ["ghs", "invghs", "asinh", "invasinh", "linear"], advanced: true),
            new(BpKey, L.T("step.ghs.bp.label"), ParameterKind.Slider, 0.0, 0, 1, L.A("step.ghs.bp.ticks"), Advanced: true, Help: L.T("step.ghs.bp.help"), ValueFormat: "{0:0.000}"),
            Choice(S, ColourKey, "humanlum", ["indep", "humanlum", "evenlum"], advanced: true),
            Hidden(HistoryKey, "[]"),
        ]);

    /// <summary>The stretch described by the sliders (not yet committed).</summary>
    public static GhsParams Current(StepParameters p)
    {
        var type = p.GetString(TypeKey, "ghs") switch
        {
            "invghs" => GhsType.InverseGhs, "asinh" => GhsType.Asinh, "invasinh" => GhsType.InverseAsinh, "linear" => GhsType.Linear, _ => GhsType.Ghs,
        };
        var colour = p.GetString(ColourKey, "humanlum") switch { "indep" => GhsColourModel.Independent, "evenlum" => GhsColourModel.EvenLuminance, _ => GhsColourModel.HumanLuminance };
        float sp = Math.Clamp(p.GetFloat(SpKey), 0f, 1f);
        float lp = Math.Min(Math.Clamp(p.GetFloat(LpKey), 0f, 1f), sp);
        float hp = Math.Max(Math.Clamp(p.GetFloat(HpKey, 1f), 0f, 1f), sp);
        return new GhsParams(type, GhsParams.DFromLog(p.GetDouble(LnDKey)), p.GetFloat(BKey), lp, sp, hp, Math.Clamp(p.GetFloat(BpKey), 0f, 0.999f), colour);
    }

    public static List<GhsParams> History(StepParameters p) => GhsParams.ListFromJson(p.GetString(HistoryKey, "[]"));

    /// <summary>Moves the current stretch into the history and resets the sliders to the identity. Returns false when there was nothing to commit.</summary>
    public static bool Commit(StepParameters p)
    {
        var current = Current(p);
        if (current.IsIdentity) return false;
        var history = History(p);
        history.Add(current);
        p[HistoryKey] = GhsParams.ListToJson(history);
        ResetCurrent(p);
        return true;
    }

    /// <summary>Removes the last committed stretch. Returns false when the history was empty.</summary>
    public static bool Undo(StepParameters p)
    {
        var history = History(p);
        if (history.Count == 0) return false;
        history.RemoveAt(history.Count - 1);
        p[HistoryKey] = GhsParams.ListToJson(history);
        return true;
    }

    public static void ResetCurrent(StepParameters p)
    {
        p[LnDKey] = 0.0; p[BpKey] = 0.0;
    }

    /// <summary>
    /// "Magic wand": commits a classic auto-stretch (MTF with the shadows clipped at median − 2.8σ and the
    /// background put at <paramref name="targetBackground"/>) into the history, so the GHS sliders can then
    /// refine it – the same "autostretch, then fine-tune" habit as in Siril. Returns false when the image
    /// is already bright.
    /// </summary>
    public static bool CommitAuto(StepParameters p, AstroImage image, float targetBackground = 0.25f)
    {
        var stats = ImageStats.ComputeAll(image);
        float median = stats.Average(s => s.Median), sigma = stats.Average(s => s.Sigma);
        if (median >= targetBackground) return false;
        float shadows = Math.Clamp(median - 2.8f * sigma, 0f, 0.99f);
        float x0 = Math.Clamp((median - shadows) / (1f - shadows), 1e-6f, 1f);
        float midtones = Math.Clamp(DisplayStretch.Mtf(x0, targetBackground), 1e-4f, 1f - 1e-4f);
        var history = History(p);
        history.Add(new GhsParams(GhsType.Mtf, midtones, 0f, 0f, shadows, 1f, 0f, GhsColourModel.HumanLuminance));
        p[HistoryKey] = GhsParams.ListToJson(history);
        ResetCurrent(p);
        return true;
    }

    /// <summary>Median of a normalised rectangle of the image (all channels) – the "eyedropper" for the symmetry point.</summary>
    public static float RegionMedian(AstroImage image, double x, double y, double w, double h)
    {
        int x0 = Math.Clamp((int)(x * image.Width), 0, image.Width - 1), y0 = Math.Clamp((int)(y * image.Height), 0, image.Height - 1);
        int x1 = Math.Clamp((int)((x + w) * image.Width), x0 + 1, image.Width), y1 = Math.Clamp((int)((y + h) * image.Height), y0 + 1, image.Height);
        var values = new List<float>();
        for (int c = 0; c < image.Channels; c++)
            for (int yy = y0; yy < y1; yy++)
                for (int xx = x0; xx < x1; xx++) values.Add(image[c, xx, yy]);
        return values.Count == 0 ? 0f : ImageStats.Median(values.ToArray());
    }

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        var history = History(context.Parameters);
        var output = history.Count == 0 ? input.Clone() : GhsTransform.ApplyAll(input, history, context.CancellationToken);
        // With a separated star layer the stretched starless image is kept for the recombination.
        if (StarLayerStore.HasStarsFor(input)) StarLayerStore.SetStarlessStretched(output);
        string summary = history.Count == 0 ? L.T("msg.ghs.none") : L.F("msg.ghs.summary", history.Count, history[^1].Describe());
        return new StepResult(output, summary);
    }, context.CancellationToken);
}

/// <summary>11. lépés: a csillagok (vagy csillagleválasztás nélkül a teljes kép) visszafogott nyújtása MTF-fel.</summary>
public sealed class StarStretchStep : StepBase
{
    public const string AmountKey = "amount";

    private const string S = "starstretch";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.StarStretch, StepGroup.Stars, S,
        [Slider(S, AmountKey, 0.4)]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        float amount = context.Parameters.GetFloat(AmountKey, 0.4f);

        // Two-layer workflow: stretch the separated (linear) star layer on its own and show it screened
        // over the stretched starless image; the recombination step sets the final balance.
        if (StarLayerStore.HasStretchedFor(input) && StarLayerStore.StarsLinear is { } starsLinear)
        {
            var stretchedStars = StretchStarLayer(starsLinear, amount, context.CancellationToken);
            StarLayerStore.SetStarsStretched(stretchedStars);
            var preview = RecombineStep.Screen(input, stretchedStars, 1f, context.CancellationToken);
            return new StepResult(preview, L.T("msg.starstretch.layerSummary"));
        }

        var stats = ImageStats.ComputeAll(input);
        if (stats.Average(s => s.Median) > 0.08f)
            return StepResult.Unchanged(input, L.T("msg.starstretch.already"));

        float target = Lerp(0.08f, 0.25f, context.Parameters.GetFloat(AmountKey, 0.4f));
        var prms = DisplayStretch.ComputeAll(input, linked: true, targetBackground: target);
        var output = MapPixels(input, (v, c) => prms[c].Apply(v), context.CancellationToken);
        output.Clamp01();
        return new StepResult(output, L.F("msg.starstretch.summary", target));
    }, context.CancellationToken);

    /// <summary>MTF stretch of a star layer (black background): the amount sets the midtones, so the stars gain size and colour gently.</summary>
    public static AstroImage StretchStarLayer(AstroImage stars, float amount, CancellationToken ct)
    {
        float m = Lerp(0.15f, 0.02f, Math.Clamp(amount, 0f, 1f));
        var output = MapPixels(stars, (v, _) => DisplayStretch.Mtf(Math.Clamp(v, 0f, 1f), m), ct);
        return output;
    }
}
