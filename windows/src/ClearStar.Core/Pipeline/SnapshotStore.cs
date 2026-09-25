using ClearStar.Core.Imaging;

namespace ClearStar.Core.Pipeline;

/// <summary>
/// Lépésenkénti képállapotok tárolása. Egy 24 MP-es színes kép ~290 MB floatként, ezért
/// csak a legutóbbi néhány marad a memóriában, a többi nyers floatként a temp mappába kerül.
/// Így bármelyik lépéshez vissza lehet ugrani anélkül, hogy újra kellene számolni.
/// </summary>
public sealed class SnapshotStore : IDisposable
{
    private readonly string _folder;
    private readonly int _memoryLimit;
    private readonly Dictionary<int, AstroImage> _memory = new();
    private readonly LinkedList<int> _lru = new();
    private readonly Dictionary<int, SnapshotMeta> _onDisk = new();
    private readonly object _lock = new();

    private sealed record SnapshotMeta(string Path, int Width, int Height, int Channels, Dictionary<string, string> Header);

    public SnapshotStore(int memoryLimit = 3, string? folder = null)
    {
        _memoryLimit = Math.Max(1, memoryLimit);
        _folder = folder ?? Path.Combine(Path.GetTempPath(), "ClearStar", "snapshots", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_folder);
    }

    public bool Contains(int key)
    {
        lock (_lock) return _memory.ContainsKey(key) || _onDisk.ContainsKey(key);
    }

    public void Put(int key, AstroImage image)
    {
        lock (_lock)
        {
            _memory[key] = image;
            Touch(key);
            if (_onDisk.Remove(key, out var old)) TryDelete(old.Path);
            EvictIfNeeded();
        }
    }

    public AstroImage? Get(int key)
    {
        lock (_lock)
        {
            if (_memory.TryGetValue(key, out var img)) { Touch(key); return img; }
            if (!_onDisk.TryGetValue(key, out var meta)) return null;
            var loaded = ReadFromDisk(meta);
            _memory[key] = loaded;
            Touch(key);
            EvictIfNeeded();
            return loaded;
        }
    }

    public void Remove(int key)
    {
        lock (_lock)
        {
            _memory.Remove(key);
            _lru.Remove(key);
            if (_onDisk.Remove(key, out var meta)) TryDelete(meta.Path);
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _memory.Clear();
            _lru.Clear();
            foreach (var m in _onDisk.Values) TryDelete(m.Path);
            _onDisk.Clear();
        }
    }

    private void Touch(int key)
    {
        _lru.Remove(key);
        _lru.AddFirst(key);
    }

    private void EvictIfNeeded()
    {
        while (_memory.Count > _memoryLimit && _lru.Last is not null)
        {
            int victim = _lru.Last.Value;
            _lru.RemoveLast();
            if (_memory.Remove(victim, out var img) && !_onDisk.ContainsKey(victim))
                _onDisk[victim] = WriteToDisk(victim, img);
        }
    }

    private SnapshotMeta WriteToDisk(int key, AstroImage img)
    {
        string path = Path.Combine(_folder, $"step{key:D2}.f32");
        using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
        var bytes = System.Runtime.InteropServices.MemoryMarshal.AsBytes(img.Data.AsSpan());
        fs.Write(bytes);
        return new SnapshotMeta(path, img.Width, img.Height, img.Channels, new Dictionary<string, string>(img.Header, StringComparer.OrdinalIgnoreCase));
    }

    private static AstroImage ReadFromDisk(SnapshotMeta meta)
    {
        var data = new float[(long)meta.Width * meta.Height * meta.Channels];
        using var fs = new FileStream(meta.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
        var bytes = System.Runtime.InteropServices.MemoryMarshal.AsBytes(data.AsSpan());
        fs.ReadExactly(bytes);
        return new AstroImage(meta.Width, meta.Height, meta.Channels, data, new Dictionary<string, string>(meta.Header, StringComparer.OrdinalIgnoreCase));
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        Clear();
        try { Directory.Delete(_folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
