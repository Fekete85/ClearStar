import Foundation

/// The 16 steps in processing order.
public enum StepCatalog {
    public static func createAll() -> [any WorkflowStep] {
        [
            LoadFramesStep(),
            StackStep(),
            CropStep(),
            NotImplementedStep(.backgroundExtraction),
            NotImplementedStep(.deconvolution),
            NotImplementedStep(.denoise),
            NotImplementedStep(.plateSolve),
            NotImplementedStep(.colorCalibration),
            NotImplementedStep(.starRemoval),
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
