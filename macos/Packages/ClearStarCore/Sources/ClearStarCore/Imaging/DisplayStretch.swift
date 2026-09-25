import Foundation

/// Automatic stretch for display (the Siril/PixInsight autostretch idea): shadows clipped below the
/// median, then an MTF that brings the median to the target background. Screen only – the image
/// data is not changed.
public enum DisplayStretch {
    public static let defaultTargetBackground: Float = 0.25
    public static let defaultShadowsClipping: Float = -2.8

    /// A screen-stretch preset: target background brightness and the shadow clipping point in MAD
    /// units below the median (GraXpert's "10% Bg, 3 sigma" style options).
    public struct Preset: Sendable, Equatable {
        public let key: String
        public let background: Float
        public let shadowsMad: Float
        public init(_ key: String, _ background: Float, _ shadowsMad: Float) {
            self.key = key; self.background = background; self.shadowsMad = shadowsMad
        }
        public var isOff: Bool { background <= 0 }
    }

    public static let presets: [Preset] = [
        Preset("off", 0, 0),
        Preset("bg10", 0.10, 3),
        Preset("bg15", 0.15, 3),
        Preset("bg20", 0.20, 3),
        Preset("bg30", 0.30, 2),
    ]

    public static let defaultPresetKey = "bg20"

    /// Longer side of the downsampled image the screen stretch is measured on (the wand uses it too).
    public static let previewWidth = 2400

    public static func presetByKey(_ key: String?) -> Preset {
        presets.first { $0.key == key } ?? presets.first { $0.key == defaultPresetKey }!
    }

    /// Midtones transfer function.
    @inline(__always)
    public static func mtf(_ x: Float, _ m: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return (m - 1) * x / ((2 * m - 1) * x - m)
    }

    public struct Params: Sendable, Equatable {
        public var shadows: Float
        public var midtones: Float
        public init(_ shadows: Float, _ midtones: Float) { self.shadows = shadows; self.midtones = midtones }
        public static let identity = Params(0, 0.5)

        @inline(__always)
        public func apply(_ x: Float) -> Float {
            let t = (x - shadows) / (1 - shadows)
            return DisplayStretch.mtf(t, midtones)
        }

        /// Exact inverse of `apply` (the MTF is its own inverse with midtones 1−m).
        public func invert(_ y: Float) -> Float {
            let t = DisplayStretch.mtf(y, 1 - midtones)
            return t * (1 - shadows) + shadows
        }
    }

    public static func compute(_ stats: ChannelStats, targetBackground: Float = defaultTargetBackground, shadowsClipping: Float = defaultShadowsClipping) -> Params {
        let shadows = (stats.median + shadowsClipping * stats.sigma).clamped(0, 1)
        let x0 = ((stats.median - shadows) / (1 - shadows)).clamped(1e-6, 1)
        // The midtones value that brings x0 to the target: m = MTF(x0, target).
        let midtones = mtf(x0, targetBackground)
        return Params(shadows, midtones.clamped(1e-4, 1 - 1e-4))
    }

    /// Per-channel parameters for a preset (shadows = median − ShadowsMad·MAD, like GraXpert). The
    /// shadows are always per channel (that neutralises the background colour); the linked mode shares
    /// the midtones so the colour ratios of the objects stay.
    public static func computeAll(_ image: AstroImage, preset: Preset, linked: Bool = false) -> [Params] {
        let stats = ImageStats.computeAll(image)
        var result = stats.map { s -> Params in
            let shadows = (s.median - preset.shadowsMad * s.mad).clamped(0, 1)
            let x0 = ((s.median - shadows) / (1 - shadows)).clamped(1e-6, 1)
            return Params(shadows, mtf(x0, preset.background).clamped(1e-4, 1 - 1e-4))
        }
        if linked && image.channels == 3 {
            let m = averageF(result.map(\.midtones))
            for c in 0 ..< result.count { result[c].midtones = m }
        }
        return result
    }

    public static func computeAll(_ image: AstroImage, linked: Bool = false, targetBackground: Float = defaultTargetBackground) -> [Params] {
        let stats = ImageStats.computeAll(image)
        var result = stats.map { compute($0, targetBackground: targetBackground) }
        if linked && image.channels == 3 {
            let m = averageF(result.map(\.midtones))
            for c in 0 ..< result.count { result[c].midtones = m }
        }
        return result
    }

    /// Lookup table without stretch.
    public static func buildLutLinear(size: Int = 4096) -> [UInt8] {
        (0 ..< size).map { UInt8((Double($0) / Double(size - 1) * 255).roundedEven) }
    }

    /// Lookup table for one channel: index = value·(size−1).
    public static func buildLut(_ p: Params, size: Int = 4096) -> [UInt8] {
        (0 ..< size).map { i in
            let x = Float(i) / Float(size - 1)
            return UInt8((p.apply(x) * 255).roundedEven.clamped(0, 255))
        }
    }
}
