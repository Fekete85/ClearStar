/// FITS / metadata header: case-insensitive keys that keep their insertion order (like the C#
/// Dictionary with OrdinalIgnoreCase, which enumerates in insertion order).
public struct FitsHeader: Sendable, Equatable, Sequence {
    private var order: [String] = []
    private var values: [String: (key: String, value: String)] = [:]

    public init() {}

    public init(_ pairs: [(String, String)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }
    public var keys: [String] { order.compactMap { values[$0]?.key } }

    public subscript(key: String) -> String? {
        get { values[key.uppercased()]?.value }
        set {
            let k = key.uppercased()
            if let newValue {
                if let existing = values[k] { values[k] = (existing.key, newValue) }
                else { values[k] = (key, newValue); order.append(k) }
            } else if values.removeValue(forKey: k) != nil {
                order.removeAll { $0 == k }
            }
        }
    }

    public func contains(_ key: String) -> Bool { values[key.uppercased()] != nil }

    public mutating func remove(_ key: String) { self[key] = nil }

    public func makeIterator() -> AnyIterator<(key: String, value: String)> {
        var i = 0
        return AnyIterator {
            while i < order.count {
                defer { i += 1 }
                if let e = values[order[i]] { return (e.key, e.value) }
            }
            return nil
        }
    }

    public static func == (a: FitsHeader, b: FitsHeader) -> Bool {
        a.order == b.order && a.order.allSatisfy { a.values[$0]!.value == b.values[$0]?.value }
    }

    /// Plain dictionary (keys as first written).
    public var dictionary: [String: String] { Dictionary(uniqueKeysWithValues: map { ($0.key, $0.value) }) }
}
