using ClearStar.Core.AI;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>Step 6: noise reduction with the GraXpert denoising network, blended by strength.</summary>
public sealed class DenoiseStep : StepBase
{
    public const string StrengthKey = "strength";
    public const string ModelKey = "model";
    private const string S = "denoise";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Denoise, StepGroup.Basics, S,
        [
            Slider(S, StrengthKey, 0.5),
            Model(S, ModelKey, nameof(AiModelKind.Denoise)),
        ]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() =>
    {
        var input = context.RequireInput();
        var p = context.Parameters;
        float strength = p.GetFloat(StrengthKey, 0.5f);
        if (strength <= 0f) return StepResult.Unchanged(input, L.T("msg.denoise.nothing"));

        string explicitPath = p.GetString(ModelKey).Trim();
        AiModelInfo? model = explicitPath.Length > 0 && File.Exists(explicitPath)
            ? new AiModelInfo(AiModelKind.Denoise, Path.GetFileName(Path.GetDirectoryName(explicitPath) ?? ""), explicitPath, L.T("msg.bge.selectedSource"))
            : AiModelStore.Resolve(AiModelKind.Denoise);
        if (model is null) throw new InvalidOperationException(L.T("msg.denoise.noModel"));

        var output = DenoiseModel.Denoise(input, model.Path, strength, f => context.Report(0.02 + 0.96 * f, L.T("msg.denoise.running")), context.CancellationToken);
        return new StepResult(output, L.F("msg.denoise.summary", model.Version, model.Source) + L.T(OnnxSessions.LastProvider == "GPU" ? "msg.ai.gpu" : "msg.ai.cpu"));
    }, context.CancellationToken);
}
