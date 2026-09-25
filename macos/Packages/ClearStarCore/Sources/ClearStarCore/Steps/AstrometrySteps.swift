import Foundation

/// Step 7: plate solving. The approximate centre comes from the FITS header or an object name resolved
/// online; the pixel scale from FOCALLEN/XPIXSZ or the user. Catalogue stars are matched to the image
/// and the TAN WCS goes into the image header for the colour calibration.
public final class PlateSolveStep: WorkflowStep {
    public static let objectKey = "object", scaleKey = "scale", magLimitKey = "maglimit"
    private static let s = "platesolve"

    private struct Shared {
        var lastResult: PlateSolveResult?
        var lastCatalog: (ra: Double, dec: Double, radius: Double, magLimit: Float, stars: [CatalogStar])?
        var catalog: any StarCatalog = AutoStarCatalog()
    }
    private static let shared = Locked(Shared())

    /// The most recent successful solve (for overlays and the colour calibration).
    public static var lastResult: PlateSolveResult? { shared.current.lastResult }

    /// The catalogue source (the tests put a local one here).
    public static var catalog: any StarCatalog {
        get { shared.current.catalog }
        set { shared.withLock { $0.catalog = newValue; $0.lastCatalog = nil } }
    }

    /// Catalogue stars around a position: the last solve's cone when it covers it, else a fresh (cached) query.
    public static func catalogAround(_ ra: Double, _ dec: Double, _ radius: Double, _ magLimit: Float, _ ct: CancellationToken) async throws -> [CatalogStar] {
        if let c = shared.current.lastCatalog, c.magLimit >= magLimit, let d = Wcs.project(ra, dec, c.ra, c.dec),
           sqrt(d.xi * d.xi + d.eta * d.eta) + radius <= c.radius + 1e-6 {
            return c.stars
        }
        let stars = try await catalog.cone(ra, dec, radius, magLimit, 4000, ct)
        shared.withLock { $0.lastCatalog = (ra, dec, radius, magLimit, stars) }
        return stars
    }

    public let definition = StepDefinition.fromLanguage(.plateSolve, .basics, s, [
        StepKit.text(s, objectKey),
        ParameterDefinition(key: scaleKey, label: L.t("step.platesolve.scale.label"), kind: .text, defaultValue: .text(""), advanced: true,
                            help: L.t("step.platesolve.scale.help")),
        StepKit.slider(s, magLimitKey, 14.0, 11, 16, advanced: true),
    ])

    public init() {}

    private static func offline(_ error: Error) -> ClearStarError {
        let msg = (error as? URLError)?.code == .timedOut ? "timeout" : error.localizedDescription
        return ClearStarError(L.f("msg.platesolve.offline", msg))
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        let p = context.parameters
        let ct = context.cancellation
        let header = input.header

        // 1. Centre: an object name the user typed (different from the header's OBJECT) wins; else the header.
        let objectName = p.getString(Self.objectKey).trimmingCharacters(in: .whitespaces)
        let headerObject = header["OBJECT"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let userOverride = !objectName.isEmpty && objectName.lowercased() != headerObject.lowercased()
        var ra: Double, dec: Double
        do {
            if userOverride || (!objectName.isEmpty && Self.headerCentre(header) == nil) {
                context.report(0.02, L.f("msg.platesolve.resolving", objectName))
                guard let pos = try await NameResolver.resolve(objectName) else { throw ClearStarError(L.f("msg.platesolve.unknownObject", objectName)) }
                (ra, dec) = pos
            } else if let centre = Self.headerCentre(header) {
                (ra, dec) = centre
            } else if !headerObject.isEmpty {
                context.report(0.02, L.f("msg.platesolve.resolving", headerObject))
                guard let pos = try await NameResolver.resolve(headerObject) else { throw ClearStarError(L.t("msg.platesolve.noCentre")) }
                (ra, dec) = pos
            } else {
                throw ClearStarError(L.t("msg.platesolve.noCentre"))
            }
        } catch let e as URLError { throw Self.offline(e) }

        // 2. Pixel scale.
        guard let scale = parseDouble(p.getString(Self.scaleKey).trimmingCharacters(in: CharacterSet(charactersIn: " '"))) ?? Self.headerScale(header) else {
            throw ClearStarError(L.t("msg.platesolve.noScale"))
        }

        // 3. Catalogue cone, generous enough for a hint off by ~half a field.
        let fovDiagDeg = sqrt(Double(input.width * input.width + input.height * input.height)) * scale / 3600
        let radius = (0.5 * fovDiagDeg + 0.3).clamped(0.3, 6)
        let magLimit = p.getFloat(Self.magLimitKey, 14)
        context.report(0.1, L.f("msg.platesolve.catalog", Self.catalog.name))
        let stars: [CatalogStar]
        do { stars = try await Self.catalogAround(ra, dec, radius, magLimit, ct) } catch let e as URLError { throw Self.offline(e) }
        if stars.count < 10 { throw ClearStarError(L.t("msg.platesolve.fewCatalogStars")) }

        // 4. Solve.
        context.report(0.3, L.t("msg.platesolve.solving"))
        let (raC, decC) = (ra, dec)
        let solved = try await Task.detached(priority: .userInitiated) {
            try PlateSolver.solve(input, stars, raHint: raC, decHint: decC, scaleArcsecHint: scale, ct,
                                  progress: { f in context.report(0.3 + 0.65 * f, L.t("msg.platesolve.solving")) })
        }.value
        guard let result = solved else { throw ClearStarError(L.t("msg.platesolve.failed")) }
        Self.shared.withLock { $0.lastResult = result }

        let output = input.clone()
        result.wcs.write(to: &output.header, imageHeight: output.height)
        output.header["OBJCTRA"] = Wcs.formatRa(result.wcs.ra)
        output.header["OBJCTDEC"] = Wcs.formatDec(result.wcs.dec)
        let summary = L.f("msg.platesolve.summary", Wcs.formatRa(result.wcs.ra), Wcs.formatDec(result.wcs.dec),
                          result.wcs.scaleArcsec, result.wcs.rotationDegrees, result.matchedStars, result.rmsArcsec)
        return StepResult(image: output, summary: summary)
    }

    /// RA/DEC in degrees, or OBJCTRA/OBJCTDEC in sexagesimal, or an existing WCS centre, from the header.
    public static func headerCentre(_ h: FitsHeader) -> (ra: Double, dec: Double)? {
        func d(_ k: String) -> Double? { parseDouble(h[k]?.trimmingCharacters(in: CharacterSet(charactersIn: " '"))) }
        if let ra = d("RA"), let dec = d("DEC") { return (ra, dec) }
        if let r = h["OBJCTRA"], let dd = h["OBJCTDEC"], let ra = sexagesimal(r, 15), let dec = sexagesimal(dd, 1) { return (ra, dec) }
        if let ra = d("CRVAL1"), let dec = d("CRVAL2") { return (ra, dec) }
        return nil
    }

    /// Arcseconds per pixel from FOCALLEN (mm) and XPIXSZ (µm), or an existing WCS.
    public static func headerScale(_ h: FitsHeader) -> Double? {
        func d(_ k: String) -> Double? { parseDouble(h[k]?.trimmingCharacters(in: CharacterSet(charactersIn: " '"))) }
        if let focal = d("FOCALLEN"), let pixel = d("XPIXSZ"), focal > 0, pixel > 0 { return 206.265 * pixel / focal }
        if let cdelt = d("CDELT2"), cdelt != 0 { return abs(cdelt) * 3600 }
        return nil
    }

    /// "00 42 44.3" or "+41 16 08" (also with ':') → degrees; hours are scaled by 15.
    public static func sexagesimal(_ s: String, _ hourFactor: Double) -> Double? {
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: " '")).split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
        guard let first = parts.first else { return nil }
        let negative = first.hasPrefix("-")
        var value = 0.0, factor = 1.0
        for part in parts {
            guard let v = parseDouble(part.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) else { return nil }
            value += v * factor; factor /= 60
        }
        return (negative ? -value : value) * hourFactor
    }
}

/// Step 8: photometric colour calibration. Needs the WCS of the plate-solve step: the Gaia stars on
/// the image are measured in R, G and B and the channels scaled so that a star of the chosen white
/// reference comes out neutral. The background is neutralised at the same time.
public final class ColorCalibrationStep: WorkflowStep {
    public static let whiteKey = "white", neutralKey = "neutral", whiteGalaxy = "galaxy", whiteVega = "vega"
    private static let s = "colorcal"

    /// The measured-colour catalogue tried first (online, short timeout); tests replace it.
    public static var onlineCatalog: any StarCatalog {
        get { online.current }
        set { online.current = newValue }
    }
    private static let online = Locked<any StarCatalog>(GaiaOnlineCatalog(useVizierFallback: false, timeout: 10))

    /// The most recent calibration (for the UI).
    public static var lastResult: ColorCalibrationResult? { last.current }
    private static let last = Locked<ColorCalibrationResult?>(nil)

    public let definition = StepDefinition.fromLanguage(.colorCalibration, .basics, s, [
        StepKit.choice(s, whiteKey, whiteGalaxy, [whiteGalaxy, whiteVega]),
        StepKit.toggle(s, neutralKey, true, advanced: true),
    ])

    public init() {}

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let input = try context.requireInput()
        let p = context.parameters
        let ct = context.cancellation
        if !input.isColor { return .unchanged(input, L.t("msg.colorcal.mono")) }
        guard let wcs = Wcs.read(input.header, imageHeight: input.height) else { throw ClearStarError(L.t("msg.colorcal.noWcs")) }

        let fovDiagDeg = sqrt(Double(input.width * input.width + input.height * input.height)) * wcs.scaleArcsec / 3600
        let centre = wcs.pixelToSky(Double(input.width - 1) / 2, Double(input.height - 1) / 2)
        context.report(0.05, L.t("msg.colorcal.catalog"))
        // Measured BP/RP colours (online) include interstellar reddening, which the T_eff colours of the
        // offline catalogue do not: the online archive briefly first, then whatever the plate solve used.
        let radius = 0.5 * fovDiagDeg + 0.05
        var stars: [CatalogStar]
        do {
            stars = try await Self.onlineCatalog.cone(centre.ra, centre.dec, radius, 14, 4000, ct)
        } catch where !ct.isCancelled && !(error is CancellationError) {
            do { stars = try await PlateSolveStep.catalogAround(centre.ra, centre.dec, radius, 14, ct) } catch let e as URLError {
                throw ClearStarError(L.f("msg.platesolve.offline", e.localizedDescription))
            }
        }

        context.report(0.2, L.t("msg.colorcal.measuring"))
        let white = p.getString(Self.whiteKey, Self.whiteGalaxy) == Self.whiteVega ? ColorCalibration.vegaBpRp : ColorCalibration.galaxyBpRp
        let catalogStars = stars
        let result = try await Task.detached(priority: .userInitiated) {
            let fwhm = try PsfMeasure.estimateFwhm(input, ct)
            let samples = try ColorCalibration.measure(input, wcs, catalogStars, fwhm: fwhm, ct)
            return ColorCalibration.fit(samples, white: white)
        }.value
        guard let result else { throw ClearStarError(L.t("msg.colorcal.fewStars")) }
        Self.last.current = result

        context.report(0.8, L.t("msg.colorcal.applying"))
        let output = ColorCalibration.apply(input, redFactor: result.redFactor, blueFactor: result.blueFactor, neutralizeBackground: p.getBool(Self.neutralKey, true))
        output.header["CLRCAL"] = "T"
        return StepResult(image: output, summary: L.f("msg.colorcal.summary", result.redFactor, result.blueFactor, result.starsUsed))
    }
}
