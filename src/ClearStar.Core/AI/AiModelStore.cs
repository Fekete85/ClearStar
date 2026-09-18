using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;

using ClearStar.Core.Localization;

namespace ClearStar.Core.AI;

public enum AiModelKind { BackgroundExtraction, Denoise, DeconvolutionObject, DeconvolutionStars }

/// <summary>Egy megtalált ONNX-modell: honnan van, milyen verzió, hol a fájl.</summary>
public sealed record AiModelInfo(AiModelKind Kind, string Version, string Path, string Source)
{
    public string DisplayName => $"{Version} – {Source}";
}

/// <summary>
/// AI-modellek (GraXpert-kompatibilis ONNX fájlok) nyilvántartása. A modellek a ClearStar saját
/// mappájában vagy – ha telepítve van – a GraXpert letöltött modelljei között lehetnek; betallózni
/// és URL-ről letölteni is lehet. A kiválasztott modell fajtánként a beállításokban marad meg.
/// A GraXpert saját modellszervere privát (a hozzáférési kulcsok nincsenek a nyílt kódban), ezért
/// onnan közvetlenül nem tudunk letölteni – a GraXpert egyszeri használatával viszont a modellek
/// a gépre kerülnek, és innentől itt is elérhetők.
/// </summary>
public static class AiModelStore
{
    public static string ClearStarModelsDir { get; } =
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClearStar", "ai-models");

    public static string GraXpertDataDir { get; } =
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GraXpert", "GraXpert");

    public static string KindName(AiModelKind kind) => kind switch
    {
        _ when L.Has($"msg.model.kind.{kind}") => L.T($"msg.model.kind.{kind}"),
        _ => kind.ToString(),
    };

    private static string GraXpertSubdir(AiModelKind kind) => kind switch
    {
        AiModelKind.BackgroundExtraction => "bge-ai-models",
        AiModelKind.Denoise => "denoise-ai-models",
        AiModelKind.DeconvolutionObject => "deconvolution-object-ai-models",
        AiModelKind.DeconvolutionStars => "deconvolution-stars-ai-models",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static string OwnSubdir(AiModelKind kind) => kind.ToString().ToLowerInvariant();

    /// <summary>Minden elérhető modell a fajtához, a legfrissebb verzió elöl.</summary>
    public static IReadOnlyList<AiModelInfo> ListAvailable(AiModelKind kind)
    {
        var list = new List<AiModelInfo>();
        Collect(list, kind, System.IO.Path.Combine(ClearStarModelsDir, OwnSubdir(kind)), "ClearStar");
        Collect(list, kind, System.IO.Path.Combine(GraXpertDataDir, GraXpertSubdir(kind)), "GraXpert");
        return list.OrderByDescending(m => ParseVersion(m.Version)).ThenBy(m => m.Source).ToList();
    }

    private static void Collect(List<AiModelInfo> list, AiModelKind kind, string root, string source)
    {
        if (!Directory.Exists(root)) return;
        foreach (var dir in Directory.EnumerateDirectories(root))
        {
            string file = System.IO.Path.Combine(dir, "model.onnx");
            if (File.Exists(file)) list.Add(new AiModelInfo(kind, System.IO.Path.GetFileName(dir), file, source));
        }
    }

    private static Version ParseVersion(string s) => Version.TryParse(s, out var v) ? v : new Version(0, 0);

    /// <summary>A felhasználó által választott modell, vagy ha nincs/eltűnt, a legfrissebb elérhető.</summary>
    public static AiModelInfo? Resolve(AiModelKind kind)
    {
        var available = ListAvailable(kind);
        string? preferred = UserSettings.Get(SettingKey(kind));
        if (preferred is not null)
        {
            var match = available.FirstOrDefault(m => string.Equals(m.Path, preferred, StringComparison.OrdinalIgnoreCase));
            if (match is not null) return match;
            if (File.Exists(preferred)) return new AiModelInfo(kind, System.IO.Path.GetFileNameWithoutExtension(preferred), preferred, L.T("msg.model.ownFile"));
        }
        return available.FirstOrDefault();
    }

    public static void SetPreferred(AiModelKind kind, string? path)
    {
        UserSettings.Set(SettingKey(kind), path);
    }

    /// <summary>Saját model.onnx (vagy azt tartalmazó zip) bemásolása a ClearStar modellmappájába.</summary>
    public static AiModelInfo Import(AiModelKind kind, string sourceFile, string? version = null)
    {
        version ??= GuessVersion(sourceFile) ?? DateTime.Now.ToString("yyyy.MM.dd");
        string dir = System.IO.Path.Combine(ClearStarModelsDir, OwnSubdir(kind), version);
        Directory.CreateDirectory(dir);
        string target = System.IO.Path.Combine(dir, "model.onnx");
        if (sourceFile.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            using var zip = ZipFile.OpenRead(sourceFile);
            var entry = zip.Entries.FirstOrDefault(e => e.Name.EndsWith(".onnx", StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidOperationException(L.T("msg.model.zipNoOnnx"));
            entry.ExtractToFile(target, overwrite: true);
        }
        else File.Copy(sourceFile, target, overwrite: true);
        var info = new AiModelInfo(kind, version, target, "ClearStar");
        SetPreferred(kind, target);
        return info;
    }

    /// <summary>Modell letöltése URL-ről (.onnx vagy .zip), majd importálás.</summary>
    public static async Task<AiModelInfo> DownloadAsync(AiModelKind kind, string url, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        string name = System.IO.Path.GetFileName(new Uri(url).AbsolutePath);
        if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) name = "model.onnx";
        string temp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ClearStar", "download", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        string file = System.IO.Path.Combine(temp, name);
        long total = response.Content.Headers.ContentLength ?? -1, read = 0;
        await using (var src = await response.Content.ReadAsStreamAsync(ct))
        await using (var dst = File.Create(file))
        {
            var buffer = new byte[1 << 16];
            int n;
            while ((n = await src.ReadAsync(buffer, ct)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                read += n;
                if (total > 0) progress?.Report(read / (double)total);
            }
        }
        var info = Import(kind, file, GuessVersion(url));
        try { Directory.Delete(temp, recursive: true); } catch (IOException) { }
        return info;
    }

    private static string? GuessVersion(string s)
    {
        var m = Regex.Match(s, @"\d+\.\d+\.\d+");
        return m.Success ? m.Value : null;
    }

    private static string SettingKey(AiModelKind kind) => $"model.{kind}";

}
