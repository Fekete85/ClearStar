import AppKit
import ClearStarCore
import SwiftUI

/// Zoomable, pannable image view with a before/after split and a rectangle selection (crop, eyedropper).
/// Pinch or the mouse wheel zooms, a trackpad scroll or a drag pans; in selection mode a drag on the image
/// draws the rectangle, its edges and corners resize it, its inside moves it.
struct ImageViewer: NSViewRepresentable {
    var image: CGImage?
    var beforeImage: CGImage?
    var isSplit: Bool
    var isSelectionMode: Bool
    var dimOutside: Bool
    var selection: CGRect?
    var hint: String?
    var sourceScale: Double
    var generation: Int
    var zoomCommand: ZoomCommand?
    var onSelection: (CGRect?) -> Void

    func makeNSView(context: Context) -> ImageViewerView {
        let v = ImageViewerView()
        v.onSelection = onSelection
        return v
    }

    func updateNSView(_ v: ImageViewerView, context: Context) {
        v.onSelection = onSelection
        v.update(image: image, before: beforeImage, split: isSplit, selectionMode: isSelectionMode, dim: dimOutside,
                 selection: selection, hint: hint, sourceScale: sourceScale, generation: generation)
        if let zoomCommand, zoomCommand.id != v.lastZoomCommand {
            v.lastZoomCommand = zoomCommand.id
            switch zoomCommand.kind {
            case .zoomIn: v.zoom(by: 1.25, at: nil)
            case .zoomOut: v.zoom(by: 0.8, at: nil)
            case .fit: v.fit()
            case .actual: v.zoomTo(1 / max(sourceScale, 1e-9), at: nil)
            }
        }
    }
}

/// A zoom request from the menu or the toolbar (a new id each time).
struct ZoomCommand: Equatable {
    enum Kind { case zoomIn, zoomOut, fit, actual }
    let kind: Kind
    let id = UUID()
}

final class ImageViewerView: NSView {
    var onSelection: ((CGRect?) -> Void)?
    var lastZoomCommand: UUID?

    private var image: CGImage?
    private var before: CGImage?
    private var split = false
    private var splitPosition: CGFloat = 0.5
    private var selectionMode = false
    private var dim = true
    private var selection: CGRect?          // fractions of the image, y down
    private var hint: String?
    private var sourceScale = 1.0
    private var generation = -1
    private var fitPending = true

    // View transform: image pixel (x, y-down) → view point: (x·scale + offset.x, y·scale + offset.y) in a flipped view.
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero

    private enum Drag { case none, pan, split, new, move, l, r, t, b, tl, tr, bl, br }
    private var drag = Drag.none
    private var dragStart = CGPoint.zero
    private var dragStartOffset = CGPoint.zero
    private var dragStartImage = CGPoint.zero
    private var dragStartRect = CGRect.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(image: CGImage?, before: CGImage?, split: Bool, selectionMode: Bool, dim: Bool, selection: CGRect?, hint: String?,
                sourceScale: Double, generation: Int) {
        let newSize = image.map { ($0.width, $0.height) }
        let oldSize = self.image.map { ($0.width, $0.height) }
        self.image = image
        self.before = before
        self.split = split
        self.selectionMode = selectionMode
        self.dim = dim
        self.selection = selection
        self.hint = hint
        self.sourceScale = sourceScale
        // A new image (load, crop, another size) is fitted; otherwise the view stays where it was.
        if generation != self.generation || newSize.map({ [$0.0, $0.1] }) != oldSize.map({ [$0.0, $0.1] }) || fitPending {
            self.generation = generation
            fit()
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        if fitPending { fit() }
    }

    func fit() {
        guard let image, bounds.width > 0, bounds.height > 0 else { fitPending = true; return }
        fitPending = false
        var s = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        s = min(s, 1 / CGFloat(sourceScale) * 4) * 0.98
        scale = s
        offset = CGPoint(x: (bounds.width - CGFloat(image.width) * s) / 2, y: (bounds.height - CGFloat(image.height) * s) / 2)
        needsDisplay = true
    }

    func zoomTo(_ newScale: CGFloat, at point: CGPoint?) {
        guard image != nil else { return }
        let target = min(max(newScale, 0.02), 16 / CGFloat(sourceScale))
        let c = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let factor = target / scale
        offset = CGPoint(x: c.x - (c.x - offset.x) * factor, y: c.y - (c.y - offset.y) * factor)
        scale = target
        needsDisplay = true
    }

    func zoom(by factor: CGFloat, at point: CGPoint?) { zoomTo(scale * factor, at: point) }

    private func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }

    private var imageRectInView: CGRect {
        guard let image else { return .zero }
        return CGRect(x: offset.x, y: offset.y, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private var selectionInView: CGRect? {
        guard let s = selection, let image else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let a = toView(CGPoint(x: s.minX * w, y: s.minY * h)), b = toView(CGPoint(x: s.maxX * w, y: s.maxY * h))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor(named: "ViewerBackground")?.cgColor ?? NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)!.cgColor)
        ctx.fill(bounds)
        guard let image else { return }
        let rect = imageRectInView
        ctx.interpolationQuality = scale * CGFloat(sourceScale) >= 2 ? .none : .high
        drawImage(ctx, image, rect)
        if split, let before {
            let x = bounds.width * splitPosition
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: x, height: bounds.height))
            drawImage(ctx, before, rect)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: bounds.height)])
            label(ctx, L.t("ui.viewer.before"), at: CGPoint(x: x - 12, y: 12), alignRight: true)
            label(ctx, L.t("ui.viewer.after"), at: CGPoint(x: x + 12, y: 12), alignRight: false)
        }
        if selectionMode {
            if let sel = selectionInView {
                if dim {
                    ctx.saveGState()
                    ctx.addRect(bounds)
                    ctx.addRect(sel)
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                    ctx.fillPath(using: .evenOdd)
                    ctx.restoreGState()
                }
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(sel)
                if dim {
                    ctx.setFillColor(NSColor.white.cgColor)
                    for p in handlePoints(sel) { ctx.fillEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)) }
                    let w = (selection!.width * CGFloat(image.width) * CGFloat(sourceScale)).rounded()
                    let h = (selection!.height * CGFloat(image.height) * CGFloat(sourceScale)).rounded()
                    label(ctx, "\(Int(w)) × \(Int(h)) px", at: CGPoint(x: sel.minX + 6, y: max(6, sel.minY - 26)), alignRight: false)
                }
            } else if let hint {
                label(ctx, hint, at: CGPoint(x: 16, y: bounds.height - 40), alignRight: false, maxWidth: bounds.width - 32)
            }
        }
        let zoomText = "\(Int((scale * CGFloat(sourceScale) * 100).rounded()))%"
        label(ctx, zoomText, at: CGPoint(x: bounds.width - 12, y: bounds.height - 34), alignRight: true)
    }

    private func drawImage(_ ctx: CGContext, _ img: CGImage, _ rect: CGRect) {
        // The view is flipped: draw the image upside down so it appears upright.
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func label(_ ctx: CGContext, _ text: String, at p: CGPoint, alignRight: Bool, maxWidth: CGFloat = 600) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        var size = str.boundingRect(with: CGSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin]).size
        size.width = ceil(size.width); size.height = ceil(size.height)
        let x = alignRight ? p.x - size.width - 12 : p.x
        let box = CGRect(x: x, y: p.y, width: size.width + 12, height: size.height + 6)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        str.draw(with: CGRect(x: box.minX + 6, y: box.minY + 3, width: size.width, height: size.height), options: [.usesLineFragmentOrigin])
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.midY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    // MARK: Mouse

    private func hitTest(selectionAt p: CGPoint) -> Drag {
        guard let r = selectionInView else { return .new }
        let t: CGFloat = 8
        let nearL = abs(p.x - r.minX) < t, nearR = abs(p.x - r.maxX) < t, nearT = abs(p.y - r.minY) < t, nearB = abs(p.y - r.maxY) < t
        let inX = p.x > r.minX - t && p.x < r.maxX + t, inY = p.y > r.minY - t && p.y < r.maxY + t
        if nearL && nearT { return .tl }
        if nearR && nearT { return .tr }
        if nearL && nearB { return .bl }
        if nearR && nearB { return .br }
        if nearL && inY { return .l }
        if nearR && inY { return .r }
        if nearT && inX { return .t }
        if nearB && inX { return .b }
        if r.contains(p) && dim { return .move }
        return .new
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragStartOffset = offset
        if split, before != nil, abs(p.x - bounds.width * splitPosition) < 8 { drag = .split; return }
        if selectionMode && image != nil && imageRectInView.contains(p) && !event.modifierFlags.contains(.option) {
            drag = hitTest(selectionAt: p)
            dragStartImage = toImage(p)
            dragStartRect = selection ?? .zero
            return
        }
        drag = .pan
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let image else { return }
        switch drag {
        case .pan:
            offset = CGPoint(x: dragStartOffset.x + p.x - dragStart.x, y: dragStartOffset.y + p.y - dragStart.y)
        case .split:
            splitPosition = min(max(p.x / bounds.width, 0.02), 0.98)
        case .none:
            break
        default:
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let q = toImage(p)
            let nx = min(max(q.x / w, 0), 1), ny = min(max(q.y / h, 0), 1)
            let sx = min(max(dragStartImage.x / w, 0), 1), sy = min(max(dragStartImage.y / h, 0), 1)
            var r = dragStartRect
            switch drag {
            case .new: r = CGRect(x: min(sx, nx), y: min(sy, ny), width: abs(nx - sx), height: abs(ny - sy))
            case .move:
                let dx = nx - sx, dy = ny - sy
                r.origin.x = min(max(dragStartRect.minX + dx, 0), 1 - r.width)
                r.origin.y = min(max(dragStartRect.minY + dy, 0), 1 - r.height)
            default:
                var x0 = dragStartRect.minX, y0 = dragStartRect.minY, x1 = dragStartRect.maxX, y1 = dragStartRect.maxY
                if [.l, .tl, .bl].contains(drag) { x0 = nx }
                if [.r, .tr, .br].contains(drag) { x1 = nx }
                if [.t, .tl, .tr].contains(drag) { y0 = ny }
                if [.b, .bl, .br].contains(drag) { y1 = ny }
                r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
            }
            selection = r
            onSelection?(r.width > 0.002 && r.height > 0.002 ? r : nil)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if drag == .new, let s = selection, s.width <= 0.002 || s.height <= 0.002 {
            // A click without a drag: the eyedropper takes a tiny box around the point; the crop keeps its frame.
            if !dim, let image {
                let q = toImage(convert(event.locationInWindow, from: nil))
                let r = CGRect(x: q.x / CGFloat(image.width) - 0.005, y: q.y / CGFloat(image.height) - 0.005, width: 0.01, height: 0.01)
                onSelection?(r)
            }
        }
        drag = .none
    }

    // The middle button pans too (like the Windows version).
    override func otherMouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragStartOffset = offset
    }

    override func otherMouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        offset = CGPoint(x: dragStartOffset.x + p.x - dragStart.x, y: dragStartOffset.y + p.y - dragStart.y)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            offset = CGPoint(x: offset.x + event.scrollingDeltaX, y: offset.y + event.scrollingDeltaY)
            needsDisplay = true
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 50 : event.scrollingDeltaY / 5
            zoom(by: pow(1.2, delta), at: p)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        if selectionMode && image != nil { addCursorRect(imageRectInView.intersection(bounds), cursor: .crosshair) }
        if split && before != nil {
            addCursorRect(CGRect(x: bounds.width * splitPosition - 6, y: 0, width: 12, height: bounds.height), cursor: .resizeLeftRight)
        }
    }
}
