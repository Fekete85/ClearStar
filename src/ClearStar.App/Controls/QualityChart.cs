using System.Collections;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ClearStar.App.ViewModels;

namespace ClearStar.App.Controls;

public enum QualityMetric { Stars, StarSize, Background, Angle }

/// <summary>
/// Képenkénti minőség-mérőszám időrendben, oszlopdiagramként: a felhasznált képek türkiz, a kihagyottak
/// piros oszlopot kapnak. Rámutatva a fájlnév és az érték látszik, kattintásra a kép előnézete nyílik.
/// </summary>
public sealed class QualityChart : FrameworkElement
{
    public static readonly DependencyProperty ItemsProperty = DependencyProperty.Register(
        nameof(Items), typeof(IEnumerable), typeof(QualityChart), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty MetricProperty = DependencyProperty.Register(
        nameof(Metric), typeof(QualityMetric), typeof(QualityChart), new FrameworkPropertyMetadata(QualityMetric.Stars, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty VersionProperty = DependencyProperty.Register(
        nameof(Version), typeof(int), typeof(QualityChart), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));

    public IEnumerable? Items { get => (IEnumerable?)GetValue(ItemsProperty); set => SetValue(ItemsProperty, value); }
    public QualityMetric Metric { get => (QualityMetric)GetValue(MetricProperty); set => SetValue(MetricProperty, value); }
    /// <summary>Bármilyen változásra növelve újrarajzol (a mérőszámok nem figyelt tulajdonságok).</summary>
    public int Version { get => (int)GetValue(VersionProperty); set => SetValue(VersionProperty, value); }

    private static readonly Brush UsedBrush = new SolidColorBrush(Color.FromRgb(0x3E, 0xCF, 0xC0));
    private static readonly Brush SkippedBrush = new SolidColorBrush(Color.FromRgb(0xE5, 0x76, 0x6D));
    private static readonly Brush MissingBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF));
    private static readonly Brush HoverBrush = new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF));
    private static readonly Brush TextBrush = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF));
    private static readonly Pen AxisPen = new(new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF)), 1);
    private static readonly Typeface Face = new("Segoe UI");

    private List<FrameItemViewModel> _items = [];
    private int _hover = -1;

    static QualityChart()
    {
        UsedBrush.Freeze(); SkippedBrush.Freeze(); MissingBrush.Freeze(); HoverBrush.Freeze(); TextBrush.Freeze(); AxisPen.Freeze();
    }

    public QualityChart()
    {
        ClipToBounds = true;
        Cursor = Cursors.Hand;
    }

    private double? Value(FrameItemViewModel f) => Metric switch
    {
        QualityMetric.Stars => f.Stars,
        QualityMetric.StarSize => f.StarSize,
        QualityMetric.Background => f.Background,
        QualityMetric.Angle => f.Angle,
        _ => null,
    };

    private string Format(double v) => Metric switch
    {
        QualityMetric.Stars => ClearStar.Core.Localization.L.F("ui.frames.starsValue", v),
        QualityMetric.StarSize => $"{v:0.00} px",
        QualityMetric.Background => $"{v * 100:0.00} %",
        QualityMetric.Angle => $"{v:+0.0;-0.0}°",
        _ => v.ToString(CultureInfo.CurrentCulture),
    };

    protected override void OnRender(DrawingContext dc)
    {
        _items = Items?.OfType<FrameItemViewModel>().ToList() ?? [];
        double w = ActualWidth, h = ActualHeight;
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));
        if (_items.Count == 0 || w < 10 || h < 10) return;

        const double left = 66, bottom = 4, top = 4;
        var values = _items.Select(Value).ToList();
        var known = values.Where(v => v.HasValue).Select(v => v!.Value).ToList();
        if (known.Count == 0) return;
        double min = known.Min(), max = known.Max();
        if (Metric == QualityMetric.Stars || Metric == QualityMetric.StarSize) min = Math.Min(min, 0);
        if (max - min < 1e-6) { max = min + 1; }
        double pad = (max - min) * 0.08;
        max += pad; if (Metric != QualityMetric.Stars && Metric != QualityMetric.StarSize) min -= pad;

        double plotW = w - left - 4, plotH = h - top - bottom;
        double barW = plotW / _items.Count;
        double Y(double v) => top + plotH - (v - min) / (max - min) * plotH;

        dc.DrawLine(AxisPen, new Point(left, top), new Point(left, top + plotH));
        dc.DrawLine(AxisPen, new Point(left, top + plotH), new Point(w - 4, top + plotH));
        DrawLabel(dc, Format(max - pad), left - 4, top, true);
        DrawLabel(dc, Format(Metric is QualityMetric.Stars or QualityMetric.StarSize ? 0 : min + pad), left - 4, top + plotH - 12, true);

        for (int i = 0; i < _items.Count; i++)
        {
            double x = left + i * barW;
            double bw = Math.Max(1, barW - (barW > 3 ? 1 : 0));
            if (values[i] is not { } v)
            {
                dc.DrawRectangle(MissingBrush, null, new Rect(x, top + plotH - 3, bw, 3));
                continue;
            }
            var brush = i == _hover ? HoverBrush : _items[i].IsUsed == false ? SkippedBrush : UsedBrush;
            double y = Y(v);
            double baseline = Metric is QualityMetric.Angle ? Y(Math.Clamp(0, min, max)) : top + plotH;
            double yTop = Math.Min(y, baseline), height = Math.Max(1, Math.Abs(baseline - y));
            dc.DrawRectangle(brush, null, new Rect(x, yTop, bw, height));
        }

        if (_hover >= 0 && _hover < _items.Count)
        {
            var f = _items[_hover];
            string text = values[_hover] is { } hv ? $"{f.FileName} · {Format(hv)}" : f.FileName;
            var ft = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Face, 11.5, Brushes.White, 1.0);
            double bx = Math.Clamp(left + _hover * barW - ft.Width / 2, left, Math.Max(left, w - ft.Width - 12));
            var box = new Rect(bx, top, ft.Width + 12, ft.Height + 6);
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(0xE6, 0x20, 0x20, 0x23)), null, box, 4, 4);
            dc.DrawText(ft, new Point(bx + 6, top + 3));
        }
    }

    private static void DrawLabel(DrawingContext dc, string text, double right, double y, bool alignRight)
    {
        var ft = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Face, 10.5, TextBrush, 1.0);
        dc.DrawText(ft, new Point(alignRight ? right - ft.Width : right, y));
    }

    private int IndexAt(Point p)
    {
        if (_items.Count == 0) return -1;
        double plotW = ActualWidth - 70;
        int i = (int)((p.X - 66) / plotW * _items.Count);
        return i >= 0 && i < _items.Count ? i : -1;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int i = IndexAt(e.GetPosition(this));
        if (i != _hover) { _hover = i; InvalidateVisual(); }
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        if (_hover != -1) { _hover = -1; InvalidateVisual(); }
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        int i = IndexAt(e.GetPosition(this));
        if (i >= 0 && _items[i].PreviewCommand.CanExecute(null)) _items[i].PreviewCommand.Execute(null);
    }
}
