import Foundation

/// Floating-point image stored plane by plane (planar): channel 0's width·height floats, then
/// channel 1, then channel 2. Mono (1 channel) or RGB (3 channels). Values are in [0,1]; during
/// processing they may temporarily leave that range.
public final class AstroImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public var data: [Float]
    public var header: FitsHeader

    public var pixelsPerChannel: Int { width * height }
    public var isColor: Bool { channels == 3 }

    public init(width: Int, height: Int, channels: Int, data: [Float]? = nil, header: FitsHeader = FitsHeader()) {
        precondition(width > 0 && height > 0, "A képméretnek pozitívnak kell lennie.")
        precondition(channels == 1 || channels == 3, "Csak 1 vagy 3 csatornás kép támogatott.")
        let count = width * height * channels
        if let data { precondition(data.count == count, "Az adattömb mérete nem egyezik a képmérettel.") }
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data ?? [Float](repeating: 0, count: count)
        self.header = header
    }

    /// One channel's plane (shares storage until written).
    public func channel(_ c: Int) -> ArraySlice<Float> {
        precondition(c >= 0 && c < channels)
        let n = pixelsPerChannel
        return data[c * n ..< (c + 1) * n]
    }

    /// One channel's plane as its own array.
    public func channelArray(_ c: Int) -> [Float] { Array(channel(c)) }

    public func setChannel(_ c: Int, _ values: [Float]) {
        let n = pixelsPerChannel
        precondition(values.count == n)
        data.replaceSubrange(c * n ..< (c + 1) * n, with: values)
    }

    public subscript(c: Int, x: Int, y: Int) -> Float {
        get { data[c * pixelsPerChannel + y * width + x] }
        set { data[c * pixelsPerChannel + y * width + x] = newValue }
    }

    public func clone() -> AstroImage { AstroImage(width: width, height: height, channels: channels, data: data, header: header) }

    /// An empty image with the same geometry and header.
    public func createEmptyLike() -> AstroImage { AstroImage(width: width, height: height, channels: channels, header: header) }

    /// Clamps every value into [0,1].
    public func clamp01() {
        data.withUnsafeMutableBufferPointer { d in
            for i in 0 ..< d.count {
                let v = d[i]
                d[i] = v < 0 ? 0 : (v > 1 ? 1 : v)
            }
        }
    }

    /// Luminance (Rec.709 weights) of one pixel; the value itself for a mono image.
    public func luminance(_ index: Int) -> Float {
        if channels == 1 { return data[index] }
        let n = pixelsPerChannel
        return 0.2126 * data[index] + 0.7152 * data[n + index] + 0.0722 * data[2 * n + index]
    }

    /// Box average with an integer factor (the preview's downsampling).
    public func downsample(_ factor: Int) -> AstroImage {
        if factor <= 1 { return self }
        let w = width / factor, h = height / factor
        let out = AstroImage(width: w, height: h, channels: channels)
        let inv = 1 / Float(factor * factor)
        let width = self.width, n = pixelsPerChannel, on = w * h
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                for c in 0 ..< channels {
                    let so = c * n, dOff = c * on
                    parallelFor(h) { y in
                        for x in 0 ..< w {
                            var sum: Float = 0
                            for yy in 0 ..< factor {
                                let row = so + (y * factor + yy) * width + x * factor
                                for xx in 0 ..< factor { sum += src[row + xx] }
                            }
                            dst[dOff + y * w + x] = sum * inv
                        }
                    }
                }
            }
        }
        return out
    }

    /// Integer factor that brings the longer side down to `maxSide` pixels (1 = no downsampling).
    public func downsampleFactor(_ maxSide: Int) -> Int {
        max(1, Int((Double(max(width, height)) / Double(maxSide)).rounded(.up)))
    }
}
