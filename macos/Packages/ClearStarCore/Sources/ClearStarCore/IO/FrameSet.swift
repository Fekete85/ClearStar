import Foundation

public enum FrameType: String, Sendable { case light = "Light", dark = "Dark", flat = "Flat", bias = "Bias", unknown = "Unknown" }

public struct FrameInfo: Sendable, Equatable, Hashable {
    public var path: String
    public var type: FrameType
    public var exposureSeconds: Double
    public var width: Int
    public var height: Int
    public var filter: String?
    public var objectName: String?

    public init(path: String, type: FrameType, exposureSeconds: Double, width: Int, height: Int, filter: String?, objectName: String? = nil) {
        self.path = path; self.type = type; self.exposureSeconds = exposureSeconds; self.width = width; self.height = height
        self.filter = filter; self.objectName = objectName
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// The images of a folder sorted by type.
public final class FrameSet: @unchecked Sendable {
    public let folder: String
    public let frames: [FrameInfo]

    public init(folder: String, frames: [FrameInfo]) {
        self.folder = folder
        self.frames = frames
    }

    public var lights: [FrameInfo] { frames.filter { $0.type == .light } }
    public var darks: [FrameInfo] { frames.filter { $0.type == .dark } }
    public var flats: [FrameInfo] { frames.filter { $0.type == .flat } }
    public var biases: [FrameInfo] { frames.filter { $0.type == .bias } }

    public func count(_ type: FrameType) -> Int { frames.filter { $0.type == type }.count }

    public var totalLightExposure: Double { lights.reduce(0) { $0 + $1.exposureSeconds } }

    private static let frameFolders = ["lights", "light", "darks", "dark", "flats", "flat", "bias", "biases", "offset"]

    /// Reads a folder: for FITS the header's IMAGETYP decides, otherwise the file/subfolder name. Only
    /// the folder and the frame-type subfolders (lights, darks, flats, bias) count – other programs'
    /// work folders (e.g. Siril's process/) hold intermediate files.
    public static func scan(_ folder: String, progress: ((Double) -> Void)? = nil, ct: CancellationToken = .none) throws -> FrameSet {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        var roots = entries.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name), isDirectory: &isDir) && isDir.boolValue
                && frameFolders.contains(name.lowercased())
        }.map { (folder as NSString).appendingPathComponent($0) }
        // With frame-type subfolders only those count (finished results in the root do not).
        if roots.isEmpty { roots.append(folder) }
        var files: [String] = []
        for r in roots {
            for name in (try? fm.contentsOfDirectory(atPath: r)) ?? [] {
                let p = (r as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, isSupported(p) { files.append(p) }
            }
        }
        files.sort(by: ordinalIgnoreCaseLess)
        var frames: [FrameInfo] = []
        frames.reserveCapacity(files.count)
        for (i, f) in files.enumerated() {
            try ct.check()
            frames.append(inspect(f, rootFolder: folder))
            progress?(Double(i + 1) / Double(files.count))
        }
        return FrameSet(folder: folder, frames: frames)
    }

    private static func isSupported(_ path: String) -> Bool { ImageFiles.isSupported(path) }

    public static func inspect(_ path: String, rootFolder: String? = nil) -> FrameInfo {
        var type = FrameType.unknown
        var exposure = 0.0
        var w = 0, h = 0
        var filter: String?
        var objectName: String?

        if FitsReader.isFits(path), let header = try? FitsReader.readHeader(path) {
            if let t = header["IMAGETYP"] { type = parseType(t) }
            if let e = header["EXPTIME"] ?? header["EXPOSURE"] { exposure = parseDouble(e) ?? 0 }
            w = parseInt(header["NAXIS1"]) ?? 0
            h = parseInt(header["NAXIS2"]) ?? 0
            filter = header["FILTER"]
            if let o = header["OBJECT"]?.trimmingCharacters(in: .whitespaces), !o.isEmpty { objectName = o }
        }

        if type == .unknown {
            let relative: String
            if let root = rootFolder, path.hasPrefix(root) {
                relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                relative = (path as NSString).lastPathComponent
            }
            type = parseType(relative)
            // Nothing points to a type: a light frame – the most common case for a beginner.
            if type == .unknown { type = .light }
        }
        return FrameInfo(path: path, type: type, exposureSeconds: exposure, width: w, height: h, filter: filter, objectName: objectName)
    }

    static func parseType(_ text: String) -> FrameType {
        let s = text.lowercased()
        if s.contains("bias") || s.contains("offset") { return .bias }
        if s.contains("dark") { return .dark }
        if s.contains("flat") { return .flat }
        if s.contains("light") || s.contains("object") || s.contains("science") { return .light }
        return .unknown
    }
}

/// Guesses the imaged object's name for pre-filling the plate-solve step.
public enum ObjectNameGuess {
    // Catalogue designations such as "NGC6992", "M 31", "IC_1396", "Sh2-101" – also inside folder names
    // like "NGC6992_0905" (underscore and digits around the designation are allowed).
    private static let designation = try! NSRegularExpression(
        pattern: "(?<![A-Za-z])(M|NGC|IC|Sh2|SH2|Abell|Barnard|Cr|Mel|Tr|LDN|LBN|vdB|Ced|PK|Arp|UGC|PGC)[ _\\-]?(\\d+[A-Za-z]?)(?![A-Za-z0-9])",
        options: [.caseInsensitive])

    /// The OBJECT keyword of the first light frame, otherwise a catalogue designation in the folder name.
    public static func from(_ frames: FrameSet) -> String? {
        if let fromHeader = frames.lights.compactMap(\.objectName).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return fromHeader
        }
        var folder = frames.folder
        while folder.hasSuffix("/") { folder.removeLast() }
        return fromText((folder as NSString).lastPathComponent)
    }

    public static func fromText(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = designation.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var cat = ns.substring(with: m.range(at: 1)).uppercased()
        let num = ns.substring(with: m.range(at: 2))
        if cat == "SH2" { return "Sh2-\(num)" }
        if cat == "VDB" { cat = "vdB" }
        else if ["ABELL", "BARNARD", "MEL", "CED", "TR", "CR"].contains(cat) { cat = String(cat.prefix(1)) + cat.dropFirst().lowercased() }
        return "\(cat) \(num)"
    }
}
