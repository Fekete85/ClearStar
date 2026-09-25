namespace ClearStar.Core.AI;

/// <summary>
/// Tile geometry shared by the GraXpert-style networks: the image is extended to a whole number
/// of strides by repeating its last rows/columns, then an overlap border is added by repeating
/// the first and last rows/columns of the extended image. Only the tile cores (stride × stride)
/// are written back, so seams fall inside the overlap.
/// </summary>
public readonly record struct Tiling(int Window, int Stride, int Width, int Height)
{
    public int Offset => (Window - Stride) / 2;
    /// <summary>Tiles down (rows) and across (columns).</summary>
    public int Rows => Height / Stride + 1;
    public int Cols => Width / Stride + 1;
    public int ExtendedHeight => Rows * Stride;
    public int ExtendedWidth => Cols * Stride;
    public int PaddedHeight => ExtendedHeight + 2 * Offset;
    public int PaddedWidth => ExtendedWidth + 2 * Offset;
    public int TileCount => Rows * Cols;

    /// <summary>Source row/column of a padded coordinate (see the class summary).</summary>
    public static int PadIndex(int padded, int size, int extended, int offset)
    {
        int r = padded < offset ? padded : padded < offset + extended ? padded - offset : padded - 2 * offset;
        r = Math.Clamp(r, 0, extended - 1);
        if (r < size) return r;
        int m = r - (extended - size);          // repeat the last rows, as GraXpert does
        return m >= 0 ? m : r % size;           // tiny images (extension larger than the image): wrap around
    }

    public int[] RowMap()
    {
        var map = new int[PaddedHeight];
        for (int y = 0; y < map.Length; y++) map[y] = PadIndex(y, Height, ExtendedHeight, Offset);
        return map;
    }

    public int[] ColMap()
    {
        var map = new int[PaddedWidth];
        for (int x = 0; x < map.Length; x++) map[x] = PadIndex(x, Width, ExtendedWidth, Offset);
        return map;
    }

    /// <summary>Padded copy of one channel (planar data starting at <paramref name="offset"/>).</summary>
    public float[] Pad(float[] data, int channelOffset, int[] rowMap, int[] colMap)
    {
        int pw = PaddedWidth, w = Width;
        var dst = new float[PaddedHeight * pw];
        Parallel.For(0, PaddedHeight, y =>
        {
            int srow = channelOffset + rowMap[y] * w;
            for (int x = 0; x < pw; x++) dst[y * pw + x] = data[srow + colMap[x]];
        });
        return dst;
    }

    /// <summary>Copies the unpadded image area out of a padded buffer.</summary>
    public void Unpad(float[] padded, Span<float> dst)
    {
        int pw = PaddedWidth, off = Offset;
        for (int y = 0; y < Height; y++)
            padded.AsSpan((y + off) * pw + off, Width).CopyTo(dst.Slice(y * Width, Width));
    }
}
