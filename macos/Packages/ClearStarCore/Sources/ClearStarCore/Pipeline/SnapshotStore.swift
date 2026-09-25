import Foundation

/// Per-step image states. A 24 MP colour image is ~290 MB as floats, so only the last few stay in
/// memory; the rest goes to the temporary folder as raw floats. Any step can be revisited without
/// recomputing.
public final class SnapshotStore: @unchecked Sendable {
    private let folder: URL
    private let memoryLimit: Int
    private var memory: [Int: AstroImage] = [:]
    private var lru: [Int] = []          // most recent first
    private var onDisk: [Int: Meta] = [:]
    private let lock = NSLock()

    private struct Meta {
        let url: URL
        let width: Int, height: Int, channels: Int
        let header: FitsHeader
    }

    public init(memoryLimit: Int = 3, folder: URL? = nil) {
        self.memoryLimit = max(1, memoryLimit)
        self.folder = folder ?? AppPaths.temporary.appendingPathComponent("snapshots/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    deinit {
        clear()
        try? FileManager.default.removeItem(at: folder)
    }

    public func contains(_ key: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return memory[key] != nil || onDisk[key] != nil
    }

    public func put(_ key: Int, _ image: AstroImage) {
        lock.lock(); defer { lock.unlock() }
        memory[key] = image
        touch(key)
        if let old = onDisk.removeValue(forKey: key) { try? FileManager.default.removeItem(at: old.url) }
        evictIfNeeded()
    }

    public func get(_ key: Int) -> AstroImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = memory[key] { touch(key); return img }
        guard let meta = onDisk[key], let loaded = read(meta) else { return nil }
        memory[key] = loaded
        touch(key)
        evictIfNeeded()
        return loaded
    }

    public func remove(_ key: Int) {
        lock.lock(); defer { lock.unlock() }
        memory.removeValue(forKey: key)
        lru.removeAll { $0 == key }
        if let meta = onDisk.removeValue(forKey: key) { try? FileManager.default.removeItem(at: meta.url) }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        memory.removeAll()
        lru.removeAll()
        for m in onDisk.values { try? FileManager.default.removeItem(at: m.url) }
        onDisk.removeAll()
    }

    /// Number of snapshots currently written to disk (tests).
    public var diskCount: Int { lock.lock(); defer { lock.unlock() }; return onDisk.count }

    private func touch(_ key: Int) {
        lru.removeAll { $0 == key }
        lru.insert(key, at: 0)
    }

    private func evictIfNeeded() {
        while memory.count > memoryLimit, let victim = lru.last {
            lru.removeLast()
            if let img = memory.removeValue(forKey: victim), onDisk[victim] == nil, let meta = write(victim, img) {
                onDisk[victim] = meta
            }
        }
    }

    private func write(_ key: Int, _ img: AstroImage) -> Meta? {
        let url = folder.appendingPathComponent(String(format: "step%02d.f32", key))
        let data = img.data.withUnsafeBufferPointer { Data(buffer: $0) }
        do { try data.write(to: url) } catch { return nil }
        return Meta(url: url, width: img.width, height: img.height, channels: img.channels, header: img.header)
    }

    private func read(_ meta: Meta) -> AstroImage? {
        guard let data = try? Data(contentsOf: meta.url) else { return nil }
        let count = meta.width * meta.height * meta.channels
        guard data.count == count * 4 else { return nil }
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        return AstroImage(width: meta.width, height: meta.height, channels: meta.channels, data: values, header: meta.header)
    }
}
