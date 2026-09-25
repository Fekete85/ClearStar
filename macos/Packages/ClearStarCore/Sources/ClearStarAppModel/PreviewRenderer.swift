import ClearStarCore
import CoreGraphics
import Foundation

/// Screen preview of an image (BGRA8 CGImage), optionally auto-stretched. Large images are downsampled
/// for fast drawing. Runs on any thread.
public enum PreviewRenderer {
    public static let maxPreviewWidth = DisplayStretch.previewWidth

    public struct Frame: @unchecked Sendable {
        public let image: CGImage
        public let width: Int, height: Int
        public let sourceWidth: Int, sourceHeight: Int
    }

    /// - Parameters:
    ///   - transform: optional live transform (e.g. the stretch being adjusted) applied to the downsampled image.
    ///   - smallOut: receives (downsampled, transformed) – for the histogram.
    public static func render(_ image: AstroImage, autoStretch: Bool, preset: DisplayStretch.Preset, maxWidth: Int = maxPreviewWidth,
                              _ ct: CancellationToken = .none, transform: ((AstroImage) throws -> AstroImage)? = nil,
                              smallOut: ((AstroImage, AstroImage) -> Void)? = nil) throws -> Frame {
        let stretch = autoStretch && !preset.isOff
        var small = image.downsample(image.downsampleFactor(maxWidth))
        try ct.check()
        let before = small
        if let transform { small = try transform(small); try ct.check() }
        smallOut?(before, small)

        // The stretch is evaluated per pixel in float: a linear image's background occupies only a few
        // thousandths of the range, so a lookup table would posterise it into colour blotches.
        let prms = stretch ? DisplayStretch.computeAll(small, preset: preset, linked: false) : nil
        try ct.check()
        let w = small.width, h = small.height, n = w * h
        var pixels = [UInt8](repeating: 255, count: n * 4)
        small.data.withUnsafeBufferPointer { d in
            pixels.withUnsafeMutableBufferPointer { px in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for i in y * w ..< (y + 1) * w {
                        let r: UInt8, g: UInt8, b: UInt8
                        if small.channels == 3 {
                            r = toByte(prms.map { $0[0].apply(d[i]) } ?? d[i])
                            g = toByte(prms.map { $0[1].apply(d[n + i]) } ?? d[n + i])
                            b = toByte(prms.map { $0[2].apply(d[2 * n + i]) } ?? d[2 * n + i])
                        } else {
                            let v = toByte(prms.map { $0[0].apply(d[i]) } ?? d[i])
                            r = v; g = v; b = v
                        }
                        let o = i * 4
                        px[o] = b; px[o + 1] = g; px[o + 2] = r; px[o + 3] = 255
                    }
                }
            }
        }
        return Frame(image: makeImage(pixels, w, h), width: w, height: h, sourceWidth: image.width, sourceHeight: image.height)
    }

    @inline(__always) static func toByte(_ v: Float) -> UInt8 { v <= 0 ? 0 : v >= 1 ? 255 : UInt8(v * 255 + 0.5) }

    static func makeImage(_ bgra: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bgra) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// Data for the histogram panel: per-channel bins of the input and the output, the transfer curve and
/// the marker positions (Siril-style).
public struct HistogramData: Sendable, Equatable {
    public var input: [[Int]]
    public var output: [[Int]]
    public var curve: [Float]
    public var lp: Float, sp: Float, hp: Float, bp: Float
    public var showMarkers: Bool
}
