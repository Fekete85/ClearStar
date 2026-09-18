using ClearStar.Core.AI;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Step 9: star removal with the user's StarNet2. The linear image is auto-stretched, StarNet2 runs,
/// the result is brought back to linear; the star layer (original − starless) goes to the
/// <see cref="StarLayerStore"/> for the star stretch and the recombination steps.
/// </summary>
public sealed class StarRemovalStep : StepBase
{
    private const string S = "starremoval";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(StepId.StarRemoval, StepGroup.Stars, S, []);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        string exe = StarNet.Locate() ?? throw new InvalidOperationException(L.T("msg.starremoval.notFound"));
        if (input.Width < 512 || input.Height < 512) throw new InvalidOperationException(L.T("msg.starremoval.tooSmall"));

        context.Report(0.02, L.T("msg.starremoval.running"));
        (var starless, var stars) = StarNet.RemoveStarsLinear(input, exe,
            f => context.Report(0.05 + 0.9 * f, L.T("msg.starremoval.running")), context.CancellationToken);
        StarLayerStore.SetLinear(starless, stars);
        return new StepResult(starless, L.T("msg.starremoval.summary"));
    }, context.CancellationToken);
}
