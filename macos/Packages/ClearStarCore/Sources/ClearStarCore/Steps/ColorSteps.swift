import Foundation

/// Step 12: green cast removal (SCNR, "average neutral").
public final class GreenRemovalStep: LivePreviewStep {
    public static let amountKey = "amount"
    private static let s = "green"

    public let definition = StepDefinition.fromLanguage(.greenRemoval, .refinement, s, [StepKit.slider(s, amountKey, 1.0)])

    public init() {}

    public func preview(_ image: AstroImage, _ p: StepParameters, _ ct: CancellationToken) throws -> AstroImage {
        if !image.isColor { return image }
        let amount = p.getFloat(Self.amountKey, 1)
        return try StepKit.mapRgb(image, ct) { r, g, b in
            let neutral = 0.5 * (r + b)
            let g2 = g > neutral ? StepKit.lerp(g, neutral, amount) : g
            return (r, g2, b)
        }
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        if !input.isColor { return .unchanged(input, L.t("msg.green.mono")) }
        return StepResult(image: try preview(input, context.parameters, context.cancellation), summary: L.t("msg.green.summary"))
    }
}

/// Step 13: purple / violet fringing around bright stars (lateral chromatic aberration). Pixels whose
/// hue lies in the violet–magenta range, saturated and bright enough, are desaturated towards their own
/// luminance, so the fringe melts into the star's white halo. Inspired by Siril's unpurple filter.
public final class FringeStep: LivePreviewStep {
    public static let amountKey = "amount", thresholdKey = "threshold", hueWidthKey = "hue"
    private static let s = "fringe"

    public let definition = StepDefinition.fromLanguage(.chromaticAberration, .refinement, s, [
        StepKit.slider(s, amountKey, 0.7),
        StepKit.slider(s, thresholdKey, 0.3, 0, 0.8, advanced: true),
        StepKit.slider(s, hueWidthKey, 0.5, 0, 1, advanced: true),
    ])

    public init() {}

    public func preview(_ image: AstroImage, _ p: StepParameters, _ ct: CancellationToken) throws -> AstroImage {
        if !image.isColor { return image }
        let amount = p.getFloat(Self.amountKey, 0.7)
        let threshold = p.getFloat(Self.thresholdKey, 0.3)
        // Hue window: violet (≈0.72) up to magenta (≈0.92); the width slider widens it.
        let width = p.getFloat(Self.hueWidthKey, 0.5)
        let hueLo: Float = 0.72 - 0.08 * width, hueHi: Float = 0.92 + 0.06 * width
        return try StepKit.mapRgb(image, ct) { r, g, b in
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            let delta = mx - mn
            if delta <= 1e-6 { return (r, g, b) }
            let sat = delta / max(mx, 1e-6)
            let hue: Float = mx == r ? ((g - b) / delta + 6).truncatingRemainder(dividingBy: 6) / 6
                : mx == g ? ((b - r) / delta + 2) / 6 : ((r - g) / delta + 4) / 6
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let w = amount * Self.window(hue, hueLo, hueHi, 0.04) * Self.smoothStep(0.12, 0.35, sat)
                * Self.smoothStep(threshold - 0.1, threshold + 0.1, lum)
            if w <= 0 { return (r, g, b) }
            return (StepKit.lerp(r, lum, w), StepKit.lerp(g, lum, w), StepKit.lerp(b, lum, w))
        }
    }

    /// 1 inside [lo, hi], fading to 0 over `edge` outside it.
    static func window(_ x: Float, _ lo: Float, _ hi: Float, _ edge: Float) -> Float {
        smoothStep(lo - edge, lo, x) * (1 - smoothStep(hi, hi + edge, x))
    }

    static func smoothStep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = ((x - a) / (b - a)).clamped(0, 1)
        return t * t * (3 - 2 * t)
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        if !input.isColor { return .unchanged(input, L.t("msg.fringe.mono")) }
        let output = try preview(input, context.parameters, context.cancellation)
        // How much of the image was touched, for the summary.
        var changed = 0
        let n = input.pixelsPerChannel
        for i in 0 ..< n where input.data[i] != output.data[i] || input.data[n + i] != output.data[n + i] || input.data[2 * n + i] != output.data[2 * n + i] {
            changed += 1
        }
        return StepResult(image: output, summary: L.f("msg.fringe.summary", Double(changed) / Double(n)))
    }
}

/// Step 14: contrast – an S-curve strengthening the midtones, with an optional black-point lift.
public final class ContrastStep: LivePreviewStep {
    public static let amountKey = "amount", blackPointKey = "black"
    private static let s = "contrast"

    public let definition = StepDefinition.fromLanguage(.contrast, .refinement, s, [
        StepKit.slider(s, amountKey, 0.3),
        StepKit.slider(s, blackPointKey, 0.0, 0, 0.15, advanced: true),
    ])

    public init() {}

    public func preview(_ image: AstroImage, _ p: StepParameters, _ ct: CancellationToken) throws -> AstroImage {
        let amount = p.getFloat(Self.amountKey, 0.3)
        let black = p.getFloat(Self.blackPointKey, 0)
        return try StepKit.mapPixels(image, ct) { v, _ in
            var x = black > 0 ? (v - black) / (1 - black) : v
            x = x.clamped(0, 1)
            let s = x * x * (3 - 2 * x)
            return StepKit.lerp(x, s, amount)
        }
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        StepResult(image: try preview(try context.requireInput(), context.parameters, context.cancellation), summary: L.t("msg.contrast.summary"))
    }
}

/// Step 15: colour saturation with the luminance kept.
public final class SaturationStep: LivePreviewStep {
    public static let amountKey = "amount"
    private static let s = "saturation"

    public let definition = StepDefinition.fromLanguage(.saturation, .refinement, s, [StepKit.slider(s, amountKey, 0.25)])

    public init() {}

    public func preview(_ image: AstroImage, _ p: StepParameters, _ ct: CancellationToken) throws -> AstroImage {
        if !image.isColor { return image }
        let gain = 1 + 1.5 * p.getFloat(Self.amountKey, 0.25)
        return try StepKit.mapRgb(image, ct) { r, g, b in
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return ((l + (r - l) * gain).clamped(0, 1), (l + (g - l) * gain).clamped(0, 1), (l + (b - l) * gain).clamped(0, 1))
        }
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        if !input.isColor { return .unchanged(input, L.t("msg.saturation.mono")) }
        return StepResult(image: try preview(input, context.parameters, context.cancellation), summary: L.t("msg.saturation.summary"))
    }
}

/// Step 16: saving in the format that suits the purpose.
public final class SaveStep: WorkflowStep {
    public static let purposeKey = "purpose", folderKey = "folder", fileNameKey = "filename"
    public static let purposeShare = "share", purposePrint = "print", purposeEdit = "edit"
    private static let s = "save"

    public let definition = StepDefinition.fromLanguage(.save, .finish, s, [
        StepKit.choice(s, purposeKey, purposeShare, [purposeShare, purposePrint, purposeEdit]),
        StepKit.folder(s, folderKey),
        StepKit.text(s, fileNameKey, L.t("step.save.defaultName")),
    ])

    public init() {}

    public static func formatFor(_ purpose: String) -> ExportFormat {
        switch purpose {
        case purposePrint: return .tiff16
        case purposeEdit: return .fits
        default: return .jpeg
        }
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        let p = context.parameters
        let format = Self.formatFor(p.getString(Self.purposeKey, Self.purposeShare))
        var folder = p.getString(Self.folderKey).trimmingCharacters(in: .whitespaces)
        if folder.isEmpty {
            folder = context.frames?.folder
                ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!.path
        }
        let defaultName = L.t("step.save.defaultName")
        var name = p.getString(Self.fileNameKey, defaultName).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = defaultName }
        for ch in ["/", ":", "\0"] { name = name.replacingOccurrences(of: ch, with: "_") }

        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name + ImageFiles.extensionFor(format))
        context.report(0.2, L.t("msg.save.saving"))
        try ImageFiles.save(path, input, format)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return StepResult(image: nil, summary: L.f("msg.save.summary", (path as NSString).lastPathComponent, Double(bytes) / 1024 / 1024))
    }
}
