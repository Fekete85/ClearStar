import Foundation

/// Step 10: generalised hyperbolic stretch of the (starless) image with Siril's GHS controls. Like
/// Siril's dialog: the sliders describe the next stretch (previewed live by the app); "Apply" commits
/// it to a history of stretches (hidden parameter) and resets the sliders, so gentle stretches can be
/// layered. Running the step replays the whole history on the input.
public final class StarlessStretchStep: WorkflowStep {
    public static let typeKey = "type", lnDKey = "lnD", bKey = "b", spKey = "sp", lpKey = "lp", hpKey = "hp", bpKey = "bp"
    public static let colourKey = "colour", historyKey = "history"
    // Beginner sliders (−1…1): brightness of the objects, level of the background, contrast between the two.
    public static let objectsKey = "objects", backgroundKey = "background", contrastKey = "contrast"
    private static let s = "ghs"
    private static let signedFormat = "{0:+0.00;−0.00;0.00}"

    private static func adv(_ key: String, _ def: Double, _ min: Double, _ max: Double, _ fmt: String) -> ParameterDefinition {
        ParameterDefinition(key: key, label: L.t("step.ghs.\(key).label"), kind: .slider, defaultValue: .number(def), min: min, max: max,
                            tickLabels: L.a("step.ghs.\(key).ticks"), advanced: true, help: L.t("step.ghs.\(key).help"), valueFormat: fmt)
    }

    private static func simple(_ key: String) -> ParameterDefinition {
        ParameterDefinition(key: key, label: L.t("step.ghs.\(key).label"), kind: .slider, defaultValue: .number(0), min: -1, max: 1,
                            tickLabels: L.a("step.ghs.\(key).ticks"), help: L.t("step.ghs.\(key).help"), valueFormat: signedFormat)
    }

    public let definition = StepDefinition.fromLanguage(.starlessStretch, .stars, s, [
        simple(objectsKey), simple(backgroundKey), simple(contrastKey),
        // Siril's GHS controls for those who know them.
        adv(lnDKey, 0, 0, 10, "{0:0.00}"),
        adv(bKey, 0, -5, 15, "{0:0.0}"),
        adv(spKey, 0, 0, 1, "{0:0.000}"),
        adv(lpKey, 0, 0, 1, "{0:0.000}"),
        adv(hpKey, 1, 0, 1, "{0:0.000}"),
        StepKit.choice(s, typeKey, "ghs", ["ghs", "invghs", "asinh", "invasinh", "linear"], advanced: true),
        adv(bpKey, 0, 0, 1, "{0:0.000}"),
        StepKit.choice(s, colourKey, "humanlum", ["indep", "humanlum", "evenlum"], advanced: true),
        StepKit.hidden(historyKey, .text("[]")),
    ])

    public init() {}

    /// The beginner stretch described by the three simple sliders, pivoting on the symmetry point (= background level).
    public static func currentSimple(_ p: StepParameters) -> GhsParams {
        .simpleStretch(objects: p.getFloat(objectsKey), background: p.getFloat(backgroundKey), contrast: p.getFloat(contrastKey), pivot: p.getFloat(spKey))
    }

    /// Everything the sliders describe (simple stretch first, then the GHS one), identities left out.
    public static func currentAll(_ p: StepParameters) -> [GhsParams] { [currentSimple(p), current(p)].filter { !$0.isIdentity } }

    /// The GHS stretch described by the advanced sliders (not yet committed).
    public static func current(_ p: StepParameters) -> GhsParams {
        let type: GhsType
        switch p.getString(typeKey, "ghs") {
        case "invghs": type = .inverseGhs
        case "asinh": type = .asinh
        case "invasinh": type = .inverseAsinh
        case "linear": type = .linear
        default: type = .ghs
        }
        let colour: GhsColourModel
        switch p.getString(colourKey, "humanlum") {
        case "indep": colour = .independent
        case "evenlum": colour = .evenLuminance
        default: colour = .humanLuminance
        }
        let sp = p.getFloat(spKey).clamped(0, 1)
        let lp = min(p.getFloat(lpKey).clamped(0, 1), sp)
        let hp = max(p.getFloat(hpKey, 1).clamped(0, 1), sp)
        return GhsParams(type, GhsParams.dFromLog(p.getDouble(lnDKey)), p.getFloat(bKey), lp, sp, hp, p.getFloat(bpKey).clamped(0, 0.999), colour)
    }

    public static func history(_ p: StepParameters) -> [GhsParams] { GhsParams.listFromJson(p.getString(historyKey, "[]")) }

    /// Moves the current stretch into the history and resets the sliders. False when there was nothing to commit.
    @discardableResult
    public static func commit(_ p: StepParameters) -> Bool {
        let current = currentAll(p)
        if current.isEmpty { return false }
        var h = history(p)
        h.append(contentsOf: current)
        p.set(historyKey, GhsParams.listToJson(h))
        resetCurrent(p)
        return true
    }

    /// Removes the last committed stretch. False when the history was empty.
    @discardableResult
    public static func undo(_ p: StepParameters) -> Bool {
        var h = history(p)
        if h.isEmpty { return false }
        h.removeLast()
        p.set(historyKey, GhsParams.listToJson(h))
        return true
    }

    public static func resetCurrent(_ p: StepParameters) {
        p.set(lnDKey, 0.0); p.set(bpKey, 0.0)
        p.set(objectsKey, 0.0); p.set(backgroundKey, 0.0); p.set(contrastKey, 0.0)
    }

    /// "Magic wand": commits the screen-boost auto-stretch (per-channel MTF of the preset, default 20%
    /// background / 3 MAD – GraXpert's autostretch) into the history, so the sliders can refine it.
    /// False when the image is already bright.
    @discardableResult
    public static func commitAuto(_ p: StepParameters, _ image: AstroImage, preset: DisplayStretch.Preset? = nil) -> Bool {
        let preset = preset ?? DisplayStretch.presetByKey(DisplayStretch.defaultPresetKey)
        // Exactly the screen boost: per-channel shadows and midtones (unlinked), measured on the same
        // downsampled image as the preview.
        let small = image.downsample(image.downsampleFactor(DisplayStretch.previewWidth))
        if averageF(ImageStats.computeAll(small).map(\.median)) >= preset.background { return false }
        let prms = DisplayStretch.computeAll(small, preset: preset, linked: false)
        var h = history(p)
        h.append(GhsParams(.mtf, averageF(prms.map(\.midtones)), 0, 0, averageF(prms.map(\.shadows)), 1, 0, .independent,
                           channelMidtones: prms.map(\.midtones), channelShadows: prms.map(\.shadows)))
        p.set(historyKey, GhsParams.listToJson(h))
        resetCurrent(p)
        return true
    }

    /// Median of a normalised rectangle (all channels) – the "eyedropper" for the symmetry point.
    public static func regionMedian(_ image: AstroImage, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Float {
        let x0 = toInt(x * Double(image.width)).clamped(0, image.width - 1), y0 = toInt(y * Double(image.height)).clamped(0, image.height - 1)
        let x1 = toInt((x + w) * Double(image.width)).clamped(x0 + 1, image.width), y1 = toInt((y + h) * Double(image.height)).clamped(y0 + 1, image.height)
        var values: [Float] = []
        for c in 0 ..< image.channels {
            for yy in y0 ..< y1 { for xx in x0 ..< x1 { values.append(image[c, xx, yy]) } }
        }
        return values.isEmpty ? 0 : ImageStats.median(&values)
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        let h = Self.history(context.parameters)
        let output = h.isEmpty ? input.clone() : try GhsTransform.applyAll(input, h, context.cancellation)
        // With a separated star layer the stretched starless image and the stars at full strength (the
        // original stretched the same way, minus the starless) are kept for the star step.
        if StarLayerStore.hasStars(for: input), let starsLinear = StarLayerStore.starsLinear {
            StarLayerStore.setStarlessStretched(output)
            StarLayerStore.setStarsStretched(try StarStretchStep.fullStrengthStars(input, starsLinear, output, h, context.cancellation))
        }
        let summary = h.isEmpty ? L.t("msg.ghs.none") : L.f("msg.ghs.summary", h.count, h[h.count - 1].describe())
        return StepResult(image: output, summary: summary)
    }
}

/// Step 11: puts the stars back onto the stretched starless image. The nebula stretch leaves the stars
/// "at full strength" in the star layer store, so the slider's maximum brings back every star as it
/// was; lower values raise the layer to a power, which shrinks the halos and drops the faint stars
/// first. Without a separated star layer the whole image gets a gentle MTF stretch instead.
public final class StarStretchStep: WorkflowStep {
    public static let amountKey = "amount"
    public static let defaultAmount: Float = 0.7
    private static let s = "starstretch"

    public let definition = StepDefinition.fromLanguage(.starStretch, .stars, s, [StepKit.slider(s, amountKey, Double(defaultAmount))])

    public init() {}

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        let amount = context.parameters.getFloat(Self.amountKey, Self.defaultAmount)

        if StarLayerStore.hasStretched(for: input), let stars = StarLayerStore.starsStretched {
            let output = try Self.addStars(input, stars, amount, context.cancellation)
            return StepResult(image: output, summary: L.f("msg.starstretch.layerSummary", amount))
        }

        let stats = ImageStats.computeAll(input)
        if averageF(stats.map(\.median)) > 0.08 { return .unchanged(input, L.t("msg.starstretch.already")) }

        let target = StepKit.lerp(0.08, 0.25, amount)
        let prms = DisplayStretch.computeAll(input, linked: true, targetBackground: target)
        let output = try StepKit.mapPixels(input, context.cancellation) { v, c in prms[c].apply(v) }
        output.clamp01()
        return StepResult(image: output, summary: L.f("msg.starstretch.summary", target))
    }

    /// Exponent applied to the full-strength star layer: 1 at the maximum, larger below it.
    public static func exponent(_ amount: Float) -> Float { 1 / amount.clamped(0.05, 1) }

    /// starless + stars^(1/amount), clamped; at amount = 1 this is exactly the stretched original.
    public static func addStars(_ starless: AstroImage, _ stars: AstroImage, _ amount: Float, _ ct: CancellationToken) throws -> AstroImage {
        let gamma = exponent(amount)
        let output = starless.createEmptyLike()
        let n = starless.pixelsPerChannel, w = starless.width, ch = starless.channels
        try starless.data.withUnsafeBufferPointer { a in
            try stars.data.withUnsafeBufferPointer { b in
                try output.data.withUnsafeMutableBufferPointer { dst in
                    try parallelFor(starless.height, ct) { y in
                        for c in 0 ..< ch {
                            let start = c * n + y * w
                            for i in start ..< start + w {
                                let s = b[i].clamped(0, 1)
                                dst[i] = (a[i] + (gamma == 1 ? s : pow(s, gamma))).clamped(0, 1)
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    /// The star layer in the stretched domain: the original (starless + stars) stretched with the same
    /// history, minus the stretched starless image.
    public static func fullStrengthStars(_ starlessLinear: AstroImage, _ starsLinear: AstroImage, _ starlessStretched: AstroImage,
                                         _ history: [GhsParams], _ ct: CancellationToken) throws -> AstroImage {
        let original = starlessLinear.createEmptyLike()
        for i in 0 ..< original.data.count { original.data[i] = starlessLinear.data[i] + starsLinear.data[i] }
        let full = try GhsTransform.applyAll(original, history, ct)
        let stars = starlessStretched.createEmptyLike()
        for i in 0 ..< stars.data.count { stars.data[i] = (full.data[i] - starlessStretched.data[i]).clamped(0, 1) }
        return stars
    }
}

/// Hands the star layer from the star-removal step to the later steps (the workflow carries one
/// image per step). Every layer is tagged with a fingerprint of the image it belongs to, so a stale
/// layer is never applied to the wrong image.
public enum StarLayerStore {
    private struct State {
        var starsLinear: AstroImage?
        var starlessLinearKey: String?
        var starlessStretched: AstroImage?
        var starsStretched: AstroImage?
        var starlessStretchedKey: String?
    }
    private static let state = Locked(State())

    /// Linear star layer (original − starless).
    public static var starsLinear: AstroImage? { state.current.starsLinear }
    public static var starlessStretched: AstroImage? { state.current.starlessStretched }
    public static var starsStretched: AstroImage? { state.current.starsStretched }

    public static func clear() { state.current = State() }

    public static func setLinear(_ starless: AstroImage, _ stars: AstroImage) {
        let key = fingerprint(starless)
        state.current = State(starsLinear: stars, starlessLinearKey: key)
    }

    /// True when `image` is the starless image the star layer was made for.
    public static func hasStars(for image: AstroImage) -> Bool {
        let s = state.current
        return s.starsLinear != nil && s.starlessLinearKey == fingerprint(image)
    }

    public static func setStarlessStretched(_ image: AstroImage) {
        let key = fingerprint(image)
        state.withLock { $0.starlessStretched = image; $0.starlessStretchedKey = key; $0.starsStretched = nil }
    }

    public static func hasStretched(for image: AstroImage) -> Bool {
        let s = state.current
        return s.starlessStretched != nil && s.starlessStretchedKey == fingerprint(image)
    }

    public static func setStarsStretched(_ stars: AstroImage) { state.withLock { $0.starsStretched = stars } }

    /// Cheap identity: size plus a strided checksum of the pixel data.
    public static func fingerprint(_ image: AstroImage) -> String {
        var sum = 0.0
        image.data.withUnsafeBufferPointer { d in
            var i = 0
            while i < d.count { sum += Double(d[i]) * Double(1 + (i % 7)); i += 97 }
        }
        return "\(image.width)x\(image.height)x\(image.channels):\(sum)"
    }
}
