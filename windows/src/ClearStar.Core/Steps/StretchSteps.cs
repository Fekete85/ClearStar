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
    // Beginner sliders (−1…1): brightness of the objects, level of the background, contrast between the two.
    public const string ObjectsKey = "objects";
    public const string BackgroundKey = "background";
    public const string ContrastKey = "contrast";
    private const string S = "ghs";
    private const string SignedFormat = "{0:+0.00;−0.00;0.00}";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.StarlessStretch, StepGroup.Stars, S,
        [
            new(ObjectsKey, L.T("step.ghs.objects.label"), ParameterKind.Slider, 0.0, -1, 1, L.A("step.ghs.objects.ticks"), Help: L.T("step.ghs.objects.help"), ValueFormat: SignedFormat),
            new(BackgroundKey, L.T("step.ghs.background.label"), ParameterKind.Slider, 0.0, -1, 1, L.A("step.ghs.background.ticks"), Help: L.T("step.ghs.background.help"), ValueFormat: SignedFormat),
            new(ContrastKey, L.T("step.ghs.contrast.label"), ParameterKind.Slider, 0.0, -1, 1, L.A("step.ghs.contrast.ticks"), Help: L.T("step.ghs.contrast.help"), ValueFormat: SignedFormat),
            // Siril's GHS controls for those who know them.
            new(LnDKey, L.T("step.ghs.lnD.label"), ParameterKind.Slider, 0.0, 0, 10, L.A("step.ghs.lnD.ticks"), Advanced: true, Help: L.T("step.ghs.lnD.help"), ValueFormat: "{0:0.00}"),
            new(BKey, L.T("step.ghs.b.label"), ParameterKind.Slider, 0.0, -5, 15, L.A("step.ghs.b.ticks"), Advanced: true, Help: L.T("step.ghs.b.help"), ValueFormat: "{0:0.0}"),
            new(SpKey, L.T("step.ghs.sp.label"), ParameterKind.Slider, 0.0, 0, 1, L.A("step.ghs.sp.ticks"), Advanced: true, Help: L.T("step.ghs.sp.help"), ValueFormat: "{0:0.000}"),
            new(LpKey, L.T("step.ghs.lp.label"), ParameterKind.Slider, 0.0, 0, 1, L.A("step.ghs.lp.ticks"), Advanced: true, Help: L.T("step.ghs.lp.help"), ValueFormat: "{0:0.000}"),
            new(HpKey, L.T("step.ghs.hp.label"), ParameterKind.Slider, 1.0, 0, 1, L.A("step.ghs.hp.ticks"), Advanced: true, Help: L.T("step.ghs.hp.help"), ValueFormat: "{0:0.000}"),
            Choice(S, TypeKey, "ghs", ["ghs", "invghs", "asinh", "invasinh", "linear"], advanced: true),
            new(BpKey, L.T("step.ghs.bp.label"), ParameterKind.Slider, 0.0, 0, 1, L.A("step.ghs.bp.ticks"), Advanced: true, Help: L.T("step.ghs.bp.help"), ValueFormat: "{0:0.000}"),
            Choice(S, ColourKey, "humanlum", ["indep", "humanlum", "evenlum"], advanced: true),
            Hidden(HistoryKey, "[]"),
        ]);

    /// <summary>The beginner stretch described by the three simple sliders, pivoting on the symmetry point (= background level).</summary>
    public static GhsParams CurrentSimple(StepParameters p) =>
        GhsParams.SimpleStretch(p.GetFloat(ObjectsKey), p.GetFloat(BackgroundKey), p.GetFloat(ContrastKey), p.GetFloat(SpKey));

    /// <summary>Everything the sliders describe (simple stretch first, then the GHS one), identities left out.</summary>
    public static List<GhsParams> CurrentAll(StepParameters p) =>
        new[] { CurrentSimple(p), Current(p) }.Where(x => !x.IsIdentity).ToList();

    /// <summary>The GHS stretch described by the advanced sliders (not yet committed).</summary>
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
        var current = CurrentAll(p);
        if (current.Count == 0) return false;
        var history = History(p);
        history.AddRange(current);
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
        p[ObjectsKey] = 0.0; p[BackgroundKey] = 0.0; p[ContrastKey] = 0.0;
    }

    /// <summary>
    /// "Magic wand": commits the screen-boost auto-stretch (per-channel MTF of the given preset, default
    /// 20% background / 3 MAD – the same as GraXpert's autostretch) into the history, so the GHS sliders can then
    /// refine it – the same "autostretch, then fine-tune" habit as in Siril. Returns false when the image
    /// is already bright.
    /// </summary>
    public static bool CommitAuto(StepParameters p, AstroImage image, DisplayStretch.Preset? preset = null)
    {
        preset ??= DisplayStretch.PresetByKey(DisplayStretch.DefaultPresetKey);
        // Exactly the screen boost: per-channel shadows and midtones (unlinked, which keeps the colours lively),
        // measured on the same downsampled image as the preview (box averaging lowers the noise, so the
        // shadow clipping lands closer to the background and the sky comes out darker and cleaner).
        var small = image.Downsample(image.DownsampleFactor(DisplayStretch.PreviewWidth));
        if (ImageStats.ComputeAll(small).Average(s => s.Median) >= preset.Background) return false;
        var prms = DisplayStretch.ComputeAll(small, preset, linked: false);
        var history = History(p);
        history.Add(new GhsParams(GhsType.Mtf, prms.Average(x => x.Midtones), 0f, 0f, prms.Average(x => x.Shadows), 1f, 0f, GhsColourModel.Independent,
            prms.Select(x => x.Midtones).ToArray(), prms.Select(x => x.Shadows).ToArray()));
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
        // With a separated star layer the stretched starless image and the stars at full strength (the
        // original stretched the same way, minus the starless) are kept for the star step.
        if (StarLayerStore.HasStarsFor(input) && StarLayerStore.StarsLinear is { } starsLinear)
        {
            StarLayerStore.SetStarlessStretched(output);
            StarLayerStore.SetStarsStretched(StarStretchStep.FullStrengthStars(input, starsLinear, output, history, context.CancellationToken));
        }
        string summary = history.Count == 0 ? L.T("msg.ghs.none") : L.F("msg.ghs.summary", history.Count, history[^1].Describe());
        return new StepResult(output, summary);
    }, context.CancellationToken);
}

/// <summary>
/// Step 11: puts the stars back onto the stretched starless image. The nebula stretch leaves the stars
/// "at full strength" in the star layer store (the original stretched exactly like the starless image,
/// minus the starless image), so the slider's maximum brings back every star as it was; lower values
/// raise the layer to a power, which shrinks the halos and drops the faint stars first. Without a
/// separated star layer the whole image gets a gentle MTF stretch instead.
/// </summary>
public sealed class StarStretchStep : StepBase
{
    public const string AmountKey = "amount";
    public const float DefaultAmount = 0.7f;

    private const string S = "starstretch";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.StarStretch, StepGroup.Stars, S,
        [Slider(S, AmountKey, DefaultAmount)]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        float amount = context.Parameters.GetFloat(AmountKey, DefaultAmount);

        if (StarLayerStore.HasStretchedFor(input) && StarLayerStore.StarsStretched is { } stars)
        {
            var output = AddStars(input, stars, amount, context.CancellationToken);
            return new StepResult(output, L.F("msg.starstretch.layerSummary", amount));
        }

        var stats = ImageStats.ComputeAll(input);
        if (stats.Average(s => s.Median) > 0.08f)
            return StepResult.Unchanged(input, L.T("msg.starstretch.already"));

        float target = Lerp(0.08f, 0.25f, amount);
        var prms = DisplayStretch.ComputeAll(input, linked: true, targetBackground: target);
        var output2 = MapPixels(input, (v, c) => prms[c].Apply(v), context.CancellationToken);
        output2.Clamp01();
        return new StepResult(output2, L.F("msg.starstretch.summary", target));
    }, context.CancellationToken);

    /// <summary>Exponent applied to the full-strength star layer: 1 at the maximum (all stars back), larger below it (faint stars and halos fade first).</summary>
    public static float Exponent(float amount) => 1f / Math.Clamp(amount, 0.05f, 1f);

    /// <summary>starless + stars^(1/amount), clamped; at amount = 1 this is exactly the stretched original.</summary>
    public static AstroImage AddStars(AstroImage starless, AstroImage stars, float amount, CancellationToken ct)
    {
        float gamma = Exponent(amount);
        var output = starless.CreateEmptyLike();
        var a = starless.Data; var b = stars.Data; var dst = output.Data;
        Parallel.For(0, starless.Height, new ParallelOptions { CancellationToken = ct }, y =>
        {
            for (int c = 0; c < starless.Channels; c++)
            {
                int start = c * starless.PixelsPerChannel + y * starless.Width;
                for (int i = start; i < start + starless.Width; i++)
                {
                    float s = Math.Clamp(b[i], 0f, 1f);
                    dst[i] = Math.Clamp(a[i] + (gamma == 1f ? s : MathF.Pow(s, gamma)), 0f, 1f);
                }
            }
        });
        return output;
    }

    /// <summary>The star layer in the stretched domain: the original (starless + stars) stretched with the same history, minus the stretched starless image.</summary>
    public static AstroImage FullStrengthStars(AstroImage starlessLinear, AstroImage starsLinear, AstroImage starlessStretched, IReadOnlyList<GhsParams> history, CancellationToken ct)
    {
        var original = starlessLinear.CreateEmptyLike();
        var o = original.Data; var sl = starlessLinear.Data; var st = starsLinear.Data;
        for (int i = 0; i < o.Length; i++) o[i] = sl[i] + st[i];
        var full = GhsTransform.ApplyAll(original, history, ct);
        var stars = starlessStretched.CreateEmptyLike();
        var f = full.Data; var b = starlessStretched.Data; var d = stars.Data;
        for (int i = 0; i < d.Length; i++) d[i] = Math.Clamp(f[i] - b[i], 0f, 1f);
        return stars;
    }
}
