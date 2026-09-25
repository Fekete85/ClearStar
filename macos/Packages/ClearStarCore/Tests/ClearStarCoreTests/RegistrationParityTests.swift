import Foundation
import Testing
@testable import ClearStarCore

/// F2 parity: star detection, matching, warping, the background polynomial and the stack.
@Suite struct RegistrationParityTests {
    let field: AstroImage
    let r: [String: Any]

    init() throws {
        field = try Ref.image("field")
        r = try Ref.dict("stars")
    }

    private func expectStars(_ mine: [Star], _ ref: Any?, _ what: String, tol: Float = 1e-4) {
        let theirs = (ref as? [Any] ?? []).map { nums($0).map { Float($0) } }
        #expect(mine.count == theirs.count, "\(what): \(mine.count) vs \(theirs.count) stars")
        for (a, b) in zip(mine, theirs) {
            let ok = abs(a.x - b[0]) <= tol && abs(a.y - b[1]) <= tol && abs(a.flux - b[2]) <= tol * max(1, b[2]) && abs(a.size - b[3]) <= tol
            #expect(ok, "\(what): \(a) vs \(b)")
            if !ok { break }
        }
    }

    private func expectTransform(_ t: SimilarityTransform?, _ ref: Any?, _ what: String, tol: Float = 1e-4) {
        guard let d = ref as? [String: Any] else { #expect(t == nil, "\(what) should be nil"); return }
        guard let t else { Issue.record("\(what) is nil"); return }
        #expect(abs(t.scale - d.f("Scale")) <= tol && abs(t.angle - d.f("Angle")) <= tol && abs(t.tx - d.f("Tx")) <= tol * 10 && abs(t.ty - d.f("Ty")) <= tol * 10,
                "\(what): \(t) vs \(d)")
    }

    @Test func detection() throws {
        let (stars, total) = try StarDetector.detectCounting(field)
        #expect(total == r["total"] as! Int)
        expectStars(stars, r["stars"], "stars")
        expectStars(try StarDetector.detect(field, maxStars: 400, thresholdSigma: 6, downsample: 1), r["stars1"], "stars1")
        let mono = try Ref.image("field_mono")
        let (sm, tm) = try StarDetector.detectCounting(mono, maxStars: 100, thresholdSigma: 4, downsample: 3)
        #expect(tm == r["totalMono"] as! Int)
        expectStars(sm, r["starsMono"], "starsMono")
        expectClose(Double(try PsfMeasure.estimateFwhm(field)), r.d("fwhm"), 1e-6, "fwhm")
        expectClose(Double(try PsfMeasure.estimateFwhm(mono)), r.d("fwhmMono"), 1e-6, "fwhmMono")
    }

    @Test func matchingAndWarp() throws {
        let move = SimilarityTransform(1.01, 0.05, 12.3, -7.7)
        let moved = AstroImage(width: 400, height: 300, channels: 3)
        try moved.data.withUnsafeMutableBufferPointer { dst in
            try ImageWarp.resample(field, move, 400, 300) { y, w, row in
                for c in 0 ..< 3 { for x in 0 ..< 400 { dst[c * 120000 + y * 400 + x] = row[c * w + x] } }
            }
        }
        try expectImage(moved, "warped", tol: 1e-6)

        let stars = try StarDetector.detect(field)
        let movedStars = try StarDetector.detect(try Ref.image("warped"))
        expectStars(movedStars, r["movedStars"], "movedStars")
        let match = StarMatcher.match(stars, movedStars)
        let m = r.sub("match")
        expectTransform(match?.transform, m["t"], "match")
        #expect(match?.matchedStars == m["MatchedStars"] as? Int)

        let rotStars = try StarDetector.detect(try Ref.image("rot90"))
        expectStars(rotStars, r["rotStars"], "rotStars")
        try expectImage(CropStep.orientRightAngle(field, 90, false, false), "rot90", tol: 0)
        expectTransform(StarMatcher.triangleMatch(stars, rotStars), r["tri"], "triangle")
        let m90 = r.sub("match90")
        let match90 = StarMatcher.match(stars, rotStars)
        expectTransform(match90?.transform, m90["t"], "match90")
        #expect(match90?.matchedStars == m90["MatchedStars"] as? Int)

        let pairs = StarMatcher.pair(stars, movedStars, match?.transform ?? .identity, 3)
        #expect(pairs.count == r["pairs"] as! Int)
        expectTransform(StarMatcher.fit(pairs), r["fit"], "fit")
        expectTransform(move.inverse(), r["inverse"], "inverse", tol: 1e-6)
        let a = move.apply(3.5, 7.25), ra = nums(r["apply"])
        #expect(Double(a.x) == Double(Float(ra[0])) && Double(a.y) == Double(Float(ra[1])))
    }

    @Test func backgroundPolynomial() throws {
        let flat = field.createEmptyLike()
        let (points, degree) = try BackgroundFit.flatten(field, flat, degree: 2, tolerance: 2, columns: 24, .none)
        try expectImage(flat, "flatten", tol: 1e-6)
        let fr = try Ref.dict("flatten")
        #expect(degree == fr["degree"] as! Int)
        let rp = (fr["points"] as! [Any]).map { nums($0) }
        #expect(points.count == rp.count)
        for (p, q) in zip(points, rp) { #expect(abs(Double(p.x) - q[0]) < 1e-6 && abs(Double(p.y) - q[1]) < 1e-6) }
        let flat4 = field.createEmptyLike()
        let (p4, d4) = try BackgroundFit.flatten(field, flat4, degree: 4, tolerance: 1.3, columns: 30, .none)
        try expectImage(flat4, "flatten4", tol: 1e-6)
        #expect(p4.count == fr["points4"] as! Int && d4 == fr["degree4"] as! Int)
        // In place (the stack's use).
        let copy = field.clone()
        _ = try BackgroundFit.flatten(copy, copy, degree: 2, tolerance: 2, columns: 24, .none)
        #expect(maxDiff(copy, flat) == 0)
    }

    @Test(arguments: TestEnv.dataSets) func realStack(_ set: DataSet) async throws {
        let frames = try FrameSet.scan(set.frames.path)
        let started = Date()
        let result = try await runStep(StackStep(), nil, frames: frames)
        let seconds = Date().timeIntervalSince(started)
        print("\(set.folder) stack: \(seconds) s")
        let ref = try Ref.image("stack", in: set)
        let mine = result.image!
        #expect(mine.width == ref.width && mine.height == ref.height)
        // Float summation on the same order: essentially the same; allow for the last bits.
        #expect(maxDiff(mine, ref) < 1e-4, "stack max diff \(maxDiff(mine, ref))")
        #expect(meanDiff(mine, ref) < 1e-6, "stack mean diff \(meanDiff(mine, ref))")
        let notes = try Ref.dict("stack", in: set).sub("notes")
        #expect(result.frameNotes?.count == notes.count)
        for (path, note) in result.frameNotes ?? [:] {
            let theirs = notes.sub((path as NSString).lastPathComponent)
            #expect(note.used == theirs["Used"] as! Bool, "\(path) used")
            #expect(note.stars == theirs["Stars"] as? Int, "\(path) stars")
            if let a = note.angle { expectClose(Double(a), theirs.d("Angle"), 1e-3, "\(path) angle") }
        }
        #expect(mine.header["STACKCNT"] == ref.header["STACKCNT"])
    }
}
