using System.Net.Http;
using System.Security.Cryptography;
using ICSharpCode.SharpZipLib.BZip2;

namespace ClearStar.Core.Astrometry;

/// <summary>
/// Downloads the offline Gaia DR3 astrometry catalogue (Siril Astrometry Catalogue, CC BY 4.0,
/// published on Zenodo as a bzip2 file of ~1.1 GB and copied to ClearStar's mirror) into ClearStar's catalogue folder, decompressing
/// on the fly and verifying the published SHA-256 of the uncompressed file (~1.5 GB).
/// </summary>
public static class CatalogDownloader
{
    /// <summary>Mirrors tried in order; a failed download or checksum moves on to the next.</summary>
    public static readonly string[] Mirrors =
    [
        // A URL ending in .bz2 is unpacked on the fly; a plain .dat mirror is copied as is.
        // The author's mirror first (faster than Zenodo), the publisher's record as fallback.
        AppLinks.Mirror + "siril/catalogs/siril_cat_healpix8_astro.dat.bz2",
        "https://zenodo.org/records/14692304/files/siril_cat_healpix8_astro.dat.bz2?download=1",
    ];
    public const string RecordUrl = "https://zenodo.org/records/14692304";
    public const string ExpectedSha256 = "2fa40c93fe115235d35c5050757f2ef60a326a6f3030f87be1598c016fcb2388";
    public const long CompressedSize = 1_142_276_749;
    public const long UncompressedSize = 1_521_132_640;

    public static string TargetDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClearStar", "catalogs");
    public static string TargetPath => Path.Combine(TargetDir, LocalGaiaCatalog.DefaultFileName);

    public sealed record Progress(double Fraction, long BytesDownloaded, long BytesTotal, string Phase);

    /// <summary>Downloads, unpacks and verifies the catalogue; returns the final path. Throws on checksum mismatch.</summary>
    public static async Task<string> DownloadAsync(IProgress<Progress>? progress, CancellationToken ct)
    {
        Directory.CreateDirectory(TargetDir);
        string partial = TargetPath + ".part";
        Exception? last = null;
        foreach (var url in Mirrors)
        {
            try
            {
                await DownloadFromAsync(url, partial, progress, ct);
                File.Move(partial, TargetPath, overwrite: true);
                UserSettings.Set(LocalGaiaCatalog.PathSettingKey, TargetPath);
                return TargetPath;
            }
            catch (Exception ex) when (ex is HttpRequestException or IOException && !ct.IsCancellationRequested)
            {
                last = ex;
            }
        }
        try { File.Delete(partial); } catch (IOException) { }
        throw last ?? new HttpRequestException("no mirror available");
    }

    private static async Task DownloadFromAsync(string url, string partial, IProgress<Progress>? progress, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ClearStar/0.1 (offline star catalogue download)");
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        long total = response.Content.Headers.ContentLength ?? CompressedSize;

        await using var network = await response.Content.ReadAsStreamAsync(ct);
        var counting = new CountingStream(network);
        // Mirrors may serve the bzip2 file (Zenodo) or the plain .dat (a fast private mirror).
        bool compressed = url.Contains(".bz2", StringComparison.OrdinalIgnoreCase);
        await using Stream bzip = compressed ? new BZip2InputStream(counting) { IsStreamOwner = false } : counting;
        await using var file = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
        using var sha = SHA256.Create();

        var buffer = new byte[1 << 20];
        long written = 0;
        var lastReport = DateTime.MinValue;
        int n;
        while ((n = await bzip.ReadAsync(buffer, ct)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, n), ct);
            sha.TransformBlock(buffer, 0, n, null, 0);
            written += n;
            if ((DateTime.UtcNow - lastReport).TotalMilliseconds > 250)
            {
                lastReport = DateTime.UtcNow;
                progress?.Report(new Progress(Math.Min(0.999, counting.BytesRead / (double)total), counting.BytesRead, total, "download"));
            }
        }
        sha.TransformFinalBlock([], 0, 0);
        string hash = Convert.ToHexString(sha.Hash!).ToLowerInvariant();
        if (!string.Equals(hash, ExpectedSha256, StringComparison.OrdinalIgnoreCase) || written != UncompressedSize)
            throw new IOException($"checksum mismatch ({hash[..12]}…, {written} bytes)");
        progress?.Report(new Progress(1.0, total, total, "done"));
    }

    /// <summary>Wraps a stream and counts the bytes read from it (download progress of the compressed data).</summary>
    private sealed class CountingStream(Stream inner) : Stream
    {
        public long BytesRead { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => BytesRead; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) { int n = inner.Read(buffer, offset, count); BytesRead += n; return n; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) { int n = await inner.ReadAsync(buffer, ct); BytesRead += n; return n; }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
