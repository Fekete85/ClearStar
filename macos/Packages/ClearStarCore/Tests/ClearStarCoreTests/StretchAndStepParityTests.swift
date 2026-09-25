import Foundation
import Testing
@testable import ClearStarCore

/// F1 parity: GHS, orientation / crop / coverage, the per-pixel steps and the star recombination.
@Suite struct StretchAndStepParityTests {
    let field: AstroImage

    init() throws { field = try Ref.image("field") }

    @Test func ghsCurves() throws {
        for case let c as [String: Any] in try Ref.json("ghs_curves") as! [Any] {
            let name = c["name"] as! String
            let p = try #require(GhsParams.fromJson(c["json"] as! String), "\(name) json")
            #expect(p.isIdentity == (c["identity"] as! Bool), "\(name) identity")
            let t = GhsTransform(p)
            let curve = nums(c["curve"])
            var worst = 0.0
            for i in 0 ..< curve.count { worst = max(worst, abs(Double(t.apply(Float(i) / 1000)) - curve[i])) }
            #expect(worst <= 2e-6, "\(name): max diff \(worst)")
        }
    }

    @Test func ghsImages() throws {
        let human = GhsParams(.ghs, GhsParams.dFromLog(2.0), 1.5, 0, 0.1, 1, 0, .humanLuminance)
        try expectImage(try GhsTransform.apply(field, human), "ghs_human", tol: 2e-6)
        var even = human; even.colour = .evenLuminance
        try expectImage(try GhsTransform.apply(field, even), "ghs_even", tol: 2e-6)
        var indep = human; indep.colour = .independent
        try expectImage(try GhsTransform.apply(field, indep), "ghs_indep", tol: 2e-6)

        let misc = try Ref.dict("ghs_misc")
        let p = StepParameters()
        p.set(StarlessStretchStep.historyKey, "[]")
        #expect(StarlessStretchStep.commitAuto(p, field))
        let mine = StarlessStretchStep.history(p)
        let theirs = GhsParams.listFromJson(misc["autoHistory"] as? String)
        #expect(mine.count == 1 && theirs.count == 1)
        expectClose(Double(mine[0].d), Double(theirs[0].d), 1e-6, "auto m")
        expectClose(Double(mine[0].sp), Double(theirs[0].sp), 1e-7, "auto shadows")
        for c in 0 ..< 3 {
            expectClose(Double(mine[0].channelMidtones![c]), Double(theirs[0].channelMidtones![c]), 1e-6, "auto m\(c)")
            expectClose(Double(mine[0].channelShadows![c]), Double(theirs[0].channelShadows![c]), 1e-7, "auto s\(c)")
        }
        try expectImage(try GhsTransform.applyAll(field, theirs), "ghs_auto", tol: 2e-6)
        #expect(GhsParams.listFromJson(misc["listJson"] as? String).count == 3)
        #expect(StarlessStretchStep.regionMedian(field, 0.1, 0.2, 0.3, 0.25) == misc.f("regionMedian"))
        let hist = Histogram.compute(field, stride: 2)
        let refHist = (misc["histogram"] as! [[Any]]).map { $0.map { ($0 as! NSNumber).intValue } }
        #expect(hist == refHist)
    }

    @Test func orientation() throws {
        for case let o as [String: Any] in try Ref.json("orient") as! [Any] {
            let angle = o.d("angle")
            let img = CropStep.orient(field, angle, o["fh"] as! Bool, o["fv"] as! Bool)
            try expectImage(img, o["name"] as! String, tol: 1e-6)
            let mine = CropStep.orientedSize(400, 300, angle)
            #expect([Double(mine.width), Double(mine.height)] == nums(o["size"]), "size \(angle)")
        }
        try expectImage(try CropStep.crop(field, 10, 20, 30, 40), "crop", tol: 0)
    }

    @Test func coverage() throws {
        let input = try Ref.image("coverage_input")
        let r = try Ref.dict("coverage")
        let c4 = try #require(Coverage.largestFilledRectangle(input))
        #expect([c4.x, c4.y, c4.w, c4.h] == nums(r["cov"]))
        let c1 = try #require(Coverage.largestFilledRectangle(input, downsample: 1))
        #expect([c1.x, c1.y, c1.w, c1.h] == nums(r["cov1"]))
        #expect((Coverage.largestFilledRectangle(field) == nil) == (r["full"] as! Bool))
    }

    @Test func cropStep() async throws {
        let sel = try await runStep(CropStep(), field) { p in
            p.set(CropStep.rotateKey, "90"); p.set(CropStep.angleKey, 3.0)
            p.set(CropStep.selLeftKey, 0.1); p.set(CropStep.selTopKey, 0.15); p.set(CropStep.selWidthKey, 0.6); p.set(CropStep.selHeightKey, 0.5)
        }
        try expectImage(sel.image!, "cropstep_sel", tol: 1e-6)
        let margin = try await runStep(CropStep(), field) { $0.set(CropStep.marginKey, 0.07) }
        try expectImage(margin.image!, "cropstep_margin", tol: 0)
    }

    @Test func colourSteps() async throws {
        let stretched = try Ref.image("stretched")
        let cases: [(any WorkflowStep, String, Double, String)] = [
            (GreenRemovalStep(), GreenRemovalStep.amountKey, 0.8, "green"),
            (FringeStep(), FringeStep.amountKey, 0.9, "fringe"),
            (ContrastStep(), ContrastStep.amountKey, 0.6, "contrast"),
            (SaturationStep(), SaturationStep.amountKey, 0.5, "saturation"),
        ]
        for (step, key, value, name) in cases {
            let r = try await runStep(step, stretched) { p in
                p.set(key, value)
                if step is ContrastStep { p.set(ContrastStep.blackPointKey, 0.03) }
                if step is FringeStep { p.set(FringeStep.thresholdKey, 0.2); p.set(FringeStep.hueWidthKey, 0.7) }
            }
            try expectImage(r.image!, name, tol: 1e-6)
        }
        let purple = try Ref.image("purple")
        let fr = try await runStep(FringeStep(), purple)
        try expectImage(fr.image!, "fringe_purple", tol: 1e-6)
    }

    @Test func starRecombination() async throws {
        let starless = try Ref.image("starless"), stars = try Ref.image("starslayer"), stretched = try Ref.image("stretched")
        let hist = GhsParams.listFromJson(try Ref.dict("ghs_misc")["autoHistory"] as? String)
        let starlessStretched = try GhsTransform.applyAll(starless, hist)
        try expectImage(try StarStretchStep.fullStrengthStars(starless, stars, starlessStretched, hist, .none), "fullstrength", tol: 2e-6)
        try expectImage(try StarStretchStep.addStars(starlessStretched, stretched, 0.6, .none), "addstars", tol: 2e-6)
        let mtf = try await runStep(StarStretchStep(), field)
        try expectImage(mtf.image!, "starstretch_mtf", tol: 2e-6)
    }

    @Test func objectNames() throws {
        for case let n as [String: Any] in try Ref.json("names") as! [Any] {
            #expect(ObjectNameGuess.fromText(n["s"] as! String) == n["guess"] as? String, "\(n)")
        }
    }

    @Test(.enabled(if: TestEnv.hasRealData)) func realFrameSet() throws {
        let r = try Ref.dict("frameset", real: true)
        let fs = try FrameSet.scan(TestEnv.m31.path)
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
        let frame0 = try ImageFiles.load(fs.lights[0].path)
        try expectImage(frame0, "frame0", tol: 0, real: true)
    }
}
