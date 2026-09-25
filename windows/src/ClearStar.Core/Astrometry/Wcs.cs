using System.Globalization;

namespace ClearStar.Core.Astrometry;

/// <summary>
/// Gnomonic (TAN) world coordinate system in ClearStar's internal pixel convention: 0-based
/// pixel centres, x to the right, y downward. The intermediate coordinates (xi, eta) are in
/// degrees on the tangent plane: xi = Cd11·(x−CrPix1) + Cd12·(y−CrPix2), eta = Cd21·… + Cd22·…
/// When written to a FITS header the y axis is flipped and the origin becomes 1-based.
/// </summary>
public sealed record Wcs(double Ra, double Dec, double CrPix1, double CrPix2, double Cd11, double Cd12, double Cd21, double Cd22)
{
    private const double Deg = Math.PI / 180.0;

    /// <summary>Pixel scale in arcseconds per pixel.</summary>
    public double ScaleArcsec => 3600.0 * Math.Sqrt(Math.Abs(Cd11 * Cd22 - Cd12 * Cd21));

    /// <summary>True when the image is mirrored relative to the sky (east to the right with north up).</summary>
    public bool Flipped => Cd11 * Cd22 - Cd12 * Cd21 > 0;

    /// <summary>Position angle of the image's "up" direction measured from north towards east, in degrees.</summary>
    public double RotationDegrees
    {
        get
        {
            // The direction of −y (up) on the tangent plane.
            double xi = -Cd12, eta = -Cd22;
            return NormalizeAngle(Math.Atan2(xi, eta) / Deg);
        }
    }

    public (double ra, double dec) PixelToSky(double x, double y)
    {
        double dx = x - CrPix1, dy = y - CrPix2;
        return Deproject(Cd11 * dx + Cd12 * dy, Cd21 * dx + Cd22 * dy, Ra, Dec);
    }

    /// <summary>Null when the position is on the far hemisphere.</summary>
    public (double x, double y)? SkyToPixel(double ra, double dec)
    {
        var p = Project(ra, dec, Ra, Dec);
        if (p is null) return null;
        var (xi, eta) = p.Value;
        double det = Cd11 * Cd22 - Cd12 * Cd21;
        if (Math.Abs(det) < 1e-30) return null;
        double dx = (Cd22 * xi - Cd12 * eta) / det;
        double dy = (-Cd21 * xi + Cd11 * eta) / det;
        return (CrPix1 + dx, CrPix2 + dy);
    }

    /// <summary>Tangent-plane projection (degrees) of a sky position around the tangent point.</summary>
    public static (double xi, double eta)? Project(double ra, double dec, double ra0, double dec0)
    {
        double sd = Math.Sin(dec * Deg), cd = Math.Cos(dec * Deg);
        double sd0 = Math.Sin(dec0 * Deg), cd0 = Math.Cos(dec0 * Deg);
        double dra = (ra - ra0) * Deg;
        double denom = sd * sd0 + cd * cd0 * Math.Cos(dra);
        if (denom <= 1e-9) return null;
        double xi = cd * Math.Sin(dra) / denom;
        double eta = (sd * cd0 - cd * sd0 * Math.Cos(dra)) / denom;
        return (xi / Deg, eta / Deg);
    }

    public static (double ra, double dec) Deproject(double xi, double eta, double ra0, double dec0)
    {
        double x = xi * Deg, y = eta * Deg;
        double sd0 = Math.Sin(dec0 * Deg), cd0 = Math.Cos(dec0 * Deg);
        double denom = cd0 - y * sd0;
        double ra = ra0 + Math.Atan2(x, denom) / Deg;
        double dec = Math.Atan2(sd0 + y * cd0, Math.Sqrt(x * x + denom * denom)) / Deg;
        ra %= 360.0; if (ra < 0) ra += 360.0;
        return (ra, dec);
    }

    private static double NormalizeAngle(double a) { a %= 360.0; if (a < 0) a += 360.0; return a; }

    /// <summary>Writes the standard FITS keywords (1-based pixels, y upward).</summary>
    public void WriteTo(IDictionary<string, string> header, int imageHeight)
    {
        header["CTYPE1"] = "RA---TAN";
        header["CTYPE2"] = "DEC--TAN";
        header["CRVAL1"] = F(Ra);
        header["CRVAL2"] = F(Dec);
        header["CRPIX1"] = F(CrPix1 + 1.0);
        header["CRPIX2"] = F(imageHeight - CrPix2);
        header["CD1_1"] = F(Cd11);
        header["CD1_2"] = F(-Cd12);
        header["CD2_1"] = F(Cd21);
        header["CD2_2"] = F(-Cd22);
        header["EQUINOX"] = "2000.0";
        header["RADESYS"] = "ICRS";
        header["CUNIT1"] = "deg";
        header["CUNIT2"] = "deg";
        // Legacy keywords some programs still read.
        header["CDELT1"] = F(-ScaleArcsec / 3600.0);
        header["CDELT2"] = F(ScaleArcsec / 3600.0);
        header["CROTA2"] = F(RotationDegrees);
        header["PLTSOLVD"] = "T";
    }

    public static Wcs? TryRead(IReadOnlyDictionary<string, string> header, int imageHeight)
    {
        if (!header.TryGetValue("CTYPE1", out var t) || !t.Contains("TAN", StringComparison.OrdinalIgnoreCase)) return null;
        if (!(D(header, "CRVAL1") is { } ra && D(header, "CRVAL2") is { } dec && D(header, "CRPIX1") is { } p1 && D(header, "CRPIX2") is { } p2)) return null;
        double cd11, cd12, cd21, cd22;
        if (D(header, "CD1_1") is { } a && D(header, "CD2_2") is { } d)
        {
            cd11 = a; cd22 = d; cd12 = D(header, "CD1_2") ?? 0; cd21 = D(header, "CD2_1") ?? 0;
        }
        else if (D(header, "CDELT1") is { } c1 && D(header, "CDELT2") is { } c2)
        {
            double rot = (D(header, "CROTA2") ?? 0) * Deg;
            cd11 = c1 * Math.Cos(rot); cd12 = -c2 * Math.Sin(rot); cd21 = c1 * Math.Sin(rot); cd22 = c2 * Math.Cos(rot);
        }
        else return null;
        return new Wcs(ra, dec, p1 - 1.0, imageHeight - p2, cd11, -cd12, cd21, -cd22);
    }

    private static string F(double v) => v.ToString("R", CultureInfo.InvariantCulture);
    private static double? D(IReadOnlyDictionary<string, string> h, string key) =>
        h.TryGetValue(key, out var s) && double.TryParse(s.Trim().Trim('\''), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    /// <summary>"00h42m44s" style RA text.</summary>
    public static string FormatRa(double ra)
    {
        double h = ra / 15.0; int hh = (int)h; double m = (h - hh) * 60; int mm = (int)m; double ss = (m - mm) * 60;
        return string.Format(CultureInfo.InvariantCulture, "{0:00}h{1:00}m{2:00}s", hh, mm, ss);
    }

    /// <summary>"+41°16′08″" style declination text.</summary>
    public static string FormatDec(double dec)
    {
        char sign = dec < 0 ? '−' : '+'; dec = Math.Abs(dec);
        int dd = (int)dec; double m = (dec - dd) * 60; int mm = (int)m; double ss = (m - mm) * 60;
        return string.Format(CultureInfo.InvariantCulture, "{0}{1:00}°{2:00}′{3:00}″", sign, dd, mm, ss);
    }
}
