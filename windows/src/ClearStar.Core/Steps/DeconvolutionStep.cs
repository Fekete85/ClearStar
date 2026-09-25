using ClearStar.Core.AI;
using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// Step 5: sharpening with the GraXpert deconvolution networks. Following the AbdurAstro workflow
/// the stellar network runs first (tighter stars), then the object network (nebula/galaxy detail).
/// The star FWHM that conditions the nets is measured automatically unless the user overrides it.
/// </summary>
public sealed class DeconvolutionStep : StepBase
{
    public const string StarsKey = "stars";
    public const string StarsStrengthKey = "starsStrength";
    public const string StarsModelKey = "starsModel";
    public const string ObjectKey = "object";
    public const string ObjectStrengthKey = "objectStrength";
    public const string ObjectModelKey = "objectModel";
    public const string AutoPsfKey = "autoPsf";
    public const string PsfKey = "psf";
    private const string S = "deconv";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Deconvolution, StepGroup.Basics, S,
        [
            Toggle(S, StarsKey, true),
            Slider(S, StarsStrengthKey, 0.5),
            Toggle(S, ObjectKey, true),
            Slider(S, ObjectStrengthKey, 0.5),
            Toggle(S, AutoPsfKey, true, advanced: true),
            Slider(S, PsfKey, 5.0, 1.5, 12, advanced: true),
            Model(S, StarsModelKey, nameof(AiModelKind.DeconvolutionStars), advanced: true),
            Model(S, ObjectModelKey, nameof(AiModelKind.DeconvolutionObject), advanced: true),
        ]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() => Run(context), context.CancellationToken);

    private StepResult Run(WorkflowContext context)
    {
        var input = context.RequireInput();
        var p = context.Parameters;
        bool stars = p.GetBool(StarsKey, true), obj = p.GetBool(ObjectKey, true);
        if (!stars && !obj) return StepResult.Unchanged(input, L.T("msg.deconv.nothing"));
        var ct = context.CancellationToken;

        // Resolve both models up front so the user gets one clear message before any work starts.
        AiModelInfo? starsModel = stars ? ResolveModel(AiModelKind.DeconvolutionStars, p.GetString(StarsModelKey)) : null;
        AiModelInfo? objectModel = obj ? ResolveModel(AiModelKind.DeconvolutionObject, p.GetString(ObjectModelKey)) : null;
        if (stars && starsModel is null) throw new InvalidOperationException(L.T("msg.deconv.noStarsModel"));
        if (obj && objectModel is null) throw new InvalidOperationException(L.T("msg.deconv.noObjectModel"));

        float fwhm;
        if (p.GetBool(AutoPsfKey, true))
        {
            context.Report(0.02, L.T("msg.deconv.measuring"));
            fwhm = PsfMeasure.EstimateFwhm(input, ct);
        }
        else fwhm = p.GetFloat(PsfKey, 5f);

        var image = input;
        double start = 0.05, span = stars && obj ? 0.47 : 0.93;
        if (stars)
        {
            image = DeconvolutionModel.Deconvolve(image, starsModel!.Path, stellar: true, p.GetFloat(StarsStrengthKey, 0.5f), fwhm,
                f => context.Report(start + span * f, L.T("msg.deconv.stars")), ct);
            start += span;
        }
        if (obj)
        {
            image = DeconvolutionModel.Deconvolve(image, objectModel!.Path, stellar: false, p.GetFloat(ObjectStrengthKey, 0.5f), fwhm,
                f => context.Report(start + span * f, L.T("msg.deconv.object")), ct);
        }

        string what = stars && obj ? L.T("msg.deconv.both") : stars ? L.T("msg.deconv.starsOnly") : L.T("msg.deconv.objectOnly");
        return new StepResult(image, L.F("msg.deconv.summary", what, fwhm) + L.T(OnnxSessions.LastProvider == "GPU" ? "msg.ai.gpu" : "msg.ai.cpu"));
    }

    private static AiModelInfo? ResolveModel(AiModelKind kind, string explicitPath)
    {
        explicitPath = explicitPath.Trim();
        return explicitPath.Length > 0 && File.Exists(explicitPath)
            ? new AiModelInfo(kind, Path.GetFileName(Path.GetDirectoryName(explicitPath) ?? ""), explicitPath, L.T("msg.bge.selectedSource"))
            : AiModelStore.Resolve(kind);
    }
}
