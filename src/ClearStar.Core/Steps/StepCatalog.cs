using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>A 17 lépés a feldolgozási sorrendben. A még el nem készültek helyőrzőként vannak jelen.</summary>
public static class StepCatalog
{
    public static IReadOnlyList<IWorkflowStep> CreateAll() =>
    [
        new LoadFramesStep(),
        new StackStep(),
        new CropStep(),
        new BackgroundExtractionStep(),
        new DeconvolutionStep(),
        new DenoiseStep(),
        new PlateSolveStep(),
        new ColorCalibrationStep(),
        new StarRemovalStep(),
        new StarlessStretchStep(),
        new StarStretchStep(),
        new RecombineStep(),
        new GreenRemovalStep(),
        new NotImplementedStep(StepId.ChromaticAberration, StepGroup.Refinement, "fringe"),
        new ContrastStep(),
        new SaturationStep(),
        new SaveStep(),
    ];

    public static Workflow CreateWorkflow() => new(CreateAll());
}
