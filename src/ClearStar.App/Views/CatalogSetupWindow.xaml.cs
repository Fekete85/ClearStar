using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using ClearStar.Core;
using ClearStar.Core.Astrometry;
using ClearStar.Core.Localization;

namespace ClearStar.App.Views;

/// <summary>Explains the offline Gaia catalogue (Siril's siril_cat_healpix8_astro.dat), links to its download and lets the user pick the file.</summary>
public partial class CatalogSetupWindow : Window
{
    public const string DownloadUrl = "https://siril.org/download/";

    public CatalogSetupWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => MainWindow.ApplyDarkTitleBar(this);
        Refresh();
    }

    public static void ShowDialog(Window owner) => new CatalogSetupWindow { Owner = owner }.ShowDialog();

    private void Refresh()
    {
        string? file = LocalGaiaCatalog.Locate();
        StatusText.Text = file is null ? L.T("ui.catalog.missing") : L.F("ui.catalog.found", file);
        StatusText.Foreground = (Brush)FindResource(file is null ? "B.Amber" : "B.Accent");
    }

    private void OpenDownload(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(DownloadUrl) { UseShellExecute = true });

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
}
