using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ClearStar.App.Controls;

/// <summary>Nagyítható-mozgatható képnéző, "előtte/utána" osztott nézettel és téglalap-kijelöléssel (vágás).</summary>
public partial class ImageViewer : UserControl
{
    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(
        nameof(Source), typeof(BitmapSource), typeof(ImageViewer), new PropertyMetadata(null, OnSourceChanged));
    public static readonly DependencyProperty BeforeSourceProperty = DependencyProperty.Register(
        nameof(BeforeSource), typeof(BitmapSource), typeof(ImageViewer), new PropertyMetadata(null, OnBeforeChanged));
    public static readonly DependencyProperty IsSplitProperty = DependencyProperty.Register(
        nameof(IsSplit), typeof(bool), typeof(ImageViewer), new PropertyMetadata(false, OnSplitChanged));
    public static readonly DependencyProperty SplitPositionProperty = DependencyProperty.Register(
        nameof(SplitPosition), typeof(double), typeof(ImageViewer), new PropertyMetadata(0.5, OnSplitChanged));
    public static readonly DependencyProperty IsSelectionModeProperty = DependencyProperty.Register(
        nameof(IsSelectionMode), typeof(bool), typeof(ImageViewer), new PropertyMetadata(false, OnSelectionChanged));
    /// <summary>Kijelölés a kép arányában (0..1); Rect.Empty = nincs.</summary>
    public static readonly DependencyProperty SelectionProperty = DependencyProperty.Register(
        nameof(Selection), typeof(Rect), typeof(ImageViewer),
        new FrameworkPropertyMetadata(Rect.Empty, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, OnSelectionChanged));

    public BitmapSource? Source { get => (BitmapSource?)GetValue(SourceProperty); set => SetValue(SourceProperty, value); }
    public BitmapSource? BeforeSource { get => (BitmapSource?)GetValue(BeforeSourceProperty); set => SetValue(BeforeSourceProperty, value); }
    public bool IsSplit { get => (bool)GetValue(IsSplitProperty); set => SetValue(IsSplitProperty, value); }
    public double SplitPosition { get => (double)GetValue(SplitPositionProperty); set => SetValue(SplitPositionProperty, value); }
    public bool IsSelectionMode { get => (bool)GetValue(IsSelectionModeProperty); set => SetValue(IsSelectionModeProperty, value); }

    /// <summary>Hint shown while nothing is selected (crop and eyedropper use different texts).</summary>
    public static readonly DependencyProperty HintTextProperty = DependencyProperty.Register(
        nameof(HintText), typeof(string), typeof(ImageViewer), new PropertyMetadata(null, (d, _) => ((ImageViewer)d).ApplyHint()));
    public string? HintText { get => (string?)GetValue(HintTextProperty); set => SetValue(HintTextProperty, value); }
    private void ApplyHint() { if (HintText is { Length: > 0 } t) SelectionHintText.Text = t; }

    /// <summary>Whether the area outside the selection is dimmed (crop) or not (a small sample rectangle).</summary>
    public static readonly DependencyProperty DimOutsideProperty = DependencyProperty.Register(
        nameof(DimOutside), typeof(bool), typeof(ImageViewer), new PropertyMetadata(true, OnSelectionChanged));
    public bool DimOutside { get => (bool)GetValue(DimOutsideProperty); set => SetValue(DimOutsideProperty, value); }
    public Rect Selection { get => (Rect)GetValue(SelectionProperty); set => SetValue(SelectionProperty, value); }

    private Matrix _matrix = Matrix.Identity;
    private Point _dragStart;
    private bool _panning;
    private bool _draggingSplit;
    private enum DragKind { None, New, Move, L, R, T, B, TL, TR, BL, BR }
    private DragKind _selecting = DragKind.None;
    private Point _selectStartImage;
    private Rect _selectStartRect;
    private bool _fitPending = true;
    private (int w, int h) _lastSize;

    public ImageViewer()
    {
        InitializeComponent();
    }

    private static void OnSourceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var v = (ImageViewer)d;
        var src = (BitmapSource?)e.NewValue;
        v.AfterImage.Source = src;
        if (src is null) { v._lastSize = (0, 0); v.UpdateSelectionOverlay(); return; }
        var size = (src.PixelWidth, src.PixelHeight);
        // Új képméretnél (betöltés, vágás) illesztünk; egyébként a nézet marad, ahol volt.
        if (size != v._lastSize || v._fitPending) { v._lastSize = size; v.Fit(); }
        v.UpdateSplit();
        v.UpdateSelectionOverlay();
    }

    private static void OnBeforeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var v = (ImageViewer)d;
        v.BeforeImage.Source = (BitmapSource?)e.NewValue;
        v.UpdateSplit();
    }

    private static void OnSplitChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((ImageViewer)d).UpdateSplit();
    private static void OnSelectionChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((ImageViewer)d).UpdateSelectionOverlay();

    private void UpdateSplit()
    {
        bool show = IsSplit && BeforeImage.Source is not null && AfterImage.Source is not null;
        BeforeImage.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        SplitOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;
        double x = Surface.ActualWidth * SplitPosition;
        SplitLine.Margin = new Thickness(x - 1, 0, 0, 0);
        // A "előtte" képet a felület bal részére vágjuk – képkoordinátákban.
        var inv = _matrix; inv.Invert();
        var p = inv.Transform(new Point(x, 0));
        if (AfterImage.Source is not BitmapSource src) return;
        BeforeClip.Rect = new Rect(0, 0, Math.Clamp(p.X, 0, src.PixelWidth), src.PixelHeight);
    }

    private void UpdateSelectionOverlay()
    {
        bool mode = IsSelectionMode && AfterImage.Source is BitmapSource;
        SelectionHint.Visibility = mode && Selection.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        bool show = mode && !Selection.IsEmpty;
        SelectionOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;
        var src = (BitmapSource)AfterImage.Source;
        // Kijelölés (0..1) → kép pixel → képernyő.
        var imgRect = new Rect(Selection.X * src.PixelWidth, Selection.Y * src.PixelHeight, Selection.Width * src.PixelWidth, Selection.Height * src.PixelHeight);
        var screen = Rect.Transform(imgRect, _matrix);
        var outer = new RectangleGeometry(new Rect(0, 0, Surface.ActualWidth, Surface.ActualHeight));
        SelDim.Data = DimOutside ? new CombinedGeometry(GeometryCombineMode.Exclude, outer, new RectangleGeometry(screen)) : Geometry.Empty;
        Canvas.SetLeft(SelBorder, screen.X); Canvas.SetTop(SelBorder, screen.Y);
        SelBorder.Width = Math.Max(0, screen.Width); SelBorder.Height = Math.Max(0, screen.Height);
        Canvas.SetLeft(SelLabel, screen.X + 6); Canvas.SetTop(SelLabel, Math.Max(6, screen.Y - 26));
        SelLabelText.Text = $"{Math.Round(imgRect.Width * SourceScale)} × {Math.Round(imgRect.Height * SourceScale)} px";
    }

    /// <summary>Az előnézet lekicsinyített lehet; ezzel szorozva kapjuk a valódi pixelméretet.</summary>
    public static readonly DependencyProperty SourceScaleProperty = DependencyProperty.Register(
        nameof(SourceScale), typeof(double), typeof(ImageViewer), new PropertyMetadata(1.0, (d, _) => ((ImageViewer)d).Apply()));
    public double SourceScale { get => (double)GetValue(SourceScaleProperty); set => SetValue(SourceScaleProperty, value); }

    private void Apply()
    {
        Transform.Matrix = _matrix;
        ZoomLabel.Text = $"{Math.Round(_matrix.M11 * SourceScale * 100)}%";
        UpdateSplit();
        UpdateSelectionOverlay();
    }

    public void Fit()
    {
        if (AfterImage.Source is not BitmapSource src || Surface.ActualWidth <= 0 || Surface.ActualHeight <= 0) { _fitPending = true; return; }
        _fitPending = false;
        double scale = Math.Min(Surface.ActualWidth / src.PixelWidth, Surface.ActualHeight / src.PixelHeight);
        scale = Math.Min(scale, 1.0) * 0.98;
        _matrix = new Matrix(scale, 0, 0, scale,
            (Surface.ActualWidth - src.PixelWidth * scale) / 2,
            (Surface.ActualHeight - src.PixelHeight * scale) / 2);
        Apply();
    }

    public void ZoomTo(double scale, Point? center = null)
    {
        if (AfterImage.Source is null) return;
        scale = Math.Clamp(scale, 0.02, 16);
        var c = center ?? new Point(Surface.ActualWidth / 2, Surface.ActualHeight / 2);
        double factor = scale / _matrix.M11;
        _matrix.ScaleAt(factor, factor, c.X, c.Y);
        Apply();
    }

    private void OnSurfaceSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_fitPending) Fit(); else { UpdateSplit(); UpdateSelectionOverlay(); }
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        double factor = e.Delta > 0 ? 1.2 : 1 / 1.2;
        ZoomTo(_matrix.M11 * factor, e.GetPosition(Surface));
        e.Handled = true;
    }

    private Point ToImageNormalized(Point screen)
    {
        var inv = _matrix; inv.Invert();
        var p = inv.Transform(screen);
        if (AfterImage.Source is not BitmapSource src) return new Point(0, 0);
        return new Point(Math.Clamp(p.X / src.PixelWidth, 0, 1), Math.Clamp(p.Y / src.PixelHeight, 0, 1));
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Focus();
        _dragStart = e.GetPosition(Surface);
        bool left = e.ChangedButton == MouseButton.Left;
        // Bal gomb: osztott nézetben a csúszkát húzza (bárhol fogjuk meg a képet, a csúszka odaugrik),
        // vágásnál a kijelölést kezeli. A kép mozgatása KIZÁRÓLAG a középső gombbal történik.
        _draggingSplit = left && SplitOverlay.Visibility == Visibility.Visible && !IsSelectionMode;
        _selecting = left && !_draggingSplit && IsSelectionMode && AfterImage.Source is not null ? HitTestSelection(_dragStart) : DragKind.None;
        _panning = e.ChangedButton == MouseButton.Middle;
        if (_draggingSplit) SplitPosition = Math.Clamp(_dragStart.X / Surface.ActualWidth, 0.02, 0.98);
        if (_selecting != DragKind.None) { _selectStartImage = ToImageNormalized(_dragStart); _selectStartRect = Selection; }
        if (_draggingSplit || _selecting != DragKind.None || _panning) Surface.CaptureMouse();
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_selecting != DragKind.None)
        {
            _selecting = DragKind.None;
            // Apró (véletlen) kattintás: kijelölés törlése.
            if (!Selection.IsEmpty && (Selection.Width < 0.005 || Selection.Height < 0.005)) Selection = Rect.Empty;
        }
        _panning = _draggingSplit = false;
        Surface.ReleaseMouseCapture();
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        var p = e.GetPosition(Surface);
        if (e.LeftButton != MouseButtonState.Pressed && e.RightButton != MouseButtonState.Pressed && e.MiddleButton != MouseButtonState.Pressed)
        {
            Surface.Cursor = IsSelectionMode && AfterImage.Source is not null ? CursorFor(HitTestSelection(p)) : Cursors.Arrow;
            return;
        }
        if (_draggingSplit)
        {
            SplitPosition = Math.Clamp(p.X / Surface.ActualWidth, 0.02, 0.98);
            return;
        }
        if (_selecting != DragKind.None)
        {
            Selection = DragSelection(_selecting, _selectStartRect, _selectStartImage, ToImageNormalized(p));
            return;
        }
        if (!_panning || e.MiddleButton != MouseButtonState.Pressed) return;
        _matrix.Translate(p.X - _dragStart.X, p.Y - _dragStart.Y);
        _dragStart = p;
        Apply();
    }

    /// <summary>Hol fogtuk meg a kijelölést: szél, sarok, belseje – vagy új kijelölés kezdődik.</summary>
    private DragKind HitTestSelection(Point screen)
    {
        if (Selection.IsEmpty || AfterImage.Source is not BitmapSource src) return DragKind.New;
        var r = Rect.Transform(new Rect(Selection.X * src.PixelWidth, Selection.Y * src.PixelHeight, Selection.Width * src.PixelWidth, Selection.Height * src.PixelHeight), _matrix);
        const double m = 9;
        bool xIn = screen.X >= r.Left - m && screen.X <= r.Right + m, yIn = screen.Y >= r.Top - m && screen.Y <= r.Bottom + m;
        bool l = xIn && yIn && Math.Abs(screen.X - r.Left) <= m, rt = xIn && yIn && Math.Abs(screen.X - r.Right) <= m;
        bool t = xIn && yIn && Math.Abs(screen.Y - r.Top) <= m, b = xIn && yIn && Math.Abs(screen.Y - r.Bottom) <= m;
        if (l && t) return DragKind.TL; if (rt && t) return DragKind.TR; if (l && b) return DragKind.BL; if (rt && b) return DragKind.BR;
        if (l) return DragKind.L; if (rt) return DragKind.R; if (t) return DragKind.T; if (b) return DragKind.B;
        return r.Contains(screen) ? DragKind.Move : DragKind.New;
    }

    private static Cursor CursorFor(DragKind k) => k switch
    {
        DragKind.L or DragKind.R => Cursors.SizeWE,
        DragKind.T or DragKind.B => Cursors.SizeNS,
        DragKind.TL or DragKind.BR => Cursors.SizeNWSE,
        DragKind.TR or DragKind.BL => Cursors.SizeNESW,
        DragKind.Move => Cursors.SizeAll,
        _ => Cursors.Cross,
    };

    private static Rect DragSelection(DragKind k, Rect start, Point from, Point to)
    {
        if (k == DragKind.New)
            return new Rect(Math.Min(from.X, to.X), Math.Min(from.Y, to.Y), Math.Abs(from.X - to.X), Math.Abs(from.Y - to.Y));
        double dx = to.X - from.X, dy = to.Y - from.Y;
        if (k == DragKind.Move)
        {
            double x = Math.Clamp(start.X + dx, 0, 1 - start.Width), y = Math.Clamp(start.Y + dy, 0, 1 - start.Height);
            return new Rect(x, y, start.Width, start.Height);
        }
        double left = start.Left, top = start.Top, right = start.Right, bottom = start.Bottom;
        if (k is DragKind.L or DragKind.TL or DragKind.BL) left = Math.Clamp(to.X, 0, right - 0.005);
        if (k is DragKind.R or DragKind.TR or DragKind.BR) right = Math.Clamp(to.X, left + 0.005, 1);
        if (k is DragKind.T or DragKind.TL or DragKind.TR) top = Math.Clamp(to.Y, 0, bottom - 0.005);
        if (k is DragKind.B or DragKind.BL or DragKind.BR) bottom = Math.Clamp(to.Y, top + 0.005, 1);
        return new Rect(left, top, right - left, bottom - top);
    }

    private void ZoomIn(object sender, RoutedEventArgs e) => ZoomTo(_matrix.M11 * 1.25);
    private void ZoomOut(object sender, RoutedEventArgs e) => ZoomTo(_matrix.M11 / 1.25);
    private void FitClick(object sender, RoutedEventArgs e) => Fit();
    private void ActualSizeClick(object sender, RoutedEventArgs e) => ZoomTo(1.0 / Math.Max(SourceScale, 1e-6));
}
