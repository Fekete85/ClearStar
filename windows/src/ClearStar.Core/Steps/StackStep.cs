using ClearStar.Core.Imaging;
using ClearStar.Core.IO;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;
using ClearStar.Core.Registration;

namespace ClearStar.Core.Steps;

/// <summary>
/// 2. lépés: a fényképek összeillesztése – a Siril OSC-előfeldolgozó scriptjének logikáját követve:
/// kalibrálás → képenkénti sík háttér-gradiens kivonás (seqsubsky 1) → csillagok szerinti igazítás
/// (eltolás + forgatás + skála) → háttérszint normálása (norm=add) → teljes látómezőre
/// (framing=max) mintavételezés → szigma-vágott átlag. A képeket egyesével töltjük be, így a
/// memóriaigény nem függ a képek számától (ezért három menet: igazítás, összegzés, szűrés).
/// </summary>
public sealed class StackStep : StepBase
{
    public const string CalibrateKey = "calibrate";
    public const string AlignKey = "align";
    public const string RejectKey = "reject";
    public const string ClipKey = "clip";
    public const string GradientKey = "gradient";
    public const string FramingKey = "framing";

    private const int MinMatches = 8;

    private const string S = "stack";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Stack, StepGroup.Preparation, S,
        [
            Toggle(S, AlignKey, true),
            Toggle(S, RejectKey, true),
            Toggle(S, CalibrateKey, true),
            Toggle(S, GradientKey, true, advanced: true),
            Toggle(S, FramingKey, true, advanced: true),
            Toggle(S, ClipKey, true, advanced: true),
        ]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() => Run(context), context.CancellationToken);

    private sealed record FramePlan(FrameInfo Frame, SimilarityTransform ToReference, int Matches, float Rms);
    private sealed record FrameQuality(int Stars, float StarSize, float Background);

    private static StepResult Run(WorkflowContext context)
    {
        var frames = context.Frames ?? throw new InvalidOperationException(L.T("msg.stack.loadFirst"));
        var lights = frames.Lights.ToList();
        if (lights.Count == 0) throw new InvalidOperationException(L.T("msg.stack.noLights"));
        var p = context.Parameters;
        bool calibrate = p.GetBool(CalibrateKey, true), align = p.GetBool(AlignKey, true);
        bool reject = p.GetBool(RejectKey, true), clip = p.GetBool(ClipKey, true);
        bool gradient = p.GetBool(GradientKey, true), framingMax = p.GetBool(FramingKey, true);
        var ct = context.CancellationToken;

        var (masterDark, masterFlat) = calibrate ? BuildMasters(frames, context) : (null, null);

        if (lights.Count == 1)
        {
            context.Report(0.3, L.T("msg.stack.loading"));
            var single = LoadCalibrated(lights[0].Path, masterDark, masterFlat);
            single.Clamp01();
            return new StepResult(single, L.T("msg.stack.single"));
        }

        // Referencia: az időben középső kép – ehhez képest a legkisebb a maximális elfordulás.
        int refIndex = lights.Count / 2;
        context.Report(0.05, L.T("msg.stack.prepRef"));
        var reference = Prepare(lights[refIndex].Path, masterDark, masterFlat, gradient, null, ct);
        int fw = reference.Width, fh = reference.Height, ch = reference.Channels;
        var refMedians = ImageStats.ComputeAll(reference).Select(s => s.Median).ToArray();
        int refTotal = 0;
        List<Star> refStars = align ? StarDetector.Detect(reference, out refTotal, ct: ct) : [];
        if (align && refStars.Count < MinMatches)
            throw new InvalidOperationException(L.F("msg.stack.fewStars", refStars.Count, MinMatches));

        // 1. menet: igazítás (kép → referencia transzformációk) – a képek egymástól függetlenek,
        // ezért több képet dolgozunk fel egyszerre (a betöltés és a csillagkeresés egyszálú lenne).
        var planSlots = new FramePlan?[lights.Count];
        var skipSlots = new string?[lights.Count];
        var qualitySlots = new FrameQuality?[lights.Count];
        int done = 0;
        var parallel = new ParallelOptions { CancellationToken = ct, MaxDegreeOfParallelism = Concurrency };
        Parallel.For(0, lights.Count, parallel, i =>
        {
            try
            {
                if (i == refIndex) { planSlots[i] = new FramePlan(lights[i], SimilarityTransform.Identity, refStars.Count, 0); qualitySlots[i] = Quality(reference, refStars, refTotal); return; }
                if (!align)
                {
                    var info = FrameSet.Inspect(lights[i].Path);
                    if (info.Width != 0 && (info.Width != fw || info.Height != fh)) { skipSlots[i] = lights[i].FileName + ": " + L.T("msg.stack.sizeMismatch"); return; }
                    planSlots[i] = new FramePlan(lights[i], SimilarityTransform.Identity, 0, 0);
                    return;
                }
                var frame = LoadCalibrated(lights[i].Path, masterDark, masterFlat);
                if (frame.Width != fw || frame.Height != fh || frame.Channels != ch) { skipSlots[i] = lights[i].FileName + ": " + L.T("msg.stack.sizeMismatch"); return; }
                var stars = StarDetector.Detect(frame, out int total, ct: ct);
                qualitySlots[i] = Quality(frame, stars, total);
                var match = StarMatcher.Match(refStars, stars, MinMatches);
                if (match is null)
                {
                    if (reject) { skipSlots[i] = lights[i].FileName + ": " + L.F("msg.stack.alignFailed", stars.Count); return; }
                    planSlots[i] = new FramePlan(lights[i], SimilarityTransform.Identity, 0, 0);
                    return;
                }
                planSlots[i] = new FramePlan(lights[i], match.Transform, match.MatchedStars, match.Rms);
            }
            finally
            {
                int d = Interlocked.Increment(ref done);
                context.Report(0.05 + 0.35 * d / lights.Count, L.F("msg.stack.aligning", d, lights.Count));
            }
        });
        var plans = planSlots.Where(p => p is not null).Select(p => p!).ToList();
        var skipped = skipSlots.Where(s => s is not null).Select(s => s!).ToList();
        float maxAngle = plans.Count == 0 ? 0 : plans.Max(p => Math.Abs(p.ToReference.AngleDegrees));
        if (plans.Count == 0) throw new InvalidOperationException(L.F("msg.stack.noneUsable", string.Join("; ", skipped.Take(3))));

        // Vászon: a referencia kerete, vagy (teljes látómező) az összes elforgatott kép befoglaló téglalapja.
        int ox = 0, oy = 0, w = fw, h = fh;
        if (framingMax && align)
        {
            float minX = 0, minY = 0, maxX = fw - 1, maxY = fh - 1;
            foreach (var plan in plans)
                foreach (var (cx, cy) in new[] { (0f, 0f), (fw - 1f, 0f), (0f, fh - 1f), (fw - 1f, fh - 1f) })
                {
                    var (x, y) = plan.ToReference.Apply(cx, cy);
                    minX = Math.Min(minX, x); minY = Math.Min(minY, y); maxX = Math.Max(maxX, x); maxY = Math.Max(maxY, y);
                }
            ox = (int)Math.Floor(minX); oy = (int)Math.Floor(minY);
            w = (int)Math.Ceiling(maxX) - ox + 1; h = (int)Math.Ceiling(maxY) - oy + 1;
        }
        int n = w * h;

        // 2. menet: kép → vászon mintavételezés, összeg + négyzetösszeg + darabszám.
        var sum = new float[ch * n];
        var sumSq = clip ? new float[ch * n] : null;
        var count = new float[n];
        AstroImage PrepareFrame(FramePlan plan) =>
            plan.Frame == lights[refIndex] ? reference : Prepare(plan.Frame.Path, masterDark, masterFlat, gradient, refMedians, ct);

        ForEachPrefetched(plans, PrepareFrame, (i, frame) =>
        {
            context.Report(0.4 + 0.3 * i / plans.Count, L.F("msg.stack.stacking", i + 1, plans.Count));
            Accumulate(frame, CanvasToFrame(plans[i].ToReference, ox, oy), w, h, ch, sum, sumSq, count, null, null, ct);
        }, ct);

        var result = new AstroImage(w, h, ch, null, new Dictionary<string, string>(reference.Header, StringComparer.OrdinalIgnoreCase));
        var mean = result.Data;
        for (int c = 0; c < ch; c++)
            for (int i = 0; i < n; i++)
                mean[c * n + i] = count[i] > 0 ? sum[c * n + i] / count[i] : 0f;

        // 3. menet: szigma-vágott átlag (csak ha van elég kép, hogy a szórásnak értelme legyen).
        bool clipped = clip && plans.Count >= 5 && sumSq is not null;
        if (clipped)
        {
            var sigma = new float[ch * n];
            for (int c = 0; c < ch; c++)
                for (int i = 0; i < n; i++)
                {
                    float m = mean[c * n + i];
                    float var = count[i] > 1 ? sumSq![c * n + i] / count[i] - m * m : 0f;
                    sigma[c * n + i] = MathF.Sqrt(Math.Max(var, 0f)) * 2.5f + 1e-4f;
                }
            var clipSum = new float[ch * n];
            var clipCount = new float[ch * n];
            ForEachPrefetched(plans, PrepareFrame, (i, frame) =>
            {
                context.Report(0.7 + 0.28 * i / plans.Count, L.F("msg.stack.clipping", i + 1, plans.Count));
                Accumulate(frame, CanvasToFrame(plans[i].ToReference, ox, oy), w, h, ch, clipSum, null, clipCount, mean, sigma, ct);
            }, ct);
            for (int k = 0; k < ch * n; k++)
                if (clipCount[k] > 0) mean[k] = clipSum[k] / clipCount[k];
        }

        result.Clamp01();
        result.Header["STACKCNT"] = plans.Count.ToString();
        result.Header.Remove("BAYERPAT");

        string summary = L.F(align ? "msg.stack.summaryAligned" : "msg.stack.summaryAveraged", plans.Count);
        if (clipped) summary += L.T("msg.stack.clipped");
        if (gradient) summary += L.T("msg.stack.gradient");
        if (masterDark is not null || masterFlat is not null) summary += L.T("msg.stack.calibrated");
        if (align && maxAngle > 0.05f) summary += L.F("msg.stack.rotation", maxAngle);
        if (skipped.Count > 0) summary += L.F("msg.stack.skipped", skipped.Count);
        var notes = new Dictionary<string, FrameNote>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < lights.Count; i++)
        {
            if (planSlots[i] is { } plan)
            {
                string text = i == refIndex ? L.T("msg.stack.reference")
                    : plan.Matches == 0 ? L.T("msg.stack.noAlign")
                    : L.F("msg.stack.aligned", plan.Matches, plan.ToReference.AngleDegrees);
                var q = qualitySlots[i];
                notes[lights[i].Path] = new FrameNote(true, text, q?.Stars, q?.StarSize, q?.Background, plan.ToReference.AngleDegrees);
            }
            else if (skipSlots[i] is { } why)
            {
                int colon = why.IndexOf(':');
                var q = qualitySlots[i];
                notes[lights[i].Path] = new FrameNote(false, L.F("msg.stack.skippedNote", colon >= 0 ? why[(colon + 2)..] : why), q?.Stars, q?.StarSize, q?.Background);
            }
        }
        return new StepResult(result, summary, FrameNotes: notes);
    }

    /// <summary>Egyszerre feldolgozott képek száma (a memóriát is ez határozza meg: ~100 MB képenként).</summary>
    private static int Concurrency => Math.Clamp(Environment.ProcessorCount / 2, 2, 8);

    /// <summary>
    /// Sorban dolgozza fel az elemeket, de a következőket már előre, párhuzamosan készíti elő,
    /// így a betöltés/gradiens (több szálon) és az összegzés (fő szál) átfedésben fut.
    /// </summary>
    private static void ForEachPrefetched<T>(IReadOnlyList<T> items, Func<T, AstroImage> prepare, Action<int, AstroImage> consume, CancellationToken ct)
    {
        int ahead = Math.Min(Concurrency, items.Count);
        var pending = new Task<AstroImage>?[items.Count];
        for (int i = 0; i < ahead; i++) { int idx = i; pending[i] = Task.Run(() => prepare(items[idx]), ct); }
        for (int i = 0; i < items.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var frame = pending[i]!.GetAwaiter().GetResult();
            pending[i] = null;
            int next = i + ahead;
            if (next < items.Count) { int idx = next; pending[next] = Task.Run(() => prepare(items[idx]), ct); }
            consume(i, frame);
        }
    }

    /// <summary>Képminőség-mérőszámok: csillagszám, tipikus csillagméret (élesség), háttérszint (zöld csatorna).</summary>
    private static FrameQuality Quality(AstroImage frame, List<Star> stars, int totalFound)
    {
        float size = stars.Count > 0 ? ImageStats.Median(stars.Take(200).Select(s => s.Size).ToArray()) : 0f;
        float bg = ImageStats.Compute(frame.Channels == 3 ? frame.Channel(1) : frame.Channel(0), 100_000).Median;
        return new FrameQuality(totalFound, size, bg);
    }

    /// <summary>Vászon (x,y) → kép koordináta: a vászon a referenciához képest (ox,oy)-nal eltolt.</summary>
    private static SimilarityTransform CanvasToFrame(SimilarityTransform toReference, int ox, int oy)
    {
        var inv = toReference.Inverse();
        return inv with { Tx = inv.A * ox - inv.B * oy + inv.Tx, Ty = inv.B * ox + inv.A * oy + inv.Ty };
    }

    /// <summary>
    /// Kép betöltése + kalibrálás + (opcionálisan) sík háttér-gradiens kivonása + a háttér szintjének
    /// a referenciához igazítása (additív normálás, mint a Siril -norm=add).
    /// </summary>
    private static AstroImage Prepare(string path, AstroImage? dark, AstroImage? flat, bool gradient, float[]? refMedians, CancellationToken ct)
    {
        var img = LoadCalibrated(path, dark, flat);
        if (gradient) BackgroundExtractionStep.Flatten(img, img, degree: 1, tolerance: 1f, columns: 24, ct);
        if (refMedians is not null && refMedians.Length == img.Channels)
        {
            var stats = ImageStats.ComputeAll(img);
            for (int c = 0; c < img.Channels; c++)
            {
                float shift = refMedians[c] - stats[c].Median;
                if (Math.Abs(shift) < 1e-6f) continue;
                var chn = img.Channel(c);
                for (int i = 0; i < chn.Length; i++) chn[i] += shift;
            }
        }
        return img;
    }

    /// <summary>A képet a referencia rácsára mintavételezi és hozzáadja az összegekhez.</summary>
    private static void Accumulate(AstroImage frame, SimilarityTransform toFrame, int w, int h, int ch,
        float[] sum, float[]? sumSq, float[] count, float[]? mean, float[]? sigma, CancellationToken ct)
    {
        int n = w * h;
        ImageWarp.Resample(frame, toFrame, w, h, (y, width, row) =>
        {
            int wOff = width * ch;
            for (int x = 0; x < width; x++)
            {
                if (row[wOff + x] <= 0f) continue;
                int i = y * width + x;
                if (mean is null)
                {
                    count[i] += 1f;
                    for (int c = 0; c < ch; c++)
                    {
                        float v = row[c * width + x];
                        sum[c * n + i] += v;
                        if (sumSq is not null) sumSq[c * n + i] += v * v;
                    }
                }
                else
                {
                    // Szigma-vágás: csatornánként külön számlálóval (count itt ch*n méretű).
                    for (int c = 0; c < ch; c++)
                    {
                        float v = row[c * width + x];
                        int k = c * n + i;
                        if (Math.Abs(v - mean[k]) <= sigma![k]) { sum[k] += v; count[k] += 1f; }
                    }
                }
            }
        }, ct);
    }

    private static (AstroImage? dark, AstroImage? flat) BuildMasters(FrameSet frames, WorkflowContext context)
    {
        AstroImage? dark = null, flat = null;
        var darks = frames.Darks.Select(f => f.Path).ToList();
        var flats = frames.Flats.Select(f => f.Path).ToList();
        if (darks.Count > 0)
        {
            context.Report(0.02, L.T("msg.stack.masterDark"));
            dark = PlainAverage(darks, context.CancellationToken);
        }
        if (flats.Count > 0)
        {
            context.Report(0.06, L.T("msg.stack.masterFlat"));
            flat = PlainAverage(flats, context.CancellationToken);
            for (int c = 0; c < flat.Channels; c++)
            {
                var chn = flat.Channel(c);
                double m = 0; foreach (var v in chn) m += v;
                float mean = (float)Math.Max(m / chn.Length, 1e-6);
                for (int i = 0; i < chn.Length; i++) chn[i] = Math.Max(chn[i] / mean, 0.05f);
            }
        }
        return (dark, flat);
    }

    private static AstroImage PlainAverage(List<string> paths, CancellationToken ct)
    {
        AstroImage? sum = null; int used = 0;
        foreach (var path in paths)
        {
            ct.ThrowIfCancellationRequested();
            var img = ImageFiles.Load(path);
            sum ??= img.CreateEmptyLike();
            if (img.Width != sum.Width || img.Height != sum.Height || img.Channels != sum.Channels) continue;
            var s = sum.Data; var d = img.Data;
            for (int i = 0; i < s.Length; i++) s[i] += d[i];
            used++;
        }
        if (sum is null || used == 0) throw new InvalidOperationException(L.T("msg.stack.calibLoadFailed"));
        float inv = 1f / used;
        for (int i = 0; i < sum.Data.Length; i++) sum.Data[i] *= inv;
        return sum;
    }

    private static AstroImage LoadCalibrated(string path, AstroImage? dark, AstroImage? flat)
    {
        var img = ImageFiles.Load(path);
        var d = img.Data;
        bool useDark = dark is not null && SameShape(dark, img);
        bool useFlat = flat is not null && SameShape(flat, img);
        if (!useDark && !useFlat) return img;
        var dk = dark?.Data; var fl = flat?.Data;
        Parallel.For(0, img.Height, y =>
        {
            for (int c = 0; c < img.Channels; c++)
            {
                int start = c * img.PixelsPerChannel + y * img.Width;
                for (int k = start; k < start + img.Width; k++)
                {
                    float v = d[k];
                    if (useDark) v -= dk![k];
                    if (useFlat) v /= fl![k];
                    d[k] = v;
                }
            }
        });
        return img;
    }

    private static bool SameShape(AstroImage a, AstroImage b) => a.Width == b.Width && a.Height == b.Height && a.Channels == b.Channels;
}
