using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ClearStar.Core.AI;
using ClearStar.Core.Astrometry;
using ClearStar.Core.Imaging;
using ClearStar.Core.IO;
using ClearStar.Core.Pipeline;
using ClearStar.Core.Registration;
using ClearStar.Core.Steps;

namespace ClearStar.Cli;

/// <summary>
/// Reference outputs for the macOS port's parity tests: the Swift code gets the same inputs and must produce
/// the same results. <c>reference synthetic &lt;dir&gt;</c> writes small generated inputs and every unit-level
/// result (committed next to the Swift tests); <c>reference real &lt;dir&gt; --m31 &lt;folder&gt; --models &lt;dir&gt;
/// --catalog &lt;file&gt;</c> runs the steps on the real test data (kept out of the repository).
/// Images are 32-bit float FITS, everything else JSON.
/// </summary>
public static class Reference
{
    public static async Task RunAsync(string[] args)
    {
        ClearStar.Core.Localization.L.Load("en");
        string mode = args[1], outDir = args[2];
        Directory.CreateDirectory(outDir);
        if (mode == "synthetic") Synthetic(outDir);
        else await Real(outDir, Arg(args, "--frames"), Arg(args, "--models"), Arg(args, "--catalog"), args.Contains("--no-stack"), OptionalArg(args, "--object"));
    }

    private static string? OptionalArg(string[] args, string name)
    {
        int i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static string Arg(string[] args, string name)
    {
        int i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : throw new ArgumentException($"missing {name}");
    }

    // ------------------------------------------------------------------ helpers

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = false, NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals };

    private static void Save(string dir, string name, AstroImage img) => FitsWriter.Write(Path.Combine(dir, name + ".fits"), img);

    private static void SaveJson(string dir, string name, object value) =>
        File.WriteAllText(Path.Combine(dir, name + ".json"), JsonSerializer.Serialize(value, Json));

    private static object Stats(ChannelStats s) => new { s.Min, s.Max, s.Median, s.Mad, s.Mean };
    private static object Prm(DisplayStretch.Params p) => new { p.Shadows, p.Midtones };
    private static object StarJ(Star s) => new[] { s.X, s.Y, s.Flux, s.Size };
    private static object Tr(SimilarityTransform t) => new { t.Scale, t.Angle, t.Tx, t.Ty };

    /// <summary>Gaussian star field with a gradient and noise (deterministic).</summary>
    public static AstroImage StarField(int w, int h, int ch, int seed, int stars = 160, float fwhm = 3.2f)
    {
        var rnd = new Random(seed);
        var img = new AstroImage(w, h, ch);
        int n = w * h;
        float sigma = fwhm / 2.355f;
        var list = new List<(float x, float y, float amp, float[] col)>();
        for (int s = 0; s < stars; s++)
        {
            float amp = (float)Math.Pow(rnd.NextDouble(), 3) * 0.8f + 0.02f;
            float t = (float)rnd.NextDouble();
            list.Add(((float)rnd.NextDouble() * (w - 1), (float)rnd.NextDouble() * (h - 1), amp, [1.0f + 0.3f * t, 1f, 1.25f - 0.4f * t]));
        }
        for (int c = 0; c < ch; c++)
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    float bg = 0.08f + 0.03f * x / w + 0.02f * y / h + (c == 1 ? 0.01f : 0f);
                    float noise = (float)((rnd.NextDouble() + rnd.NextDouble() + rnd.NextDouble() - 1.5) * 0.006);
                    img.Data[c * n + y * w + x] = bg + noise;
                }
        foreach (var (sx, sy, amp, col) in list)
        {
            int r = (int)Math.Ceiling(sigma * 4);
            for (int y = Math.Max(0, (int)sy - r); y <= Math.Min(h - 1, (int)sy + r); y++)
                for (int x = Math.Max(0, (int)sx - r); x <= Math.Min(w - 1, (int)sx + r); x++)
                {
                    float d2 = (x - sx) * (x - sx) + (y - sy) * (y - sy);
                    float v = amp * MathF.Exp(-d2 / (2 * sigma * sigma));
                    for (int c = 0; c < ch; c++) img.Data[c * n + y * w + x] += v * (ch == 3 ? col[c] / 1.25f : 1f);
                }
        }
        // A faint "nebula" blob so that the background fit has something to reject.
        for (int c = 0; c < ch; c++)
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    float dx = (x - 0.3f * w) / (0.12f * w), dy = (y - 0.6f * h) / (0.1f * h);
                    img.Data[c * n + y * w + x] += 0.05f * MathF.Exp(-(dx * dx + dy * dy)) * (c == 0 ? 1.2f : c == 1 ? 0.7f : 1f);
                }
        img.Clamp01();
        return img;
    }

    // ------------------------------------------------------------------ synthetic

    private static void Synthetic(string root)
    {
        string d = root;
        var field = StarField(400, 300, 3, 11);
        var mono = StarField(400, 300, 1, 12);
        Save(d, "field", field);
        Save(d, "field_mono", mono);
        var scalars = new JsonObject();

        // Statistics, screen stretch, MTF.
        SaveJson(d, "stats", new
        {
            field = ImageStats.ComputeAll(field).Select(Stats),
            mono = ImageStats.ComputeAll(mono).Select(Stats),
            strided = Stats(ImageStats.Compute(field.Channel(1), 5000)),
            median = new[] { ImageStats.Median([3f, 1f, 2f]), ImageStats.Median([4f, 1f, 3f, 2f]), ImageStats.Median([]) },
        });
        var presets = DisplayStretch.Presets.ToDictionary(p => p.Key, p => new
        {
            unlinked = DisplayStretch.ComputeAll(field, p, false).Select(Prm),
            linked = DisplayStretch.ComputeAll(field, p, true).Select(Prm),
        });
        var mtf = new List<float[]>();
        foreach (float m in new[] { 0.05f, 0.25f, 0.5f, 0.8f })
            foreach (float x in new[] { -0.1f, 0f, 0.001f, 0.1f, 0.5f, 0.9f, 1f, 1.2f })
                mtf.Add([m, x, DisplayStretch.Mtf(x, m)]);
        var p0 = new DisplayStretch.Params(0.03f, 0.2f);
        SaveJson(d, "stretch", new
        {
            presets,
            auto = DisplayStretch.ComputeAll(field).Select(Prm),
            autoLinked = DisplayStretch.ComputeAll(field, linked: true, targetBackground: 0.15f).Select(Prm),
            mtf,
            apply = new[] { 0f, 0.03f, 0.1f, 0.5f, 1f }.Select(x => new[] { x, p0.Apply(x), p0.Invert(p0.Apply(x)) }),
            lut = DisplayStretch.BuildLut(p0, 64).Select(b => (int)b),
            factor = new[] { field.DownsampleFactor(100), field.DownsampleFactor(2400), field.DownsampleFactor(150) },
        });
        Save(d, "downsample3", field.Downsample(3));

        // Resampling.
        var ch0 = field.Channel(0).ToArray();
        Save(d, "resize_down", new AstroImage(123, 77, 1, Resample.Resize(ch0, 400, 300, 123, 77)));
        Save(d, "resize_up", new AstroImage(700, 520, 1, Resample.Resize(ch0, 400, 300, 700, 520)));
        Save(d, "blur", new AstroImage(400, 300, 1, Resample.GaussianBlur(ch0, 400, 300, 2.5f)));

        // Debayer.
        var cfa = new AstroImage(64, 48, 1);
        var rnd = new Random(5);
        for (int i = 0; i < cfa.Data.Length; i++) cfa.Data[i] = (float)rnd.NextDouble();
        Save(d, "cfa", cfa);
        foreach (var pat in Enum.GetValues<BayerPattern>()) Save(d, "debayer_" + pat, Debayer.Bilinear(cfa, pat));
        var bayerHeaders = new List<object>();
        foreach (var (row, yoff, hgt) in new[] { ("", "", 48), ("TOP-DOWN", "", 48), ("", "1", 48), ("", "", 47), ("TOP-DOWN", "1", 47) })
        {
            var img = new AstroImage(64, hgt, 1);
            if (row.Length > 0) img.Header["ROWORDER"] = row;
            if (yoff.Length > 0) img.Header["YBAYROFF"] = yoff;
            foreach (var pat in Enum.GetValues<BayerPattern>())
                bayerHeaders.Add(new { row, yoff, hgt, pat = pat.ToString(), eff = ImageFiles.EffectiveBayerPattern(img, pat).ToString() });
        }
        SaveJson(d, "bayer", bayerHeaders);

        // FITS variants written by hand (the writer only does -32); the C# reading of each is the reference.
        WriteFitsVariants(d);

        // Raster files written by ImageSharp: the Swift ImageIO reader must decode the same pixels.
        ImageFiles.Save(Path.Combine(d, "raster.tif"), field, ExportFormat.Tiff16);
        ImageFiles.Save(Path.Combine(d, "raster.png"), field, ExportFormat.Png16);
        ImageFiles.Save(Path.Combine(d, "raster.jpg"), field, ExportFormat.Jpeg);
        foreach (var ext in new[] { "tif", "png", "jpg" }) Save(d, "raster_" + ext + "_read", ImageFiles.Load(Path.Combine(d, "raster." + ext)));

        // GHS curves and images.
        var ghsCases = GhsCases();
        var curves = new List<object>();
        foreach (var (name, p) in ghsCases)
        {
            var t = new GhsTransform(p);
            var ys = new float[1001];
            for (int i = 0; i < ys.Length; i++) ys[i] = t.Apply(i / 1000f);
            curves.Add(new { name, json = p.ToJson(), identity = p.IsIdentity, curve = ys });
        }
        SaveJson(d, "ghs_curves", curves);
        var human = new GhsParams(GhsType.Ghs, GhsParams.DFromLog(2.0), 1.5f, 0f, 0.1f, 1f, 0f, GhsColourModel.HumanLuminance);
        Save(d, "ghs_human", GhsTransform.Apply(field, human));
        Save(d, "ghs_even", GhsTransform.Apply(field, human with { Colour = GhsColourModel.EvenLuminance }));
        Save(d, "ghs_indep", GhsTransform.Apply(field, human with { Colour = GhsColourModel.Independent }));
        var auto = new StepParameters();
        auto[StarlessStretchStep.HistoryKey] = "[]";
        StarlessStretchStep.CommitAuto(auto, field);
        var hist = StarlessStretchStep.History(auto);
        Save(d, "ghs_auto", GhsTransform.ApplyAll(field, hist));
        SaveJson(d, "ghs_misc", new
        {
            autoHistory = auto.GetString(StarlessStretchStep.HistoryKey),
            listJson = GhsParams.ListToJson(ghsCases.Take(3).Select(c => c.p)),
            regionMedian = StarlessStretchStep.RegionMedian(field, 0.1, 0.2, 0.3, 0.25),
            histogram = Histogram.Compute(field, 2),
            describe = ghsCases.Select(c => c.p.Describe()),
        });

        // Crop / orientation.
        var orient = new List<object>();
        foreach (var (angle, fh, fv) in new[] { (0.0, false, false), (90.0, false, false), (180.0, true, false), (270.0, false, true), (90.0, true, true), (12.5, false, false), (-30.0, true, false), (450.0, false, false) })
        {
            var o = CropStep.Orient(field, angle, fh, fv);
            string name = $"orient_{angle.ToString(CultureInfo.InvariantCulture)}_{(fh ? 1 : 0)}{(fv ? 1 : 0)}";
            Save(d, name, o);
            orient.Add(new { angle, fh, fv, name, size = CropStep.OrientedSize(400, 300, angle) is var (ow, oh) ? new[] { ow, oh } : null });
        }
        SaveJson(d, "orient", orient);
        Save(d, "crop", CropStep.Crop(field, 10, 20, 30, 40));
        var rotated = CropStep.Orient(field, 17, false, false);
        Save(d, "coverage_input", rotated);
        var cov = Coverage.LargestFilledRectangle(rotated);
        var cov1 = Coverage.LargestFilledRectangle(rotated, 1);
        SaveJson(d, "coverage", new { cov = cov is { } c1 ? new[] { c1.X, c1.Y, c1.W, c1.H } : null, cov1 = cov1 is { } c2 ? new[] { c2.X, c2.Y, c2.W, c2.H } : null, full = Coverage.LargestFilledRectangle(field) is null });

        // Crop step through its parameters (selection and margin).
        var cropStep = new CropStep();
        var cp = new StepParameters(cropStep.Definition.Parameters);
        cp[CropStep.RotateKey] = "90"; cp[CropStep.AngleKey] = 3.0; cp[CropStep.SelLeftKey] = 0.1; cp[CropStep.SelTopKey] = 0.15; cp[CropStep.SelWidthKey] = 0.6; cp[CropStep.SelHeightKey] = 0.5;
        Save(d, "cropstep_sel", RunStep(cropStep, field, cp));
        var cp2 = new StepParameters(cropStep.Definition.Parameters);
        cp2[CropStep.MarginKey] = 0.07;
        Save(d, "cropstep_margin", RunStep(cropStep, field, cp2));

        // Per-pixel colour steps.
        var stretched = GhsTransform.ApplyAll(field, hist);
        Save(d, "stretched", stretched);
        foreach (var (step, key, value, name) in new (StepBase, string, double, string)[]
                 {
                     (new GreenRemovalStep(), GreenRemovalStep.AmountKey, 0.8, "green"),
                     (new FringeStep(), FringeStep.AmountKey, 0.9, "fringe"),
                     (new ContrastStep(), ContrastStep.AmountKey, 0.6, "contrast"),
                     (new SaturationStep(), SaturationStep.AmountKey, 0.5, "saturation"),
                 })
        {
            var p = new StepParameters(step.Definition.Parameters);
            p[key] = value;
            if (step is ContrastStep) p[ContrastStep.BlackPointKey] = 0.03;
            if (step is FringeStep) { p[FringeStep.ThresholdKey] = 0.2; p[FringeStep.HueWidthKey] = 0.7; }
            Save(d, name, RunStep(step, stretched, p));
        }
        // Fringe needs violet pixels to do anything: a purple-tinted copy.
        var purple = stretched.Clone();
        for (int i = 0; i < purple.PixelsPerChannel; i++) { purple.Data[i] *= 1.25f; purple.Data[purple.PixelsPerChannel + i] *= 0.6f; purple.Data[2 * purple.PixelsPerChannel + i] *= 1.4f; }
        purple.Clamp01();
        Save(d, "purple", purple);
        var fp = new StepParameters(new FringeStep().Definition.Parameters);
        Save(d, "fringe_purple", RunStep(new FringeStep(), purple, fp));

        // Star recombination.
        var starless = StarField(400, 300, 3, 21, stars: 0);
        var starsLayer = field.CreateEmptyLike();
        for (int i = 0; i < starsLayer.Data.Length; i++) starsLayer.Data[i] = Math.Max(field.Data[i] - starless.Data[i], 0f);
        Save(d, "starless", starless);
        Save(d, "starslayer", starsLayer);
        var starlessStretched = GhsTransform.ApplyAll(starless, hist);
        Save(d, "fullstrength", StarStretchStep.FullStrengthStars(starless, starsLayer, starlessStretched, hist, default));
        Save(d, "addstars", StarStretchStep.AddStars(starlessStretched, stretched, 0.6f, default));
        var ss = new StarStretchStep();
        var ssp = new StepParameters(ss.Definition.Parameters);
        Save(d, "starstretch_mtf", RunStep(ss, field, ssp));

        // Star detection, matching, warping.
        var stars = StarDetector.Detect(field, out int total);
        var stars1 = StarDetector.Detect(field, maxStars: 400, thresholdSigma: 6f, downsample: 1);
        var starsMono = StarDetector.Detect(mono, out int totalMono, maxStars: 100, thresholdSigma: 4f, downsample: 3);
        var move = new SimilarityTransform(1.01f, 0.05f, 12.3f, -7.7f);
        var moved = new AstroImage(400, 300, 3);
        ImageWarp.Resample(field, move, 400, 300, (y, w, row) =>
        {
            for (int c = 0; c < 3; c++) row.Slice(c * w, w).CopyTo(moved.Data.AsSpan(c * 120000 + y * 400, 400));
        });
        Save(d, "warped", moved);
        var movedStars = StarDetector.Detect(moved);
        var match = StarMatcher.Match(stars, movedStars);
        var rot90 = CropStep.OrientRightAngle(field, 90, false, false);
        var rotStars = StarDetector.Detect(rot90);
        var tri = StarMatcher.TriangleMatch(stars, rotStars);
        var match90 = StarMatcher.Match(stars, rotStars);
        var pairs = StarMatcher.PairStars(stars, movedStars, match?.Transform ?? SimilarityTransform.Identity, 3f);
        SaveJson(d, "stars", new
        {
            total, stars = stars.Select(StarJ), stars1 = stars1.Select(StarJ), totalMono, starsMono = starsMono.Select(StarJ),
            movedStars = movedStars.Select(StarJ), rotStars = rotStars.Select(StarJ),
            match = match is null ? null : new { t = Tr(match.Transform), match.MatchedStars, match.Rms },
            tri = tri is null ? null : Tr(tri.Value),
            match90 = match90 is null ? null : new { t = Tr(match90.Transform), match90.MatchedStars, match90.Rms },
            pairs = pairs.Count, fit = Tr(StarMatcher.Fit(pairs)),
            inverse = Tr(move.Inverse()), apply = move.Apply(3.5f, 7.25f) is var (ax, ay) ? new[] { ax, ay } : null,
            fwhm = PsfMeasure.EstimateFwhm(field), fwhmMono = PsfMeasure.EstimateFwhm(mono),
        });
        Save(d, "rot90", rot90);

        // Background polynomial.
        var flat = field.CreateEmptyLike();
        var (points, degree) = BackgroundExtractionStep.Flatten(field, flat, 2, 2f, 24, default);
        Save(d, "flatten", flat);
        var flat4 = field.CreateEmptyLike();
        var (points4, degree4) = BackgroundExtractionStep.Flatten(field, flat4, 4, 1.3f, 30, default);
        Save(d, "flatten4", flat4);
        var bgeStep = new BackgroundExtractionStep();
        var bp = new StepParameters(bgeStep.Definition.Parameters);
        bp[BackgroundExtractionStep.MethodKey] = BackgroundExtractionStep.MethodPolynomial;
        bp[BackgroundExtractionStep.SmoothingKey] = 0.5; bp[BackgroundExtractionStep.StrengthKey] = 0.4; bp[BackgroundExtractionStep.GridKey] = 0.3;
        Save(d, "bgestep_poly", RunStep(bgeStep, field, bp));
        SaveJson(d, "flatten", new { points = points.Select(p => new[] { p.x, p.y }), degree, points4 = points4.Count, degree4 });

        // AI tile geometry.
        var tilings = new List<object>();
        foreach (var (win, stride, w, h) in new[] { (512, 448, 400, 300), (256, 128, 400, 300), (512, 448, 1000, 700), (256, 128, 37, 29) })
        {
            var t = new Tiling(win, stride, w, h);
            tilings.Add(new { win, stride, w, h, t.Rows, t.Cols, t.PaddedWidth, t.PaddedHeight, rowMap = t.RowMap(), colMap = t.ColMap() });
        }
        SaveJson(d, "tiling", new
        {
            tilings,
            psf = new[] { (true, "1.0.0", 3f), (false, "1.0.0", 3f), (false, "1.0.1", 3f), (false, "1.0.1", 20f), (true, "1.0.0", 1f) }
                .Select(x => DeconvolutionModel.NormalizedPsf(x.Item1, x.Item2, x.Item3)),
            thresholds = new[] { "1.0.0", "1.1.0", "2.0.0", "3.0.2" }.Select(DenoiseModel.ThresholdFor),
        });

        // Astrometry.
        Astrometry(d);

        // Frame set / name guess.
        SaveJson(d, "names", new[] { "NGC6992_0905", "M 31", "m31_lights", "IC_1396", "sh2-101 test", "Abell 426", "vdB 141", "Mel 111", "nothing here", "M31X", "2026-09-01" }
            .Select(s => new { s, guess = ObjectNameGuess.FromText(s) }));
    }

    private static AstroImage RunStep(IWorkflowStep step, AstroImage input, StepParameters p)
    {
        var ctx = new WorkflowContext { Input = input, Frames = null, Parameters = p };
        return step.RunAsync(ctx).GetAwaiter().GetResult().Image!;
    }

    public static List<(string name, GhsParams p)> GhsCases()
    {
        var list = new List<(string, GhsParams)>();
        float D = GhsParams.DFromLog(2.5);
        foreach (var type in new[] { GhsType.Ghs, GhsType.InverseGhs })
            foreach (float b in new[] { -1f, -0.5f, 0f, 1.5f, 6f })
                foreach (var (lp, sp, hp) in new[] { (0f, 0.1f, 1f), (0.02f, 0.25f, 0.9f) })
                    list.Add(($"{type}_{b}_{sp}", new GhsParams(type, D, b, lp, sp, hp, 0f, GhsColourModel.Independent)));
        foreach (var type in new[] { GhsType.Asinh, GhsType.InverseAsinh })
            foreach (var (lp, sp, hp) in new[] { (0f, 0.1f, 1f), (0.02f, 0.25f, 0.9f) })
                list.Add(($"{type}_{sp}", new GhsParams(type, D, 0f, lp, sp, hp, 0f, GhsColourModel.Independent)));
        list.Add(("linear", new GhsParams(GhsType.Linear, 0f, 0f, 0f, 0f, 1f, 0.05f, GhsColourModel.Independent)));
        list.Add(("mtf", new GhsParams(GhsType.Mtf, 0.2f, 0f, 0f, 0.01f, 1f, 0f, GhsColourModel.Independent)));
        list.Add(("identity", GhsParams.Identity));
        foreach (var (o, bg, c, pv) in new[] { (0.5f, 0f, 0f, 0.1f), (-0.4f, 0.3f, 0f, 0.2f), (0.3f, -0.5f, 0.6f, 0.15f), (0f, 0f, -0.7f, 0.1f), (1f, 1f, 1f, 0.3f) })
            list.Add(($"simple_{o}_{bg}_{c}", GhsParams.SimpleStretch(o, bg, c, pv)));
        return list;
    }

    private static void WriteFitsVariants(string d)
    {
        var rnd = new Random(9);
        int w = 13, h = 7;
        void Write(string name, int bitpix, double bzero, double bscale, int naxis3, Func<int, byte[]> value, string extra = "")
        {
            var sb = new StringBuilder();
            void Card(string k, string v) => sb.Append((k.PadRight(8) + "= " + v.PadLeft(20)).PadRight(80));
            sb.Append("SIMPLE  =                    T".PadRight(80));
            Card("BITPIX", bitpix.ToString(CultureInfo.InvariantCulture));
            Card("NAXIS", naxis3 > 1 ? "3" : "2");
            Card("NAXIS1", w.ToString(CultureInfo.InvariantCulture));
            Card("NAXIS2", h.ToString(CultureInfo.InvariantCulture));
            if (naxis3 > 1) Card("NAXIS3", naxis3.ToString(CultureInfo.InvariantCulture));
            if (bzero != 0) Card("BZERO", bzero.ToString("R", CultureInfo.InvariantCulture));
            if (bscale != 1) Card("BSCALE", bscale.ToString("R", CultureInfo.InvariantCulture));
            sb.Append("OBJECT  = 'M 31    '           / the target".PadRight(80));
            sb.Append("EXPTIME =                 30.0 / seconds".PadRight(80));
            sb.Append("COMMENT this card has no value".PadRight(80));
            sb.Append("NOTE    = 'it''s / quoted'".PadRight(80));
            if (extra.Length > 0) sb.Append(extra.PadRight(80));
            sb.Append("END".PadRight(80));
            while (sb.Length % 2880 != 0) sb.Append(' ');
            using var fs = File.Create(Path.Combine(d, name + ".fits"));
            fs.Write(Encoding.ASCII.GetBytes(sb.ToString()));
            long bytes = 0;
            for (int i = 0; i < w * h * naxis3; i++) { var b = value(i); fs.Write(b); bytes += b.Length; }
            long pad = (2880 - bytes % 2880) % 2880;
            fs.Write(new byte[pad]);
        }
        byte[] I16(short v) { var b = new byte[2]; BinaryPrimitives.WriteInt16BigEndian(b, v); return b; }
        byte[] I32(int v) { var b = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(b, v); return b; }
        byte[] F32(float v) { var b = new byte[4]; BinaryPrimitives.WriteSingleBigEndian(b, v); return b; }
        byte[] F64(double v) { var b = new byte[8]; BinaryPrimitives.WriteDoubleBigEndian(b, v); return b; }
        Write("fits_u8", 8, 0, 1, 1, _ => [(byte)rnd.Next(256)]);
        Write("fits_u16", 16, 32768, 1, 1, _ => I16((short)rnd.Next(short.MinValue, short.MaxValue)));
        Write("fits_i16", 16, 0, 1, 3, _ => I16((short)rnd.Next(0, short.MaxValue)));
        Write("fits_i32", 32, 0, 1, 1, _ => I32(rnd.Next(0, int.MaxValue)));
        Write("fits_u32", 32, 2147483648, 1, 1, _ => I32(rnd.Next(int.MinValue, int.MaxValue)));
        Write("fits_f32", -32, 0, 1, 3, _ => F32((float)rnd.NextDouble()));
        Write("fits_f32_65535", -32, 0, 1, 1, _ => F32((float)(rnd.NextDouble() * 60000)));
        Write("fits_f64", -64, 0, 1, 1, _ => F64(rnd.NextDouble()), "BAYERPAT= 'RGGB    '");
        Write("fits_scaled", 16, 100, 2, 1, _ => I16((short)rnd.Next(0, 1000)));
        var headers = new Dictionary<string, object>();
        foreach (var name in new[] { "fits_u8", "fits_u16", "fits_i16", "fits_i32", "fits_u32", "fits_f32", "fits_f32_65535", "fits_f64", "fits_scaled" })
        {
            var img = FitsReader.Read(Path.Combine(d, name + ".fits"));
            Save(d, name + "_read", img);
            headers[name] = img.Header;
        }
        headers["fits_f64_debayered"] = ImageFiles.Load(Path.Combine(d, "fits_f64.fits")).Header;
        Save(d, "fits_f64_debayered", ImageFiles.Load(Path.Combine(d, "fits_f64.fits")));
        SaveJson(d, "fits_headers", headers);
    }

    // ------------------------------------------------------------------ astrometry

    /// <summary>A synthetic Siril HEALPix catalogue (level 3) with the given stars; returns the file path.</summary>
    public static string WriteSirilCatalog(string path, List<(double ra, double dec, float g, ushort teff)> stars, int level = 3)
    {
        var hp = Healpix.ForOrder(level);
        var byPix = new List<(double ra, double dec, float g, ushort teff)>[hp.Npix];
        for (int i = 0; i < byPix.Length; i++) byPix[i] = [];
        foreach (var s in stars) byPix[PixelOf(hp, s.ra, s.dec)].Add(s);
        using var fs = File.Create(path);
        var header = new byte[128];
        Encoding.ASCII.GetBytes("Siril catalogue").CopyTo(header, 0);
        header[48] = 1; header[49] = (byte)level; header[50] = 1; header[51] = 0;
        fs.Write(header);
        uint cum = 0;
        var idx = new byte[4];
        foreach (var list in byPix) { cum += (uint)list.Count; BinaryPrimitives.WriteUInt32LittleEndian(idx, cum); fs.Write(idx); }
        var rec = new byte[16];
        foreach (var list in byPix)
            foreach (var s in list)
            {
                Array.Clear(rec);
                BinaryPrimitives.WriteInt32LittleEndian(rec, (int)Math.Round(s.ra / (360.0 / int.MaxValue)));
                BinaryPrimitives.WriteInt32LittleEndian(rec.AsSpan(4), (int)Math.Round(s.dec / (360.0 / int.MaxValue)));
                BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(12), s.teff);
                BinaryPrimitives.WriteInt16LittleEndian(rec.AsSpan(14), (short)Math.Round(s.g * 1000));
                fs.Write(rec);
            }
        return path;
    }

    /// <summary>The NESTED pixel whose centre is nearest (good enough to bucket the synthetic stars).</summary>
    private static int PixelOf(Healpix hp, double ra, double dec)
    {
        double r = ra * Math.PI / 180, de = dec * Math.PI / 180;
        double x = Math.Cos(de) * Math.Cos(r), y = Math.Cos(de) * Math.Sin(r), z = Math.Sin(de);
        int best = 0; double bestDot = -2;
        for (int p = 0; p < hp.Npix; p++)
        {
            var (pz, phi) = hp.PixToZPhi(p);
            double s = Math.Sqrt(Math.Max(0, 1 - pz * pz));
            double dot = s * Math.Cos(phi) * x + s * Math.Sin(phi) * y + pz * z;
            if (dot > bestDot) { bestDot = dot; best = p; }
        }
        return best;
    }

    private static void Astrometry(string d)
    {
        var wcs = new Wcs(10.6847, 41.2690, 199.5, 149.5, -3.0e-4, 0.4e-4, 0.4e-4, 3.0e-4);
        var header = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        wcs.WriteTo(header, 300);
        var cdelt = new Dictionary<string, string> { ["CTYPE1"] = "RA---TAN", ["CRVAL1"] = "83.8", ["CRVAL2"] = "-5.39", ["CRPIX1"] = "100", ["CRPIX2"] = "80", ["CDELT1"] = "-0.001", ["CDELT2"] = "0.001", ["CROTA2"] = "12" };
        var samples = new List<object>();
        foreach (var (x, y) in new[] { (0.0, 0.0), (199.5, 149.5), (399.0, 299.0), (50.25, 250.75) })
        {
            var (ra, dec) = wcs.PixelToSky(x, y);
            var back = wcs.SkyToPixel(ra, dec);
            samples.Add(new[] { x, y, ra, dec, back!.Value.x, back.Value.y });
        }
        var hp3 = Healpix.ForOrder(3);
        var hp8 = Healpix.ForOrder(8);
        SaveJson(d, "wcs", new
        {
            samples,
            project = new[] { (10.0, 41.0, 10.6847, 41.269), (359.9, -0.5, 0.1, 0.2), (200.0, -80.0, 180.0, -85.0) }.Select(p => Wcs.Project(p.Item1, p.Item2, p.Item3, p.Item4) is { } q ? new[] { q.xi, q.eta } : null),
            farSide = Wcs.Project(190, -41, 10, 41) is null,
            deproject = new[] { (0.5, -0.25, 10.6847, 41.269), (-1.0, 2.0, 359.5, -10.0) }.Select(p => Wcs.Deproject(p.Item1, p.Item2, p.Item3, p.Item4) is var (a, b) ? new[] { a, b } : null),
            header,
            read = Wcs.TryRead(header, 300) is { } rw ? new[] { rw.Ra, rw.Dec, rw.CrPix1, rw.CrPix2, rw.Cd11, rw.Cd12, rw.Cd21, rw.Cd22 } : null,
            readCdelt = Wcs.TryRead(cdelt, 160) is { } rc ? new[] { rc.Ra, rc.Dec, rc.CrPix1, rc.CrPix2, rc.Cd11, rc.Cd12, rc.Cd21, rc.Cd22 } : null,
            scale = wcs.ScaleArcsec, rotation = wcs.RotationDegrees, flipped = wcs.Flipped,
            fmt = new[] { 10.6847, 0.0, 359.99, 187.5 }.Select(Wcs.FormatRa),
            fmtDec = new[] { 41.269, -5.3911, 0.0, -89.999 }.Select(Wcs.FormatDec),
            sexa = new[] { ("00 42 44.3", 15.0), ("+41 16 08", 1.0), ("-05:23:28", 1.0), ("bad x", 1.0) }.Select(s => PlateSolveStep.Sexagesimal(s.Item1, s.Item2)),
            centre = new[]
            {
                new Dictionary<string, string> { ["RA"] = "10.68", ["DEC"] = "41.27" },
                new Dictionary<string, string> { ["OBJCTRA"] = "'00 42 44'", ["OBJCTDEC"] = "'+41 16 08'" },
                new Dictionary<string, string> { ["CRVAL1"] = "1.5", ["CRVAL2"] = "-2.5" },
                new Dictionary<string, string>(),
            }.Select(h => PlateSolveStep.HeaderCentre(h) is { } c ? new[] { c.ra, c.dec } : null),
            scaleHint = new[]
            {
                new Dictionary<string, string> { ["FOCALLEN"] = "250", ["XPIXSZ"] = "2.9" },
                new Dictionary<string, string> { ["CDELT2"] = "-0.0004" },
                new Dictionary<string, string>(),
            }.Select(PlateSolveStep.HeaderScale),
            healpix3 = Enumerable.Range(0, hp3.Npix).Where(p => p % 37 == 0).Select(p => { var (z, phi) = hp3.PixToZPhi(p); return new[] { p, z, phi }; }),
            healpix8 = new long[] { 0, 1, 12345, 400000, 786431 }.Select(p => { var (z, phi) = hp8.PixToZPhi(p); return new[] { p, z, phi }; }),
            disc3 = hp3.QueryDiscInclusive(10.68, 41.27, 5.0),
            disc8 = hp8.QueryDiscInclusive(83.8, -5.4, 0.8),
            teff = new[] { 25000f, 20000f, 9700f, 5770f, 5000f, 3100f, 2000f }.Select(LocalGaiaCatalog.BpRpFromTeff),
        });

        // Synthetic catalogue + image around M31 and the plate solve / colour calibration on it.
        var rnd = new Random(77);
        var truth = new Wcs(10.6847, 41.2690, 299.5, 199.5, -8.0e-4, 1.2e-4, 1.2e-4, 8.0e-4);
        var cat = new List<(double ra, double dec, float g, ushort teff)>();
        for (int i = 0; i < 700; i++)
        {
            double x = rnd.NextDouble() * 900 - 150, y = rnd.NextDouble() * 700 - 150;
            var (ra, dec) = truth.PixelToSky(x, y);
            cat.Add((ra, dec, (float)(8 + 7 * Math.Pow(rnd.NextDouble(), 0.6)), (ushort)(3500 + rnd.Next(7000))));
        }
        string catPath = WriteSirilCatalog(Path.Combine(d, "catalog_l3.dat"), cat);
        var local = LocalGaiaCatalog.Open(catPath)!;
        var cone = local.Cone(10.6847, 41.269, 0.35, 13.5f, 500);
        SaveJson(d, "catalog", new
        {
            level = local.Level,
            cone = cone.Select(s => new[] { s.Ra, s.Dec, s.G, s.Bp, s.Rp }),
            cone2 = local.Cone(10.9, 41.0, 0.1, 20f, 5).Select(s => new[] { s.Ra, s.Dec, s.G, s.Bp, s.Rp }),
        });

        // Image rendered from the catalogue with the true WCS (colours from BP−RP), then solved.
        var img = new AstroImage(600, 400, 3);
        int n = 600 * 400;
        for (int c = 0; c < 3; c++) for (int i = 0; i < n; i++) img.Data[c * n + i] = 0.05f + 0.002f * (float)(rnd.NextDouble() - 0.5);
        var all = local.Cone(10.6847, 41.269, 0.6, 20f, 5000);
        foreach (var s in all)
        {
            var p = truth.SkyToPixel(s.Ra, s.Dec);
            if (p is null) continue;
            float flux = MathF.Pow(10f, -0.4f * (s.G - 8f)) * 0.6f;
            float bprp = s.BpRp;
            float[] col = [MathF.Pow(10f, 0.4f * 0.3f * (bprp - 0.82f)), 1f, MathF.Pow(10f, -0.4f * 0.4f * (bprp - 0.82f))];
            for (int y = (int)p.Value.y - 6; y <= (int)p.Value.y + 6; y++)
                for (int x = (int)p.Value.x - 6; x <= (int)p.Value.x + 6; x++)
                {
                    if (x < 0 || y < 0 || x >= 600 || y >= 400) continue;
                    double d2 = (x - p.Value.x) * (x - p.Value.x) + (y - p.Value.y) * (y - p.Value.y);
                    float v = flux * (float)Math.Exp(-d2 / (2 * 1.4 * 1.4));
                    for (int c = 0; c < 3; c++) img.Data[c * n + y * 600 + x] += v * col[c] * (c == 0 ? 0.8f : c == 2 ? 1.15f : 1f);
                }
        }
        img.Clamp01();
        Save(d, "solve_input", img);
        var result = PlateSolver.Solve(img, cone, 10.70, 41.25, 3600 * 8.1e-4);
        var catList = cone.Select(s => new[] { s.Ra, s.Dec, s.G, s.Bp, s.Rp }).ToList();
        object? solved = result is null ? null : new { w = new[] { result.Wcs.Ra, result.Wcs.Dec, result.Wcs.CrPix1, result.Wcs.CrPix2, result.Wcs.Cd11, result.Wcs.Cd12, result.Wcs.Cd21, result.Wcs.Cd22 }, result.MatchedStars, result.RmsArcsec };
        var solvedWcs = result?.Wcs ?? truth;
        float fwhm = PsfMeasure.EstimateFwhm(img);
        var measured = ColorCalibration.Measure(img, solvedWcs, all, fwhm);
        var fit = ColorCalibration.Fit(measured, ColorCalibration.GalaxyBpRp);
        var fitVega = ColorCalibration.Fit(measured, ColorCalibration.VegaBpRp);
        Save(d, "colorcal_apply", ColorCalibration.Apply(img, fit?.RedFactor ?? 1.1f, fit?.BlueFactor ?? 0.9f, true));
        Save(d, "colorcal_apply_raw", ColorCalibration.Apply(img, 1.2f, 0.8f, false));
        SaveJson(d, "solve", new
        {
            solved,
            fwhm,
            samples = measured.Select(s => new[] { s.BpRp, s.RminusG, s.BminusG }),
            fit = fit is null ? null : new[] { fit.RedFactor, fit.BlueFactor, fit.StarsUsed, fit.SlopeR, fit.SlopeB, fit.ScatterR, fit.ScatterB },
            fitVega = fitVega is null ? null : new[] { fitVega.RedFactor, fitVega.BlueFactor, fitVega.StarsUsed },
            line = ColorCalibration.RobustLine([(0f, 1f), (1f, 3f), (2f, 5.1f), (3f, 6.9f), (4f, 9f), (5f, 30f), (6f, 13f)]) is var (a, b, k, sc) ? new object[] { a, b, k, sc } : null,
            all = all.Count,
        });

        // Online catalogue parsers.
        string tsv = "#comment\nRA_ICRS\tDE_ICRS\tGmag\tBPmag\tRPmag\ndeg\tdeg\tmag\tmag\tmag\n---\t---\t---\t---\t---\n10.1\t41.2\t9.5\t9.9\t9.0\n10.2\t41.3\t12.5\t\t\nbad\t1\t2\n";
        string csv = "ra,dec,phot_g_mean_mag,phot_bp_mean_mag,phot_rp_mean_mag\r\n10.1,41.2,9.5,9.9,9.0\r\n10.2,41.3,12.5,,\r\n";
        string sesame = "# M 31\n#=Sc=Simbad (via url):    1\n%@ 1234\n%J 10.684708 +41.26875 = 00:42:44.33 +41:16:07.5\n%J.E [3.2 2.1 0]\n";
        File.WriteAllText(Path.Combine(d, "vizier.tsv"), tsv);
        File.WriteAllText(Path.Combine(d, "tap.csv"), csv);
        File.WriteAllText(Path.Combine(d, "sesame.txt"), sesame);
        SaveJson(d, "parsers", new
        {
            tsv = VizierGaiaCatalog.ParseTsv(tsv).Select(s => new[] { s.Ra, s.Dec, s.G, s.Bp, s.Rp }),
            csv = GaiaOnlineCatalog.ParseCsv(csv).Select(s => new[] { s.Ra, s.Dec, s.G, s.Bp, s.Rp }),
            sesame = NameResolver.Parse(sesame) is { } pos ? new[] { pos.ra, pos.dec } : null,
            none = NameResolver.Parse("nothing") is null,
        });
    }

    // ------------------------------------------------------------------ real data

    private static async Task Real(string root, string framesFolder, string models, string catalogFile, bool skipStack, string? objectName)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        void Log(string s) => Console.WriteLine($"{sw.Elapsed.TotalSeconds,6:0.0} s  {s}");

        var frames = FrameSet.Scan(framesFolder);
        SaveJson(root, "frameset", new
        {
            frames.Folder,
            frames = frames.Frames.Select(f => new { name = Path.GetRelativePath(framesFolder, f.Path), type = f.Type.ToString(), f.ExposureSeconds, f.Width, f.Height, f.Filter, f.ObjectName }),
            guess = ObjectNameGuess.From(frames),
            describe = LoadFramesStep.Describe(frames),
        });
        // One raw frame as the reader sees it (FITS + Bayer).
        var first = frames.Lights.First();
        Save(root, "frame0", ImageFiles.Load(first.Path));
        Log("frame set");

        AstroImage stack;
        string stackPath = Path.Combine(root, "stack.fits");
        if (skipStack && File.Exists(stackPath)) stack = FitsReader.Read(stackPath);
        else
        {
            var step = new StackStep();
            var p = new StepParameters(step.Definition.Parameters);
            var result = await step.RunAsync(new WorkflowContext { Input = null, Frames = frames, Parameters = p });
            stack = result.Image!;
            Save(root, "stack", stack);
            SaveJson(root, "stack", new
            {
                result.Summary,
                notes = result.FrameNotes!.ToDictionary(k => Path.GetFileName(k.Key), v => new { v.Value.Used, v.Value.Text, v.Value.Stars, v.Value.StarSize, v.Value.Background, v.Value.Angle }),
            });
            Log("stack");
        }

        // Every later step on the previous C# result, with the default settings unless noted.
        async Task<AstroImage> Step(IWorkflowStep step, AstroImage input, string name, Action<StepParameters>? set = null)
        {
            var p = new StepParameters(step.Definition.Parameters);
            set?.Invoke(p);
            var r = await step.RunAsync(new WorkflowContext { Input = input, Frames = frames, Parameters = p });
            var img = r.Image ?? input;
            Save(root, name, img);
            File.WriteAllText(Path.Combine(root, name + ".txt"), r.Summary);
            Log(name);
            return img;
        }
        string Model(string kind, string version) => Path.Combine(models, kind, version, "model.onnx");

        var crop = await Step(new CropStep(), stack, "s03_crop", p => p[CropStep.MarginKey] = 0.05);
        var bgePoly = await Step(new BackgroundExtractionStep(), crop, "s04_bge_poly", p => p[BackgroundExtractionStep.MethodKey] = BackgroundExtractionStep.MethodPolynomial);
        var bge = await Step(new BackgroundExtractionStep(), crop, "s04_bge_ai", p => p[BackgroundExtractionStep.ModelKey] = Model("bge", "1.0.1"));
        // The AI steps on a centred cut of at most 1024×768 (the networks are slow on the CPU) – enough tiles for the geometry.
        int cw = Math.Min(1024, bge.Width - 64), chh = Math.Min(768, bge.Height - 64);
        int cl = (bge.Width - cw) / 2, ctp = (bge.Height - chh) / 2;
        var cut = CropStep.Crop(bge, cl, ctp, bge.Width - cl - cw, bge.Height - ctp - chh);
        Save(root, "ai_input", cut);
        await Step(new DeconvolutionStep(), cut, "s05_deconv", p =>
        {
            p[DeconvolutionStep.StarsModelKey] = Model("deconvolution-stars", "1.0.0");
            p[DeconvolutionStep.ObjectModelKey] = Model("deconvolution-object", "1.0.1");
        });
        await Step(new DenoiseStep(), cut, "s06_denoise", p => p[DenoiseStep.ModelKey] = Model("denoise", "3.0.2"));
        var bgModel = BackgroundModel.EstimateBackground(crop, Model("bge", "1.0.1"), 0.1f);
        Save(root, "bge_model", bgModel);
        Save(root, "bge_divide", BackgroundModel.Divide(crop, bgModel));
        SaveJson(root, "psf", new { fwhm = PsfMeasure.EstimateFwhm(bge), fwhmCut = PsfMeasure.EstimateFwhm(cut) });
        Log("ai");

        // Plate solve with the offline catalogue, then the colour calibration on the same catalogue. A data
        // set without a usable centre or scale fails here: the reference records the message instead.
        var catalog = LocalGaiaCatalog.Open(catalogFile) ?? throw new InvalidOperationException("catalogue");
        PlateSolveStep.Catalog = catalog;
        AstroImage calibrated;
        try
        {
            var solved = await Step(new PlateSolveStep(), bge, "s07_platesolve", p => { if (objectName is not null) p[PlateSolveStep.ObjectKey] = objectName; });
            var wcs = Wcs.TryRead(solved.Header, solved.Height)!;
            SaveJson(root, "s07_platesolve", new
            {
                wcs = new[] { wcs.Ra, wcs.Dec, wcs.CrPix1, wcs.CrPix2, wcs.Cd11, wcs.Cd12, wcs.Cd21, wcs.Cd22 },
                PlateSolveStep.LastResult!.MatchedStars, PlateSolveStep.LastResult.RmsArcsec,
                header = solved.Header,
            });
            double fov = Math.Sqrt((double)solved.Width * solved.Width + (double)solved.Height * solved.Height) * wcs.ScaleArcsec / 3600.0;
            var centre = wcs.PixelToSky((solved.Width - 1) / 2.0, (solved.Height - 1) / 2.0);
            var stars = catalog.Cone(centre.ra, centre.dec, 0.5 * fov + 0.05, 14f, 4000);
            File.WriteAllLines(Path.Combine(root, "s08_catalog.csv"), stars.Select(s => string.Join(",", new[] { s.Ra, s.Dec, s.G, s.Bp, s.Rp }.Select(v => v.ToString("R", CultureInfo.InvariantCulture)))));
            float fwhm = PsfMeasure.EstimateFwhm(solved);
            var samples = ColorCalibration.Measure(solved, wcs, stars, fwhm);
            var fit = ColorCalibration.Fit(samples, ColorCalibration.GalaxyBpRp)!;
            calibrated = ColorCalibration.Apply(solved, fit.RedFactor, fit.BlueFactor, true);
            calibrated.Header["CLRCAL"] = "T";
            Save(root, "s08_colorcal", calibrated);
            SaveJson(root, "s08_colorcal", new { fwhm, samples = samples.Count, fit = new[] { fit.RedFactor, fit.BlueFactor, fit.StarsUsed } });
        }
        catch (InvalidOperationException ex)
        {
            SaveJson(root, "s07_platesolve", new { error = ex.Message });
            calibrated = bge;
            Save(root, "s08_colorcal", calibrated);
            SaveJson(root, "s08_colorcal", new { skipped = true });
        }
        Log("colour");

        // Stretch as the CLI does it: auto stretch, then the default sliders committed.
        var ghs = new StarlessStretchStep();
        var gp = new StepParameters(ghs.Definition.Parameters);
        StarlessStretchStep.CommitAuto(gp, calibrated);
        var stretched = await Step(ghs, calibrated, "s10_ghs", p => { foreach (var (k, v) in gp.Values) p[k] = v; });
        File.WriteAllText(Path.Combine(root, "s10_history.json"), gp.GetString(StarlessStretchStep.HistoryKey));
        var star = await Step(new StarStretchStep(), stretched, "s11_starstretch");
        var starMtf = await Step(new StarStretchStep(), calibrated, "s11_starstretch_mtf");
        var green = await Step(new GreenRemovalStep(), stretched, "s12_green");
        var fringe = await Step(new FringeStep(), green, "s13_fringe");
        var contrast = await Step(new ContrastStep(), fringe, "s14_contrast");
        var saturation = await Step(new SaturationStep(), contrast, "s15_saturation");
        ImageFiles.Save(Path.Combine(root, "s16_final.tif"), saturation, ExportFormat.Tiff16);
        Log("done");
    }
}
