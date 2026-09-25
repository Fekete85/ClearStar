import Foundation

public enum StepState: Sendable {
    /// Has not run yet.
    case pending
    /// Ran, its result is valid.
    case done
    /// The user skipped it.
    case skipped
    /// Ran, but an earlier step changed since – has to run again.
    case stale
}

public struct ProgressInfo: Sendable {
    public var fraction: Double
    public var message: String
    public init(_ fraction: Double, _ message: String) { self.fraction = fraction; self.message = message }
}

/// What a step gets to run: the input image and the loaded files.
public struct WorkflowContext: Sendable {
    public var input: AstroImage?
    public var frames: FrameSet?
    public var parameters: StepParameters
    public var progress: (@Sendable (ProgressInfo) -> Void)?
    public var cancellation: CancellationToken

    public init(input: AstroImage?, frames: FrameSet?, parameters: StepParameters,
                progress: (@Sendable (ProgressInfo) -> Void)? = nil, cancellation: CancellationToken = .none) {
        self.input = input; self.frames = frames; self.parameters = parameters; self.progress = progress; self.cancellation = cancellation
    }

    public func requireInput() throws -> AstroImage {
        guard let input else { throw ClearStarError(L.t("msg.workflow.needImage")) }
        return input
    }

    public func report(_ fraction: Double, _ message: String) { progress?(ProgressInfo(fraction, message)) }
}

/// How one input frame fared in the stack and its quality figures. Plotted in time order they show
/// when the sky got worse during the night (cloud, dew, field rotation, light pollution).
public struct FrameNote: Sendable, Equatable {
    public var used: Bool
    public var text: String
    public var stars: Int?
    public var starSize: Float?
    public var background: Float?
    public var angle: Float?
    public init(used: Bool, text: String, stars: Int? = nil, starSize: Float? = nil, background: Float? = nil, angle: Float? = nil) {
        self.used = used; self.text = text; self.stars = stars; self.starSize = starSize; self.background = background; self.angle = angle
    }
}

/// A step's result: the new image (nil when the step does not produce one), a short summary and
/// optionally per-frame notes (file → state, e.g. "aligned" / "skipped").
public struct StepResult: Sendable {
    public var image: AstroImage?
    public var summary: String
    public var frames: FrameSet?
    public var frameNotes: [String: FrameNote]?

    public init(image: AstroImage?, summary: String, frames: FrameSet? = nil, frameNotes: [String: FrameNote]? = nil) {
        self.image = image; self.summary = summary; self.frames = frames; self.frameNotes = frameNotes
    }

    public static func unchanged(_ image: AstroImage, _ summary: String) -> StepResult { StepResult(image: image, summary: summary) }
}

/// One workflow step. A step must not modify its input image.
public protocol WorkflowStep: AnyObject, Sendable {
    var definition: StepDefinition { get }
    /// True when the step really does something (unfinished steps pass the image through).
    var isImplemented: Bool { get }
    func run(_ context: WorkflowContext) async throws -> StepResult
}

extension WorkflowStep {
    public var isImplemented: Bool { true }
}

/// A step whose effect is cheap and purely per pixel, so the app can preview the sliders live on the
/// downsampled image: `preview` applies the same transform `run` would.
public protocol LivePreviewStep: WorkflowStep {
    func preview(_ image: AstroImage, _ parameters: StepParameters, _ ct: CancellationToken) throws -> AstroImage
}
