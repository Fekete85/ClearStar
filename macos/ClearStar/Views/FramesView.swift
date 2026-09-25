import Charts
import ClearStarAppModel
import ClearStarCore
import SwiftUI

/// Steps 1–2: the loaded frames, after the stack their quality over time and the finished stack.
struct FramesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.framesTitle).font(.title3.weight(.semibold))
                    Text(model.framesSubtitle).foregroundStyle(.secondary)
                }
                if model.showQuality {
                    QualityPanel(model: model)
                }
                if let thumb = model.stackThumbnail, model.isStackView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L.t("ui.frames.stackDone")).font(.headline)
                            Spacer()
                            Button(L.t("ui.frames.openInCrop")) { model.goToCrop() }.buttonStyle(.link)
                        }
                        Image(decorative: thumb, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture { model.goToCrop() }
                    }
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(model.frames) { frame in
                        FrameCard(frame: frame, showStatus: model.isStackView)
                            .onTapGesture { Task { await model.previewFrame(frame) } }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct FrameCard: View {
    let frame: FrameItem
    let showStatus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(frame.typeName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text(frame.detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if showStatus, let used = frame.isUsed {
                    Image(systemName: used ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(used ? .green : .red)
                }
            }
            Text(frame.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
            if showStatus, let status = frame.status {
                Text(status).font(.caption).foregroundStyle(frame.isUsed == false ? Color.red : Color.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
        .opacity(showStatus && frame.isUsed == false ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}

/// Four quality charts in time order (stars, star size, background, rotation): teal used, red skipped,
/// hover for the value, click for the preview.
struct QualityPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("ui.frames.qualityTitle")).font(.headline)
                Spacer()
                Text(L.t("ui.frames.qualityLegend")).font(.caption).foregroundStyle(.secondary)
            }
            chart(L.t("ui.frames.qStars"), height: 84) { $0.stars.map(Double.init) }
            chart(L.t("ui.frames.qSize"), height: 84) { $0.starSize.map(Double.init) }
            chart(L.t("ui.frames.qBackground"), height: 84) { $0.background.map(Double.init) }
            chart(L.t("ui.frames.qAngle"), height: 64) { $0.angle.map(Double.init) }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func chart(_ title: String, height: CGFloat, _ value: @escaping (FrameItem) -> Double?) -> some View {
        QualityChart(title: title, frames: model.frames, value: value) { frame in Task { await model.previewFrame(frame) } }
            .frame(height: height + 26)
    }
}

struct QualityChart: View {
    let title: String
    let frames: [FrameItem]
    let value: (FrameItem) -> Double?
    let onSelect: (FrameItem) -> Void
    @State private var hover: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let h = hover, h < frames.count, let v = value(frames[h]) {
                    Text("\(frames[h].fileName): \(v, format: .number.precision(.fractionLength(0 ... 3)))").font(.caption.monospacedDigit())
                }
            }
            Chart(Array(frames.enumerated()), id: \.offset) { i, f in
                if let v = value(f) {
                    BarMark(x: .value("#", i), y: .value(title, v))
                        .foregroundStyle(f.isUsed == false ? Color.red.opacity(0.8) : Color.teal.opacity(hover == i ? 1 : 0.75))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p):
                                if let plot = proxy.plotFrame, let x: Int = proxy.value(atX: p.x - geo[plot].origin.x) { hover = x } else { hover = nil }
                            case .ended: hover = nil
                            }
                        }
                        .onTapGesture { p in
                            if let plot = proxy.plotFrame, let x: Int = proxy.value(atX: p.x - geo[plot].origin.x), x >= 0, x < frames.count { onSelect(frames[x]) }
                        }
                }
            }
        }
    }
}

/// Siril-style stretch histogram: the stretched image's RGB histogram (log scale), the input histogram
/// as a faint outline, the transfer curve, and dashed markers at BP / LP / SP / HP.
struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func path(_ bins: [Int], _ maxLog: Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h))
                for (i, c) in bins.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(bins.count - 1)
                    let y = h - h * CGFloat(log(Double(c) + 1) / maxLog)
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
                return p
            }
            let maxLog = max(1, (data.output + data.input).flatMap { $0 }.map { log(Double($0) + 1) }.max() ?? 1)
            let colours: [Color] = data.output.count == 3 ? [.red, .green, .blue] : [.white]
            for (c, bins) in data.output.enumerated() {
                ctx.fill(path(bins, maxLog), with: .color(colours[min(c, colours.count - 1)].opacity(0.45)))
            }
            for bins in data.input {
                ctx.stroke(path(bins, maxLog), with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            var curve = Path()
            for (i, v) in data.curve.enumerated() {
                let p = CGPoint(x: w * CGFloat(i) / CGFloat(data.curve.count - 1), y: h - h * CGFloat(v))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(.teal), lineWidth: 1.5)
            if data.showMarkers {
                for (value, name) in [(data.bp, "BP"), (data.lp, "LP"), (data.sp, "SP"), (data.hp, "HP")] where value > 0 && value < 1 {
                    let x = w * CGFloat(value)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: h))
                    ctx.stroke(line, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ctx.draw(Text(name).font(.caption2).foregroundStyle(.white.opacity(0.8)), at: CGPoint(x: x + 10, y: 8))
                }
            }
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
