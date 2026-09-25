import Foundation
import Testing
@testable import ClearStarCore

/// Parity on the real data sets (M31, M99, NGC6992): every step gets the C# result of the previous step as
/// its input and must produce the C# result of its own (testdata/reference/<set>, made by make-references.sh).
@Suite struct RealStepsParityTests {
    init() { _ = TestEnv.setUp }

    @Test(arguments: TestEnv.dataSets) func frameSet(_ set: DataSet) throws {
        let r = try Ref.dict("frameset", in: set)
        let fs = try FrameSet.scan(set.frames.path)
        let refFrames = r.arr("frames") as! [[String: Any]]
        #expect(fs.frames.count == refFrames.count)
        for (mine, theirs) in zip(fs.frames, refFrames) {
            #expect(mine.path.hasSuffix(theirs["name"] as! String))
            #expect(mine.type.rawValue == theirs["type"] as! String)
            #expect(mine.exposureSeconds == theirs.d("ExposureSeconds"))
            #expect(mine.width == theirs["Width"] as! Int && mine.height == theirs["Height"] as! Int)
            #expect(mine.filter == theirs["Filter"] as? String)
            #expect(mine.objectName == theirs["ObjectName"] as? String)
        }
        #expect(ObjectNameGuess.from(fs) == r["guess"] as? String)
        #expect(LoadFramesStep.describe(fs).count > 0)
        try expectImage(try ImageFiles.load(fs.lights[0].path), "frame0", tol: 0, in: set)
    }

    @Test(arguments: TestEnv.dataSets) func crop(_ set: DataSet) async throws {
        let stack = try Ref.image("stack", in: set)
        let r = try await runStep(CropStep(), stack) { $0.set(CropStep.marginKey, 0.05) }
        try expectImage(r.image!, "s03_crop", tol: 0, in: set)
    }

    @Test(arguments: TestEnv.dataSets) func stretchAndFinishing(_ set: DataSet) async throws {
        let calibrated = try Ref.image("s08_colorcal", in: set)
        // The stretch history the C# run committed (auto stretch), replayed by the step.
        let history = try Ref.text("s10_history.json", in: set)
        let p = StepParameters()
        p.set(StarlessStretchStep.historyKey, "[]")
        let committed = StarlessStretchStep.commitAuto(p, calibrated)
        let theirs = GhsParams.listFromJson(history)
        #expect(committed == !theirs.isEmpty)
        if committed, let mine = StarlessStretchStep.history(p).first, let t = theirs.first {
            expectClose(Double(mine.d), Double(t.d), 1e-6, "auto m")
            expectClose(Double(mine.sp), Double(t.sp), 1e-6, "auto shadows")
        }
        let ghs = try await runStep(StarlessStretchStep(), calibrated) { $0.set(StarlessStretchStep.historyKey, history) }
        try expectImage(ghs.image!, "s10_ghs", tol: 2e-6, in: set)

        let stretched = try Ref.image("s10_ghs", in: set)
        let star = try await runStep(StarStretchStep(), stretched)
        try expectImage(star.image!, "s11_starstretch", tol: 2e-6, in: set)
        let starMtf = try await runStep(StarStretchStep(), calibrated)
        try expectImage(starMtf.image!, "s11_starstretch_mtf", tol: 2e-6, in: set)

        let green = try await runStep(GreenRemovalStep(), stretched)
        try expectImage(green.image!, "s12_green", tol: 1e-6, in: set)
        let fringe = try await runStep(FringeStep(), try Ref.image("s12_green", in: set))
        try expectImage(fringe.image!, "s13_fringe", tol: 1e-6, in: set)
        let contrast = try await runStep(ContrastStep(), try Ref.image("s13_fringe", in: set))
        try expectImage(contrast.image!, "s14_contrast", tol: 1e-6, in: set)
        let saturation = try await runStep(SaturationStep(), try Ref.image("s14_contrast", in: set))
        try expectImage(saturation.image!, "s15_saturation", tol: 1e-6, in: set)
    }

    @Test(arguments: TestEnv.dataSets) func saveFormats(_ set: DataSet) async throws {
        let final = try Ref.image("s15_saturation", in: set)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (purpose, ext) in [(SaveStep.purposeShare, "jpg"), (SaveStep.purposePrint, "tif"), (SaveStep.purposeEdit, "fits")] {
            let r = try await runStep(SaveStep(), final) { p in
                p.set(SaveStep.purposeKey, purpose); p.set(SaveStep.folderKey, dir.path); p.set(SaveStep.fileNameKey, "final")
            }
            #expect(r.image == nil && r.summary.contains("final.\(ext)"))
            let back = try ImageFiles.load(dir.appendingPathComponent("final.\(ext)").path)
            #expect(back.width == final.width && back.height == final.height)
            if ext == "fits" { #expect(maxDiff(back, final) == 0) }
            if ext == "tif" {
                // A real 16-bit TIFF (D5: the Windows build's ImageSharp writes 8 bits despite Bit48), so it
                // matches the float image to 16-bit precision and the C# TIFF to 8-bit precision.
                #expect(maxDiff(back, final) <= 0.5 / 65535 + 1e-7)
                let theirs = try ImageFiles.load(Ref.url("s16_final.tif", in: set).path)
                #expect(maxDiff(back, theirs) <= 0.5 / 255 + 1e-6)
            }
        }
    }
}
