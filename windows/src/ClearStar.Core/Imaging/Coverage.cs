namespace ClearStar.Core.Imaging;

/// <summary>
/// A stackelt kép adatokkal lefedett része: az elforgatott képek miatt a sarkokban üres (0 értékű)
/// területek vannak. Ez a legnagyobb olyan tengelypárhuzamos téglalapot keresi meg, amelyben már
/// nincs üres pixel – a vágás természetes kiindulópontja.
/// </summary>
public static class Coverage
{
    /// <summary>
    /// A legnagyobb, teljesen kitöltött téglalap a kép arányában (x, y, w, h ∈ 0..1), vagy null,
    /// ha a kép gyakorlatilag teljesen lefedett (nincs mit vágni).
    /// </summary>
    public static (double X, double Y, double W, double H)? LargestFilledRectangle(AstroImage image, int downsample = 4)
    {
        int w = image.Width / downsample, h = image.Height / downsample;
        if (w < 4 || h < 4) return null;
        int n = image.PixelsPerChannel, ch = image.Channels;
        var data = image.Data;

        // Egy cella akkor kitöltött, ha minden pixele hordoz adatot (bármelyik csatorna > 0).
        var filled = new bool[w * h];
        long empty = 0;
        Parallel.For(0, h, cy =>
        {
            for (int cx = 0; cx < w; cx++)
            {
                bool ok = true;
                for (int yy = 0; yy < downsample && ok; yy++)
                {
                    int row = (cy * downsample + yy) * image.Width + cx * downsample;
                    for (int xx = 0; xx < downsample; xx++)
                    {
                        int i = row + xx;
                        bool any = false;
                        for (int c = 0; c < ch; c++) if (data[c * n + i] > 0f) { any = true; break; }
                        if (!any) { ok = false; break; }
                    }
                }
                filled[cy * w + cx] = ok;
            }
        });
        for (int i = 0; i < filled.Length; i++) if (!filled[i]) empty++;
        if (empty < filled.Length * 0.002) return null;

        // Legnagyobb téglalap bináris mátrixban: soronként "hisztogram" + verem (O(w·h)).
        var heights = new int[w];
        int bestArea = 0, bx = 0, by = 0, bw = 0, bh = 0;
        var stack = new Stack<int>();
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++) heights[x] = filled[y * w + x] ? heights[x] + 1 : 0;
            stack.Clear();
            for (int x = 0; x <= w; x++)
            {
                int hx = x < w ? heights[x] : 0;
                while (stack.Count > 0 && heights[stack.Peek()] >= hx)
                {
                    int top = stack.Pop();
                    int height = heights[top];
                    int left = stack.Count > 0 ? stack.Peek() + 1 : 0;
                    int width = x - left;
                    if (width * height > bestArea) { bestArea = width * height; bx = left; by = y - height + 1; bw = width; bh = height; }
                }
                stack.Push(x);
            }
        }
        if (bestArea == 0) return null;
        // Egy cellányi biztonsági ráhagyás, hogy a lekicsinyítés miatti szélső pixelek se lógjanak ki.
        double x0 = (bx + 1) * downsample, y0 = (by + 1) * downsample;
        double x1 = (bx + bw - 1) * downsample, y1 = (by + bh - 1) * downsample;
        if (x1 <= x0 || y1 <= y0) return null;
        return (x0 / image.Width, y0 / image.Height, (x1 - x0) / image.Width, (y1 - y0) / image.Height);
    }
}
