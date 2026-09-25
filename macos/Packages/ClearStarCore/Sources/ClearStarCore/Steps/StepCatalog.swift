import Foundation

/// The 16 steps in processing order.
public enum StepCatalog {
    public static func createAll() -> [any WorkflowStep] {
        [
            LoadFramesStep(),
            StackStep(),
            CropStep(),
            BackgroundExtractionStep(),
            DeconvolutionStep(),
            DenoiseStep(),
            NotImplementedStep(.plateSolve),
            NotImplementedStep(.colorCalibration),
            StarRemovalStep(),
            StarlessStretchStep(),
            StarStretchStep(),
            GreenRemovalStep(),
            FringeStep(),
            ContrastStep(),
            SaturationStep(),
            SaveStep(),
        ]
    }

    public static func createWorkflow() -> Workflow { Workflow(createAll()) }
}
