using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using ClearStar.Core.Imaging;

namespace ClearStar.Core.IO;

/// <summary>
/// Egyszerű FITS-olvasó: az elsődleges HDU-t olvassa (2D mono vagy 3D RGB),
/// BITPIX 8/16/32/-32/-64, BZERO/BSCALE kezeléssel. Az egész típusú adatot [0,1]-re normálja.
/// </summary>
public static class FitsReader
{
    public const int BlockSize = 2880;
    public const int CardSize = 80;

    public static readonly string[] Extensions = [".fit", ".fits", ".fts"];

    public static bool IsFits(string path) =>
        Extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static AstroImage Read(string path)
    {
        using var stream = File.OpenRead(path);
        return Read(stream);
    }

    public static AstroImage Read(Stream stream)
    {
        var header = ReadHeader(stream, out long dataStart);
        stream.Position = dataStart;

        int bitpix = GetInt(header, "BITPIX");
        int naxis = GetInt(header, "NAXIS");
        if (naxis is not (2 or 3)) throw new InvalidDataException($"Csak 2 vagy 3 dimenziós FITS támogatott (NAXIS={naxis}).");
        int width = GetInt(header, "NAXIS1");
        int height = GetInt(header, "NAXIS2");
        int channels = naxis == 3 ? GetInt(header, "NAXIS3") : 1;
        if (channels is not (1 or 3)) throw new InvalidDataException($"Csak 1 vagy 3 csatornás FITS támogatott (NAXIS3={channels}).");
        double bzero = GetDouble(header, "BZERO", 0);
        double bscale = GetDouble(header, "BSCALE", 1);

        long pixels = (long)width * height * channels;
        int bytesPerPixel = Math.Abs(bitpix) / 8;
        var raw = new byte[pixels * bytesPerPixel];
        ReadExactly(stream, raw);

        var data = new float[pixels];
        // Egész típusnál a fizikai érték = BZERO + BSCALE*raw; ezt a típus teljes tartományára normáljuk.
        switch (bitpix)
        {
            case 8:
                for (long i = 0; i < pixels; i++) data[i] = (float)((bzero + bscale * raw[i]) / 255.0);
                break;
            case 16:
            {
                // Az elterjedt "unsigned 16 bit" konvenció: BZERO=32768 → 0..65535.
                double norm = bzero == 32768 ? 65535.0 : 32767.0;
                for (long i = 0; i < pixels; i++)
                {
                    short v = BinaryPrimitives.ReadInt16BigEndian(raw.AsSpan((int)(i * 2), 2));
                    data[i] = (float)((bzero + bscale * v) / norm);
                }
                break;
            }
            case 32:
            {
                double norm = bzero == 2147483648 ? 4294967295.0 : 2147483647.0;
                for (long i = 0; i < pixels; i++)
                {
                    int v = BinaryPrimitives.ReadInt32BigEndian(raw.AsSpan((int)(i * 4), 4));
                    data[i] = (float)((bzero + bscale * v) / norm);
                }
                break;
            }
            case -32:
                for (long i = 0; i < pixels; i++)
                {
                    float v = BinaryPrimitives.ReadSingleBigEndian(raw.AsSpan((int)(i * 4), 4));
                    data[i] = (float)(bzero + bscale * v);
                }
                break;
            case -64:
                for (long i = 0; i < pixels; i++)
                {
                    double v = BinaryPrimitives.ReadDoubleBigEndian(raw.AsSpan((int)(i * 8), 8));
                    data[i] = (float)(bzero + bscale * v);
                }
                break;
            default:
                throw new InvalidDataException($"Nem támogatott BITPIX: {bitpix}.");
        }

        // Lebegőpontos képnél, ha az értékek nyilvánvalóan nem [0,1]-ben vannak (pl. 0..65535), normálunk.
        if (bitpix < 0)
        {
            float max = 0f;
            foreach (var v in data) if (v > max) max = v;
            if (max > 1.5f)
            {
                float norm = max <= 255f ? 255f : max <= 65535f ? 65535f : max;
                for (long i = 0; i < pixels; i++) data[i] /= norm;
            }
        }

        // A FITS az első sort alulra teszi; a képfeldolgozásban a 0. sor a felső. Sorokat fordítunk.
        var image = new AstroImage(width, height, channels, data, header);
        FlipVertical(image);
        return image;
    }

    public static Dictionary<string, string> ReadHeader(string path)
    {
        using var stream = File.OpenRead(path);
        return ReadHeader(stream, out _);
    }

    public static Dictionary<string, string> ReadHeader(Stream stream, out long dataStart)
    {
        var header = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var block = new byte[BlockSize];
        bool end = false;
        long pos = 0;
        bool first = true;
        while (!end)
        {
            ReadExactly(stream, block);
            pos += BlockSize;
            for (int i = 0; i < BlockSize; i += CardSize)
            {
                string card = Encoding.ASCII.GetString(block, i, CardSize);
                if (first)
                {
                    if (!card.StartsWith("SIMPLE", StringComparison.Ordinal))
                        throw new InvalidDataException("Nem FITS fájl (hiányzik a SIMPLE kulcs).");
                    first = false;
                }
                string key = card[..8].TrimEnd();
                if (key == "END") { end = true; break; }
                if (key.Length == 0 || key == "COMMENT" || key == "HISTORY") continue;
                if (card.Length < 10 || card[8] != '=' ) continue;
                string value = card[10..];
                int slash = FindCommentSlash(value);
                if (slash >= 0) value = value[..slash];
                value = value.Trim();
                if (value.Length >= 2 && value[0] == '\'' && value[^1] == '\'')
                    value = value[1..^1].Replace("''", "'").TrimEnd();
                header[key] = value;
            }
        }
        dataStart = pos;
        return header;
    }

    private static int FindCommentSlash(string value)
    {
        bool inString = false;
        for (int i = 0; i < value.Length; i++)
        {
            if (value[i] == '\'') inString = !inString;
            else if (value[i] == '/' && !inString) return i;
        }
        return -1;
    }

    internal static int GetInt(Dictionary<string, string> h, string key) =>
        h.TryGetValue(key, out var s) && int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v)
            ? v : throw new InvalidDataException($"Hiányzó vagy hibás FITS kulcs: {key}.");

    internal static double GetDouble(Dictionary<string, string> h, string key, double fallback) =>
        h.TryGetValue(key, out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    private static void ReadExactly(Stream stream, byte[] buffer)
    {
        int read = 0;
        while (read < buffer.Length)
        {
            int n = stream.Read(buffer, read, buffer.Length - read);
            if (n <= 0) throw new EndOfStreamException("A FITS fájl rövidebb a vártnál.");
            read += n;
        }
    }

    internal static void FlipVertical(AstroImage image)
    {
        int w = image.Width, h = image.Height;
        var row = new float[w];
        for (int c = 0; c < image.Channels; c++)
        {
            var ch = image.Channel(c);
            for (int y = 0; y < h / 2; y++)
            {
                var a = ch.Slice(y * w, w);
                var b = ch.Slice((h - 1 - y) * w, w);
                a.CopyTo(row);
                b.CopyTo(a);
                row.CopyTo(b);
            }
        }
    }
}
