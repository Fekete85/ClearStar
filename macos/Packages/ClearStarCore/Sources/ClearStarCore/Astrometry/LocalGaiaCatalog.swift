import CBZip2
import CryptoKit
import Foundation

/// Offline Gaia DR3 catalogue in the Siril HEALPix Catalog Format 1.0.0 (the
/// `siril_cat_healpix8_astro.dat` file Siril downloads, ~1.5 GB): 128-byte header, a cumulative uint32
/// record-count index per HEALPix pixel (NESTED, level 8), then 16-byte records (RA/Dec scaled int32,
/// proper motions, T_eff, G magnitude ×1000) sorted by pixel. Colours come from T_eff.
public final class LocalGaiaCatalog: StarCatalog, @unchecked Sendable {
    public static let pathSettingKey = "catalog.gaiaAstro"
    public static let defaultFileName = "siril_cat_healpix8_astro.dat"
    static let headerSize = 128, recordSize = 16
    static let raDecScale = 360.0 / Double(Int32.max)

    public var name: String { "Gaia DR3 (offline)" }
    public let filePath: String
    public let level: Int
    private let healpix: Healpix
    private let index: [UInt32]

    private init(_ path: String, _ level: Int) throws {
        filePath = path
        self.level = level
        healpix = Healpix.forOrder(level)
        guard let h = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileReadNoPermission) }
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(Self.headerSize))
        let bytes = try h.read(upToCount: healpix.npix * 4) ?? Data()
        guard bytes.count == healpix.npix * 4 else { throw CocoaError(.fileReadCorruptFile) }
        index = bytes.withUnsafeBytes { raw in (0 ..< raw.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
    }

    /// Opens a catalogue after validating its header; nil when it is not a monolithic astro catalogue.
    public static func open(_ path: String) -> LocalGaiaCatalog? {
        guard FileManager.default.fileExists(atPath: path), let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: headerSize), header.count == headerSize else { return nil }
        let level = Int(header[49]), catType = header[50], chunked = header[51]
        if level < 1 || level > 12 || catType != 1 || chunked != 0 { return nil }
        let npix = 12 * (1 << level) * (1 << level)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size < headerSize + npix * 4 { return nil }
        return try? LocalGaiaCatalog(path, level)
    }

    /// Candidate files: ClearStar setting, Siril's configuration, Siril's and ClearStar's data folders.
    public static func candidates() -> [String] {
        var list: [String] = []
        if let own = UserSettings.get(pathSettingKey), !own.isEmpty { list.append(own) }
        list.append(contentsOf: StarNet.sirilSetting("catalogue_gaia_astro"))
        let home = AppPaths.home
        for dir in ["Library/Application Support/org.siril.Siril/siril", "Library/Application Support/org.siril.Siril", ".local/share/siril"] {
            list.append(home.appendingPathComponent(dir).appendingPathComponent(defaultFileName).path)
        }
        list.append(CatalogDownloader.targetPath.path)
        return list
    }

    public static func locate() -> String? { candidates().first { open($0) != nil } }

    private static let cached = Locked<LocalGaiaCatalog?>(nil)

    /// The first usable catalogue on this machine (kept open), or nil.
    public static func defaultCatalog() -> LocalGaiaCatalog? {
        if let c = cached.current, FileManager.default.fileExists(atPath: c.filePath), candidates().first(where: { FileManager.default.fileExists(atPath: $0) }) == c.filePath {
            return c
        }
        for c in candidates() {
            if let cat = open(c) { cached.current = cat; return cat }
        }
        cached.current = nil
        return nil
    }

    public func cone(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken) async throws -> [CatalogStar] {
        try await Task.detached { try self.coneSync(ra, dec, radiusDeg, magLimit, maxStars, ct) }.value
    }

    public func coneSync(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken = .none) throws -> [CatalogStar] {
        let pixels = healpix.queryDiscInclusive(ra, dec, radiusDeg)
        var result: [CatalogStar] = []
        let dataStart = UInt64(Self.headerSize + index.count * 4)
        let magScaledLimit = Int16(clamping: Int((Double(magLimit) * 1000).roundedEven))
        let cosRadius = cos(radiusDeg * .pi / 180)
        let ra0 = ra * .pi / 180, dec0 = dec * .pi / 180
        let cx = cos(dec0) * cos(ra0), cy = cos(dec0) * sin(ra0), cz = sin(dec0)
        guard let f = FileHandle(forReadingAtPath: filePath) else { throw CocoaError(.fileReadNoPermission) }
        defer { try? f.close() }
        var i = 0
        while i < pixels.count {
            try ct.check()
            // Runs of consecutive pixels are one read.
            var j = i
            while j + 1 < pixels.count && pixels[j + 1] == pixels[j] + 1 { j += 1 }
            let first = pixels[i] == 0 ? 0 : Int(index[pixels[i] - 1]), last = Int(index[pixels[j]])
            if last > first {
                let count = last - first
                try f.seek(toOffset: dataStart + UInt64(first * Self.recordSize))
                let buffer = try f.read(upToCount: count * Self.recordSize) ?? Data()
                buffer.withUnsafeBytes { raw in
                    for r in 0 ..< buffer.count / Self.recordSize {
                        let o = r * Self.recordSize
                        let magScaled = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 14, as: Int16.self))
                        if magScaled > magScaledLimit { continue }
                        let sra = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int32.self))) * Self.raDecScale
                        let sdec = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: Int32.self))) * Self.raDecScale
                        let dr = sra * .pi / 180, dd = sdec * .pi / 180
                        let dot = cos(dd) * cos(dr) * cx + cos(dd) * sin(dr) * cy + sin(dd) * cz
                        if dot < cosRadius { continue }
                        let teff = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 12, as: UInt16.self))
                        let g = Float(magScaled) / 1000
                        let colour: Float = teff > 0 ? Self.bpRpFromTeff(Float(teff)) : .nan
                        result.append(CatalogStar(sra, sdec, g, colour.isNaN ? .nan : g + colour / 2, colour.isNaN ? .nan : g - colour / 2))
                    }
                }
            }
            i = j + 1
        }
        // Stable sort by G (List.Sort in .NET is not stable, but the records come in file order and
        // equal G magnitudes are rare; stable keeps it deterministic).
        result = result.enumerated().sorted { a, b in a.element.g != b.element.g ? a.element.g < b.element.g : a.offset < b.offset }.map(\.element)
        if result.count > maxStars { result.removeLast(result.count - maxStars) }
        return result
    }

    // Approximate dwarf-star relation between Gaia BP−RP and effective temperature.
    private static let colourTable: [(bpRp: Float, teff: Float)] = [
        (-0.30, 20000), (-0.20, 15000), (-0.10, 12000), (0.00, 9700), (0.20, 8000), (0.40, 7200),
        (0.60, 6450), (0.82, 5770), (1.00, 5270), (1.20, 4900), (1.40, 4450), (1.60, 4250),
        (1.84, 3850), (2.20, 3550), (2.60, 3350), (3.00, 3200), (3.50, 3000),
    ]

    /// BP−RP for an effective temperature by interpolating the table (clamped at the ends).
    public static func bpRpFromTeff(_ teff: Float) -> Float {
        if teff >= colourTable[0].teff { return colourTable[0].bpRp }
        for k in 1 ..< colourTable.count where teff >= colourTable[k].teff {
            let (c0, t0) = colourTable[k - 1], (c1, t1) = colourTable[k]
            return c0 + (c1 - c0) * (t0 - teff) / (t0 - t1)
        }
        return colourTable[colourTable.count - 1].bpRp
    }
}

/// Downloads the offline Gaia DR3 astrometry catalogue (Siril Astrometry Catalogue, CC BY 4.0) into
/// ClearStar's catalogue folder, decompressing on the fly and checking the SHA-256 of the result.
public enum CatalogDownloader {
    /// Mirrors tried in order; a failed download or checksum moves on to the next. A URL with .bz2 is
    /// unpacked on the fly; a plain .dat is copied as is.
    public static var mirrors: [String] {
        [AppLinks.mirror + "siril/catalogs/siril_cat_healpix8_astro.dat.bz2",
         "https://zenodo.org/records/14692304/files/siril_cat_healpix8_astro.dat.bz2?download=1"]
    }
    public static let recordUrl = "https://zenodo.org/records/14692304"
    public static let expectedSha256 = "2fa40c93fe115235d35c5050757f2ef60a326a6f3030f87be1598c016fcb2388"
    public static let compressedSize: Int64 = 1_142_276_749
    public static let uncompressedSize: Int64 = 1_521_132_640

    public static var targetDirectory: URL { AppPaths.support.appendingPathComponent("catalogs", isDirectory: true) }
    public static var targetPath: URL { targetDirectory.appendingPathComponent(LocalGaiaCatalog.defaultFileName) }

    public struct Progress: Sendable { public var fraction: Double; public var bytesDownloaded: Int64; public var bytesTotal: Int64; public var phase: String }

    /// Downloads, unpacks and verifies the catalogue; returns the final path.
    @discardableResult
    public static func download(urls: [String]? = nil, expectedSha: String = expectedSha256, expectedSize: Int64 = uncompressedSize,
                                progress: (@Sendable (Progress) -> Void)? = nil, _ ct: CancellationToken = .none) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let partial = targetPath.appendingPathExtension("part")
        var last: Error?
        for url in urls ?? mirrors {
            do {
                try await downloadFrom(url, partial, expectedSha, expectedSize, progress, ct)
                try? fm.removeItem(at: targetPath)
                try fm.moveItem(at: partial, to: targetPath)
                UserSettings.set(LocalGaiaCatalog.pathSettingKey, targetPath.path)
                return targetPath
            } catch {
                if ct.isCancelled || error is CancellationError { try? fm.removeItem(at: partial); throw CancellationError() }
                last = error
            }
        }
        try? fm.removeItem(at: partial)
        throw last ?? ClearStarError("no mirror available")
    }

    private static func downloadFrom(_ urlText: String, _ partial: URL, _ expectedSha: String, _ expectedSize: Int64,
                                     _ progress: (@Sendable (Progress) -> Void)?, _ ct: CancellationToken) async throws {
        var request = URLRequest(url: URL(string: urlText)!)
        request.setValue("ClearStar/0.1 (offline star catalogue download)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw ClearStarError("HTTP \(http.statusCode)") }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : compressedSize
        let compressed = urlText.lowercased().contains(".bz2")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        var sha = SHA256()
        var written: Int64 = 0, read: Int64 = 0
        var lastReport = Date.distantPast
        let decoder = compressed ? try BZip2Decoder() : nil
        var chunk = [UInt8]()
        chunk.reserveCapacity(1 << 20)

        func emit(_ out: [UInt8]) throws {
            if out.isEmpty { return }
            let d = Data(out)
            try file.write(contentsOf: d)
            sha.update(data: d)
            written += Int64(out.count)
        }
        func flush() throws {
            read += Int64(chunk.count)
            if let decoder { try emit(try decoder.decode(chunk)) } else { try emit(chunk) }
            chunk.removeAll(keepingCapacity: true)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress?(Progress(fraction: min(0.999, Double(read) / Double(total)), bytesDownloaded: read, bytesTotal: total, phase: "download"))
            }
            try ct.check()
        }
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 20 { try flush() }
        }
        try flush()
        let hash = sha.finalize().map { String(format: "%02x", $0) }.joined()
        if hash != expectedSha.lowercased() || written != expectedSize {
            throw ClearStarError("checksum mismatch (\(hash.prefix(12))…, \(written) bytes)")
        }
        progress?(Progress(fraction: 1, bytesDownloaded: total, bytesTotal: total, phase: "done"))
    }
}

/// Streaming bzip2 decompression with the system's libbz2 (concatenated streams are handled).
final class BZip2Decoder {
    private var stream = bz_stream()
    private var ended = false

    init() throws {
        if BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK { throw ClearStarError("bzip2 init failed") }
    }

    deinit { BZ2_bzDecompressEnd(&stream) }

    func decode(_ input: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var remaining = input[...]
        while true {
            if ended {
                if remaining.isEmpty { return out }
                // A new stream follows (pbzip2-style files): restart the decoder.
                BZ2_bzDecompressEnd(&stream)
                stream = bz_stream()
                if BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK { throw ClearStarError("bzip2 init failed") }
                ended = false
            }
            let consumedBefore = remaining.count
            let (ret, produced, left): (Int32, Int, Int) = remaining.withUnsafeBufferPointer { inp in
                buffer.withUnsafeMutableBufferPointer { outp in
                    stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) })
                    stream.avail_in = UInt32(inp.count)
                    stream.next_out = UnsafeMutableRawPointer(outp.baseAddress!).assumingMemoryBound(to: CChar.self)
                    stream.avail_out = UInt32(outp.count)
                    let r = BZ2_bzDecompress(&stream)
                    return (r, outp.count - Int(stream.avail_out), Int(stream.avail_in))
                }
            }
            out.append(contentsOf: buffer[0 ..< produced])
            remaining = remaining.suffix(left)
            if ret == BZ_STREAM_END { ended = true; continue }
            if ret != BZ_OK { throw ClearStarError("bzip2 data error (\(ret))") }
            if left == 0 && produced < buffer.count { return out }
            if left == consumedBefore && produced == 0 { return out }
        }
    }
}
