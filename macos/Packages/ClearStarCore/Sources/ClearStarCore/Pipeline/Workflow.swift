import Foundation

/// One step's run-time state in the workflow.
public final class WorkflowEntry: @unchecked Sendable {
    public let step: any WorkflowStep
    public var definition: StepDefinition { step.definition }
    public var id: StepId { definition.id }
    public let parameters: StepParameters
    public internal(set) var state: StepState = .pending
    public internal(set) var summary: String?
    public internal(set) var lastDuration: TimeInterval?
    /// What it last ran with – shows whether the settings changed since.
    public internal(set) var appliedParameters: StepParameters?

    init(_ step: any WorkflowStep) {
        self.step = step
        self.parameters = StepParameters(step.definition.parameters)
    }

    public var hasUnappliedChanges: Bool {
        state == .done && appliedParameters.map { !$0.valuesEqual(parameters) } == true
    }
}

/// The engine of the guided process: runs the steps in order, keeps each step's result, and knows
/// which results became stale because an earlier step ran again.
public final class Workflow: @unchecked Sendable {
    private let snapshots: SnapshotStore
    private let entries: [StepId: WorkflowEntry]

    public let steps: [WorkflowEntry]
    public private(set) var frames: FrameSet?

    /// Called whenever any step's state or result changed.
    public var changed: (() -> Void)?

    public init(_ steps: [any WorkflowStep], snapshots: SnapshotStore? = nil) {
        precondition(!steps.isEmpty, L.t("msg.workflow.oneStep"))
        self.snapshots = snapshots ?? SnapshotStore()
        self.steps = steps.map(WorkflowEntry.init).sorted { $0.id.rawValue < $1.id.rawValue }
        self.entries = Dictionary(uniqueKeysWithValues: self.steps.map { ($0.id, $0) })
    }

    public subscript(id: StepId) -> WorkflowEntry { entries[id]! }

    /// The starting image: the stack (or the single loaded image).
    public var original: AstroImage? { firstImageStep().flatMap { snapshots.get($0.rawValue) } }

    public var hasImage: Bool { original != nil }

    /// The latest valid (done) step's image – the "current" image.
    public var current: AstroImage? { latestDoneImageStep(before: .save).flatMap { snapshots.get($0.rawValue) } }

    /// The image as it looked after the step (or after the latest valid earlier step when this one did not run).
    public func imageAfter(_ id: StepId) -> AstroImage? {
        latestDoneImageStep(beforeRaw: id.rawValue + 1).flatMap { snapshots.get($0.rawValue) }
    }

    /// The image the step would get as its input.
    public func imageBefore(_ id: StepId) -> AstroImage? { latestDoneImageStep(before: id).flatMap { snapshots.get($0.rawValue) } }

    /// The most recent step before `id` that produced an image.
    public func lastImageStepBefore(_ id: StepId) -> StepId? { latestDoneImageStep(before: id) }

    /// In the linear phase (before the stretch) the screen shows the image with an automatic stretch.
    public static func isLinearPhase(_ id: StepId) -> Bool { id.rawValue < StepId.starlessStretch.rawValue }

    /// The next thing to do: the first step that is neither done nor skipped.
    public var nextPending: StepId { steps.first { $0.state == .pending || $0.state == .stale }?.id ?? .save }

    public var doneCount: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }

    @discardableResult
    public func run(_ id: StepId, progress: (@Sendable (ProgressInfo) -> Void)? = nil, cancellation: CancellationToken = .none) async throws -> StepResult {
        let entry = entries[id]!
        let context = WorkflowContext(input: id == .loadFrames ? nil : imageBefore(id), frames: frames,
                                      parameters: entry.parameters.clone(), progress: progress, cancellation: cancellation)
        if id.rawValue > StepId.stack.rawValue && context.input == nil { throw ClearStarError(L.t("msg.workflow.needStack")) }

        let started = Date()
        let result = try await entry.step.run(context)
        try cancellation.check()

        if let f = result.frames { frames = f }
        if let img = result.image { snapshots.put(id.rawValue, img) } else { snapshots.remove(id.rawValue) }

        entry.state = .done
        entry.summary = result.summary
        entry.lastDuration = Date().timeIntervalSince(started)
        entry.appliedParameters = context.parameters

        // Stale intermediate steps are no longer part of the chain: marked skipped.
        for e in steps where e.id.rawValue < id.rawValue && e.state == .stale {
            e.state = .skipped
            snapshots.remove(e.id.rawValue)
        }
        invalidateAfter(id)
        changed?()
        return result
    }

    public func skip(_ id: StepId) throws {
        if id == .loadFrames || id == .stack { throw ClearStarError(L.t("msg.workflow.cannotSkip")) }
        let entry = entries[id]!
        let hadImage = snapshots.contains(id.rawValue)
        entry.state = .skipped
        entry.summary = nil
        entry.appliedParameters = nil
        snapshots.remove(id.rawValue)
        if hadImage { invalidateAfter(id) }
        changed?()
    }

    /// A skipped or stale step back to "to do" (does not run it).
    public func reopen(_ id: StepId) {
        let entry = entries[id]!
        if entry.state == .skipped || entry.state == .stale {
            entry.state = .pending
            changed?()
        }
    }

    public func reset() {
        for e in steps {
            e.state = .pending
            e.summary = nil
            e.appliedParameters = nil
        }
        frames = nil
        snapshots.clear()
        changed?()
    }

    private func invalidateAfter(_ id: StepId) {
        for e in steps where e.id.rawValue > id.rawValue && e.state == .done {
            e.state = .stale
            snapshots.remove(e.id.rawValue)
        }
    }

    private func firstImageStep() -> StepId? {
        steps.first { $0.state == .done && snapshots.contains($0.id.rawValue) }?.id
    }

    /// The latest done step with an image whose id is lower than the given one.
    private func latestDoneImageStep(before: StepId) -> StepId? { latestDoneImageStep(beforeRaw: before.rawValue) }

    private func latestDoneImageStep(beforeRaw: Int) -> StepId? {
        for e in steps.reversed() where e.id.rawValue < beforeRaw && e.state == .done && snapshots.contains(e.id.rawValue) {
            return e.id
        }
        return nil
    }
}
