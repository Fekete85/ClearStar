using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using ClearStar.Core.Imaging;

namespace ClearStar.Core.IO;

/// <summary>32 bites lebegőpontos FITS írása (BITPIX=-32), a fontosabb fejléckulcsok átvitelével.</summary>
public static class FitsWriter
{
    private static readonly HashSet<string> Structural = new(StringComparer.OrdinalIgnoreCase)
    {
        "SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "BZERO", "BSCALE", "EXTEND", "END",
    };

    public static void Write(string path, AstroImage image)
    {
        using var stream = File.Create(path);
        Write(stream, image);
    }

    public static void Write(Stream stream, AstroImage image)
    {
        var cards = new List<string>
        {
            Card("SIMPLE", "T", "ClearStar"),
            Card("BITPIX", "-32", "32 bit lebegőpontos"),
            Card("NAXIS", image.Channels == 3 ? "3" : "2"),
            Card("NAXIS1", image.Width.ToString(CultureInfo.InvariantCulture)),
            Card("NAXIS2", image.Height.ToString(CultureInfo.InvariantCulture)),
        };
        if (image.Channels == 3) cards.Add(Card("NAXIS3", "3"));
        cards.Add(Card("BZERO", "0.0"));
        cards.Add(Card("BSCALE", "1.0"));
        cards.Add(Card("PROGRAM", Quote("ClearStar")));
        foreach (var (key, value) in image.Header)
        {
            if (Structural.Contains(key) || key.Length > 8 || key == "PROGRAM") continue;
            string v = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _) || value is "T" or "F"
                ? value : Quote(value);
            var card = Card(key, v);
            if (card.Length == FitsReader.CardSize) cards.Add(card);
        }
        cards.Add("END".PadRight(FitsReader.CardSize));

        var sb = new StringBuilder();
        foreach (var c in cards) sb.Append(c);
        while (sb.Length % FitsReader.BlockSize != 0) sb.Append(' ');
        var headerBytes = Encoding.ASCII.GetBytes(sb.ToString());
        stream.Write(headerBytes);

        // Sorokat visszafordítjuk a FITS konvenciójára (első sor alul).
        int w = image.Width, h = image.Height;
        var buffer = new byte[w * 4];
        for (int c = 0; c < image.Channels; c++)
        {
            var ch = image.Channel(c);
            for (int y = h - 1; y >= 0; y--)
            {
                var row = ch.Slice(y * w, w);
                for (int x = 0; x < w; x++)
                    BinaryPrimitives.WriteSingleBigEndian(buffer.AsSpan(x * 4, 4), row[x]);
                stream.Write(buffer);
            }
        }
        long dataBytes = (long)w * h * image.Channels * 4;
        long pad = (FitsReader.BlockSize - dataBytes % FitsReader.BlockSize) % FitsReader.BlockSize;
        if (pad > 0) stream.Write(new byte[pad]);
    }

    private static string Quote(string s) => "'" + s.Replace("'", "''").PadRight(8) + "'";

    private static string Card(string key, string value, string? comment = null)
    {
        string body = key.PadRight(8) + "= " + (value.StartsWith('\'') ? value : value.PadLeft(20));
        if (comment is not null) body += " / " + comment;
        return body.Length > FitsReader.CardSize ? body[..FitsReader.CardSize] : body.PadRight(FitsReader.CardSize);
    }
}
