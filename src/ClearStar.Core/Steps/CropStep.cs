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

    private const string S = "crop";

    public override StepDefinition Definition { get; } = StepDefinition.FromLanguage(
        StepId.Crop, StepGroup.Preparation, S,
        [
            Slider(S, MarginKey, 0.0, 0, 0.15),
            Choice(S, RotateKey, "0", ["0", "90", "180", "270"]),
            Toggle(S, FlipHKey, false),
            Toggle(S, FlipVKey, false),
            Hidden(SelLeftKey, 0.0),
            Hidden(SelTopKey, 0.0),
            Hidden(SelWidthKey, 0.0),
            Hidden(SelHeightKey, 0.0),
        ]);

    public static bool HasSelection(StepParameters p) => p.GetDouble(SelWidthKey) > 0.001 && p.GetDouble(SelHeightKey) > 0.001;

    public override Task<StepResult> RunAsync(WorkflowContext context)
    {
        var input = context.RequireInput();
        var p = context.Parameters;
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
        int rotate = int.TryParse(p.GetString(RotateKey, "0"), out var r) ? r : 0;
        bool flipH = p.GetBool(FlipHKey), flipV = p.GetBool(FlipVKey);
        output = Orient(output, rotate, flipH, flipV);
        string summary = L.F("msg.crop.size", output.Width, output.Height);
        if (rotate != 0) summary += L.F("msg.crop.rotated", rotate);
        if (flipH || flipV) summary += L.T("msg.crop.flipped");
        return Task.FromResult(new StepResult(output, summary));
    }

    /// <summary>Mirror (horizontal / vertical) and then rotate by a multiple of 90° clockwise. Lossless.</summary>
    public static AstroImage Orient(AstroImage input, int rotateDegrees, bool flipH, bool flipV)
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
