import CryptoKit
import Foundation

public enum AiModelKind: String, CaseIterable, Sendable {
    case backgroundExtraction = "BackgroundExtraction"
    case denoise = "Denoise"
    case deconvolutionObject = "DeconvolutionObject"
    case deconvolutionStars = "DeconvolutionStars"

    /// Folder name on the mirror and in GraXpert's layout.
    var mirrorSubdir: String {
        switch self {
        case .backgroundExtraction: return "bge"
        case .denoise: return "denoise"
        case .deconvolutionObject: return "deconvolution-object"
        case .deconvolutionStars: return "deconvolution-stars"
        }
    }

    /// Folder in ClearStar's own model store (as on Windows: the kind in lower case).
    var ownSubdir: String { rawValue.lowercased() }
}

/// A model found on the machine: where it comes from, its version, its package.
public struct AiModelInfo: Sendable, Equatable {
    public var kind: AiModelKind
    public var version: String
    public var path: String
    public var source: String
    public var displayName: String { "\(version) – \(source)" }
}

/// A model available on ClearStar's mirror: version, download address, size and checksum.
public struct MirrorModel: Sendable, Equatable {
    public var kind: AiModelKind
    public var version: String
    public var url: String
    public var size: Int64
    public var sha256: String
    public var licenseUrl: String?
}

/// The Core ML models (GraXpert networks converted by macos/tools/convert-models) in ClearStar's own
/// folder, `~/Library/Application Support/ClearStar/ai-models/<kind>/<version>/model.mlpackage`. They
/// come from ClearStar's mirror (its manifest.json gives the versions, sizes and SHA-256 checked after
/// the download) or are imported by the user (.mlpackage or a zip holding one). The choice per kind
/// stays in the settings.
public enum AiModelStore {
    public static var modelsDirectory: URL { AppPaths.support.appendingPathComponent("ai-models", isDirectory: true) }

    public static func kindName(_ kind: AiModelKind) -> String {
        L.has("msg.model.kind.\(kind.rawValue)") ? L.t("msg.model.kind.\(kind.rawValue)") : kind.rawValue
    }

    /// The version of a model: the name of its folder.
    public static func versionOf(_ modelPath: String) -> String {
        URL(fileURLWithPath: modelPath).deletingLastPathComponent().lastPathComponent
    }

    /// Every model of the kind, newest version first.
    public static func listAvailable(_ kind: AiModelKind) -> [AiModelInfo] {
        let root = modelsDirectory.appendingPathComponent(kind.ownSubdir)
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var list: [AiModelInfo] = []
        for d in dirs {
            let pkg = root.appendingPathComponent(d).appendingPathComponent("model.mlpackage")
            if FileManager.default.fileExists(atPath: pkg.path) { list.append(AiModelInfo(kind: kind, version: d, path: pkg.path, source: "ClearStar")) }
        }
        return list.sorted { compareVersions($0.version, $1.version) > 0 }
    }

    /// Numeric version comparison ("1.10.0" > "1.9.2"); unparsable versions count as 0.0.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let p = s.split(separator: ".").map { Int($0) }
            return p.contains(nil) || p.count < 2 || p.count > 4 ? [0, 0] : p.map { $0! }
        }
        let x = parts(a), y = parts(b)
        for i in 0 ..< max(x.count, y.count) {
            let u = i < x.count ? x[i] : -1, v = i < y.count ? y[i] : -1
            if u != v { return u < v ? -1 : 1 }
        }
        return 0
    }

    /// The model the user chose, or (when none / gone) the newest available.
    public static func resolve(_ kind: AiModelKind) -> AiModelInfo? {
        let available = listAvailable(kind)
        if let preferred = UserSettings.get(settingKey(kind)) {
            if let m = available.first(where: { $0.path == preferred }) { return m }
            if FileManager.default.fileExists(atPath: preferred) {
                return AiModelInfo(kind: kind, version: versionOf(preferred), path: preferred, source: L.t("msg.model.ownFile"))
            }
        }
        return available.first
    }

    /// The model for a step: the explicitly chosen package when it exists, otherwise `resolve`.
    public static func resolve(_ kind: AiModelKind, explicitPath: String) -> AiModelInfo? {
        let p = explicitPath.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && FileManager.default.fileExists(atPath: p) {
            return AiModelInfo(kind: kind, version: versionOf(p), path: p, source: L.t("msg.bge.selectedSource"))
        }
        return resolve(kind)
    }

    public static func setPreferred(_ kind: AiModelKind, _ path: String?) { UserSettings.set(settingKey(kind), path) }

    /// Copies a model package (or a zip holding one) into ClearStar's model folder.
    @discardableResult
    public static func importModel(_ kind: AiModelKind, from source: URL, version: String? = nil) throws -> AiModelInfo {
        let version = version ?? guessVersion(source.path) ?? {
            let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd"; return f.string(from: Date())
        }()
        let dir = modelsDirectory.appendingPathComponent(kind.ownSubdir).appendingPathComponent(version)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("model.mlpackage")
        try? fm.removeItem(at: target)
        try? fm.removeItem(at: dir.appendingPathComponent("model.mlmodelc"))
        if source.pathExtension.lowercased() == "zip" {
            let temp = AppPaths.temporary.appendingPathComponent("unzip-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try unzip(source, to: temp)
            guard let pkg = findPackage(in: temp) else { throw ClearStarError(L.t("msg.model.zipNoOnnx")) }
            try fm.moveItem(at: pkg, to: target)
        } else if source.pathExtension.lowercased() == "mlpackage" {
            try fm.copyItem(at: source, to: target)
        } else {
            throw ClearStarError(L.t("msg.model.zipNoOnnx"))
        }
        CoreMLRunner.unloadAll()
        let info = AiModelInfo(kind: kind, version: version, path: target.path, source: "ClearStar")
        setPreferred(kind, target.path)
        return info
    }

    private static func findPackage(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.pathExtension == "mlpackage" { return u }
        return nil
    }

    /// Unpacks a zip with the system's ditto (the app is not sandboxed).
    static func unzip(_ zip: URL, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw ClearStarError("unzip failed (\(p.terminationStatus))") }
    }

    /// The newest model of the kind in the mirror's manifest.json, or nil when there is none.
    public static func latestOnMirror(_ kind: AiModelKind) async throws -> MirrorModel? {
        let (data, _) = try await session.data(from: URL(string: AppLinks.mirror + "manifest.json")!)
        return try latestInManifest(data, kind, baseUrl: AppLinks.mirror)
    }

    /// Among the manifest's (files[]: path, size, sha256) `coreml/<kind>/<version>/model.mlpackage.zip`
    /// entries the highest version, with the LICENSE.html next to it.
    public static func latestInManifest(_ json: Data, _ kind: AiModelKind, baseUrl: String) throws -> MirrorModel? {
        let prefix = "coreml/\(kind.mirrorSubdir)/"
        let modelFile = "/model.mlpackage.zip"
        var files: [(path: String, size: Int64, sha: String)] = []
        do {
            guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any], let list = root["files"] as? [[String: Any]] else {
                throw ClearStarError("manifest")
            }
            for f in list {
                guard let path = f["path"] as? String, let size = (f["size"] as? NSNumber)?.int64Value, let sha = f["sha256"] as? String else {
                    throw ClearStarError("manifest")
                }
                if path.hasPrefix(prefix) { files.append((path, size, sha)) }
            }
        } catch {
            throw ClearStarError(L.t("msg.model.mirrorManifest"))
        }
        var best: MirrorModel?
        for f in files where f.path.hasSuffix(modelFile) {
            let version = String(f.path.dropFirst(prefix.count).dropLast(modelFile.count))
            if version.isEmpty || version.contains("/") { continue }
            if let b = best, compareVersions(version, b.version) <= 0 { continue }
            let license = prefix + version + "/LICENSE.html"
            best = MirrorModel(kind: kind, version: version, url: baseUrl + f.path, size: f.size, sha256: f.sha,
                               licenseUrl: files.contains { $0.path == license } ? baseUrl + license : nil)
        }
        return best
    }

    /// Downloads a model from the mirror (with its licence) into ClearStar's model folder, checking size
    /// and SHA-256. A bad download leaves no model behind.
    @discardableResult
    public static func downloadFromMirror(_ model: MirrorModel, progress: (@Sendable (Double) -> Void)? = nil) async throws -> AiModelInfo {
        let fm = FileManager.default
        let dir = modelsDirectory.appendingPathComponent(model.kind.ownSubdir).appendingPathComponent(model.version)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent("model.mlpackage.zip.part")
        defer { try? fm.removeItem(at: partial) }
        let hash = try await Downloader.download(URL(string: model.url)!, to: partial, progress: progress)
        let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? -1
        if hash.lowercased() != model.sha256.lowercased() || size != model.size { throw ClearStarError(L.t("msg.model.checksum")) }
        if let lic = model.licenseUrl, let url = URL(string: lic) {
            let (data, _) = try await session.data(from: url)
            try data.write(to: dir.appendingPathComponent("LICENSE.html"))
        }
        let temp = AppPaths.temporary.appendingPathComponent("unzip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try unzip(partial, to: temp)
        guard let pkg = findPackage(in: temp) else { throw ClearStarError(L.t("msg.model.checksum")) }
        let target = dir.appendingPathComponent("model.mlpackage")
        try? fm.removeItem(at: target)
        try? fm.removeItem(at: dir.appendingPathComponent("model.mlmodelc"))
        try fm.moveItem(at: pkg, to: target)
        CoreMLRunner.unloadAll()
        setPreferred(model.kind, target.path)
        return AiModelInfo(kind: model.kind, version: model.version, path: target.path, source: "ClearStar")
    }

    /// Downloads a model (.zip holding a package) from any URL, then imports it.
    @discardableResult
    public static func download(_ kind: AiModelKind, from url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> AiModelInfo {
        let temp = AppPaths.temporary.appendingPathComponent("download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent(url.lastPathComponent.isEmpty ? "model.zip" : url.lastPathComponent)
        _ = try await Downloader.download(url, to: file, progress: progress)
        return try importModel(kind, from: file, version: guessVersion(url.absoluteString))
    }

    static func guessVersion(_ s: String) -> String? {
        guard let r = s.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    static func settingKey(_ kind: AiModelKind) -> String { "model.\(kind.rawValue)" }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "ClearStar/0.1 (AI model download)"]
        return URLSession(configuration: c)
    }()
}

/// Streaming download with an incremental SHA-256 (file:// URLs work too – the tests' local mirror).
public enum Downloader {
    public static func download(_ url: URL, to file: URL, userAgent: String = "ClearStar/0.1",
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ClearStarError("HTTP \(http.statusCode)")
        }
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var read: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                read += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress?(Double(read) / Double(total)) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            read += Int64(buffer.count)
        }
        progress?(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
