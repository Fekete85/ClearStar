using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using ClearStar.Core.Imaging;
using ClearStar.Core.IO;

namespace ClearStar.Core.AI;

/// <summary>
/// Runs the user's own StarNet2 command-line program (starnetastro.com) as an external process.
/// StarNet2 is not part of ClearStar and is not redistributed: it is located on the machine
/// (ClearStar settings, Siril's configuration, the default install folder, PATH) or chosen by
/// the user. Images travel as 32-bit FITS files through a temporary folder.
/// </summary>
public static partial class StarNet
{
    public const string ExeSettingKey = "starnet.exe";
    public const string DownloadUrl = "https://www.starnetastro.com/download";
    public const string ExeName = "starnet2.exe";

    /// <summary>The executable's full path, or null when StarNet2 cannot be found.</summary>
    public static string? Locate()
    {
        foreach (var candidate in Candidates())
            if (candidate is not null && File.Exists(candidate)) return candidate;
        return null;
    }

    private static IEnumerable<string?> Candidates()
    {
        yield return UserSettings.Get(ExeSettingKey);
        // Siril stores the path the user configured there: starnet_exe=D:\\astro\\starnet\\starnet2.exe
        string sirilDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "siril");
        if (Directory.Exists(sirilDir))
            foreach (var ini in Directory.EnumerateFiles(sirilDir, "config*.ini").OrderByDescending(f => f))
            {
                string? path = null;
                try
                {
                    foreach (var line in File.ReadLines(ini))
                        if (line.StartsWith("starnet_exe=", StringComparison.OrdinalIgnoreCase))
                        { path = line["starnet_exe=".Length..].Trim().Replace("\\\\", "\\"); break; }
                }
                catch (IOException) { }
                if (!string.IsNullOrEmpty(path)) yield return path;
            }
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        yield return Path.Combine(pf, "StarNet2", "bin", ExeName);
        yield return Path.Combine(pf, "StarNet2", ExeName);
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
            yield return Path.Combine(dir.Trim(), ExeName);
    }

    /// <summary>Remembers a user-chosen executable (null clears it).</summary>
    public static void SetExecutable(string? path) => UserSettings.Set(ExeSettingKey, path);

    [GeneratedRegex("\"percent\"\\s*:\\s*([0-9.]+)")]
    private static partial Regex PercentPattern();

    [GeneratedRegex("\"message\"\\s*:\\s*\"([^\"]*)\"")]
    private static partial Regex MessagePattern();

    /// <summary>
    /// Removes the stars from an already stretched (non-linear) image. Returns the starless image;
    /// throws with StarNet2's own message when the program fails.
    /// </summary>
    public static AstroImage RemoveStars(AstroImage stretched, string exe, Action<double>? progress = null, CancellationToken ct = default)
    {
        string dir = Path.Combine(Path.GetTempPath(), "ClearStar", "starnet", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            string input = Path.Combine(dir, "input.fit"), output = Path.Combine(dir, "starless.fit");
            ImageFiles.Save(input, stretched, ExportFormat.Fits);

            var psi = new ProcessStartInfo(exe)
            {
                WorkingDirectory = Path.GetDirectoryName(exe) ?? dir,
                RedirectStandardOutput = true, RedirectStandardError = true,
                UseShellExecute = false, CreateNoWindow = true,
            };
            psi.ArgumentList.Add("--input"); psi.ArgumentList.Add(input);
            psi.ArgumentList.Add("--output"); psi.ArgumentList.Add(output);
            psi.ArgumentList.Add("--machine-progress");
            psi.ArgumentList.Add("--quiet");

            using var process = Process.Start(psi) ?? throw new InvalidOperationException("StarNet2 could not be started.");
            string? lastError = null;
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data is null) return;
                var m = PercentPattern().Match(e.Data);
                if (m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var pct))
                    progress?.Invoke(pct / 100.0);
                if (e.Data.Contains("\"event\":\"error\"", StringComparison.Ordinal))
                {
                    var msg = MessagePattern().Match(e.Data);
                    lastError = msg.Success ? msg.Groups[1].Value : e.Data;
                }
            };
            process.BeginErrorReadLine();
            var stdout = process.StandardOutput.ReadToEndAsync(ct);
            while (!process.WaitForExit(200))
            {
                if (!ct.IsCancellationRequested) continue;
                try { process.Kill(true); } catch (InvalidOperationException) { }
                ct.ThrowIfCancellationRequested();
            }
            process.WaitForExit(); // flush the async readers
            if (process.ExitCode != 0 || !File.Exists(output))
                throw new InvalidOperationException(lastError ?? $"StarNet2 exit code {process.ExitCode}");
            var result = ImageFiles.Load(output, debayer: false);
            // StarNet2 (OpenCV inside) writes the colour planes of a FITS cube in BGR order: swap them back.
            if (result.Channels == 3)
            {
                var red = result.Channel(0).ToArray();
                result.Channel(2).CopyTo(result.Channel(0));
                red.AsSpan().CopyTo(result.Channel(2));
            }
            return result;
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// Star removal on a linear image: an auto-stretch (linked MTF) is applied first, StarNet2 runs
    /// on the stretched image, and the exact inverse stretch brings the starless result back to
    /// linear. Returns (starless, stars) with stars = original − starless.
    /// </summary>
    public static (AstroImage starless, AstroImage stars) RemoveStarsLinear(AstroImage linear, string exe, Action<double>? progress = null, CancellationToken ct = default)
    {
        var prms = DisplayStretch.ComputeAll(linear, new DisplayStretch.Preset("starnet", 0.25f, 2.8f), linked: true);
        var stretched = linear.CreateEmptyLike();
        int n = linear.PixelsPerChannel;
        for (int c = 0; c < linear.Channels; c++)
        {
            var p = prms[c]; var src = linear.Data; var dst = stretched.Data; int off = c * n;
            Parallel.For(0, linear.Height, y => { for (int i = off + y * linear.Width; i < off + (y + 1) * linear.Width; i++) dst[i] = p.Apply(src[i]); });
        }
        var starlessStretched = RemoveStars(stretched, exe, progress, ct);
        if (starlessStretched.Width != linear.Width || starlessStretched.Height != linear.Height || starlessStretched.Channels != linear.Channels)
            throw new InvalidOperationException("StarNet2 returned an image of a different size.");

        var starless = linear.CreateEmptyLike();
        var stars = linear.CreateEmptyLike();
        for (int c = 0; c < linear.Channels; c++)
        {
            var p = prms[c]; var src = starlessStretched.Data; var dst = starless.Data; var orig = linear.Data; var st = stars.Data; int off = c * n;
            Parallel.For(0, linear.Height, y =>
            {
                for (int i = off + y * linear.Width; i < off + (y + 1) * linear.Width; i++)
                {
                    float v = Math.Clamp(p.Invert(Math.Clamp(src[i], 0f, 1f)), 0f, 1f);
                    dst[i] = v;
                    st[i] = Math.Max(orig[i] - v, 0f);
                }
            });
        }
        return (starless, stars);
    }
}
