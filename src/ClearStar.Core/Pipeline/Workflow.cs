using ClearStar.Core.Imaging;
using ClearStar.Core.IO;

using ClearStar.Core.Localization;

namespace ClearStar.Core.Pipeline;

/// <summary>Egy lépés futásidejű állapota a workflow-ban.</summary>
public sealed class WorkflowEntry
{
    public IWorkflowStep Step { get; }
    public StepDefinition Definition => Step.Definition;
    public StepId Id => Definition.Id;
    public StepParameters Parameters { get; }
    public StepState State { get; internal set; } = StepState.Pending;
    public string? Summary { get; internal set; }
    public TimeSpan? LastDuration { get; internal set; }
    /// <summary>Amivel legutóbb lefutott – ebből látszik, változott-e azóta a beállítás.</summary>
    public StepParameters? AppliedParameters { get; internal set; }

    internal WorkflowEntry(IWorkflowStep step)
    {
        Step = step;
        Parameters = new StepParameters(step.Definition.Parameters);
    }

    public bool HasUnappliedChanges => State == StepState.Done && AppliedParameters is not null && !AppliedParameters.ValuesEqual(Parameters);
}

/// <summary>
/// A 17 lépéses vezetett folyamat motorja: sorban futtatja a lépéseket, minden lépés
/// eredményét elmenti, és tudja, melyik lépés eredménye avult el egy korábbi újrafuttatása miatt.
/// </summary>
public sealed class Workflow : IDisposable
{
    private readonly SnapshotStore _snapshots;
    private readonly Dictionary<StepId, WorkflowEntry> _entries;

    public IReadOnlyList<WorkflowEntry> Steps { get; }
    public FrameSet? Frames { get; private set; }

    /// <summary>Akkor sül el, ha bármelyik lépés állapota vagy eredménye változott.</summary>
    public event Action? Changed;

    public Workflow(IEnumerable<IWorkflowStep> steps, SnapshotStore? snapshots = null)
    {
        _snapshots = snapshots ?? new SnapshotStore();
        Steps = steps.Select(s => new WorkflowEntry(s)).OrderBy(e => e.Id).ToList();
        _entries = Steps.ToDictionary(e => e.Id);
        if (Steps.Count == 0) throw new ArgumentException(L.T("msg.workflow.oneStep"), nameof(steps));
    }

    public WorkflowEntry this[StepId id] => _entries[id];

    /// <summary>A kiindulási kép: az összeillesztés (vagy egyetlen betöltött kép) eredménye.</summary>
    public AstroImage? Original => FirstImageStep() is { } id ? _snapshots.Get((int)id) : null;

    public bool HasImage => Original is not null;

    /// <summary>A legutolsó érvényes (Done) lépés képe – ez a "jelenlegi" kép.</summary>
    public AstroImage? Current => LatestDoneImageStep(StepId.Save) is { } id ? _snapshots.Get((int)id) : null;

    /// <summary>A kép, ahogy az adott lépés UTÁN kinézett (vagy a legutóbbi érvényes korábbi lépés után, ha ez nem futott).</summary>
    public AstroImage? ImageAfter(StepId id) => LatestDoneImageStep(id + 1) is { } d ? _snapshots.Get((int)d) : null;

    /// <summary>A kép, amit az adott lépés bemenetként kapna.</summary>
    public AstroImage? ImageBefore(StepId id) => LatestDoneImageStep(id) is { } d ? _snapshots.Get((int)d) : null;

    /// <summary>A lineáris fázisban (a nyújtás előtt) a képernyőn automatikus nyújtással érdemes nézni a képet.</summary>
    public static bool IsLinearPhase(StepId id) => id < StepId.StarlessStretch;

    /// <summary>A következő teendő: az első lépés, ami se kész, se kihagyott.</summary>
    public StepId NextPending => Steps.FirstOrDefault(e => e.State is StepState.Pending or StepState.Stale)?.Id ?? StepId.Save;

    public int DoneCount => Steps.Count(e => e.State is StepState.Done or StepState.Skipped);

    public async Task<StepResult> RunAsync(StepId id, IProgress<ProgressInfo>? progress = null, CancellationToken ct = default)
    {
        var entry = _entries[id];
        var context = new WorkflowContext
        {
            Input = id == StepId.LoadFrames ? null : ImageBefore(id),
            Frames = Frames,
            Parameters = entry.Parameters.Clone(),
            Progress = progress,
            CancellationToken = ct,
        };
        if (id > StepId.Stack && context.Input is null)
            throw new InvalidOperationException(L.T("msg.workflow.needStack"));

        var started = DateTime.UtcNow;
        var result = await entry.Step.RunAsync(context).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();

        if (result.Frames is not null) Frames = result.Frames;
        if (result.Image is not null) _snapshots.Put((int)id, result.Image);
        else _snapshots.Remove((int)id);

        entry.State = StepState.Done;
        entry.Summary = result.Summary;
        entry.LastDuration = DateTime.UtcNow - started;
        entry.AppliedParameters = context.Parameters;

        // A közbenső, elavult lépések eredménye már nem része a láncnak: kihagyottnak jelöljük.
        foreach (var e in Steps.Where(e => e.Id < id && e.State == StepState.Stale))
        {
            e.State = StepState.Skipped;
            _snapshots.Remove((int)e.Id);
        }
        InvalidateAfter(id);
        Changed?.Invoke();
        return result;
    }

    public void Skip(StepId id)
    {
        if (id is StepId.LoadFrames or StepId.Stack)
            throw new InvalidOperationException(L.T("msg.workflow.cannotSkip"));
        var entry = _entries[id];
        bool hadImage = _snapshots.Contains((int)id);
        entry.State = StepState.Skipped;
        entry.Summary = null;
        entry.AppliedParameters = null;
        _snapshots.Remove((int)id);
        if (hadImage) InvalidateAfter(id);
        Changed?.Invoke();
    }

    /// <summary>Kihagyott vagy elavult lépés visszaállítása "teendő" állapotba (nem futtatja).</summary>
    public void Reopen(StepId id)
    {
        var entry = _entries[id];
        if (entry.State is StepState.Skipped or StepState.Stale)
        {
            entry.State = StepState.Pending;
            Changed?.Invoke();
        }
    }

    public void Reset()
    {
        foreach (var e in Steps)
        {
            e.State = StepState.Pending;
            e.Summary = null;
            e.AppliedParameters = null;
        }
        Frames = null;
        _snapshots.Clear();
        Changed?.Invoke();
    }

    private void InvalidateAfter(StepId id)
    {
        foreach (var e in Steps.Where(e => e.Id > id && e.State == StepState.Done))
        {
            e.State = StepState.Stale;
            _snapshots.Remove((int)e.Id);
        }
    }

    private StepId? FirstImageStep()
    {
        foreach (var e in Steps)
            if (e.State == StepState.Done && _snapshots.Contains((int)e.Id)) return e.Id;
        return null;
    }

    /// <summary>A legutolsó Done lépés, amelynek van képe és az azonosítója kisebb, mint a megadott.</summary>
    private StepId? LatestDoneImageStep(StepId before)
    {
        for (int i = Steps.Count - 1; i >= 0; i--)
        {
            var e = Steps[i];
            if (e.Id < before && e.State == StepState.Done && _snapshots.Contains((int)e.Id)) return e.Id;
        }
        return null;
    }

    public void Dispose() => _snapshots.Dispose();
}
