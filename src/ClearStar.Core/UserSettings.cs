using System.Text.Json;

namespace ClearStar.Core;

/// <summary>Kulcs-erteek beallitasok a %LOCALAPPDATA%\ClearStar\settings.json fajlban (nyelv, modellvalasztas...).</summary>
public static class UserSettings
{
    public const string LanguageKey = "language";

    public static string Path { get; } =
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClearStar", "settings.json");

    public static string? Get(string key) => Load().TryGetValue(key, out var v) ? v : null;

    public static void Set(string key, string? value)
    {
        var s = Load();
        if (value is null) s.Remove(key); else s[key] = value;
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        File.WriteAllText(Path, JsonSerializer.Serialize(s, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static Dictionary<string, string> Load()
    {
        try
        {
            if (File.Exists(Path))
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path)) ?? new();
        }
        catch (Exception ex) when (ex is IOException or JsonException) { }
        return new();
    }
}
