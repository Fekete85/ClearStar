import Foundation
import Testing
@testable import ClearStarCore

/// Swift counterparts of the C# workflow tests (RerunningEarlierStepMarksLaterStale, SkippedStepIsBypassed,
/// SnapshotStoreSpillsToDiskAndReloads) plus the parameter model.
@Suite struct WorkflowTests {
    init() { _ = TestEnv.setUp }

    /// A step that adds a constant to the image (or produces a 16×16 grey image when it gets none).
    final class AddStep: WorkflowStep {
        let definition: StepDefinition
        let amount: Float
        init(_ id: StepId, _ amount: Float) {
            definition = StepDefinition(id: id, group: id.group, name: "\(id)", technicalName: nil, description: "", parameters: [])
            self.amount = amount
        }
        func run(_ context: WorkflowContext) async throws -> StepResult {
            let src = context.input ?? AstroImage(width: 16, height: 16, channels: 1, data: [Float](repeating: 0.1, count: 256))
            let out = src.clone()
            for i in 0 ..< out.data.count { out.data[i] += amount }
            return StepResult(image: out, summary: "+\(amount)")
        }
    }

    private func makeWorkflow() -> Workflow {
        Workflow([AddStep(.loadFrames, 0), AddStep(.stack, 0.1), AddStep(.crop, 0.1), AddStep(.backgroundExtraction, 0.1), AddStep(.deconvolution, 0.1)])
    }

    @Test func rerunningEarlierStepMarksLaterStale() async throws {
        let wf = makeWorkflow()
        for id in [StepId.loadFrames, .stack, .crop, .backgroundExtraction] { try await wf.run(id) }
        #expect(wf[.backgroundExtraction].state == .done)
        try await wf.run(.crop)
        #expect(wf[.backgroundExtraction].state == .stale)
        #expect(wf.nextPending == .backgroundExtraction)
        // The stale step no longer counts: the current image is the re-run crop (0.1 + 0.1 + 0.1).
        expectClose(Double(wf.current!.data[0]), 0.3, 1e-6, "current after rerun")
    }

    @Test func skippedStepIsBypassed() async throws {
        let wf = makeWorkflow()
        for id in [StepId.loadFrames, .stack] { try await wf.run(id) }
        try wf.skip(.crop)
        try await wf.run(.backgroundExtraction)
        // stack gives 0.2, crop skipped, background adds 0.1
        expectClose(Double(wf.current!.data[0]), 0.3, 1e-6, "bypassed")
        #expect(wf.doneCount == 4)
        #expect(throws: ClearStarError.self) { try wf.skip(.stack) }
        wf.reopen(.crop)
        #expect(wf[.crop].state == .pending)
        wf.reset()
        #expect(wf.current == nil && wf.doneCount == 0)
    }

    @Test func imageBeforeAndAfter() async throws {
        let wf = makeWorkflow()
        for id in [StepId.loadFrames, .stack, .crop] { try await wf.run(id) }
        expectClose(Double(wf.imageBefore(.crop)!.data[0]), 0.2, 1e-6, "before")
        expectClose(Double(wf.imageAfter(.crop)!.data[0]), 0.3, 1e-6, "after")
        expectClose(Double(wf.imageAfter(.deconvolution)!.data[0]), 0.3, 1e-6, "after not run")
        #expect(wf.lastImageStepBefore(.backgroundExtraction) == .crop)
        expectClose(Double(wf.original!.data[0]), 0.1, 1e-6, "original")
        #expect(Workflow.isLinearPhase(.crop) && !Workflow.isLinearPhase(.starlessStretch))
    }

    @Test func snapshotStoreSpillsToDiskAndReloads() {
        let store = SnapshotStore(memoryLimit: 2)
        for k in 1 ... 4 {
            let img = AstroImage(width: 8, height: 8, channels: 3, data: [Float](repeating: Float(k), count: 192))
            img.header["KEY"] = "\(k)"
            store.put(k, img)
        }
        #expect(store.diskCount == 2)
        let first = store.get(1)
        #expect(first?.data[5] == 1 && first?.header["KEY"] == "1")
        #expect(store.contains(3) && !store.contains(9))
        store.remove(1)
        #expect(!store.contains(1))
        store.clear()
        #expect(store.get(2) == nil)
    }

    @Test func parameters() {
        let p = StepParameters(CropStep().definition.parameters)
        #expect(p.getDouble(CropStep.marginKey) == 0)
        p.set("MARGIN", 0.1)
        #expect(p.getDouble(CropStep.marginKey) == 0.1)
        p.set("x", "2.5")
        #expect(p.getDouble("x") == 2.5)
        p.set("b", "True")
        #expect(p.getBool("b"))
        let c = p.clone()
        #expect(c.valuesEqual(p))
        c.set("x", 3.0)
        #expect(!c.valuesEqual(p))
        #expect(StepParameters().getString("missing", "d") == "d")
    }

    @Test func stepDefinitionsAreLocalizedAndChoicesAreKeys() {
        for step in StepCatalog.createAll() {
            let d = step.definition
            #expect(!d.name.hasPrefix("step."), "\(d.id) name")
            for p in d.parameters where p.kind != .hidden {
                #expect(!p.label.hasPrefix("step."), "\(d.id).\(p.key) label")
                if let choices = p.choices { #expect(choices.allSatisfy { !$0.contains(" ") }) }
            }
        }
    }

    @Test func settingsRoundTrip() {
        UserSettings.set("test.key", "value")
        #expect(UserSettings.get("test.key") == "value")
        UserSettings.set("test.key", nil)
        #expect(UserSettings.get("test.key") == nil)
    }

    @Test func realLoadStep() async throws {
        guard TestEnv.hasRealData else { return }
        let r = try await runStep(LoadFramesStep(), nil) { $0.set(LoadFramesStep.folderKey, TestEnv.m31.path) }
        #expect(r.frames?.lights.count == 63)
        #expect(r.summary.contains("63"))
    }
}
