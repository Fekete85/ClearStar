import Foundation

/// Step 3: crop. Either the rectangle selected on the image (the UI fills the hidden parameters, as
/// fractions 0..1 of the image), or without a selection a band cut proportionally from the edges.
public final class CropStep: WorkflowStep {
    public static let marginKey = "margin"
    public static let selLeftKey = "selLeft", selTopKey = "selTop", selWidthKey = "selWidth", selHeightKey = "selHeight"
    public static let rotateKey = "rotate"
    public static let flipHKey = "flipH"
    public static let flipVKey = "flipV"
    public static let angleKey = "angle"
    private static let s = "crop"

    public let definition = StepDefinition.fromLanguage(.crop, .preparation, s, [
        StepKit.slider(s, marginKey, 0.0, 0, 0.15),
        StepKit.choice(s, rotateKey, "0", ["0", "90", "180", "270"]),
        ParameterDefinition(key: angleKey, label: L.t("step.crop.angle.label"), kind: .slider, defaultValue: .number(0), min: -45, max: 45,
                            tickLabels: L.a("step.crop.angle.ticks"), help: L.t("step.crop.angle.help"), valueFormat: "{0:+0.0;−0.0;0}°"),
        StepKit.toggle(s, flipHKey, false),
        StepKit.toggle(s, flipVKey, false),
        StepKit.hidden(selLeftKey, .number(0)),
        StepKit.hidden(selTopKey, .number(0)),
        StepKit.hidden(selWidthKey, .number(0)),
        StepKit.hidden(selHeightKey, .number(0)),
    ])

    public init() {}

    public static func hasSelection(_ p: StepParameters) -> Bool { p.getDouble(selWidthKey) > 0.001 && p.getDouble(selHeightKey) > 0.001 }

    /// Total rotation (90° choice + fine angle) and mirroring – the orientation applied before the crop.
    public static func orientation(_ p: StepParameters) -> (angle: Double, flipH: Bool, flipV: Bool) {
        let rotate = parseInt(p.getString(rotateKey, "0")) ?? 0
        return (Double(rotate) + p.getDouble(angleKey), p.getBool(flipHKey), p.getBool(flipVKey))
    }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        let raw = try context.requireInput()
        let p = context.parameters
        // Orientation first (the selection was drawn on the oriented preview), then the crop.
        let (angle, flipH, flipV) = Self.orientation(p)
        let input = Self.orient(raw, angle, flipH, flipV)
        var left: Int, top: Int, right: Int, bottom: Int
        if Self.hasSelection(p) {
            let sl = p.getDouble(Self.selLeftKey).clamped(0, 1), st = p.getDouble(Self.selTopKey).clamped(0, 1)
            let sw = p.getDouble(Self.selWidthKey).clamped(0, 1 - sl), sh = p.getDouble(Self.selHeightKey).clamped(0, 1 - st)
            left = Int((sl * Double(input.width)).roundedEven); top = Int((st * Double(input.height)).roundedEven)
            right = input.width - Int(((sl + sw) * Double(input.width)).roundedEven)
            bottom = input.height - Int(((st + sh) * Double(input.height)).roundedEven)
        } else {
            let m = p.getFloat(Self.marginKey)
            left = toInt(m * Float(input.width)); right = left
            top = toInt(m * Float(input.height)); bottom = top
        }
        let output = try Self.crop(input, left, top, right, bottom)
        var summary = L.f("msg.crop.size", output.width, output.height)
        if abs(angle) > 1e-6 { summary += L.f("msg.crop.rotated", angle) }
        if flipH || flipV { summary += L.t("msg.crop.flipped") }
        return StepResult(image: output, summary: summary)
    }

    /// Size of the canvas holding the image rotated by `angleDegrees` (bounding box).
    public static func orientedSize(_ width: Int, _ height: Int, _ angleDegrees: Double) -> (width: Int, height: Int) {
        let a = angleDegrees * .pi / 180, c = abs(cos(a)), s = abs(sin(a))
        return (Int((Double(width) * c + Double(height) * s).roundedEven), Int((Double(width) * s + Double(height) * c).roundedEven))
    }

    /// Mirror (horizontal / vertical), then rotate clockwise by any angle. Multiples of 90° are
    /// lossless; other angles are resampled bilinearly onto the bounding-box canvas (empty corners stay black).
    public static func orient(_ input: AstroImage, _ angleDegrees: Double, _ flipH: Bool, _ flipV: Bool) -> AstroImage {
        let norm = (angleDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let nearest = Int((norm / 90).roundedEven) * 90 % 360
        if abs(norm - (norm / 90).roundedEven * 90) < 1e-6 { return orientRightAngle(input, nearest, flipH, flipV) }

        let flipped = (flipH || flipV) ? orientRightAngle(input, 0, flipH, flipV) : input
        let w = flipped.width, h = flipped.height
        let (ow, oh) = orientedSize(w, h, norm)
        let a = norm * .pi / 180, cosA = cos(a), sinA = sin(a)
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2, ocx = Double(ow - 1) / 2, ocy = Double(oh - 1) / 2
        let output = AstroImage(width: ow, height: oh, channels: input.channels, header: input.header)
        let n = flipped.pixelsPerChannel, on = output.pixelsPerChannel
        flipped.data.withUnsafeBufferPointer { src in
            output.data.withUnsafeMutableBufferPointer { dst in
                for c in 0 ..< input.channels {
                    let so = c * n, dstOff = c * on
                    parallelFor(oh) { oy in
                        let dy = Double(oy) - ocy
                        for ox in 0 ..< ow {
                            let dx = Double(ox) - ocx
                            // Inverse of a clockwise rotation (screen coordinates, y down).
                            let sx = cosA * dx + sinA * dy + cx, sy = -sinA * dx + cosA * dy + cy
                            let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                            if x0 < 0 || y0 < 0 || x0 >= w - 1 || y0 >= h - 1 { dst[dstOff + oy * ow + ox] = 0; continue }
                            let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                            let v00 = src[so + y0 * w + x0], v10 = src[so + y0 * w + x0 + 1]
                            let v01 = src[so + (y0 + 1) * w + x0], v11 = src[so + (y0 + 1) * w + x0 + 1]
                            dst[dstOff + oy * ow + ox] = (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
                        }
                    }
                }
            }
        }
        return output
    }

    /// Mirror (horizontal / vertical), then rotate by a multiple of 90° clockwise. Lossless.
    public static func orientRightAngle(_ input: AstroImage, _ rotateDegrees: Int, _ flipH: Bool, _ flipV: Bool) -> AstroImage {
        let rot = ((rotateDegrees % 360) + 360) % 360
        if rot == 0 && !flipH && !flipV { return input }
        let w = input.width, h = input.height
        let swap = rot == 90 || rot == 270
        let ow = swap ? h : w, oh = swap ? w : h
        let output = AstroImage(width: ow, height: oh, channels: input.channels, header: input.header)
        let n = input.pixelsPerChannel
        input.data.withUnsafeBufferPointer { src in
            output.data.withUnsafeMutableBufferPointer { dst in
                for c in 0 ..< input.channels {
                    let off = c * n
                    parallelFor(oh) { oy in
                        for ox in 0 ..< ow {
                            // Undo the rotation to find the source pixel, then undo the flips.
                            var x: Int, y: Int
                            switch rot {
                            case 90: x = oy; y = h - 1 - ox
                            case 180: x = w - 1 - ox; y = h - 1 - oy
                            case 270: x = w - 1 - oy; y = ox
                            default: x = ox; y = oy
                            }
                            if flipH { x = w - 1 - x }
                            if flipV { y = h - 1 - y }
                            dst[off + oy * ow + ox] = src[off + y * w + x]
                        }
                    }
                }
            }
        }
        return output
    }

    public static func crop(_ input: AstroImage, _ left: Int, _ top: Int, _ right: Int, _ bottom: Int) throws -> AstroImage {
        let w = input.width - left - right, h = input.height - top - bottom
        if w < 16 || h < 16 { throw ClearStarError(L.t("msg.crop.tooMuch")) }
        if left == 0 && top == 0 && right == 0 && bottom == 0 { return input.clone() }
        let output = AstroImage(width: w, height: h, channels: input.channels, header: input.header)
        let n = input.pixelsPerChannel, on = output.pixelsPerChannel
        input.data.withUnsafeBufferPointer { src in
            output.data.withUnsafeMutableBufferPointer { dst in
                for c in 0 ..< input.channels {
                    for y in 0 ..< h {
                        let s = c * n + (y + top) * input.width + left, d = c * on + y * w
                        for x in 0 ..< w { dst[d + x] = src[s + x] }
                    }
                }
            }
        }
        return output
    }
}
