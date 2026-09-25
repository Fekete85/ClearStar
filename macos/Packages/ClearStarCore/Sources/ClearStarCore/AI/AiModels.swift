import Foundation

/// Background model: GraXpert's background network on a 256×256, per-channel normalised image
/// (shrink to 240×240, 8 px edge repeat, (x−median)/MAD·0.04 clamped to ±1, inference,
/// de-normalisation, optional smoothing, Gaussian σ=3, enlarge to full size).
public enum BackgroundModel {
    static let netSize = 256
    static let padding = 8
    static let scale: Float = 0.04

    /// The estimated background at the original size.
    public static func estimateBackground(_ image: AstroImage, _ modelPath: String, smoothing: Float = 0, _ ct: CancellationToken = .none) throws -> AstroImage {
        let inner = netSize - 2 * padding
        let w = image.width, h = image.height, ch = image.channels
        var small: [[Float]] = [], median = [Float](repeating: 0, count: 3), mad = [Float](repeating: 0, count: 3)
        for c in 0 ..< 3 {
            let src = min(c, ch - 1)
            // Empty (0) areas – corners of rotated frames – are filled with the channel median so they do
            // not pull the background down at the edges.
            var channel = image.channelArray(src)
            let fill = ImageStats.compute(channel).median
            for i in 0 ..< channel.count where channel[i] <= 0 { channel[i] = fill }
            let shrunk = Resample.resize(channel, w, h, inner, inner)
            var padded = [Float](repeating: 0, count: netSize * netSize)
            for y in 0 ..< netSize {
                let sy = (y - padding).clamped(0, inner - 1)
                for x in 0 ..< netSize { padded[y * netSize + x] = shrunk[sy * inner + (x - padding).clamped(0, inner - 1)] }
            }
            var sorted = padded
            median[c] = ImageStats.median(&sorted)
            for i in 0 ..< sorted.count { sorted[i] = abs(padded[i] - median[c]) }
            mad[c] = max(ImageStats.median(&sorted), 1e-6)
            small.append(padded)
        }
        try ct.check()

        // NHWC input [1, 256, 256, 3].
        var input = [Float](repeating: 0, count: netSize * netSize * 3)
        for y in 0 ..< netSize {
            for x in 0 ..< netSize {
                for c in 0 ..< 3 {
                    input[(y * netSize + x) * 3 + c] = ((small[c][y * netSize + x] - median[c]) / mad[c] * scale).clamped(-1, 1)
                }
            }
        }
        let model = try CoreMLRunner.load(modelPath)
        let name = CoreMLRunner.inputNames(model).first ?? "gen_input_image"
        let output = try CoreMLRunner.predict(model, [(name, [1, netSize, netSize, 3], input)])
        try ct.check()

        let background = AstroImage(width: w, height: h, channels: ch, header: image.header)
        for c in 0 ..< ch {
            var net = [Float](repeating: 0, count: netSize * netSize)
            for y in 0 ..< netSize {
                for x in 0 ..< netSize { net[y * netSize + x] = output[(y * netSize + x) * 3 + c] / scale * mad[c] + median[c] }
            }
            if smoothing > 0 { net = Resample.gaussianBlur(net, netSize, netSize, smoothing * 20) }
            // Cut the padding, then Gaussian σ=3 and enlarge.
            var core = [Float](repeating: 0, count: inner * inner)
            for y in 0 ..< inner { for x in 0 ..< inner { core[y * inner + x] = net[(y + padding) * netSize + padding + x] } }
            core = Resample.gaussianBlur(core, inner, inner, 3)
            background.setChannel(c, Resample.resize(core, inner, inner, w, h))
        }
        return background
    }

    /// Subtraction: image − background + the background's mean (one common mean, as in GraXpert).
    public static func subtract(_ image: AstroImage, _ background: AstroImage) -> AstroImage {
        let result = image.createEmptyLike()
        var sum = 0.0
        for v in background.data { sum += Double(v) }
        let mean = Float(sum / Double(background.data.count))
        for i in 0 ..< result.data.count { result.data[i] = image.data[i] - background.data[i] + mean }
        result.clamp01()
        return result
    }

    /// Division (flat-like correction): image / background · the channel mean.
    public static func divide(_ image: AstroImage, _ background: AstroImage) -> AstroImage {
        let result = image.createEmptyLike()
        let n = image.pixelsPerChannel
        for c in 0 ..< image.channels {
            var sum = 0.0
            for i in c * n ..< (c + 1) * n { sum += Double(image.data[i]) }
            let mean = Float(sum / Double(n))
            for i in c * n ..< (c + 1) * n {
                let bg = background.data[i]
                result.data[i] = bg > 1e-6 ? image.data[i] / bg * mean : image.data[i]
            }
        }
        result.clamp01()
        return result
    }
}

/// GraXpert's deconvolution (sharpening) networks on a linear image: a stellar one (tightens stars)
/// and an object one (nebula / galaxy detail). 512×512 single-channel tiles, log-normalised per tile,
/// plus a condition vector (normalised PSF size, strength). The net predicts a residual; tiles overlap
/// by 64 px so only their 448×448 cores are kept. Follows GraXpert's deconvolution.py.
public enum DeconvolutionModel {
    public static let window = 512
    public static let stride = 448
    public static let offset = (window - stride) / 2
    static let epsilon: Float = 1e-5
    static let normScale: Float = 0.1

    /// Star FWHM in pixels → the network's 0.05–0.95 condition value (version-specific, as in GraXpert).
    public static func normalizedPsf(stellar: Bool, _ modelVersion: String, _ fwhmPx: Float) -> Float {
        let sigma = fwhmPx / 2.355
        let v: Float = stellar ? (sigma - 1.5) / 3.0 : modelVersion.contains("1.0.0") ? (sigma - 1.0) / 5.0 : (sigma - 0.5) / 5.5
        return v.clamped(0.05, 0.95)
    }

    public static func deconvolve(_ image: AstroImage, _ modelPath: String, stellar: Bool, strength: Float, fwhmPx: Float,
                                  progress: ((Double) -> Void)? = nil, _ ct: CancellationToken = .none) throws -> AstroImage {
        let w = image.width, h = image.height, ch = image.channels
        let version = AiModelStore.versionOf(modelPath)
        let psf = normalizedPsf(stellar: stellar, version, fwhmPx)
        let strength = strength.clamped(0, 1) * 0.95 // strength 1.0 gives no result in the nets (GraXpert quirk)

        let tiling = Tiling(window, stride, w, h)
        let ith = tiling.rows, itw = tiling.cols, pw = tiling.paddedWidth
        let rowMap = tiling.rowMap(), colMap = tiling.colMap()
        let padded = (0 ..< ch).map { tiling.pad(image.data, $0 * image.pixelsPerChannel, rowMap, colMap) }
        var output = padded

        let model = try CoreMLRunner.load(modelPath)
        let names = CoreMLRunner.inputNames(model)
        let separateParams = names.contains("sigma") // object model v1.0.0 layout

        let total = ith * itw
        var done = 0
        var tile = [Float](repeating: 0, count: ch * window * window)
        var mins = [Float](repeating: 0, count: ch)
        for i in 0 ..< ith {
            for j in 0 ..< itw {
                try ct.check()
                let x0 = i * stride, y0 = j * stride // GraXpert: i walks rows, j walks columns

                // Log-normalise the tile: per-channel minimum, then a shared mean/std over all channels.
                var sum = 0.0, sumSq = 0.0
                for c in 0 ..< ch {
                    var mn = Float.greatestFiniteMagnitude
                    padded[c].withUnsafeBufferPointer { p in
                        for y in 0 ..< window {
                            let row = (x0 + y) * pw + y0
                            for x in 0 ..< window { mn = min(mn, p[row + x]) }
                        }
                        mins[c] = mn
                        for y in 0 ..< window {
                            let row = (x0 + y) * pw + y0
                            for x in 0 ..< window {
                                let v = log(p[row + x] - mn + epsilon)
                                tile[(c * window + y) * window + x] = v
                                sum += Double(v); sumSq += Double(v * v)
                            }
                        }
                    }
                }
                let n = Double(ch * window * window)
                let mean = Float(sum / n)
                let std = max(Float(sqrt(max(sumSq / n - Double(mean) * Double(mean), 0))), 1e-6)
                for k in 0 ..< tile.count { tile[k] = (tile[k] - mean) / std * normScale }

                // One channel at a time (the networks treat the batch entries independently).
                for c in 0 ..< ch {
                    let plane = Array(tile[c * window * window ..< (c + 1) * window * window])
                    var inputs: [(name: String, shape: [Int], data: [Float])] = [("gen_input_image", [1, 1, window, window], plane)]
                    if separateParams {
                        inputs.append(("sigma", [1, 1], [psf]))
                        inputs.append(("strenght", [1, 1], [strength]))
                    } else {
                        inputs.append(("params", [1, 2], [psf, strength]))
                    }
                    let residual = try CoreMLRunner.predict(model, inputs)
                    // Residual → de-normalise → exp → original scale; only the tile core is kept.
                    output[c].withUnsafeMutableBufferPointer { dst in
                        for y in offset ..< offset + stride {
                            let row = (x0 + y) * pw + y0
                            for x in offset ..< offset + stride {
                                let v = (plane[y * window + x] - residual[y * window + x]) * std / normScale + mean
                                dst[row + x] = exp(v) + mins[c] - epsilon
                            }
                        }
                    }
                }
                done += 1
                progress?(Double(done) / Double(total))
            }
        }

        var data = [Float](repeating: 0, count: w * h * ch)
        for c in 0 ..< ch { tiling.unpad(output[c], into: &data, at: c * w * h) }
        let result = AstroImage(width: w, height: h, channels: ch, data: data, header: image.header)
        result.clamp01()
        return result
    }
}

/// GraXpert's denoising network. The image is normalised per channel with the global median and MAD
/// ((x − median)/MAD·0.04), cut into 256×256 RGB tiles with a 128 px stride; pixels above the model
/// threshold (bright stars, cores) keep their values; the result is blended with the original by the
/// strength. Follows GraXpert's denoising.py.
public enum DenoiseModel {
    public static let window = 256
    public static let stride = 128
    static let scale: Float = 0.04

    /// Old (1.x) models were trained on a ±1 range, the current ones on ±10.
    public static func thresholdFor(_ modelVersion: String) -> Float {
        modelVersion.contains("1.0.0") || modelVersion.contains("1.1.0") ? 1 : 10
    }

    public static func denoise(_ image: AstroImage, _ modelPath: String, strength: Float, progress: ((Double) -> Void)? = nil,
                               _ ct: CancellationToken = .none) throws -> AstroImage {
        let w = image.width, h = image.height, ch = image.channels
        let threshold = thresholdFor(AiModelStore.versionOf(modelPath))
        let strength = strength.clamped(0, 1)

        // Per-channel median / MAD of the whole image (empty rotation corners excluded).
        let stats = ImageStats.computeAll(image)
        var median = [Float](repeating: 0, count: 3), mad = [Float](repeating: 0, count: 3)
        for c in 0 ..< 3 {
            let s = stats[min(c, ch - 1)]
            median[c] = s.median; mad[c] = max(s.mad, 1e-6)
        }

        let tiling = Tiling(window, stride, w, h)
        let pw = tiling.paddedWidth, off = tiling.offset
        let rowMap = tiling.rowMap(), colMap = tiling.colMap()
        // The net always takes three channels: a mono image is fed as grey RGB.
        let padded = (0 ..< 3).map { tiling.pad(image.data, min($0, ch - 1) * image.pixelsPerChannel, rowMap, colMap) }
        var output = padded

        let model = try CoreMLRunner.load(modelPath)
        let name = CoreMLRunner.inputNames(model).first ?? "gen_input_image"
        let total = tiling.tileCount
        var done = 0
        var input = [Float](repeating: 0, count: window * window * 3)
        var raw = [Float](repeating: 0, count: window * window * 3)
        for i in 0 ..< tiling.rows {
            for j in 0 ..< tiling.cols {
                try ct.check()
                let x0 = i * stride, y0 = j * stride
                for c in 0 ..< 3 {
                    let p = padded[c]
                    for y in 0 ..< window {
                        let row = (x0 + y) * pw + y0
                        for x in 0 ..< window {
                            let v = (p[row + x] - median[c]) / mad[c] * scale
                            raw[(y * window + x) * 3 + c] = v
                            input[(y * window + x) * 3 + c] = v.clamped(-threshold, threshold)
                        }
                    }
                }
                let res = try CoreMLRunner.predict(model, [(name, [1, window, window, 3], input)])
                for c in 0 ..< 3 {
                    output[c].withUnsafeMutableBufferPointer { dst in
                        for y in off ..< off + stride {
                            let row = (x0 + y) * pw + y0
                            for x in off ..< off + stride {
                                let k = (y * window + x) * 3 + c
                                let v = raw[k] < threshold ? res[k] : raw[k]
                                dst[row + x] = v / scale * mad[c] + median[c]
                            }
                        }
                    }
                }
                done += 1
                progress?(Double(done) / Double(total))
            }
        }

        // Blend: bright pixels stay original, the rest is mixed by the strength.
        let result = AstroImage(width: w, height: h, channels: ch, header: image.header)
        var denoised = [Float](repeating: 0, count: w * h)
        let n = w * h
        for c in 0 ..< ch {
            tiling.unpad(output[c], into: &denoised, at: 0)
            let absThreshold = threshold / scale * mad[c] + median[c]
            for i in 0 ..< n {
                let o = image.data[c * n + i]
                let d = o < absThreshold ? denoised[i] : o
                result.data[c * n + i] = (d * strength + o * (1 - strength)).clamped(0, 1)
            }
        }
        return result
    }
}
