using System.IO.Compression;
using System.Security.Cryptography;
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

/// <summary>A ClearStar tükrén elérhető modell: verzió, letöltési cím, méret és ellenőrzőösszeg.</summary>
public sealed record MirrorModel(AiModelKind Kind, string Version, string Url, long Size, string Sha256, string? LicenseUrl);

/// <summary>
/// AI-modellek (GraXpert-kompatibilis ONNX fájlok) nyilvántartása. A modellek a ClearStar saját
/// mappájában vagy – ha telepítve van – a GraXpert letöltött modelljei között lehetnek; betallózni
/// és URL-ről letölteni is lehet. A kiválasztott modell fajtánként a beállításokban marad meg.
/// A GraXpert saját modellszervere privát (a hozzáférési kulcsok nincsenek a nyílt kódban), ezért
/// a modelleket a ClearStar tükréről (<see cref="AppLinks.Mirror"/>) töltjük le: a tükör
/// manifest.json-ja adja a verziókat, a méretet és az SHA-256-ot, amit letöltés után ellenőrzünk.
/// A GraXpert által már letöltött modelleket továbbra is megtaláljuk.
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

    /// <summary>A fajta legfrissebb modellje a tükör manifest.json-ja szerint, vagy null, ha nincs ott ilyen.</summary>
    public static async Task<MirrorModel?> LatestOnMirrorAsync(AiModelKind kind, CancellationToken ct = default)
    {
        using var http = CreateHttp(TimeSpan.FromSeconds(30));
        return LatestInManifest(await http.GetStringAsync(AppLinks.Mirror + "manifest.json", ct), kind, AppLinks.Mirror);
    }

    /// <summary>
    /// A manifest.json (files[]: path, size, sha256) <c>graxpert/&lt;fajta&gt;-ai-models/&lt;verzió&gt;/model.onnx</c>
    /// bejegyzései közül a legmagasabb verzió, a mellette lévő LICENSE.html címével együtt.
    /// </summary>
    public static MirrorModel? LatestInManifest(string json, AiModelKind kind, string baseUrl)
    {
        string prefix = $"graxpert/{GraXpertSubdir(kind)}/";
        const string modelFile = "/model.onnx";
        List<(string Path, long Size, string Sha256)> files;
        try
        {
            using var doc = JsonDocument.Parse(json);
            files = doc.RootElement.GetProperty("files").EnumerateArray()
                .Select(f => (Path: f.GetProperty("path").GetString() ?? "", Size: f.GetProperty("size").GetInt64(), Sha256: f.GetProperty("sha256").GetString() ?? ""))
                .Where(f => f.Path.StartsWith(prefix, StringComparison.Ordinal))
                .ToList();
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            throw new IOException(L.T("msg.model.mirrorManifest"), ex);
        }

        MirrorModel? best = null;
        foreach (var f in files.Where(f => f.Path.EndsWith(modelFile, StringComparison.Ordinal)))
        {
            string version = f.Path[prefix.Length..^modelFile.Length];
            if (version.Length == 0 || version.Contains('/')) continue;
            if (best is not null && ParseVersion(version) <= ParseVersion(best.Version)) continue;
            string license = prefix + version + "/LICENSE.html";
            best = new MirrorModel(kind, version, baseUrl + f.Path, f.Size, f.Sha256,
                files.Any(x => x.Path == license) ? baseUrl + license : null);
        }
        return best;
    }

    /// <summary>
    /// Modell letöltése a tükörről a ClearStar modellmappájába (a licencfájllal együtt), méret- és
    /// SHA-256-ellenőrzéssel. Hibás letöltésből nem marad model.onnx a mappában.
    /// </summary>
    public static async Task<AiModelInfo> DownloadFromMirrorAsync(MirrorModel model, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        string dir = System.IO.Path.Combine(ClearStarModelsDir, OwnSubdir(model.Kind), model.Version);
        Directory.CreateDirectory(dir);
        string target = System.IO.Path.Combine(dir, "model.onnx");
        string partial = target + ".part";
        using var http = CreateHttp(TimeSpan.FromMinutes(30));
        try
        {
            string hash = await DownloadToFileAsync(http, model.Url, partial, progress, ct);
            if (!string.Equals(hash, model.Sha256, StringComparison.OrdinalIgnoreCase) || new FileInfo(partial).Length != model.Size)
                throw new IOException(L.T("msg.model.checksum"));
            if (model.LicenseUrl is not null)
                await File.WriteAllBytesAsync(System.IO.Path.Combine(dir, "LICENSE.html"), await http.GetByteArrayAsync(model.LicenseUrl, ct), ct);
            File.Move(partial, target, overwrite: true);
        }
        finally
        {
            try { File.Delete(partial); } catch (IOException) { }
        }
        var info = new AiModelInfo(model.Kind, model.Version, target, "ClearStar");
        SetPreferred(model.Kind, target);
        return info;
    }

    /// <summary>Modell letöltése URL-ről (.onnx vagy .zip), majd importálás.</summary>
    public static async Task<AiModelInfo> DownloadAsync(AiModelKind kind, string url, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        using var http = CreateHttp(TimeSpan.FromMinutes(30));
        string name = System.IO.Path.GetFileName(new Uri(url).AbsolutePath);
        if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) name = "model.onnx";
        string temp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ClearStar", "download", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        string file = System.IO.Path.Combine(temp, name);
        await DownloadToFileAsync(http, url, file, progress, ct);
        var info = Import(kind, file, GuessVersion(url));
        try { Directory.Delete(temp, recursive: true); } catch (IOException) { }
        return info;
    }

    private static HttpClient CreateHttp(TimeSpan timeout)
    {
        var http = new HttpClient { Timeout = timeout };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ClearStar/0.1 (AI model download)");
        return http;
    }

    /// <summary>Letölti a fájlt, és visszaadja az SHA-256-ját (kisbetűs hex).</summary>
    private static async Task<string> DownloadToFileAsync(HttpClient http, string url, string file, IProgress<double>? progress, CancellationToken ct)
    {
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        long total = response.Content.Headers.ContentLength ?? -1, read = 0;
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        await using (var src = await response.Content.ReadAsStreamAsync(ct))
        await using (var dst = File.Create(file))
        {
            var buffer = new byte[1 << 20];
            int n;
            while ((n = await src.ReadAsync(buffer, ct)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                sha.AppendData(buffer, 0, n);
                read += n;
                if (total > 0) progress?.Report(read / (double)total);
            }
        }
        return Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
    }

    private static string? GuessVersion(string s)
    {
        var m = Regex.Match(s, @"\d+\.\d+\.\d+");
        return m.Success ? m.Value : null;
    }

    private static string SettingKey(AiModelKind kind) => $"model.{kind}";

}
