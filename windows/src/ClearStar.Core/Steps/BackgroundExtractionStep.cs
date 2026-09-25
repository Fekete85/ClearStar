using ClearStar.Core.AI;
using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// 4. lépés: háttér kiegyenlítése. Alapértelmezetten a GraXpert AI-modelljével (ONNX): a háló egy
/// kicsinyített képből becsüli a háttér-gradienst, amit kivonunk. Tartalék módszer: rácsos mintavétel
/// és polinom-illesztés (a túl fényes cellák – köd, galaxis, csillag – kizárásával).
/// </summary>
public sealed class BackgroundExtractionStep : StepBase
{
    public const string MethodKey = "method";
    public const string ModelKey = "model";
    public const string StrengthKey = "strength";
    public const string SmoothingKey = "smoothing";
    public const string GridKey = "grid";
    public const string CorrectionKey = "correction";

    private const string S = "bge";

    // Nyelvfüggetlen választóértékek (feliratuk: step.bge.method.* és step.bge.correction.*).
    public const string MethodAi = "ai";
    public const string MethodPolynomial = "polynomial";
    public const string CorrectionSubtract = "subtract";
    public const string CorrectionDivide = "divide";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.BackgroundExtraction, StepGroup.Basics, S,
        [
            Slider(S, SmoothingKey, 0.2),
            Choice(S, MethodKey, MethodAi, [MethodAi, MethodPolynomial], advanced: true),
            Model(S, ModelKey, nameof(AiModelKind.BackgroundExtraction), advanced: true),
            Slider(S, StrengthKey, 0.5, advanced: true),
            Slider(S, GridKey, 0.5, advanced: true),
            Choice(S, CorrectionKey, CorrectionSubtract, [CorrectionSubtract, CorrectionDivide], advanced: true),
        ]);

    public override Task<StepResult> RunAsync(WorkflowContext context) => Task.Run(() => Run(context), context.CancellationToken);

    /// <summary>A mintavételi pontok (normált 0..1 koordináták), hogy a felület ki tudja rajzolni őket.</summary>
    public static List<(float x, float y)> LastSamplePoints { get; private set; } = [];

    private static StepResult Run(WorkflowContext context)
    {
        var input = context.RequireInput();
        var ct = context.CancellationToken;
        var p = context.Parameters;
        float strength = p.GetFloat(StrengthKey, 0.5f);
        float smoothing = p.GetFloat(SmoothingKey, 0.2f);
        float grid = p.GetFloat(GridKey, 0.5f);

        if (p.GetString(MethodKey, MethodAi) == MethodAi)
        {
            string modelPath = p.GetString(ModelKey).Trim();
            AiModelInfo? model = modelPath.Length > 0 && File.Exists(modelPath)
                ? new AiModelInfo(AiModelKind.BackgroundExtraction, Path.GetFileName(Path.GetDirectoryName(modelPath) ?? ""), modelPath, L.T("msg.bge.selectedSource"))
                : AiModelStore.Resolve(AiModelKind.BackgroundExtraction);
            if (model is null)
                throw new InvalidOperationException(L.T("msg.bge.noModel"));

            context.Report(0.1, L.T("msg.bge.estimating"));
            var background = BackgroundModel.EstimateBackground(input, model.Path, smoothing * 0.5f, ct);
            context.Report(0.8, L.T("msg.bge.subtracting"));
            bool divide = p.GetString(CorrectionKey, CorrectionSubtract) == CorrectionDivide;
            var corrected = divide ? BackgroundModel.Divide(input, background) : BackgroundModel.Subtract(input, background);
            LastSamplePoints = [];
            return new StepResult(corrected, L.F("msg.bge.summaryAi", model.Version, model.Source) + L.T(OnnxSessions.LastProvider == "GPU" ? "msg.ai.gpu" : "msg.ai.cpu"));
        }

        // Gyenge: a modellnél 1σ-val fényesebb cella már "objektum"; Erős: 3σ-ig még háttér.
        float tolerance = Lerp(1f, 3f, strength);
        int degree = smoothing < 0.34f ? 4 : smoothing < 0.67f ? 2 : 1;
        int columns = (int)Math.Round(Lerp(16, 48, grid));
        var output = input.CreateEmptyLike();
        var (points, usedDegree) = Flatten(input, output, degree, tolerance, columns, ct, (f, m) => context.Report(f, m));
        LastSamplePoints = points;
        output.Clamp01();
        return new StepResult(output, L.F("msg.bge.summaryPoly", points.Count, DegreeName(usedDegree)));
    }

    /// <summary>
    /// Háttérmodell illesztése és kivonása csatornánként. Az output lehet maga az input is (helyben).
    /// A stackelés is ezt használja képenként (sík modell), mint a Siril seqsubsky-ja.
    /// </summary>
    public static (List<(float x, float y)> points, int degree) Flatten(AstroImage input, AstroImage output, int degree, float tolerance, int columns, CancellationToken ct, Action<double, string>? report = null)
    {
        int rows = Math.Max(4, (int)Math.Round(columns * input.Height / (double)input.Width));
        var points = new List<(float x, float y)>();
        for (int c = 0; c < input.Channels; c++)
        {
            ct.ThrowIfCancellationRequested();
            report?.Invoke(c / (double)input.Channels, L.T("msg.bge.collecting"));
            var samples = CollectSamples(input, c, columns, rows);

            report?.Invoke((c + 0.5) / input.Channels, L.T("msg.bge.fitting"));
            var coeffs = FitWithRejection(samples, ref degree, tolerance, out var accepted);
            if (c == 0) points = accepted.Select(s => ((float)((s.x + 1) / 2), (float)((s.y + 1) / 2))).ToList();
            SubtractModel(input, output, c, coeffs, degree, ct);
        }
        return (points, degree);
    }

    private static string DegreeName(int d) => L.T(d switch { 1 => "msg.bge.degree1", 2 => "msg.bge.degree2", _ => "msg.bge.degreeN" });

    /// <summary>Cellamediánok normált (-1..1) koordinátákkal.</summary>
    private static List<(double x, double y, double v)> CollectSamples(AstroImage img, int c, int columns, int rows)
    {
        int tileW = img.Width / columns, tileH = img.Height / rows;
        int perTile = Math.Min(tileW * tileH, 1024);
        int stride = Math.Max(1, tileW * tileH / perTile);
        var medians = new float[columns * rows];
        var data = img.Data;
        int offset = c * img.PixelsPerChannel, width = img.Width;

        // Cellasoronként párhuzamosan: minden cella mediánja független. A 0 értékű (adat nélküli,
        // pl. az elforgatott képek sarkaiból származó) pixelek nem számítanak háttérnek.
        Parallel.For(0, rows, ty =>
        {
            var buffer = new float[perTile];
            for (int tx = 0; tx < columns; tx++)
            {
                int x0 = tx * tileW, y0 = ty * tileH, n = 0, total = 0;
                for (int k = 0; k < tileW * tileH && total < perTile; k += stride, total++)
                {
                    float v = data[offset + (y0 + k / tileW) * width + x0 + k % tileW];
                    if (v > 0f) buffer[n++] = v;
                }
                if (n < total / 2) { medians[ty * columns + tx] = float.NaN; continue; }
                Array.Sort(buffer, 0, n);
                medians[ty * columns + tx] = n % 2 == 1 ? buffer[n / 2] : 0.5f * (buffer[n / 2 - 1] + buffer[n / 2]);
            }
        });

        var samples = new List<(double, double, double)>(columns * rows);
        for (int ty = 0; ty < rows; ty++)
        for (int tx = 0; tx < columns; tx++)
        {
            float m = medians[ty * columns + tx];
            if (float.IsNaN(m)) continue;
            samples.Add(((tx * tileW + tileW / 2.0) / img.Width * 2 - 1, (ty * tileH + tileH / 2.0) / img.Height * 2 - 1, m));
        }
        return samples;
    }

    /// <summary>
    /// Iteratív illesztés: először síkot illesztünk, majd a modellnél a reziduálok szórásához képest
    /// túl fényes cellákat (köd, galaxis, csillag) kidobjuk, és a maradékra illesztjük a végleges fokot.
    /// Csak a pozitív (fényes) eltérést büntetjük – a sötét cellák valódi hátteret jelentenek.
    /// </summary>
    private static double[] FitWithRejection(List<(double x, double y, double v)> all, ref int degree, float tolerance, out List<(double x, double y, double v)> accepted)
    {
        accepted = all;
        double[] coeffs = FitPolynomial(accepted, 1);
        int fitDegree = 1;
        Span<double> scratch = stackalloc double[PolyTerms(MaxDegree)];   // basis terms, sized once for the largest degree
        for (int iter = 0; iter < 4; iter++)
        {
            int n = PolyTerms(fitDegree);
            var residuals = new double[all.Count];
            var t = scratch[..n];
            for (int i = 0; i < all.Count; i++)
            {
                Basis(all[i].x, all[i].y, fitDegree, t);
                double m = 0; for (int k = 0; k < n; k++) m += coeffs[k] * t[k];
                residuals[i] = all[i].v - m;
            }
            var abs = residuals.Select(Math.Abs).ToArray();
            double sigma = 1.4826 * ImageStats.Median(abs.Select(a => (float)a).ToArray());
            double limit = tolerance * Math.Max(sigma, 1e-6);
            var kept = new List<(double, double, double)>(all.Count);
            for (int i = 0; i < all.Count; i++) if (residuals[i] <= limit) kept.Add(all[i]);
            int nextDegree = iter >= 1 ? degree : 1;
            if (kept.Count < PolyTerms(nextDegree) + 3) nextDegree = 1;
            if (kept.Count < 6) break;
            accepted = kept;
            fitDegree = nextDegree;
            coeffs = FitPolynomial(accepted, fitDegree);
        }
        degree = fitDegree;
        return coeffs;
    }

    /// <summary>Highest polynomial degree the basis supports (15 terms).</summary>
    private const int MaxDegree = 4;
    private static int PolyTerms(int degree) => (degree + 1) * (degree + 2) / 2;

    private static void Basis(double x, double y, int degree, Span<double> outTerms)
    {
        // Hatványok ismételt szorzással (pixelenként hívjuk, a Math.Pow túl lassú lenne).
        Span<double> xp = stackalloc double[5];
        Span<double> yp = stackalloc double[5];
        xp[0] = 1; yp[0] = 1;
        for (int i = 1; i <= degree; i++) { xp[i] = xp[i - 1] * x; yp[i] = yp[i - 1] * y; }
        int k = 0;
        for (int d = 0; d <= degree; d++)
            for (int i = 0; i <= d; i++)
                outTerms[k++] = xp[d - i] * yp[i];
    }

    /// <summary>Legkisebb négyzetes illesztés a normálegyenletekkel (a tagok száma legfeljebb 15).</summary>
    private static double[] FitPolynomial(List<(double x, double y, double v)> samples, int degree)
    {
        int n = PolyTerms(degree);
        var ata = new double[n, n];
        var atb = new double[n];
        Span<double> t = stackalloc double[n];
        foreach (var (x, y, v) in samples)
        {
            Basis(x, y, degree, t);
            for (int i = 0; i < n; i++)
            {
                atb[i] += t[i] * v;
                for (int j = 0; j < n; j++) ata[i, j] += t[i] * t[j];
            }
        }
        // Enyhe regularizáció a numerikus stabilitásért.
        for (int i = 0; i < n; i++) ata[i, i] += 1e-9;
        return SolveGauss(ata, atb, n);
    }

    private static double[] SolveGauss(double[,] a, double[] b, int n)
    {
        for (int col = 0; col < n; col++)
        {
            int pivot = col;
            for (int r = col + 1; r < n; r++) if (Math.Abs(a[r, col]) > Math.Abs(a[pivot, col])) pivot = r;
            if (pivot != col)
            {
                for (int k = 0; k < n; k++) (a[col, k], a[pivot, k]) = (a[pivot, k], a[col, k]);
                (b[col], b[pivot]) = (b[pivot], b[col]);
            }
            double p = a[col, col];
            if (Math.Abs(p) < 1e-14) continue;
            for (int r = col + 1; r < n; r++)
            {
                double f = a[r, col] / p;
                if (f == 0) continue;
                for (int k = col; k < n; k++) a[r, k] -= f * a[col, k];
                b[r] -= f * b[col];
            }
        }
        var x = new double[n];
        for (int r = n - 1; r >= 0; r--)
        {
            double s = b[r];
            for (int k = r + 1; k < n; k++) s -= a[r, k] * x[k];
            x[r] = Math.Abs(a[r, r]) < 1e-14 ? 0 : s / a[r, r];
        }
        return x;
    }

    private static void SubtractModel(AstroImage input, AstroImage output, int c, double[] coeffs, int degree, CancellationToken ct)
    {
        int w = input.Width, h = input.Height, n = PolyTerms(degree);
        int offset = c * input.PixelsPerChannel;
        // A modell átlagát visszaadjuk, hogy a háttér ne 0-ra, hanem egy természetes sötét szintre kerüljön.
        double modelMean = 0;
        {
            Span<double> t = stackalloc double[n];
            int cnt = 0;
            for (int y = 0; y < h; y += Math.Max(1, h / 64))
            for (int x = 0; x < w; x += Math.Max(1, w / 64))
            {
                Basis(x / (double)w * 2 - 1, y / (double)h * 2 - 1, degree, t);
                double m = 0; for (int i = 0; i < n; i++) m += coeffs[i] * t[i];
                modelMean += m; cnt++;
            }
            modelMean /= Math.Max(cnt, 1);
        }
        float pedestal = (float)modelMean;

        // Soronként a modellt x-polinommá hajtjuk össze: m(x) = Σ_j a_j(y)·x^j, a_j(y) = Σ_i c_{j,i}·y^i,
        // így pixelenként csak egy Horner-kiértékelés marad (a pow/stackalloc pixelenként túl lassú volt).
        Parallel.For(0, h, new ParallelOptions { CancellationToken = ct }, y =>
        {
            double ny = y / (double)h * 2 - 1;
            Span<double> yp = stackalloc double[5];
            Span<double> a = stackalloc double[5];
            yp[0] = 1; for (int i = 1; i <= degree; i++) yp[i] = yp[i - 1] * ny;
            a.Clear();
            int k = 0;
            for (int d = 0; d <= degree; d++)
                for (int i = 0; i <= d; i++)
                    a[d - i] += coeffs[k++] * yp[i];   // x^(d-i) · y^i

            var src = input.Data; var dst = output.Data;
            double sx = 2.0 / w;
            int row = offset + y * w;
            for (int x = 0; x < w; x++)
            {
                double nx = x * sx - 1;
                double m = a[degree];
                for (int j = degree - 1; j >= 0; j--) m = m * nx + a[j];
                dst[row + x] = src[row + x] - (float)m + pedestal;
            }
        });
    }
}
