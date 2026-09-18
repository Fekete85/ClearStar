using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Step 12: puts the stretched stars back onto the stretched starless image with a screen blend,
/// the star weight chosen by the user. Without a separated star layer the image passes through.
/// </summary>
public sealed class RecombineStep : StepBase
{
    public const string AmountKey = "amount";
    private const string S = "recombine";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.StarRecombination, StepGroup.Stars, S,
        [Slider(S, AmountKey, 1.0, 0.2, 1.5)]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        var starless = StarLayerStore.StarlessStretched;
        var stars = StarLayerStore.StarsStretched;
        if (starless is null || stars is null) return StepResult.Unchanged(input, L.T("msg.recombine.noLayers"));
        if (starless.Width != input.Width || starless.Height != input.Height) return StepResult.Unchanged(input, L.T("msg.recombine.noLayers"));
        float amount = context.Parameters.GetFloat(AmountKey, 1f);
        var output = Screen(starless, stars, amount, context.CancellationToken);
        return new StepResult(output, L.F("msg.recombine.summary", amount));
    }, context.CancellationToken);

    /// <summary>Screen blend: 1 − (1 − a)(1 − w·b), which never clips and keeps star colours.</summary>
    public static AstroImage Screen(AstroImage starless, AstroImage stars, float weight, CancellationToken ct)
    {
        var output = starless.CreateEmptyLike();
        var a = starless.Data; var b = stars.Data; var dst = output.Data;
        Parallel.For(0, starless.Height, new ParallelOptions { CancellationToken = ct }, y =>
        {
            for (int c = 0; c < starless.Channels; c++)
            {
                int start = c * starless.PixelsPerChannel + y * starless.Width;
                for (int i = start; i < start + starless.Width; i++)
                {
                    float s = Math.Clamp(b[i] * weight, 0f, 1f);
                    dst[i] = 1f - (1f - a[i]) * (1f - s);
                }
            }
        });
        return output;
    }
}
