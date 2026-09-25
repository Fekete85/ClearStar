import Foundation

/// Resizing and smoothing of one channel (planar float images).
public enum Resample {
    /// Area averaging when shrinking (any ratio), bilinear when enlarging.
    public static func resize(_ src: [Float], _ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: dw * dh)
        if dw <= sw && dh <= sh {
            // Area average: every target pixel is the (sub-pixel weighted) mean of a source rectangle.
            let sx = Double(sw) / Double(dw), sy = Double(sh) / Double(dh)
            src.withUnsafeBufferPointer { s in
                for y in 0 ..< dh {
                    let y0 = Double(y) * sy, y1 = Double(y + 1) * sy
                    let iy0 = Int(y0), iy1 = min(sh - 1, Int(y1.rounded(.up)) - 1)
                    for x in 0 ..< dw {
                        let x0 = Double(x) * sx, x1 = Double(x + 1) * sx
                        let ix0 = Int(x0), ix1 = min(sw - 1, Int(x1.rounded(.up)) - 1)
                        var sum = 0.0, wsum = 0.0
                        if iy0 <= iy1 {
                            for yy in iy0 ... iy1 {
                                let wy = min(y1, Double(yy + 1)) - max(y0, Double(yy))
                                if wy <= 0 { continue }
                                let row = yy * sw
                                if ix0 > ix1 { continue }
                                for xx in ix0 ... ix1 {
                                    let wx = min(x1, Double(xx + 1)) - max(x0, Double(xx))
                                    if wx <= 0 { continue }
                                    sum += Double(s[row + xx]) * wx * wy
                                    wsum += wx * wy
                                }
                            }
                        }
                        dst[y * dw + x] = wsum > 0 ? Float(sum / wsum) : 0
                    }
                }
            }
            return dst
        }

        // Bilinear enlargement (pixel centres aligned).
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                parallelFor(dh) { y in
                    let fy = (Double(y) + 0.5) * Double(sh) / Double(dh) - 0.5
                    let y0 = Int(fy.rounded(.down)).clamped(0, sh - 1), y1 = min(y0 + 1, sh - 1)
                    let ty = Float((fy - Double(y0)).clamped(0, 1))
                    for x in 0 ..< dw {
                        let fx = (Double(x) + 0.5) * Double(sw) / Double(dw) - 0.5
                        let x0 = Int(fx.rounded(.down)).clamped(0, sw - 1), x1 = min(x0 + 1, sw - 1)
                        let tx = Float((fx - Double(x0)).clamped(0, 1))
                        let a = s[y0 * sw + x0] * (1 - tx) + s[y0 * sw + x1] * tx
                        let b = s[y1 * sw + x0] * (1 - tx) + s[y1 * sw + x1] * tx
                        d[y * dw + x] = a * (1 - ty) + b * ty
                    }
                }
            }
        }
        return dst
    }

    /// Separable Gaussian blur with mirrored edges.
    public static func gaussianBlur(_ src: [Float], _ w: Int, _ h: Int, _ sigma: Float) -> [Float] {
        if sigma <= 0 { return src }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: 2 * radius + 1)
        var sum: Float = 0
        for i in -radius ... radius {
            kernel[i + radius] = exp(Float(-i * i) / (2 * sigma * sigma))
            sum += kernel[i + radius]
        }
        for i in 0 ..< kernel.count { kernel[i] /= sum }

        var tmp = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in
            for y in 0 ..< h {
                for x in 0 ..< w {
                    var acc: Float = 0
                    for k in -radius ... radius {
                        var xx = x + k
                        if xx < 0 { xx = -xx }
                        if xx >= w { xx = 2 * w - xx - 2 }
                        acc += s[y * w + xx.clamped(0, w - 1)] * kernel[k + radius]
                    }
                    tmp[y * w + x] = acc
                }
            }
        }
        var dst = [Float](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var acc: Float = 0
                for k in -radius ... radius {
                    var yy = y + k
                    if yy < 0 { yy = -yy }
                    if yy >= h { yy = 2 * h - yy - 2 }
                    acc += tmp[yy.clamped(0, h - 1) * w + x] * kernel[k + radius]
                }
                dst[y * w + x] = acc
            }
        }
        return dst
    }
}
