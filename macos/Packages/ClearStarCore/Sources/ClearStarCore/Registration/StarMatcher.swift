import Foundation

/// Similarity transform: q = s·R(θ)·p + t (frame → reference).
public struct SimilarityTransform: Sendable, Equatable {
    public var scale: Float, angle: Float, tx: Float, ty: Float
    public init(_ scale: Float, _ angle: Float, _ tx: Float, _ ty: Float) { self.scale = scale; self.angle = angle; self.tx = tx; self.ty = ty }

    public static let identity = SimilarityTransform(1, 0, 0, 0)

    public var a: Float { scale * cos(angle) }
    public var b: Float { scale * sin(angle) }

    public func apply(_ x: Float, _ y: Float) -> (x: Float, y: Float) { (a * x - b * y + tx, b * x + a * y + ty) }

    /// Reference → frame (for resampling the frame).
    public func inverse() -> SimilarityTransform {
        let s = 1 / scale, ang = -angle
        let ia = s * cos(ang), ib = s * sin(ang)
        return SimilarityTransform(s, ang, -(ia * tx - ib * ty), -(ib * tx + ia * ty))
    }

    public var angleDegrees: Float { angle * 180 / .pi }
}

public struct MatchResult: Sendable {
    public var transform: SimilarityTransform
    public var matchedStars: Int
    public var rms: Float
}

/// Key of a 2D grid cell.
struct Cell: Hashable { let x: Int, y: Int }

/// Dictionary that remembers insertion order – the enumeration order of the C# Dictionary (without
/// removals), which decides ties.
struct OrderedDict<K: Hashable, V> {
    private(set) var keys: [K] = []
    private var storage: [K: V] = [:]
    subscript(key: K) -> V? {
        get { storage[key] }
        set {
            if storage[key] == nil, newValue != nil { keys.append(key) }
            storage[key] = newValue
        }
    }
}

/// Matching star lists: coarse translation by voting, then iterative nearest-neighbour pairing and a
/// closed-form similarity fit (shift + rotation + scale) with a shrinking radius.
public enum StarMatcher {
    public static func match(_ reference: [Star], _ frame: [Star], minMatches: Int = 8, maxRms: Float = 1.5) -> MatchResult? {
        if reference.count < minMatches || frame.count < minMatches { return nil }
        // First try: pure translation (fast, enough for most frames). Second: triangle matching, independent
        // of rotation and scale – on an alt-az mount the frames may even turn by 90°.
        let (tx, ty) = voteTranslation(reference, frame)
        if let r = refine(reference, frame, SimilarityTransform(1, 0, tx, ty), minMatches, maxRms) { return r }
        guard let tri = triangleMatch(reference, frame) else { return nil }
        return refine(reference, frame, tri, minMatches, maxRms)
    }

    /// Nearest-neighbour pairing with a shrinking radius and refitting from an initial transform.
    private static func refine(_ reference: [Star], _ frame: [Star], _ start: SimilarityTransform, _ minMatches: Int, _ maxRms: Float) -> MatchResult? {
        var transform = start
        var pairs: [(r: Star, f: Star)] = []
        for radius: Float in [40, 20, 8, 4, 2.5] {
            pairs = pair(reference, frame, transform, radius)
            if pairs.count < max(3, minMatches / 2) { return nil }
            transform = fit(pairs)
        }
        pairs = pair(reference, frame, transform, 2)
        if pairs.count < minMatches { return nil }
        transform = fit(pairs)

        var se = 0.0
        for (r, f) in pairs {
            let (x, y) = transform.apply(f.x, f.y)
            se += Double((x - r.x) * (x - r.x) + (y - r.y) * (y - r.y))
        }
        let rms = sqrt(Float(se / Double(pairs.count)))
        if rms > maxRms { return nil }
        return MatchResult(transform: transform, matchedStars: pairs.count, rms: rms)
    }

    /// Triangle with its vertex indices (opposite the longest side first) and side ratios.
    private struct Tri { let i0: Int, i1: Int, i2: Int, a: Float, rb: Float, rc: Float }

    /// Rotation- and scale-invariant initial match: side ratios (b/a, c/a) of triangles of the brightest
    /// stars; matching triangles vote for their vertices as star pairs; mutually best pairs give the fit.
    /// `takeReference`: brightest reference stars used (plate solving passes more – the catalogue
    /// covers more sky than the image). `minScale`/`maxScale`: accepted frame/reference size ratio.
    public static func triangleMatch(_ reference: [Star], _ frame: [Star], take: Int = 45, tolerance: Float = 0.006,
                                     takeReference: Int = -1, minScale: Float = 0.8, maxScale: Float = 1.25) -> SimilarityTransform? {
        let r = Array(reference.stableSortedDescending { $0.flux }.prefix(takeReference > 0 ? takeReference : take))
        let f = Array(frame.stableSortedDescending { $0.flux }.prefix(take))
        if r.count < 6 || f.count < 6 { return nil }

        var grid: [Cell: [Tri]] = [:]
        let cellDiv = Float(Int((1 / tolerance).rounded(.up)))
        for t in triangles(r) {
            grid[Cell(x: toInt(t.rb * cellDiv), y: toInt(t.rc * cellDiv)), default: []].append(t)
        }

        var votes = [Int](repeating: 0, count: r.count * f.count)
        let fc = f.count
        for t in triangles(f) {
            let gx = toInt(t.rb * cellDiv), gy = toInt(t.rc * cellDiv)
            for i in -1 ... 1 {
                for j in -1 ... 1 {
                    guard let list = grid[Cell(x: gx + i, y: gy + j)] else { continue }
                    for rt in list {
                        if abs(rt.rb - t.rb) > tolerance || abs(rt.rc - t.rc) > tolerance { continue }
                        // Same instrument: the size ratio is near 1, which drops most false matches.
                        let scale = t.a / rt.a
                        if scale < minScale || scale > maxScale { continue }
                        votes[rt.i0 * fc + t.i0] += 1; votes[rt.i1 * fc + t.i1] += 1; votes[rt.i2 * fc + t.i2] += 1
                    }
                }
            }
        }

        // Mutually best pairs with a few votes at least.
        var pairs: [(r: Star, f: Star, v: Int)] = []
        for i in 0 ..< r.count {
            var bestJ = -1, best = 0, second = 0
            for j in 0 ..< fc {
                let v = votes[i * fc + j]
                if v > best { second = best; best = v; bestJ = j } else if v > second { second = v }
            }
            if bestJ < 0 || best < 4 || best < 2 * second { continue }
            var mutual = true
            for k in 0 ..< r.count where k != i && votes[k * fc + bestJ] >= best { mutual = false; break }
            if mutual { pairs.append((r[i], f[bestJ], best)) }
        }
        if pairs.count < 5 { return nil }

        let top = pairs.stableSortedDescending { $0.v }.prefix(30).map { (r: $0.r, f: $0.f) }
        let transform = fit(Array(top))
        // A rough check: do the pairs used really fall on each other?
        var good = 0
        for (rs, fs) in top {
            let (x, y) = transform.apply(fs.x, fs.y)
            if (x - rs.x) * (x - rs.x) + (y - rs.y) * (y - rs.y) < 30 * 30 { good += 1 }
        }
        return good >= 5 ? transform : nil
    }

    private static func triangles(_ stars: [Star]) -> [Tri] {
        var result: [Tri] = []
        let n = stars.count
        for i in 0 ..< n {
            for j in i + 1 ..< max(i + 1, n) {
                for k in j + 1 ..< max(j + 1, n) {
                    let dij = dist(stars[i], stars[j]), djk = dist(stars[j], stars[k]), dik = dist(stars[i], stars[k])
                    // Vertex order: opposite the longest side first, then the middle one, then the shortest.
                    var v0: Int, v1: Int, v2: Int, a: Float, b: Float, c: Float
                    if djk >= dik && djk >= dij {
                        v0 = i
                        if dik >= dij { v1 = j; v2 = k; a = djk; b = dik; c = dij } else { v1 = k; v2 = j; a = djk; b = dij; c = dik }
                    } else if dik >= dij {
                        v0 = j
                        if djk >= dij { v1 = i; v2 = k; a = dik; b = djk; c = dij } else { v1 = k; v2 = i; a = dik; b = dij; c = djk }
                    } else {
                        v0 = k
                        if djk >= dik { v1 = i; v2 = j; a = dij; b = djk; c = dik } else { v1 = j; v2 = i; a = dij; b = dik; c = djk }
                    }
                    if a < 30 || c / a < 0.15 { continue }         // too small or degenerate
                    if b / a > 0.995 || c / b > 0.995 { continue }  // isosceles: vertex order uncertain
                    result.append(Tri(i0: v0, i1: v1, i2: v2, a: a, rb: b / a, rc: c / a))
                }
            }
        }
        return result
    }

    @inline(__always) private static func dist(_ p: Star, _ q: Star) -> Float { sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)) }

    /// The most common (reference − frame) shift among the brightest stars, on a coarse grid.
    private static func voteTranslation(_ reference: [Star], _ frame: [Star], take: Int = 60, bin: Float = 24) -> (Float, Float) {
        let refTop = reference.stableSortedDescending { $0.flux }.prefix(take)
        let frameTop = frame.stableSortedDescending { $0.flux }.prefix(take)
        var votes = OrderedDict<Cell, (count: Int, sx: Double, sy: Double)>()
        for r in refTop {
            for f in frameTop {
                let dx = r.x - f.x, dy = r.y - f.y
                let key = Cell(x: Int((dx / bin).rounded(.down)), y: Int((dy / bin).rounded(.down)))
                let v = votes[key] ?? (0, 0, 0)
                votes[key] = (v.count + 1, v.sx + Double(dx), v.sy + Double(dy))
            }
        }
        // Neighbouring cells count too, so a shift on a cell boundary does not split.
        var best = Cell(x: 0, y: 0), bestCount = -1
        for key in votes.keys {
            var c = 0
            for i in -1 ... 1 { for j in -1 ... 1 { if let v = votes[Cell(x: key.x + i, y: key.y + j)] { c += v.count } } }
            if c > bestCount { bestCount = c; best = key }
        }
        var sx = 0.0, sy = 0.0, n = 0
        for i in -1 ... 1 {
            for j in -1 ... 1 {
                if let v = votes[Cell(x: best.x + i, y: best.y + j)] { sx += v.sx; sy += v.sy; n += v.count }
            }
        }
        return n == 0 ? (0, 0) : (Float(sx / Double(n)), Float(sy / Double(n)))
    }

    /// Nearest-neighbour pairs (reference star, frame star) within `radius` px after transforming the frame.
    public static func pair(_ reference: [Star], _ frame: [Star], _ t: SimilarityTransform, _ radius: Float) -> [(r: Star, f: Star)] {
        let cell = max(radius, 1) * 2
        var grid: [Cell: [Int]] = [:]
        for (i, s) in reference.enumerated() {
            grid[Cell(x: Int((s.x / cell).rounded(.down)), y: Int((s.y / cell).rounded(.down))), default: []].append(i)
        }
        var used = Set<Int>()
        var pairs: [(r: Star, f: Star)] = []
        let r2 = radius * radius
        for f in frame {
            let (x, y) = t.apply(f.x, f.y)
            let gx = Int((x / cell).rounded(.down)), gy = Int((y / cell).rounded(.down))
            var best = -1
            var bestD = r2
            for i in -1 ... 1 {
                for j in -1 ... 1 {
                    guard let list = grid[Cell(x: gx + i, y: gy + j)] else { continue }
                    for idx in list where !used.contains(idx) {
                        let dx = reference[idx].x - x, dy = reference[idx].y - y
                        let d = dx * dx + dy * dy
                        if d < bestD { bestD = d; best = idx }
                    }
                }
            }
            if best >= 0 { used.insert(best); pairs.append((reference[best], f)) }
        }
        return pairs
    }

    /// Closed-form least-squares similarity fit (2D Umeyama).
    public static func fit(_ pairs: [(r: Star, f: Star)]) -> SimilarityTransform {
        var mrx = 0.0, mry = 0.0, mfx = 0.0, mfy = 0.0
        for (r, f) in pairs { mrx += Double(r.x); mry += Double(r.y); mfx += Double(f.x); mfy += Double(f.y) }
        let n = Double(pairs.count)
        mrx /= n; mry /= n; mfx /= n; mfy /= n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for (r, f) in pairs {
            let fx = Double(f.x) - mfx, fy = Double(f.y) - mfy, rx = Double(r.x) - mrx, ry = Double(r.y) - mry
            dot += fx * rx + fy * ry
            cross += fx * ry - fy * rx
            norm += fx * fx + fy * fy
        }
        let angle = atan2(cross, dot)
        let scale = norm > 0 ? (dot * cos(angle) + cross * sin(angle)) / norm : 1.0
        let a = scale * cos(angle), b = scale * sin(angle)
        let tx = mrx - (a * mfx - b * mfy)
        let ty = mry - (b * mfx + a * mfy)
        return SimilarityTransform(Float(scale), Float(angle), Float(tx), Float(ty))
    }
}

/// Resampling a frame into the reference's coordinate system (bilinear).
public enum ImageWarp {
    /// For every (x, y) of the output grid the frame's matching point is sampled. `toFrame` is the
    /// output → frame transform. Each row goes to `rowSink(y, width, row)` with the channels one after
    /// the other and a final weight segment (1 inside the frame, 0 outside), so averaging stays correct.
    /// Rows are processed in parallel; the sink must only touch its own row.
    public static func resample(_ frame: AstroImage, _ toFrame: SimilarityTransform, _ outWidth: Int, _ outHeight: Int,
                                _ ct: CancellationToken = .none, _ rowSink: (Int, Int, UnsafeBufferPointer<Float>) -> Void) throws {
        let fw = frame.width, fh = frame.height, fn = frame.pixelsPerChannel, ch = frame.channels
        let a = toFrame.a, b = toFrame.b, tx = toFrame.tx, ty = toFrame.ty
        try frame.data.withUnsafeBufferPointer { src in
            try parallelFor(outHeight, ct) { y in
                // Row: [channel0 ... | channel1 ... | ... | weight ...]
                var row = [Float](repeating: 0, count: outWidth * (ch + 1))
                let wOff = outWidth * ch
                row.withUnsafeMutableBufferPointer { r in
                    for x in 0 ..< outWidth {
                        let sx = a * Float(x) - b * Float(y) + tx
                        let sy = b * Float(x) + a * Float(y) + ty
                        if sx < 0 || sy < 0 || sx > Float(fw) - 1.001 || sy > Float(fh) - 1.001 { continue }
                        let x0 = Int(sx), y0 = Int(sy)
                        let fx = sx - Float(x0), fy = sy - Float(y0)
                        let i00 = y0 * fw + x0
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                        for c in 0 ..< ch {
                            let o = c * fn + i00
                            r[c * outWidth + x] = w00 * src[o] + w10 * src[o + 1] + w01 * src[o + fw] + w11 * src[o + fw + 1]
                        }
                        r[wOff + x] = 1
                    }
                }
                row.withUnsafeBufferPointer { rowSink(y, outWidth, $0) }
            }
        }
    }
}
