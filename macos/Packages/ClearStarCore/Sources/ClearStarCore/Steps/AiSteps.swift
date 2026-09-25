import Foundation

/// Step 4: flattening the background. By default with GraXpert's AI model: the network estimates the
/// gradient from a shrunk image and it is subtracted. Fallback: grid sampling and a polynomial fit
/// (bright cells – nebula, galaxy, star – excluded).
public final class BackgroundExtractionStep: WorkflowStep {
    public static let methodKey = "method", modelKey = "model", strengthKey = "strength", smoothingKey = "smoothing"
    public static let gridKey = "grid", correctionKey = "correction"
    // Language-independent choice values (labels: step.bge.method.* and step.bge.correction.*).
    public static let methodAi = "ai", methodPolynomial = "polynomial"
    public static let correctionSubtract = "subtract", correctionDivide = "divide"
    private static let s = "bge"

    public let definition = StepDefinition.fromLanguage(.backgroundExtraction, .basics, s, [
        StepKit.slider(s, smoothingKey, 0.2),
        StepKit.choice(s, methodKey, methodAi, [methodAi, methodPolynomial], advanced: true),
        StepKit.model(s, modelKey, tag: AiModelKind.backgroundExtraction.rawValue, advanced: true),
        StepKit.slider(s, strengthKey, 0.5, advanced: true),
        StepKit.slider(s, gridKey, 0.5, advanced: true),
        StepKit.choice(s, correctionKey, correctionSubtract, [correctionSubtract, correctionDivide], advanced: true),
    ])

    public init() {}

    /// The sample points (normalised 0..1) so the UI can draw them.
    public static var lastSamplePoints: [(x: Float, y: Float)] {
        get { samplePoints.current }
        set { samplePoints.current = newValue }
    }
    private static let samplePoints = Locked<[(x: Float, y: Float)]>([])

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        try await Task.detached(priority: .userInitiated) { try Self.run(context) }.value
    }

    private static func run(_ context: WorkflowContext) throws -> StepResult {
        let input = try context.requireInput()
        let ct = context.cancellation
        let p = context.parameters
        let strength = p.getFloat(strengthKey, 0.5), smoothing = p.getFloat(smoothingKey, 0.2), grid = p.getFloat(gridKey, 0.5)

        if p.getString(methodKey, methodAi) == methodAi {
            guard let model = AiModelStore.resolve(.backgroundExtraction, explicitPath: p.getString(modelKey)) else {
                throw ClearStarError(L.t("msg.bge.noModel"))
            }
            context.report(0.1, L.t("msg.bge.estimating"))
            let background = try BackgroundModel.estimateBackground(input, model.path, smoothing: smoothing * 0.5, ct)
            context.report(0.8, L.t("msg.bge.subtracting"))
            let divide = p.getString(correctionKey, correctionSubtract) == correctionDivide
            let corrected = divide ? BackgroundModel.divide(input, background) : BackgroundModel.subtract(input, background)
            lastSamplePoints = []
            return StepResult(image: corrected, summary: L.f("msg.bge.summaryAi", model.version, model.source)
                              + L.t(CoreMLRunner.lastProvider == "GPU" ? "msg.ai.gpu" : "msg.ai.cpu"))
        }

        // Weak: a cell 1σ brighter than the model is already "object"; strong: background up to 3σ.
        let tolerance = StepKit.lerp(1, 3, strength)
        let degree = smoothing < 0.34 ? 4 : smoothing < 0.67 ? 2 : 1
        let columns = Int(Double(StepKit.lerp(16, 48, grid)).roundedEven)
        let output = input.createEmptyLike()
        let (points, used) = try BackgroundFit.flatten(input, output, degree: degree, tolerance: tolerance, columns: columns, ct) { f, m in context.report(f, m) }
        lastSamplePoints = points
        output.clamp01()
        return StepResult(image: output, summary: L.f("msg.bge.summaryPoly", points.count, degreeName(used)))
    }

    private static func degreeName(_ d: Int) -> String { L.t(d == 1 ? "msg.bge.degree1" : d == 2 ? "msg.bge.degree2" : "msg.bge.degreeN") }
}

/// Step 5: sharpening with the GraXpert deconvolution networks. As in the AbdurAstro workflow the
/// stellar network runs first (tighter stars), then the object network. The star FWHM conditioning the
/// networks is measured unless the user sets it.
public final class DeconvolutionStep: WorkflowStep {
    public static let starsKey = "stars", starsStrengthKey = "starsStrength", starsModelKey = "starsModel"
    public static let objectKey = "object", objectStrengthKey = "objectStrength", objectModelKey = "objectModel"
    public static let autoPsfKey = "autoPsf", psfKey = "psf"
    private static let s = "deconv"

    public let definition = StepDefinition.fromLanguage(.deconvolution, .basics, s, [
        StepKit.toggle(s, starsKey, true),
        StepKit.slider(s, starsStrengthKey, 0.5),
        StepKit.toggle(s, objectKey, true),
        StepKit.slider(s, objectStrengthKey, 0.5),
        StepKit.toggle(s, autoPsfKey, true, advanced: true),
        StepKit.slider(s, psfKey, 5.0, 1.5, 12, advanced: true),
        StepKit.model(s, starsModelKey, tag: AiModelKind.deconvolutionStars.rawValue, advanced: true),
        StepKit.model(s, objectModelKey, tag: AiModelKind.deconvolutionObject.rawValue, advanced: true),
    ])

    public init() {}

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        try await Task.detached(priority: .userInitiated) { try Self.run(context) }.value
    }

    private static func run(_ context: WorkflowContext) throws -> StepResult {
        let input = try context.requireInput()
        let p = context.parameters
        let stars = p.getBool(starsKey, true), obj = p.getBool(objectKey, true)
        if !stars && !obj { return .unchanged(input, L.t("msg.deconv.nothing")) }
        let ct = context.cancellation

        // Both models up front so the user gets one clear message before any work starts.
        let starsModel = stars ? AiModelStore.resolve(.deconvolutionStars, explicitPath: p.getString(starsModelKey)) : nil
        let objectModel = obj ? AiModelStore.resolve(.deconvolutionObject, explicitPath: p.getString(objectModelKey)) : nil
        if stars && starsModel == nil { throw ClearStarError(L.t("msg.deconv.noStarsModel")) }
        if obj && objectModel == nil { throw ClearStarError(L.t("msg.deconv.noObjectModel")) }

        let fwhm: Float
        if p.getBool(autoPsfKey, true) {
            context.report(0.02, L.t("msg.deconv.measuring"))
            fwhm = try PsfMeasure.estimateFwhm(input, ct)
        } else {
            fwhm = p.getFloat(psfKey, 5)
        }

        var image = input
        var start = 0.05
        let span = stars && obj ? 0.47 : 0.93
        if stars, let m = starsModel {
            let from = start
            image = try DeconvolutionModel.deconvolve(image, m.path, stellar: true, strength: p.getFloat(starsStrengthKey, 0.5), fwhmPx: fwhm,
                                                      progress: { f in context.report(from + span * f, L.t("msg.deconv.stars")) }, ct)
            start += span
        }
        if obj, let m = objectModel {
            let from = start
            image = try DeconvolutionModel.deconvolve(image, m.path, stellar: false, strength: p.getFloat(objectStrengthKey, 0.5), fwhmPx: fwhm,
                                                      progress: { f in context.report(from + span * f, L.t("msg.deconv.object")) }, ct)
        }
        let what = stars && obj ? L.t("msg.deconv.both") : stars ? L.t("msg.deconv.starsOnly") : L.t("msg.deconv.objectOnly")
        return StepResult(image: image, summary: L.f("msg.deconv.summary", what, fwhm) + L.t(CoreMLRunner.lastProvider == "GPU" ? "msg.ai.gpu" : "msg.ai.cpu"))
    }
}

/// Step 6: noise reduction with the GraXpert denoising network, blended by strength.
public final class DenoiseStep: WorkflowStep {
    public static let strengthKey = "strength", modelKey = "model"
    private static let s = "denoise"

    public let definition = StepDefinition.fromLanguage(.denoise, .basics, s, [
        StepKit.slider(s, strengthKey, 0.5),
        StepKit.model(s, modelKey, tag: AiModelKind.denoise.rawValue, advanced: true),
    ])

    public init() {}

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        try await Task.detached(priority: .userInitiated) {
            let input = try context.requireInput()
            let p = context.parameters
            let strength = p.getFloat(Self.strengthKey, 0.5)
            if strength <= 0 { return .unchanged(input, L.t("msg.denoise.nothing")) }
            guard let model = AiModelStore.resolve(.denoise, explicitPath: p.getString(Self.modelKey)) else {
                throw ClearStarError(L.t("msg.denoise.noModel"))
            }
            let output = try DenoiseModel.denoise(input, model.path, strength: strength,
                                                  progress: { f in context.report(0.02 + 0.96 * f, L.t("msg.denoise.running")) }, context.cancellation)
            return StepResult(image: output, summary: L.f("msg.denoise.summary", model.version, model.source)
                              + L.t(CoreMLRunner.lastProvider == "GPU" ? "msg.ai.gpu" : "msg.ai.cpu"))
        }.value
    }
}

/// Step 9: star removal with the user's StarNet2. The linear image is auto-stretched, StarNet2 runs,
/// the result goes back to linear; the star layer (original − starless) goes to the StarLayerStore
/// for the star stretch and the recombination.
public final class StarRemovalStep: WorkflowStep {
    private static let s = "starremoval"
    public let definition = StepDefinition.fromLanguage(.starRemoval, .stars, s, [])

    public init() {}

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        try await Task.detached(priority: .userInitiated) {
            let input = try context.requireInput()
            guard let exe = StarNet.locate() else { throw ClearStarError(L.t("msg.starremoval.notFound")) }
            if input.width < 512 || input.height < 512 { throw ClearStarError(L.t("msg.starremoval.tooSmall")) }
            context.report(0.02, L.t("msg.starremoval.running"))
            let (starless, stars) = try StarNet.removeStarsLinear(input, exe: exe,
                                                                  progress: { f in context.report(0.05 + 0.9 * f, L.t("msg.starremoval.running")) },
                                                                  context.cancellation)
            StarLayerStore.setLinear(starless, stars)
            return StepResult(image: starless, summary: L.t("msg.starremoval.summary"))
        }.value
    }
}
