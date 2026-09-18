using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// 10. lépés: a halvány ködök, galaxisok kiemelése általánosított hiperbolikus nyújtással (GHS).
/// A b&gt;0 alak szimmetriapont (SP) körüli formáját használjuk, [0,1]-re normálva:
/// x&lt;SP: (1 + D·b·(SP−x))^(−1/b), x≥SP: 2 − (1 + D·b·(x−SP))^(−1/b).
/// Előtte az autostretch-hez hasonló árnyékvágás, hogy a háttér ne "szürküljön".
/// </summary>
public sealed class StarlessStretchStep : StepBase
{
    public const string AmountKey = "amount";
    public const string FocusKey = "focus";
    public const string ShapeKey = "shape";
    public const string LinkedKey = "linked";

    private const string S = "ghs";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.StarlessStretch, StepGroup.Stars, S,
        [
            Slider(S, AmountKey, 0.5),
            Slider(S, FocusKey, 0.15),
            Slider(S, ShapeKey, 0.4, advanced: true),
            Toggle(S, LinkedKey, true, advanced: true),
        ]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        var p = context.Parameters;
        float amount = p.GetFloat(AmountKey, 0.5f);
        float focus = p.GetFloat(FocusKey, 0.3f);
        float shape = p.GetFloat(ShapeKey, 0.4f);
        bool linked = p.GetBool(LinkedKey, true);

        // A "kiemelés mértéke" a háttér célfényessége a nyújtás után; a D-t ehhez keressük meg.
        float targetBackground = Lerp(0.07f, 0.28f, amount);
        float b = Lerp(0.2f, 6f, shape);

        var stats = ImageStats.ComputeAll(input);
        var output = input.CreateEmptyLike();
        int n = input.PixelsPerChannel;
        // Árnyékvágás csatornánként: a háttér színét semlegesíti. Összekapcsolt módban közös
        // zajszinttel vágunk, így minden csatorna háttere ugyanoda kerül; a görbe is közös.
        float sigmaRef = stats.Max(s => s.Sigma);
        var shadowsPer = new float[input.Channels];
        var bgPer = new float[input.Channels];
        for (int c = 0; c < input.Channels; c++)
        {
            float sigma = linked ? sigmaRef : stats[c].Sigma;
            shadowsPer[c] = Math.Clamp(stats[c].Median - 2.8f * sigma, 0f, 0.99f);
            bgPer[c] = Math.Clamp((stats[c].Median - shadowsPer[c]) / (1f - shadowsPer[c]), 1e-4f, 0.5f);
        }
        float linkedBg = bgPer.Average();
        float linkedSp = focus * Math.Min(0.25f, linkedBg * 6f);
        float linkedD = SolveD(linkedBg, targetBackground, b, linkedSp);
        float d = linkedD;
        for (int c = 0; c < input.Channels; c++)
        {
            float shadows = shadowsPer[c];
            float bg = linked ? linkedBg : bgPer[c];
            // Szimmetriapont: "Sötét részek" = 0 (a leghalványabb köd kapja a legtöbb kontrasztot),
            // feljebb tolva a fényesebb tartomány kap hangsúlyt, a háttér pedig sötétebb marad.
            float sp = linked ? linkedSp : focus * Math.Min(0.25f, bg * 6f);
            d = linked ? linkedD : SolveD(bg, targetBackground, b, sp);
            var ghs = new Ghs(d, b, sp);
            var src = input.Data; var dst = output.Data;
            int off = c * n;
            Parallel.For(0, input.Height, new ParallelOptions { CancellationToken = context.CancellationToken }, y =>
            {
                for (int i = off + y * input.Width; i < off + (y + 1) * input.Width; i++)
                {
                    float x = (src[i] - shadows) / (1f - shadows);
                    dst[i] = ghs.Apply(x);
                }
            });
        }
        output.Clamp01();
        // With a separated star layer the stretched starless image is kept for the recombination.
        if (StarLayerStore.HasStarsFor(input)) StarLayerStore.SetStarlessStretched(output);
        return new StepResult(output, L.F("msg.ghs.summary", targetBackground, d, b));
    }, context.CancellationToken);

    /// <summary>Az a D, amellyel a háttér (bg) a célértékre kerül – felezéssel, log skálán.</summary>
    public static float SolveD(float bg, float target, float b, float sp)
    {
        if (bg >= target) return 0.5f;
        float lo = -1f, hi = 4f; // log10 D ∈ [0.1, 10000]
        for (int i = 0; i < 40; i++)
        {
            float mid = 0.5f * (lo + hi);
            float y = new Ghs(MathF.Pow(10f, mid), b, sp).Apply(bg);
            if (y < target) lo = mid; else hi = mid;
        }
        return MathF.Pow(10f, 0.5f * (lo + hi));
    }

    public readonly struct Ghs
    {
        private readonly float _d, _b, _sp, _lo, _range;

        public Ghs(float d, float b, float sp)
        {
            _d = d; _b = b; _sp = Math.Clamp(sp, 0.001f, 0.999f);
            _lo = Raw(0f);
            _range = Math.Max(Raw(1f) - _lo, 1e-6f);
        }

        private float Raw(float x)
        {
            if (x < _sp) return MathF.Pow(1f + _d * _b * (_sp - x), -1f / _b);
            return 2f - MathF.Pow(1f + _d * _b * (x - _sp), -1f / _b);
        }

        public float Apply(float x)
        {
            if (x <= 0f) return 0f;
            if (x >= 1f) return 1f;
            return (Raw(x) - _lo) / _range;
        }
    }
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
