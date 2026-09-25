import CoreML
import Foundation

/// Loads the converted GraXpert networks (`model.mlpackage`) and runs them. Compiled models are cached
/// next to the package (`model.mlmodelc`) and kept loaded per path and compute setting. With the
/// `ai.gpu` setting off everything runs on the CPU, like the Windows version's GPU switch.
public enum CoreMLRunner {
    /// Settings key; "false" disables the GPU / Neural Engine.
    public static let gpuSettingKey = "ai.gpu"

    public static var gpuEnabled: Bool {
        get { UserSettings.get(gpuSettingKey)?.lowercased() != "false" }
        set { UserSettings.set(gpuSettingKey, newValue ? nil : "false") }
    }

    /// Which units the most recently loaded model uses ("GPU" or "CPU") – shown in the step summaries.
    public static var lastProvider: String { state.current.lastProvider }

    private struct State { var models: [String: MLModel] = [:]; var warm: Set<String> = []; var lastProvider = "CPU" }
    private static let state = Locked(State())
    /// Loading a large model takes seconds: one load at a time, so a warm-up and a run never load it twice.
    private static let loadLock = NSLock()

    /// The loaded model for a package (compiling it on first use).
    public static func load(_ packagePath: String) throws -> MLModel {
        let gpu = gpuEnabled
        let key = packagePath + (gpu ? "#all" : "#cpu")
        loadLock.lock()
        defer { loadLock.unlock() }
        if let m = state.current.models[key] {
            state.withLock { $0.lastProvider = gpu ? "GPU" : "CPU" }
            return m
        }
        let compiled = try compiledURL(packagePath)
        let config = MLModelConfiguration()
        config.computeUnits = gpu ? .all : .cpuOnly
        let model = try MLModel(contentsOf: compiled, configuration: config)
        state.withLock { $0.models[key] = model; $0.lastProvider = gpu ? "GPU" : "CPU" }
        return model
    }

    /// Loads the model and runs one prediction on zeros, so the GPU pipeline is prepared before the user
    /// presses Apply (the first run of a large network otherwise spends tens of seconds on this). Safe to
    /// call repeatedly and from any thread; errors are ignored (the real run reports them).
    public static func warmUp(_ packagePath: String) {
        let key = packagePath + (gpuEnabled ? "#all" : "#cpu")
        if state.current.warm.contains(key) { return }
        guard let model = try? load(packagePath) else { return }
        var inputs: [(name: String, shape: [Int], data: [Float])] = []
        for (name, desc) in model.modelDescription.inputDescriptionsByName {
            guard let shape = desc.multiArrayConstraint?.shape.map(\.intValue) else { return }
            inputs.append((name, shape, [Float](repeating: 0, count: shape.reduce(1, *))))
        }
        if (try? predict(model, inputs)) != nil { state.withLock { _ = $0.warm.insert(key) } }
    }

    /// Drops the loaded models (after a model was replaced or deleted).
    public static func unloadAll() { state.withLock { $0.models.removeAll(); $0.warm.removeAll() } }

    /// `model.mlmodelc` next to the package, compiled when missing or older than the package.
    static func compiledURL(_ packagePath: String) throws -> URL {
        let pkg = URL(fileURLWithPath: packagePath)
        if pkg.pathExtension == "mlmodelc" { return pkg }
        let target = pkg.deletingLastPathComponent().appendingPathComponent("model.mlmodelc")
        let fm = FileManager.default
        if let t = modified(target), let p = modified(pkg), t >= p { return target }
        let temp = try MLModel.compileModel(at: pkg)
        try? fm.removeItem(at: target)
        do { try fm.moveItem(at: temp, to: target) } catch {
            // A read-only location (e.g. a model inside the app bundle): use the temporary compilation.
            return temp
        }
        return target
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Names of the model's inputs.
    public static func inputNames(_ model: MLModel) -> Set<String> { Set(model.modelDescription.inputDescriptionsByName.keys) }

    /// Runs the model on float32 inputs of the given shapes; returns the first output as a flat float array.
    public static func predict(_ model: MLModel, _ inputs: [(name: String, shape: [Int], data: [Float])]) throws -> [Float] {
        var features: [String: MLFeatureValue] = [:]
        for input in inputs {
            let array = try MLMultiArray(shape: input.shape.map { NSNumber(value: $0) }, dataType: .float32)
            try fill(array, input.data)
            features[input.name] = MLFeatureValue(multiArray: array)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let out = try model.prediction(from: provider)
        let name = model.modelDescription.outputDescriptionsByName.keys.sorted().first { out.featureValue(for: $0)?.multiArrayValue != nil } ?? "output"
        guard let array = out.featureValue(for: name)?.multiArrayValue else { throw ClearStarError("Core ML: no output") }
        return read(array)
    }

    /// Copies row-major data into the array, honouring its strides.
    static func fill(_ array: MLMultiArray, _ data: [Float]) throws {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard data.count == shape.reduce(1, *) else { throw ClearStarError("Core ML: input size mismatch") }
        array.withUnsafeMutableBytes { raw, _ in
            let p = raw.bindMemory(to: Float.self)
            if isContiguous(shape, strides) {
                data.withUnsafeBufferPointer { s in p.baseAddress!.update(from: s.baseAddress!, count: data.count) }
                return
            }
            forEachIndex(shape) { flat, offset in p[offsetOf(offset, strides)] = data[flat] }
        }
    }

    /// Row-major float copy of an array (float32 or float16).
    static func read(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var result = [Float](repeating: 0, count: count)
        array.withUnsafeBytes { raw in
            switch array.dataType {
            case .float16:
                let p = raw.bindMemory(to: Float16.self)
                forEachIndex(shape) { flat, idx in result[flat] = Float(p[offsetOf(idx, strides)]) }
            case .double:
                let p = raw.bindMemory(to: Double.self)
                forEachIndex(shape) { flat, idx in result[flat] = Float(p[offsetOf(idx, strides)]) }
            default:
                let p = raw.bindMemory(to: Float.self)
                if isContiguous(shape, strides) {
                    result.withUnsafeMutableBufferPointer { d in d.baseAddress!.update(from: p.baseAddress!, count: count) }
                } else {
                    forEachIndex(shape) { flat, idx in result[flat] = p[offsetOf(idx, strides)] }
                }
            }
        }
        return result
    }

    private static func isContiguous(_ shape: [Int], _ strides: [Int]) -> Bool {
        var expected = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[d] > 1 && strides[d] != expected { return false }
            expected *= shape[d]
        }
        return true
    }

    @inline(__always) private static func offsetOf(_ idx: [Int], _ strides: [Int]) -> Int {
        var o = 0
        for d in 0 ..< idx.count { o += idx[d] * strides[d] }
        return o
    }

    private static func forEachIndex(_ shape: [Int], _ body: (Int, [Int]) -> Void) {
        let count = shape.reduce(1, *)
        var idx = [Int](repeating: 0, count: shape.count)
        for flat in 0 ..< count {
            body(flat, idx)
            var d = shape.count - 1
            while d >= 0 {
                idx[d] += 1
                if idx[d] < shape[d] { break }
                idx[d] = 0
                d -= 1
            }
        }
    }
}

/// Tile geometry shared by the GraXpert-style networks: the image is extended to a whole number of
/// strides by repeating its last rows/columns, then an overlap border is added by repeating the first
/// and last rows/columns of the extended image. Only the tile cores (stride × stride) are written back.
public struct Tiling: Sendable {
    public let window: Int, stride: Int, width: Int, height: Int
    public init(_ window: Int, _ stride: Int, _ width: Int, _ height: Int) {
        self.window = window; self.stride = stride; self.width = width; self.height = height
    }

    public var offset: Int { (window - stride) / 2 }
    public var rows: Int { height / stride + 1 }
    public var cols: Int { width / stride + 1 }
    public var extendedHeight: Int { rows * stride }
    public var extendedWidth: Int { cols * stride }
    public var paddedHeight: Int { extendedHeight + 2 * offset }
    public var paddedWidth: Int { extendedWidth + 2 * offset }
    public var tileCount: Int { rows * cols }

    /// Source row/column of a padded coordinate.
    public static func padIndex(_ padded: Int, _ size: Int, _ extended: Int, _ offset: Int) -> Int {
        var r = padded < offset ? padded : (padded < offset + extended ? padded - offset : padded - 2 * offset)
        r = r.clamped(0, extended - 1)
        if r < size { return r }
        let m = r - (extended - size)           // repeat the last rows, as GraXpert does
        return m >= 0 ? m : r % size            // tiny images (extension larger than the image): wrap around
    }

    public func rowMap() -> [Int] { (0 ..< paddedHeight).map { Self.padIndex($0, height, extendedHeight, offset) } }
    public func colMap() -> [Int] { (0 ..< paddedWidth).map { Self.padIndex($0, width, extendedWidth, offset) } }

    /// Padded copy of one channel (planar data starting at `channelOffset`).
    public func pad(_ data: [Float], _ channelOffset: Int, _ rowMap: [Int], _ colMap: [Int]) -> [Float] {
        let pw = paddedWidth, w = width
        var dst = [Float](repeating: 0, count: paddedHeight * pw)
        data.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                parallelFor(paddedHeight) { y in
                    let srow = channelOffset + rowMap[y] * w
                    for x in 0 ..< pw { d[y * pw + x] = s[srow + colMap[x]] }
                }
            }
        }
        return dst
    }

    /// Copies the unpadded area out of a padded buffer into `dst` at `dstOffset`.
    public func unpad(_ padded: [Float], into dst: inout [Float], at dstOffset: Int) {
        let pw = paddedWidth, off = offset
        for y in 0 ..< height {
            let s = (y + off) * pw + off, d = dstOffset + y * width
            for x in 0 ..< width { dst[d + x] = padded[s + x] }
        }
    }
}
