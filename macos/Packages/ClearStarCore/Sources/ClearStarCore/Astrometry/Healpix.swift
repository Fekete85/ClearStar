import Foundation

/// Minimal HEALPix (NESTED scheme): pixel centres for an order and cone queries by pixel-centre
/// distance. Enough to read Siril's HEALPix-ordered catalogue files.
public final class Healpix: @unchecked Sendable {
    private static let jrll = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]
    private static let jpll = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7]

    public let order: Int
    public let nside: Int
    public let npix: Int
    /// Unit vectors of every pixel centre (x, y, z interleaved).
    private var centres: [Float]
    /// Angular radius (rad) that certainly contains a whole pixel around its centre.
    public let pixelRadius: Double

    private static let cache = Locked<[Int: Healpix]>([:])

    public static func forOrder(_ order: Int) -> Healpix {
        if let h = cache.current[order] { return h }
        let h = Healpix(order)
        cache.withLock { $0[order] = h }
        return h
    }

    private init(_ order: Int) {
        self.order = order
        nside = 1 << order
        npix = 12 * nside * nside
        centres = [Float](repeating: 0, count: npix * 3)
        // A pixel's farthest corner is at most ~1.362·(pixel "side") from its centre; a safe bound.
        pixelRadius = 1.362 * sqrt(4 * Double.pi / Double(npix))
        let n = npix
        let me = self
        centres.withUnsafeMutableBufferPointer { c in
            parallelFor(n) { p in
                let (z, phi) = me.pixToZPhi(p)
                let s = sqrt(max(0, 1 - z * z))
                c[p * 3] = Float(s * cos(phi))
                c[p * 3 + 1] = Float(s * sin(phi))
                c[p * 3 + 2] = Float(z)
            }
        }
    }

    /// (z = cos θ, φ) of a NESTED pixel centre (from the HEALPix reference implementation).
    public func pixToZPhi(_ pix: Int) -> (z: Double, phi: Double) {
        let npface = nside * nside
        let face = pix / npface
        let ipf = pix & (npface - 1)
        let ix = Self.compressBits(ipf), iy = Self.compressBits(ipf >> 1)
        let nl4 = 4 * nside
        let fact2 = 4.0 / Double(npix)
        let jr = Self.jrll[face] * nside - ix - iy - 1
        var nr: Int, kshift: Int, z: Double
        if jr < nside {
            nr = jr; z = 1 - Double(nr * nr) * fact2; kshift = 0
        } else if jr > 3 * nside {
            nr = nl4 - jr; z = Double(nr * nr) * fact2 - 1; kshift = 0
        } else {
            let fact1 = Double(nside << 1) * fact2
            nr = nside; z = Double(2 * nside - jr) * fact1; kshift = (jr - nside) & 1
        }
        var jp = (Self.jpll[face] * nr + ix - iy + 1 + kshift) / 2
        if jp > nl4 { jp -= nl4 }
        if jp < 1 { jp += nl4 }
        let phi = (Double(jp) - Double(kshift + 1) * 0.5) * (Double.pi / 2 / Double(nr))
        return (z, phi)
    }

    private static func compressBits(_ value: Int) -> Int {
        var v = UInt64(value) & 0x5555555555555555
        v = (v | (v >> 1)) & 0x3333333333333333
        v = (v | (v >> 2)) & 0x0f0f0f0f0f0f0f0f
        v = (v | (v >> 4)) & 0x00ff00ff00ff00ff
        v = (v | (v >> 8)) & 0x0000ffff0000ffff
        v = (v | (v >> 16)) & 0x00000000ffffffff
        return Int(v)
    }

    /// Pixels whose area may intersect the cone (inclusive), in increasing order.
    public func queryDiscInclusive(_ raDeg: Double, _ decDeg: Double, _ radiusDeg: Double) -> [Int] {
        let ra = raDeg * .pi / 180, dec = decDeg * .pi / 180
        let cx = cos(dec) * cos(ra), cy = cos(dec) * sin(ra), cz = sin(dec)
        let limit = cos(min(Double.pi, radiusDeg * .pi / 180 + pixelRadius))
        var result: [Int] = []
        centres.withUnsafeBufferPointer { c in
            for p in 0 ..< npix {
                let dot = Double(c[p * 3]) * cx + Double(c[p * 3 + 1]) * cy + Double(c[p * 3 + 2]) * cz
                if dot >= limit { result.append(p) }
            }
        }
        return result
    }
}
