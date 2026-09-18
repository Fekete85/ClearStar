using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media.Imaging;
using ClearStar.App.Services;
using ClearStar.Core;
using ClearStar.Core.Imaging;
using ClearStar.Core.IO;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;
using ClearStar.Core.Steps;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace ClearStar.App.ViewModels;

public sealed partial class FrameItemViewModel : ObservableObject
{
    private readonly MainViewModel _owner;
    public FrameInfo Info { get; }
    public string Path => Info.Path;
    public string FileName => Info.FileName;
    public string TypeName { get; }
    public string Detail { get; }

    /// <summary>Az összeillesztés eredménye erre a képre (null, amíg nem futott).</summary>
    [ObservableProperty] private string? _status;
    [ObservableProperty] private bool? _isUsed;
    public int? Stars { get; set; }
    public float? StarSize { get; set; }
    public float? Background { get; set; }
    public float? Angle { get; set; }

    public FrameItemViewModel(MainViewModel owner, FrameInfo info)
    {
        _owner = owner;
        Info = info;
        TypeName = info.Type switch
        {
            FrameType.Light => L.T("ui.frames.typeLight"),
            FrameType.Dark => L.T("ui.frames.typeDark"),
            FrameType.Flat => L.T("ui.frames.typeFlat"),
            FrameType.Bias => L.T("ui.frames.typeBias"),
            _ => "?",
        };
        Detail = info.ExposureSeconds > 0 ? L.F("ui.frames.seconds", info.ExposureSeconds) : "";
    }

    [RelayCommand]
    private Task Preview() => _owner.PreviewFrameAsync(this);
}

public partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly Workflow _workflow;
    private CancellationTokenSource? _cts;
    private CancellationTokenSource? _previewCts;

    public ObservableCollection<object> SidebarItems { get; } = [];
    public ObservableCollection<StepViewModel> Steps { get; } = [];
    public ObservableCollection<FrameItemViewModel> Frames { get; } = [];

    [ObservableProperty] private StepViewModel? _selectedStep;
    [ObservableProperty] private BitmapSource? _previewImage;
    [ObservableProperty] private BitmapSource? _beforeImage;
    [ObservableProperty] private bool _hasImage;
    [ObservableProperty] private bool _hasFrames;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private double _progress;
    [ObservableProperty] private string _statusText = L.T("ui.status.noImage");
    [ObservableProperty] private string _imageInfo = "";
    [ObservableProperty] private bool _isError;
    [ObservableProperty] private bool _showOriginal;
    [ObservableProperty] private bool _splitView;
    [ObservableProperty] private bool _autoStretch = true;
    [ObservableProperty] private bool _showWelcome = true;
    [ObservableProperty] private int _doneCount;
    [ObservableProperty] private string _encouragement = "";
    [ObservableProperty] private string _windowTitle = L.T("ui.app.title");
    [ObservableProperty] private bool _isSelectionMode;
    [ObservableProperty] private Rect _selection = Rect.Empty;
    [ObservableProperty] private double _previewScale = 1.0;

    public int TotalSteps => Steps.Count;
    public double ProgressFraction => TotalSteps == 0 ? 0 : DoneCount / (double)TotalSteps;

    public MainViewModel()
    {
        _workflow = StepCatalog.CreateWorkflow();
        _workflow.Changed += OnWorkflowChanged;
        InitStretchPreset();

        StepGroup? group = null;
        foreach (var entry in _workflow.Steps)
        {
            if (entry.Definition.Group != group)
            {
                group = entry.Definition.Group;
                SidebarItems.Add(new GroupHeaderViewModel(StepDefinition.GroupName(group.Value)));
            }
            var vm = new StepViewModel(this, entry);
            Steps.Add(vm);
            SidebarItems.Add(vm);
        }
        SelectStep(Steps[0]);

        // A vágás csúszkája élőben állítja a kijelölést (arányos szegély minden oldalon).
        var cropStep = Steps.First(s => s.Id == StepId.Crop);
        if (cropStep.Parameters.OfType<SliderParameterViewModel>().FirstOrDefault(p => p.Key == CropStep.MarginKey) is { } margin)
        {
            margin.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName != nameof(SliderParameterViewModel.Value) || SelectedStep?.Id != StepId.Crop) return;
                // A csúszka a lefedett téglalaphoz képest vág (nem a teljes képhez, amiben üres sarkok vannak).
                double m = margin.Value;
                var b = _cropBase;
                Selection = new Rect(b.X + m * b.Width, b.Y + m * b.Height, b.Width * (1 - 2 * m), b.Height * (1 - 2 * m));
            };
        }
    }

    private void OnWorkflowChanged()
    {
        foreach (var s in Steps) s.Refresh();
        DoneCount = _workflow.DoneCount;
        OnPropertyChanged(nameof(ProgressFraction));
        HasImage = _workflow.HasImage;
        int remaining = TotalSteps - DoneCount;
        Encouragement = DoneCount == 0 ? "" : remaining switch
        {
            0 => L.T("ui.status.allDone"),
            1 => L.T("ui.status.lastStep"),
            <= 5 => L.F("ui.status.fewLeft", remaining),
            _ => L.F("ui.status.progress", DoneCount),
        };
    }

    public void SelectStep(StepViewModel step)
    {
        IsFramePreview = false;
        _previewedFrame = null;
        if (SelectedStep is not null) SelectedStep.IsActive = false;
        SelectedStep = step;
        step.IsActive = true;
        // Lineáris fázisban automatikusan felerősítjük az előnézetet, utána már a valódi képet mutatjuk.
        AutoStretch = step.IsDone ? Workflow.IsLinearPhase(step.Id) : step.Id <= StepId.StarlessStretch;
        // Vágásnál a kép a kijelölés vászna: a bemeneti (még vágatlan) képet mutatjuk, rajta a kijelöléssel.
        IsSelectionMode = step.Id == StepId.Crop;
        if (IsSelectionMode) LoadCropSelection(step); else Selection = Rect.Empty;
        UpdateFramesView(step);
        RefreshPreview();
    }

    /// <summary>A vágás kiindulási téglalapja: a stackelt kép adatokkal lefedett része (vagy a teljes kép).</summary>
    private Rect _cropBase = new(0, 0, 1, 1);
    private AstroImage? _cropBaseImage;

    private void LoadCropSelection(StepViewModel step)
    {
        step.NoteCommand ??= new RelayCommand(() => Selection = _cropBase);
        var img = _workflow.ImageBefore(StepId.Crop);
        var p = step.Entry.Parameters;
        if (CropStep.HasSelection(p))
        {
            Selection = new Rect(p.GetDouble(CropStep.SelLeftKey), p.GetDouble(CropStep.SelTopKey), p.GetDouble(CropStep.SelWidthKey), p.GetDouble(CropStep.SelHeightKey));
            if (ReferenceEquals(img, _cropBaseImage)) { UpdateCropNote(step); return; }
        }
        if (img is null) { Selection = Rect.Empty; UpdateCropNote(step); return; }
        if (ReferenceEquals(img, _cropBaseImage)) { if (Selection.IsEmpty) Selection = _cropBase; UpdateCropNote(step); return; }

        // A lefedett téglalap kiszámítása háttérszálon (nagy képen ~0,1–0,3 s).
        _cropBaseImage = img;
        step.Note = L.T("ui.crop.computing");
        _ = Task.Run(() => Coverage.LargestFilledRectangle(img)).ContinueWith(t =>
        {
            if (!ReferenceEquals(img, _cropBaseImage)) return;
            _cropBase = t.IsCompletedSuccessfully && t.Result is { } r ? new Rect(r.X, r.Y, r.W, r.H) : new Rect(0, 0, 1, 1);
            if (SelectedStep?.Id == StepId.Crop && Selection.IsEmpty) Selection = _cropBase;
            if (SelectedStep?.Id == StepId.Crop) UpdateCropNote(step);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void UpdateCropNote(StepViewModel step)
    {
        var img = _workflow.ImageBefore(StepId.Crop);
        if (Selection.IsEmpty || img is null)
        {
            step.Note = L.T("ui.crop.noSelection");
            step.NoteActionText = _cropBase.Width < 1 ? L.T("ui.crop.covered") : null;
            return;
        }
        bool isBase = Math.Abs(Selection.X - _cropBase.X) < 1e-6 && Math.Abs(Selection.Y - _cropBase.Y) < 1e-6
            && Math.Abs(Selection.Width - _cropBase.Width) < 1e-6 && Math.Abs(Selection.Height - _cropBase.Height) < 1e-6;
        step.Note = L.F("ui.crop.selection", Math.Round(Selection.Width * img.Width), Math.Round(Selection.Height * img.Height))
            + (isBase && _cropBase.Width < 1 ? L.T("ui.crop.noCorners") : "");
        step.NoteActionText = L.T(isBase ? "ui.crop.clear" : "ui.crop.covered");
        if (isBase) step.NoteCommand = new RelayCommand(() => Selection = Rect.Empty);
        else step.NoteCommand = new RelayCommand(() => Selection = _cropBase);
    }

    partial void OnSelectionChanged(Rect value)
    {
        if (SelectedStep is not { Id: StepId.Crop } step) return;
        var p = step.Entry.Parameters;
        p[CropStep.SelLeftKey] = value.IsEmpty ? 0.0 : value.X;
        p[CropStep.SelTopKey] = value.IsEmpty ? 0.0 : value.Y;
        p[CropStep.SelWidthKey] = value.IsEmpty ? 0.0 : value.Width;
        p[CropStep.SelHeightKey] = value.IsEmpty ? 0.0 : value.Height;
        UpdateCropNote(step);
    }

    public void OnParametersReset(StepViewModel step)
    {
        if (step.Id == StepId.Crop) Selection = _cropBase;
    }

    public async Task ApplyAsync(StepViewModel step)
    {
        if (IsBusy) return;
        _cts = new CancellationTokenSource();
        IsBusy = true;
        IsError = false;
        Progress = 0;
        StatusText = L.F("ui.status.running", step.Name);
        var progress = new Progress<ProgressInfo>(p =>
        {
            Progress = p.Fraction;
            StatusText = p.Message;
        });
        try
        {
            var result = await _workflow.RunAsync(step.Id, progress, _cts.Token);
            if (result.Frames is not null) LoadFrames(result.Frames);
            if (result.FrameNotes is { } notes)
                foreach (var item in Frames)
                    if (notes.TryGetValue(item.Path, out var note))
                    {
                        item.Status = note.Text; item.IsUsed = note.Used;
                        item.Stars = note.Stars; item.StarSize = note.StarSize; item.Background = note.Background; item.Angle = note.Angle;
                    }
            if (result.FrameNotes is not null) { HasQuality = Frames.Any(f => f.Stars is not null); QualityVersion++; if (SelectedStep is { } s) UpdateFramesView(s); }
            ShowWelcome = false;
            StatusText = L.F("ui.status.done", step.Name, result.Summary);
            UpdateImageInfo();
            var next = Steps.FirstOrDefault(s => s.Id == _workflow.NextPending);
            if (next is not null && next.Id > step.Id) SelectStep(next);
            else RefreshPreview();
        }
        catch (OperationCanceledException)
        {
            StatusText = L.T("ui.status.cancelled");
        }
        catch (Exception ex)
        {
            IsError = true;
            StatusText = ex.Message;
        }
        finally
        {
            IsBusy = false;
            Progress = 0;
            _cts.Dispose();
            _cts = null;
        }
    }

    public void Skip(StepViewModel step)
    {
        try
        {
            _workflow.Skip(step.Id);
            var next = Steps.FirstOrDefault(s => s.Id == _workflow.NextPending);
            if (next is not null) SelectStep(next);
        }
        catch (InvalidOperationException ex)
        {
            IsError = true;
            StatusText = ex.Message;
        }
    }

    [RelayCommand]
    private void Cancel() => _cts?.Cancel();

    [RelayCommand]
    private void CloseWelcome() => ShowWelcome = false;

    [RelayCommand]
    private void ShowAbout() => Views.AboutWindow.ShowDialog(System.Windows.Application.Current.MainWindow);

    partial void OnShowOriginalChanged(bool value) => RefreshPreview();
    // ----- Screen-stretch presets (toolbar toggle + dropdown), persisted in the settings -----
    public sealed record StretchPresetItem(string Key, string Label);
    public IReadOnlyList<StretchPresetItem> StretchPresets { get; } =
        DisplayStretch.Presets.Select(p => new StretchPresetItem(p.Key, L.T("ui.stretch." + p.Key))).ToList();
    [ObservableProperty] private StretchPresetItem? _selectedStretchPreset;
    [ObservableProperty] private bool _isStretchMenuOpen;
    private string _lastStretchKey = DisplayStretch.DefaultPresetKey;
    private const string StretchSettingKey = "preview.stretch";

    private void InitStretchPreset()
    {
        var preset = DisplayStretch.PresetByKey(UserSettings.Get(StretchSettingKey));
        _lastStretchKey = preset.Key;
        PreviewRenderer.Preset = preset;
        SelectedStretchPreset = StretchPresets.First(i => i.Key == preset.Key);
    }

    partial void OnSelectedStretchPresetChanged(StretchPresetItem? value)
    {
        if (value is null) return;
        IsStretchMenuOpen = false;
        if (value.Key == "off") { AutoStretch = false; return; }
        _lastStretchKey = value.Key;
        PreviewRenderer.Preset = DisplayStretch.PresetByKey(value.Key);
        UserSettings.Set(StretchSettingKey, value.Key);
        if (!AutoStretch) AutoStretch = true; else RefreshPreview();
    }

    partial void OnAutoStretchChanged(bool value)
    {
        // Keep the dropdown in sync: off ↔ the last chosen strength.
        string wanted = value ? _lastStretchKey : "off";
        if (SelectedStretchPreset?.Key != wanted) SelectedStretchPreset = StretchPresets.First(i => i.Key == wanted);
        RefreshPreview();
    }

    partial void OnSplitViewChanged(bool value) => RefreshPreview();

    // ----- Képlista-nézet (1–2. lépés) -----
    [ObservableProperty] private BitmapSource? _stackThumbnail;
    [ObservableProperty] private bool _isStackView;
    [ObservableProperty] private bool _isFramesView;
    [ObservableProperty] private string _framesTitle = L.T("ui.frames.loadedTitle");
    [ObservableProperty] private string _framesSubtitle = "";

    public bool ShowQuality => HasQuality && IsStackView;
    public bool CanCompare => HasImage && !IsFramesView;

    partial void OnHasQualityChanged(bool value) => OnPropertyChanged(nameof(ShowQuality));
    partial void OnIsStackViewChanged(bool value) => OnPropertyChanged(nameof(ShowQuality));
    partial void OnIsFramesViewChanged(bool value) => OnPropertyChanged(nameof(CanCompare));
    partial void OnHasImageChanged(bool value) => OnPropertyChanged(nameof(CanCompare));

    private void UpdateFramesView(StepViewModel step)
    {
        IsStackView = step.Id == StepId.Stack;
        IsFramesView = step.Id is StepId.LoadFrames or StepId.Stack;
        FramesTitle = L.T(IsStackView ? "ui.frames.stackTitle" : "ui.frames.loadedTitle");
        FramesSubtitle = IsStackView
            ? L.T(HasQuality ? "ui.frames.stackedSub" : "ui.frames.stackSub")
            : L.T("ui.frames.loadedSub");
    }

    private void RefreshStackThumbnail(CancellationToken ct)
    {
        var stack = _workflow.ImageAfter(StepId.Stack);
        if (!IsStackView || stack is null) { StackThumbnail = null; return; }
        if (ReferenceEquals(stack, _thumbnailSource) && StackThumbnail is not null) return;
        _thumbnailSource = stack;
        _ = Task.Run(() => PreviewRenderer.Render(stack, autoStretch: true, ct, maxWidth: 900), ct)
            .ContinueWith(t =>
            {
                if (t.IsCompletedSuccessfully && !ct.IsCancellationRequested) StackThumbnail = t.Result.ToBitmap();
            }, TaskScheduler.FromCurrentSynchronizationContext());
    }
    private AstroImage? _thumbnailSource;

    [RelayCommand]
    private void GoToCrop() => SelectStep(Steps.First(s => s.Id == StepId.Crop));

    // ----- Egyetlen nyers kép előnézete a betöltött képek listájából -----
    [ObservableProperty] private bool _hasQuality;
    [ObservableProperty] private int _qualityVersion;
    [ObservableProperty] private bool _isFramePreview;
    [ObservableProperty] private string _framePreviewTitle = "";
    private FrameItemViewModel? _previewedFrame;

    public async Task PreviewFrameAsync(FrameItemViewModel frame)
    {
        _previewedFrame = frame;
        IsFramePreview = true;
        int index = Frames.IndexOf(frame);
        FramePreviewTitle = L.F("ui.frames.previewTitle", frame.FileName, index + 1, Frames.Count);
        IsError = false;
        StatusText = L.F("ui.frames.previewLoading", frame.FileName);
        try
        {
            var rendered = await Task.Run(() =>
            {
                var img = ImageFiles.Load(frame.Path);
                return PreviewRenderer.Render(img, autoStretch: true);
            });
            if (!ReferenceEquals(_previewedFrame, frame) || !IsFramePreview) return;
            PreviewScale = rendered.SourceWidth / (double)rendered.Width;
            PreviewImage = rendered.ToBitmap();
            BeforeImage = null;
            StatusText = L.F("ui.frames.previewInfo", frame.FileName, rendered.SourceWidth, rendered.SourceHeight) + (frame.Status is { } s ? $" · {s}" : "");
        }
        catch (Exception ex)
        {
            IsError = true;
            StatusText = L.F("ui.frames.openFailed", ex.Message);
        }
    }

    [RelayCommand]
    private void ExitFramePreview()
    {
        IsFramePreview = false;
        _previewedFrame = null;
        RefreshPreview();
    }

    [RelayCommand]
    private Task NextFrame() => StepFrame(+1);

    [RelayCommand]
    private Task PreviousFrame() => StepFrame(-1);

    private Task StepFrame(int delta)
    {
        if (_previewedFrame is null || Frames.Count == 0) return Task.CompletedTask;
        int i = (Frames.IndexOf(_previewedFrame) + delta + Frames.Count) % Frames.Count;
        return PreviewFrameAsync(Frames[i]);
    }

    private void LoadFrames(FrameSet frames)
    {
        Frames.Clear();
        foreach (var f in frames.Frames) Frames.Add(new FrameItemViewModel(this, f));
        HasQuality = false;
        QualityVersion++;
        HasFrames = Frames.Count > 0;
        WindowTitle = L.F("ui.app.titleWithFolder", Path.GetFileName(frames.Folder));
        PrefillObjectName(frames);
    }

    /// <summary>Plate solving: pre-fill the object name from the header (or the folder name) so the user sees what will be looked up.</summary>
    private void PrefillObjectName(FrameSet frames)
    {
        var step = Steps.FirstOrDefault(s => s.Id == StepId.PlateSolve);
        var param = step?.Parameters.OfType<TextParameterViewModel>().FirstOrDefault(t => t.Key == PlateSolveStep.ObjectKey);
        if (param is null) return;
        string? name = ObjectNameGuess.From(frames);
        if (name is not null) param.Text = name;
    }

    private void UpdateImageInfo()
    {
        var img = _workflow.Current;
        ImageInfo = img is null ? "" : L.F("ui.status.imageInfo", img.Width, img.Height, L.T(img.IsColor ? "ui.status.color" : "ui.status.mono"));
    }

    /// <summary>Az előnézet frissítése háttérszálon; a régi renderelést megszakítjuk.</summary>
    private void RefreshPreview()
    {
        if (IsFramePreview && _previewedFrame is not null) { _ = PreviewFrameAsync(_previewedFrame); return; }
        _previewCts?.Cancel();
        var cts = _previewCts = new CancellationTokenSource();
        var step = SelectedStep;
        if (step is null) return;

        // Az első két lépés a képlista nézete (mappa tartalma, majd az összeillesztés eredménye és
        // statisztikái kis előnézettel); a nagy kép a vágásnál jelenik meg először.
        if (step.Id is StepId.LoadFrames or StepId.Stack)
        {
            PreviewImage = null;
            BeforeImage = null;
            RefreshStackThumbnail(cts.Token);
            return;
        }
        AstroImage? after = ShowOriginal ? _workflow.Original
            : step.Id == StepId.Crop ? _workflow.ImageBefore(step.Id)
            : step.IsDone ? _workflow.ImageAfter(step.Id) : _workflow.ImageBefore(step.Id);
        // Split view: a finished step compares its own input and output; a step that has not run yet
        // compares the previous finished step's input with the current image, so right after "Apply"
        // (the app moves on to the next step) the user still sees what the last step changed.
        AstroImage? before = null;
        if (SplitView && !ShowOriginal)
            before = step.IsDone || step.Id == StepId.Crop ? _workflow.ImageBefore(step.Id)
                : _workflow.LastImageStepBefore(step.Id) is { } prev ? _workflow.ImageBefore(prev) : null;
        bool stretch = AutoStretch;
        if (after is null)
        {
            PreviewImage = null;
            BeforeImage = null;
            return;
        }
        _ = Task.Run(() =>
        {
            var a = PreviewRenderer.Render(after, stretch, cts.Token);
            var b = before is not null && !ReferenceEquals(before, after) ? PreviewRenderer.Render(before, stretch, cts.Token) : null;
            return (a, b);
        }, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled || cts.IsCancellationRequested) return;
            if (t.IsFaulted) { IsError = true; StatusText = t.Exception?.InnerException?.Message ?? L.T("ui.status.previewError"); return; }
            PreviewScale = t.Result.a.SourceWidth / (double)t.Result.a.Width;
            PreviewImage = t.Result.a.ToBitmap();
            BeforeImage = t.Result.b?.ToBitmap() ?? (SplitView ? PreviewImage : null);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _previewCts?.Cancel();
        _workflow.Dispose();
    }
}
