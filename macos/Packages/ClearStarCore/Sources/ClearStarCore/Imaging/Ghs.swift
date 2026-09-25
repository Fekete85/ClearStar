import Foundation

/// Stretch types: Siril's five, `mtf` for the auto-stretch (wand) and `simple` for the beginner sliders
/// (object brightness, background level, contrast around the background). The raw values match the
/// C# enum (the stretch history is stored as JSON with numeric enums).
public enum GhsType: Int, Codable, Sendable { case ghs, inverseGhs, asinh, inverseAsinh, linear, mtf, simple }
public enum GhsColourModel: Int, Codable, Sendable { case independent, humanLuminance, evenLuminance }

/// One generalised hyperbolic stretch with Siril's parameter set: stretch factor D (the UI shows
/// ln(D+1)), local intensity b, symmetry point SP, shadow/highlight protection LP/HP, black point BP
/// (linear type only) and the colour model.
public struct GhsParams: Codable, Sendable, Equatable {
    public var type: GhsType
    public var d: Float
    public var b: Float
    public var lp: Float
    public var sp: Float
    public var hp: Float
    public var bp: Float
    public var colour: GhsColourModel
    public var channelMidtones: [Float]?
    public var channelShadows: [Float]?

    enum CodingKeys: String, CodingKey {
        case type = "Type", d = "D", b = "B", lp = "LP", sp = "SP", hp = "HP", bp = "BP", colour = "Colour"
        case channelMidtones = "ChannelMidtones", channelShadows = "ChannelShadows"
    }

    public init(_ type: GhsType, _ d: Float, _ b: Float, _ lp: Float, _ sp: Float, _ hp: Float, _ bp: Float, _ colour: GhsColourModel,
                channelMidtones: [Float]? = nil, channelShadows: [Float]? = nil) {
        self.type = type; self.d = d; self.b = b; self.lp = lp; self.sp = sp; self.hp = hp; self.bp = bp; self.colour = colour
        self.channelMidtones = channelMidtones; self.channelShadows = channelShadows
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type); try c.encode(d, forKey: .d); try c.encode(b, forKey: .b)
        try c.encode(lp, forKey: .lp); try c.encode(sp, forKey: .sp); try c.encode(hp, forKey: .hp)
        try c.encode(bp, forKey: .bp); try c.encode(colour, forKey: .colour)
        // Explicit nulls, like System.Text.Json.
        if let m = channelMidtones { try c.encode(m, forKey: .channelMidtones) } else { try c.encodeNil(forKey: .channelMidtones) }
        if let s = channelShadows { try c.encode(s, forKey: .channelShadows) } else { try c.encodeNil(forKey: .channelShadows) }
    }

    public static let identity = GhsParams(.ghs, 0, 0, 0, 0, 1, 0, .independent)

    /// ln(D+1) → D.
    public static func dFromLog(_ lnD1: Double) -> Float { Float(exp(lnD1) - 1.0) }

    /// For `mtf` (auto stretch) D holds the midtones balance and SP the shadow clipping point. For
    /// `simple` D, BP and B are the three sliders in −1…1 (objects, background, contrast) and SP the
    /// background level they pivot on.
    public var isIdentity: Bool {
        switch type {
        case .linear: return bp <= 0
        case .mtf: return false
        case .simple: return abs(d) < 1e-4 && abs(bp) < 1e-4 && abs(b) < 1e-4
        default: return d <= 0
        }
    }

    /// The beginner stretch: objects, background and contrast in −1…1 around the background level `pivot`.
    public static func simpleStretch(objects: Float, background: Float, contrast: Float, pivot: Float) -> GhsParams {
        GhsParams(.simple, objects.clamped(-1, 1), contrast.clamped(-1, 1), 0, pivot.clamped(0, 1), 1, background.clamped(-1, 1), .independent)
    }

    public func toJson() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }

    public static func fromJson(_ json: String) -> GhsParams? {
        try? JSONDecoder().decode(GhsParams.self, from: Data(json.utf8))
    }

    public static func listToJson(_ list: [GhsParams]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }

    public static func listFromJson(_ json: String?) -> [GhsParams] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return (try? JSONDecoder().decode([GhsParams].self, from: Data(json.utf8))) ?? []
    }

    public func describe() -> String {
        let loc = Locale.current
        switch type {
        case .linear: return DotNetFormat.format("BP {0:0.000}", [bp], locale: loc)
        case .mtf: return DotNetFormat.format("auto (MTF m={0:0.000}, shadows {1:0.000})", [d, sp], locale: loc)
        case .simple: return L.f("msg.ghs.simple", d, bp, b)
        default: return DotNetFormat.format("ln(D+1) {0:0.00}, b {1:0.0}, SP {2:0.000}", [log(Double(d) + 1), b, sp], locale: loc)
        }
    }
}

/// The stretch transform – the port of Siril's GHT (ght.c): piecewise definitions below LP, between
/// LP and SP, between SP and HP and above HP, for the hyperbolic, inverse hyperbolic, modified
/// arcsinh, inverse arcsinh and linear types.
public final class GhsTransform: @unchecked Sendable {
    private let p: GhsParams
    private var qlp: Float = 0, q0: Float = 0, qwp: Float = 0, q1: Float = 0, q: Float = 0
    private var a1: Float = 0, b1: Float = 0, a2: Float = 0, b2: Float = 0, c2: Float = 0, d2: Float = 0, e2: Float = 0
    private var a3: Float = 0, b3: Float = 0, c3: Float = 0, d3: Float = 0, e3: Float = 0, a4: Float = 0, b4: Float = 0
    private var lpt: Float = 0, spt: Float = 0, hpt: Float = 0
    private var bcat = 2 // 0: B == -1 (log), 1: B == 0 (exp), 2: other (pow)

    // Simple (beginner) stretch.
    private static let backgroundRange: Float = 0.12
    private static let objectsRange: Float = 0.35
    private static let contrastLnD: Float = 1.5
    private var sBg: Float = 0, sBg2: Float = 0, sM: Float = 0, sYsp: Float = 0, sLo: Float = 0, sHi: Float = 0
    private var sContrast: GhsTransform?

    public init(_ p: GhsParams) {
        self.p = p
        var B = p.b
        let D = p.d, LP = p.lp, SP = p.sp, HP = p.hp
        // b = −1 has its own (log) formulas in Siril whose LP branch is not continuous; the general
        // power form a hair away from −1 is indistinguishable and well behaved.
        if B == -1 { B = -1.0001 }
        bcat = B == -1 ? 0 : (B == 0 ? 1 : 2)
        if p.type == .simple { setupSimple(p); return }
        if D == 0 || p.type == .linear { return }
        setup(B, D, LP, SP, HP, p.type)
    }

    private func setupSimple(_ p: GhsParams) {
        sBg = p.sp.clamped(0.005, 0.9)
        sBg2 = (sBg + Self.backgroundRange * p.bp).clamped(0.001, 0.9)
        sM = (0.5 - Self.objectsRange * p.d).clamped(0.15, 0.85)
        if abs(p.b) < 1e-4 { return }
        let g = GhsParams(p.b > 0 ? .ghs : .inverseGhs, GhsParams.dFromLog(Double(Self.contrastLnD * abs(p.b))), 1, 0, sBg2, 1, 0, .independent)
        let c = GhsTransform(g)
        sContrast = c
        sYsp = c.apply(sBg2)
        sLo = sBg2 / max(sYsp, 1e-6)
        sHi = (1 - sBg2) / max(1 - sYsp, 1e-6)
    }

    private func applySimple(_ x: Float) -> Float {
        let y: Float = x < sBg ? sBg2 * (x / sBg) : sBg2 + (1 - sBg2) * DisplayStretch.mtf((x - sBg) / (1 - sBg), sM)
        guard let c = sContrast else { return y }
        let z = c.apply(y)
        return z <= sYsp ? z * sLo : 1 - (1 - z) * sHi
    }

    private func setup(_ Bin: Float, _ D: Float, _ LP: Float, _ SP: Float, _ HP: Float, _ type: GhsType) {
        var B = Bin
        switch type {
        case .ghs:
            if B == -1 {
                qlp = -log(1 + D * (SP - LP))
                q0 = qlp - D * LP / (1 + D * (SP - LP))
                qwp = log(1 + D * (HP - SP))
                q1 = qwp + D * (1 - HP) / (1 + D * (HP - SP))
                q = 1 / (q1 - q0)
                b1 = (1 + D * (SP - LP)) / (D * q)
                a2 = -q0 * q; b2 = -q; c2 = 1 + D * SP; d2 = -D
                a3 = -q0 * q; b3 = q; c3 = 1 - D * SP; d3 = D
                a4 = (qwp - q0 - D * HP / (1 + D * (HP - SP))) * q
                b4 = q * D / (1 + D * (HP - SP))
            } else if B < 0 {
                B = -B
                qlp = (1 - pow(1 + D * B * (SP - LP), (B - 1) / B)) / (B - 1)
                q0 = qlp - D * LP * pow(1 + D * B * (SP - LP), -1 / B)
                qwp = (pow(1 + D * B * (HP - SP), (B - 1) / B) - 1) / (B - 1)
                q1 = qwp + D * (1 - HP) * pow(1 + D * B * (HP - SP), -1 / B)
                q = 1 / (q1 - q0)
                b1 = D * pow(1 + D * B * (SP - LP), -1 / B) * q
                a2 = (1 / (B - 1) - q0) * q; b2 = -q / (B - 1); c2 = 1 + D * B * SP; d2 = -D * B; e2 = (B - 1) / B
                a3 = (-1 / (B - 1) - q0) * q; b3 = q / (B - 1); c3 = 1 - D * B * SP; d3 = D * B; e3 = (B - 1) / B
                a4 = (qwp - q0 - D * HP * pow(1 + D * B * (HP - SP), -1 / B)) * q
                b4 = D * pow(1 + D * B * (HP - SP), -1 / B) * q
            } else if B == 0 {
                qlp = exp(-D * (SP - LP))
                q0 = qlp - D * LP * exp(-D * (SP - LP))
                qwp = 2 - exp(-D * (HP - SP))
                q1 = qwp + D * (1 - HP) * exp(-D * (HP - SP))
                q = 1 / (q1 - q0)
                a1 = 0; b1 = D * exp(-D * (SP - LP)) * q
                a2 = -q0 * q; b2 = q; c2 = -D * SP; d2 = D
                a3 = (2 - q0) * q; b3 = -q; c3 = D * SP; d3 = -D
                a4 = (qwp - q0 - D * HP * exp(-D * (HP - SP))) * q
                b4 = D * exp(-D * (HP - SP)) * q
            } else {
                qlp = pow(1 + D * B * (SP - LP), -1 / B)
                q0 = qlp - D * LP * pow(1 + D * B * (SP - LP), -(1 + B) / B)
                qwp = 2 - pow(1 + D * B * (HP - SP), -1 / B)
                q1 = qwp + D * (1 - HP) * pow(1 + D * B * (HP - SP), -(1 + B) / B)
                q = 1 / (q1 - q0)
                b1 = D * pow(1 + D * B * (SP - LP), -(1 + B) / B) * q
                a2 = -q0 * q; b2 = q; c2 = 1 + D * B * SP; d2 = -D * B; e2 = -1 / B
                a3 = (2 - q0) * q; b3 = -q; c3 = 1 - D * B * SP; d3 = D * B; e3 = -1 / B
                a4 = (qwp - q0 - D * HP * pow(1 + D * B * (HP - SP), -(B + 1) / B)) * q
                b4 = D * pow(1 + D * B * (HP - SP), -(B + 1) / B) * q
            }

        case .inverseGhs:
            if B == -1 {
                qlp = -log(1 + D * (SP - LP))
                q0 = qlp - D * LP / (1 + D * (SP - LP))
                qwp = log(1 + D * (HP - SP))
                q1 = qwp + D * (1 - HP) / (1 + D * (HP - SP))
                q = 1 / (q1 - q0)
                lpt = (qlp - q0) * q; spt = q0 * q; hpt = (qwp - q0) * q
                b1 = (1 + D * (SP - LP)) / (D * q)
                a2 = (1 + D * SP) / D; b2 = -1 / D; c2 = -q0; d2 = -1 / q
                a3 = -(1 - D * SP) / D; b3 = 1 / D; c3 = q0; d3 = 1 / q
                a4 = HP + (q0 - qwp) * (1 + D * (HP - SP)) / D
                b4 = (1 + D * (HP - SP)) / (q * D)
            } else if B < 0 {
                B = -B
                qlp = (1 - pow(1 + D * B * (SP - LP), (B - 1) / B)) / (B - 1)
                q0 = qlp - D * LP * pow(1 + D * B * (SP - LP), -1 / B)
                qwp = (pow(1 + D * B * (HP - SP), (B - 1) / B) - 1) / (B - 1)
                q1 = qwp + D * (1 - HP) * pow(1 + D * B * (HP - SP), -1 / B)
                q = 1 / (q1 - q0)
                lpt = (qlp - q0) * q; spt = -q0 * q; hpt = (qwp - q0) * q
                b1 = pow(1 + D * B * (SP - LP), 1 / B) / (q * D)
                a2 = (1 + D * B * SP) / (D * B); b2 = -1 / (D * B); c2 = -q0 * (B - 1) + 1; d2 = (1 - B) / q; e2 = B / (B - 1)
                a3 = (D * B * SP - 1) / (D * B); b3 = 1 / (D * B); c3 = 1 + q0 * (B - 1); d3 = (B - 1) / q; e3 = B / (B - 1)
                a4 = (q0 - qwp) / (D * pow(1 + D * B * (HP - SP), -1 / B)) + HP
                b4 = 1 / (D * pow(1 + D * B * (HP - SP), -1 / B) * q)
            } else if B == 0 {
                qlp = exp(-D * (SP - LP))
                q0 = qlp - D * LP * exp(-D * (SP - LP))
                qwp = 2 - exp(-D * (HP - SP))
                q1 = qwp + D * (1 - HP) * exp(-D * (HP - SP))
                q = 1 / (q1 - q0)
                lpt = (qlp - q0) * q; spt = (1 - q0) * q; hpt = (qwp - q0) * q
                a1 = 0; b1 = 1 / (D * exp(-D * (SP - LP)) * q)
                a2 = SP; b2 = 1 / D; c2 = q0; d2 = 1 / q
                a3 = SP; b3 = -1 / D; c3 = 2 - q0; d3 = -1 / q
                a4 = (q0 - qwp) / (D * exp(-D * (HP - SP))) + HP
                b4 = 1 / (D * exp(-D * (HP - SP)) * q)
            } else {
                qlp = pow(1 + D * B * (SP - LP), -1 / B)
                q0 = qlp - D * LP * pow(1 + D * B * (SP - LP), -(1 + B) / B)
                qwp = 2 - pow(1 + D * B * (HP - SP), -1 / B)
                q1 = qwp + D * (1 - HP) * pow(1 + D * B * (HP - SP), -(1 + B) / B)
                q = 1 / (q1 - q0)
                lpt = (qlp - q0) * q; spt = (1 - q0) * q; hpt = (qwp - q0) * q
                b1 = 1 / (D * pow(1 + D * B * (SP - LP), -(1 + B) / B) * q)
                a2 = 1 / (D * B) + SP; b2 = -1 / (D * B); c2 = q0; d2 = 1 / q; e2 = -B
                a3 = -1 / (D * B) + SP; b3 = 1 / (D * B); c3 = 2 - q0; d3 = -1 / q; e3 = -B
                a4 = (q0 - qwp) / (D * pow(1 + D * B * (HP - SP), -(B + 1) / B)) + HP
                b4 = 1 / (D * pow(1 + D * B * (HP - SP), -(B + 1) / B) * q)
            }

        case .asinh, .inverseAsinh:
            qlp = -log(D * (SP - LP) + sqrt(D * D * (SP - LP) * (SP - LP) + 1))
            q0 = qlp - LP * D / sqrt(D * D * (SP - LP) * (SP - LP) + 1)
            qwp = log(D * (HP - SP) + sqrt(D * D * (HP - SP) * (HP - SP) + 1))
            q1 = qwp + (1 - HP) * D / sqrt(D * D * (HP - SP) * (HP - SP) + 1)
            q = 1 / (q1 - q0)
            a1 = 0; b1 = D / sqrt(D * D * (SP - LP) * (SP - LP) + 1) * q
            a2 = -q0 * q; b2 = -q; c2 = -D; d2 = D * D; e2 = SP
            a3 = -q0 * q; b3 = q; c3 = D; d3 = D * D; e3 = SP
            a4 = (qwp - HP * D / sqrt(D * D * (HP - SP) * (HP - SP) + 1) - q0) * q
            b4 = D / sqrt(D * D * (HP - SP) * (HP - SP) + 1) * q
            if type == .inverseAsinh {
                lpt = a1 + b1 * LP
                spt = a2 + b2 * log(c2 * (SP - e2) + sqrt(d2 * (SP - e2) * (SP - e2) + 1))
                hpt = a4 + b4 * HP
            }

        default:
            break
        }
    }

    /// Stretches one value in [0,1].
    public func apply(_ input: Float) -> Float {
        let x = input.clamped(0, 1)
        switch p.type {
        case .linear:
            return max(0, (x - p.bp) / (1 - p.bp))
        case .mtf:
            return DisplayStretch.mtf(max(0, (x - p.sp) / (1 - p.sp)), p.d)
        case .simple:
            return applySimple(x)
        case .ghs:
            if p.d == 0 { return x }
            let r1: Float, r2: Float
            if bcat == 0 { r1 = a2 + b2 * log(c2 + d2 * x); r2 = a3 + b3 * log(c3 + d3 * x) }
            else if bcat == 2 { r1 = a2 + b2 * pow(c2 + d2 * x, e2); r2 = a3 + b3 * pow(c3 + d3 * x, e3) }
            else { r1 = a2 + b2 * exp(c2 + d2 * x); r2 = a3 + b3 * exp(c3 + d3 * x) }
            return x < p.lp ? b1 * x : x < p.sp ? r1 : x < p.hp ? r2 : a4 + b4 * x
        case .inverseGhs:
            if p.d == 0 { return x }
            let r1: Float, r2: Float
            if bcat == 0 { r1 = a2 + b2 * exp(c2 + d2 * x); r2 = a3 + b3 * exp(c3 + d3 * x) }
            else if bcat == 2 { r1 = a2 + b2 * pow(c2 + d2 * x, e2); r2 = a3 + b3 * pow(c3 + d3 * x, e3) }
            else { r1 = a2 + b2 * log(c2 + d2 * x); r2 = a3 + b3 * log(c3 + d3 * x) }
            return x < lpt ? b1 * x : x < spt ? r1 : x < hpt ? r2 : a4 + b4 * x
        case .asinh:
            if p.d == 0 { return x }
            let v1 = c2 * (x - e2) + sqrt(d2 * (x - e2) * (x - e2) + 1)
            let r1 = a2 + b2 * log(v1)
            let v2 = c3 * (x - e3) + sqrt(d3 * (x - e3) * (x - e3) + 1)
            let r2 = a3 + b3 * log(v2)
            return x < p.lp ? a1 + b1 * x : x < p.sp ? r1 : x < p.hp ? r2 : a4 + b4 * x
        case .inverseAsinh:
            if p.d == 0 { return x }
            var ex = exp((a2 - x) / b2)
            let r1 = e2 - (ex - 1 / ex) / (2 * c2)
            ex = exp((a3 - x) / b3)
            let r2 = e3 - (ex - 1 / ex) / (2 * c3)
            return x < lpt ? (x - a1) / b1 : x < spt ? r1 : x < hpt ? r2 : (x - a4) / b4
        }
    }

    /// Applies the stretch to a whole image with the chosen colour model.
    public static func apply(_ input: AstroImage, _ p: GhsParams, _ ct: CancellationToken = .none) throws -> AstroImage {
        let output = input.createEmptyLike()
        let n = input.pixelsPerChannel, w = input.width, h = input.height, ch = input.channels
        // Auto stretch with per-channel MTF parameters (unlinked, like the screen boost and GraXpert's autostretch).
        if p.type == .mtf, let cm = p.channelMidtones, let cs = p.channelShadows {
            try input.data.withUnsafeBufferPointer { s in
                try output.data.withUnsafeMutableBufferPointer { d in
                    try parallelFor(h * ch, ct) { row in
                        let c = row / h, y = row % h
                        let prm = DisplayStretch.Params(cs[min(c, cs.count - 1)], cm[min(c, cm.count - 1)])
                        let start = c * n + y * w
                        for i in start ..< start + w { d[i] = prm.apply(s[i].clamped(0, 1)).clamped(0, 1) }
                    }
                }
            }
            return output
        }
        let t = GhsTransform(p)
        if p.colour == .independent || ch != 3 {
            try input.data.withUnsafeBufferPointer { s in
                try output.data.withUnsafeMutableBufferPointer { d in
                    try parallelFor(h * ch, ct) { row in
                        let c = row / h, y = row % h
                        let start = c * n + y * w
                        for i in start ..< start + w { d[i] = t.apply(s[i]).clamped(0, 1) }
                    }
                }
            }
            return output
        }
        let even = p.colour == .evenLuminance
        let fr: Float = even ? 1.0 / 3 : 0.2126, fg: Float = even ? 1.0 / 3 : 0.7152, fb: Float = even ? 1.0 / 3 : 0.0722
        try input.data.withUnsafeBufferPointer { s in
            try output.data.withUnsafeMutableBufferPointer { d in
                try parallelFor(h, ct) { y in
                    for i in y * w ..< (y + 1) * w {
                        let r = s[i].clamped(0, 1), g = s[n + i].clamped(0, 1), b = s[2 * n + i].clamped(0, 1)
                        let lum = fr * r + fg * g + fb * b
                        let factor = t.apply(lum) / max(lum, 1e-9)
                        d[i] = (r * factor).clamped(0, 1)
                        d[n + i] = (g * factor).clamped(0, 1)
                        d[2 * n + i] = (b * factor).clamped(0, 1)
                    }
                }
            }
        }
        return output
    }

    /// Applies a sequence of stretches in order.
    public static func applyAll(_ input: AstroImage, _ list: [GhsParams], _ ct: CancellationToken = .none) throws -> AstroImage {
        var image = input
        for p in list where !p.isIdentity { image = try apply(image, p, ct) }
        return image
    }
}

/// Per-channel histogram (256 bins), values in [0,1].
public enum Histogram {
    public static let bins = 256

    public static func compute(_ image: AstroImage, stride: Int = 1) -> [[Int]] {
        (0 ..< image.channels).map { c in
            var result = [Int](repeating: 0, count: bins)
            image.channel(c).withUnsafeBufferPointer { ch in
                var i = 0
                while i < ch.count {
                    let v = ch[i]
                    i += stride
                    if v <= 0 { continue } // empty canvas outside the frames
                    result[min(bins - 1, toInt(v * Float(bins)))] += 1
                }
            }
            return result
        }
    }
}
