import Foundation

/// Estimates the typical star size (FWHM in pixels) of a linear image. Stars are detected at full
/// resolution; for each of the brightest unsaturated ones the local background comes from an annulus,
/// and the area above half the peak gives an equivalent-disc FWHM (2·sqrt(area/π)). The median over
/// the stars is returned – enough to drive the sharpening networks.
public enum PsfMeasure {
    private static let radius = 7
    private static let ringInner = 8, ringOuter = 11

    public static func estimateFwhm(_ image: AstroImage, _ ct: CancellationToken = .none, fallback: Float = 4) throws -> Float {
        let stars = try StarDetector.detect(image, maxStars: 400, thresholdSigma: 6, downsample: 1, ct: ct)
        if stars.count < 5 { return fallback }
        let data = image.channelArray(image.channels == 3 ? 1 : 0)
        let w = image.width, h = image.height
        var widths: [Float] = []
        for s in stars.stableSortedDescending(by: { $0.flux }) {
            try ct.check()
            let cx = Int(s.x.roundedEven), cy = Int(s.y.roundedEven)
            if cx < ringOuter || cy < ringOuter || cx >= w - ringOuter || cy >= h - ringOuter { continue }

            // Local background: median of an annulus around the star.
            var ring: [Float] = []
            for dy in -ringOuter ... ringOuter {
                for dx in -ringOuter ... ringOuter {
                    let r2 = dx * dx + dy * dy
                    if r2 < ringInner * ringInner || r2 > ringOuter * ringOuter { continue }
                    ring.append(data[(cy + dy) * w + cx + dx])
                }
            }
            let background = ImageStats.median(&ring)

            var peak = -Float.greatestFiniteMagnitude
            for dy in -2 ... 2 { for dx in -2 ... 2 { peak = max(peak, data[(cy + dy) * w + cx + dx]) } }
            if peak >= 0.98 || peak - background < 1e-4 { continue } // saturated or not really a star

            let half = background + 0.5 * (peak - background)
            var area = 0
            for dy in -radius ... radius { for dx in -radius ... radius where data[(cy + dy) * w + cx + dx] >= half { area += 1 } }
            if area < 1 { continue }
            widths.append(2 * sqrt(Float(area) / .pi))
            if widths.count >= 120 { break }
        }
        if widths.count < 5 { return fallback }
        return ImageStats.median(&widths).clamped(1.5, 14)
    }
}
