using ClearStar.Core.Imaging;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;

namespace ClearStar.Core.Steps;

/// <summary>
/// 3. lépés: vágás. Vagy a képen egérrel kijelölt téglalap (a felület tölti a rejtett
/// paramétereket, a kép arányában 0..1), vagy ha nincs kijelölés, a szélekből arányosan levágott sáv.
/// </summary>
public sealed class CropStep : StepBase
{
    public const string MarginKey = "margin";
    public const string SelLeftKey = "selLeft", SelTopKey = "selTop", SelWidthKey = "selWidth", SelHeightKey = "selHeight";
    public const string RotateKey = "rotate";
    public const string FlipHKey = "flipH";
    public const string FlipVKey = "flipV";
    public const string AngleKey = "angle";

    private const string S = "crop";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Crop, StepGroup.Preparation, S,
        [
            Slider(S, MarginKey, 0.0, 0, 0.15),
            Choice(S, RotateKey, "0", ["0", "90", "180", "270"]),
            new(AngleKey, L.T("step.crop.angle.label"), ParameterKind.Slider, 0.0, -45, 45, L.A("step.crop.angle.ticks"), Help: L.T("step.crop.angle.help"), ValueFormat: "{0:+0.0;−0.0;0}°"),
            Toggle(S, FlipHKey, false),
            Toggle(S, FlipVKey, false),
            Hidden(SelLeftKey, 0.0),
            Hidden(SelTopKey, 0.0),
            Hidden(SelWidthKey, 0.0),
            Hidden(SelHeightKey, 0.0),
        ]);

    public static bool HasSelection(StepParameters p) => p.GetDouble(SelWidthKey) > 0.001 && p.GetDouble(SelHeightKey) > 0.001;

    /// <summary>Total rotation (90° choice + fine angle), mirroring flags – the orientation applied before the crop.</summary>
    public static (double angle, bool flipH, bool flipV) Orientation(StepParameters p)
    {
        int rotate = int.TryParse(p.GetString(RotateKey, "0"), out var r) ? r : 0;
        return (rotate + p.GetDouble(AngleKey), p.GetBool(FlipHKey), p.GetBool(FlipVKey));
    }

    public override Task<StepResult> RunAsync(WorkflowContext context)
    {
        var raw = context.RequireInput();
        var p = context.Parameters;
        // Orientation first (the selection was drawn on the oriented preview), then the crop.
        var (angle, flipH, flipV) = Orientation(p);
        var input = Orient(raw, angle, flipH, flipV);
        int left, top, right, bottom;
        if (HasSelection(p))
        {
            double sl = Math.Clamp(p.GetDouble(SelLeftKey), 0, 1), st = Math.Clamp(p.GetDouble(SelTopKey), 0, 1);
            double sw = Math.Clamp(p.GetDouble(SelWidthKey), 0, 1 - sl), sh = Math.Clamp(p.GetDouble(SelHeightKey), 0, 1 - st);
            left = (int)Math.Round(sl * input.Width); top = (int)Math.Round(st * input.Height);
            right = input.Width - (int)Math.Round((sl + sw) * input.Width);
            bottom = input.Height - (int)Math.Round((st + sh) * input.Height);
        }
        else
        {
            float m = p.GetFloat(MarginKey);
            left = right = (int)(m * input.Width);
            top = bottom = (int)(m * input.Height);
        }
        var output = Crop(input, left, top, right, bottom);
        string summary = L.F("msg.crop.size", output.Width, output.Height);
        if (Math.Abs(angle) > 1e-6) summary += L.F("msg.crop.rotated", angle);
        if (flipH || flipV) summary += L.T("msg.crop.flipped");
        return Task.FromResult(new StepResult(output, summary));
    }

    /// <summary>Size of the canvas that holds the image rotated by <paramref name="angleDegrees"/> (bounding box, as WPF's TransformedBitmap does).</summary>
    public static (int width, int height) OrientedSize(int width, int height, double angleDegrees)
    {
        double a = angleDegrees * Math.PI / 180, c = Math.Abs(Math.Cos(a)), s = Math.Abs(Math.Sin(a));
        return ((int)Math.Round(width * c + height * s), (int)Math.Round(width * s + height * c));
    }

    /// <summary>
    /// Mirror (horizontal / vertical), then rotate clockwise by any angle. Multiples of 90° are lossless;
    /// other angles are resampled bilinearly onto the bounding-box canvas (empty corners stay black).
    /// </summary>
    public static AstroImage Orient(AstroImage input, double angleDegrees, bool flipH, bool flipV)
    {
        double norm = ((angleDegrees % 360) + 360) % 360;
        int nearest = (int)Math.Round(norm / 90) * 90 % 360;
        if (Math.Abs(norm - Math.Round(norm / 90) * 90) < 1e-6) return OrientRightAngle(input, nearest, flipH, flipV);

        var flipped = (flipH || flipV) ? OrientRightAngle(input, 0, flipH, flipV) : input;
        int w = flipped.Width, h = flipped.Height;
        var (ow, oh) = OrientedSize(w, h, norm);
        double a = norm * Math.PI / 180, cos = Math.Cos(a), sin = Math.Sin(a);
        double cx = (w - 1) / 2.0, cy = (h - 1) / 2.0, ocx = (ow - 1) / 2.0, ocy = (oh - 1) / 2.0;
        var output = new AstroImage(ow, oh, input.Channels, null, new Dictionary<string, string>(input.Header, StringComparer.OrdinalIgnoreCase));
        for (int c = 0; c < input.Channels; c++)
        {
            var src = flipped.Channel(c).ToArray();
            int dstOff = c * output.PixelsPerChannel;
            var dst = output.Data;
            Parallel.For(0, oh, oy =>
            {
                double dy = oy - ocy;
                for (int ox = 0; ox < ow; ox++)
                {
                    double dx = ox - ocx;
                    // Inverse of a clockwise rotation (screen coordinates, y down).
                    double sx = cos * dx + sin * dy + cx, sy = -sin * dx + cos * dy + cy;
                    int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
                    if (x0 < 0 || y0 < 0 || x0 >= w - 1 || y0 >= h - 1) { dst[dstOff + oy * ow + ox] = 0f; continue; }
                    float fx = (float)(sx - x0), fy = (float)(sy - y0);
                    float v00 = src[y0 * w + x0], v10 = src[y0 * w + x0 + 1], v01 = src[(y0 + 1) * w + x0], v11 = src[(y0 + 1) * w + x0 + 1];
                    dst[dstOff + oy * ow + ox] = (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy;
                }
            });
        }
        return output;
    }

    /// <summary>Mirror (horizontal / vertical) and then rotate by a multiple of 90° clockwise. Lossless.</summary>
    public static AstroImage OrientRightAngle(AstroImage input, int rotateDegrees, bool flipH, bool flipV)
    {
        int rot = ((rotateDegrees % 360) + 360) % 360;
        if (rot == 0 && !flipH && !flipV) return input;
        int w = input.Width, h = input.Height;
        bool swap = rot is 90 or 270;
        int ow = swap ? h : w, oh = swap ? w : h;
        var output = new AstroImage(ow, oh, input.Channels, null, new Dictionary<string, string>(input.Header, StringComparer.OrdinalIgnoreCase));
        for (int c = 0; c < input.Channels; c++)
        {
            var src = input.Channel(c).ToArray();
            var dstOff = c * output.PixelsPerChannel;
            var dst = output.Data;
            Parallel.For(0, oh, oy =>
            {
                for (int ox = 0; ox < ow; ox++)
                {
                    // Undo the rotation to find the source pixel, then undo the flips.
                    int x, y;
                    switch (rot)
                    {
                        case 90: x = oy; y = h - 1 - ox; break;
                        case 180: x = w - 1 - ox; y = h - 1 - oy; break;
                        case 270: x = w - 1 - oy; y = ox; break;
                        default: x = ox; y = oy; break;
                    }
                    if (flipH) x = w - 1 - x;
                    if (flipV) y = h - 1 - y;
                    dst[dstOff + oy * ow + ox] = src[y * w + x];
                }
            });
        }
        return output;
    }

    public static AstroImage Crop(AstroImage input, int left, int top, int right, int bottom)
    {
        int w = input.Width - left - right, h = input.Height - top - bottom;
        if (w < 16 || h < 16) throw new InvalidOperationException(L.T("msg.crop.tooMuch"));
        if (left == 0 && top == 0 && right == 0 && bottom == 0) return input.Clone();
        var output = new AstroImage(w, h, input.Channels, null, new Dictionary<string, string>(input.Header, StringComparer.OrdinalIgnoreCase));
        for (int c = 0; c < input.Channels; c++)
        {
            var src = input.Channel(c);
            var dst = output.Channel(c);
            for (int y = 0; y < h; y++)
                src.Slice((y + top) * input.Width + left, w).CopyTo(dst.Slice(y * w, w));
        }
        return output;
    }
}
