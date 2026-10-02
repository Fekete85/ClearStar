import Foundation
import Testing
@testable import ClearStarCore

/// F3: tile geometry, the Core ML networks against the C# (ONNX Runtime) results, the model store with a
/// local mirror, and StarNet2 through a stand-in program.
@Suite(.serialized, .globalState) struct AiTests {
    init() { _ = TestEnv.setUp }

    static let coreml = TestEnv.testdata.appendingPathComponent("coreml")
    static var hasModels: Bool { FileManager.default.fileExists(atPath: coreml.appendingPathComponent("denoise/3.0.2/model.mlpackage").path) }
    static func model(_ kind: String, _ version: String) -> String { coreml.appendingPathComponent("\(kind)/\(version)/model.mlpackage").path }

    @Test func tilingGeometry() throws {
        let r = try Ref.dict("tiling")
        for case let t as [String: Any] in r.arr("tilings") {
            let tiling = Tiling(t["win"] as! Int, t["stride"] as! Int, t["w"] as! Int, t["h"] as! Int)
            #expect(tiling.rows == t["Rows"] as! Int && tiling.cols == t["Cols"] as! Int)
            #expect(tiling.paddedWidth == t["PaddedWidth"] as! Int && tiling.paddedHeight == t["PaddedHeight"] as! Int)
            #expect(tiling.rowMap().map(Double.init) == nums(t["rowMap"]))
            #expect(tiling.colMap().map(Double.init) == nums(t["colMap"]))
        }
        let psf = [(true, "1.0.0", Float(3)), (false, "1.0.0", 3), (false, "1.0.1", 3), (false, "1.0.1", 20), (true, "1.0.0", 1)]
            .map { Double(DeconvolutionModel.normalizedPsf(stellar: $0.0, $0.1, $0.2)) }
        #expect(psf.map { Float($0) } == nums(r["psf"]).map { Float($0) })
        #expect(["1.0.0", "1.1.0", "2.0.0", "3.0.2"].map { Double(DenoiseModel.thresholdFor($0)) } == nums(r["thresholds"]))
    }

    @Test func polynomialBackgroundStep() async throws {
        let field = try Ref.image("field")
        let r = try await runStep(BackgroundExtractionStep(), field) { p in
            p.set(BackgroundExtractionStep.methodKey, BackgroundExtractionStep.methodPolynomial)
            p.set(BackgroundExtractionStep.smoothingKey, 0.5); p.set(BackgroundExtractionStep.strengthKey, 0.4); p.set(BackgroundExtractionStep.gridKey, 0.3)
        }
        try expectImage(r.image!, "bgestep_poly", tol: 1e-6)
        #expect(!BackgroundExtractionStep.lastSamplePoints.isEmpty)
    }

    @Test(.enabled(if: AiTests.hasModels), arguments: TestEnv.dataSets) func realBackgroundAi(_ set: DataSet) async throws {
        CoreMLRunner.gpuEnabled = true
        let crop = try Ref.image("s03_crop", in: set)
        let r = try await runStep(BackgroundExtractionStep(), crop) { $0.set(BackgroundExtractionStep.modelKey, Self.model("bge", "1.0.1")) }
        let ref = try Ref.image("s04_bge_ai", in: set)
        #expect(maxDiff(r.image!, ref) < 2e-5, "bge max diff \(maxDiff(r.image!, ref))")
        let bg = try BackgroundModel.estimateBackground(crop, Self.model("bge", "1.0.1"), smoothing: 0.1)
        let refBg = try Ref.image("bge_model", in: set)
        #expect(maxDiff(bg, refBg) < 2e-5, "bge model max diff \(maxDiff(bg, refBg))")
        let div = BackgroundModel.divide(crop, refBg)
        try expectImage(div, "bge_divide", tol: 1e-6, in: set)
        #expect(r.summary.contains("1.0.1"))

        let poly = try await runStep(BackgroundExtractionStep(), crop) { $0.set(BackgroundExtractionStep.methodKey, BackgroundExtractionStep.methodPolynomial) }
        try expectImage(poly.image!, "s04_bge_poly", tol: 1e-6, in: set)
    }

    @Test(.enabled(if: AiTests.hasModels), arguments: TestEnv.dataSets) func realDeconvolution(_ set: DataSet) async throws {
        CoreMLRunner.gpuEnabled = true
        let input = try Ref.image("ai_input", in: set)
        let fwhm = try PsfMeasure.estimateFwhm(input)
        expectClose(Double(fwhm), try Ref.dict("psf", in: set).d("fwhmCut"), 1e-6, "fwhm")
        let started = Date()
        let r = try await runStep(DeconvolutionStep(), input) { p in
            p.set(DeconvolutionStep.starsModelKey, Self.model("deconvolution-stars", "1.0.0"))
            p.set(DeconvolutionStep.objectModelKey, Self.model("deconvolution-object", "1.0.1"))
        }
        print("\(set.folder) deconvolution: \(Date().timeIntervalSince(started)) s")
        let ref = try Ref.image("s05_deconv", in: set)
        let out = r.image!
        print("deconv maxDiff \(maxDiff(out, ref)) mean \(meanDiff(out, ref)) psnr \(psnr(out, ref))")
        #expect(psnr(out, ref) > 60, "deconv PSNR \(psnr(out, ref))")
        #expect(meanDiff(out, ref) < 5e-5, "deconv mean diff \(meanDiff(out, ref))")
    }

    @Test(.enabled(if: AiTests.hasModels), arguments: TestEnv.dataSets) func realDenoise(_ set: DataSet) async throws {
        CoreMLRunner.gpuEnabled = true
        let input = try Ref.image("ai_input", in: set)
        let started = Date()
        let r = try await runStep(DenoiseStep(), input) { $0.set(DenoiseStep.modelKey, Self.model("denoise", "3.0.2")) }
        print("\(set.folder) denoise: \(Date().timeIntervalSince(started)) s")
        let ref = try Ref.image("s06_denoise", in: set)
        let out = r.image!
        print("denoise maxDiff \(maxDiff(out, ref)) mean \(meanDiff(out, ref)) psnr \(psnr(out, ref))")
        #expect(psnr(out, ref) > 60, "denoise PSNR \(psnr(out, ref))")
        #expect(meanDiff(out, ref) < 5e-5, "denoise mean diff \(meanDiff(out, ref))")
    }

    // MARK: model store

    /// A fake model package (the store only moves and unpacks it).
    private func fakePackage(in dir: URL) throws -> URL {
        let pkg = dir.appendingPathComponent("model.mlpackage")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pkg.appendingPathComponent("Manifest.json"))
        return pkg
    }

    private func zip(_ source: URL, to zip: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    private func sha256(_ url: URL) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        return String(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(64))
    }

    @Test func manifestPicksHighestVersionAndLicense() throws {
        let json = """
        {"files":[{"path":"coreml/denoise/2.0.0/model.mlpackage.zip","size":10,"sha256":"aa"},
        {"path":"coreml/denoise/10.1.0/model.mlpackage.zip","size":20,"sha256":"bb"},
        {"path":"coreml/denoise/10.1.0/LICENSE.html","size":1,"sha256":"cc"},
        {"path":"coreml/bge/1.0.1/model.mlpackage.zip","size":5,"sha256":"dd"},
        {"path":"graxpert/denoise-ai-models/9.9.9/model.onnx","size":5,"sha256":"ee"}]}
        """
        let m = try #require(try AiModelStore.latestInManifest(Data(json.utf8), .denoise, baseUrl: "https://x/"))
        #expect(m.version == "10.1.0" && m.size == 20 && m.sha256 == "bb")
        #expect(m.licenseUrl == "https://x/coreml/denoise/10.1.0/LICENSE.html")
        #expect(try AiModelStore.latestInManifest(Data(json.utf8), .backgroundExtraction, baseUrl: "https://x/")?.version == "1.0.1")
        #expect(try AiModelStore.latestInManifest(Data(json.utf8), .deconvolutionStars, baseUrl: "https://x/") == nil)
        #expect(throws: ClearStarError.self) { try AiModelStore.latestInManifest(Data("{\"files\":5}".utf8), .denoise, baseUrl: "") }
    }

    @Test func downloadImportAndResolve() async throws {
        let fm = FileManager.default
        let mirror = fm.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: mirror) }
        let versionDir = mirror.appendingPathComponent("coreml/denoise/3.0.2", isDirectory: true)
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let staging = mirror.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let zipURL = versionDir.appendingPathComponent("model.mlpackage.zip")
        try zip(try fakePackage(in: staging), to: zipURL)
        try Data("<html>CC BY-NC-SA 4.0</html>".utf8).write(to: versionDir.appendingPathComponent("LICENSE.html"))
        let size = try fm.attributesOfItem(atPath: zipURL.path)[.size] as! Int
        let manifest = """
        {"files":[{"path":"coreml/denoise/3.0.2/model.mlpackage.zip","size":\(size),"sha256":"\(try sha256(zipURL))"},
        {"path":"coreml/denoise/3.0.2/LICENSE.html","size":1,"sha256":"x"}]}
        """
        let base = mirror.absoluteString
        let latest = try #require(try AiModelStore.latestInManifest(Data(manifest.utf8), .denoise, baseUrl: base))
        let info = try await AiModelStore.downloadFromMirror(latest)
        #expect(info.version == "3.0.2")
        #expect(fm.fileExists(atPath: info.path))
        #expect(fm.fileExists(atPath: URL(fileURLWithPath: info.path).deletingLastPathComponent().appendingPathComponent("LICENSE.html").path))
        #expect(AiModelStore.resolve(.denoise)?.path == info.path)
        #expect(AiModelStore.listAvailable(.denoise).first?.version == "3.0.2")

        // A wrong checksum leaves nothing behind.
        var bad = latest
        bad.version = "3.0.3"; bad.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: ClearStarError.self) { try await AiModelStore.downloadFromMirror(bad) }
        #expect(!fm.fileExists(atPath: AiModelStore.modelsDirectory.appendingPathComponent("denoise/3.0.3/model.mlpackage").path))

        // Import of a zip and of a package; the newest version wins when nothing is preferred.
        let imported = try AiModelStore.importModel(.denoise, from: zipURL, version: "4.0.0")
        #expect(fm.fileExists(atPath: imported.path))
        let pkgImport = try AiModelStore.importModel(.backgroundExtraction, from: try fakePackage(in: staging.appendingPathComponent("b")))
        #expect(fm.fileExists(atPath: pkgImport.path))
        AiModelStore.setPreferred(.denoise, nil)
        #expect(AiModelStore.resolve(.denoise)?.version == "4.0.0")
        #expect(AiModelStore.resolve(.denoise, explicitPath: info.path)?.version == "3.0.2")
        #expect(AiModelStore.compareVersions("1.10.0", "1.9.2") > 0)
    }

    static var hasLocalMirror: Bool { FileManager.default.fileExists(atPath: TestEnv.testdata.appendingPathComponent("mirror/manifest.json").path) }

    /// End to end with the local stand-in of the mirror (package-for-mirror.sh): manifest → download →
    /// SHA-256 → unpack → compile → run, the result matching the C# background extraction.
    @Test(.enabled(if: TestEnv.hasRealData && AiTests.hasLocalMirror)) func downloadFromLocalMirrorAndRun() async throws {
        setenv("CLEARSTAR_MIRROR", TestEnv.testdata.appendingPathComponent("mirror").absoluteString, 1)
        defer { unsetenv("CLEARSTAR_MIRROR") }
        let latest = try #require(try await AiModelStore.latestOnMirror(.backgroundExtraction))
        #expect(latest.version == "1.0.1" && latest.licenseUrl != nil)
        let info = try await AiModelStore.downloadFromMirror(latest)
        let r = try await runStep(BackgroundExtractionStep(), try Ref.image("s03_crop", real: true))
        #expect(AiModelStore.resolve(.backgroundExtraction)?.path == info.path)
        #expect(maxDiff(r.image!, try Ref.image("s04_bge_ai", real: true)) < 2e-5)
    }

    /// The live mirror (opt-in: CLEARSTAR_LIVE_MIRROR=1): every kind is listed; the background model is
    /// downloaded, verified, compiled and run like in the app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLEARSTAR_LIVE_MIRROR"] == "1" && TestEnv.hasRealData))
    func liveMirror() async throws {
        for kind in AiModelKind.allCases {
            let m = try #require(try await AiModelStore.latestOnMirror(kind), "\(kind)")
            #expect(m.url.hasPrefix("https://csillag.blackit.hu/clearstar/coreml/") && m.licenseUrl != nil)
        }
        let latest = try #require(try await AiModelStore.latestOnMirror(.backgroundExtraction))
        try await AiModelStore.downloadFromMirror(latest)
        let r = try await runStep(BackgroundExtractionStep(), try Ref.image("s03_crop", real: true))
        #expect(maxDiff(r.image!, try Ref.image("s04_bge_ai", real: true)) < 2e-5)
    }

    @Test(.enabled(if: AiTests.hasModels)) func gpuSwitch() throws {
        CoreMLRunner.gpuEnabled = false
        _ = try CoreMLRunner.load(Self.model("bge", "1.0.1"))
        #expect(CoreMLRunner.lastProvider == "CPU")
        CoreMLRunner.gpuEnabled = true
        _ = try CoreMLRunner.load(Self.model("bge", "1.0.1"))
        #expect(CoreMLRunner.lastProvider == "GPU")
        #expect(UserSettings.get(CoreMLRunner.gpuSettingKey) == nil)
    }

    // MARK: StarNet2

    static let stub = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/starnet2-stub.py")

    @Test func starNetIsFoundInSirilSettingsAndApplications() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home); AppPaths.useHome(nil) }
        AppPaths.useHome(home)
        StarNet.setExecutable(nil)
        #expect(!StarNet.candidates().contains { $0.hasPrefix("/Users/") && !$0.hasPrefix(home.path) && $0.contains("Library/Application Support") })

        // ~/Applications/StarNet2/starnet2
        let app = home.appendingPathComponent("Applications/StarNet2", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let exe = app.appendingPathComponent("starnet2")
        try fm.copyItem(at: Self.stub, to: exe)
        #expect(StarNet.locate() == exe.path)

        // Siril's configuration wins over the Applications folders.
        let other = home.appendingPathComponent("tools/sn", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let exe2 = other.appendingPathComponent("starnet2")
        try fm.copyItem(at: Self.stub, to: exe2)
        let cfg = home.appendingPathComponent("Library/Application Support/org.siril.Siril/siril", isDirectory: true)
        try fm.createDirectory(at: cfg, withIntermediateDirectories: true)
        try "[core]\nstarnet_exe=\(exe2.path)\n".write(to: cfg.appendingPathComponent("config.1.4.ini"), atomically: true, encoding: .utf8)
        #expect(StarNet.locate() == exe2.path)

        // The user's choice wins over everything.
        StarNet.setExecutable(exe.path)
        #expect(StarNet.locate() == exe.path)
        StarNet.setExecutable(nil)
    }

    @Test func starRemovalThroughTheStandIn() async throws {
        let field = try Ref.image("field")
        // StarNet2 needs at least 512 px: enlarge the synthetic field.
        let big = AstroImage(width: 800, height: 600, channels: 3, header: field.header)
        for c in 0 ..< 3 { big.setChannel(c, Resample.resize(field.channelArray(c), 400, 300, 800, 600)) }
        StarNet.setExecutable(Self.stub.path)
        defer { StarNet.setExecutable(nil) }

        // The stand-in changes nothing: starless = input, no star layer; the BGR planes come back as RGB.
        let progress = Locked<[Double]>([])
        let (starless, stars) = try StarNet.removeStarsLinear(big, exe: Self.stub.path, progress: { f in progress.withLock { $0.append(f) } })
        // Above the stretch's shadow point the round trip is exact (below it the stretch clips to 0), and
        // a swapped channel order would show at once.
        let prms = DisplayStretch.computeAll(big, preset: DisplayStretch.Preset("starnet", 0.25, 2.8), linked: true)
        var worst: Float = 0
        for c in 0 ..< 3 {
            let n = big.pixelsPerChannel
            for i in c * n ..< (c + 1) * n where big.data[i] > prms[c].shadows + 1e-3 { worst = max(worst, abs(starless.data[i] - big.data[i])) }
        }
        #expect(worst < 1e-4, "channel order / round trip \(worst)")
        #expect(stars.data.max()! < 1e-4)
        #expect(progress.current.contains(1.0))

        // A StarNet2 build that writes RGB planes must not be swapped.
        setenv("STUB_RGB", "1", 1)
        let starlessRgb = try StarNet.removeStars(big, exe: Self.stub.path)
        unsetenv("STUB_RGB")
        let starlessBgr = try StarNet.removeStars(big, exe: Self.stub.path)
        #expect(starlessRgb.data == starlessBgr.data)

        // Through the step: the star layer is stored for the stretch steps.
        StarLayerStore.clear()
        let r = try await runStep(StarRemovalStep(), big)
        #expect(StarLayerStore.hasStars(for: r.image!))

        // A failing StarNet2 reports its own message.
        setenv("STUB_FAIL", "1", 1)
        defer { unsetenv("STUB_FAIL") }
        do {
            _ = try StarNet.removeStars(big, exe: Self.stub.path)
            Issue.record("should fail")
        } catch {
            #expect(error.localizedDescription == "stub failure")
        }
    }

    @Test func starRemovalNeedsStarNet() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        AppPaths.useHome(home)
        defer { AppPaths.useHome(nil) }
        StarNet.setExecutable(nil)
        if StarNet.locate() == nil {
            await #expect(throws: ClearStarError.self) { try await runStep(StarRemovalStep(), try Ref.image("field")) }
        }
    }
}
