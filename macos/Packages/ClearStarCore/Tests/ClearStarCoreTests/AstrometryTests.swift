import Foundation
import Testing
@testable import ClearStarCore

/// F4 parity: WCS, HEALPix, the offline catalogue, the online parsers, plate solving, colour calibration.
@Suite(.serialized, .globalState) struct AstrometryTests {
    let r: [String: Any]
    init() throws { r = try Ref.dict("wcs") }

    private func wcsArray(_ w: Wcs) -> [Double] { [w.ra, w.dec, w.crPix1, w.crPix2, w.cd11, w.cd12, w.cd21, w.cd22] }

    private func expectArray(_ a: [Double], _ b: [Double], _ tol: Double, _ what: String) {
        #expect(a.count == b.count, "\(what) count")
        for (x, y) in zip(a, b) where !(abs(x - y) <= tol * max(1, abs(y))) { Issue.record("\(what): \(a) vs \(b)"); return }
    }

    @Test func wcsParity() throws {
        let wcs = Wcs(10.6847, 41.2690, 199.5, 149.5, -3.0e-4, 0.4e-4, 0.4e-4, 3.0e-4)
        for s in r.arr("samples").map(nums) {
            let (ra, dec) = wcs.pixelToSky(s[0], s[1])
            let back = wcs.skyToPixel(ra, dec)!
            expectArray([ra, dec, back.x, back.y], Array(s[2...5]), 1e-12, "samples")
        }
        let proj = [(10.0, 41.0, 10.6847, 41.269), (359.9, -0.5, 0.1, 0.2), (200.0, -80.0, 180.0, -85.0)]
        for (i, p) in proj.enumerated() {
            let q = Wcs.project(p.0, p.1, p.2, p.3)!
            expectArray([q.xi, q.eta], nums(r.arr("project")[i]), 1e-12, "project")
        }
        #expect((Wcs.project(190, -41, 10, 41) == nil) == (r["farSide"] as! Bool))
        for (i, p) in [(0.5, -0.25, 10.6847, 41.269), (-1.0, 2.0, 359.5, -10.0)].enumerated() {
            let q = Wcs.deproject(p.0, p.1, p.2, p.3)
            expectArray([q.ra, q.dec], nums(r.arr("deproject")[i]), 1e-12, "deproject")
        }
        var header = FitsHeader()
        wcs.write(to: &header, imageHeight: 300)
        let refHeader = r["header"] as! [String: String]
        #expect(Set(header.keys.map { $0.uppercased() }) == Set(refHeader.keys))
        for (k, v) in refHeader {
            if let dv = Double(v) { expectClose(parseDouble(header[k])!, dv, 1e-15 * max(1, abs(dv)), k) } else { #expect(header[k] == v, "\(k)") }
        }
        expectArray(wcsArray(Wcs.read(header, imageHeight: 300)!), nums(r["read"]), 1e-12, "read")
        var cdelt = FitsHeader()
        for (k, v) in [("CTYPE1", "RA---TAN"), ("CRVAL1", "83.8"), ("CRVAL2", "-5.39"), ("CRPIX1", "100"), ("CRPIX2", "80"), ("CDELT1", "-0.001"), ("CDELT2", "0.001"), ("CROTA2", "12")] { cdelt[k] = v }
        expectArray(wcsArray(Wcs.read(cdelt, imageHeight: 160)!), nums(r["readCdelt"]), 1e-12, "readCdelt")
        expectClose(wcs.scaleArcsec, r.d("scale"), 1e-12, "scale")
        expectClose(wcs.rotationDegrees, r.d("rotation"), 1e-10, "rotation")
        #expect(wcs.flipped == (r["flipped"] as! Bool))
        #expect([10.6847, 0.0, 359.99, 187.5].map(Wcs.formatRa) == r.arr("fmt") as! [String])
        #expect([41.269, -5.3911, 0.0, -89.999].map(Wcs.formatDec) == r.arr("fmtDec") as! [String])
        let sexa = [("00 42 44.3", 15.0), ("+41 16 08", 1.0), ("-05:23:28", 1.0), ("bad x", 1.0)].map { PlateSolveStep.sexagesimal($0.0, $0.1) }
        for (a, b) in zip(sexa, r.arr("sexa")) {
            if let b = b as? NSNumber { expectClose(a!, b.doubleValue, 1e-12, "sexa") } else { #expect(a == nil) }
        }
        let centres: [FitsHeader] = [FitsHeader([("RA", "10.68"), ("DEC", "41.27")]), FitsHeader([("OBJCTRA", "'00 42 44'"), ("OBJCTDEC", "'+41 16 08'")]),
                                     FitsHeader([("CRVAL1", "1.5"), ("CRVAL2", "-2.5")]), FitsHeader()]
        for (h, ref) in zip(centres, r.arr("centre")) {
            if let c = PlateSolveStep.headerCentre(h) { expectArray([c.ra, c.dec], nums(ref), 1e-12, "centre") } else { #expect(ref is NSNull) }
        }
        let scales: [FitsHeader] = [FitsHeader([("FOCALLEN", "250"), ("XPIXSZ", "2.9")]), FitsHeader([("CDELT2", "-0.0004")]), FitsHeader()]
        for (h, ref) in zip(scales, r.arr("scaleHint")) {
            if let s = PlateSolveStep.headerScale(h) { expectClose(s, num(ref), 1e-12, "scaleHint") } else { #expect(ref is NSNull) }
        }
        #expect([25000, 20000, 9700, 5770, 5000, 3100, 2000].map { Double(LocalGaiaCatalog.bpRpFromTeff(Float($0))) }.map { Float($0) }
                == nums(r["teff"]).map { Float($0) })
    }

    @Test func healpixParity() {
        let hp3 = Healpix.forOrder(3), hp8 = Healpix.forOrder(8)
        for row in r.arr("healpix3").map(nums) {
            let (z, phi) = hp3.pixToZPhi(Int(row[0]))
            #expect(abs(z - row[1]) < 1e-15 && abs(phi - row[2]) < 1e-15)
        }
        for row in r.arr("healpix8").map(nums) {
            let (z, phi) = hp8.pixToZPhi(Int(row[0]))
            #expect(abs(z - row[1]) < 1e-15 && abs(phi - row[2]) < 1e-15)
        }
        #expect(hp3.queryDiscInclusive(10.68, 41.27, 5.0).map(Double.init) == nums(r["disc3"]))
        #expect(hp8.queryDiscInclusive(83.8, -5.4, 0.8).map(Double.init) == nums(r["disc8"]))
    }

    private func starsArray(_ s: [CatalogStar]) -> [[Double]] { s.map { [$0.ra, $0.dec, Double($0.g), Double($0.bp), Double($0.rp)] } }

    private func expectStars(_ mine: [CatalogStar], _ ref: Any?, _ what: String) {
        let theirs = (ref as? [Any] ?? []).map(nums)
        #expect(mine.count == theirs.count, "\(what) count \(mine.count) vs \(theirs.count)")
        // Equal G magnitudes may come in another order (.NET's List.Sort is not stable): compare as sets.
        let key: ([Double]) -> String = { $0.map { $0.isNaN ? "nan" : String(format: "%.9g", $0) }.joined(separator: ",") }
        let a = Set(starsArray(mine).map { $0.enumerated().map { $0.offset < 2 ? $0.element : Double(Float($0.element)) } }.map(key))
        let b = Set(theirs.map { $0.enumerated().map { $0.offset < 2 ? $0.element : Double(Float($0.element)) } }.map(key))
        #expect(a == b, "\(what) differs")
    }

    @Test func offlineCatalogue() throws {
        let c = try Ref.dict("catalog")
        let cat = try #require(LocalGaiaCatalog.open(Ref.url("catalog_l3.dat").path))
        #expect(cat.level == c["level"] as! Int)
        expectStars(try cat.coneSync(10.6847, 41.269, 0.35, 13.5, 500), c["cone"], "cone")
        expectStars(try cat.coneSync(10.9, 41.0, 0.1, 20, 5), c["cone2"], "cone2")
        #expect(LocalGaiaCatalog.open(Ref.url("field.fits").path) == nil)
    }

    @Test func catalogueIsFoundThroughSirilSettings() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        AppPaths.useHome(home)
        defer { AppPaths.useHome(nil); try? fm.removeItem(at: home) }
        UserSettings.set(LocalGaiaCatalog.pathSettingKey, nil)
        let cfg = home.appendingPathComponent("Library/Application Support/org.siril.Siril/siril", isDirectory: true)
        try fm.createDirectory(at: cfg, withIntermediateDirectories: true)
        let path = Ref.url("catalog_l3.dat").path
        try "[core]\ncatalogue_gaia_astro=\(path)\n".write(to: cfg.appendingPathComponent("config.1.4.ini"), atomically: true, encoding: .utf8)
        #expect(LocalGaiaCatalog.locate() == path)
        #expect(AutoStarCatalog().isOffline)
    }

    @Test func onlineParsers() throws {
        let p = try Ref.dict("parsers")
        expectStars(VizierGaiaCatalog.parseTsv(try Ref.text("vizier.tsv")), p["tsv"], "tsv")
        expectStars(GaiaOnlineCatalog.parseCsv(try Ref.text("tap.csv")), p["csv"], "csv")
        let s = try #require(NameResolver.parse(try Ref.text("sesame.txt")))
        #expect([s.ra, s.dec] == nums(p["sesame"]))
        #expect(NameResolver.parse("nothing") == nil)
    }

    @Test func syntheticPlateSolveAndColour() throws {
        let img = try Ref.image("solve_input")
        let s = try Ref.dict("solve")
        let cat = try #require(LocalGaiaCatalog.open(Ref.url("catalog_l3.dat").path))
        let cone = try cat.coneSync(10.6847, 41.269, 0.35, 13.5, 500)
        let result = try #require(try PlateSolver.solve(img, cone, raHint: 10.70, decHint: 41.25, scaleArcsecHint: 3600 * 8.1e-4))
        let solved = s.sub("solved")
        expectArray(wcsArray(result.wcs), nums(solved["w"]), 1e-9, "solved wcs")
        #expect(result.matchedStars == solved["MatchedStars"] as! Int)
        expectClose(result.rmsArcsec, solved.d("RmsArcsec"), 1e-6, "rms")

        let fwhm = try PsfMeasure.estimateFwhm(img)
        #expect(fwhm == s.f("fwhm"))
        let all = try cat.coneSync(10.6847, 41.269, 0.6, 20, 5000)
        #expect(all.count == s["all"] as! Int)
        let samples = try ColorCalibration.measure(img, result.wcs, all, fwhm: fwhm)
        let refSamples = s.arr("samples").map(nums)
        #expect(samples.count == refSamples.count)
        for (a, b) in zip(samples, refSamples) {
            #expect(abs(Double(a.bpRp) - b[0]) < 1e-6 && abs(Double(a.rMinusG) - b[1]) < 1e-5 && abs(Double(a.bMinusG) - b[2]) < 1e-5, "\(a) vs \(b)")
        }
        let fit = try #require(ColorCalibration.fit(samples, white: ColorCalibration.galaxyBpRp))
        let rf = nums(s["fit"])
        expectArray([Double(fit.redFactor), Double(fit.blueFactor), Double(fit.starsUsed), Double(fit.slopeR), Double(fit.slopeB)], Array(rf[0...4]), 1e-5, "fit")
        let vega = try #require(ColorCalibration.fit(samples, white: ColorCalibration.vegaBpRp))
        expectArray([Double(vega.redFactor), Double(vega.blueFactor), Double(vega.starsUsed)], nums(s["fitVega"]), 1e-5, "fitVega")
        let line = ColorCalibration.robustLine([(0, 1), (1, 3), (2, 5.1), (3, 6.9), (4, 9), (5, 30), (6, 13)])
        expectArray([Double(line.a), Double(line.b), Double(line.n), Double(line.scatter)], nums(s["line"]), 1e-6, "line")
        try expectImage(ColorCalibration.apply(img, redFactor: Float(rf[0]), blueFactor: Float(rf[1]), neutralizeBackground: true), "colorcal_apply", tol: 1e-6)
        try expectImage(ColorCalibration.apply(img, redFactor: 1.2, blueFactor: 0.8, neutralizeBackground: false), "colorcal_apply_raw", tol: 1e-6)
    }

    /// A catalogue that returns fixed stars (or fails like a network without connection).
    struct FixedCatalog: StarCatalog {
        let stars: [CatalogStar]?
        var name: String { "fixed" }
        func cone(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken) async throws -> [CatalogStar] {
            guard let stars else { throw URLError(.notConnectedToInternet) }
            return stars
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestEnv.catalog.path)), arguments: TestEnv.dataSets)
    func realPlateSolveAndColour(_ set: DataSet) async throws {
        _ = TestEnv.setUp
        let bge = try Ref.image("s04_bge_ai", in: set)
        PlateSolveStep.catalog = try #require(LocalGaiaCatalog.open(TestEnv.catalog.path))
        defer {
            ColorCalibrationStep.onlineCatalog = GaiaOnlineCatalog(useVizierFallback: false, timeout: 10)
            PlateSolveStep.catalog = AutoStarCatalog()
        }
        let ref = try Ref.dict("s07_platesolve", in: set)
        if let error = ref["error"] as? String {
            // The C# run could not solve this set (no usable centre / scale): Swift fails the same way.
            do {
                _ = try await runStep(PlateSolveStep(), bge) { p in if let o = set.object { p.set(PlateSolveStep.objectKey, o) } }
                Issue.record("\(set.folder): the plate solve should fail like in C#: \(error)")
            } catch {
                #expect(error.localizedDescription == (ref["error"] as! String))
            }
            return
        }
        let started = Date()
        let solved = try await runStep(PlateSolveStep(), bge) { p in if let o = set.object { p.set(PlateSolveStep.objectKey, o) } }
        print("\(set.folder) plate solve: \(Date().timeIntervalSince(started)) s – \(solved.summary)")
        let wcs = try #require(Wcs.read(solved.image!.header, imageHeight: bge.height))
        expectArray(wcsArray(wcs), nums(ref["wcs"]), 1e-9, "\(set.folder) wcs")
        #expect(PlateSolveStep.lastResult?.matchedStars == ref["MatchedStars"] as? Int)
        let refImage = try Ref.image("s07_platesolve", in: set)
        #expect(maxDiff(solved.image!, refImage) == 0)

        // Colour calibration with the catalogue stars the C# run used (served as the "online" catalogue).
        let csv = try Ref.text("s08_catalog.csv", in: set)
        let stars = csv.split(separator: "\n").map { line -> CatalogStar in
            let f = line.split(separator: ",").map { Double($0) ?? .nan }
            return CatalogStar(f[0], f[1], Float(f[2]), Float(f[3]), Float(f[4]))
        }
        ColorCalibrationStep.onlineCatalog = FixedCatalog(stars: stars)
        let cal = try await runStep(ColorCalibrationStep(), refImage)
        let refCal = try Ref.dict("s08_colorcal", in: set)
        let fit = try #require(ColorCalibrationStep.lastResult)
        expectArray([Double(fit.redFactor), Double(fit.blueFactor), Double(fit.starsUsed)], nums(refCal["fit"]), 1e-5, "\(set.folder) colour fit")
        try expectImage(cal.image!, "s08_colorcal", tol: 1e-5, in: set)
        #expect(cal.image!.header["CLRCAL"] == "T")

        // Offline: the online catalogue fails, the plate solve's catalogue is used instead.
        ColorCalibrationStep.onlineCatalog = FixedCatalog(stars: nil)
        let offline = try await runStep(ColorCalibrationStep(), refImage)
        #expect(offline.image != nil)
    }

    // MARK: catalogue download

    private func run(_ tool: String, _ args: [String], stdout: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let stdout { FileManager.default.createFile(atPath: stdout.path, contents: nil); p.standardOutput = try FileHandle(forWritingTo: stdout) }
        try p.run(); p.waitUntilExit()
    }

    @Test func catalogueDownloadWithBzip2AndMirrors() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("catdl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // ~3 MB of catalogue-like bytes, compressed as two concatenated bzip2 streams (like pbzip2).
        let plain = dir.appendingPathComponent("cat.dat")
        var bytes = [UInt8](repeating: 0, count: 3_000_000)
        for i in 0 ..< bytes.count { bytes[i] = UInt8((i * 7919 + i / 1000) & 0xff) }
        try Data(bytes).write(to: plain)
        let half1 = dir.appendingPathComponent("a"), half2 = dir.appendingPathComponent("b")
        try Data(bytes[0 ..< 1_200_000]).write(to: half1)
        try Data(bytes[1_200_000...]).write(to: half2)
        try run("/usr/bin/bzip2", ["-k", "-f", half1.path])
        try run("/usr/bin/bzip2", ["-k", "-f", half2.path])
        let bz = dir.appendingPathComponent("cat.dat.bz2")
        var joined = try Data(contentsOf: URL(fileURLWithPath: half1.path + ".bz2"))
        joined.append(try Data(contentsOf: URL(fileURLWithPath: half2.path + ".bz2")))
        try joined.write(to: bz)
        let sha = try String(String(decoding: {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); p.arguments = ["-a", "256", plain.path]; p.standardOutput = pipe
            try p.run(); p.waitUntilExit(); return pipe.fileHandleForReading.readDataToEndOfFile()
        }(), as: UTF8.self).prefix(64))

        // A dead mirror first, then the bz2: the second one wins and is unpacked on the fly.
        let progress = Locked<[CatalogDownloader.Progress]>([])
        let path = try await CatalogDownloader.download(urls: [dir.appendingPathComponent("missing.bz2").absoluteString, bz.absoluteString],
                                                        expectedSha: sha, expectedSize: Int64(bytes.count),
                                                        progress: { p in progress.withLock { $0.append(p) } })
        #expect(try Data(contentsOf: path) == Data(bytes))
        #expect(UserSettings.get(LocalGaiaCatalog.pathSettingKey) == path.path)
        #expect(progress.current.last?.phase == "done")
        // A plain .dat mirror is copied as is; a wrong checksum fails.
        _ = try await CatalogDownloader.download(urls: [plain.absoluteString], expectedSha: sha, expectedSize: Int64(bytes.count))
        await #expect(throws: ClearStarError.self) {
            try await CatalogDownloader.download(urls: [plain.absoluteString], expectedSha: String(repeating: "0", count: 64), expectedSize: Int64(bytes.count))
        }
        UserSettings.set(LocalGaiaCatalog.pathSettingKey, nil)
    }
}
