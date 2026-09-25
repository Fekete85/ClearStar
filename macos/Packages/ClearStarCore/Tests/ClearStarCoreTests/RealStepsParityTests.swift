import Foundation
import Testing
@testable import ClearStarCore

/// Parity on the real M31 data: every step gets the C# result of the previous step as its input and
/// must produce the C# result of its own (testdata/reference/m31, made by make-references.sh).
@Suite(.enabled(if: TestEnv.hasRealData)) struct RealStepsParityTests {
    init() { _ = TestEnv.setUp }

    @Test func crop() async throws {
        let stack = try Ref.image("stack", real: true)
        let r = try await runStep(CropStep(), stack) { $0.set(CropStep.marginKey, 0.05) }
        try expectImage(r.image!, "s03_crop", tol: 0, real: true)
    }

    @Test func stretchAndFinishing() async throws {
        let calibrated = try Ref.image("s08_colorcal", real: true)
        // The stretch history the C# run committed (auto stretch), replayed by the step.
        let history = try Ref.text("s10_history.json", real: true)
        let p = StepParameters()
        p.set(StarlessStretchStep.historyKey, "[]")
        #expect(StarlessStretchStep.commitAuto(p, calibrated))
        let mine = StarlessStretchStep.history(p)[0], theirs = GhsParams.listFromJson(history)[0]
        expectClose(Double(mine.d), Double(theirs.d), 1e-6, "auto m")
        expectClose(Double(mine.sp), Double(theirs.sp), 1e-6, "auto shadows")
        let ghs = try await runStep(StarlessStretchStep(), calibrated) { $0.set(StarlessStretchStep.historyKey, history) }
        try expectImage(ghs.image!, "s10_ghs", tol: 2e-6, real: true)

        let stretched = try Ref.image("s10_ghs", real: true)
        let star = try await runStep(StarStretchStep(), stretched)
        try expectImage(star.image!, "s11_starstretch", tol: 0, real: true)
        let starMtf = try await runStep(StarStretchStep(), calibrated)
        try expectImage(starMtf.image!, "s11_starstretch_mtf", tol: 2e-6, real: true)

        let green = try await runStep(GreenRemovalStep(), stretched)
        try expectImage(green.image!, "s12_green", tol: 1e-6, real: true)
        let fringe = try await runStep(FringeStep(), try Ref.image("s12_green", real: true))
        try expectImage(fringe.image!, "s13_fringe", tol: 1e-6, real: true)
        #expect(fringe.summary.count > 0)
        let contrast = try await runStep(ContrastStep(), try Ref.image("s13_fringe", real: true))
        try expectImage(contrast.image!, "s14_contrast", tol: 1e-6, real: true)
        let saturation = try await runStep(SaturationStep(), try Ref.image("s14_contrast", real: true))
        try expectImage(saturation.image!, "s15_saturation", tol: 1e-6, real: true)
    }

    @Test func saveFormats() async throws {
        let final = try Ref.image("s15_saturation", real: true)
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
                let theirs = try ImageFiles.load(Ref.url("s16_final.tif", real: true).path)
                #expect(maxDiff(back, theirs) <= 0.5 / 255 + 1e-6)
            }
        }
    }
}
