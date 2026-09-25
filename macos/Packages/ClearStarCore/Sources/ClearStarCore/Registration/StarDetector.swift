import Foundation

/// A detected star: weighted centroid, flux above the background, size.
public struct Star: Sendable, Equatable {
    public var x: Float, y: Float, flux: Float, size: Float
    public init(_ x: Float, _ y: Float, _ flux: Float, _ size: Float) { self.x = x; self.y = y; self.flux = flux; self.size = size }
}

extension Array {
    /// Stable sort, descending by key – LINQ's OrderByDescending (ties keep their order).
    func stableSortedDescending<K: Comparable>(by key: (Element) -> K) -> [Element] {
        enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka > kb : a.offset < b.offset
        }.map(\.element)
    }
}

/// Simple, fast star finder: connected blobs above background + k·σ with an intensity-weighted centroid.
/// Plenty for registration.
public enum StarDetector {
    public static func detect(_ image: AstroImage, maxStars: Int = 300, thresholdSigma: Float = 5, downsample: Int = 2, ct: CancellationToken = .none) throws -> [Star] {
        try detectCounting(image, maxStars: maxStars, thresholdSigma: thresholdSigma, downsample: downsample, ct: ct).stars
    }

    /// Like `detect`, but also returns how many stars were found before the limit (a quality figure).
    public static func detectCounting(_ image: AstroImage, maxStars: Int = 300, thresholdSigma: Float = 5, downsample: Int = 2,
                                      ct: CancellationToken = .none) throws -> (stars: [Star], total: Int) {
        // Colour: the green channel (best signal); mono: the image itself.
        let src = image.channels == 3 ? image.channel(1) : image.channel(0)
        let w = image.width, h = image.height
        var data: [Float]
        let dw: Int, dh: Int
        if downsample > 1 {
            dw = w / downsample; dh = h / downsample
            data = [Float](repeating: 0, count: dw * dh)
            let inv = 1 / Float(downsample * downsample)
            src.withUnsafeBufferPointer { s in
                for y in 0 ..< dh {
                    for x in 0 ..< dw {
                        var sum: Float = 0
                        for yy in 0 ..< downsample {
                            for xx in 0 ..< downsample { sum += s[(y * downsample + yy) * w + x * downsample + xx] }
                        }
                        data[y * dw + x] = sum * inv
                    }
                }
            }
        } else {
            dw = w; dh = h; data = Array(src)
        }

        let stats = ImageStats.compute(data)
        let background = stats.median
        let threshold = background + thresholdSigma * max(stats.sigma, 1e-6)

        var labels = [Int32](repeating: 0, count: dw * dh)
        var stars: [Star] = []
        var stack: [Int] = []
        let maxArea = max(64, dw * dh / 2000)
        for i in 0 ..< data.count {
            if data[i] < threshold || labels[i] != 0 { continue }
            try ct.check()
            // Connected component (8-neighbourhood).
            let label = Int32(stars.count + 1)
            var sx = 0.0, sy = 0.0, sw = 0.0
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, area = 0
            stack.append(i); labels[i] = label
            while let p = stack.popLast() {
                let px = p % dw, py = p / dw
                let v = data[p] - background
                sx += Double(v * Float(px)); sy += Double(v * Float(py)); sw += Double(v); area += 1
                if px < minX { minX = px }; if px > maxX { maxX = px }
                if py < minY { minY = py }; if py > maxY { maxY = py }
                if area > maxArea { continue }
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 {
                        let nx = px + dx, ny = py + dy
                        if nx < 0 || ny < 0 || nx >= dw || ny >= dh { continue }
                        let q = ny * dw + nx
                        if labels[q] == 0 && data[q] >= threshold { labels[q] = label; stack.append(q) }
                    }
                }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            if area < 2 || area > maxArea || sw <= 0 { continue }
            let aspect = Float(max(bw, bh)) / Float(min(bw, bh))
            if aspect > 2.5 { continue }                                         // streak, hot row, satellite
            if minX == 0 || minY == 0 || maxX == dw - 1 || maxY == dh - 1 { continue } // touches the edge
            let cx = Float(sx / sw), cy = Float(sy / sw)
            stars.append(Star((cx + 0.5) * Float(downsample) - 0.5, (cy + 0.5) * Float(downsample) - 0.5, Float(sw), sqrt(Float(area))))
        }
        let total = stars.count
        return (Array(stars.stableSortedDescending { $0.flux }.prefix(maxStars)), total)
    }
}
