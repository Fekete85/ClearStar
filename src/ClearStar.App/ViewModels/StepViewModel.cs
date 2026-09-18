using System.Collections.ObjectModel;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace ClearStar.App.ViewModels;

public sealed class GroupHeaderViewModel(string name)
{
    public string Name { get; } = name;
}

/// <summary>Egy lépés kártyája a bal oldali listában.</summary>
public partial class StepViewModel : ObservableObject
{
    private readonly MainViewModel _owner;
    public WorkflowEntry Entry { get; }
    public StepDefinition Definition => Entry.Definition;
    public StepId Id => Entry.Id;

    public int Number => Definition.Number;
    public string Name => Definition.Name;
    public string? TechnicalName => Definition.TechnicalName is { } t ? $"({t})" : null;
    public string Description => Definition.Description;
    public string IconKey => $"I.{Id}";
    public bool IsImplemented => Entry.Step.IsImplemented;
    public bool CanSkip => Id is not (StepId.LoadFrames or StepId.Stack or StepId.Save);

    public ObservableCollection<ParameterViewModel> Parameters { get; }
    public IEnumerable<ParameterViewModel> BasicParameters => Parameters.Where(p => !p.IsAdvanced && !p.IsHidden);
    public IEnumerable<ParameterViewModel> AdvancedParameters => Parameters.Where(p => p.IsAdvanced && !p.IsHidden);
    public bool HasAdvanced => Parameters.Any(p => p.IsAdvanced);
    public bool HasParameters => Parameters.Any(p => !p.IsHidden);

    /// <summary>Kiegészítő sor a kártyán (pl. a vágás aktuális kijelölése) és egy hozzá tartozó művelet.</summary>
    [ObservableProperty] private string? _note;
    [ObservableProperty] private string? _noteActionText;
    /// <summary>Optional second action shown as a prominent button under the parameters (e.g. "Auto stretch").</summary>
    [ObservableProperty] private string? _secondaryActionText;
    [ObservableProperty] private IRelayCommand? _secondaryCommand;
    [ObservableProperty] private IRelayCommand? _noteCommand;

    [ObservableProperty] private bool _isActive;
    [ObservableProperty] private bool _showAdvanced;
    [ObservableProperty] private StepState _state;
    [ObservableProperty] private string? _summary;

    public StepViewModel(MainViewModel owner, WorkflowEntry entry)
    {
        _owner = owner;
        Entry = entry;
        Parameters = new ObservableCollection<ParameterViewModel>(
            entry.Definition.Parameters.Select(d => ParameterViewModel.Create(d, entry.Parameters)));
        Refresh();
    }

    public void Refresh()
    {
        State = Entry.State;
        Summary = Entry.Summary;
        OnPropertyChanged(nameof(IsDone));
        OnPropertyChanged(nameof(IsSkipped));
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(IsPending));
        OnPropertyChanged(nameof(MetaText));
        OnPropertyChanged(nameof(PrimaryButtonText));
    }

    public bool IsDone => State == StepState.Done;
    public bool IsSkipped => State == StepState.Skipped;
    public bool IsStale => State == StepState.Stale;
    public bool IsPending => State == StepState.Pending;

    /// <summary>A fejléc jobb oldalán megjelenő rövid szöveg.</summary>
    public string? MetaText => State switch
    {
        StepState.Skipped => L.T("ui.step.skipped"),
        StepState.Stale => L.T("ui.step.stale"),
        StepState.Done => Summary,
        _ => null,
    };

    public string PrimaryButtonText => Id switch
    {
        StepId.LoadFrames => L.T("ui.step.btnLoad"),
        StepId.Stack => L.T("ui.step.btnStack"),
        StepId.Save => L.T("ui.step.btnSave"),
        _ => L.T(State == StepState.Done ? "ui.step.btnReapply" : "ui.step.btnApply"),
    };

    [RelayCommand]
    private void Select() => _owner.SelectStep(this);

    [RelayCommand]
    private Task Apply() => _owner.ApplyAsync(this);

    [RelayCommand(CanExecute = nameof(CanSkip))]
    private void Skip() => _owner.Skip(this);

    [RelayCommand]
    private void ResetParameters()
    {
        foreach (var p in Parameters) p.Reset();
        _owner.OnParametersReset(this);
    }

    [RelayCommand]
    private void ToggleAdvanced() => ShowAdvanced = !ShowAdvanced;
}
