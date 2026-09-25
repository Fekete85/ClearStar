/// A 16 lépés, a Windows-változat `StepId` enumjával azonos sorrendben és számozással.
public enum StepId: Int, CaseIterable, Sendable {
    case loadFrames = 1
    case stack
    case crop
    case backgroundExtraction
    case deconvolution
    case denoise
    case plateSolve
    case colorCalibration
    case starRemoval
    case starlessStretch
    case starStretch
    case greenRemoval
    case chromaticAberration
    case contrast
    case saturation
    case save

    /// A lépés kulcsa a nyelvi fájlokban (`step.<kulcs>.name`).
    public var languageKey: String {
        switch self {
        case .loadFrames: "load"
        case .stack: "stack"
        case .crop: "crop"
        case .backgroundExtraction: "bge"
        case .deconvolution: "deconv"
        case .denoise: "denoise"
        case .plateSolve: "platesolve"
        case .colorCalibration: "colorcal"
        case .starRemoval: "starremoval"
        case .starlessStretch: "ghs"
        case .starStretch: "starstretch"
        case .greenRemoval: "green"
        case .chromaticAberration: "fringe"
        case .contrast: "contrast"
        case .saturation: "saturation"
        case .save: "save"
        }
    }

    public var group: StepGroup {
        switch self {
        case .loadFrames, .stack, .crop: .preparation
        case .backgroundExtraction, .deconvolution, .denoise, .plateSolve, .colorCalibration: .basics
        case .starRemoval, .starlessStretch, .starStretch: .stars
        case .greenRemoval, .chromaticAberration, .contrast, .saturation: .refinement
        case .save: .finish
        }
    }
}

public enum StepGroup: String, CaseIterable, Sendable {
    case preparation = "Preparation"
    case basics = "Basics"
    case stars = "Stars"
    case refinement = "Refinement"
    case finish = "Finish"
}
