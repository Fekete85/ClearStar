import Foundation

/// Robust statistics of one channel (median, MAD).
public struct ChannelStats: Sendable, Equatable {
    public var min: Float = 0, max: Float = 0, median: Float = 0, mad: Float = 0, mean: Float = 0
    public init() {}
    public init(min: Float, max: Float, median: Float, mad: Float, mean: Float) {
        self.min = min; self.max = max; self.median = median; self.mad = mad; self.mean = mean
    }
    /// MAD scaled to a standard deviation (≈σ for a normal distribution).
    public var sigma: Float { mad * 1.4826 }
}

public enum ImageStats {
    /// Strided sampling keeps it fast on large images (300k samples by default – the median is still
    /// exact enough). Pixels that are exactly 0 do not count: those are the empty corners of rotated
    /// frames, not sky – so an image before and after the crop has the same statistics (and preview).
    public static func compute(_ data: UnsafeBufferPointer<Float>, maxSamples: Int = 300_000) -> ChannelStats {
        if data.isEmpty { return ChannelStats() }
        let stride = Swift.max(1, data.count / maxSamples)
        var samples = [Float]()
        samples.reserveCapacity((data.count + stride - 1) / stride)
        var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
        var sum = 0.0
        var i = 0
        while i < data.count {
            let v = data[i]
            i += stride
            if v <= 0 { continue }
            samples.append(v)
            if v < mn { mn = v }
            if v > mx { mx = v }
            sum += Double(v)
        }
        if samples.isEmpty { return ChannelStats() }
        let median = Self.median(&samples)
        for k in 0 ..< samples.count { samples[k] = abs(samples[k] - median) }
        let mad = Self.median(&samples)
        return ChannelStats(min: mn, max: mx, median: median, mad: mad, mean: Float(sum / Double(samples.count)))
    }

    public static func compute(_ data: [Float], maxSamples: Int = 300_000) -> ChannelStats {
        data.withUnsafeBufferPointer { compute($0, maxSamples: maxSamples) }
    }

    public static func compute(_ data: ArraySlice<Float>, maxSamples: Int = 300_000) -> ChannelStats {
        data.withUnsafeBufferPointer { compute($0, maxSamples: maxSamples) }
    }

    public static func computeAll(_ image: AstroImage) -> [ChannelStats] {
        (0 ..< image.channels).map { compute(image.channel($0)) }
    }

    /// Median by sorting in place (the array is modified).
    public static func median(_ values: inout [Float]) -> Float {
        if values.isEmpty { return 0 }
        values.sort()
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : 0.5 * (values[mid - 1] + values[mid])
    }

    /// Median of a copy.
    public static func median(_ values: [Float]) -> Float {
        var copy = values
        return median(&copy)
    }
}
