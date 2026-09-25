import Foundation
import Testing
@testable import ClearStarCore

/// The whole 16-step chain in Swift on the real M31 frames: Core ML networks, the offline catalogue,
/// StarNet2 through the stand-in program, saving. Checks that every step runs and the result is sane.
@Suite(.serialized) struct FullChainTests {
    @Test(.enabled(if: TestEnv.hasRealData && AiTests.hasModels && FileManager.default.fileExists(atPath: TestEnv.catalog.path)))
    func wholeChainOnM31() async throws {
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
        wf[.loadFrames].parameters.set(LoadFramesStep.folderKey, TestEnv.m31.path)
        wf[.crop].parameters.set(CropStep.marginKey, 0.05)
        wf[.backgroundExtraction].parameters.set(BackgroundExtractionStep.modelKey, AiTests.model("bge", "1.0.1"))
        wf[.deconvolution].parameters.set(DeconvolutionStep.starsModelKey, AiTests.model("deconvolution-stars", "1.0.0"))
        wf[.deconvolution].parameters.set(DeconvolutionStep.objectModelKey, AiTests.model("deconvolution-object", "1.0.1"))
        wf[.denoise].parameters.set(DenoiseStep.modelKey, AiTests.model("denoise", "3.0.2"))
        wf[.plateSolve].parameters.set(PlateSolveStep.objectKey, "M 31")
        wf[.save].parameters.set(SaveStep.folderKey, out.path)
        wf[.save].parameters.set(SaveStep.fileNameKey, "final")
        wf[.save].parameters.set(SaveStep.purposeKey, SaveStep.purposePrint)

        for entry in wf.steps {
            let started = Date()
            if entry.id == .starlessStretch, let current = wf.current {
                // As the CLI and the app's wand: auto stretch, then the (empty) sliders committed.
                #expect(StarlessStretchStep.commitAuto(entry.parameters, current))
                StarlessStretchStep.commit(entry.parameters)
            }
            let r = try await wf.run(entry.id)
            print(String(format: "%2d. %-28@ %6.1f s  %@", entry.definition.number, entry.definition.name, Date().timeIntervalSince(started), r.summary))
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
        #expect(wf.imageAfter(.plateSolve)?.header["PLTSOLVD"] == "T")
    }
}
