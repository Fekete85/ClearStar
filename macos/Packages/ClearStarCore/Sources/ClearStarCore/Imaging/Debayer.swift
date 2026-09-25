import Foundation

/// Layout of the Bayer filter: the colours of the top-left 2×2 block in reading order.
public enum BayerPattern: String, CaseIterable, Sendable {
    case RGGB, BGGR, GRBG, GBRG
}

/// Turns a mono raw (CFA) image into colour. Bilinear interpolation: the two missing colours of
/// every pixel are averaged from the neighbours. Fast; the remaining artefacts average out in the stack.
public enum Debayer {
    public static func parse(_ text: String?) -> BayerPattern? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return BayerPattern(rawValue: t.uppercased())
    }

    /// FITS stores the rows bottom-up, we top-down; the vertical flip swaps the pattern's two rows
    /// for an even height (GRBG ↔ BGGR, RGGB ↔ GBRG).
    public static func flipRows(_ p: BayerPattern) -> BayerPattern {
        switch p {
        case .RGGB: return .GBRG
        case .GBRG: return .RGGB
        case .GRBG: return .BGGR
        case .BGGR: return .GRBG
        }
    }

    /// Colour channel (0=R, 1=G, 2=B) at pixel (x, y).
    static func colorAt(_ p: BayerPattern, _ x: Int, _ y: Int) -> Int {
        let i = (y & 1) * 2 + (x & 1)
        switch p {
        case .RGGB: return [0, 1, 1, 2][i]
        case .BGGR: return [2, 1, 1, 0][i]
        case .GRBG: return [1, 0, 2, 1][i]
        case .GBRG: return [1, 2, 0, 1][i]
        }
    }

    public static func bilinear(_ cfa: AstroImage, _ pattern: BayerPattern) -> AstroImage {
        precondition(cfa.channels == 1, "A debayerezéshez egycsatornás kép kell.")
        let w = cfa.width, h = cfa.height, n = w * h
        let rgb = AstroImage(width: w, height: h, channels: 3, header: cfa.header)
        let c00 = colorAt(pattern, 0, 0), c10 = colorAt(pattern, 1, 0), c01 = colorAt(pattern, 0, 1), c11 = colorAt(pattern, 1, 1)
        cfa.data.withUnsafeBufferPointer { src in
            rgb.data.withUnsafeMutableBufferPointer { dst in
                parallelFor(h) { y in
                    let ym = max(y - 1, 0) * w, yp = min(y + 1, h - 1) * w, y0 = y * w
                    for x in 0 ..< w {
                        let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                        let here = (y & 1) == 0 ? ((x & 1) == 0 ? c00 : c10) : ((x & 1) == 0 ? c01 : c11)
                        let v = src[y0 + x]
                        let hAvg = 0.5 * (src[y0 + xm] + src[y0 + xp])
                        let vAvg = 0.5 * (src[ym + x] + src[yp + x])
                        let cross = 0.5 * (hAvg + vAvg)
                        let diag = 0.25 * (src[ym + xm] + src[ym + xp] + src[yp + xm] + src[yp + xp])
                        var r: Float, g: Float, b: Float
                        if here == 1 {
                            // Green pixel: the colour in its row horizontally, the other vertically.
                            let rowColor = (x & 1) == 0 ? ((y & 1) == 0 ? c10 : c11) : ((y & 1) == 0 ? c00 : c01)
                            g = v
                            if rowColor == 0 { r = hAvg; b = vAvg } else { b = hAvg; r = vAvg }
                        } else {
                            g = cross
                            if here == 0 { r = v; b = diag } else { b = v; r = diag }
                        }
                        let i = y0 + x
                        dst[i] = r; dst[n + i] = g; dst[2 * n + i] = b
                    }
                }
            }
        }
        rgb.header.remove("BAYERPAT")
        rgb.header["DEBAYER"] = pattern.rawValue
        return rgb
    }
}
