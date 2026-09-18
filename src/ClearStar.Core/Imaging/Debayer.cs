namespace ClearStar.Core.Imaging;

/// <summary>A Bayer-szűrő elrendezése: a bal felső 2×2 blokk színei sorfolytonosan.</summary>
public enum BayerPattern { RGGB, BGGR, GRBG, GBRG }

/// <summary>
/// Egyszínű nyers (CFA) kép színessé alakítása. Bilineáris interpoláció: minden pixelhez a hiányzó
/// két színt a szomszédokból átlagoljuk. Gyors és a stackelés után a maradék műtermék kiátlagolódik.
/// </summary>
public static class Debayer
{
    public static bool TryParse(string? text, out BayerPattern pattern)
    {
        pattern = BayerPattern.RGGB;
        if (string.IsNullOrWhiteSpace(text)) return false;
        return Enum.TryParse(text.Trim().ToUpperInvariant(), out pattern);
    }

    /// <summary>
    /// A FITS a sorokat alulról tárolja, mi felülről; a függőleges tükrözés páros magasságnál
    /// felcseréli a minta két sorát (GRBG ↔ BGGR, RGGB ↔ GBRG).
    /// </summary>
    public static BayerPattern FlipRows(BayerPattern p) => p switch
    {
        BayerPattern.RGGB => BayerPattern.GBRG,
        BayerPattern.GBRG => BayerPattern.RGGB,
        BayerPattern.GRBG => BayerPattern.BGGR,
        BayerPattern.BGGR => BayerPattern.GRBG,
        _ => p,
    };

    /// <summary>Melyik színcsatorna (0=R,1=G,2=B) van az (x,y) pixelen.</summary>
    private static int ColorAt(BayerPattern p, int x, int y)
    {
        int i = (y & 1) * 2 + (x & 1);
        return p switch
        {
            BayerPattern.RGGB => i switch { 0 => 0, 1 => 1, 2 => 1, _ => 2 },
            BayerPattern.BGGR => i switch { 0 => 2, 1 => 1, 2 => 1, _ => 0 },
            BayerPattern.GRBG => i switch { 0 => 1, 1 => 0, 2 => 2, _ => 1 },
            _ /* GBRG */ => i switch { 0 => 1, 1 => 2, 2 => 0, _ => 1 },
        };
    }

    public static AstroImage Bilinear(AstroImage cfa, BayerPattern pattern)
    {
        if (cfa.Channels != 1) throw new ArgumentException("A debayerezéshez egycsatornás kép kell.", nameof(cfa));
        int w = cfa.Width, h = cfa.Height, n = w * h;
        var src = cfa.Data;
        var rgb = new AstroImage(w, h, 3, null, new Dictionary<string, string>(cfa.Header, StringComparer.OrdinalIgnoreCase));
        var dst = rgb.Data;

        // Az (x,y) pixel színe csak a paritástól függ – előre kiszámoljuk a 2×2 blokkra.
        int c00 = ColorAt(pattern, 0, 0), c10 = ColorAt(pattern, 1, 0), c01 = ColorAt(pattern, 0, 1), c11 = ColorAt(pattern, 1, 1);

        Parallel.For(0, h, y =>
        {
            int ym = Math.Max(y - 1, 0) * w, yp = Math.Min(y + 1, h - 1) * w, y0 = y * w;
            for (int x = 0; x < w; x++)
            {
                int xm = Math.Max(x - 1, 0), xp = Math.Min(x + 1, w - 1);
                int here = (y & 1) == 0 ? ((x & 1) == 0 ? c00 : c10) : ((x & 1) == 0 ? c01 : c11);
                float v = src[y0 + x];
                float hAvg = 0.5f * (src[y0 + xm] + src[y0 + xp]);            // vízszintes szomszédok
                float vAvg = 0.5f * (src[ym + x] + src[yp + x]);              // függőleges szomszédok
                float cross = 0.5f * (hAvg + vAvg);                            // 4 él-szomszéd
                float diag = 0.25f * (src[ym + xm] + src[ym + xp] + src[yp + xm] + src[yp + xp]);
                float r, g, b;
                if (here == 1)
                {
                    // Zöld pixel: a sorában lévő szín vízszintesen, a másik függőlegesen.
                    int rowColor = (x & 1) == 0 ? ((y & 1) == 0 ? c10 : c11) : ((y & 1) == 0 ? c00 : c01);
                    g = v;
                    if (rowColor == 0) { r = hAvg; b = vAvg; } else { b = hAvg; r = vAvg; }
                }
                else
                {
                    g = cross;
                    if (here == 0) { r = v; b = diag; } else { b = v; r = diag; }
                }
                int i = y0 + x;
                dst[i] = r; dst[n + i] = g; dst[2 * n + i] = b;
            }
        });
        rgb.Header.Remove("BAYERPAT");
        rgb.Header["DEBAYER"] = pattern.ToString();
        return rgb;
    }
}
