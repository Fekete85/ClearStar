using System.Windows.Markup;
using ClearStar.Core.Localization;

namespace ClearStar.App.Localization;

/// <summary>
/// XAML-felirat a nyelvi adatbázisból: <c>Text="{l:T ui.toolbar.original}"</c>.
/// A szöveg betöltéskor dől el (a nyelvváltás újraindítást kér).
/// </summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension : MarkupExtension
{
    public string Key { get; set; }

    public TExtension() { Key = ""; }
    public TExtension(string key) { Key = key; }

    public override object ProvideValue(IServiceProvider serviceProvider) => L.T(Key);
}
