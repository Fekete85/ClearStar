import Foundation
import Testing
@testable import ClearStarCore

/// The whole 16-step chain in Swift on every real data set: Core ML networks, the offline catalogue,
/// StarNet2 through the stand-in program, saving. Checks that every step runs and the result is sane.
@Suite(.serialized, .globalState) struct FullChainTests {
    @Test(.enabled(if: AiTests.hasModels && FileManager.default.fileExists(atPath: TestEnv.catalog.path)), arguments: TestEnv.dataSets)
    func wholeChain(_ set: DataSet) async throws {
        _ = TestEnv.setUp
        CoreMLRunner.gpuEnabled = true
        PlateSolveStep.catalog = try #require(LocalGaiaCatalog.open(TestEnv.catalog.path))
        ColorCalibrationStep.onlineCatalog = AstrometryTests.FixedCatalog(stars: nil)   // offline: the plate solve's catalogue
        StarNet.setExecutable(AiTests.stub.path)
        defer {
            StarNet.setExecutable(nil)
            PlateSolveStep.catalog = AutoStarCatalog()
            ColorCalibrationStep.onlineCatalog = GaiaOnlineCatalog(useVizierFallback: false, timeout: 10)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }

        let wf = StepCatalog.createWorkflow()
        wf[.loadFrames].parameters.set(LoadFramesStep.folderKey, set.frames.path)
        wf[.crop].parameters.set(CropStep.marginKey, 0.05)
        wf[.backgroundExtraction].parameters.set(BackgroundExtractionStep.modelKey, AiTests.model("bge", "1.0.1"))
        wf[.deconvolution].parameters.set(DeconvolutionStep.starsModelKey, AiTests.model("deconvolution-stars", "1.0.0"))
        wf[.deconvolution].parameters.set(DeconvolutionStep.objectModelKey, AiTests.model("deconvolution-object", "1.0.1"))
        wf[.denoise].parameters.set(DenoiseStep.modelKey, AiTests.model("denoise", "3.0.2"))
        if let o = set.object { wf[.plateSolve].parameters.set(PlateSolveStep.objectKey, o) }
        let solvable = (try? Ref.dict("s07_platesolve", in: set))?["error"] == nil
        wf[.save].parameters.set(SaveStep.folderKey, out.path)
        wf[.save].parameters.set(SaveStep.fileNameKey, "final")
        wf[.save].parameters.set(SaveStep.purposeKey, SaveStep.purposePrint)

        for entry in wf.steps {
            let started = Date()
            // A set the C# run could not plate solve (no centre / scale): those two steps are skipped, like a user would.
            if !solvable && (entry.id == .plateSolve || entry.id == .colorCalibration) {
                try wf.skip(entry.id)
                continue
            }
            // A set whose sky the C# chain does not identify after the AI steps either: the same error, then skipped.
            if !set.chainSolves && entry.id == .plateSolve {
                await #expect(throws: ClearStarError.self) { try await wf.run(entry.id) }
                try wf.skip(.plateSolve)
                try wf.skip(.colorCalibration)
                continue
            }
            if !set.chainSolves && entry.id == .colorCalibration { continue }
            if entry.id == .starlessStretch, let current = wf.current {
                // As the CLI and the app's wand: auto stretch, then the (empty) sliders committed.
                StarlessStretchStep.commitAuto(entry.parameters, current)
                StarlessStretchStep.commit(entry.parameters)
            }
            let r = try await wf.run(entry.id)
            print(String(format: "%@ %2d. %-28@ %6.1f s  %@", set.folder, entry.definition.number, entry.definition.name, Date().timeIntervalSince(started), r.summary))
            #expect(wf[entry.id].state == .done)
        }
        #expect(wf.doneCount == 16)
        let final = try #require(wf.current)
        #expect(!final.data.contains { $0.isNaN })
        let stats = ImageStats.computeAll(final)
        #expect(stats.allSatisfy { $0.median > 0.05 && $0.median < 0.6 }, "final medians \(stats.map(\.median))")
        #expect(StarLayerStore.hasStretched(for: wf.imageBefore(.starStretch)!))
        let saved = try ImageFiles.load(out.appendingPathComponent("final.tif").path)
        #expect(saved.width == final.width && saved.height == final.height)
        if solvable && set.chainSolves { #expect(wf.imageAfter(.plateSolve)?.header["PLTSOLVD"] == "T") }
    }
}
