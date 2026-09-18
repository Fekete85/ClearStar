using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using ClearStar.App.ViewModels;
using ClearStar.Core.Pipeline;

namespace ClearStar.App.Views;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm = new();

    public MainWindow(string? initialPath = null)
    {
        InitializeComponent();
        DataContext = _vm;
        // Ne lógjon ki a képernyőről: a munkaterületnél kisebbre vesszük (DIP-ben, tehát DPI-skálázással együtt).
        var area = SystemParameters.WorkArea;
        Width = Math.Min(1600, area.Width - 40);
        Height = Math.Min(1000, area.Height - 40);
        SourceInitialized += (_, _) => EnableDarkTitleBar();
        Closed += (_, _) => _vm.Dispose();
        if (initialPath is not null) Loaded += async (_, _) => await LoadPathAsync(initialPath);
    }

    /// <summary>Betöltés és összeillesztés egy lépésben (drag&drop vagy parancssori indítás).</summary>
    private async Task LoadPathAsync(string path)
    {
        var loadStep = _vm.Steps.First(s => s.Id == StepId.LoadFrames);
        loadStep.Parameters.OfType<FolderParameterViewModel>().First().Path = path;
        _vm.ShowWelcome = false;
        _vm.SelectStep(loadStep);
        await _vm.ApplyAsync(loadStep);
        var stackStep = _vm.Steps.First(s => s.Id == StepId.Stack);
        if (loadStep.IsDone) await _vm.ApplyAsync(stackStep);
    }

    private void OriginalDown(object sender, MouseButtonEventArgs e) => _vm.ShowOriginal = true;
    private void OriginalUp(object sender, MouseEventArgs e) { if (_vm.ShowOriginal) _vm.ShowOriginal = false; }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) && !_vm.IsBusy ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } paths || _vm.IsBusy) return;
        // Egy fájl → az a kép; több fájl vagy mappa → a mappa.
        await LoadPathAsync(paths.Length == 1 ? paths[0] : Path.GetDirectoryName(paths[0]) ?? paths[0]);
    }

    // Windows 11: sötét címsor a rendszer ablakkeretén.
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private void EnableDarkTitleBar() => ApplyDarkTitleBar(this);

    public static void ApplyDarkTitleBar(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        int on = 1;
        _ = DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref on, sizeof(int));
        int color = 0x001D1A1A; // COLORREF: 0x00BBGGRR → #1A1A1D
        _ = DwmSetWindowAttribute(hwnd, 35 /* DWMWA_CAPTION_COLOR */, ref color, sizeof(int));
    }
}
