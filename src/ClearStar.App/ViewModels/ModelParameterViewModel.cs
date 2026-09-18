using System.Collections.ObjectModel;
using System.Net.Http;
using ClearStar.Core.AI;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace ClearStar.App.ViewModels;

/// <summary>
/// AI-modell választó: a gépen talált (ClearStar / GraXpert) modellek listája, frissítés, tallózás,
/// letöltés URL-ről. Az üres érték = a legfrissebb elérhető modell; a választás a beállításokba kerül.
/// </summary>
public partial class ModelParameterViewModel : ParameterViewModel
{
    public AiModelKind ModelKind { get; }
    public ObservableCollection<ModelChoice> Choices { get; } = [];

    [ObservableProperty] private ModelChoice? _selected;
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private bool _isMissing;
    [ObservableProperty] private bool _isDownloading;
    [ObservableProperty] private double _downloadProgress;

    public sealed record ModelChoice(string Label, string Path);

    public ModelParameterViewModel(ParameterDefinition d, StepParameters p) : base(d, p)
    {
        ModelKind = Enum.TryParse<AiModelKind>(d.Tag, out var k) ? k : AiModelKind.BackgroundExtraction;
        Refresh();
    }

    partial void OnSelectedChanged(ModelChoice? value)
    {
        if (value is null) return;
        Parameters[Key] = value.Path;
        AiModelStore.SetPreferred(ModelKind, value.Path.Length == 0 ? null : value.Path);
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        var resolved = AiModelStore.Resolve(ModelKind);
        IsMissing = resolved is null;
        StatusText = resolved is null
            ? L.T("ui.model.missing")
            : L.F("ui.model.using", resolved.Version, resolved.Source);
    }

    public override void Reset()
    {
        Parameters[Key] = "";
        Refresh();
    }

    [RelayCommand]
    public void Refresh()
    {
        string current = Parameters[Key]?.ToString() ?? "";
        Choices.Clear();
        Choices.Add(new ModelChoice(L.T("ui.model.auto"), ""));
        foreach (var m in AiModelStore.ListAvailable(ModelKind))
            Choices.Add(new ModelChoice(L.F("ui.model.fromFolder", m.Version, m.Source), m.Path));
        if (current.Length > 0 && Choices.All(c => c.Path != current) && File.Exists(current))
            Choices.Add(new ModelChoice(L.F("ui.model.ownFile", System.IO.Path.GetFileName(current)), current));
        Selected = Choices.FirstOrDefault(c => c.Path == current) ?? Choices[0];
        UpdateStatus();
    }

    [RelayCommand]
    private void Browse()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = L.F("ui.model.pickTitle", AiModelStore.KindName(ModelKind)),
            Filter = L.T("ui.model.pickFilter"),
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            var info = AiModelStore.Import(ModelKind, dialog.FileName);
            Parameters[Key] = info.Path;
            Refresh();
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            StatusText = L.F("ui.model.loadFailed", ex.Message);
        }
    }

    [RelayCommand]
    private async Task DownloadAsync()
    {
        string? url = Views.TextPromptWindow.Show(L.T("ui.model.downloadTitle"), L.T("ui.model.downloadPrompt"), "https://");
        if (string.IsNullOrWhiteSpace(url) || url.Trim() == "https://") return;
        IsDownloading = true;
        DownloadProgress = 0;
        StatusText = L.T("ui.model.downloading");
        try
        {
            var info = await AiModelStore.DownloadAsync(ModelKind, url.Trim(), new Progress<double>(p => DownloadProgress = p));
            Parameters[Key] = info.Path;
            Refresh();
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidOperationException or TaskCanceledException or UriFormatException)
        {
            StatusText = L.F("ui.model.downloadFailed", ex.Message);
        }
        finally { IsDownloading = false; }
    }
}
