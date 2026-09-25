import Foundation

/// Parameter factories (labels from the language database: step.&lt;step&gt;.&lt;param&gt;.label / .help /
/// .ticks, choice labels step.&lt;step&gt;.&lt;param&gt;.&lt;value&gt;) and per-pixel helpers – the C# StepBase.
public enum StepKit {
    static func label(_ step: String, _ key: String) -> String { L.t("step.\(step).\(key).label") }
    static func help(_ step: String, _ key: String) -> String? { L.has("step.\(step).\(key).help") ? L.t("step.\(step).\(key).help") : nil }

    public static func slider(_ step: String, _ key: String, _ def: Double, _ min: Double = 0, _ max: Double = 1, advanced: Bool = false) -> ParameterDefinition {
        ParameterDefinition(key: key, label: label(step, key), kind: .slider, defaultValue: .number(def), min: min, max: max,
                            tickLabels: L.a("step.\(step).\(key).ticks"), advanced: advanced, help: help(step, key))
    }

    public static func toggle(_ step: String, _ key: String, _ def: Bool, advanced: Bool = false) -> ParameterDefinition {
        ParameterDefinition(key: key, label: label(step, key), kind: .toggle, defaultValue: .bool(def), advanced: advanced, help: help(step, key))
    }

    public static func choice(_ step: String, _ key: String, _ def: String, _ values: [String], advanced: Bool = false) -> ParameterDefinition {
        ParameterDefinition(key: key, label: label(step, key), kind: .choice, defaultValue: .text(def), choices: values, advanced: advanced,
                            help: help(step, key), choiceLabels: values.map { L.t("step.\(step).\(key).\($0)") })
    }

    public static func folder(_ step: String, _ key: String, _ def: String = "") -> ParameterDefinition {
        ParameterDefinition(key: key, label: label(step, key), kind: .folder, defaultValue: .text(def))
    }

    public static func text(_ step: String, _ key: String, _ def: String = "") -> ParameterDefinition {
        ParameterDefinition(key: key, label: label(step, key), kind: .text, defaultValue: .text(def))
    }

    public static func model(_ step: String, _ key: String, tag: String, advanced: Bool = false) -> ParameterDefinition {
        ParameterDefinition(key: key, label: label(step, key), kind: .model, defaultValue: .text(""), advanced: advanced, help: help(step, key), tag: tag)
    }

    public static func hidden(_ key: String, _ def: ParameterValue) -> ParameterDefinition {
        ParameterDefinition(key: key, label: "", kind: .hidden, defaultValue: def)
    }

    /// Per-pixel operation per channel, rows in parallel.
    public static func mapPixels(_ input: AstroImage, _ ct: CancellationToken, _ fn: (Float, Int) -> Float) throws -> AstroImage {
        let output = input.createEmptyLike()
        let n = input.pixelsPerChannel, w = input.width
        try input.data.withUnsafeBufferPointer { src in
            try output.data.withUnsafeMutableBufferPointer { dst in
                for c in 0 ..< input.channels {
                    let offset = c * n
                    try parallelFor(input.height, ct) { y in
                        let start = offset + y * w
                        for i in start ..< start + w { dst[i] = fn(src[i], c) }
                    }
                }
            }
        }
        return output
    }

    /// Per-pixel RGB operation (the three channels together).
    public static func mapRgb(_ input: AstroImage, _ ct: CancellationToken, _ fn: (Float, Float, Float) -> (Float, Float, Float)) throws -> AstroImage {
        if input.channels != 3 { return input.clone() }
        let output = input.createEmptyLike()
        let n = input.pixelsPerChannel, w = input.width
        try input.data.withUnsafeBufferPointer { src in
            try output.data.withUnsafeMutableBufferPointer { dst in
                try parallelFor(input.height, ct) { y in
                    for i in y * w ..< (y + 1) * w {
                        let (r, g, b) = fn(src[i], src[n + i], src[2 * n + i])
                        dst[i] = r; dst[n + i] = g; dst[2 * n + i] = b
                    }
                }
            }
        }
        return output
    }

    @inline(__always) public static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}

/// A step not ported yet: passes the image through so the process can be walked.
public final class NotImplementedStep: WorkflowStep {
    public let definition: StepDefinition
    public var isImplemented: Bool { false }

    public init(_ id: StepId) {
        definition = .fromLanguage(id, id.group, id.languageKey, [])
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        .unchanged(try context.requireInput(), L.t("msg.notImplemented"))
    }
}
