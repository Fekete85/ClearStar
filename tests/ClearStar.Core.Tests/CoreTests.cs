using ClearStar.Core.Imaging;
using ClearStar.Core.IO;
using ClearStar.Core.Pipeline;
using ClearStar.Core.Steps;
using ClearStar.Core.Registration;
using Xunit;

// A nyelvi tabla globalis allapot: a nyelvvaltos teszt miatt a tesztosztalyok nem futhatnak parhuzamosan.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace ClearStar.Core.Tests;

public class FitsTests
{
    [Fact]
    public void FloatFitsRoundTrip()
    {
        var img = new AstroImage(7, 5, 3);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = i / (float)img.Data.Length;
        img.Header["OBJECT"] = "M31";
        img.Header["EXPTIME"] = "120.5";

        using var ms = new MemoryStream();
        FitsWriter.Write(ms, img);
        Assert.Equal(0, ms.Length % FitsReader.BlockSize);
        ms.Position = 0;
        var back = FitsReader.Read(ms);

        Assert.Equal(img.Width, back.Width);
        Assert.Equal(img.Height, back.Height);
        Assert.Equal(img.Channels, back.Channels);
        Assert.Equal(img.Data, back.Data);
        Assert.Equal("M31", back.Header["OBJECT"]);
        Assert.Equal("120.5", back.Header["EXPTIME"]);
    }

    [Fact]
    public void Reads16BitUnsignedConvention()
    {
        // 2x2 mono, BITPIX=16, BZERO=32768: raw -32768 → 0, raw 32767 → 65535.
        var header = "SIMPLE  =                    T" + new string(' ', 50)
            + "BITPIX  =                   16" + new string(' ', 50)
            + "NAXIS   =                    2" + new string(' ', 50)
            + "NAXIS1  =                    2" + new string(' ', 50)
            + "NAXIS2  =                    2" + new string(' ', 50)
            + "BZERO   =                32768" + new string(' ', 50)
            + "END" + new string(' ', 77);
        header = header.PadRight(FitsReader.BlockSize);
        var bytes = new List<byte>(System.Text.Encoding.ASCII.GetBytes(header));
        short[] raw = [-32768, 32767, 0, -32768];
        foreach (var v in raw) { bytes.Add((byte)(v >> 8)); bytes.Add((byte)(v & 0xFF)); }
        while (bytes.Count % FitsReader.BlockSize != 0) bytes.Add(0);

        var img = FitsReader.Read(new MemoryStream(bytes.ToArray()));
        // A FITS első sora a kép alsó sora, ezért a (0,0) raw érték a képen az utolsó sorba kerül.
        Assert.Equal(0f, img[0, 0, 1], 5);
        Assert.Equal(1f, img[0, 1, 1], 5);
        Assert.Equal(32768f / 65535f, img[0, 0, 0], 5);
    }
}

public class StretchTests
{
    [Fact]
    public void MtfMapsMedianToTarget()
    {
        var stats = new ChannelStats(0, 1, 0.02f, 0.002f, 0.02f);
        var p = DisplayStretch.Compute(stats, 0.25f);
        Assert.Equal(0.25f, p.Apply(0.02f), 3);
    }

    [Theory]
    [InlineData(GhsType.Ghs, 1f)] [InlineData(GhsType.Ghs, 0f)] [InlineData(GhsType.Ghs, -1f)] [InlineData(GhsType.Ghs, -2f)]
    [InlineData(GhsType.InverseGhs, 1f)] [InlineData(GhsType.InverseGhs, 0f)] [InlineData(GhsType.Asinh, 0f)] [InlineData(GhsType.InverseAsinh, 0f)]
    public void GhsIsMonotonicAndNormalized(GhsType type, float b)
    {
        // Siril-style parameters: D = e^2 − 1, LP/SP/HP protection points inside the range.
        var ghs = new GhsTransform(new GhsParams(type, GhsParams.DFromLog(2.0), b, 0.02f, 0.05f, 0.9f, 0f, GhsColourModel.Independent));
        float prev = -1f;
        for (int i = 0; i <= 200; i++)
        {
            float y = ghs.Apply(i / 200f);
            Assert.True(y >= prev - 1e-5f, $"not monotonic at {i / 200f}: {prev} -> {y}");
            Assert.True(float.IsFinite(y));
            prev = y;
        }
        Assert.Equal(0f, ghs.Apply(0f), 4);
        Assert.Equal(1f, ghs.Apply(1f), 4);
        // The forward and inverse hyperbolic stretches undo each other.
        if (type == GhsType.Ghs)
        {
            var inv = new GhsTransform(new GhsParams(GhsType.InverseGhs, GhsParams.DFromLog(2.0), b, 0.02f, 0.05f, 0.9f, 0f, GhsColourModel.Independent));
            for (int i = 1; i < 200; i++) { float x = i / 200f; Assert.InRange(inv.Apply(ghs.Apply(x)), x - 2e-3f, x + 2e-3f); }
        }
    }

    [Theory]
    [InlineData(0f, 0f, 0f)] [InlineData(1f, 0f, 0f)] [InlineData(-1f, 0f, 0f)] [InlineData(0f, 1f, 0f)] [InlineData(0f, -1f, 0f)]
    [InlineData(0f, 0f, 1f)] [InlineData(0f, 0f, -1f)] [InlineData(0.6f, -0.4f, 0.8f)]
    public void SimpleStretchKeepsTheBackgroundWhereTheSliderPutsIt(float objects, float background, float contrast)
    {
        const float bg = 0.2f; // background after the auto stretch
        var p = GhsParams.SimpleStretch(objects, background, contrast, bg);
        Assert.Equal(objects == 0f && background == 0f && contrast == 0f, p.IsIdentity);
        var t = new GhsTransform(p);
        float prev = -1f;
        for (int i = 0; i <= 400; i++)
        {
            float y = t.Apply(i / 400f);
            Assert.True(y >= prev - 1e-5f, $"not monotonic at {i / 400f}: {prev} -> {y}");
            prev = y;
        }
        Assert.Equal(0f, t.Apply(0f), 4);
        Assert.Equal(1f, t.Apply(1f), 3);
        // The background lands on the level the background slider asks for; objects and contrast leave it alone.
        float expectedBg = bg + 0.12f * background;
        Assert.InRange(t.Apply(bg), expectedBg - 2e-3f, expectedBg + 2e-3f);
        // Objects: brighter or darker than the identity above the background.
        float mid = t.Apply(0.5f);
        if (objects > 0f && background == 0f && contrast == 0f) Assert.True(mid > 0.5f);
        if (objects < 0f && background == 0f && contrast == 0f) Assert.True(mid < 0.5f);
        // Contrast: steeper just above the background.
        if (contrast > 0f && objects == 0f && background == 0f) Assert.True(t.Apply(bg + 0.02f) - t.Apply(bg) > 0.02f);
        if (contrast < 0f && objects == 0f && background == 0f) Assert.True(t.Apply(bg + 0.02f) - t.Apply(bg) < 0.02f);
        // Round trip through the history JSON.
        var back = GhsParams.ListFromJson(GhsParams.ListToJson([p]));
        Assert.Single(back);
        Assert.Equal(p, back[0]);
    }
}

public class WorkflowTests
{
    private sealed class FakeStep(StepId id, float add) : IWorkflowStep
    {
        public StepDefinition Definition { get; } = new(id, StepGroup.Basics, id.ToString(), null, "", []);
        public Task<StepResult> RunAsync(WorkflowContext context)
        {
            AstroImage img = context.Input?.Clone() ?? new AstroImage(2, 2, 1);
            for (int i = 0; i < img.Data.Length; i++) img.Data[i] += add;
            return Task.FromResult(new StepResult(img, $"+{add}"));
        }
    }

    private static Workflow Make() => new([new FakeStep(StepId.Stack, 0.1f), new FakeStep(StepId.Crop, 0.2f), new FakeStep(StepId.Contrast, 0.3f)],
        new SnapshotStore(memoryLimit: 1, folder: Path.Combine(Path.GetTempPath(), "ClearStarTests", Guid.NewGuid().ToString("N"))));

    [Fact]
    public async Task RerunningEarlierStepMarksLaterStale()
    {
        using var wf = Make();
        await wf.RunAsync(StepId.Stack);
        await wf.RunAsync(StepId.Crop);
        await wf.RunAsync(StepId.Contrast);
        Assert.Equal(0.6f, wf.Current!.Data[0], 5);
        Assert.Equal(3, wf.DoneCount);

        await wf.RunAsync(StepId.Crop);
        Assert.Equal(StepState.Stale, wf[StepId.Contrast].State);
        Assert.Equal(0.3f, wf.Current!.Data[0], 5);
        Assert.Equal(0.1f, wf.Original!.Data[0], 5);
        Assert.Equal(StepId.Contrast, wf.NextPending);
    }

    [Fact]
    public async Task SkippedStepIsBypassed()
    {
        using var wf = Make();
        await wf.RunAsync(StepId.Stack);
        wf.Skip(StepId.Crop);
        await wf.RunAsync(StepId.Contrast);
        Assert.Equal(0.4f, wf.Current!.Data[0], 5);
        Assert.Equal(StepState.Skipped, wf[StepId.Crop].State);
    }

    [Fact]
    public void SnapshotStoreSpillsToDiskAndReloads()
    {
        using var store = new SnapshotStore(memoryLimit: 1, folder: Path.Combine(Path.GetTempPath(), "ClearStarTests", Guid.NewGuid().ToString("N")));
        var a = new AstroImage(3, 2, 1, [1, 2, 3, 4, 5, 6]);
        var b = new AstroImage(2, 2, 3);
        store.Put(1, a);
        store.Put(2, b);
        var back = store.Get(1)!;
        Assert.Equal(a.Data, back.Data);
        Assert.Equal(3, back.Width);
    }
}

public class StepTests
{
    [Fact]
    public async Task BackgroundExtractionFlattensGradient()
    {
        int w = 256, h = 160;
        var img = new AstroImage(w, h, 1);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                img[0, x, y] = 0.05f + 0.1f * x / w + 0.05f * y / h;
        var step = new BackgroundExtractionStep();
        var prms = new StepParameters(step.Definition.Parameters);
        prms[BackgroundExtractionStep.MethodKey] = BackgroundExtractionStep.MethodPolynomial;
        var ctx = new WorkflowContext { Input = img, Frames = null, Parameters = prms };
        var result = await step.RunAsync(ctx);
        var stats = ImageStats.Compute(result.Image!.Channel(0));
        Assert.True(stats.Max - stats.Min < 0.005f, $"A háttér nem lett sík: {stats.Min}..{stats.Max}");
    }

    [Fact]
    public async Task AiBackgroundExtractionFlattensGradientWhenModelAvailable()
    {
        if (ClearStar.Core.AI.AiModelStore.Resolve(ClearStar.Core.AI.AiModelKind.BackgroundExtraction) is null) return; // nincs modell a gépen – kihagyjuk
        int w = 512, h = 384;
        var img = new AstroImage(w, h, 3);
        var rng = new Random(5);
        for (int c = 0; c < 3; c++)
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    img[c, x, y] = 0.08f + 0.1f * x / w + 0.05f * y / h + (float)rng.NextDouble() * 0.002f;
        var step = new BackgroundExtractionStep();
        var ctx = new WorkflowContext { Input = img, Frames = null, Parameters = new StepParameters(step.Definition.Parameters) };
        var result = await step.RunAsync(ctx);
        var stats = ImageStats.Compute(result.Image!.Channel(1));
        // A 0,15-ös gradiensből legfeljebb 0,02 maradhat.
        Assert.True(stats.Max - stats.Min < 0.02f, $"Az AI nem simította ki a hátteret: {stats.Min}..{stats.Max}");
        Assert.Contains("AI-modell", result.Summary);
    }

    [Fact]
    public async Task GreenRemovalOnlyLowersGreen()
    {
        var img = new AstroImage(1, 1, 3, [0.2f, 0.5f, 0.3f]);
        var step = new GreenRemovalStep();
        var ctx = new WorkflowContext { Input = img, Frames = null, Parameters = new StepParameters(step.Definition.Parameters) };
        var r = (await step.RunAsync(ctx)).Image!;
        Assert.Equal(0.2f, r.Data[0]);
        Assert.Equal(0.25f, r.Data[1], 5);
        Assert.Equal(0.3f, r.Data[2]);
    }
}

public class RegistrationTests
{
    [Fact]
    public void MatcherRecoversRotationAndShift()
    {
        var rng = new Random(7);
        var reference = Enumerable.Range(0, 120).Select(_ => new Star((float)(rng.NextDouble() * 2000), (float)(rng.NextDouble() * 3000), (float)rng.NextDouble() * 100, 2f)).ToList();
        // A kép a referenciához képest 1.5°-kal elforgatva és eltolva; néhány csillag hiányzik / plusz.
        var truth = new ClearStar.Core.Registration.SimilarityTransform(1f, 1.5f * MathF.PI / 180f, 37.5f, -22f);
        var inv = truth.Inverse();
        var frame = reference.Skip(10).Select(s => { var (x, y) = inv.Apply(s.X, s.Y); return new Star(x + (float)(rng.NextDouble() - 0.5) * 0.4f, y + (float)(rng.NextDouble() - 0.5) * 0.4f, s.Flux, s.Size); })
            .Concat(Enumerable.Range(0, 15).Select(_ => new Star((float)(rng.NextDouble() * 2000), (float)(rng.NextDouble() * 3000), 5f, 2f)))
            .OrderByDescending(s => s.Flux).ToList();

        var match = ClearStar.Core.Registration.StarMatcher.Match(reference, frame);
        Assert.NotNull(match);
        Assert.True(match.MatchedStars >= 80, $"csak {match.MatchedStars} pár");
        Assert.Equal(1.5f, match.Transform.AngleDegrees, 2);
        Assert.Equal(37.5f, match.Transform.Tx, 1);
        Assert.Equal(-22f, match.Transform.Ty, 1);
        Assert.True(match.Rms < 0.5f);
    }

    [Fact]
    public void DetectorFindsGaussianStars()
    {
        int w = 400, h = 300;
        var img = new AstroImage(w, h, 1);
        var rng = new Random(3);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = 0.05f + (float)rng.NextDouble() * 0.002f;
        var truth = new List<(float x, float y)> { (50.3f, 60.7f), (200.1f, 150.4f), (333.6f, 240.2f), (120f, 280f) };
        foreach (var (sx, sy) in truth)
            for (int y = (int)sy - 5; y <= sy + 5; y++)
                for (int x = (int)sx - 5; x <= sx + 5; x++)
                    img[0, x, y] += 0.5f * MathF.Exp(-((x - sx) * (x - sx) + (y - sy) * (y - sy)) / 4f);
        var stars = ClearStar.Core.Registration.StarDetector.Detect(img, downsample: 1);
        Assert.Equal(truth.Count, stars.Count);
        foreach (var (sx, sy) in truth)
            Assert.Contains(stars, s => Math.Abs(s.X - sx) < 0.3f && Math.Abs(s.Y - sy) < 0.3f);
    }
}

public class DebayerTests
{
    [Fact]
    public void BilinearKeepsFlatFieldFlat()
    {
        var cfa = new AstroImage(8, 6, 1);
        for (int y = 0; y < 6; y++) for (int x = 0; x < 8; x++)
            cfa[0, x, y] = (x + y) % 2 == 0 ? 0.4f : ((y % 2 == 0) ? 0.2f : 0.6f); // GRBG: G=0.4, R=0.2, B=0.6
        var rgb = Debayer.Bilinear(cfa, BayerPattern.GRBG);
        Assert.Equal(3, rgb.Channels);
        Assert.Equal(0.2f, rgb[0, 3, 3], 3);
        Assert.Equal(0.4f, rgb[1, 3, 3], 3);
        Assert.Equal(0.6f, rgb[2, 3, 3], 3);
    }
}

public class CropTests
{
    [Fact]
    public async Task SelectionCropsToFraction()
    {
        var img = new AstroImage(1000, 500, 1);
        var step = new CropStep();
        var p = new StepParameters(step.Definition.Parameters);
        p[CropStep.SelLeftKey] = 0.1; p[CropStep.SelTopKey] = 0.2; p[CropStep.SelWidthKey] = 0.5; p[CropStep.SelHeightKey] = 0.4;
        var r = await step.RunAsync(new WorkflowContext { Input = img, Frames = null, Parameters = p });
        Assert.Equal(500, r.Image!.Width);
        Assert.Equal(200, r.Image.Height);
    }

    [Fact]
    public async Task NoSelectionUsesMargin()
    {
        var img = new AstroImage(1000, 500, 1);
        var step = new CropStep();
        var p = new StepParameters(step.Definition.Parameters);
        p[CropStep.MarginKey] = 0.1;
        var r = await step.RunAsync(new WorkflowContext { Input = img, Frames = null, Parameters = p });
        Assert.Equal(800, r.Image!.Width);
        Assert.Equal(400, r.Image.Height);
    }
}

public class TriangleMatchTests
{
    [Fact]
    public void MatcherHandlesLargeRotation()
    {
        var rng = new Random(11);
        var reference = Enumerable.Range(0, 150).Select(_ => new Star((float)(rng.NextDouble() * 2160), (float)(rng.NextDouble() * 3840), (float)rng.NextDouble() * 100, 2f)).ToList();
        // 85°-os elforgatás nagy eltolással – itt az eltolás-szavazás biztosan nem működik.
        var truth = new ClearStar.Core.Registration.SimilarityTransform(1f, 85f * MathF.PI / 180f, -2800f, -700f);
        var inv = truth.Inverse();
        var frame = reference.Skip(20).Select(s => { var (x, y) = inv.Apply(s.X, s.Y); return new Star(x + (float)(rng.NextDouble() - 0.5) * 0.4f, y + (float)(rng.NextDouble() - 0.5) * 0.4f, s.Flux * (0.9f + 0.2f * (float)rng.NextDouble()), s.Size); })
            .Concat(Enumerable.Range(0, 25).Select(_ => new Star((float)(rng.NextDouble() * 2160), (float)(rng.NextDouble() * 3840), 5f, 2f)))
            .OrderByDescending(s => s.Flux).ToList();

        var match = ClearStar.Core.Registration.StarMatcher.Match(reference, frame);
        Assert.NotNull(match);
        Assert.Equal(85f, match.Transform.AngleDegrees, 1);
        Assert.True(match.MatchedStars >= 100, $"csak {match.MatchedStars} pár");
        Assert.True(match.Rms < 0.5f);
    }
}

public class CoverageTests
{
    [Fact]
    public void FindsLargestFilledRectangle()
    {
        // 400x300 kép, a bal felső 100x300 sáv és az alsó 60 sor üres → a kitöltött rész 300x240 jobbra fent.
        var img = new AstroImage(400, 300, 1);
        for (int py = 0; py < 240; py++) for (int px = 100; px < 400; px++) img[0, px, py] = 0.1f;
        var r = Coverage.LargestFilledRectangle(img, 4);
        Assert.NotNull(r);
        var (x, y, w, h) = r.Value;
        Assert.InRange(x * 400, 100, 112);
        Assert.InRange(y * 300, 0, 8);
        Assert.InRange((x + w) * 400, 388, 400);
        Assert.InRange((y + h) * 300, 228, 240);
    }

    [Fact]
    public void FullyCoveredImageNeedsNoCrop()
    {
        var img = new AstroImage(200, 200, 3);
        Array.Fill(img.Data, 0.2f);
        Assert.Null(Coverage.LargestFilledRectangle(img));
    }
}

public class LocalizationTests
{
    private static Dictionary<string, string> Table(string code)
    {
        var asm = typeof(ClearStar.Core.Localization.L).Assembly;
        using var s = asm.GetManifestResourceStream($"ClearStar.Core.Languages.{code}.json")!;
        using var r = new StreamReader(s);
        return ClearStar.Core.Localization.L.Parse(r.ReadToEnd());
    }

    [Fact]
    public void BuiltInLanguagesHaveTheSameKeys()
    {
        var hu = Table("hu");
        var en = Table("en");
        var missingInEn = hu.Keys.Except(en.Keys).ToList();
        var missingInHu = en.Keys.Except(hu.Keys).ToList();
        Assert.True(missingInEn.Count == 0, "Hianyzik az en.json-bol: " + string.Join(", ", missingInEn));
        Assert.True(missingInHu.Count == 0, "Hianyzik a hu.json-bol: " + string.Join(", ", missingInHu));
        // A helyorzok szama is egyezzen (kulonben a string.Format elszall).
        foreach (var (k, v) in hu)
            Assert.Equal(System.Text.RegularExpressions.Regex.Matches(v, @"\{\d").Count, System.Text.RegularExpressions.Regex.Matches(en[k], @"\{\d").Count);
    }

    [Fact]
    public void StepDefinitionsAreLocalizedAndChoicesAreKeys()
    {
        ClearStar.Core.Localization.L.Load("en");
        var steps = StepCatalog.CreateAll();
        Assert.Equal(17, steps.Count);
        foreach (var step in steps)
        {
            Assert.DoesNotContain("step.", step.Definition.Name);
            foreach (var p in step.Definition.Parameters)
            {
                if (p.Kind == ParameterKind.Hidden) continue;
                Assert.DoesNotContain("step.", p.Label);
                if (p.Kind == ParameterKind.Slider) Assert.True(p.TickLabels!.Length >= 2 && !p.TickLabels[0].Contains("step."));
                if (p.Kind == ParameterKind.Choice)
                {
                    Assert.All(p.Choices!, c => Assert.DoesNotContain(" ", c));
                    Assert.Equal(p.Choices!.Length, p.ChoiceLabels!.Length);
                }
            }
        }
        Assert.Equal("Stack images", steps[1].Definition.Name);
        ClearStar.Core.Localization.L.Load("hu");
        Assert.Equal("Vágás", new CropStep().Definition.Name);
        Assert.Equal("kulcs.ami.nincs", ClearStar.Core.Localization.L.T("kulcs.ami.nincs"));
    }
}

public class DeconvolutionTests
{
    [Fact]
    public void PadIndexRepeatsEdgesLikeGraXpert()
    {
        // size 1000, extended to 1344 (3 strides): rows 1000..1343 repeat rows 656..999,
        // then a 32 px border repeats the first/last 32 rows of the extended image.
        const int size = 1000, ext = 1344, off = ClearStar.Core.AI.DeconvolutionModel.Offset;
        Assert.Equal(0, ClearStar.Core.AI.DeconvolutionModel.PadIndex(0, size, ext));
        Assert.Equal(31, ClearStar.Core.AI.DeconvolutionModel.PadIndex(31, size, ext));
        Assert.Equal(0, ClearStar.Core.AI.DeconvolutionModel.PadIndex(off, size, ext));
        Assert.Equal(999, ClearStar.Core.AI.DeconvolutionModel.PadIndex(off + 999, size, ext));
        Assert.Equal(656, ClearStar.Core.AI.DeconvolutionModel.PadIndex(off + 1000, size, ext));
        Assert.Equal(999, ClearStar.Core.AI.DeconvolutionModel.PadIndex(off + 1343, size, ext));
        Assert.Equal(1344 - 32 - 344, ClearStar.Core.AI.DeconvolutionModel.PadIndex(off + 1344, size, ext));
        Assert.Equal(999, ClearStar.Core.AI.DeconvolutionModel.PadIndex(off + 1344 + 31, size, ext));
    }

    [Fact]
    public void NormalizedPsfFollowsModelVersion()
    {
        Assert.Equal(0.05f, ClearStar.Core.AI.DeconvolutionModel.NormalizedPsf(true, "1.0.0", 1f));
        Assert.InRange(ClearStar.Core.AI.DeconvolutionModel.NormalizedPsf(true, "1.0.0", 5f), 0.20f, 0.21f);
        Assert.InRange(ClearStar.Core.AI.DeconvolutionModel.NormalizedPsf(false, "1.0.1", 5f), 0.29f, 0.30f);
        Assert.InRange(ClearStar.Core.AI.DeconvolutionModel.NormalizedPsf(false, "1.0.0", 5f), 0.22f, 0.23f);
        Assert.Equal(0.95f, ClearStar.Core.AI.DeconvolutionModel.NormalizedPsf(true, "1.0.0", 40f));
    }

    [Fact]
    public void FwhmIsMeasuredFromSyntheticStars()
    {
        var img = new AstroImage(600, 400, 1);
        var rnd = new Random(3);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = 0.05f + (rnd.NextSingle() - 0.5f) * 0.004f;
        const float sigma = 1.7f; // FWHM ≈ 4.0 px
        for (int s = 0; s < 60; s++)
        {
            float cx = 20 + rnd.NextSingle() * 560, cy = 20 + rnd.NextSingle() * 360, amp = 0.2f + rnd.NextSingle() * 0.5f;
            for (int y = -8; y <= 8; y++) for (int x = -8; x <= 8; x++)
            {
                int px = (int)cx + x, py = (int)cy + y;
                float dx = px - cx, dy = py - cy;
                img[0, px, py] += amp * MathF.Exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
            }
        }
        float fwhm = ClearStar.Core.Imaging.PsfMeasure.EstimateFwhm(img);
        Assert.InRange(fwhm, 3.2f, 4.8f);
    }

    [Fact]
    public void DeconvolutionRunsWithLocalModelsIfPresent()
    {
        var stars = ClearStar.Core.AI.AiModelStore.Resolve(ClearStar.Core.AI.AiModelKind.DeconvolutionStars);
        if (stars is null) return; // no model on this machine – nothing to verify
        var img = new AstroImage(300, 200, 3);
        Array.Fill(img.Data, 0.1f);
        for (int c = 0; c < 3; c++) for (int y = 95; y < 105; y++) for (int x = 145; x < 155; x++) img[c, x, y] = 0.6f;
        var outp = ClearStar.Core.AI.DeconvolutionModel.Deconvolve(img, stars.Path, true, 0.5f, 4f);
        Assert.Equal(img.Width, outp.Width);
        Assert.Equal(img.Height, outp.Height);
        Assert.All(outp.Data, v => Assert.False(float.IsNaN(v)));
    }
}

public class DenoiseTests
{
    [Fact]
    public void TilingGeometryMatchesGraXpert()
    {
        var t = new ClearStar.Core.AI.Tiling(256, 128, 1000, 700);
        Assert.Equal(64, t.Offset);
        Assert.Equal(6, t.Rows);      // 700/128 + 1
        Assert.Equal(8, t.Cols);      // 1000/128 + 1
        Assert.Equal(768 + 128, t.PaddedHeight);
        Assert.Equal(1024 + 128, t.PaddedWidth);
        var rows = t.RowMap();
        Assert.Equal(0, rows[64]);
        Assert.Equal(699, rows[64 + 699]);
        Assert.Equal(700 - 68, rows[64 + 700]); // the last 68 rows are repeated
    }

    [Fact]
    public void DenoiseRunsWithLocalModelIfPresent()
    {
        var model = ClearStar.Core.AI.AiModelStore.Resolve(ClearStar.Core.AI.AiModelKind.Denoise);
        if (model is null) return;
        var rnd = new Random(1);
        var img = new AstroImage(300, 200, 3);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = 0.1f + (rnd.NextSingle() - 0.5f) * 0.02f;
        var outp = ClearStar.Core.AI.DenoiseModel.Denoise(img, model.Path, 1f);
        float madIn = ImageStats.Compute(img.Channel(0).ToArray()).Mad, madOut = ImageStats.Compute(outp.Channel(0).ToArray()).Mad;
        Assert.True(madOut < madIn * 0.7f, $"noise not reduced: {madIn} -> {madOut}");
        Assert.InRange(ImageStats.Compute(outp.Channel(0).ToArray()).Median, 0.09f, 0.11f);
    }
}

public class AstrometryTests
{
    [Fact]
    public void ProjectionRoundTrips()
    {
        var p = ClearStar.Core.Astrometry.Wcs.Project(11.2, 41.9, 10.68, 41.27)!.Value;
        var (ra, dec) = ClearStar.Core.Astrometry.Wcs.Deproject(p.xi, p.eta, 10.68, 41.27);
        Assert.InRange(ra, 11.2 - 1e-9, 11.2 + 1e-9);
        Assert.InRange(dec, 41.9 - 1e-9, 41.9 + 1e-9);
    }

    [Fact]
    public void WcsHeaderRoundTrips()
    {
        double s = 2.3 / 3600, rot = 25 * Math.PI / 180;
        var wcs = new ClearStar.Core.Astrometry.Wcs(10.68, 41.27, 399.5, 299.5, -s * Math.Cos(rot), s * Math.Sin(rot), s * Math.Sin(rot), s * Math.Cos(rot));
        var header = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        wcs.WriteTo(header, 600);
        var back = ClearStar.Core.Astrometry.Wcs.TryRead(header, 600)!;
        var a = wcs.PixelToSky(100, 50); var b = back.PixelToSky(100, 50);
        Assert.InRange(b.ra, a.ra - 1e-9, a.ra + 1e-9);
        Assert.InRange(b.dec, a.dec - 1e-9, a.dec + 1e-9);
        Assert.InRange(wcs.ScaleArcsec, 2.299, 2.301);
        var px = wcs.SkyToPixel(a.ra, a.dec)!.Value;
        Assert.InRange(px.x, 99.99, 100.01); Assert.InRange(px.y, 49.99, 50.01);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SolvesSyntheticFieldWithRoughHints(bool mirrored)
    {
        // A true WCS (rotated 33°, optionally mirrored) generates a star field; the hints are off by
        // 0.15° in position and 6% in scale, as a real telescope header would be.
        const int w = 900, h = 700;
        double s = 2.3 / 3600, rot = 33 * Math.PI / 180, sign = mirrored ? -1 : 1;
        var truth = new ClearStar.Core.Astrometry.Wcs(10.68, 41.27, (w - 1) / 2.0, (h - 1) / 2.0,
            sign * -s * Math.Cos(rot), s * Math.Sin(rot), sign * s * Math.Sin(rot), s * Math.Cos(rot));
        var rnd = new Random(7);
        var catalog = new List<ClearStar.Core.Astrometry.CatalogStar>();
        var img = new AstroImage(w, h, 1);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = 0.05f + (rnd.NextSingle() - 0.5f) * 0.004f;
        for (int i = 0; i < 400; i++)
        {
            double ra = 10.68 + (rnd.NextDouble() - 0.5) * 1.2, dec = 41.27 + (rnd.NextDouble() - 0.5) * 0.9;
            float g = 8f + rnd.NextSingle() * 6f;
            catalog.Add(new ClearStar.Core.Astrometry.CatalogStar(ra, dec, g, g + 0.3f, g - 0.4f));
            var p = truth.SkyToPixel(ra, dec); if (p is null) continue;
            double cx = p.Value.x, cy = p.Value.y;
            if (cx < 10 || cy < 10 || cx > w - 11 || cy > h - 11) continue;
            float amp = 0.9f * MathF.Pow(10f, -0.4f * (g - 8f));
            for (int y = -6; y <= 6; y++) for (int x = -6; x <= 6; x++)
            {
                int px = (int)Math.Round(cx) + x, py = (int)Math.Round(cy) + y;
                double dx = px - cx, dy = py - cy;
                img[0, px, py] = Math.Min(1f, img[0, px, py] + amp * MathF.Exp(-(float)(dx * dx + dy * dy) / (2 * 1.5f * 1.5f)));
            }
        }
        var result = ClearStar.Core.Astrometry.PlateSolver.Solve(img, catalog, 10.68 + 0.15, 41.27 - 0.1, 2.3 * 1.06);
        Assert.NotNull(result);
        Assert.True(result!.MatchedStars >= 30, $"matched {result.MatchedStars}");
        var centre = result.Wcs.PixelToSky((w - 1) / 2.0, (h - 1) / 2.0);
        Assert.InRange(Math.Abs(centre.ra - 10.68) * 3600 * Math.Cos(41.27 * Math.PI / 180), 0, 1.5);
        Assert.InRange(Math.Abs(centre.dec - 41.27) * 3600, 0, 1.5);
        Assert.InRange(result.Wcs.ScaleArcsec, 2.29, 2.31);
        Assert.Equal(mirrored, result.Wcs.Flipped);
        Assert.InRange(result.RmsArcsec, 0, 1.0);
    }

    [Fact]
    public void ParsesVizierAndSesameFormats()
    {
        string tsv = "#comment\nRA_ICRS\tDE_ICRS\tGmag\tBPmag\tRPmag\ndeg\tdeg\tmag\tmag\tmag\n---\t---\t---\t---\t---\n010.80894\t+41.00948\t 8.92\t 9.43\t 8.25\n010.60875\t+41.09671\t 9.48\t\t\n";
        var stars = ClearStar.Core.Astrometry.VizierGaiaCatalog.ParseTsv(tsv);
        Assert.Equal(2, stars.Count);
        Assert.InRange(stars[0].BpRp, 1.17f, 1.19f);
        Assert.True(float.IsNaN(stars[1].Bp));
        var pos = ClearStar.Core.Astrometry.NameResolver.Parse("# M31\n%J 10.68470833 +41.26875000 = 00 42 44.330  +41 16 07.50 \n");
        Assert.NotNull(pos);
        Assert.InRange(pos!.Value.dec, 41.268, 41.269);
        Assert.InRange(ClearStar.Core.Steps.PlateSolveStep.Sexagesimal("00 42 44.3", 15.0)!.Value, 10.684, 10.685);
        Assert.InRange(ClearStar.Core.Steps.PlateSolveStep.Sexagesimal("-05:23:28", 1.0)!.Value, -5.392, -5.391);
    }
}

public class OrientationTests
{
    [Fact]
    public void RotationAndMirrorMoveThePixelsAsExpected()
    {
        var img = new AstroImage(4, 3, 1);
        for (int y = 0; y < 3; y++) for (int x = 0; x < 4; x++) img[0, x, y] = y * 10 + x;
        var r90 = CropStep.Orient(img, 90, false, false);
        Assert.Equal(3, r90.Width); Assert.Equal(4, r90.Height);
        Assert.Equal(20f, r90[0, 0, 0]);     // bottom-left of the source becomes top-left
        Assert.Equal(0f, r90[0, 2, 0]);      // top-left of the source becomes top-right
        var r270 = CropStep.Orient(img, 270, false, false);
        Assert.Equal(3f, r270[0, 0, 0]);     // top-right of the source becomes top-left
        var r180 = CropStep.Orient(img, 180, false, false);
        Assert.Equal(23f, r180[0, 0, 0]);
        var fh = CropStep.Orient(img, 0, true, false);
        Assert.Equal(3f, fh[0, 0, 0]); Assert.Equal(0f, fh[0, 3, 0]);
        var fv = CropStep.Orient(img, 0, false, true);
        Assert.Equal(20f, fv[0, 0, 0]);
        Assert.Equal("NGC 6992", ClearStar.Core.IO.ObjectNameGuess.FromText("NGC6992_0905"));
        Assert.Equal("M 31", ClearStar.Core.IO.ObjectNameGuess.FromText("M31_0908"));
        Assert.Equal("Sh2-101", ClearStar.Core.IO.ObjectNameGuess.FromText("sh2-101 tulip"));
        Assert.Null(ClearStar.Core.IO.ObjectNameGuess.FromText("2026-09-18 session"));
    }
}

public class ColorCalibrationTests
{
    [Fact]
    public void FitRecoversFactorsFromSyntheticColours()
    {
        // Instrument: red channel 1.3× too strong, blue 0.8× too weak; colour dependence slope 0.9 / −0.5 mag per BP−RP.
        var rnd = new Random(5);
        var samples = new List<ClearStar.Core.Astrometry.ColorSample>();
        for (int i = 0; i < 80; i++)
        {
            float c = 0.2f + rnd.NextSingle() * 1.8f;
            float rg = -2.5f * MathF.Log10(1.3f) + 0.9f * (c - 0.82f) + (rnd.NextSingle() - 0.5f) * 0.04f;
            float bg = -2.5f * MathF.Log10(0.8f) - 0.5f * (c - 0.82f) + (rnd.NextSingle() - 0.5f) * 0.04f;
            samples.Add(new(c, rg, bg));
        }
        samples.Add(new(1.0f, 3f, -3f)); // an outlier (blended star) that must be rejected
        var fit = ClearStar.Core.Astrometry.ColorCalibration.Fit(samples, ClearStar.Core.Astrometry.ColorCalibration.GalaxyBpRp)!;
        Assert.InRange(fit.RedFactor, 1f / 1.3f - 0.03f, 1f / 1.3f + 0.03f);
        Assert.InRange(fit.BlueFactor, 1f / 0.8f - 0.04f, 1f / 0.8f + 0.04f);
        Assert.True(fit.StarsUsed >= 70);
    }

    [Fact]
    public void ApplyNeutralisesBackgroundAndScalesSignal()
    {
        var img = new AstroImage(64, 64, 3);
        var rnd = new Random(2);
        for (int c = 0; c < 3; c++)
        {
            float bg = c == 0 ? 0.12f : c == 1 ? 0.10f : 0.09f;
            for (int i = 0; i < img.PixelsPerChannel; i++) img.Data[c * img.PixelsPerChannel + i] = bg + (rnd.NextSingle() - 0.5f) * 0.002f;
        }
        img[0, 10, 10] = 0.5f; img[1, 10, 10] = 0.5f; img[2, 10, 10] = 0.5f;
        var outp = ClearStar.Core.Astrometry.ColorCalibration.Apply(img, 0.8f, 1.25f, true);
        var s = ImageStats.ComputeAll(outp);
        Assert.InRange(s[0].Median, 0.099f, 0.101f);
        Assert.InRange(s[2].Median, 0.099f, 0.101f);
        Assert.InRange(outp[0, 10, 10], 0.10f + 0.38f * 0.8f - 0.01f, 0.10f + 0.38f * 0.8f + 0.01f);
        Assert.InRange(outp[2, 10, 10], 0.10f + 0.41f * 1.25f - 0.01f, 0.10f + 0.41f * 1.25f + 0.01f);
    }
}

public class StarLayerTests
{
    [Fact]
    public void StoreOnlyMatchesTheImageItWasMadeFor()
    {
        var starless = new AstroImage(64, 64, 1); Array.Fill(starless.Data, 0.1f);
        var stars = new AstroImage(64, 64, 1);
        StarLayerStore.SetLinear(starless, stars);
        Assert.True(StarLayerStore.HasStarsFor(starless.Clone()));
        var other = starless.Clone(); for (int i = 0; i < other.Data.Length; i++) other.Data[i] += 0.01f;
        Assert.False(StarLayerStore.HasStarsFor(other));
        StarLayerStore.Clear();
        Assert.False(StarLayerStore.HasStarsFor(starless));
    }

    [Fact]
    public void ScreenBlendNeverClipsAndKeepsBackground()
    {
        var a = new AstroImage(8, 8, 3); Array.Fill(a.Data, 0.2f);
        var b = new AstroImage(8, 8, 3); b[0, 1, 1] = 1f; b[1, 1, 1] = 0.5f;
        var s = RecombineStep.Screen(a, b, 1f, default);
        Assert.Equal(0.2f, s[0, 0, 0], 3);
        Assert.Equal(1f, s[0, 1, 1], 3);
        Assert.Equal(0.6f, s[1, 1, 1], 3);
    }

    [Fact]
    public void StarNetRemovesSyntheticStarsIfInstalled()
    {
        string? exe = ClearStar.Core.AI.StarNet.Locate();
        if (exe is null) return; // StarNet2 is the user's own program – nothing to verify without it
        var rnd = new Random(4);
        var img = new AstroImage(600, 560, 3);
        for (int i = 0; i < img.Data.Length; i++) img.Data[i] = 0.02f + (rnd.NextSingle() - 0.5f) * 0.002f;
        var centres = new List<(int x, int y)>();
        for (int s = 0; s < 40; s++)
        {
            int cx = 30 + rnd.Next(540), cy = 30 + rnd.Next(500); centres.Add((cx, cy));
            float amp = 0.05f + rnd.NextSingle() * 0.4f;
            for (int c = 0; c < 3; c++) for (int y = -8; y <= 8; y++) for (int x = -8; x <= 8; x++)
                img[c, cx + x, cy + y] += amp * MathF.Exp(-(x * x + y * y) / (2 * 1.8f * 1.8f));
        }
        var (starless, stars) = ClearStar.Core.AI.StarNet.RemoveStarsLinear(img, exe);
        Assert.Equal(img.Width, starless.Width);
        float peakBefore = centres.Average(p => img[1, p.x, p.y]), peakAfter = centres.Average(p => starless[1, p.x, p.y]);
        Assert.True(peakAfter < 0.25f * peakBefore, $"stars not removed: {peakBefore} -> {peakAfter}");
        Assert.InRange(ImageStats.Compute(starless.Channel(1).ToArray()).Median, 0.018f, 0.022f);
        Assert.True(stars[1, centres[0].x, centres[0].y] > 0.03f);
    }
}

public class LocalCatalogTests
{
    [Fact]
    public void HealpixPixelCentresCoverTheSphereEvenly()
    {
        var h = ClearStar.Core.Astrometry.Healpix.ForOrder(3); // 768 pixels
        Assert.Equal(768, h.Npix);
        var (z0, phi0) = h.PixToZPhi(0);
        Assert.InRange(z0, 0.0, 0.2); Assert.InRange(phi0, 0.7, 0.9); // NESTED pixel 0 is the southern corner of face 0, on the equator side
        // A 30° cone at the pole must be covered by pixels of both caps and equator rows, none from the south.
        var pix = h.QueryDiscInclusive(0, 90, 30);
        Assert.InRange(pix.Count, 40, 140);
        Assert.All(pix, p => Assert.True(h.PixToZPhi(p).z > 0.3));
        Assert.InRange(ClearStar.Core.Astrometry.LocalGaiaCatalog.BpRpFromTeff(5770), 0.81f, 0.83f);
        Assert.InRange(ClearStar.Core.Astrometry.LocalGaiaCatalog.BpRpFromTeff(9700), -0.01f, 0.01f);
    }

    [Fact]
    public void OfflineCatalogueAgreesWithOnlineCacheIfPresent()
    {
        var local = ClearStar.Core.Astrometry.LocalGaiaCatalog.Default();
        if (local is null) return; // no Siril catalogue on this machine
        var stars = local.Cone(10.68470833, 41.26875, 0.3, 12f, 4000);
        Assert.InRange(stars.Count, 15, 200);
        // Brightest star in the M31 cone below G=12 is at RA 10.809, Dec 41.009 (G=8.92) in Gaia DR3.
        var brightest = stars[0];
        Assert.InRange(brightest.G, 8.8f, 9.0f);
        Assert.InRange(brightest.Ra, 10.805, 10.813);
        Assert.InRange(brightest.Dec, 41.005, 41.013);
        Assert.All(stars, s => Assert.True(s.G <= 12f));
    }
}

public class FineRotationTests
{
    [Fact]
    public void ArbitraryAngleRotationKeepsTheCentreAndMatchesTheCanvasSize()
    {
        var img = new AstroImage(200, 120, 1);
        Array.Fill(img.Data, 0.2f);
        img[0, 100, 60] = 1f; img[0, 20, 60] = 0.9f; // centre and a point left of it
        var r = CropStep.Orient(img, 10, false, false);
        var (w, h) = CropStep.OrientedSize(200, 120, 10);
        Assert.Equal(w, r.Width); Assert.Equal(h, r.Height);
        int cx = (r.Width - 1) / 2, cy = (r.Height - 1) / 2;
        float centreMax = 0; for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) centreMax = Math.Max(centreMax, r[0, cx + x, cy + y]);
        Assert.True(centreMax > 0.5f);
        // Clockwise by 10°: a point to the left of the centre moves up (smaller y) on screen.
        double a = 10 * Math.PI / 180; int px = (int)Math.Round(cx - 80 * Math.Cos(a)), py = (int)Math.Round(cy - 80 * Math.Sin(a));
        float leftMax = 0; for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) leftMax = Math.Max(leftMax, r[0, px + x, py + y]);
        Assert.True(leftMax > 0.5f, $"rotated point not found near ({px},{py})");
        Assert.Equal(0f, r[0, 0, 0]); // empty corner
    }
}

public class StarNetChannelOrderTests
{
    [Fact]
    public void ChannelOrderIsPreservedThroughStarNet()
    {
        string? exe = ClearStar.Core.AI.StarNet.Locate();
        if (exe is null) return;
        var img = new AstroImage(600, 560, 3);
        var rnd = new Random(1);
        for (int c = 0; c < 3; c++) { float level = 0.2f + 0.2f * c; for (int i = 0; i < img.PixelsPerChannel; i++) img.Data[c * img.PixelsPerChannel + i] = level + (rnd.NextSingle() - 0.5f) * 0.01f; }
        var outp = ClearStar.Core.AI.StarNet.RemoveStars(img, exe);
        var m = Enumerable.Range(0, 3).Select(c => ImageStats.Compute(outp.Channel(c).ToArray()).Median).ToArray();
        // StarNet2 writes BGR planes; the runner must swap them back so red stays red.
        Assert.InRange(m[0], 0.18f, 0.22f); Assert.InRange(m[1], 0.38f, 0.42f); Assert.InRange(m[2], 0.58f, 0.62f);
    }
}
