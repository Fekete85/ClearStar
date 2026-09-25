using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace ClearStar.App;

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }
    public object Convert(object? value, Type t, object? p, CultureInfo c) =>
        (value is true) ^ Invert ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => throw new NotSupportedException();
}

public sealed class NullToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }
    public object Convert(object? value, Type t, object? p, CultureInfo c)
    {
        bool has = value is not null && value is not string { Length: 0 };
        return has ^ Invert ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => throw new NotSupportedException();
}

/// <summary>Ikonkulcs (pl. "I.Crop") → Geometry az alkalmazás erőforrásaiból.</summary>
public sealed class IconConverter : IValueConverter
{
    public object? Convert(object? value, Type t, object? p, CultureInfo c) =>
        value is string key ? Application.Current.TryFindResource(key) as Geometry : null;
    public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => throw new NotSupportedException();
}

public sealed class FractionToWidthConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type t, object? p, CultureInfo c) =>
        values.Length == 2 && values[0] is double f && values[1] is double w ? Math.Max(0, f * w) : 0d;
    public object[] ConvertBack(object value, Type[] t, object? p, CultureInfo c) => throw new NotSupportedException();
}
