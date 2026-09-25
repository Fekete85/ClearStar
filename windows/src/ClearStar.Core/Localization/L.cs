using System.Globalization;
using System.Reflection;
using System.Text.Json;

namespace ClearStar.Core.Localization;

/// <summary>Egy elérhető nyelv: kód (pl. "hu"), saját nevén írt neve és a forrás (beépített vagy fájl).</summary>
public sealed record LanguageInfo(string Code, string Name, string? FilePath)
{
    public bool IsBuiltIn => FilePath is null;
}

/// <summary>
/// Nyelvi adatbázis: a felület minden szövege kulcs alapján innen jön. A beépített nyelvek
/// (hu, en) a Core-ba ágyazott JSON-ok; további nyelvek a program mappájának <c>Languages</c>
/// alkönyvtárából és a <c>%LOCALAPPDATA%\ClearStar\Languages</c> mappából jönnek – egy új
/// <c>xx.json</c> fájl bemásolása elég egy új nyelvhez (az azonos kódú fájl felülírja a beépítettet).
/// A hiányzó kulcsok az angol tartalékból, végső soron magából a kulcsból jönnek.
/// </summary>
public static class L
{
    public const string DefaultLanguage = "hu";
    public const string FallbackLanguage = "en";

    private static Dictionary<string, string> _table = new();
    private static Dictionary<string, string> _fallback = new();

    /// <summary>A betöltött nyelv kódja.</summary>
    public static string Language { get; private set; } = "";

    /// <summary>A felhasználói nyelvfájlok mappája (ide másolhat be a felhasználó új nyelvet).</summary>
    public static string UserLanguagesDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClearStar", "Languages");

    /// <summary>A program mellé (a telepítéssel) tehető nyelvfájlok mappája.</summary>
    public static string AppLanguagesDir => Path.Combine(AppContext.BaseDirectory, "Languages");

    /// <summary>Szöveg kulcs alapján. Ha nincs meg sem a nyelvben, sem a tartalékban, a kulcs jön vissza.</summary>
    public static string T(string key)
    {
        if (Language.Length == 0) Load(DefaultLanguage);
        return _table.TryGetValue(key, out var v) ? v : _fallback.TryGetValue(key, out v) ? v : key;
    }

    /// <summary>Formázott szöveg ({0}, {1} … helyőrzőkkel).</summary>
    public static string F(string key, params object?[] args)
    {
        string format = T(key);
        try { return string.Format(CultureInfo.CurrentCulture, format, args); }
        catch (FormatException) { return format; }
    }

    /// <summary>Felsorolás (pl. csúszkafeliratok): a szöveg "|" jelekkel elválasztott elemei.</summary>
    public static string[] A(string key) => T(key).Split('|', StringSplitOptions.TrimEntries);

    /// <summary>Van-e ilyen kulcs (a nyelvben vagy a tartalékban)?</summary>
    public static bool Has(string key)
    {
        if (Language.Length == 0) Load(DefaultLanguage);
        return _table.ContainsKey(key) || _fallback.ContainsKey(key);
    }

    /// <summary>Az összes elérhető nyelv: beépítettek + a két mappában talált fájlok (a fájl felülírja a beépítettet).</summary>
    public static IReadOnlyList<LanguageInfo> Available()
    {
        var byCode = new Dictionary<string, LanguageInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in EmbeddedNames())
        {
            string code = name.Split('.')[^2]; // ClearStar.Core.Languages.hu.json → hu
            try
            {
                var table = Parse(ReadEmbedded(name));
                byCode[code] = new LanguageInfo(code, table.GetValueOrDefault("_meta.name", code), null);
            }
            catch { /* hibás beépített fájl – kihagyjuk */ }
        }
        foreach (var dir in new[] { AppLanguagesDir, UserLanguagesDir })
        {
            if (!Directory.Exists(dir)) continue;
            foreach (var file in Directory.EnumerateFiles(dir, "*.json"))
            {
                string code = Path.GetFileNameWithoutExtension(file);
                try
                {
                    var table = Parse(File.ReadAllText(file));
                    byCode[code] = new LanguageInfo(code, table.GetValueOrDefault("_meta.name", code), file);
                }
                catch { /* hibás fájl – kihagyjuk, a többi nyelv attól még működik */ }
            }
        }
        return byCode.Values.OrderBy(l => l.Code, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>A rendszer nyelvéhez legjobban illő elérhető nyelv (nincs találat: magyar, végső soron angol).</summary>
    public static string SystemLanguage()
    {
        var codes = Available().Select(l => l.Code).ToList();
        string ui = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        if (codes.Contains(ui, StringComparer.OrdinalIgnoreCase)) return ui;
        return codes.Contains(DefaultLanguage) ? DefaultLanguage : FallbackLanguage;
    }

    /// <summary>Nyelv betöltése kód alapján (a tartalék mindig az angol).</summary>
    public static void Load(string code)
    {
        var langs = Available();
        _fallback = LoadTable(langs, FallbackLanguage) ?? new Dictionary<string, string>();
        _table = LoadTable(langs, code) ?? _fallback;
        Language = _table == _fallback && !string.Equals(code, FallbackLanguage, StringComparison.OrdinalIgnoreCase)
            ? FallbackLanguage : code;
    }

    /// <summary>Teszt/CLI: tábla közvetlen betöltése.</summary>
    public static void LoadTable(string code, IReadOnlyDictionary<string, string> table)
    {
        _table = new Dictionary<string, string>(table);
        Language = code;
    }

    private static Dictionary<string, string>? LoadTable(IReadOnlyList<LanguageInfo> langs, string code)
    {
        var info = langs.FirstOrDefault(l => string.Equals(l.Code, code, StringComparison.OrdinalIgnoreCase));
        if (info is null) return null;
        string json = info.FilePath is null ? ReadEmbedded(EmbeddedNames().First(n => n.EndsWith($".{info.Code}.json", StringComparison.OrdinalIgnoreCase)))
                                            : File.ReadAllText(info.FilePath);
        return Parse(json);
    }

    /// <summary>JSON → lapos kulcs–érték tábla. A beágyazott objektumok kulcsai ponttal fűződnek össze.</summary>
    public static Dictionary<string, string> Parse(string json)
    {
        var result = new Dictionary<string, string>();
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        Flatten(doc.RootElement, "", result);
        return result;
    }

    private static void Flatten(JsonElement e, string prefix, Dictionary<string, string> into)
    {
        switch (e.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var p in e.EnumerateObject())
                    Flatten(p.Value, prefix.Length == 0 ? p.Name : prefix + "." + p.Name, into);
                break;
            case JsonValueKind.Array:
                into[prefix] = string.Join("|", e.EnumerateArray().Select(x => x.ToString()));
                break;
            case JsonValueKind.Null:
                break;
            default:
                into[prefix] = e.ToString();
                break;
        }
    }

    private static IEnumerable<string> EmbeddedNames() =>
        typeof(L).Assembly.GetManifestResourceNames().Where(n => n.Contains(".Languages.", StringComparison.Ordinal) && n.EndsWith(".json", StringComparison.OrdinalIgnoreCase));

    private static string ReadEmbedded(string name)
    {
        using var s = typeof(L).Assembly.GetManifestResourceStream(name) ?? throw new FileNotFoundException(name);
        using var r = new StreamReader(s);
        return r.ReadToEnd();
    }
}
