using System.Collections.ObjectModel;
using ClearStar.Core.Localization;
using ClearStar.Core.Pipeline;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace ClearStar.App.ViewModels;

/// <summary>Egy beállítás a lépés kártyáján. A módosítás azonnal a StepParameters-be íródik.</summary>
public abstract partial class ParameterViewModel : ObservableObject
{
    protected readonly StepParameters Parameters;
    public ParameterDefinition Definition { get; }

    public string Key => Definition.Key;
    public string Label => Definition.Label;
    public string? Help => Definition.Help;
    public bool IsAdvanced => Definition.Advanced;
    public bool IsHidden => Definition.Kind == ParameterKind.Hidden;

    protected ParameterViewModel(ParameterDefinition definition, StepParameters parameters)
    {
        Definition = definition;
        Parameters = parameters;
    }

    public static ParameterViewModel Create(ParameterDefinition d, StepParameters p) => d.Kind switch
    {
        ParameterKind.Slider => new SliderParameterViewModel(d, p),
        ParameterKind.Toggle => new ToggleParameterViewModel(d, p),
        ParameterKind.Choice => new ChoiceParameterViewModel(d, p),
        ParameterKind.Folder => new FolderParameterViewModel(d, p),
        ParameterKind.Hidden => new HiddenParameterViewModel(d, p),
        ParameterKind.Model => new ModelParameterViewModel(d, p),
        _ => new TextParameterViewModel(d, p),
    };

    /// <summary>Az alapértelmezett érték visszaállítása.</summary>
    public abstract void Reset();
}

public partial class SliderParameterViewModel : ParameterViewModel
{
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ValueLabel))]
    private double _value;

    public double Minimum => Definition.Min;
    public double Maximum => Definition.Max;
    public string[] TickLabels { get; }

    public SliderParameterViewModel(ParameterDefinition d, StepParameters p) : base(d, p)
    {
        _value = p.GetDouble(d.Key, Convert.ToDouble(d.Default));
        TickLabels = d.TickLabels ?? ["", "", ""];
    }

    /// <summary>A csúszka állásához legközelebbi felirat – a kezdő ezt látja szám helyett.</summary>
    public string ValueLabel
    {
        get
        {
            // A numeric format (e.g. "{0:0.0}°") shows the value itself instead of the nearest tick label.
            if (Definition.ValueFormat is { } format) return string.Format(System.Globalization.CultureInfo.CurrentCulture, format, Value);
            if (TickLabels.Length == 0 || Maximum <= Minimum) return "";
            double t = (Value - Minimum) / (Maximum - Minimum);
            int i = (int)Math.Round(t * (TickLabels.Length - 1));
            return TickLabels[Math.Clamp(i, 0, TickLabels.Length - 1)];
        }
    }

    partial void OnValueChanged(double value) => Parameters[Key] = value;

    public override void Reset() => Value = Convert.ToDouble(Definition.Default);
}

public partial class ToggleParameterViewModel : ParameterViewModel
{
    [ObservableProperty] private bool _isOn;

    public ToggleParameterViewModel(ParameterDefinition d, StepParameters p) : base(d, p)
    {
        _isOn = p.GetBool(d.Key, (bool)d.Default);
    }

    partial void OnIsOnChanged(bool value) => Parameters[Key] = value;
    public override void Reset() => IsOn = (bool)Definition.Default;
}

/// <summary>Egy választólista-elem: nyelvfüggetlen érték + a felhasználónak szóló felirat.</summary>
public sealed record ChoiceItem(string Value, string Label)
{
    public override string ToString() => Label;
}

public partial class ChoiceParameterViewModel : ParameterViewModel
{
    [ObservableProperty] private ChoiceItem? _selected;
    public ObservableCollection<ChoiceItem> Choices { get; }

    public ChoiceParameterViewModel(ParameterDefinition d, StepParameters p) : base(d, p)
    {
        Choices = new ObservableCollection<ChoiceItem>((d.Choices ?? []).Select(v => new ChoiceItem(v, d.LabelFor(v))));
        _selected = Find(p.GetString(d.Key, d.Default.ToString() ?? ""));
    }

    private ChoiceItem? Find(string value) => Choices.FirstOrDefault(c => c.Value == value) ?? Choices.FirstOrDefault();

    partial void OnSelectedChanged(ChoiceItem? value) { if (value is not null) Parameters[Key] = value.Value; }
    public override void Reset() => Selected = Find(Definition.Default.ToString() ?? "");
}

public partial class TextParameterViewModel : ParameterViewModel
{
    [ObservableProperty] private string _text = "";

    public TextParameterViewModel(ParameterDefinition d, StepParameters p) : base(d, p)
    {
        _text = p.GetString(d.Key, d.Default.ToString() ?? "");
    }

    partial void OnTextChanged(string value) => Parameters[Key] = value;
    public override void Reset() => Text = Definition.Default.ToString() ?? "";
}

public partial class FolderParameterViewModel : ParameterViewModel
{
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(DisplayPath))]
    [NotifyPropertyChangedFor(nameof(HasPath))]
    private string _path = "";

    public FolderParameterViewModel(ParameterDefinition d, StepParameters p) : base(d, p)
    {
        _path = p.GetString(d.Key, d.Default.ToString() ?? "");
    }

    public bool HasPath => Path.Length > 0;
    public string DisplayPath => Path.Length == 0 ? L.T("ui.step.noPath") : Path;

    partial void OnPathChanged(string value) => Parameters[Key] = value;
    public override void Reset() => Path = Definition.Default.ToString() ?? "";

    [RelayCommand]
    private void Browse()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = Label, Multiselect = false };
        if (HasPath && Directory.Exists(Path)) dialog.InitialDirectory = Path;
        if (dialog.ShowDialog() == true) Path = dialog.FolderName;
    }

    [RelayCommand]
    private void BrowseFile()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = L.T("ui.step.pickImage"),
            Filter = L.T("ui.step.imageFilter"),
        };
        if (dialog.ShowDialog() == true) Path = dialog.FileName;
    }
}

/// <summary>A felületen nem megjelenő, program által töltött érték (pl. a vágás kijelölése).</summary>
public sealed class HiddenParameterViewModel(ParameterDefinition d, StepParameters p) : ParameterViewModel(d, p)
{
    public override void Reset() => Parameters[Key] = Definition.Default;
}
