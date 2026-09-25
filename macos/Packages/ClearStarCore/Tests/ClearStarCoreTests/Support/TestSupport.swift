import Foundation
import Testing
@testable import ClearStarCore

/// Paths and one-time setup shared by the tests.
enum TestEnv {
    /// The repository root (…/ClearStar), found from this file's location.
    static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("shared/Languages").path) { return url }
        }
        fatalError("repository root not found")
    }()

    static let languages = repo.appendingPathComponent("shared/Languages")
    static let testdata = repo.appendingPathComponent("testdata")
    /// Synthetic references written by `clearstar-cli reference synthetic` (see macos/tools/make-references.sh).
    static let synthetic = testdata.appendingPathComponent("reference/synthetic")
    /// References from the real test images (`clearstar-cli reference real`).
    static let real = testdata.appendingPathComponent("reference/m31")
    static let m31 = testdata.appendingPathComponent("M31")
    static let models = testdata.appendingPathComponent("models")
    static let catalog = testdata.appendingPathComponent("catalog/siril_cat_healpix8_astro.dat")

    /// English texts (the references were made with English), settings in a private temporary folder.
    static let setUp: Void = {
        L.directories = [languages]
        L.load("en")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClearStarTests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.useRoot(root)
    }()

    static var hasRealData: Bool { FileManager.default.fileExists(atPath: m31.path) }

    /// The real test data sets whose frames and C# references are present.
    static let dataSets: [DataSet] = [
        DataSet(folder: "M31", ref: "m31", object: "M 31"),
        DataSet(folder: "M99", ref: "m99", object: nil),
        // Solves after the background step, but not after sharpening + noise reduction – the C# chain fails the same way.
        DataSet(folder: "NGC6992_sub", ref: "ngc6992", object: nil, chainSolves: false),
    ].filter { FileManager.default.fileExists(atPath: $0.frames.path) && FileManager.default.fileExists(atPath: $0.refDir.appendingPathComponent("stack.fits").path) }
}

/// For suites that set the process-wide state of the steps (catalogues, StarNet, the star layers, GPU switch):
/// their tests run one at a time across all such suites (`.serialized` only orders tests within one suite).
struct GlobalStateTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await GlobalStateLock.shared.lock()
        do { try await function() } catch { GlobalStateLock.shared.unlock(); throw error }
        GlobalStateLock.shared.unlock()
    }
}

extension Trait where Self == GlobalStateTrait {
    static var globalState: Self { GlobalStateTrait() }
}

final class GlobalStateLock: @unchecked Sendable {
    static let shared = GlobalStateLock()
    private let mutex = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            mutex.lock()
            if locked { waiters.append(c) } else { locked = true; c.resume() }
            mutex.unlock()
        }
    }

    func unlock() {
        mutex.lock()
        if waiters.isEmpty { locked = false; mutex.unlock() } else { let next = waiters.removeFirst(); mutex.unlock(); next.resume() }
    }
}

/// A folder of real frames with its C# reference outputs (testdata/reference/<ref>).
struct DataSet: Sendable, CustomTestStringConvertible {
    let folder: String
    let ref: String
    /// The object name typed for the plate solve (nil: from the header).
    let object: String?
    /// Whether the whole chain (plate solve after the AI steps) identifies the sky.
    var chainSolves = true
    var frames: URL { TestEnv.testdata.appendingPathComponent(folder) }
    var refDir: URL { TestEnv.testdata.appendingPathComponent("reference/\(ref)") }
    var testDescription: String { folder }
}

/// Reading the reference files.
enum Ref {
    static func url(_ name: String, real: Bool = false) -> URL {
        _ = TestEnv.setUp
        return (real ? TestEnv.real : TestEnv.synthetic).appendingPathComponent(name)
    }

    static func url(_ name: String, in set: DataSet) -> URL {
        _ = TestEnv.setUp
        return set.refDir.appendingPathComponent(name)
    }

    static func image(_ name: String, in set: DataSet) throws -> AstroImage { try FitsReader.read(url(name + ".fits", in: set).path) }

    static func dict(_ name: String, in set: DataSet) throws -> [String: Any] {
        let data = try Data(contentsOf: url(name + ".json", in: set))
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"NaN\"", with: "null").replacingOccurrences(of: "NaN", with: "null")
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func text(_ name: String, in set: DataSet) throws -> String { try String(contentsOf: url(name, in: set), encoding: .utf8) }

    static func image(_ name: String, real: Bool = false) throws -> AstroImage {
        let u = url(name + ".fits", real: real)
        guard FileManager.default.fileExists(atPath: u.path) else {
            throw ClearStarError("Missing reference \(u.path) – run macos/tools/make-references.sh")
        }
        return try FitsReader.read(u.path)
    }

    static func json(_ name: String, real: Bool = false) throws -> Any {
        let u = url(name + ".json", real: real)
        guard let data = try? Data(contentsOf: u) else { throw ClearStarError("Missing reference \(u.path) – run macos/tools/make-references.sh") }
        // The C# writer uses NaN / Infinity literals.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"NaN\"", with: "null").replacingOccurrences(of: "NaN", with: "null")
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    static func dict(_ name: String, real: Bool = false) throws -> [String: Any] { try json(name, real: real) as! [String: Any] }

    static func text(_ name: String, real: Bool = false) throws -> String {
        try String(contentsOf: url(name, real: real), encoding: .utf8)
    }
}

extension Dictionary where Key == String, Value == Any {
    func d(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? .nan }
    func f(_ k: String) -> Float { Float(d(k)) }
    func arr(_ k: String) -> [Any] { self[k] as? [Any] ?? [] }
    func sub(_ k: String) -> [String: Any] { self[k] as? [String: Any] ?? [:] }
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }
func nums(_ v: Any?) -> [Double] { (v as? [Any] ?? []).map(num) }

/// Maximum absolute difference of two images (geometry must match).
func maxDiff(_ a: AstroImage, _ b: AstroImage) -> Float {
    guard a.width == b.width, a.height == b.height, a.channels == b.channels else { return .infinity }
    var m: Float = 0
    for i in 0 ..< a.data.count {
        let d = abs(a.data[i] - b.data[i])
        if d > m || d.isNaN { m = d.isNaN ? .infinity : d }
    }
    return m
}

/// Mean absolute difference.
func meanDiff(_ a: AstroImage, _ b: AstroImage) -> Double {
    guard a.data.count == b.data.count else { return .infinity }
    var s = 0.0
    for i in 0 ..< a.data.count { s += Double(abs(a.data[i] - b.data[i])) }
    return s / Double(a.data.count)
}

/// Fraction of pixels differing by more than `tol`.
func fractionOver(_ a: AstroImage, _ b: AstroImage, _ tol: Float) -> Double {
    guard a.data.count == b.data.count else { return 1 }
    var k = 0
    for i in 0 ..< a.data.count where abs(a.data[i] - b.data[i]) > tol { k += 1 }
    return Double(k) / Double(a.data.count)
}

/// Peak signal-to-noise ratio in dB (signal range 1).
func psnr(_ a: AstroImage, _ b: AstroImage) -> Double {
    guard a.data.count == b.data.count else { return 0 }
    var se = 0.0
    for i in 0 ..< a.data.count { let d = Double(a.data[i] - b.data[i]); se += d * d }
    let mse = se / Double(a.data.count)
    return mse == 0 ? 200 : 10 * log10(1 / mse)
}

/// Expects the image to match the reference within `tol` (maximum absolute difference).
func expectImage(_ image: AstroImage, _ refName: String, tol: Float = 1e-5, real: Bool = false, in set: DataSet? = nil,
                 sourceLocation: SourceLocation = #_sourceLocation) throws {
    let ref = try set.map { try Ref.image(refName, in: $0) } ?? Ref.image(refName, real: real)
    #expect(image.width == ref.width && image.height == ref.height && image.channels == ref.channels,
            "\(refName): geometry \(image.width)×\(image.height)×\(image.channels) vs \(ref.width)×\(ref.height)×\(ref.channels)", sourceLocation: sourceLocation)
    let d = maxDiff(image, ref)
    #expect(d <= tol, "\(refName): max diff \(d) > \(tol)", sourceLocation: sourceLocation)
}

func expectClose(_ a: Double, _ b: Double, _ tol: Double, _ what: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) <= tol || (a.isNaN && b.isNaN), "\(what): \(a) vs \(b)", sourceLocation: sourceLocation)
}

/// Runs a step synchronously in a test.
func runStep(_ step: any WorkflowStep, _ input: AstroImage?, _ configure: (StepParameters) -> Void = { _ in }, frames: FrameSet? = nil) async throws -> StepResult {
    let p = StepParameters(step.definition.parameters)
    configure(p)
    return try await step.run(WorkflowContext(input: input, frames: frames, parameters: p))
}
