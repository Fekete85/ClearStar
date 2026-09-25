using System.Text.RegularExpressions;

namespace ClearStar.Core.IO;

/// <summary>Guesses the imaged object's name for pre-filling the plate-solve step.</summary>
public static partial class ObjectNameGuess
{
    // Catalogue designations such as "NGC6992", "M 31", "IC_1396", "Sh2-101" – also inside folder names
    // like "NGC6992_0905" (underscore and digits around the designation are allowed).
    [GeneratedRegex(@"(?<![A-Za-z])(M|NGC|IC|Sh2|SH2|Abell|Barnard|Cr|Mel|Tr|LDN|LBN|vdB|Ced|PK|Arp|UGC|PGC)[ _\-]?(\d+[A-Za-z]?)(?![A-Za-z0-9])", RegexOptions.IgnoreCase)]
    private static partial Regex Designation();

    /// <summary>The OBJECT keyword of the first light frame, otherwise a catalogue designation found in the folder name.</summary>
    public static string? From(FrameSet frames)
    {
        var fromHeader = frames.Lights.Select(f => f.ObjectName).FirstOrDefault(n => !string.IsNullOrWhiteSpace(n));
        if (fromHeader is not null) return fromHeader;
        return FromText(Path.GetFileName(frames.Folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)));
    }

    public static string? FromText(string text)
    {
        var m = Designation().Match(text);
        if (!m.Success) return null;
        string cat = m.Groups[1].Value.ToUpperInvariant();
        if (cat == "SH2") return $"Sh2-{m.Groups[2].Value}";
        if (cat == "VDB") cat = "vdB";
        else if (cat is "ABELL" or "BARNARD") cat = cat[0] + cat[1..].ToLowerInvariant();
        else if (cat is "MEL" or "CED" or "TR" or "CR") cat = cat[0] + cat[1..].ToLowerInvariant();
        return $"{cat} {m.Groups[2].Value}";
    }
}
