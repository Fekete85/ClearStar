import Foundation

// Helpers that reproduce .NET numeric semantics exactly (the parity tests compare with the C# results).

extension Float {
    /// Math.Clamp(value, lo, hi).
    @inline(__always) func clamped(_ lo: Float, _ hi: Float) -> Float { self < lo ? lo : (self > hi ? hi : self) }
    /// MathF.Round – round half to even.
    @inline(__always) var roundedEven: Float { rounded(.toNearestOrEven) }
}

extension Double {
    @inline(__always) func clamped(_ lo: Double, _ hi: Double) -> Double { self < lo ? lo : (self > hi ? hi : self) }
    /// Math.Round – round half to even.
    @inline(__always) var roundedEven: Double { rounded(.toNearestOrEven) }
}

extension Int {
    @inline(__always) func clamped(_ lo: Int, _ hi: Int) -> Int { self < lo ? lo : (self > hi ? hi : self) }
}

/// (int)x of .NET: truncation toward zero; NaN and out-of-range values saturate instead of trapping.
@inline(__always) func toInt(_ x: Double) -> Int {
    if x.isNaN { return Int(Int32.min) }
    if x >= 2147483647 { return Int(Int32.max) }
    if x <= -2147483648 { return Int(Int32.min) }
    return Int(x)
}

@inline(__always) func toInt(_ x: Float) -> Int { toInt(Double(x)) }

/// Average of floats like LINQ's Average(Func&lt;T, float&gt;): double accumulator, float result.
func averageF<S: Sequence>(_ s: S) -> Float where S.Element == Float {
    var sum = 0.0, n = 0
    for v in s { sum += Double(v); n += 1 }
    return n == 0 ? 0 : Float(sum / Double(n))
}

/// Invariant-culture number parsing like double.TryParse(s, NumberStyles.Float, InvariantCulture).
func parseDouble(_ s: String?) -> Double? {
    guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    if t.hasPrefix("+") { t.removeFirst() }
    // Swift also accepts hex floats and "inf"/"nan" spellings .NET does not; only plain decimals pass.
    let allowed = CharacterSet(charactersIn: "0123456789.-+eE")
    guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        switch t.lowercased() {
        case "nan": return .nan
        case "infinity", "∞": return .infinity
        case "-infinity", "-∞": return -.infinity
        default: return nil
        }
    }
    return Double(t)
}

/// int.TryParse(s, NumberStyles.Integer, InvariantCulture).
func parseInt(_ s: String?) -> Int? {
    guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    guard let v = Int(t.hasPrefix("+") ? String(t.dropFirst()) : t), v >= Int(Int32.min), v <= Int(Int32.max) else { return nil }
    return v
}

/// Shortest round-trip text of a double, like double.ToString("R", InvariantCulture).
func formatR(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v > 0 ? "Infinity" : "-Infinity" }
    if v == v.rounded(), abs(v) < 1e15 { return String(format: "%.0f", v) }
    var s = "\(v)"
    if s.contains("e") { s = s.replacingOccurrences(of: "e", with: "E") }
    if let r = s.range(of: "E-0") { s.replaceSubrange(r, with: "E-") }
    return s
}

/// OrdinalIgnoreCase ordering of .NET.
func ordinalIgnoreCaseLess(_ a: String, _ b: String) -> Bool {
    a.uppercased().unicodeScalars.lexicographicallyPrecedes(b.uppercased().unicodeScalars)
}

// sin and cos of the same argument: LLVM merges the two calls into __sincos_stret / __sincosf_stret, which
// round differently from the separate sin/cos .NET calls in ~1% of cases (1 ulp – enough to flip a sigma-clip
// decision in the stack). These module-level versions shadow the Darwin ones inside ClearStarCore and cannot
// be inlined, so the calls stay separate.
@inline(never) func sin(_ x: Double) -> Double { Darwin.sin(x) }
@inline(never) func cos(_ x: Double) -> Double { Darwin.cos(x) }
@inline(never) func sin(_ x: Float) -> Float { Darwin.sinf(x) }
@inline(never) func cos(_ x: Float) -> Float { Darwin.cosf(x) }
