using System.Globalization;
using System.Text.Json;

namespace ClearStar.Core.Imaging;

/// <summary>
/// Stretch types: Siril's five, <see cref="Mtf"/> for the auto-stretch (wand) and <see cref="Simple"/>
/// for the beginner sliders (object brightness, background level, contrast around the background).
/// </summary>
public enum GhsType { Ghs, InverseGhs, Asinh, InverseAsinh, Linear, Mtf, Simple }
public enum GhsColourModel { Independent, HumanLuminance, EvenLuminance }

/// <summary>
/// One generalised hyperbolic stretch, with Siril's parameter set: stretch factor D (the UI shows
/// ln(D+1)), local intensity b, symmetry point SP, shadow/highlight protection points LP/HP, black
/// point BP (linear type only) and the colour model.
/// </summary>
public sealed record GhsParams(GhsType Type, float D, float B, float LP, float SP, float HP, float BP, GhsColourModel Colour,
    float[]? ChannelMidtones = null, float[]? ChannelShadows = null)
{
    public static readonly GhsParams Identity = new(GhsType.Ghs, 0f, 0f, 0f, 0f, 1f, 0f, GhsColourModel.Independent);

    /// <summary>ln(D+1) → D.</summary>
    public static float DFromLog(double lnD1) => (float)(Math.Exp(lnD1) - 1.0);
    /// <summary>
    /// For <see cref="GhsType.Mtf"/> (auto stretch) D holds the midtones balance and SP the shadow clipping point.
    /// For <see cref="GhsType.Simple"/> D, BP and B are the three sliders in −1…1 (objects, background, contrast) and SP the background level they pivot on.
    /// </summary>
    public bool IsIdentity => Type switch
    {
        GhsType.Linear => BP <= 0f,
        GhsType.Mtf => false,
        GhsType.Simple => MathF.Abs(D) < 1e-4f && MathF.Abs(BP) < 1e-4f && MathF.Abs(B) < 1e-4f,
        _ => D <= 0f,
    };

    /// <summary>The beginner stretch: <paramref name="objects"/>, <paramref name="background"/> and <paramref name="contrast"/> in −1…1 around the background level <paramref name="pivot"/>.</summary>
    public static GhsParams SimpleStretch(float objects, float background, float contrast, float pivot) =>
        new(GhsType.Simple, Math.Clamp(objects, -1f, 1f), Math.Clamp(contrast, -1f, 1f), 0f, Math.Clamp(pivot, 0f, 1f), 1f, Math.Clamp(background, -1f, 1f), GhsColourModel.Independent);

    public string ToJson() => JsonSerializer.Serialize(this);
    public static GhsParams? FromJson(string json)
    {
        try { return JsonSerializer.Deserialize<GhsParams>(json); } catch (JsonException) { return null; }
    }

    public static string ListToJson(IEnumerable<GhsParams> list) => JsonSerializer.Serialize(list.ToArray());
    public static List<GhsParams> ListFromJson(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try { return JsonSerializer.Deserialize<List<GhsParams>>(json) ?? []; } catch (JsonException) { return []; }
    }

    public string Describe() => Type switch
    {
        GhsType.Linear => string.Format(CultureInfo.CurrentCulture, "BP {0:0.000}", BP),
        GhsType.Mtf => string.Format(CultureInfo.CurrentCulture, "auto (MTF m={0:0.000}, shadows {1:0.000})", D, SP),
        GhsType.Simple => Localization.L.F("msg.ghs.simple", D, BP, B),
        _ => string.Format(CultureInfo.CurrentCulture, "ln(D+1) {0:0.00}, b {1:0.0}, SP {2:0.000}", Math.Log(D + 1), B, SP),
    };
}

/// <summary>
/// The stretch transform itself – a port of Siril's GHT (ght.c): piecewise definitions below LP,
/// between LP and SP, between SP and HP and above HP, for the hyperbolic, inverse hyperbolic,
/// modified-arcsinh, inverse arcsinh and linear types.
/// </summary>
public sealed class GhsTransform
{
    private readonly GhsParams _p;
    private float qlp, q0, qwp, q1, q, a1, b1, a2, b2, c2, d2, e2, a3, b3, c3, d3, e3, a4, b4, LPT, SPT, HPT;
    private readonly int _bcat; // 0: B == -1 (log), 1: B == 0 (exp), 2: other (pow)

    public GhsTransform(GhsParams p)
    {
        _p = p;
        float B = p.B, D = p.D, LP = p.LP, SP = p.SP, HP = p.HP;
        // b = −1 has its own (log) formulas in Siril whose LP branch is not continuous; the general
        // power form a hair away from −1 is indistinguishable and well behaved.
        if (B == -1f) B = -1.0001f;
        _bcat = B == -1f ? 0 : B == 0f ? 1 : 2;
        if (p.Type == GhsType.Simple) { SetupSimple(p); return; }
        if (D == 0f || p.Type == GhsType.Linear) return;
        Setup(B, D, LP, SP, HP, p.Type);
    }

    // ----- Simple (beginner) stretch -----
    // Three effects composed around the background level (pivot):
    //  * background: moves the pivot up or down (a black-point shift with the shadows scaled linearly),
    //  * objects: an MTF on the range above the pivot – brightens or darkens everything that is not sky,
    //  * contrast: a hyperbolic stretch centred on the new pivot, re-pivoted so the background stays put.
    private const float BackgroundRange = 0.12f;   // full slider throw moves the background by this much
    private const float ObjectsRange = 0.35f;      // midtones 0.5 ± this
    private const float ContrastLnD = 1.5f;        // ln(D+1) of the contrast GHS at full throw
    private float sBg, sBg2, sM, sYsp, sLo, sHi;
    private GhsTransform? sContrast;

    private void SetupSimple(GhsParams p)
    {
        sBg = Math.Clamp(p.SP, 0.005f, 0.9f);
        sBg2 = Math.Clamp(sBg + BackgroundRange * p.BP, 0.001f, 0.9f);
        sM = Math.Clamp(0.5f - ObjectsRange * p.D, 0.15f, 0.85f);
        if (MathF.Abs(p.B) < 1e-4f) return;
        var g = new GhsParams(p.B > 0f ? GhsType.Ghs : GhsType.InverseGhs, GhsParams.DFromLog(ContrastLnD * MathF.Abs(p.B)), 1f, 0f, sBg2, 1f, 0f, GhsColourModel.Independent);
        sContrast = new GhsTransform(g);
        sYsp = sContrast.Apply(sBg2);
        sLo = sBg2 / MathF.Max(sYsp, 1e-6f);
        sHi = (1f - sBg2) / MathF.Max(1f - sYsp, 1e-6f);
    }

    private float ApplySimple(float x)
    {
        float y;
        if (x < sBg) y = sBg2 * (x / sBg);
        else y = sBg2 + (1f - sBg2) * DisplayStretch.Mtf((x - sBg) / (1f - sBg), sM);
        if (sContrast is null) return y;
        float z = sContrast.Apply(y);
        return z <= sYsp ? z * sLo : 1f - (1f - z) * sHi;
    }

    private void Setup(float B, float D, float LP, float SP, float HP, GhsType type)
    {
        switch (type)
        {
            case GhsType.Ghs:
                if (B == -1f)
                {
                    qlp = -MathF.Log(1f + D * (SP - LP));
                    q0 = qlp - D * LP / (1f + D * (SP - LP));
                    qwp = MathF.Log(1f + D * (HP - SP));
                    q1 = qwp + D * (1f - HP) / (1f + D * (HP - SP));
                    q = 1f / (q1 - q0);
                    b1 = (1f + D * (SP - LP)) / (D * q);
                    a2 = -q0 * q; b2 = -q; c2 = 1f + D * SP; d2 = -D;
                    a3 = -q0 * q; b3 = q; c3 = 1f - D * SP; d3 = D;
                    a4 = (qwp - q0 - D * HP / (1f + D * (HP - SP))) * q;
                    b4 = q * D / (1f + D * (HP - SP));
                }
                else if (B < 0f)
                {
                    B = -B;
                    qlp = (1f - MathF.Pow(1f + D * B * (SP - LP), (B - 1f) / B)) / (B - 1f);
                    q0 = qlp - D * LP * MathF.Pow(1f + D * B * (SP - LP), -1f / B);
                    qwp = (MathF.Pow(1f + D * B * (HP - SP), (B - 1f) / B) - 1f) / (B - 1f);
                    q1 = qwp + D * (1f - HP) * MathF.Pow(1f + D * B * (HP - SP), -1f / B);
                    q = 1f / (q1 - q0);
                    b1 = D * MathF.Pow(1f + D * B * (SP - LP), -1f / B) * q;
                    a2 = (1f / (B - 1f) - q0) * q; b2 = -q / (B - 1f); c2 = 1f + D * B * SP; d2 = -D * B; e2 = (B - 1f) / B;
                    a3 = (-1f / (B - 1f) - q0) * q; b3 = q / (B - 1f); c3 = 1f - D * B * SP; d3 = D * B; e3 = (B - 1f) / B;
                    a4 = (qwp - q0 - D * HP * MathF.Pow(1f + D * B * (HP - SP), -1f / B)) * q;
                    b4 = D * MathF.Pow(1f + D * B * (HP - SP), -1f / B) * q;
                }
                else if (B == 0f)
                {
                    qlp = MathF.Exp(-D * (SP - LP));
                    q0 = qlp - D * LP * MathF.Exp(-D * (SP - LP));
                    qwp = 2f - MathF.Exp(-D * (HP - SP));
                    q1 = qwp + D * (1f - HP) * MathF.Exp(-D * (HP - SP));
                    q = 1f / (q1 - q0);
                    a1 = 0f; b1 = D * MathF.Exp(-D * (SP - LP)) * q;
                    a2 = -q0 * q; b2 = q; c2 = -D * SP; d2 = D;
                    a3 = (2f - q0) * q; b3 = -q; c3 = D * SP; d3 = -D;
                    a4 = (qwp - q0 - D * HP * MathF.Exp(-D * (HP - SP))) * q;
                    b4 = D * MathF.Exp(-D * (HP - SP)) * q;
                }
                else
                {
                    qlp = MathF.Pow(1f + D * B * (SP - LP), -1f / B);
                    q0 = qlp - D * LP * MathF.Pow(1f + D * B * (SP - LP), -(1f + B) / B);
                    qwp = 2f - MathF.Pow(1f + D * B * (HP - SP), -1f / B);
                    q1 = qwp + D * (1f - HP) * MathF.Pow(1f + D * B * (HP - SP), -(1f + B) / B);
                    q = 1f / (q1 - q0);
                    b1 = D * MathF.Pow(1f + D * B * (SP - LP), -(1f + B) / B) * q;
                    a2 = -q0 * q; b2 = q; c2 = 1f + D * B * SP; d2 = -D * B; e2 = -1f / B;
                    a3 = (2f - q0) * q; b3 = -q; c3 = 1f - D * B * SP; d3 = D * B; e3 = -1f / B;
                    a4 = (qwp - q0 - D * HP * MathF.Pow(1f + D * B * (HP - SP), -(B + 1f) / B)) * q;
                    b4 = D * MathF.Pow(1f + D * B * (HP - SP), -(B + 1f) / B) * q;
                }
                break;

            case GhsType.InverseGhs:
                if (B == -1f)
                {
                    qlp = -MathF.Log(1f + D * (SP - LP));
                    q0 = qlp - D * LP / (1f + D * (SP - LP));
                    qwp = MathF.Log(1f + D * (HP - SP));
                    q1 = qwp + D * (1f - HP) / (1f + D * (HP - SP));
                    q = 1f / (q1 - q0);
                    LPT = (qlp - q0) * q; SPT = q0 * q; HPT = (qwp - q0) * q;
                    b1 = (1f + D * (SP - LP)) / (D * q);
                    a2 = (1f + D * SP) / D; b2 = -1f / D; c2 = -q0; d2 = -1f / q;
                    a3 = -(1f - D * SP) / D; b3 = 1f / D; c3 = q0; d3 = 1f / q;
                    a4 = HP + (q0 - qwp) * (1f + D * (HP - SP)) / D;
                    b4 = (1f + D * (HP - SP)) / (q * D);
                }
                else if (B < 0f)
                {
                    B = -B;
                    qlp = (1f - MathF.Pow(1f + D * B * (SP - LP), (B - 1f) / B)) / (B - 1f);
                    q0 = qlp - D * LP * MathF.Pow(1f + D * B * (SP - LP), -1f / B);
                    qwp = (MathF.Pow(1f + D * B * (HP - SP), (B - 1f) / B) - 1f) / (B - 1f);
                    q1 = qwp + D * (1f - HP) * MathF.Pow(1f + D * B * (HP - SP), -1f / B);
                    q = 1f / (q1 - q0);
                    LPT = (qlp - q0) * q; SPT = -q0 * q; HPT = (qwp - q0) * q;
                    b1 = MathF.Pow(1f + D * B * (SP - LP), 1f / B) / (q * D);
                    a2 = (1f + D * B * SP) / (D * B); b2 = -1f / (D * B); c2 = -q0 * (B - 1f) + 1f; d2 = (1f - B) / q; e2 = B / (B - 1f);
                    a3 = (D * B * SP - 1f) / (D * B); b3 = 1f / (D * B); c3 = 1f + q0 * (B - 1f); d3 = (B - 1f) / q; e3 = B / (B - 1f);
                    a4 = (q0 - qwp) / (D * MathF.Pow(1f + D * B * (HP - SP), -1f / B)) + HP;
                    b4 = 1f / (D * MathF.Pow(1f + D * B * (HP - SP), -1f / B) * q);
                }
                else if (B == 0f)
                {
                    qlp = MathF.Exp(-D * (SP - LP));
                    q0 = qlp - D * LP * MathF.Exp(-D * (SP - LP));
                    qwp = 2f - MathF.Exp(-D * (HP - SP));
                    q1 = qwp + D * (1f - HP) * MathF.Exp(-D * (HP - SP));
                    q = 1f / (q1 - q0);
                    LPT = (qlp - q0) * q; SPT = (1f - q0) * q; HPT = (qwp - q0) * q;
                    a1 = 0f; b1 = 1f / (D * MathF.Exp(-D * (SP - LP)) * q);
                    a2 = SP; b2 = 1f / D; c2 = q0; d2 = 1f / q;
                    a3 = SP; b3 = -1f / D; c3 = 2f - q0; d3 = -1f / q;
                    a4 = (q0 - qwp) / (D * MathF.Exp(-D * (HP - SP))) + HP;
                    b4 = 1f / (D * MathF.Exp(-D * (HP - SP)) * q);
                }
                else
                {
                    qlp = MathF.Pow(1f + D * B * (SP - LP), -1f / B);
                    q0 = qlp - D * LP * MathF.Pow(1f + D * B * (SP - LP), -(1f + B) / B);
                    qwp = 2f - MathF.Pow(1f + D * B * (HP - SP), -1f / B);
                    q1 = qwp + D * (1f - HP) * MathF.Pow(1f + D * B * (HP - SP), -(1f + B) / B);
                    q = 1f / (q1 - q0);
                    LPT = (qlp - q0) * q; SPT = (1f - q0) * q; HPT = (qwp - q0) * q;
                    b1 = 1f / (D * MathF.Pow(1f + D * B * (SP - LP), -(1f + B) / B) * q);
                    a2 = 1f / (D * B) + SP; b2 = -1f / (D * B); c2 = q0; d2 = 1f / q; e2 = -B;
                    a3 = -1f / (D * B) + SP; b3 = 1f / (D * B); c3 = 2f - q0; d3 = -1f / q; e3 = -B;
                    a4 = (q0 - qwp) / (D * MathF.Pow(1f + D * B * (HP - SP), -(B + 1f) / B)) + HP;
                    b4 = 1f / (D * MathF.Pow(1f + D * B * (HP - SP), -(B + 1f) / B) * q);
                }
                break;

            case GhsType.Asinh:
            case GhsType.InverseAsinh:
                qlp = -MathF.Log(D * (SP - LP) + MathF.Sqrt(D * D * (SP - LP) * (SP - LP) + 1f));
                q0 = qlp - LP * D / MathF.Sqrt(D * D * (SP - LP) * (SP - LP) + 1f);
                qwp = MathF.Log(D * (HP - SP) + MathF.Sqrt(D * D * (HP - SP) * (HP - SP) + 1f));
                q1 = qwp + (1f - HP) * D / MathF.Sqrt(D * D * (HP - SP) * (HP - SP) + 1f);
                q = 1f / (q1 - q0);
                a1 = 0f; b1 = D / MathF.Sqrt(D * D * (SP - LP) * (SP - LP) + 1f) * q;
                a2 = -q0 * q; b2 = -q; c2 = -D; d2 = D * D; e2 = SP;
                a3 = -q0 * q; b3 = q; c3 = D; d3 = D * D; e3 = SP;
                a4 = (qwp - HP * D / MathF.Sqrt(D * D * (HP - SP) * (HP - SP) + 1f) - q0) * q;
                b4 = D / MathF.Sqrt(D * D * (HP - SP) * (HP - SP) + 1f) * q;
                if (type == GhsType.InverseAsinh)
                {
                    LPT = a1 + b1 * LP;
                    SPT = a2 + b2 * MathF.Log(c2 * (SP - e2) + MathF.Sqrt(d2 * (SP - e2) * (SP - e2) + 1f));
                    HPT = a4 + b4 * HP;
                }
                break;
        }
    }

    /// <summary>Stretches one value in [0,1].</summary>
    public float Apply(float input)
    {
        var p = _p;
        float x = Math.Clamp(input, 0f, 1f);
        switch (p.Type)
        {
            case GhsType.Linear:
                return Math.Max(0f, (x - p.BP) / (1f - p.BP));
            case GhsType.Mtf:
                return DisplayStretch.Mtf(Math.Max(0f, (x - p.SP) / (1f - p.SP)), p.D);
            case GhsType.Simple:
                return ApplySimple(x);
            case GhsType.Ghs:
            {
                if (p.D == 0f) return x;
                float r1, r2;
                if (_bcat == 0) { r1 = a2 + b2 * MathF.Log(c2 + d2 * x); r2 = a3 + b3 * MathF.Log(c3 + d3 * x); }
                else if (_bcat == 2) { r1 = a2 + b2 * MathF.Pow(c2 + d2 * x, e2); r2 = a3 + b3 * MathF.Pow(c3 + d3 * x, e3); }
                else { r1 = a2 + b2 * MathF.Exp(c2 + d2 * x); r2 = a3 + b3 * MathF.Exp(c3 + d3 * x); }
                return x < p.LP ? b1 * x : x < p.SP ? r1 : x < p.HP ? r2 : a4 + b4 * x;
            }
            case GhsType.InverseGhs:
            {
                if (p.D == 0f) return x;
                float r1, r2;
                if (_bcat == 0) { r1 = a2 + b2 * MathF.Exp(c2 + d2 * x); r2 = a3 + b3 * MathF.Exp(c3 + d3 * x); }
                else if (_bcat == 2) { r1 = a2 + b2 * MathF.Pow(c2 + d2 * x, e2); r2 = a3 + b3 * MathF.Pow(c3 + d3 * x, e3); }
                else { r1 = a2 + b2 * MathF.Log(c2 + d2 * x); r2 = a3 + b3 * MathF.Log(c3 + d3 * x); }
                return x < LPT ? b1 * x : x < SPT ? r1 : x < HPT ? r2 : a4 + b4 * x;
            }
            case GhsType.Asinh:
            {
                if (p.D == 0f) return x;
                float v1 = c2 * (x - e2) + MathF.Sqrt(d2 * (x - e2) * (x - e2) + 1f);
                float r1 = a2 + b2 * MathF.Log(v1);
                float v2 = c3 * (x - e3) + MathF.Sqrt(d3 * (x - e3) * (x - e3) + 1f);
                float r2 = a3 + b3 * MathF.Log(v2);
                return x < p.LP ? a1 + b1 * x : x < p.SP ? r1 : x < p.HP ? r2 : a4 + b4 * x;
            }
            default:
            {
                if (p.D == 0f) return x;
                float ex = MathF.Exp((a2 - x) / b2);
                float r1 = e2 - (ex - 1f / ex) / (2f * c2);
                ex = MathF.Exp((a3 - x) / b3);
                float r2 = e3 - (ex - 1f / ex) / (2f * c3);
                return x < LPT ? (x - a1) / b1 : x < SPT ? r1 : x < HPT ? r2 : (x - a4) / b4;
            }
        }
    }

    /// <summary>Applies the stretch to a whole image with the chosen colour model.</summary>
    public static AstroImage Apply(AstroImage input, GhsParams p, CancellationToken ct = default)
    {
        var output = input.CreateEmptyLike();
        int n = input.PixelsPerChannel, w = input.Width;
        // Auto stretch with per-channel MTF parameters (unlinked, like the screen boost and GraXpert's autostretch).
        if (p.Type == GhsType.Mtf && p.ChannelMidtones is { } cm && p.ChannelShadows is { } cs)
        {
            Parallel.For(0, input.Height * input.Channels, new ParallelOptions { CancellationToken = ct }, row =>
            {
                int c = row / input.Height, y = row % input.Height;
                var prm = new DisplayStretch.Params(cs[Math.Min(c, cs.Length - 1)], cm[Math.Min(c, cm.Length - 1)]);
                int start = c * n + y * w;
                var s = input.Data; var d = output.Data;
                for (int i = start; i < start + w; i++) d[i] = Math.Clamp(prm.Apply(Math.Clamp(s[i], 0f, 1f)), 0f, 1f);
            });
            return output;
        }
        var t = new GhsTransform(p);
        var src = input.Data; var dst = output.Data;
        if (p.Colour == GhsColourModel.Independent || input.Channels != 3)
        {
            Parallel.For(0, input.Height * input.Channels, new ParallelOptions { CancellationToken = ct }, row =>
            {
                int c = row / input.Height, y = row % input.Height;
                int start = c * n + y * w;
                for (int i = start; i < start + w; i++) dst[i] = Math.Clamp(t.Apply(src[i]), 0f, 1f);
            });
            return output;
        }
        float fr = p.Colour == GhsColourModel.EvenLuminance ? 1f / 3 : 0.2126f;
        float fg = p.Colour == GhsColourModel.EvenLuminance ? 1f / 3 : 0.7152f;
        float fb = p.Colour == GhsColourModel.EvenLuminance ? 1f / 3 : 0.0722f;
        Parallel.For(0, input.Height, new ParallelOptions { CancellationToken = ct }, y =>
        {
            for (int i = y * w; i < (y + 1) * w; i++)
            {
                float r = Math.Clamp(src[i], 0f, 1f), g = Math.Clamp(src[n + i], 0f, 1f), b = Math.Clamp(src[2 * n + i], 0f, 1f);
                float lum = fr * r + fg * g + fb * b;
                float factor = t.Apply(lum) / MathF.Max(lum, 1e-9f);
                dst[i] = Math.Clamp(r * factor, 0f, 1f);
                dst[n + i] = Math.Clamp(g * factor, 0f, 1f);
                dst[2 * n + i] = Math.Clamp(b * factor, 0f, 1f);
            }
        });
        return output;
    }

    /// <summary>Applies a sequence of stretches in order.</summary>
    public static AstroImage ApplyAll(AstroImage input, IEnumerable<GhsParams> list, CancellationToken ct = default)
    {
        var image = input;
        foreach (var p in list) if (!p.IsIdentity) image = Apply(image, p, ct);
        return image;
    }
}

/// <summary>Per-channel histogram (256 bins), values in [0,1].</summary>
public static class Histogram
{
    public const int Bins = 256;

    public static int[][] Compute(AstroImage image, int stride = 1)
    {
        var result = new int[image.Channels][];
        for (int c = 0; c < image.Channels; c++)
        {
            var bins = new int[Bins];
            var ch = image.Channel(c);
            for (int i = 0; i < ch.Length; i += stride)
            {
                float v = ch[i];
                if (v <= 0f) continue;                 // empty canvas outside the frames
                bins[Math.Min(Bins - 1, (int)(v * Bins))]++;
            }
            result[c] = bins;
        }
        return result;
    }
}
