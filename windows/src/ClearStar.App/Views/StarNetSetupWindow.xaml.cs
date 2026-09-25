using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using ClearStar.Core.AI;
using ClearStar.Core.Localization;

namespace ClearStar.App.Views;

/// <summary>Explains what StarNet2 is, opens its download page and lets the user point ClearStar to starnet2.exe.</summary>
public partial class StarNetSetupWindow : Window
{
    public StarNetSetupWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => MainWindow.ApplyDarkTitleBar(this);
        Refresh();
    }

    public static void ShowDialog(Window owner) => new StarNetSetupWindow { Owner = owner }.ShowDialog();

    private void Refresh()
    {
        string? exe = StarNet.Locate();
        StatusText.Text = exe is null ? L.T("ui.starnet.missing") : L.F("ui.starnet.found", exe);
        StatusText.Foreground = (Brush)FindResource(exe is null ? "B.Amber" : "B.Accent");
    }

    private void OpenDownload(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(StarNet.DownloadUrl) { UseShellExecute = true });

    private void Browse(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = L.T("ui.starnet.pickTitle"), Filter = L.T("ui.starnet.pickFilter"), FileName = StarNet.ExeName };
        if (dialog.ShowDialog() != true) return;
        StarNet.SetExecutable(dialog.FileName);
        Refresh();
    }
}
