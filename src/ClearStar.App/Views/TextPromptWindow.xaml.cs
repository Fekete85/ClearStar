using System.Windows;

namespace ClearStar.App.Views;

/// <summary>Egyszerű szövegbekérő ablak (pl. letöltési URL).</summary>
public partial class TextPromptWindow : Window
{
    public TextPromptWindow()
    {
        InitializeComponent();
    }

    public static string? Show(string title, string prompt, string initial = "")
    {
        var w = new TextPromptWindow { Title = title, Owner = Application.Current.MainWindow };
        w.Prompt.Text = prompt;
        w.Input.Text = initial;
        w.Loaded += (_, _) => { w.Input.Focus(); w.Input.CaretIndex = w.Input.Text.Length; };
        return w.ShowDialog() == true ? w.Input.Text : null;
    }

    private void Ok(object sender, RoutedEventArgs e) => DialogResult = true;
}
