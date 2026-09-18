using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace ClearStar.App.Controls;

/// <summary>Data for the histogram panel: per-channel bins of the input and the output, the transfer curve and the marker positions.</summary>
public sealed record HistogramData(int[][] Input, int[][] Output, float[] Curve, float Lp, float Sp, float Hp, float Bp, bool ShowMarkers);

/// <summary>
/// Siril-style stretch histogram: the stretched image's RGB histogram (log scale), the input
/// histogram as a faint outline, the transfer curve, and dashed markers at BP / LP / SP / HP.
/// </summary>
public sealed class HistogramView : FrameworkElement
{
    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(
        nameof(Data), typeof(HistogramData), typeof(HistogramView), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public HistogramData? Data { get => (HistogramData?)GetValue(DataProperty); set => SetValue(DataProperty, value); }

    private static readonly Brush[] ChannelBrushes =
    [
        new SolidColorBrush(Color.FromArgb(120, 255, 96, 96)),
        new SolidColorBrush(Color.FromArgb(120, 96, 230, 120)),
        new SolidColorBrush(Color.FromArgb(120, 110, 150, 255)),
    ];
    private static readonly Pen InputPen = new(new SolidColorBrush(Color.FromArgb(110, 255, 255, 255)), 1);
    private static readonly Pen CurvePen = new(new SolidColorBrush(Color.FromRgb(0x3E, 0xCF, 0xC0)), 1.5);
    private static readonly Typeface Face = new("Segoe UI");

    static HistogramView()
    {
        foreach (var b in ChannelBrushes) b.Freeze();
        InputPen.Freeze(); CurvePen.Freeze();
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(180, 16, 16, 18)), null, new Rect(0, 0, w, h));
        var data = Data;
        if (data is null || w < 10 || h < 10) return;
        double left = 6, right = w - 6, top = 6, bottom = h - 18;
        double plotW = right - left, plotH = bottom - top;

        // Log-scaled bars, normalised to the tallest output bin.
        double Scale(int[][] hist) => Math.Log(1 + hist.SelectMany(b => b).DefaultIfEmpty(1).Max());
        double outMax = Scale(data.Output), inMax = Scale(data.Input);
        int bins = data.Output[0].Length;
        double barW = plotW / bins;
        for (int c = 0; c < data.Output.Length && c < 3; c++)
        {
            var brush = data.Output.Length == 1 ? Brushes.LightGray : ChannelBrushes[c];
            for (int i = 0; i < bins; i++)
            {
                double v = Math.Log(1 + data.Output[c][i]) / outMax;
                if (v <= 0) continue;
                dc.DrawRectangle(brush, null, new Rect(left + i * barW, bottom - v * plotH, Math.Max(barW, 1), v * plotH));
            }
        }
        // Input histogram outline (luminance-ish: max over channels).
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            g.BeginFigure(new Point(left, bottom), false, false);
            for (int i = 0; i < bins; i++)
            {
                int m = 0; for (int c = 0; c < data.Input.Length; c++) m = Math.Max(m, data.Input[c][i]);
                double v = Math.Log(1 + m) / inMax;
                g.LineTo(new Point(left + (i + 0.5) * barW, bottom - v * plotH), true, false);
            }
        }
        geo.Freeze();
        dc.DrawGeometry(null, InputPen, geo);

        // Transfer curve.
        if (data.Curve.Length > 1)
        {
            var curve = new StreamGeometry();
            using (var g = curve.Open())
            {
                g.BeginFigure(new Point(left, bottom - Math.Clamp(data.Curve[0], 0, 1) * plotH), false, false);
                for (int i = 1; i < data.Curve.Length; i++)
                    g.LineTo(new Point(left + plotW * i / (data.Curve.Length - 1), bottom - Math.Clamp(data.Curve[i], 0, 1) * plotH), true, false);
            }
            curve.Freeze();
            dc.DrawGeometry(null, CurvePen, curve);
        }

        // Markers with labels.
        if (data.ShowMarkers)
        {
            Marker(dc, left + data.Bp * plotW, top, bottom, "BP", Color.FromRgb(200, 200, 200), data.Bp > 0);
            Marker(dc, left + data.Lp * plotW, top, bottom, "LP", Color.FromRgb(120, 170, 255), true);
            Marker(dc, left + data.Sp * plotW, top, bottom, "SP", Color.FromRgb(255, 200, 80), true);
            Marker(dc, left + data.Hp * plotW, top, bottom, "HP", Color.FromRgb(255, 120, 120), true);
        }
        // Axis ticks.
        for (int i = 0; i <= 4; i++)
        {
            double x = left + plotW * i / 4;
            var t = new FormattedText((i / 4.0).ToString("0.00", CultureInfo.CurrentCulture), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Face, 10, Brushes.Gray, 1.0);
            dc.DrawText(t, new Point(Math.Min(x - t.Width / 2, w - t.Width - 2), bottom + 2));
        }
    }

    private static void Marker(DrawingContext dc, double x, double top, double bottom, string label, Color colour, bool visible)
    {
        if (!visible) return;
        var pen = new Pen(new SolidColorBrush(colour), 1) { DashStyle = DashStyles.Dash };
        dc.DrawLine(pen, new Point(x, top), new Point(x, bottom));
        var t = new FormattedText(label, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Face, 10, new SolidColorBrush(colour), 1.0);
        dc.DrawText(t, new Point(x + 3, top));
    }
}
