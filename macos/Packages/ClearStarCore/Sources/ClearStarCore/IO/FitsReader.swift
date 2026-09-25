import Foundation

public struct FitsError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Simple FITS reader: the primary HDU (2D mono or 3D RGB), BITPIX 8/16/32/−32/−64 with BZERO/BSCALE.
/// Integer data is normalised to [0,1].
public enum FitsReader {
    public static let blockSize = 2880
    public static let cardSize = 80
    public static let extensions = [".fit", ".fits", ".fts"]

    public static func isFits(_ path: String) -> Bool {
        let ext = "." + (path as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }

    public static func read(_ path: String) throws -> AstroImage {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        defer { try? handle.close() }
        let (header, dataStart) = try readHeader(handle)
        try handle.seek(toOffset: UInt64(dataStart))

        let bitpix = try getInt(header, "BITPIX")
        let naxis = try getInt(header, "NAXIS")
        guard naxis == 2 || naxis == 3 else { throw FitsError(message: "Csak 2 vagy 3 dimenziós FITS támogatott (NAXIS=\(naxis)).") }
        let width = try getInt(header, "NAXIS1")
        let height = try getInt(header, "NAXIS2")
        let channels = naxis == 3 ? try getInt(header, "NAXIS3") : 1
        guard channels == 1 || channels == 3 else { throw FitsError(message: "Csak 1 vagy 3 csatornás FITS támogatott (NAXIS3=\(channels)).") }
        let bzero = getDouble(header, "BZERO", 0)
        let bscale = getDouble(header, "BSCALE", 1)

        let pixels = width * height * channels
        let bytesPerPixel = abs(bitpix) / 8
        guard [8, 16, 32, -32, -64].contains(bitpix) else { throw FitsError(message: "Nem támogatott BITPIX: \(bitpix).") }
        let raw = try handle.read(upToCount: pixels * bytesPerPixel) ?? Data()
        guard raw.count == pixels * bytesPerPixel else { throw FitsError(message: "A FITS fájl rövidebb a vártnál.") }

        var data = [Float](repeating: 0, count: pixels)
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            data.withUnsafeMutableBufferPointer { d in
                // Integer types: physical value = BZERO + BSCALE·raw, normalised to the type's full range.
                switch bitpix {
                case 8:
                    for i in 0 ..< pixels { d[i] = Float((bzero + bscale * Double(buf[i])) / 255.0) }
                case 16:
                    // The common "unsigned 16 bit" convention: BZERO=32768 → 0..65535.
                    let norm = bzero == 32768 ? 65535.0 : 32767.0
                    for i in 0 ..< pixels {
                        let v = Int16(bitPattern: UInt16(bigEndian: buf.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                        d[i] = Float((bzero + bscale * Double(v)) / norm)
                    }
                case 32:
                    let norm = bzero == 2147483648 ? 4294967295.0 : 2147483647.0
                    for i in 0 ..< pixels {
                        let v = Int32(bitPattern: UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                        d[i] = Float((bzero + bscale * Double(v)) / norm)
                    }
                case -32:
                    for i in 0 ..< pixels {
                        let v = Float(bitPattern: UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                        d[i] = Float(bzero + bscale * Double(v))
                    }
                default:
                    for i in 0 ..< pixels {
                        let v = Double(bitPattern: UInt64(bigEndian: buf.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)))
                        d[i] = Float(bzero + bscale * v)
                    }
                }
            }
        }

        // A float image whose values are obviously not in [0,1] (e.g. 0..65535) is normalised.
        if bitpix < 0 {
            var mx: Float = 0
            for v in data where v > mx { mx = v }
            if mx > 1.5 {
                let norm: Float = mx <= 255 ? 255 : (mx <= 65535 ? 65535 : mx)
                for i in 0 ..< pixels { data[i] /= norm }
            }
        }

        // FITS puts the first row at the bottom; in processing row 0 is the top. Rows are flipped.
        let image = AstroImage(width: width, height: height, channels: channels, data: data, header: header)
        flipVertical(image)
        return image
    }

    public static func readHeader(_ path: String) throws -> FitsHeader {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        defer { try? handle.close() }
        return try readHeader(handle).header
    }

    static func readHeader(_ handle: FileHandle) throws -> (header: FitsHeader, dataStart: Int) {
        var header = FitsHeader()
        var end = false
        var pos = 0
        var first = true
        while !end {
            guard let block = try handle.read(upToCount: blockSize), block.count == blockSize else {
                throw FitsError(message: "A FITS fájl rövidebb a vártnál.")
            }
            pos += blockSize
            let bytes = [UInt8](block)
            var i = 0
            while i < blockSize {
                // ASCII decoding: other bytes become "?", like Encoding.ASCII.
                let card = String(bytes[i ..< i + cardSize].map { Character(Unicode.Scalar($0 < 128 ? $0 : 63)) })
                i += cardSize
                if first {
                    guard card.hasPrefix("SIMPLE") else { throw FitsError(message: "Nem FITS fájl (hiányzik a SIMPLE kulcs).") }
                    first = false
                }
                let chars = Array(card)
                let key = String(chars[0 ..< 8]).trimmingTrailingSpaces()
                if key == "END" { end = true; break }
                if key.isEmpty || key == "COMMENT" || key == "HISTORY" { continue }
                if chars.count < 10 || chars[8] != "=" { continue }
                var value = String(chars[10...])
                if let slash = findCommentSlash(value) { value = String(value[..<slash]) }
                value = value.trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.first == "'", value.last == "'" {
                    value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'").trimmingTrailingSpaces()
                }
                header[key] = value
            }
        }
        return (header, pos)
    }

    private static func findCommentSlash(_ value: String) -> String.Index? {
        var inString = false
        var i = value.startIndex
        while i < value.endIndex {
            let c = value[i]
            if c == "'" { inString.toggle() } else if c == "/" && !inString { return i }
            i = value.index(after: i)
        }
        return nil
    }

    static func getInt(_ h: FitsHeader, _ key: String) throws -> Int {
        guard let v = parseInt(h[key]) else { throw FitsError(message: "Hiányzó vagy hibás FITS kulcs: \(key).") }
        return v
    }

    static func getDouble(_ h: FitsHeader, _ key: String, _ fallback: Double) -> Double { parseDouble(h[key]) ?? fallback }

    static func flipVertical(_ image: AstroImage) {
        let w = image.width, h = image.height, n = image.pixelsPerChannel
        image.data.withUnsafeMutableBufferPointer { d in
            for c in 0 ..< image.channels {
                for y in 0 ..< h / 2 {
                    let a = c * n + y * w, b = c * n + (h - 1 - y) * w
                    for x in 0 ..< w { d.swapAt(a + x, b + x) }
                }
            }
        }
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
