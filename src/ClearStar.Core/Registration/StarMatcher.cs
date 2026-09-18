namespace ClearStar.Core.Registration;

/// <summary>Hasonlósági transzformáció: q = s·R(θ)·p + t (kép → referencia).</summary>
public readonly record struct SimilarityTransform(float Scale, float Angle, float Tx, float Ty)
{
    public static readonly SimilarityTransform Identity = new(1f, 0f, 0f, 0f);

    public float A => Scale * MathF.Cos(Angle);
    public float B => Scale * MathF.Sin(Angle);

    public (float x, float y) Apply(float x, float y) => (A * x - B * y + Tx, B * x + A * y + Ty);

    /// <summary>Referencia → kép (a képmintavételezéshez).</summary>
    public SimilarityTransform Inverse()
    {
        float s = 1f / Scale, ang = -Angle;
        float a = s * MathF.Cos(ang), b = s * MathF.Sin(ang);
        return new SimilarityTransform(s, ang, -(a * Tx - b * Ty), -(b * Tx + a * Ty));
    }

    public float AngleDegrees => Angle * 180f / MathF.PI;
}

public sealed record MatchResult(SimilarityTransform Transform, int MatchedStars, float Rms);

/// <summary>
/// Csillaglisták egymáshoz illesztése: durva eltolás szavazással, majd iteratív legközelebbi-szomszéd
/// párosítás és zárt alakú hasonlósági illesztés (eltolás + forgatás + skála), csökkenő sugárral.
/// </summary>
public static class StarMatcher
{
    public static MatchResult? Match(IReadOnlyList<Star> reference, IReadOnlyList<Star> frame, int minMatches = 8, float maxRms = 1.5f)
    {
        if (reference.Count < minMatches || frame.Count < minMatches) return null;

        // 1. próba: tiszta eltolás (gyors, a képek többségénél elég). 2. próba: háromszög-illesztés,
        // ami forgatástól és skálától független – alt-az mechanikánál a képek 90°-kal is elfordulhatnak.
        var (tx, ty) = VoteTranslation(reference, frame);
        var transform = new SimilarityTransform(1f, 0f, tx, ty);
        var result = Refine(reference, frame, transform, minMatches, maxRms);
        if (result is not null) return result;

        var triangle = TriangleMatch(reference, frame);
        if (triangle is null) return null;
        return Refine(reference, frame, triangle.Value, minMatches, maxRms);
    }

    /// <summary>Csökkenő sugarú legközelebbi-szomszéd párosítás és újraillesztés egy kezdeti transzformációból.</summary>
    private static MatchResult? Refine(IReadOnlyList<Star> reference, IReadOnlyList<Star> frame, SimilarityTransform transform, int minMatches, float maxRms)
    {
        float[] radii = [40f, 20f, 8f, 4f, 2.5f];
        List<(Star r, Star f)> pairs = [];
        foreach (var radius in radii)
        {
            pairs = Pair(reference, frame, transform, radius);
            if (pairs.Count < Math.Max(3, minMatches / 2)) return null;
            transform = Fit(pairs);
        }
        pairs = Pair(reference, frame, transform, 2f);
        if (pairs.Count < minMatches) return null;
        transform = Fit(pairs);

        double se = 0;
        foreach (var (r, f) in pairs)
        {
            var (x, y) = transform.Apply(f.X, f.Y);
            se += (x - r.X) * (x - r.X) + (y - r.Y) * (y - r.Y);
        }
        float rms = MathF.Sqrt((float)(se / pairs.Count));
        if (rms > maxRms) return null;
        return new MatchResult(transform, pairs.Count, rms);
    }

    /// <summary>
    /// Forgatás- és skálafüggetlen kezdeti illesztés: a legfényesebb csillagokból képzett háromszögek
    /// oldalarányai (b/a, c/a) nem függnek a forgatástól; az egyező arányú háromszögek a csúcsaikra
    /// mint csillagpárokra szavaznak, a legtöbb szavazatot kapó, kölcsönösen legjobb párokból
    /// hasonlósági transzformációt illesztünk.
    /// </summary>
    public static SimilarityTransform? TriangleMatch(IReadOnlyList<Star> reference, IReadOnlyList<Star> frame, int take = 45, float tolerance = 0.006f)
    {
        var r = reference.OrderByDescending(s => s.Flux).Take(take).ToList();
        var f = frame.OrderByDescending(s => s.Flux).Take(take).ToList();
        if (r.Count < 6 || f.Count < 6) return null;

        // Referencia-háromszögek rácsba rendezve az invariánsok szerint.
        var grid = new Dictionary<(int, int), List<Tri>>();
        int cellDiv = (int)MathF.Ceiling(1f / tolerance);
        foreach (var t in Triangles(r))
        {
            var key = ((int)(t.Rb * cellDiv), (int)(t.Rc * cellDiv));
            if (!grid.TryGetValue(key, out var list)) grid[key] = list = [];
            list.Add(t);
        }

        var votes = new int[r.Count, f.Count];
        foreach (var t in Triangles(f))
        {
            int gx = (int)(t.Rb * cellDiv), gy = (int)(t.Rc * cellDiv);
            for (int i = -1; i <= 1; i++)
            for (int j = -1; j <= 1; j++)
            {
                if (!grid.TryGetValue((gx + i, gy + j), out var list)) continue;
                foreach (var rt in list)
                {
                    if (MathF.Abs(rt.Rb - t.Rb) > tolerance || MathF.Abs(rt.Rc - t.Rc) > tolerance) continue;
                    // Azonos műszer: a méretarány 1 körül van, ezzel a hamis egyezések nagy része kiesik.
                    float scale = t.A / rt.A;
                    if (scale < 0.8f || scale > 1.25f) continue;
                    votes[rt.I0, t.I0]++; votes[rt.I1, t.I1]++; votes[rt.I2, t.I2]++;
                }
            }
        }

        // Kölcsönösen legjobb párok, legalább néhány szavazattal.
        var pairs = new List<(Star r, Star f, int v)>();
        for (int i = 0; i < r.Count; i++)
        {
            int bestJ = -1, best = 0, second = 0;
            for (int j = 0; j < f.Count; j++)
            {
                int v = votes[i, j];
                if (v > best) { second = best; best = v; bestJ = j; }
                else if (v > second) second = v;
            }
            if (bestJ < 0 || best < 4 || best < 2 * second) continue;
            bool mutual = true;
            for (int k = 0; k < r.Count; k++) if (k != i && votes[k, bestJ] >= best) { mutual = false; break; }
            if (mutual) pairs.Add((r[i], f[bestJ], best));
        }
        if (pairs.Count < 5) return null;

        var top = pairs.OrderByDescending(p => p.v).Take(30).Select(p => (p.r, p.f)).ToList();
        var transform = Fit(top);
        // Egy durva ellenőrzés: a felhasznált párok tényleg egymásra esnek-e.
        int good = 0;
        foreach (var (rs, fs) in top)
        {
            var (x, y) = transform.Apply(fs.X, fs.Y);
            if ((x - rs.X) * (x - rs.X) + (y - rs.Y) * (y - rs.Y) < 30f * 30f) good++;
        }
        return good >= 5 ? transform : null;
    }

    /// <summary>Háromszög a csúcsok indexeivel a leghosszabb oldallal szemközti csúcstól sorolva, és az oldalarányokkal.</summary>
    private readonly record struct Tri(int I0, int I1, int I2, float A, float Rb, float Rc);

    private static IEnumerable<Tri> Triangles(List<Star> stars)
    {
        int n = stars.Count;
        for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
        for (int k = j + 1; k < n; k++)
        {
            float dij = Dist(stars[i], stars[j]), djk = Dist(stars[j], stars[k]), dik = Dist(stars[i], stars[k]);
            // Csúcsok sorrendje: a leghosszabb oldallal szemközti először, aztán a középsővel, végül a legrövidebbel.
            int v0, v1, v2; float a, b, c;
            if (djk >= dik && djk >= dij) { v0 = i; if (dik >= dij) { v1 = j; v2 = k; a = djk; b = dik; c = dij; } else { v1 = k; v2 = j; a = djk; b = dij; c = dik; } }
            else if (dik >= dij) { v0 = j; if (djk >= dij) { v1 = i; v2 = k; a = dik; b = djk; c = dij; } else { v1 = k; v2 = i; a = dik; b = dij; c = djk; } }
            else { v0 = k; if (djk >= dik) { v1 = i; v2 = j; a = dij; b = djk; c = dik; } else { v1 = j; v2 = i; a = dij; b = dik; c = djk; } }
            if (a < 30f || c / a < 0.15f) continue;           // túl kicsi vagy elfajult háromszög
            if (b / a > 0.995f || c / b > 0.995f) continue;    // egyenlő szárú: a csúcsok sorrendje bizonytalan
            yield return new Tri(v0, v1, v2, a, b / a, c / a);
        }
    }

    private static float Dist(Star p, Star q) => MathF.Sqrt((p.X - q.X) * (p.X - q.X) + (p.Y - q.Y) * (p.Y - q.Y));

    /// <summary>A leggyakoribb (ref − kép) eltolás a legfényesebb csillagok között, durva rácson.</summary>
    private static (float tx, float ty) VoteTranslation(IReadOnlyList<Star> reference, IReadOnlyList<Star> frame, int take = 60, float bin = 24f)
    {
        var refTop = reference.OrderByDescending(s => s.Flux).Take(take).ToList();
        var frameTop = frame.OrderByDescending(s => s.Flux).Take(take).ToList();
        var votes = new Dictionary<(int, int), (int count, double sx, double sy)>();
        foreach (var r in refTop)
        foreach (var f in frameTop)
        {
            float dx = r.X - f.X, dy = r.Y - f.Y;
            var key = ((int)MathF.Floor(dx / bin), (int)MathF.Floor(dy / bin));
            votes.TryGetValue(key, out var v);
            votes[key] = (v.count + 1, v.sx + dx, v.sy + dy);
        }
        // A szomszédos cellákat is összeszámoljuk, hogy a rácshatárra eső eltolás ne essen szét.
        (int, int) best = default; int bestCount = -1;
        foreach (var key in votes.Keys)
        {
            int c = 0;
            for (int i = -1; i <= 1; i++) for (int j = -1; j <= 1; j++)
                if (votes.TryGetValue((key.Item1 + i, key.Item2 + j), out var v)) c += v.count;
            if (c > bestCount) { bestCount = c; best = key; }
        }
        double sx = 0, sy = 0; int n = 0;
        for (int i = -1; i <= 1; i++) for (int j = -1; j <= 1; j++)
            if (votes.TryGetValue((best.Item1 + i, best.Item2 + j), out var v)) { sx += v.sx; sy += v.sy; n += v.count; }
        return n == 0 ? (0f, 0f) : ((float)(sx / n), (float)(sy / n));
    }

    private static List<(Star r, Star f)> Pair(IReadOnlyList<Star> reference, IReadOnlyList<Star> frame, SimilarityTransform t, float radius)
    {
        // Rácsos gyorsítás a referencia csillagokra.
        float cell = Math.Max(radius, 1f) * 2f;
        var grid = new Dictionary<(int, int), List<int>>();
        for (int i = 0; i < reference.Count; i++)
        {
            var key = ((int)MathF.Floor(reference[i].X / cell), (int)MathF.Floor(reference[i].Y / cell));
            if (!grid.TryGetValue(key, out var list)) grid[key] = list = [];
            list.Add(i);
        }
        var used = new HashSet<int>();
        var pairs = new List<(Star, Star)>();
        float r2 = radius * radius;
        foreach (var f in frame)
        {
            var (x, y) = t.Apply(f.X, f.Y);
            int gx = (int)MathF.Floor(x / cell), gy = (int)MathF.Floor(y / cell);
            int best = -1; float bestD = r2;
            for (int i = -1; i <= 1; i++) for (int j = -1; j <= 1; j++)
            {
                if (!grid.TryGetValue((gx + i, gy + j), out var list)) continue;
                foreach (var idx in list)
                {
                    if (used.Contains(idx)) continue;
                    float dx = reference[idx].X - x, dy = reference[idx].Y - y;
                    float d = dx * dx + dy * dy;
                    if (d < bestD) { bestD = d; best = idx; }
                }
            }
            if (best >= 0) { used.Add(best); pairs.Add((reference[best], f)); }
        }
        return pairs;
    }

    /// <summary>Zárt alakú legkisebb négyzetes hasonlósági illesztés (Umeyama 2D-ben).</summary>
    public static SimilarityTransform Fit(IReadOnlyList<(Star r, Star f)> pairs)
    {
        double mrx = 0, mry = 0, mfx = 0, mfy = 0;
        foreach (var (r, f) in pairs) { mrx += r.X; mry += r.Y; mfx += f.X; mfy += f.Y; }
        int n = pairs.Count;
        mrx /= n; mry /= n; mfx /= n; mfy /= n;
        double dot = 0, cross = 0, norm = 0;
        foreach (var (r, f) in pairs)
        {
            double fx = f.X - mfx, fy = f.Y - mfy, rx = r.X - mrx, ry = r.Y - mry;
            dot += fx * rx + fy * ry;
            cross += fx * ry - fy * rx;
            norm += fx * fx + fy * fy;
        }
        double angle = Math.Atan2(cross, dot);
        double scale = norm > 0 ? (dot * Math.Cos(angle) + cross * Math.Sin(angle)) / norm : 1.0;
        double a = scale * Math.Cos(angle), b = scale * Math.Sin(angle);
        double tx = mrx - (a * mfx - b * mfy);
        double ty = mry - (b * mfx + a * mfy);
        return new SimilarityTransform((float)scale, (float)angle, (float)tx, (float)ty);
    }
}
