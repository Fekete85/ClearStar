import Foundation

/// Egy elérhető nyelv: kód (pl. "hu"), saját nevén írt neve és a fájl helye.
public struct LanguageInfo: Sendable, Hashable {
    public let code: String
    public let name: String
    public let url: URL
}

/// Nyelvi adatbázis – a Windows-változat `L` osztályának megfelelője, ugyanazokból a
/// `shared/Languages/*.json` fájlokból. A beágyazott objektumok kulcsai ponttal fűződnek össze,
/// a tömbök "|"-vel. A hiányzó kulcsok az angol tartalékból, végső soron magából a kulcsból jönnek.
public struct Strings: Sendable {
    public static let defaultLanguage = "hu"
    public static let fallbackLanguage = "en"

    public let language: String
    private let table: [String: String]
    private let fallback: [String: String]
    private let locale: Locale

    /// Nyelv betöltése a megadott mappából (a tartalék mindig az angol).
    public init(language code: String, directory: URL) {
        self.init(language: code, directories: [directory])
    }

    /// Nyelv betöltése több mappából; a későbbi mappa azonos kódú fájlja felülírja a korábbit.
    public init(language code: String, directories: [URL]) {
        let langs = Self.available(in: directories)
        func load(_ c: String) -> [String: String]? {
            guard let info = langs.first(where: { $0.code.caseInsensitiveCompare(c) == .orderedSame }),
                  let data = try? Data(contentsOf: info.url) else { return nil }
            return try? Self.parse(data)
        }
        let fallback = load(Self.fallbackLanguage) ?? [:]
        if let table = load(code) {
            self.init(language: code, table: table, fallback: fallback)
        } else {
            self.init(language: Self.fallbackLanguage, table: fallback, fallback: fallback)
        }
    }

    /// Teszt: tábla közvetlen megadása.
    public init(language: String, table: [String: String], fallback: [String: String] = [:]) {
        self.language = language
        self.table = table
        self.fallback = fallback
        self.locale = Locale(identifier: language)
    }

    /// Szöveg kulcs alapján.
    public func t(_ key: String) -> String { table[key] ?? fallback[key] ?? key }

    /// Formázott szöveg a .NET-es helyőrzőkkel ({0}, {1:0.0}, {0:P1}, {2:+0.00;−0.00;0}).
    public func f(_ key: String, _ args: Any...) -> String { DotNetFormat.format(t(key), args, locale: locale) }

    /// Formázott szöveg tömbként átadott argumentumokkal, adott területi beállítással.
    public func format(_ key: String, _ args: [Any], locale: Locale) -> String { DotNetFormat.format(t(key), args, locale: locale) }

    /// Felsorolás (pl. csúszkafeliratok): a "|" jelekkel elválasztott elemek.
    public func a(_ key: String) -> [String] {
        t(key).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func has(_ key: String) -> Bool { table[key] != nil || fallback[key] != nil }

    /// A mappában található nyelvek, kód szerint rendezve (hibás fájl kimarad).
    public static func available(in directory: URL) -> [LanguageInfo] { available(in: [directory]) }

    /// A mappákban található nyelvek; a későbbi mappa azonos kódú fájlja felülírja a korábbit.
    public static func available(in directories: [URL]) -> [LanguageInfo] {
        var byCode: [String: LanguageInfo] = [:]
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: url), let table = try? parse(data) else { continue }
                let code = url.deletingPathExtension().lastPathComponent
                byCode[code.lowercased()] = LanguageInfo(code: code, name: table["_meta.name"] ?? code, url: url)
            }
        }
        return byCode.values.sorted { $0.code.lowercased() < $1.code.lowercased() }
    }

    /// A rendszer nyelvéhez illő elérhető nyelv (nincs találat: magyar, végső soron angol).
    public static func systemLanguage(in directory: URL) -> String { systemLanguage(in: [directory]) }

    public static func systemLanguage(in directories: [URL]) -> String {
        let codes = available(in: directories).map { $0.code.lowercased() }
        if let ui = Locale.preferredLanguages.first.map({ String($0.prefix(2)).lowercased() }), codes.contains(ui) { return ui }
        return codes.contains(defaultLanguage) ? defaultLanguage : fallbackLanguage
    }

    /// JSON → lapos kulcs–érték tábla.
    public static func parse(_ data: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        flatten(try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]), "", &result)
        return result
    }

    private static func flatten(_ value: Any, _ prefix: String, _ into: inout [String: String]) {
        switch value {
        case let dict as [String: Any]:
            for (k, v) in dict { flatten(v, prefix.isEmpty ? k : prefix + "." + k, &into) }
        case let array as [Any]:
            into[prefix] = array.map { "\($0)" }.joined(separator: "|")
        case is NSNull:
            break
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
            into[prefix] = n.boolValue ? "true" : "false"
        default:
            into[prefix] = "\(value)"
        }
    }
}
