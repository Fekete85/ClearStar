import Foundation

/// Gnomonic (TAN) world coordinate system in ClearStar's pixel convention: 0-based pixel centres, x to
/// the right, y downward. The intermediate coordinates (xi, eta) are degrees on the tangent plane:
/// xi = cd11·(x−crPix1) + cd12·(y−crPix2), eta = cd21·… + cd22·… In a FITS header the y axis is flipped
/// and the origin becomes 1-based.
public struct Wcs: Sendable, Equatable {
    public var ra: Double, dec: Double, crPix1: Double, crPix2: Double, cd11: Double, cd12: Double, cd21: Double, cd22: Double
    private static let deg = Double.pi / 180

    public init(_ ra: Double, _ dec: Double, _ crPix1: Double, _ crPix2: Double, _ cd11: Double, _ cd12: Double, _ cd21: Double, _ cd22: Double) {
        self.ra = ra; self.dec = dec; self.crPix1 = crPix1; self.crPix2 = crPix2
        self.cd11 = cd11; self.cd12 = cd12; self.cd21 = cd21; self.cd22 = cd22
    }

    /// Pixel scale in arcseconds per pixel.
    public var scaleArcsec: Double { 3600 * sqrt(abs(cd11 * cd22 - cd12 * cd21)) }

    /// True when the image is mirrored relative to the sky.
    public var flipped: Bool { cd11 * cd22 - cd12 * cd21 > 0 }

    /// Position angle of the image's "up" direction from north towards east, in degrees.
    public var rotationDegrees: Double { Self.normalizeAngle(atan2(-cd12, -cd22) / Self.deg) }

    public func pixelToSky(_ x: Double, _ y: Double) -> (ra: Double, dec: Double) {
        let dx = x - crPix1, dy = y - crPix2
        return Self.deproject(cd11 * dx + cd12 * dy, cd21 * dx + cd22 * dy, ra, dec)
    }

    /// Nil when the position is on the far hemisphere.
    public func skyToPixel(_ ra: Double, _ dec: Double) -> (x: Double, y: Double)? {
        guard let (xi, eta) = Self.project(ra, dec, self.ra, self.dec) else { return nil }
        let det = cd11 * cd22 - cd12 * cd21
        if abs(det) < 1e-30 { return nil }
        let dx = (cd22 * xi - cd12 * eta) / det
        let dy = (-cd21 * xi + cd11 * eta) / det
        return (crPix1 + dx, crPix2 + dy)
    }

    /// Tangent-plane projection (degrees) of a sky position around the tangent point.
    public static func project(_ ra: Double, _ dec: Double, _ ra0: Double, _ dec0: Double) -> (xi: Double, eta: Double)? {
        let sd = sin(dec * deg), cd = cos(dec * deg)
        let sd0 = sin(dec0 * deg), cd0 = cos(dec0 * deg)
        let dra = (ra - ra0) * deg
        let denom = sd * sd0 + cd * cd0 * cos(dra)
        if denom <= 1e-9 { return nil }
        let xi = cd * sin(dra) / denom
        let eta = (sd * cd0 - cd * sd0 * cos(dra)) / denom
        return (xi / deg, eta / deg)
    }

    public static func deproject(_ xi: Double, _ eta: Double, _ ra0: Double, _ dec0: Double) -> (ra: Double, dec: Double) {
        let x = xi * deg, y = eta * deg
        let sd0 = sin(dec0 * deg), cd0 = cos(dec0 * deg)
        let denom = cd0 - y * sd0
        var ra = ra0 + atan2(x, denom) / deg
        let dec = atan2(sd0 + y * cd0, sqrt(x * x + denom * denom)) / deg
        ra = ra.truncatingRemainder(dividingBy: 360)
        if ra < 0 { ra += 360 }
        return (ra, dec)
    }

    private static func normalizeAngle(_ a: Double) -> Double {
        var a = a.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    /// Writes the standard FITS keywords (1-based pixels, y upward).
    public func write(to header: inout FitsHeader, imageHeight: Int) {
        header["CTYPE1"] = "RA---TAN"
        header["CTYPE2"] = "DEC--TAN"
        header["CRVAL1"] = formatR(ra)
        header["CRVAL2"] = formatR(dec)
        header["CRPIX1"] = formatR(crPix1 + 1)
        header["CRPIX2"] = formatR(Double(imageHeight) - crPix2)
        header["CD1_1"] = formatR(cd11)
        header["CD1_2"] = formatR(-cd12)
        header["CD2_1"] = formatR(cd21)
        header["CD2_2"] = formatR(-cd22)
        header["EQUINOX"] = "2000.0"
        header["RADESYS"] = "ICRS"
        header["CUNIT1"] = "deg"
        header["CUNIT2"] = "deg"
        // Legacy keywords some programs still read.
        header["CDELT1"] = formatR(-scaleArcsec / 3600)
        header["CDELT2"] = formatR(scaleArcsec / 3600)
        header["CROTA2"] = formatR(rotationDegrees)
        header["PLTSOLVD"] = "T"
    }

    public static func read(_ header: FitsHeader, imageHeight: Int) -> Wcs? {
        guard let t = header["CTYPE1"], t.uppercased().contains("TAN") else { return nil }
        func d(_ k: String) -> Double? { parseDouble(header[k]?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'"))) }
        guard let ra = d("CRVAL1"), let dec = d("CRVAL2"), let p1 = d("CRPIX1"), let p2 = d("CRPIX2") else { return nil }
        var cd11: Double, cd12: Double, cd21: Double, cd22: Double
        if let a = d("CD1_1"), let dd = d("CD2_2") {
            cd11 = a; cd22 = dd; cd12 = d("CD1_2") ?? 0; cd21 = d("CD2_1") ?? 0
        } else if let c1 = d("CDELT1"), let c2 = d("CDELT2") {
            let rot = (d("CROTA2") ?? 0) * deg
            cd11 = c1 * cos(rot); cd12 = -c2 * sin(rot); cd21 = c1 * sin(rot); cd22 = c2 * cos(rot)
        } else {
            return nil
        }
        return Wcs(ra, dec, p1 - 1, Double(imageHeight) - p2, cd11, -cd12, cd21, -cd22)
    }

    /// "00h42m44s" style RA text.
    public static func formatRa(_ ra: Double) -> String {
        let h = ra / 15, hh = Int(h), m = (h - Double(hh)) * 60, mm = Int(m), ss = (m - Double(mm)) * 60
        return String(format: "%02dh%02dm%@s", hh, mm, pad2(ss))
    }

    /// "+41°16′08″" style declination text.
    public static func formatDec(_ decIn: Double) -> String {
        let sign = decIn < 0 ? "−" : "+"
        let dec = abs(decIn)
        let dd = Int(dec), m = (dec - Double(dd)) * 60, mm = Int(m), ss = (m - Double(mm)) * 60
        return String(format: "%@%02d°%02d′%@″", sign, dd, mm, pad2(ss))
    }

    /// {0:00} of .NET for a double: rounded half to even... .NET's custom format rounds half away from zero.
    private static func pad2(_ v: Double) -> String {
        let r = Int((v).rounded(.toNearestOrAwayFromZero))
        return String(format: "%02d", r)
    }
}
