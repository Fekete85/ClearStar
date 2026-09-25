using ClearStar.Core.Imaging;
using ClearStar.Core.Registration;

namespace ClearStar.Core.Astrometry;

/// <summary>Outcome of a plate solve: the WCS plus quality figures.</summary>
public sealed record PlateSolveResult(Wcs Wcs, int MatchedStars, double RmsArcsec, IReadOnlyList<(CatalogStar star, float x, float y)> Matches);

/// <summary>
/// "Near" plate solver: given an approximate centre and pixel scale (from the FITS header or the
/// user), catalogue stars around the centre are projected onto a tangent plane, the brightest ones
/// are matched to the detected image stars with the rotation/scale-invariant triangle matcher, and
/// a TAN WCS is fitted by least squares (linear CD matrix, tangent point at the image centre).
/// Both mirror orientations are tried, so flipped images solve too.
/// </summary>
public static class PlateSolver
{
    public static PlateSolveResult? Solve(AstroImage image, IReadOnlyList<CatalogStar> catalog, double raHint, double decHint, double scaleArcsecHint,
        CancellationToken ct = default, Action<double>? progress = null)
    {
        int w = image.Width, h = image.Height;
        var imageStars = StarDetector.Detect(image, maxStars: 300, thresholdSigma: 5f, downsample: 1, ct: ct);
        progress?.Invoke(0.3);
        if (imageStars.Count < 10 || catalog.Count < 10) return null;

        double scaleDeg = scaleArcsecHint / 3600.0;
        double cx = (w - 1) / 2.0, cy = (h - 1) / 2.0;

        // Projected catalogue in "pixels" around the hinted centre; try normal and mirrored orientation.
        PlateSolveResult? best = null;
        foreach (bool mirror in new[] { false, true })
        {
            ct.ThrowIfCancellationRequested();
            var reference = new List<Star>(catalog.Count);
            var refIndex = new List<int>(catalog.Count);
            for (int i = 0; i < catalog.Count; i++)
            {
                var p = Wcs.Project(catalog[i].Ra, catalog[i].Dec, raHint, decHint);
                if (p is null) continue;
                var (xi, eta) = p.Value;
                float x = (float)(cx + (mirror ? xi : -xi) / scaleDeg);   // east to the left unless mirrored
                float y = (float)(cy - eta / scaleDeg);                  // north up (y runs downward)
                float g = float.IsNaN(catalog[i].G) ? 15f : catalog[i].G;
                reference.Add(new Star(x, y, MathF.Pow(10f, -0.4f * g), 3f));
                refIndex.Add(i);
            }
            // The triangle matcher needs the two star sets to overlap well, so only the catalogue stars
            // inside an image-sized window take part. The window starts at the hinted centre and, if
            // that fails, is shifted around it to cover a hint that is off by up to ~40% of the field.
            List<(Star r, Star f)> pairs = [];
            bool ok = false;
            foreach (var (fx, fy) in WindowOffsets)
            {
                ct.ThrowIfCancellationRequested();
                float x0 = fx * w - 0.1f * w, x1 = fx * w + 1.1f * w, y0 = fy * h - 0.1f * h, y1 = fy * h + 1.1f * h;
                var window = new List<Star>();
                for (int i = 0; i < reference.Count; i++)
                    if (reference[i].X > x0 && reference[i].X < x1 && reference[i].Y > y0 && reference[i].Y < y1) window.Add(reference[i]);
                if (window.Count < 10) continue;
                var initial = StarMatcher.TriangleMatch(window, imageStars, take: 50, takeReference: 70, minScale: 0.85f, maxScale: 1.18f);
                if (initial is null) continue;
                var transform = initial.Value;
                ok = true;
                foreach (float radius in new[] { 40f, 20f, 10f, 5f, 3f })
                {
                    pairs = StarMatcher.PairStars(reference, imageStars, transform, radius);
                    if (pairs.Count < 8) { ok = false; break; }
                    transform = StarMatcher.Fit(pairs);
                }
                if (ok) break;
            }
            if (!ok) continue;
            var matched = new List<(CatalogStar star, float x, float y)>();
            foreach (var (r, f) in pairs)
            {
                int idx = reference.IndexOf(r);
                if (idx >= 0) matched.Add((catalog[refIndex[idx]], f.X, f.Y));
            }
            var fitted = FitWcs(matched, raHint, decHint, cx, cy);
            if (fitted is null) continue;

            // Second pass with the fitted WCS: pair every catalogue star with an image star within 2 px.
            var refined = RefineWithWcs(fitted.Wcs, catalog, imageStars, cx, cy) ?? fitted;
            if (best is null || refined.MatchedStars > best.MatchedStars) best = refined;
        }
        progress?.Invoke(1.0);
        return best;
    }

    /// <summary>Window positions as fractions of the image size: centre first, then the eight neighbours.</summary>
    private static readonly (float fx, float fy)[] WindowOffsets =
        [(0, 0), (0.35f, 0), (-0.35f, 0), (0, 0.35f), (0, -0.35f), (0.35f, 0.35f), (-0.35f, 0.35f), (0.35f, -0.35f), (-0.35f, -0.35f)];

    private static PlateSolveResult? RefineWithWcs(Wcs wcs, IReadOnlyList<CatalogStar> catalog, List<Star> imageStars, double cx, double cy)
    {
        var projected = new List<Star>(catalog.Count);
        var index = new List<int>(catalog.Count);
        for (int i = 0; i < catalog.Count; i++)
        {
            var p = wcs.SkyToPixel(catalog[i].Ra, catalog[i].Dec);
            if (p is null) continue;
            projected.Add(new Star((float)p.Value.x, (float)p.Value.y, 1f, 3f));
            index.Add(i);
        }
        var pairs = StarMatcher.PairStars(projected, imageStars, SimilarityTransform.Identity, 2f);
        if (pairs.Count < 8) return null;
        var matched = new List<(CatalogStar star, float x, float y)>();
        foreach (var (r, f) in pairs)
        {
            int idx = projected.IndexOf(r);
            if (idx >= 0) matched.Add((catalog[index[idx]], f.X, f.Y));
        }
        return FitWcs(matched, wcs.Ra, wcs.Dec, cx, cy);
    }

    /// <summary>
    /// Least-squares TAN fit: xi/eta of the matched stars (projected around ra0/dec0) as a linear
    /// function of the pixel offsets from the image centre; the tangent point is then moved to the
    /// image centre and the fit repeated so the constant terms vanish.
    /// </summary>
    public static PlateSolveResult? FitWcs(IReadOnlyList<(CatalogStar star, float x, float y)> matched, double ra0, double dec0, double cx, double cy)
    {
        if (matched.Count < 6) return null;
        double ra = ra0, dec = dec0;
        double a = 0, b = 0, c = 0, d = 0, e = 0, f = 0;
        for (int iter = 0; iter < 3; iter++)
        {
            // Normal equations for xi = a·dx + b·dy + c and eta = d·dx + e·dy + f.
            double sxx = 0, sxy = 0, syy = 0, sx = 0, sy = 0, n = 0;
            double sxXi = 0, syXi = 0, sXi = 0, sxEta = 0, syEta = 0, sEta = 0;
            foreach (var (star, px, py) in matched)
            {
                var p = Wcs.Project(star.Ra, star.Dec, ra, dec);
                if (p is null) continue;
                double dx = px - cx, dy = py - cy;
                sxx += dx * dx; sxy += dx * dy; syy += dy * dy; sx += dx; sy += dy; n++;
                sxXi += dx * p.Value.xi; syXi += dy * p.Value.xi; sXi += p.Value.xi;
                sxEta += dx * p.Value.eta; syEta += dy * p.Value.eta; sEta += p.Value.eta;
            }
            if (n < 6) return null;
            if (!Solve3(sxx, sxy, sx, sxy, syy, sy, sx, sy, n, sxXi, syXi, sXi, out a, out b, out c)) return null;
            if (!Solve3(sxx, sxy, sx, sxy, syy, sy, sx, sy, n, sxEta, syEta, sEta, out d, out e, out f)) return null;
            // Move the tangent point to where the image centre actually points.
            (ra, dec) = Wcs.Deproject(c, f, ra, dec);
        }
        var wcs = new Wcs(ra, dec, cx, cy, a, b, d, e);
        double se = 0; int m = 0;
        foreach (var (star, px, py) in matched)
        {
            var p = wcs.SkyToPixel(star.Ra, star.Dec);
            if (p is null) continue;
            se += (p.Value.x - px) * (p.Value.x - px) + (p.Value.y - py) * (p.Value.y - py); m++;
        }
        double rmsPx = Math.Sqrt(se / Math.Max(m, 1));
        return new PlateSolveResult(wcs, m, rmsPx * wcs.ScaleArcsec, matched);
    }

    /// <summary>Solves the 3×3 symmetric system [[m11 m12 m13],[m21 m22 m23],[m31 m32 m33]]·[x y z] = [r1 r2 r3].</summary>
    private static bool Solve3(double m11, double m12, double m13, double m21, double m22, double m23, double m31, double m32, double m33,
        double r1, double r2, double r3, out double x, out double y, out double z)
    {
        double det = m11 * (m22 * m33 - m23 * m32) - m12 * (m21 * m33 - m23 * m31) + m13 * (m21 * m32 - m22 * m31);
        x = y = z = 0;
        if (Math.Abs(det) < 1e-18) return false;
        x = (r1 * (m22 * m33 - m23 * m32) - m12 * (r2 * m33 - m23 * r3) + m13 * (r2 * m32 - m22 * r3)) / det;
        y = (m11 * (r2 * m33 - m23 * r3) - r1 * (m21 * m33 - m23 * m31) + m13 * (m21 * r3 - r2 * m31)) / det;
        z = (m11 * (m22 * r3 - r2 * m32) - m12 * (m21 * r3 - r2 * m31) + r1 * (m21 * m32 - m22 * m31)) / det;
        return true;
    }
}
