using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>13. lépés: zöld árnyalat eltávolítása (SCNR, "average neutral" módszer).</summary>
public sealed class GreenRemovalStep : StepBase
{
    public const string AmountKey = "amount";

    private const string S = "green";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.GreenRemoval, StepGroup.Refinement, S,
        [Slider(S, AmountKey, 1.0)]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        if (!input.IsColor) return StepResult.Unchanged(input, L.T("msg.green.mono"));
        float amount = context.Parameters.GetFloat(AmountKey, 1f);
        var output = MapRgb(input, (r, g, b) =>
        {
            float neutral = 0.5f * (r + b);
            float g2 = g > neutral ? Lerp(g, neutral, amount) : g;
            return (r, g2, b);
        }, context.CancellationToken);
        return new StepResult(output, L.T("msg.green.summary"));
    }, context.CancellationToken);
}

/// <summary>15. lépés: kontraszt – középtónusokat erősítő S-görbe, opcionális feketepont-emeléssel.</summary>
public sealed class ContrastStep : StepBase
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

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        float amount = context.Parameters.GetFloat(AmountKey, 0.3f);
        float black = context.Parameters.GetFloat(BlackPointKey, 0f);
        var output = MapPixels(input, (v, _) =>
        {
            float x = black > 0 ? (v - black) / (1f - black) : v;
            x = Math.Clamp(x, 0f, 1f);
            float s = x * x * (3f - 2f * x);
            return Lerp(x, s, amount);
        }, context.CancellationToken);
        return new StepResult(output, L.T("msg.contrast.summary"));
    }, context.CancellationToken);
}

/// <summary>16. lépés: színtelítettség a világosság megtartásával.</summary>
public sealed class SaturationStep : StepBase
{
    public const string AmountKey = "amount";

    private const string S = "saturation";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Saturation, StepGroup.Refinement, S,
        [Slider(S, AmountKey, 0.25)]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        if (!input.IsColor) return StepResult.Unchanged(input, L.T("msg.saturation.mono"));
        float gain = 1f + 1.5f * context.Parameters.GetFloat(AmountKey, 0.25f);
        var output = MapRgb(input, (r, g, b) =>
        {
            float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            return (Math.Clamp(l + (r - l) * gain, 0f, 1f), Math.Clamp(l + (g - l) * gain, 0f, 1f), Math.Clamp(l + (b - l) * gain, 0f, 1f));
        }, context.CancellationToken);
        return new StepResult(output, L.T("msg.saturation.summary"));
    }, context.CancellationToken);
}
