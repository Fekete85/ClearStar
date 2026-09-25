import ClearStarAppModel
import ClearStarCore
import SwiftUI

/// The main window: the steps on the left, the image in the middle, the step's settings on the right.
struct MainView: View {
    @Bindable var model: AppModel
    @Binding var zoom: ZoomCommand?
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            ImageStage(model: model, zoom: $zoom, dropTargeted: dropTargeted)
                .inspector(isPresented: $showInspector) {
                    if let step = model.selectedStep {
                        InspectorView(model: model, step: step)
                            .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
                    }
                }
        }
        .navigationTitle(model.windowTitle)
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, let first = urls.first else { return false }
            // One file → that image; several files or a folder → the folder.
            let path = urls.count == 1 ? first.path : first.deletingLastPathComponent().path
            Task { await model.loadPath(path) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: $model.showWelcome) { WelcomeView(model: model) }
        .sheet(isPresented: $model.showStarNetSetup, onDismiss: model.refreshNotes) { StarNetSetupView() }
        .sheet(isPresented: $model.showCatalogSetup, onDismiss: model.refreshNotes) { CatalogSetupView() }
        .focusedSceneValue(\.inspectorVisible, $showInspector)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.showOriginal.toggle()
            } label: {
                Label(L.t("ui.toolbar.original"), systemImage: model.showOriginal ? "eye.fill" : "eye")
            }
            .help(L.t("ui.toolbar.originalTip"))
            .disabled(!model.canCompare)

            Toggle(isOn: $model.splitView) {
                Label(L.t("ui.toolbar.split"), systemImage: "rectangle.split.2x1")
            }
            .help(L.t("ui.toolbar.split"))
            .disabled(!model.canCompare)

            Menu {
                Picker(L.t("ui.toolbar.stretchMenuTitle"), selection: $model.stretchPresetKey) {
                    ForEach(model.stretchPresets, id: \.key) { Text($0.label).tag($0.key) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(L.t("ui.toolbar.boost"), systemImage: model.autoStretch ? "sun.max.fill" : "sun.max")
            } primaryAction: {
                model.autoStretch.toggle()
            }
            .help(L.t("ui.toolbar.boostTip"))
            .disabled(!model.canCompare)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { zoom = ZoomCommand(kind: .zoomOut) } label: { Label(L.t("ui.viewer.zoomOut"), systemImage: "minus.magnifyingglass") }
                Button { zoom = ZoomCommand(kind: .fit) } label: { Label(L.t("ui.viewer.fit"), systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                Button { zoom = ZoomCommand(kind: .zoomIn) } label: { Label(L.t("ui.viewer.zoomIn"), systemImage: "plus.magnifyingglass") }
            }
            .disabled(model.previewImage == nil)
            Button { showInspector.toggle() } label: { Label(L.t("mac.menu.inspector"), systemImage: "sidebar.right") }
                .help(L.t("mac.menu.inspector"))
        }
    }
}

/// The middle: frame list (steps 1–2) or the image, the drop zone, the histogram and the status bar.
struct ImageStage: View {
    @Bindable var model: AppModel
    @Binding var zoom: ZoomCommand?
    var dropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.5)
                if model.previewImage != nil && !(model.isFramesView && !model.isFramePreview) {
                    ImageViewer(image: model.previewImage, beforeImage: model.beforeImage, isSplit: model.splitView,
                                isSelectionMode: model.isSelectionMode && !model.showOriginal, dimOutside: model.dimOutsideSelection,
                                selection: model.selection, hint: model.selectionHint, sourceScale: model.previewScale,
                                generation: model.imageGeneration, zoomCommand: zoom) { model.selection = $0 }
                } else if model.hasFrames && model.isFramesView {
                    FramesView(model: model)
                } else {
                    DropZone(targeted: dropTargeted)
                }
                if model.isFramePreview {
                    VStack {
                        FramePreviewBar(model: model)
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
            if model.showHistogram, let h = model.histogram {
                HistogramView(data: h)
                    .frame(height: 150)
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .padding([.horizontal, .bottom], 12)
            }
            StatusBar(model: model)
        }
    }
}

struct DropZone: View {
    var targeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(L.t("ui.drop.title")).font(.title2.weight(.semibold))
            Text(L.t("ui.drop.sub")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(36)
        }
    }
}

struct FramePreviewBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button(L.t("ui.frames.prev")) { Task { await model.previousFrame() } }
            Text(model.framePreviewTitle).font(.callout).lineLimit(1)
            Button(L.t("ui.frames.next")) { Task { await model.nextFrame() } }
            Divider().frame(height: 16)
            Button(L.t("ui.frames.backToList")) { model.exitFramePreview() }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

struct StatusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(model.isError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer()
            if model.isBusy {
                ProgressView(value: model.progress).frame(width: 160)
                Button(L.t("ui.status.cancel")) { model.cancelRunning() }
                    .buttonStyle(.borderless)
            }
            Text(model.imageInfo).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }
}

/// The steps grouped like the Windows sidebar, with the progress on top.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selectedStep?.id }, set: { id in if let id { model.select(id) } })) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L.t("ui.sidebar.title")).font(.headline)
                        Spacer()
                        Text("\(model.doneCount) / \(model.totalSteps) \(L.t("ui.sidebar.progress"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: model.progressFraction)
                    if !model.encouragement.isEmpty {
                        Text(model.encouragement).font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(model.groups, id: \.group) { group in
                Section(group.name) {
                    ForEach(group.steps) { step in
                        StepRow(step: step).tag(step.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct StepRow: View {
    let step: StepModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stateIcon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(step.number). \(step.name)").lineLimit(1)
                if let meta = step.metaText {
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var stateIcon: some View {
        switch step.state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
        case .stale: Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

extension FocusedValues {
    @Entry var inspectorVisible: Binding<Bool>?
}
