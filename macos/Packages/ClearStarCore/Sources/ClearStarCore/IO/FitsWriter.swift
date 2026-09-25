import Foundation

/// 32-bit float FITS writer (BITPIX=−32) that carries over the header keys.
public enum FitsWriter {
    private static let structural: Set<String> = ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "BZERO", "BSCALE", "EXTEND", "END"]

    public static func write(_ path: String, _ image: AstroImage) throws {
        try data(image).write(to: URL(fileURLWithPath: path))
    }

    public static func data(_ image: AstroImage) -> Data {
        var cards = [
            card("SIMPLE", "T", "ClearStar"),
            card("BITPIX", "-32", "32 bit lebegőpontos"),
            card("NAXIS", image.channels == 3 ? "3" : "2"),
            card("NAXIS1", String(image.width)),
            card("NAXIS2", String(image.height)),
        ]
        if image.channels == 3 { cards.append(card("NAXIS3", "3")) }
        cards.append(card("BZERO", "0.0"))
        cards.append(card("BSCALE", "1.0"))
        cards.append(card("PROGRAM", quote("ClearStar")))
        for (key, value) in image.header {
            if structural.contains(key.uppercased()) || key.count > 8 || key == "PROGRAM" { continue }
            let v = parseDouble(value) != nil || value == "T" || value == "F" ? value : quote(value)
            cards.append(card(key, v))
        }
        cards.append("END".padding(toLength: FitsReader.cardSize, withPad: " ", startingAt: 0))

        var text = cards.joined()
        let rem = text.count % FitsReader.blockSize
        if rem != 0 { text += String(repeating: " ", count: FitsReader.blockSize - rem) }
        // Header bytes: printable ASCII only (other characters are replaced, as ASCII encoding does).
        var out = Data(text.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") })

        // Rows back in FITS order (first row at the bottom).
        let w = image.width, h = image.height, n = image.pixelsPerChannel
        var buffer = [UInt8](repeating: 0, count: w * h * image.channels * 4)
        image.data.withUnsafeBufferPointer { d in
            buffer.withUnsafeMutableBytes { b in
                var o = 0
                for c in 0 ..< image.channels {
                    for y in stride(from: h - 1, through: 0, by: -1) {
                        let row = c * n + y * w
                        for x in 0 ..< w {
                            b.storeBytes(of: d[row + x].bitPattern.bigEndian, toByteOffset: o, as: UInt32.self)
                            o += 4
                        }
                    }
                }
            }
        }
        out.append(contentsOf: buffer)
        let pad = (FitsReader.blockSize - buffer.count % FitsReader.blockSize) % FitsReader.blockSize
        if pad > 0 { out.append(Data(count: pad)) }
        return out
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''").padding(toLength: max(8, s.replacingOccurrences(of: "'", with: "''").count), withPad: " ", startingAt: 0) + "'"
    }

    private static func card(_ key: String, _ value: String, _ comment: String? = nil) -> String {
        let padKey = key.padding(toLength: max(8, key.count), withPad: " ", startingAt: 0)
        let v = value.hasPrefix("'") ? value : String(repeating: " ", count: max(0, 20 - value.count)) + value
        var body = padKey + "= " + v
        if let comment { body += " / " + comment }
        if body.count > FitsReader.cardSize { return String(body.prefix(FitsReader.cardSize)) }
        return body.padding(toLength: FitsReader.cardSize, withPad: " ", startingAt: 0)
    }
}
