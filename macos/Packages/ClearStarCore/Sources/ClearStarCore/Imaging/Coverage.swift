import Foundation

/// The part of a stacked image covered by data: rotated frames leave empty (0) corners. Finds the
/// largest axis-aligned rectangle without empty pixels – the natural starting point of the crop.
public enum Coverage {
    /// The largest fully filled rectangle as fractions of the image (x, y, w, h ∈ 0..1), or nil when
    /// the image is practically fully covered (nothing to crop).
    public static func largestFilledRectangle(_ image: AstroImage, downsample: Int = 4) -> (x: Double, y: Double, w: Double, h: Double)? {
        let w = image.width / downsample, h = image.height / downsample
        if w < 4 || h < 4 { return nil }
        let n = image.pixelsPerChannel, ch = image.channels, iw = image.width

        // A cell is filled when every pixel carries data (any channel > 0).
        var filled = [Bool](repeating: false, count: w * h)
        image.data.withUnsafeBufferPointer { data in
            filled.withUnsafeMutableBufferPointer { f in
                parallelFor(h) { cy in
                    for cx in 0 ..< w {
                        var ok = true
                        var yy = 0
                        while yy < downsample && ok {
                            let row = (cy * downsample + yy) * iw + cx * downsample
                            for xx in 0 ..< downsample {
                                let i = row + xx
                                var any = false
                                for c in 0 ..< ch where data[c * n + i] > 0 { any = true; break }
                                if !any { ok = false; break }
                            }
                            yy += 1
                        }
                        f[cy * w + cx] = ok
                    }
                }
            }
        }
        let empty = filled.reduce(0) { $0 + ($1 ? 0 : 1) }
        if Double(empty) < Double(filled.count) * 0.002 { return nil }

        // Largest rectangle in a binary matrix: per-row "histogram" + stack (O(w·h)).
        var heights = [Int](repeating: 0, count: w)
        var bestArea = 0, bx = 0, by = 0, bw = 0, bh = 0
        var stack = [Int]()
        for y in 0 ..< h {
            for x in 0 ..< w { heights[x] = filled[y * w + x] ? heights[x] + 1 : 0 }
            stack.removeAll(keepingCapacity: true)
            for x in 0 ... w {
                let hx = x < w ? heights[x] : 0
                while let top = stack.last, heights[top] >= hx {
                    stack.removeLast()
                    let height = heights[top]
                    let left = stack.last.map { $0 + 1 } ?? 0
                    let width = x - left
                    if width * height > bestArea { bestArea = width * height; bx = left; by = y - height + 1; bw = width; bh = height }
                }
                stack.append(x)
            }
        }
        if bestArea == 0 { return nil }
        // One cell of safety margin so the edge pixels lost to the downsampling do not stick out.
        let x0 = Double((bx + 1) * downsample), y0 = Double((by + 1) * downsample)
        let x1 = Double((bx + bw - 1) * downsample), y1 = Double((by + bh - 1) * downsample)
        if x1 <= x0 || y1 <= y0 { return nil }
        return (x0 / Double(image.width), y0 / Double(image.height), (x1 - x0) / Double(image.width), (y1 - y0) / Double(image.height))
    }
}
