using ClearStar.Core.Imaging;
using ClearStar.Core.IO;

using ClearStar.Core.Localization;

namespace ClearStar.Core.Pipeline;

public enum StepState
{
    /// <summary>Még nem futott.</summary>
    Pending,
    /// <summary>Lefutott, az eredménye érvényes.</summary>
    Done,
    /// <summary>A felhasználó átugrotta.</summary>
    Skipped,
    /// <summary>Lefutott, de egy korábbi lépés azóta változott – újra kell futtatni.</summary>
    Stale,
}

public readonly record struct ProgressInfo(double Fraction, string Message);

/// <summary>Amit egy lépés a futásához kap: a bemeneti kép és a betöltött fájlok.</summary>
public sealed class WorkflowContext
{
    public required AstroImage? Input { get; init; }
    public required FrameSet? Frames { get; init; }
    public required StepParameters Parameters { get; init; }
    public IProgress<ProgressInfo>? Progress { get; init; }
    public CancellationToken CancellationToken { get; init; }

    public AstroImage RequireInput() =>
        Input ?? throw new InvalidOperationException(L.T("msg.workflow.needImage"));

    public void Report(double fraction, string message) => Progress?.Report(new ProgressInfo(fraction, message));
}

/// <summary>
/// Egy lépés eredménye: az új kép (vagy null, ha a lépés nem képet állít elő), egy rövid összefoglaló,
/// és opcionálisan képenkénti megjegyzések (fájl → állapot, pl. "igazítva" / "kihagyva").
/// </summary>
public sealed record StepResult(AstroImage? Image, string Summary, FrameSet? Frames = null, IReadOnlyDictionary<string, FrameNote>? FrameNotes = null)
{
    public static StepResult Unchanged(AstroImage image, string summary) => new(image, summary);
}

/// <summary>Egy workflow-lépés végrehajtója. A lépés nem módosíthatja a bemeneti képet.</summary>
public interface IWorkflowStep
{
    StepDefinition Definition { get; }

    /// <summary>Igaz, ha a lépés valóban csinál valamit (a még el nem készült lépések átengedik a képet).</summary>
    bool IsImplemented => true;

    Task<StepResult> RunAsync(WorkflowContext context);
}

/// <summary>
/// Egy bemeneti kép sorsa és minősége az összeillesztésben. A mérőszámok időrendben kirajzolva
/// megmutatják, ha az éjszaka során romlott az ég (felhő, pára, zenit közeli forgás, fényszennyezés).
/// </summary>
public sealed record FrameNote(bool Used, string Text, int? Stars = null, float? StarSize = null, float? Background = null, float? Angle = null);
