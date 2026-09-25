import CryptoKit
import Foundation

/// A catalogue star: ICRS position in degrees and Gaia G / BP / RP magnitudes (NaN when missing).
public struct CatalogStar: Sendable, Equatable {
    public var ra: Double, dec: Double, g: Float, bp: Float, rp: Float
    public init(_ ra: Double, _ dec: Double, _ g: Float, _ bp: Float, _ rp: Float) { self.ra = ra; self.dec = dec; self.g = g; self.bp = bp; self.rp = rp }
    public var bpRp: Float { bp - rp }
}

/// Source of catalogue stars for plate solving and colour calibration.
public protocol StarCatalog: Sendable {
    var name: String { get }
    /// Stars within `radiusDeg` of the centre, brightest first.
    func cone(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken) async throws -> [CatalogStar]
}

/// Network access for the online catalogues (replaceable in the tests).
public enum CatalogNetwork {
    static let userAgent = "ClearStar/0.1 (astrophoto processing; plate solving)"

    static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)
    }

    static func text(_ request: URLRequest, timeout: TimeInterval) async throws -> String {
        let (data, response) = try await session(timeout: timeout).data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The query cache: `~/Library/Caches/ClearStar/catalog-cache/<sha1(query)[:24]>.<ext>`.
    static func cacheFile(_ query: String, _ ext: String) -> URL {
        let hash = Insecure.SHA1.hash(data: Data(query.utf8)).map { String(format: "%02X", $0) }.joined()
        return AppPaths.caches.appendingPathComponent("catalog-cache").appendingPathComponent(String(hash.prefix(24)) + "." + ext)
    }
}

/// Invariant number formatting of the queries (.NET "0.00000" style).
private func fixed(_ v: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), v) }

/// Gaia DR3 (VizieR I/355) cone search over HTTP, cached on disk so a solved field solves offline again.
public struct VizierGaiaCatalog: StarCatalog {
    public static let baseUrl = "https://vizier.cds.unistra.fr/viz-bin/asu-tsv"
    public var name: String { "Gaia DR3 (VizieR)" }
    public init() {}

    public func cone(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken) async throws -> [CatalogStar] {
        let decText = (dec < 0 ? "-" : "+") + fixed(abs(dec), 5)
        let query = "-source=I/355/gaiadr3&-c=\(fixed(ra, 5)) \(decText)&-c.rd=\(fixed(radiusDeg, 3))&-c.eq=J2000&-out=RA_ICRS,DE_ICRS,Gmag,BPmag,RPmag&Gmag=<\(fixed(Double(magLimit), 1))&-out.max=\(maxStars)&-sort=Gmag"
        let cache = CatalogNetwork.cacheFile(query, "tsv")
        if let text = try? String(contentsOf: cache, encoding: .utf8) { return Self.parseTsv(text) }
        let url = URL(string: Self.baseUrl + "?" + query.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: "+", with: "%2B"))!
        let tsv = try await CatalogNetwork.text(URLRequest(url: url), timeout: 90)
        try ct.check()
        let stars = Self.parseTsv(tsv)
        if !stars.isEmpty {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? tsv.write(to: cache, atomically: true, encoding: .utf8)
        }
        return stars
    }

    /// VizieR TSV: '#' comments, a column-name line, a units line, a dashes line, then tab-separated rows.
    public static func parseTsv(_ tsv: String) -> [CatalogStar] {
        var result: [CatalogStar] = []
        var inData = false
        for raw in tsv.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !inData { if line.hasPrefix("---") { inData = true }; continue }
            let f = line.components(separatedBy: "\t")
            if f.count < 3 { continue }
            guard let ra = parseDouble(f[0]), let dec = parseDouble(f[1]) else { continue }
            result.append(CatalogStar(ra, dec, mag(f, 2), mag(f, 3), mag(f, 4)))
        }
        return result
    }

    static func mag(_ f: [String], _ i: Int) -> Float {
        guard i < f.count, let v = parseDouble(f[i].trimmingCharacters(in: .whitespaces)) else { return .nan }
        return Float(v)
    }
}

/// Gaia DR3 cone search on the ESA Gaia archive (TAP/ADQL, typically 1–3 s), falling back to VizieR.
/// Results are cached on disk by query.
public struct GaiaOnlineCatalog: StarCatalog {
    public static let tapUrl = "https://gea.esac.esa.int/tap-server/tap/sync"
    public var name: String { "Gaia DR3" }
    let useFallback: Bool
    let timeout: TimeInterval

    public init(useVizierFallback: Bool = true, timeout: TimeInterval = 60) {
        useFallback = useVizierFallback
        self.timeout = timeout
    }

    public func cone(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken) async throws -> [CatalogStar] {
        let adql = "SELECT TOP \(maxStars) ra,dec,phot_g_mean_mag,phot_bp_mean_mag,phot_rp_mean_mag FROM gaiadr3.gaia_source WHERE 1=CONTAINS(POINT(ra,dec),CIRCLE(\(fixed(ra, 5)),\(fixed(dec, 5)),\(fixed(radiusDeg, 3)))) AND phot_g_mean_mag<\(fixed(Double(magLimit), 1)) ORDER BY phot_g_mean_mag"
        let cache = CatalogNetwork.cacheFile(adql, "csv")
        if let text = try? String(contentsOf: cache, encoding: .utf8) { return Self.parseCsv(text) }
        do {
            var request = URLRequest(url: URL(string: Self.tapUrl)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "REQUEST", value: "doQuery"), URLQueryItem(name: "LANG", value: "ADQL"),
                               URLQueryItem(name: "FORMAT", value: "csv"), URLQueryItem(name: "MAXREC", value: String(maxStars)),
                               URLQueryItem(name: "QUERY", value: adql)]
            request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            let csv = try await CatalogNetwork.text(request, timeout: timeout)
            let stars = Self.parseCsv(csv)
            if stars.isEmpty { throw URLError(.cannotParseResponse) }
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? csv.write(to: cache, atomically: true, encoding: .utf8)
            return stars
        } catch let e as URLError where useFallback && !ct.isCancelled {
            _ = e
            return try await VizierGaiaCatalog().cone(ra, dec, radiusDeg, magLimit, maxStars, ct)
        }
    }

    /// TAP csv: header line, then ra,dec,g,bp,rp rows (empty fields for a missing magnitude).
    public static func parseCsv(_ csv: String) -> [CatalogStar] {
        var result: [CatalogStar] = []
        var first = true
        for raw in csv.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            if first { first = false; continue }
            let f = line.components(separatedBy: ",")
            if f.count < 3 { continue }
            guard let ra = parseDouble(f[0]), let dec = parseDouble(f[1]) else { continue }
            result.append(CatalogStar(ra, dec, VizierGaiaCatalog.mag(f, 2), VizierGaiaCatalog.mag(f, 3), VizierGaiaCatalog.mag(f, 4)))
        }
        return result
    }
}

/// Object name → ICRS position via the CDS Sesame service (Simbad, NED, VizieR).
public enum NameResolver {
    public static let baseUrl = "https://cds.unistra.fr/cgi-bin/nph-sesame/-op/SNV?"

    public static func resolve(_ name: String) async throws -> (ra: Double, dec: Double)? {
        let escaped = name.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? name
        let text = try await CatalogNetwork.text(URLRequest(url: URL(string: baseUrl + escaped)!), timeout: 30)
        return parse(text)
    }

    /// The "%J ra dec" line of a Sesame plain-text answer.
    public static func parse(_ text: String) -> (ra: Double, dec: Double)? {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("%J ") else { continue }
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 3, let ra = parseDouble(f[1]), let dec = parseDouble(f[2]) { return (ra, dec) }
        }
        return nil
    }
}

/// The offline Gaia catalogue when one is on the machine, otherwise the online services.
public struct AutoStarCatalog: StarCatalog {
    public init() {}
    public var name: String { LocalGaiaCatalog.defaultCatalog()?.name ?? GaiaOnlineCatalog().name }
    public var isOffline: Bool { LocalGaiaCatalog.defaultCatalog() != nil }

    public func cone(_ ra: Double, _ dec: Double, _ radiusDeg: Double, _ magLimit: Float, _ maxStars: Int, _ ct: CancellationToken) async throws -> [CatalogStar] {
        if let local = LocalGaiaCatalog.defaultCatalog() { return try await local.cone(ra, dec, radiusDeg, magLimit, maxStars, ct) }
        return try await GaiaOnlineCatalog().cone(ra, dec, radiusDeg, magLimit, maxStars, ct)
    }
}
