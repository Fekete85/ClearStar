import Foundation
import Testing
@testable import ClearStarCore

/// F1 parity: statistics, screen stretch, resampling, Bayer, FITS, raster files.
@Suite struct ImagingParityTests {
    let field: AstroImage
    let mono: AstroImage

    init() throws {
        field = try Ref.image("field")
        mono = try Ref.image("field_mono")
    }

    private func expectStats(_ s: ChannelStats, _ r: Any?, _ what: String) {
        let d = r as! [String: Any]
        expectClose(Double(s.min), d.d("Min"), 1e-7, "\(what) min")
        expectClose(Double(s.max), d.d("Max"), 1e-7, "\(what) max")
        expectClose(Double(s.median), d.d("Median"), 1e-7, "\(what) median")
        expectClose(Double(s.mad), d.d("Mad"), 1e-7, "\(what) mad")
        expectClose(Double(s.mean), d.d("Mean"), 1e-6, "\(what) mean")
    }

    @Test func statistics() throws {
        let r = try Ref.dict("stats")
        for (c, s) in ImageStats.computeAll(field).enumerated() { expectStats(s, r.arr("field")[c], "field \(c)") }
        expectStats(ImageStats.computeAll(mono)[0], r.arr("mono")[0], "mono")
        expectStats(ImageStats.compute(field.channel(1), maxSamples: 5000), r["strided"], "strided")
        let med = nums(r["median"])
        #expect(ImageStats.median([3, 1, 2]) == Float(med[0]))
        #expect(ImageStats.median([4, 1, 3, 2]) == Float(med[1]))
        #expect(ImageStats.median([]) == Float(med[2]))
    }

    private func expectParams(_ p: [DisplayStretch.Params], _ r: [Any], _ what: String) {
        #expect(p.count == r.count)
        for (i, x) in p.enumerated() {
            let d = r[i] as! [String: Any]
            expectClose(Double(x.shadows), d.d("Shadows"), 1e-7, "\(what) shadows \(i)")
            expectClose(Double(x.midtones), d.d("Midtones"), 1e-6, "\(what) midtones \(i)")
        }
    }

    @Test func screenStretch() throws {
        let r = try Ref.dict("stretch")
        for preset in DisplayStretch.presets {
            let pr = r.sub("presets").sub(preset.key)
            expectParams(DisplayStretch.computeAll(field, preset: preset, linked: false), pr.arr("unlinked"), "\(preset.key) unlinked")
            expectParams(DisplayStretch.computeAll(field, preset: preset, linked: true), pr.arr("linked"), "\(preset.key) linked")
        }
        expectParams(DisplayStretch.computeAll(field), r.arr("auto"), "auto")
        expectParams(DisplayStretch.computeAll(field, linked: true, targetBackground: 0.15), r.arr("autoLinked"), "autoLinked")
        for row in r.arr("mtf") {
            let v = nums(row)
            #expect(DisplayStretch.mtf(Float(v[1]), Float(v[0])) == Float(v[2]), "mtf \(v)")
        }
        let p0 = DisplayStretch.Params(0.03, 0.2)
        for row in r.arr("apply") {
            let v = nums(row)
            #expect(p0.apply(Float(v[0])) == Float(v[1]))
            expectClose(Double(p0.invert(p0.apply(Float(v[0])))), v[2], 1e-7, "invert")
        }
        #expect(DisplayStretch.buildLut(p0, size: 64).map { Double($0) } == nums(r["lut"]))
        #expect([field.downsampleFactor(100), field.downsampleFactor(2400), field.downsampleFactor(150)].map(Double.init) == nums(r["factor"]))
        try expectImage(field.downsample(3), "downsample3", tol: 0)
    }

    @Test func resampling() throws {
        let ch0 = field.channelArray(0)
        try expectImage(AstroImage(width: 123, height: 77, channels: 1, data: Resample.resize(ch0, 400, 300, 123, 77)), "resize_down", tol: 1e-7)
        try expectImage(AstroImage(width: 700, height: 520, channels: 1, data: Resample.resize(ch0, 400, 300, 700, 520)), "resize_up", tol: 1e-7)
        try expectImage(AstroImage(width: 400, height: 300, channels: 1, data: Resample.gaussianBlur(ch0, 400, 300, 2.5)), "blur", tol: 1e-7)
    }

    @Test func debayer() throws {
        let cfa = try Ref.image("cfa")
        for pat in BayerPattern.allCases { try expectImage(Debayer.bilinear(cfa, pat), "debayer_\(pat.rawValue)", tol: 0) }
        for row in try Ref.json("bayer") as! [[String: Any]] {
            let img = AstroImage(width: 64, height: row["hgt"] as! Int, channels: 1)
            if let r = row["row"] as? String, !r.isEmpty { img.header["ROWORDER"] = r }
            if let y = row["yoff"] as? String, !y.isEmpty { img.header["YBAYROFF"] = y }
            let eff = ImageFiles.effectiveBayerPattern(img, BayerPattern(rawValue: row["pat"] as! String)!)
            #expect(eff.rawValue == row["eff"] as! String, "\(row)")
        }
    }

    @Test func fitsVariants() throws {
        let headers = try Ref.dict("fits_headers")
        for name in ["fits_u8", "fits_u16", "fits_i16", "fits_i32", "fits_u32", "fits_f32", "fits_f32_65535", "fits_f64", "fits_scaled"] {
            let img = try FitsReader.read(Ref.url(name + ".fits").path)
            try expectImage(img, name + "_read", tol: 0)
            let h = headers[name] as! [String: String]
            #expect(img.header.dictionary == h, "\(name) header")
        }
        let deb = try ImageFiles.load(Ref.url("fits_f64.fits").path)
        try expectImage(deb, "fits_f64_debayered", tol: 0)
        #expect(deb.header.dictionary == headers["fits_f64_debayered"] as! [String: String])
    }

    @Test func fitsRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).fits").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        field.header["OBJECT"] = "M 31"
        field.header["NOTE"] = "it's"
        try FitsWriter.write(tmp, field)
        let back = try FitsReader.read(tmp)
        #expect(maxDiff(back, field) == 0)
        #expect(back.header["OBJECT"] == "M 31")
        #expect(back.header["NOTE"] == "it's")
        #expect(back.header["PROGRAM"] == "ClearStar")
    }

    @Test func rasterFiles() throws {
        try expectImage(try ImageFiles.load(Ref.url("raster.tif").path), "raster_tif_read", tol: 0)
        try expectImage(try ImageFiles.load(Ref.url("raster.png").path), "raster_png_read", tol: 0)
        // JPEG decoders differ in the IDCT / chroma upsampling details.
        let jpg = try ImageFiles.load(Ref.url("raster.jpg").path)
        let ref = try Ref.image("raster_jpg_read")
        #expect(meanDiff(jpg, ref) < 0.003, "jpeg mean diff \(meanDiff(jpg, ref))")
        #expect(maxDiff(jpg, ref) < 0.05, "jpeg max diff \(maxDiff(jpg, ref))")

        // Our own writers: TIFF/PNG 16 bit are lossless, JPEG close.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (fmt, ext, tol) in [(ExportFormat.tiff16, "tif", Float(1.0 / 65535)), (.png16, "png", Float(1.0 / 65535)), (.jpeg, "jpg", Float(0.08))] {
            let path = dir.appendingPathComponent("out.\(ext)").path
            try ImageFiles.save(path, field, fmt)
            let back = try ImageFiles.load(path)
            #expect(maxDiff(back, field) <= tol, "\(ext) roundtrip \(maxDiff(back, field))")
        }
    }
}
