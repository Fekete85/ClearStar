using ClearStar.Core.Imaging;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Tiff;
using SixLabors.ImageSharp.Formats.Tiff.Constants;
using SixLabors.ImageSharp.PixelFormats;

namespace ClearStar.Core.IO;

public enum ExportFormat { Jpeg, Tiff16, Png16, Fits }

/// <summary>Képek betöltése és mentése formátumtól függően (FITS saját kóddal, a többi ImageSharp-pal).</summary>
public static class ImageFiles
{
    private static readonly string[] RasterExtensions = [".tif", ".tiff", ".png", ".jpg", ".jpeg"];

    public static IReadOnlyList<string> SupportedExtensions { get; } = [.. FitsReader.Extensions, .. RasterExtensions];

    public static bool IsSupported(string path) =>
        SupportedExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>Betöltés; a Bayer-mintás (egycsatornás, BAYERPAT fejlécű) FITS-t színessé alakítja.</summary>
    public static AstroImage Load(string path, bool debayer = true)
    {
        if (FitsReader.IsFits(path))
        {
            var img = FitsReader.Read(path);
            if (debayer && img.Channels == 1 && Debayer.TryParse(img.Header.GetValueOrDefault("BAYERPAT"), out var pattern))
                return Debayer.Bilinear(img, EffectiveBayerPattern(img, pattern));
            return img;
        }
        if (RasterExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) return LoadRaster(path);
        throw new NotSupportedException($"Nem támogatott képformátum: {Path.GetExtension(path)}");
    }

    /// <summary>
    /// A fejlécben megadott minta az adatra vonatkozik, ahogy a fájlban van. Mi a sorokat
    /// megfordítjuk (a FITS alulról tárol), így páros magasságnál a minta két sora felcserélődik –
    /// kivéve, ha a rögzítő szoftver eleve felülről írta (ROWORDER=TOP-DOWN), mert akkor a
    /// fordítás után pont a fejléc szerinti minta érvényes.
    /// </summary>
    public static BayerPattern EffectiveBayerPattern(AstroImage img, BayerPattern headerPattern)
    {
        bool topDown = img.Header.GetValueOrDefault("ROWORDER")?.Trim().Equals("TOP-DOWN", StringComparison.OrdinalIgnoreCase) == true;
        int yOffset = int.TryParse(img.Header.GetValueOrDefault("YBAYROFF"), out var yo) ? yo : 0;
        var p = headerPattern;
        if ((yOffset & 1) == 1) p = Debayer.FlipRows(p);
        if (!topDown && (img.Height & 1) == 0) p = Debayer.FlipRows(p);
        return p;
    }

    private static AstroImage LoadRaster(string path)
    {
        using var img = Image.Load<Rgb48>(path);
        int w = img.Width, h = img.Height, n = w * h;
        var data = new float[n * 3];
        img.ProcessPixelRows(accessor =>
        {
            for (int y = 0; y < h; y++)
            {
                var row = accessor.GetRowSpan(y);
                for (int x = 0; x < w; x++)
                {
                    int i = y * w + x;
                    data[i] = row[x].R / 65535f;
                    data[n + i] = row[x].G / 65535f;
                    data[2 * n + i] = row[x].B / 65535f;
                }
            }
        });
        var image = new AstroImage(w, h, 3, data);
        image.Header["ORIGFILE"] = Path.GetFileName(path);
        return image;
    }

    public static string ExtensionFor(ExportFormat format) => format switch
    {
        ExportFormat.Jpeg => ".jpg",
        ExportFormat.Tiff16 => ".tif",
        ExportFormat.Png16 => ".png",
        ExportFormat.Fits => ".fits",
        _ => throw new ArgumentOutOfRangeException(nameof(format)),
    };

    public static void Save(string path, AstroImage image, ExportFormat format, int jpegQuality = 92)
    {
        if (format == ExportFormat.Fits) { FitsWriter.Write(path, image); return; }

        using var img = ToRgb48(image);
        switch (format)
        {
            case ExportFormat.Jpeg:
                img.Save(path, new JpegEncoder { Quality = jpegQuality });
                break;
            case ExportFormat.Tiff16:
                img.Save(path, new TiffEncoder { BitsPerPixel = TiffBitsPerPixel.Bit48, Compression = TiffCompression.Deflate });
                break;
            case ExportFormat.Png16:
                img.Save(path, new PngEncoder { BitDepth = PngBitDepth.Bit16, ColorType = PngColorType.Rgb });
                break;
        }
    }

    private static Image<Rgb48> ToRgb48(AstroImage image)
    {
        int w = image.Width, h = image.Height, n = w * h;
        var img = new Image<Rgb48>(w, h);
        var d = image.Data;
        img.ProcessPixelRows(accessor =>
        {
            for (int y = 0; y < h; y++)
            {
                var row = accessor.GetRowSpan(y);
                for (int x = 0; x < w; x++)
                {
                    int i = y * w + x;
                    if (image.Channels == 3)
                        row[x] = new Rgb48(To16(d[i]), To16(d[n + i]), To16(d[2 * n + i]));
                    else
                    {
                        ushort v = To16(d[i]);
                        row[x] = new Rgb48(v, v, v);
                    }
                }
            }
        });
        return img;
    }

    private static ushort To16(float v) => (ushort)Math.Clamp(MathF.Round(v * 65535f), 0f, 65535f);
}
