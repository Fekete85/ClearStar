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
        new NotImplementedStep(StepId.Denoise, StepGroup.Basics, "denoise"),
        new NotImplementedStep(StepId.PlateSolve, StepGroup.Basics, "platesolve"),
        new NotImplementedStep(StepId.ColorCalibration, StepGroup.Basics, "colorcal"),
        new NotImplementedStep(StepId.StarRemoval, StepGroup.Stars, "starremoval"),
        new StarlessStretchStep(),
        new StarStretchStep(),
        new NotImplementedStep(StepId.StarRecombination, StepGroup.Stars, "recombine"),
        new GreenRemovalStep(),
        new NotImplementedStep(StepId.ChromaticAberration, StepGroup.Refinement, "fringe"),
        new ContrastStep(),
        new SaturationStep(),
        new SaveStep(),
    ];

    public static Workflow CreateWorkflow() => new(CreateAll());
}
