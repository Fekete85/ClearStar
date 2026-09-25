import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: Sendable { case jpeg, tiff16, png16, fits }

/// Loading and saving images by format (FITS with our own code, the rest with ImageIO).
public enum ImageFiles {
    static let rasterExtensions = [".tif", ".tiff", ".png", ".jpg", ".jpeg"]
    public static let supportedExtensions = FitsReader.extensions + rasterExtensions

    public static func isSupported(_ path: String) -> Bool {
        supportedExtensions.contains("." + (path as NSString).pathExtension.lowercased())
    }

    /// Loads an image; a Bayer-pattern (single-channel, BAYERPAT) FITS is turned into colour.
    public static func load(_ path: String, debayer: Bool = true) throws -> AstroImage {
        if FitsReader.isFits(path) {
            let img = try FitsReader.read(path)
            if debayer, img.channels == 1, let pattern = Debayer.parse(img.header["BAYERPAT"]) {
                return Debayer.bilinear(img, effectiveBayerPattern(img, pattern))
            }
            return img
        }
        if rasterExtensions.contains("." + (path as NSString).pathExtension.lowercased()) { return try loadRaster(path) }
        throw ClearStarError("Nem támogatott képformátum: .\((path as NSString).pathExtension)")
    }

    /// The header's pattern refers to the data as stored. We flip the rows (FITS stores bottom-up), so
    /// for an even height the two rows of the pattern swap – unless the capture software wrote top-down
    /// (ROWORDER=TOP-DOWN), when the header's pattern is right after our flip.
    public static func effectiveBayerPattern(_ img: AstroImage, _ headerPattern: BayerPattern) -> BayerPattern {
        let topDown = img.header["ROWORDER"]?.trimmingCharacters(in: .whitespaces).uppercased() == "TOP-DOWN"
        let yOffset = parseInt(img.header["YBAYROFF"]) ?? 0
        var p = headerPattern
        if (yOffset & 1) == 1 { p = Debayer.flipRows(p) }
        if !topDown && (img.height & 1) == 0 { p = Debayer.flipRows(p) }
        return p
    }

    /// TIFF/PNG/JPEG as 16-bit RGB (grey images are replicated into the three channels), no colour
    /// management – the pixel values as stored, like ImageSharp's Rgb48.
    static func loadRaster(_ path: String) throws -> AstroImage {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ClearStarError("A kép nem olvasható: \((path as NSString).lastPathComponent)")
        }
        let w = cg.width, h = cg.height, n = w * h
        let grey = cg.colorSpace?.model == .monochrome
        let space = cg.colorSpace.flatMap { ($0.model == .rgb || $0.model == .monochrome) ? $0 : nil }
            ?? (grey ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!)
        let comps = grey ? 1 : 4
        var buf = [UInt16](repeating: 0, count: n * comps)
        let info = (grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) | CGBitmapInfo.byteOrder16Little.rawValue
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * comps * 2,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { throw ClearStarError("A kép nem olvasható: \((path as NSString).lastPathComponent)") }
        var data = [Float](repeating: 0, count: n * 3)
        for i in 0 ..< n {
            if grey {
                let v = Float(buf[i]) / 65535
                data[i] = v; data[n + i] = v; data[2 * n + i] = v
            } else {
                data[i] = Float(buf[i * 4]) / 65535
                data[n + i] = Float(buf[i * 4 + 1]) / 65535
                data[2 * n + i] = Float(buf[i * 4 + 2]) / 65535
            }
        }
        let image = AstroImage(width: w, height: h, channels: 3, data: data)
        image.header["ORIGFILE"] = (path as NSString).lastPathComponent
        return image
    }

    public static func extensionFor(_ format: ExportFormat) -> String {
        switch format {
        case .jpeg: return ".jpg"
        case .tiff16: return ".tif"
        case .png16: return ".png"
        case .fits: return ".fits"
        }
    }

    public static func save(_ path: String, _ image: AstroImage, _ format: ExportFormat, jpegQuality: Int = 92) throws {
        if format == .fits { try FitsWriter.write(path, image); return }
        let w = image.width, h = image.height, n = w * h
        var rgb16 = [UInt16](repeating: 0, count: n * 3)
        image.data.withUnsafeBufferPointer { d in
            for i in 0 ..< n {
                if image.channels == 3 {
                    rgb16[i * 3] = to16(d[i]); rgb16[i * 3 + 1] = to16(d[n + i]); rgb16[i * 3 + 2] = to16(d[2 * n + i])
                } else {
                    let v = to16(d[i])
                    rgb16[i * 3] = v; rgb16[i * 3 + 1] = v; rgb16[i * 3 + 2] = v
                }
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg: CGImage?
        if format == .jpeg {
            // 16 → 8 bit with rounding, like ImageSharp's Rgb48 → Rgb24.
            let bytes = rgb16.map { UInt8((UInt32($0) * 255 + 32895) >> 16) }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                         shouldInterpolate: false, intent: .defaultIntent)
        } else {
            let data = rgb16.withUnsafeBufferPointer { Data(buffer: $0) }
            let provider = CGDataProvider(data: data as CFData)!
            cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let cg else { throw ClearStarError("A kép nem menthető.") }
        let type: UTType = format == .jpeg ? .jpeg : format == .tiff16 ? .tiff : .png
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil) else {
            throw ClearStarError("A kép nem menthető: \(path)")
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = Double(jpegQuality) / 100 }
        if format == .tiff16 { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] } // LZW, lossless
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw ClearStarError("A kép nem menthető: \(path)") }
    }

    @inline(__always) static func to16(_ v: Float) -> UInt16 { UInt16((v * 65535).roundedEven.clamped(0, 65535)) }
}
