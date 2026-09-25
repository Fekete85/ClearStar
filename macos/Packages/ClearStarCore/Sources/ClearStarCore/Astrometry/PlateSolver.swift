import Foundation

/// Outcome of a plate solve: the WCS plus quality figures.
public struct PlateSolveResult: Sendable {
    public var wcs: Wcs
    public var matchedStars: Int
    public var rmsArcsec: Double
    public var matches: [(star: CatalogStar, x: Float, y: Float)]
}

/// "Near" plate solver: given an approximate centre and pixel scale (FITS header or the user), the
/// catalogue stars around the centre are projected onto a tangent plane, the brightest are matched to
/// the image stars with the rotation/scale-invariant triangle matcher, and a TAN WCS is fitted by least
/// squares. Both mirror orientations are tried, so flipped images solve too.
public enum PlateSolver {
    public static func solve(_ image: AstroImage, _ catalog: [CatalogStar], raHint: Double, decHint: Double, scaleArcsecHint: Double,
                             _ ct: CancellationToken = .none, progress: ((Double) -> Void)? = nil) throws -> PlateSolveResult? {
        let w = image.width, h = image.height
        let imageStars = try StarDetector.detect(image, maxStars: 300, thresholdSigma: 5, downsample: 1, ct: ct)
        progress?(0.3)
        if imageStars.count < 10 || catalog.count < 10 { return nil }

        let scaleDeg = scaleArcsecHint / 3600
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2

        var best: PlateSolveResult?
        for mirror in [false, true] {
            try ct.check()
            var reference: [Star] = []
            var refIndex: [Int] = []
            for (i, s) in catalog.enumerated() {
                guard let (xi, eta) = Wcs.project(s.ra, s.dec, raHint, decHint) else { continue }
                let x = Float(cx + (mirror ? xi : -xi) / scaleDeg)   // east to the left unless mirrored
                let y = Float(cy - eta / scaleDeg)                   // north up (y runs downward)
                let g = s.g.isNaN ? 15 : s.g
                reference.append(Star(x, y, pow(10, -0.4 * g), 3))
                refIndex.append(i)
            }
            // The triangle matcher needs the two sets to overlap well: only the catalogue stars in an
            // image-sized window take part, first at the hinted centre, then shifted around it.
            var pairs: [(r: Star, f: Star)] = []
            var ok = false
            for (fx, fy) in windowOffsets {
                try ct.check()
                let x0 = fx * Float(w) - 0.1 * Float(w), x1 = fx * Float(w) + 1.1 * Float(w)
                let y0 = fy * Float(h) - 0.1 * Float(h), y1 = fy * Float(h) + 1.1 * Float(h)
                let window = reference.filter { $0.x > x0 && $0.x < x1 && $0.y > y0 && $0.y < y1 }
                if window.count < 10 { continue }
                guard let initial = StarMatcher.triangleMatch(window, imageStars, take: 50, takeReference: 70, minScale: 0.85, maxScale: 1.18) else { continue }
                var transform = initial
                ok = true
                for radius: Float in [40, 20, 10, 5, 3] {
                    pairs = StarMatcher.pair(reference, imageStars, transform, radius)
                    if pairs.count < 8 { ok = false; break }
                    transform = StarMatcher.fit(pairs)
                }
                if ok { break }
            }
            if !ok { continue }
            var matched: [(star: CatalogStar, x: Float, y: Float)] = []
            for (r, f) in pairs {
                if let idx = reference.firstIndex(of: r) { matched.append((catalog[refIndex[idx]], f.x, f.y)) }
            }
            guard let fitted = fitWcs(matched, decHintRa: raHint, decHint, cx, cy) else { continue }
            // Second pass with the fitted WCS: every catalogue star paired with an image star within 2 px.
            let refined = refineWithWcs(fitted.wcs, catalog, imageStars, cx, cy) ?? fitted
            if best == nil || refined.matchedStars > best!.matchedStars { best = refined }
        }
        progress?(1)
        return best
    }

    /// Window positions as fractions of the image size: centre first, then the eight neighbours.
    private static let windowOffsets: [(Float, Float)] = [(0, 0), (0.35, 0), (-0.35, 0), (0, 0.35), (0, -0.35), (0.35, 0.35), (-0.35, 0.35), (0.35, -0.35), (-0.35, -0.35)]

    private static func refineWithWcs(_ wcs: Wcs, _ catalog: [CatalogStar], _ imageStars: [Star], _ cx: Double, _ cy: Double) -> PlateSolveResult? {
        var projected: [Star] = []
        var index: [Int] = []
        for (i, s) in catalog.enumerated() {
            guard let p = wcs.skyToPixel(s.ra, s.dec) else { continue }
            projected.append(Star(Float(p.x), Float(p.y), 1, 3))
            index.append(i)
        }
        let pairs = StarMatcher.pair(projected, imageStars, .identity, 2)
        if pairs.count < 8 { return nil }
        var matched: [(star: CatalogStar, x: Float, y: Float)] = []
        for (r, f) in pairs {
            if let idx = projected.firstIndex(of: r) { matched.append((catalog[index[idx]], f.x, f.y)) }
        }
        return fitWcs(matched, decHintRa: wcs.ra, wcs.dec, cx, cy)
    }

    /// Least-squares TAN fit: xi/eta of the matched stars (projected around ra0/dec0) as a linear
    /// function of the pixel offsets from the image centre; the tangent point is moved to the image
    /// centre and the fit repeated so the constant terms vanish.
    public static func fitWcs(_ matched: [(star: CatalogStar, x: Float, y: Float)], decHintRa ra0: Double, _ dec0: Double, _ cx: Double, _ cy: Double) -> PlateSolveResult? {
        if matched.count < 6 { return nil }
        var ra = ra0, dec = dec0
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0, e = 0.0, f = 0.0
        for _ in 0 ..< 3 {
            var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, n = 0.0
            var sxXi = 0.0, syXi = 0.0, sXi = 0.0, sxEta = 0.0, syEta = 0.0, sEta = 0.0
            for (star, px, py) in matched {
                guard let p = Wcs.project(star.ra, star.dec, ra, dec) else { continue }
                let dx = Double(px) - cx, dy = Double(py) - cy
                sxx += dx * dx; sxy += dx * dy; syy += dy * dy; sx += dx; sy += dy; n += 1
                sxXi += dx * p.xi; syXi += dy * p.xi; sXi += p.xi
                sxEta += dx * p.eta; syEta += dy * p.eta; sEta += p.eta
            }
            if n < 6 { return nil }
            guard let r1 = solve3(sxx, sxy, sx, sxy, syy, sy, sx, sy, n, sxXi, syXi, sXi),
                  let r2 = solve3(sxx, sxy, sx, sxy, syy, sy, sx, sy, n, sxEta, syEta, sEta) else { return nil }
            (a, b, c) = r1
            (d, e, f) = r2
            // Move the tangent point to where the image centre actually points.
            (ra, dec) = Wcs.deproject(c, f, ra, dec)
        }
        let wcs = Wcs(ra, dec, cx, cy, a, b, d, e)
        var se = 0.0, m = 0
        for (star, px, py) in matched {
            guard let p = wcs.skyToPixel(star.ra, star.dec) else { continue }
            se += (p.x - Double(px)) * (p.x - Double(px)) + (p.y - Double(py)) * (p.y - Double(py)); m += 1
        }
        let rmsPx = sqrt(se / Double(max(m, 1)))
        return PlateSolveResult(wcs: wcs, matchedStars: m, rmsArcsec: rmsPx * wcs.scaleArcsec, matches: matched)
    }

    /// Solves the 3×3 system by Cramer's rule.
    private static func solve3(_ m11: Double, _ m12: Double, _ m13: Double, _ m21: Double, _ m22: Double, _ m23: Double,
                               _ m31: Double, _ m32: Double, _ m33: Double, _ r1: Double, _ r2: Double, _ r3: Double) -> (Double, Double, Double)? {
        let det = m11 * (m22 * m33 - m23 * m32) - m12 * (m21 * m33 - m23 * m31) + m13 * (m21 * m32 - m22 * m31)
        if abs(det) < 1e-18 { return nil }
        let x = (r1 * (m22 * m33 - m23 * m32) - m12 * (r2 * m33 - m23 * r3) + m13 * (r2 * m32 - m22 * r3)) / det
        let y = (m11 * (r2 * m33 - m23 * r3) - r1 * (m21 * m33 - m23 * m31) + m13 * (m21 * r3 - r2 * m31)) / det
        let z = (m11 * (m22 * r3 - r2 * m32) - m12 * (m21 * r3 - r2 * m31) + r1 * (m21 * m32 - m22 * m31)) / det
        return (x, y, z)
    }
}

/// One measured star: catalogue colour and the instrumental colour indices (magnitudes).
public struct ColorSample: Sendable { public var bpRp: Float, rMinusG: Float, bMinusG: Float }

/// Result of a photometric colour calibration: channel factors and fit quality.
public struct ColorCalibrationResult: Sendable {
    public var redFactor: Float, blueFactor: Float, starsUsed: Int, slopeR: Float, slopeB: Float, scatterR: Float, scatterB: Float
}

/// Photometric colour calibration (SPCC-style): the Gaia stars on the image measured by aperture
/// photometry in R, G, B; −2.5·log10(R/G) and −2.5·log10(B/G) fitted as lines against BP−RP; the fit at
/// the white reference gives the factors that make such a star white.
public enum ColorCalibration {
    /// BP−RP of the white reference: a Sun-like (G2V) star / average spiral galaxy.
    public static let galaxyBpRp: Float = 0.82
    /// BP−RP of an A0V (Vega-like) star.
    public static let vegaBpRp: Float = 0.0

    /// Aperture photometry of the catalogue stars that fall on the image (positions from the WCS).
    public static func measure(_ image: AstroImage, _ wcs: Wcs, _ catalog: [CatalogStar], fwhm: Float, _ ct: CancellationToken = .none) throws -> [ColorSample] {
        if image.channels != 3 { return [] }
        let w = image.width, h = image.height
        let rAp = max(3, 1.5 * fwhm), rIn = max(rAp + 2, 3 * fwhm), rOut = rIn + max(3, 1.5 * fwhm)
        let reach = Int(rOut.rounded(.up)) + 1
        let planes = [image.channelArray(0), image.channelArray(1), image.channelArray(2)]
        var samples: [ColorSample] = []

        // Blended stars are skipped: another catalogue star within the annulus.
        var positions: [(x: Double, y: Double, idx: Int)] = []
        for (i, s) in catalog.enumerated() {
            guard let p = wcs.skyToPixel(s.ra, s.dec) else { continue }
            positions.append((p.x, p.y, i))
        }
        var grid: [Cell: [Int]] = [:]
        let cell = rOut * 2
        for p in positions { grid[Cell(x: Int((Float(p.x) / cell).rounded(.down)), y: Int((Float(p.y) / cell).rounded(.down))), default: []].append(p.idx) }
        var posByIdx: [Int: (Double, Double)] = [:]
        for p in positions { posByIdx[p.idx] = (p.x, p.y) }

        for (x, y, idx) in positions {
            try ct.check()
            let star = catalog[idx]
            if star.bp.isNaN || star.rp.isNaN { continue }
            let cxp = Int(x.roundedEven), cyp = Int(y.roundedEven)
            if cxp < reach || cyp < reach || cxp >= w - reach || cyp >= h - reach { continue }

            var crowded = false
            let key = Cell(x: Int((Float(x) / cell).rounded(.down)), y: Int((Float(y) / cell).rounded(.down)))
            outer: for i in -1 ... 1 {
                for j in -1 ... 1 {
                    guard let list = grid[Cell(x: key.x + i, y: key.y + j)] else { continue }
                    for other in list where other != idx {
                        let (ox, oy) = posByIdx[other]!
                        let d2 = (ox - x) * (ox - x) + (oy - y) * (oy - y)
                        if d2 < Double(rOut * rOut) && catalog[other].g < star.g + 3 { crowded = true; break outer }
                    }
                }
            }
            if crowded { continue }

            var fr: Float = 0, fg: Float = 0, fb: Float = 0, peak: Float = 0
            var ok = true
            for c in 0 ..< 3 {
                let data = planes[c]
                var ring: [Float] = []
                var sum = 0.0
                var n = 0
                for dy in -reach ... reach {
                    for dx in -reach ... reach {
                        let d = sqrt(Float(dx * dx + dy * dy))
                        let v = data[(cyp + dy) * w + cxp + dx]
                        if d >= rIn && d <= rOut { ring.append(v) } else if d <= rAp { sum += Double(v); n += 1; peak = max(peak, v) }
                    }
                }
                if ring.count < 8 || n < 4 { ok = false; break }
                let bg = ImageStats.median(ring)
                let mad = ImageStats.median(ring.map { abs($0 - bg) })
                let flux = Float(sum - Double(Float(n) * bg)) // n·bg is a float product in the C# code
                // Signal-to-noise gate: the aperture flux must stand well above the background noise.
                if flux < 25 * mad * sqrt(Float(n)) { ok = false; break }
                if c == 0 { fr = flux } else if c == 1 { fg = flux } else { fb = flux }
            }
            if !ok || peak > 0.9 || fr <= 0 || fg <= 0 || fb <= 0 { continue }
            samples.append(ColorSample(bpRp: star.bpRp, rMinusG: -2.5 * log10(fr / fg), bMinusG: -2.5 * log10(fb / fg)))
        }
        return samples
    }

    /// Robust line fits and the factors for the white reference.
    public static func fit(_ samples: [ColorSample], white: Float, minStars: Int = 12) -> ColorCalibrationResult? {
        if samples.count < minStars { return nil }
        let (aR, bR, nR, sR) = robustLine(samples.map { ($0.bpRp, $0.rMinusG) })
        let (aB, bB, nB, sB) = robustLine(samples.map { ($0.bpRp, $0.bMinusG) })
        if min(nR, nB) < minStars { return nil }
        let mR = aR * white + bR, mB = aB * white + bB
        // A white star must end up with R = G = B: scale R and B by their predicted deficit.
        let kR = pow(10, 0.4 * mR), kB = pow(10, 0.4 * mB)
        if !kR.isFinite || !kB.isFinite || kR < 0.2 || kR > 5 || kB < 0.2 || kB > 5 { return nil }
        return ColorCalibrationResult(redFactor: kR, blueFactor: kB, starsUsed: min(nR, nB), slopeR: aR, slopeB: aB, scatterR: sR, scatterB: sB)
    }

    /// Least squares with rounds of 2.5σ rejection. Returns slope, intercept, stars kept, scatter.
    public static func robustLine(_ pts: [(Float, Float)]) -> (a: Float, b: Float, n: Int, scatter: Float) {
        var keep = pts
        var a: Float = 0, b: Float = 0, scatter: Float = 0
        for _ in 0 ..< 4 {
            if keep.count < 3 { break }
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            let n = Double(keep.count)
            for (x, y) in keep {
                sx += Double(x); sy += Double(y); sxx += Double(x * x); sxy += Double(x * y)
            }
            let det = n * sxx - sx * sx
            if abs(det) < 1e-9 { a = 0; b = Float(sy / n) } else { a = Float((n * sxy - sx * sy) / det); b = Float((sy - Double(a) * sx) / n) }
            let resid = keep.map { $0.1 - (a * $0.0 + b) }
            let med = ImageStats.median(resid)
            let mad = ImageStats.median(resid.map { abs($0 - med) })
            scatter = max(mad * 1.4826, 1e-4)
            var next: [(Float, Float)] = []
            for (i, p) in keep.enumerated() where abs(resid[i] - med) <= 2.5 * scatter { next.append(p) }
            if next.count == keep.count { break }
            keep = next
        }
        return (a, b, keep.count, scatter)
    }

    /// Applies the factors around a neutral background: (v − bg_c)·k_c + bg.
    public static func apply(_ image: AstroImage, redFactor kR: Float, blueFactor kB: Float, neutralizeBackground: Bool) -> AstroImage {
        let stats = ImageStats.computeAll(image)
        let k: [Float] = [kR, 1, kB]
        let bg = [stats[0].median, stats[1].median, stats[2].median]
        let target = neutralizeBackground ? ImageStats.median(bg) : 0
        let result = image.createEmptyLike()
        let n = image.pixelsPerChannel
        for c in 0 ..< 3 {
            let kc = k[c], bgc = neutralizeBackground ? bg[c] : 0, add = neutralizeBackground ? target : 0
            for i in c * n ..< (c + 1) * n { result.data[i] = ((image.data[i] - bgc) * kc + add).clamped(0, 1) }
        }
        return result
    }
}
