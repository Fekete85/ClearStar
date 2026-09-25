import Foundation

/// A nyelvi fájlok .NET `string.Format` helyőrzőinek az a része, amit ténylegesen használunk:
/// `{0}`, `{1:0.0}`, `{0:0.#}`, `{0:P1}` és a szakaszos `{0:+0.00;−0.00;0}` (pozitív;negatív;nulla).
enum DotNetFormat {
    static func format(_ template: String, _ args: [Any], locale: Locale) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if (c == "{" || c == "}"), next < template.endIndex, template[next] == c { // {{ és }}
                out.append(c)
                i = template.index(after: next)
                continue
            }
            if c == "{", let close = template[i...].firstIndex(of: "}") {
                let spec = template[next..<close]
                let parts = spec.split(separator: ":", maxSplits: 1)
                let indexPart = parts.first.map { $0.split(separator: ",").first ?? $0 } ?? ""
                guard let index = Int(indexPart), index < args.count else { return template }
                out += string(args[index], format: parts.count > 1 ? String(parts[1]) : nil, locale: locale)
                i = template.index(after: close)
                continue
            }
            out.append(c)
            i = next
        }
        return out
    }

    private static func string(_ arg: Any, format: String?, locale: Locale) -> String {
        let number: Double
        switch arg {
        case let v as Double: number = v
        case let v as Float: number = Double(v)
        case let v as Int: number = Double(v)
        default: return "\(arg)"
        }
        guard let format, !format.isEmpty else {
            return arg is Int ? "\(arg)" : formatter(locale, minFraction: 0, maxFraction: 15).string(from: number as NSNumber) ?? "\(number)"
        }
        if format.first == "P" || format.first == "p" {
            let digits = Int(format.dropFirst()) ?? 2
            let f = formatter(locale, minFraction: digits, maxFraction: digits)
            f.numberStyle = .percent
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
            return f.string(from: number as NSNumber) ?? "\(number)"
        }
        // Szakaszok: pozitív;negatív;nulla – a negatív szakasz az abszolút értéket formázza.
        let sections = format.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var value = number
        var section = sections[0]
        if number < 0, sections.count > 1 { section = sections[1]; value = -number }
        if number == 0, sections.count > 2 { section = sections[2] }
        return custom(value, section, locale: locale)
    }

    /// Egyedi numerikus minta: előtag + `0`/`#`/`.`/`,` mag + utótag.
    private static func custom(_ value: Double, _ pattern: String, locale: Locale) -> String {
        let isCore: (Character) -> Bool = { "0#.,".contains($0) }
        guard let start = pattern.firstIndex(where: isCore) else { return pattern }
        let end = pattern[start...].firstIndex(where: { !isCore($0) }) ?? pattern.endIndex
        let core = pattern[start..<end]
        let intPart = core.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let fracPart = core.contains(".") ? core.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[1] : ""
        let f = formatter(locale, minFraction: fracPart.filter { $0 == "0" }.count, maxFraction: fracPart.filter { $0 == "0" || $0 == "#" }.count)
        f.minimumIntegerDigits = max(intPart.filter { $0 == "0" }.count, 1)
        f.usesGroupingSeparator = intPart.contains(",")
        return String(pattern[..<start]) + (f.string(from: value as NSNumber) ?? "\(value)") + String(pattern[end...])
    }

    private static func formatter(_ locale: Locale, minFraction: Int, maxFraction: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.roundingMode = .halfUp // mint a .NET: félúton a nullától el
        f.minimumFractionDigits = minFraction
        f.maximumFractionDigits = maxFraction
        return f
    }
}
