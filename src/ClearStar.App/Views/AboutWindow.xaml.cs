using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using ClearStar.App.Services;
using ClearStar.Core;
using ClearStar.Core.Localization;

namespace ClearStar.App.Views;

/// <summary>Névjegy: verzió, szerző, nyelvválasztás, licenc és a felhasznált munkák (beágyazott jogi szövegek).</summary>
public partial class AboutWindow : Window
{
    private readonly string _startLanguage = L.Language;

    public AboutWindow()
    {
        InitializeComponent();
        var asm = typeof(AboutWindow).Assembly;
        string version = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion?.Split('+')[0]
                         ?? asm.GetName().Version?.ToString(3) ?? "";
        VersionText.Text = L.F("ui.about.version", version);
        CopyrightText.Text = asm.GetCustomAttribute<AssemblyCopyrightAttribute>()?.Copyright ?? "";
        SummaryText.Text = L.T("ui.about.summary");
        SupportUrlText.Text = ClearStar.Core.AppLinks.Support;
        LanguageFolderText.Text = L.UserLanguagesDir;
        GpuSwitch.IsChecked = ClearStar.Core.AI.OnnxSessions.GpuEnabled;

        var langs = L.Available();
        LanguageList.ItemsSource = langs;
        LanguageList.SelectedItem = langs.FirstOrDefault(x => string.Equals(x.Code, L.Language, StringComparison.OrdinalIgnoreCase));
        SourceInitialized += (_, _) => MainWindow.ApplyDarkTitleBar(this);
    }

    public static void ShowDialog(Window owner) => new AboutWindow { Owner = owner }.ShowDialog();

    private void TabChecked(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleButton tb || tb.Tag is not string tag) return;
        foreach (var other in new[] { TabAbout, TabLicense, TabThirdParty, TabModels })
            if (!ReferenceEquals(other, tb)) other.IsChecked = false;
        AboutScroll.Visibility = tag == "about" ? Visibility.Visible : Visibility.Collapsed;
        DocPanel.Visibility = tag == "thirdparty" ? Visibility.Visible : Visibility.Collapsed;
        TextPanel.Visibility = tag is "about" or "thirdparty" ? Visibility.Collapsed : Visibility.Visible;
        if (tag == "thirdparty")
        {
            // The notices are Markdown (headings, tables, links): render them instead of showing the source.
            DocPanel.Document ??= MarkdownLite.ToDocument(ReadLegal("Legal.THIRD-PARTY-NOTICES.md"),
                (Brush)FindResource("B.Text"), (Brush)FindResource("B.Text2"), (Brush)FindResource("B.Accent"), (Brush)FindResource("B.Stroke"), (FontFamily)FindResource("F.Body"));
            return;
        }
        TextPanel.Text = tag switch
        {
            "license" => ReadLegal("Legal.LICENSE.txt"),
            "models" => string.Join("\n\n----------------------------------------\n\n",
                new[] { "Legal.GraXpert-BGE-Model-LICENSE.txt", "Legal.GraXpert-Denoise-Model-LICENSE.txt", "Legal.GraXpert-Deconvolution-Model-LICENSE.txt" }
                    .Select(ReadLegal)),
            _ => "",
        };
        TextPanel.ScrollToHome();
    }

    private static string ReadLegal(string name)
    {
        using var s = typeof(AboutWindow).Assembly.GetManifestResourceStream(name);
        if (s is null) return name;
        using var r = new StreamReader(s);
        return r.ReadToEnd();
    }

    private void LanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LanguageList.SelectedItem is not LanguageInfo info) return;
        UserSettings.Set(UserSettings.LanguageKey, info.Code);
        RestartButton.Visibility = string.Equals(info.Code, _startLanguage, StringComparison.OrdinalIgnoreCase) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void GpuChanged(object sender, RoutedEventArgs e) => ClearStar.Core.AI.OnnxSessions.GpuEnabled = GpuSwitch.IsChecked == true;

    private void OpenSupport(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(ClearStar.Core.AppLinks.Support) { UseShellExecute = true }); }
        catch (Exception) { /* no browser – the address is shown as text next to the button */ }
    }

    private void OpenLanguageFolder(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(L.UserLanguagesDir);
        Process.Start(new ProcessStartInfo("explorer.exe", L.UserLanguagesDir) { UseShellExecute = true });
    }

    private void Restart(object sender, RoutedEventArgs e)
    {
        if (Environment.ProcessPath is { } exe)
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
        Application.Current.Shutdown();
    }
}
