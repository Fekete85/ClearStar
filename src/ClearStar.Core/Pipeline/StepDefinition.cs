using ClearStar.Core.Localization;

namespace ClearStar.Core.Pipeline;

/// <summary>A 16 workflow-lépés azonosítója, a feldolgozási sorrendben.</summary>
public enum StepId
{
    LoadFrames = 1,
    Stack = 2,
    Crop = 3,
    BackgroundExtraction = 4,
    Deconvolution = 5,
    Denoise = 6,
    PlateSolve = 7,
    ColorCalibration = 8,
    StarRemoval = 9,
    StarlessStretch = 10,
    StarStretch = 11,
    GreenRemoval = 12,
    ChromaticAberration = 13,
    Contrast = 14,
    Saturation = 15,
    Save = 16,
}

public enum StepGroup { Preparation, Basics, Stars, Refinement, Finish }

public enum ParameterKind { Slider, Toggle, Choice, Folder, Text, Hidden, Model }

/// <summary>
/// Egy beállítás leírása a felület számára. A feliratok a nyelvi adatbázisból jönnek
/// (<see cref="L"/>), a csúszkák "Gyenge – Közepes – Erős" jellegű feliratokat kapnak (TickLabels),
/// a nyers számot a kezdő nem látja. A választólista értékei (Choices) nyelvfüggetlen kulcsok,
/// a hozzájuk tartozó feliratok a ChoiceLabels.
/// </summary>
public sealed record ParameterDefinition(
    string Key,
    string Label,
    ParameterKind Kind,
    object Default,
    double Min = 0,
    double Max = 1,
    string[]? TickLabels = null,
    string[]? Choices = null,
    bool Advanced = false,
    string? Help = null,
    string? Tag = null,
    string[]? ChoiceLabels = null,
    string? ValueFormat = null)
{
    /// <summary>Egy választóérték felirata (ha nincs, maga az érték).</summary>
    public string LabelFor(string choice)
    {
        if (Choices is null || ChoiceLabels is null) return choice;
        int i = Array.IndexOf(Choices, choice);
        return i >= 0 && i < ChoiceLabels.Length ? ChoiceLabels[i] : choice;
    }
}

/// <summary>Egy lépés statikus leírása: név, csoport, közérthető magyarázat, paraméterek.</summary>
public sealed record StepDefinition(
    StepId Id,
    StepGroup Group,
    string Name,
    string? TechnicalName,
    string Description,
    IReadOnlyList<ParameterDefinition> Parameters)
{
    public int Number => (int)Id;

    /// <summary>Definíció a nyelvi adatbázisból: step.&lt;key&gt;.name / .tech / .desc.</summary>
    public static StepDefinition FromLanguage(StepId id, StepGroup group, string key, IReadOnlyList<ParameterDefinition> parameters) =>
        new(id, group, L.T($"step.{key}.name"), L.Has($"step.{key}.tech") ? L.T($"step.{key}.tech") : null, L.T($"step.{key}.desc"), parameters);

    public static string GroupName(StepGroup g) => L.T($"group.{g}");
}
