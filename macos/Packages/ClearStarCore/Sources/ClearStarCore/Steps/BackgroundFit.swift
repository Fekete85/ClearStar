import Foundation

/// Polynomial background model: grid sampling, fit with rejection of bright cells (nebula, galaxy,
/// star), subtraction. The stack uses it per frame (plane) like Siril's seqsubsky.
public enum BackgroundFit {
    /// Fits and subtracts the model per channel. `output` may be `input` itself (in place).
    /// Returns the accepted sample points of channel 0 (normalised 0..1) and the degree actually used.
    public static func flatten(_ input: AstroImage, _ output: AstroImage, degree: Int, tolerance: Float, columns: Int,
                               _ ct: CancellationToken, report: ((Double, String) -> Void)? = nil) throws -> (points: [(x: Float, y: Float)], degree: Int) {
        let rows = max(4, Int((Double(columns * input.height) / Double(input.width)).roundedEven))
        var points: [(x: Float, y: Float)] = []
        var degree = degree
        for c in 0 ..< input.channels {
            try ct.check()
            report?(Double(c) / Double(input.channels), L.t("msg.bge.collecting"))
            let samples = collectSamples(input, c, columns, rows)
            report?((Double(c) + 0.5) / Double(input.channels), L.t("msg.bge.fitting"))
            let (coeffs, accepted) = fitWithRejection(samples, &degree, tolerance)
            if c == 0 { points = accepted.map { (Float(($0.x + 1) / 2), Float(($0.y + 1) / 2)) } }
            try subtractModel(input, output, c, coeffs, degree, ct)
        }
        return (points, degree)
    }

    typealias Sample = (x: Double, y: Double, v: Double)

    /// Cell medians with normalised (−1..1) coordinates.
    static func collectSamples(_ img: AstroImage, _ c: Int, _ columns: Int, _ rows: Int) -> [Sample] {
        let tileW = img.width / columns, tileH = img.height / rows
        let perTile = min(tileW * tileH, 1024)
        let stride = max(1, tileW * tileH / max(perTile, 1))
        var medians = [Float](repeating: 0, count: columns * rows)
        let offset = c * img.pixelsPerChannel, width = img.width

        // Rows of cells in parallel. Pixels with 0 (no data, e.g. the corners of rotated frames) are not background.
        img.data.withUnsafeBufferPointer { data in
            medians.withUnsafeMutableBufferPointer { med in
                parallelFor(rows) { ty in
                    var buffer = [Float](repeating: 0, count: perTile)
                    for tx in 0 ..< columns {
                        let x0 = tx * tileW, y0 = ty * tileH
                        var n = 0, total = 0, k = 0
                        while k < tileW * tileH && total < perTile {
                            let v = data[offset + (y0 + k / tileW) * width + x0 + k % tileW]
                            if v > 0 { buffer[n] = v; n += 1 }
                            k += stride; total += 1
                        }
                        if n < total / 2 { med[ty * columns + tx] = .nan; continue }
                        buffer[0 ..< n].sort()
                        med[ty * columns + tx] = n % 2 == 1 ? buffer[n / 2] : 0.5 * (buffer[n / 2 - 1] + buffer[n / 2])
                    }
                }
            }
        }

        var samples: [Sample] = []
        samples.reserveCapacity(columns * rows)
        for ty in 0 ..< rows {
            for tx in 0 ..< columns {
                let m = medians[ty * columns + tx]
                if m.isNaN { continue }
                samples.append(((Double(tx * tileW) + Double(tileW) / 2.0) / Double(img.width) * 2 - 1,
                                (Double(ty * tileH) + Double(tileH) / 2.0) / Double(img.height) * 2 - 1, Double(m)))
            }
        }
        return samples
    }

    /// Iterative fit: first a plane, then cells too bright relative to the residual scatter (nebula,
    /// galaxy, star) are dropped and the final degree is fitted to the rest. Only bright deviations are
    /// punished – dark cells are real background.
    static func fitWithRejection(_ all: [Sample], _ degree: inout Int, _ tolerance: Float) -> (coeffs: [Double], accepted: [Sample]) {
        var accepted = all
        var coeffs = fitPolynomial(accepted, 1)
        var fitDegree = 1
        var t = [Double](repeating: 0, count: polyTerms(maxDegree))
        for iter in 0 ..< 4 {
            let n = polyTerms(fitDegree)
            var residuals = [Double](repeating: 0, count: all.count)
            for i in 0 ..< all.count {
                basis(all[i].x, all[i].y, fitDegree, &t)
                var m = 0.0
                for k in 0 ..< n { m += coeffs[k] * t[k] }
                residuals[i] = all[i].v - m
            }
            let sigma = 1.4826 * Double(ImageStats.median(residuals.map { Float(abs($0)) }))
            let limit = Double(tolerance) * max(sigma, 1e-6)
            var kept: [Sample] = []
            for i in 0 ..< all.count where residuals[i] <= limit { kept.append(all[i]) }
            var nextDegree = iter >= 1 ? degree : 1
            if kept.count < polyTerms(nextDegree) + 3 { nextDegree = 1 }
            if kept.count < 6 { break }
            accepted = kept
            fitDegree = nextDegree
            coeffs = fitPolynomial(accepted, fitDegree)
        }
        degree = fitDegree
        return (coeffs, accepted)
    }

    /// Highest polynomial degree the basis supports (15 terms).
    static let maxDegree = 4
    static func polyTerms(_ degree: Int) -> Int { (degree + 1) * (degree + 2) / 2 }

    static func basis(_ x: Double, _ y: Double, _ degree: Int, _ out: inout [Double]) {
        var xp = [Double](repeating: 0, count: 5), yp = [Double](repeating: 0, count: 5)
        xp[0] = 1; yp[0] = 1
        if degree >= 1 { for i in 1 ... degree { xp[i] = xp[i - 1] * x; yp[i] = yp[i - 1] * y } }
        var k = 0
        for d in 0 ... degree {
            for i in 0 ... d { out[k] = xp[d - i] * yp[i]; k += 1 }
        }
    }

    /// Least squares via the normal equations (at most 15 terms).
    static func fitPolynomial(_ samples: [Sample], _ degree: Int) -> [Double] {
        let n = polyTerms(degree)
        var ata = [Double](repeating: 0, count: n * n)
        var atb = [Double](repeating: 0, count: n)
        var t = [Double](repeating: 0, count: n)
        for s in samples {
            basis(s.x, s.y, degree, &t)
            for i in 0 ..< n {
                atb[i] += t[i] * s.v
                for j in 0 ..< n { ata[i * n + j] += t[i] * t[j] }
            }
        }
        // Slight regularisation for numerical stability.
        for i in 0 ..< n { ata[i * n + i] += 1e-9 }
        return solveGauss(&ata, &atb, n)
    }

    static func solveGauss(_ a: inout [Double], _ b: inout [Double], _ n: Int) -> [Double] {
        for col in 0 ..< n {
            var pivot = col
            for r in col + 1 ..< max(col + 1, n) where abs(a[r * n + col]) > abs(a[pivot * n + col]) { pivot = r }
            if pivot != col {
                for k in 0 ..< n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            let p = a[col * n + col]
            if abs(p) < 1e-14 { continue }
            for r in col + 1 ..< max(col + 1, n) {
                let f = a[r * n + col] / p
                if f == 0 { continue }
                for k in col ..< n { a[r * n + k] -= f * a[col * n + k] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in r + 1 ..< max(r + 1, n) { s -= a[r * n + k] * x[k] }
            x[r] = abs(a[r * n + r]) < 1e-14 ? 0 : s / a[r * n + r]
        }
        return x
    }

    static func subtractModel(_ input: AstroImage, _ output: AstroImage, _ c: Int, _ coeffs: [Double], _ degree: Int, _ ct: CancellationToken) throws {
        let w = input.width, h = input.height, n = polyTerms(degree)
        let offset = c * input.pixelsPerChannel
        // The model's mean is added back so the background lands on a natural dark level, not 0.
        var modelMean = 0.0
        do {
            var t = [Double](repeating: 0, count: n)
            var cnt = 0
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    basis(Double(x) / Double(w) * 2 - 1, Double(y) / Double(h) * 2 - 1, degree, &t)
                    var m = 0.0
                    for i in 0 ..< n { m += coeffs[i] * t[i] }
                    modelMean += m; cnt += 1
                    x += max(1, w / 64)
                }
                y += max(1, h / 64)
            }
            modelMean /= Double(max(cnt, 1))
        }
        let pedestal = Float(modelMean)

        // Per row the model folds into a polynomial in x: m(x) = Σ_j a_j(y)·x^j, so every pixel is one Horner evaluation.
        let body: (UnsafeBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) throws -> Void = { src, dst in
            try parallelFor(h, ct) { y in
                let ny = Double(y) / Double(h) * 2 - 1
                var yp = [Double](repeating: 0, count: 5), a = [Double](repeating: 0, count: 5)
                yp[0] = 1
                if degree >= 1 { for i in 1 ... degree { yp[i] = yp[i - 1] * ny } }
                var k = 0
                for d in 0 ... degree {
                    for i in 0 ... d { a[d - i] += coeffs[k] * yp[i]; k += 1 }   // x^(d-i) · y^i
                }
                let sx = 2.0 / Double(w)
                let row = offset + y * w
                for x in 0 ..< w {
                    let nx = Double(x) * sx - 1
                    var m = a[degree]
                    if degree >= 1 { for j in stride(from: degree - 1, through: 0, by: -1) { m = m * nx + a[j] } }
                    dst[row + x] = src[row + x] - Float(m) + pedestal
                }
            }
        }
        if input === output {
            try output.data.withUnsafeMutableBufferPointer { d in try body(UnsafeBufferPointer(d), d) }
        } else {
            try input.data.withUnsafeBufferPointer { s in try output.data.withUnsafeMutableBufferPointer { d in try body(s, d) } }
        }
    }
}
