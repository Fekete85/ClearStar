using System.Diagnostics;
using System.Net.Http;
using System.Windows;
using System.Windows.Media;
using ClearStar.Core;
using ClearStar.Core.Astrometry;
using ClearStar.Core.Localization;

namespace ClearStar.App.Views;

/// <summary>
/// Explains the offline Gaia catalogue, downloads it in-app (Zenodo, bzip2, SHA-256 verified) with
/// progress and cancel, or lets the user point ClearStar to an existing file. The download keeps
/// running if the window is closed; it is shared so the dialog can be reopened to watch it.
/// </summary>
public partial class CatalogSetupWindow : Window
{
    private static Task<string>? _download;
    private static CancellationTokenSource? _downloadCts;
    private static CatalogDownloader.Progress? _lastProgress;
    private static event Action<CatalogDownloader.Progress>? ProgressChanged;

    public CatalogSetupWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => MainWindow.ApplyDarkTitleBar(this);
        ProgressChanged += OnProgress;
        Closed += (_, _) => ProgressChanged -= OnProgress;
        Refresh();
        if (_download is { IsCompleted: false }) ShowDownloading();
    }

    public static void ShowDialog(Window owner) => new CatalogSetupWindow { Owner = owner }.ShowDialog();

    private void Refresh()
    {
        string? file = LocalGaiaCatalog.Locate();
        StatusText.Text = file is null ? L.T("ui.catalog.missing") : L.F("ui.catalog.found", file);
        StatusText.Foreground = (Brush)FindResource(file is null ? "B.Amber" : "B.Accent");
        DownloadButton.Visibility = file is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OpenRecord(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(CatalogDownloader.RecordUrl) { UseShellExecute = true });

    private void Browse(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = L.T("ui.catalog.pickTitle"), Filter = L.T("ui.catalog.pickFilter"), FileName = LocalGaiaCatalog.DefaultFileName };
        if (dialog.ShowDialog() != true) return;
        if (LocalGaiaCatalog.Open(dialog.FileName) is null)
        {
            StatusText.Text = L.T("ui.catalog.invalid");
            StatusText.Foreground = (Brush)FindResource("B.Red");
            return;
        }
        UserSettings.Set(LocalGaiaCatalog.PathSettingKey, dialog.FileName);
        Refresh();
    }

    private async void Download(object sender, RoutedEventArgs e)
    {
        if (_download is { IsCompleted: false }) { ShowDownloading(); return; }
        _downloadCts = new CancellationTokenSource();
        var progress = new Progress<CatalogDownloader.Progress>(p => { _lastProgress = p; ProgressChanged?.Invoke(p); });
        _download = CatalogDownloader.DownloadAsync(progress, _downloadCts.Token);
        ShowDownloading();
        try
        {
            await _download;
            if (IsLoaded) { HideDownloading(); StatusText.Text = L.T("ui.catalog.downloaded"); StatusText.Foreground = (Brush)FindResource("B.Accent"); Refresh(); }
        }
        catch (OperationCanceledException)
        {
            if (IsLoaded) { HideDownloading(); Refresh(); }
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or UnauthorizedAccessException)
        {
            if (IsLoaded) { HideDownloading(); StatusText.Text = L.F("ui.catalog.downloadFailed", ex.Message); StatusText.Foreground = (Brush)FindResource("B.Red"); }
        }
    }

    private void CancelDownload(object sender, RoutedEventArgs e) => _downloadCts?.Cancel();

    private void ShowDownloading()
    {
        DownloadButton.IsEnabled = false;
        CancelButton.Visibility = Visibility.Visible;
        Progress.Visibility = ProgressText.Visibility = Visibility.Visible;
        if (_lastProgress is { } p) OnProgress(p);
    }

    private void HideDownloading()
    {
        DownloadButton.IsEnabled = true;
        CancelButton.Visibility = Visibility.Collapsed;
        Progress.Visibility = ProgressText.Visibility = Visibility.Collapsed;
    }

    private void OnProgress(CatalogDownloader.Progress p)
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(() => OnProgress(p)); return; }
        Progress.Value = p.Fraction;
        ProgressText.Text = p.Phase == "done" ? L.T("ui.catalog.verifying")
            : L.F("ui.catalog.downloading", p.BytesDownloaded / 1_048_576, p.BytesTotal / 1_048_576);
    }
}
