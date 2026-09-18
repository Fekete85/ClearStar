using System.Windows;
using ClearStar.App.Views;
using ClearStar.Core;
using ClearStar.Core.Localization;

namespace ClearStar.App;

public partial class App : Application
{
    private bool _reporting;

    public static string LogPath { get; } = Path.Combine(Path.GetTempPath(), "ClearStar", "error.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Nyelv: a beállításokban választott, különben a Windows nyelve (ha van hozzá fájl), különben magyar.
        L.Load(UserSettings.Get(UserSettings.LanguageKey) ?? L.SystemLanguage());
        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {args.Exception}\n\n");
            }
            catch (IOException) { }
            // Ha a hiba a rajzolás közben jön, a felugró ablak újra kiváltaná – ilyenkor csak naplózunk.
            if (_reporting) return;
            _reporting = true;
            try { MessageBox.Show(args.Exception.Message + "\n\n" + L.F("ui.app.errorDetails", LogPath), L.T("ui.app.errorTitle"), MessageBoxButton.OK, MessageBoxImage.Error); }
            finally { _reporting = false; }
        };
        // ClearStar.exe <mappa vagy kép> → azonnal betölt.
        var window = new MainWindow(e.Args.Length > 0 ? e.Args[0] : null);
        window.Show();
    }
}
