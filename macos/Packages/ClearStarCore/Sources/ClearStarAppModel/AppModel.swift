import ClearStarCore
import CoreGraphics
import Foundation
import Observation

/// The main window's state – the counterpart of the Windows MainViewModel: the workflow, the step
/// cards, the preview (with the live previews of the stretch, star and per-pixel steps), the crop and
/// eyedropper selections, the frame list with its quality charts, and the status line.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored public let workflow: Workflow
    public let steps: [StepModel]
    public private(set) var selectedStep: StepModel?

    // Preview
    public private(set) var previewImage: CGImage?
    public private(set) var beforeImage: CGImage?
    /// The preview may be downsampled; multiplied by this the real pixel size results.
    public private(set) var previewScale = 1.0
    public private(set) var histogram: HistogramData?
    public private(set) var showHistogram = false
    /// Bumped whenever a new image (not just a new rendering of the same one) is shown – the viewer fits it.
    public private(set) var imageGeneration = 0

    // Status
    public private(set) var statusText = L.t("ui.status.noImage")
    public private(set) var isError = false
    public private(set) var isBusy = false
    public private(set) var progress = 0.0
    public private(set) var imageInfo = ""
    public private(set) var doneCount = 0
    public private(set) var encouragement = ""
    public private(set) var windowTitle = L.t("ui.app.title")
    public private(set) var hasImage = false

    // View options
    public var showOriginal = false { didSet { if showOriginal != oldValue { refreshPreview() } } }
    public var splitView = false { didSet { if splitView != oldValue { refreshPreview() } } }
    public var autoStretch = true { didSet { if autoStretch != oldValue { onAutoStretchChanged() } } }
    public var showWelcome = true
    public var showStarNetSetup = false
    public var showCatalogSetup = false

    // Screen-stretch presets (toolbar toggle + menu), kept in the settings.
    public static let stretchSettingKey = "preview.stretch"
    public var stretchPresetKey: String { didSet { if stretchPresetKey != oldValue { onStretchPresetChanged() } } }
    @ObservationIgnored private var lastStretchKey = DisplayStretch.defaultPresetKey
    public var stretchPresets: [(key: String, label: String)] { DisplayStretch.presets.map { ($0.key, L.t("ui.stretch." + $0.key)) } }
    var preset: DisplayStretch.Preset { DisplayStretch.presetByKey(lastStretchKey) }

    // Selection (crop rectangle / eyedropper), as fractions 0..1 of the (oriented) preview.
    public var selection: CGRect? { didSet { if selection != oldValue { onSelectionChanged() } } }
    public private(set) var isSelectionMode = false
    public private(set) var dimOutsideSelection = true
    public private(set) var selectionHint: String?

    // Frames view (steps 1–2)
    public private(set) var frames: [FrameItem] = []
    public private(set) var hasFrames = false
    public private(set) var hasQuality = false
    public private(set) var qualityVersion = 0
    public private(set) var isStackView = false
    public private(set) var isFramesView = false
    public private(set) var framesTitle = L.t("ui.frames.loadedTitle")
    public private(set) var framesSubtitle = ""
    public private(set) var stackThumbnail: CGImage?
    public private(set) var isFramePreview = false
    public private(set) var framePreviewTitle = ""
    @ObservationIgnored private var previewedFrame: FrameItem?

    @ObservationIgnored private var cancel: CancellationToken?
    @ObservationIgnored private var previewCancel = CancellationToken()
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailSource: AstroImage?
    @ObservationIgnored private var lastShownSize: (Int, Int) = (0, 0)
    @ObservationIgnored private var starsSmall: (source: AstroImage, factor: Int, small: AstroImage)?
    // The crop's starting rectangle: the covered part of the stack (or the whole image).
    @ObservationIgnored private var cropBase = CGRect(x: 0, y: 0, width: 1, height: 1)
    @ObservationIgnored private var cropBaseImage: AstroImage?
    @ObservationIgnored private var cropBaseOrientation: (Double, Bool, Bool) = (0, false, false)

    public var totalSteps: Int { steps.count }
    public var progressFraction: Double { totalSteps == 0 ? 0 : Double(doneCount) / Double(totalSteps) }
    public var canCompare: Bool { hasImage && !isFramesView }
    public var showQuality: Bool { hasQuality && isStackView }

    public init(workflow: Workflow = StepCatalog.createWorkflow()) {
        self.workflow = workflow
        steps = workflow.steps.map(StepModel.init)
        let key = DisplayStretch.presetByKey(UserSettings.get(Self.stretchSettingKey)).key
        stretchPresetKey = key
        lastStretchKey = key
        workflow.changed = { [weak self] in
            // The workflow reports from the thread that ran the step; the UI state lives on the main actor.
            if Thread.isMainThread { MainActor.assumeIsolated { self?.onWorkflowChanged() } }
            else { Task { @MainActor in self?.onWorkflowChanged() } }
        }
        wireLiveUpdates()
        select(steps[0])
    }

    public func step(_ id: StepId) -> StepModel { steps.first { $0.id == id }! }

    /// Groups for the sidebar (in step order).
    public var groups: [(group: StepGroup, name: String, steps: [StepModel])] {
        var result: [(StepGroup, String, [StepModel])] = []
        for s in steps {
            if let last = result.last, last.0 == s.definition.group { result[result.count - 1].2.append(s) }
            else { result.append((s.definition.group, StepDefinition.groupName(s.definition.group), [s])) }
        }
        return result
    }

    private func wireLiveUpdates() {
        // The crop slider moves the selection live (a margin on every side of the covered rectangle).
        let crop = step(.crop)
        crop.parameter(CropStep.marginKey)?.onChange = { [weak self] in
            guard let self, self.selectedStep?.id == .crop, let m = crop.parameter(CropStep.marginKey)?.number else { return }
            let b = self.cropBase
            self.selection = CGRect(x: b.minX + m * b.width, y: b.minY + m * b.height, width: b.width * (1 - 2 * m), height: b.height * (1 - 2 * m))
        }
        // Crop orientation (quarter turns, fine angle, mirroring) is previewed live.
        for key in [CropStep.rotateKey, CropStep.angleKey, CropStep.flipHKey, CropStep.flipVKey] {
            crop.parameter(key)?.onChange = { [weak self] in self?.onCropOrientationChanged(crop) }
        }
        // The stretch sliders, the star step and the per-pixel steps are previewed live (debounced).
        for s in steps where s.id == .starlessStretch || s.id == .starStretch || s.entry.step is LivePreviewStep {
            for p in s.parameters where !p.isHidden { p.onChange = { [weak self] in self?.scheduleLivePreview() } }
        }
    }

    // MARK: - Workflow state

    private func onWorkflowChanged() {
        for s in steps { s.refresh() }
        doneCount = workflow.doneCount
        hasImage = workflow.hasImage
        let remaining = totalSteps - doneCount
        encouragement = doneCount == 0 ? "" : remaining == 0 ? L.t("ui.status.allDone") : remaining == 1 ? L.t("ui.status.lastStep")
            : remaining <= 5 ? L.f("ui.status.fewLeft", remaining) : L.f("ui.status.progress", doneCount)
    }

    public func select(_ step: StepModel) {
        isFramePreview = false
        previewedFrame = nil
        selectedStep = step
        // The linear phase is boosted on screen automatically; after the stretch the real image shows.
        autoStretchInternal(step.id == .starlessStretch ? false : step.isDone ? Workflow.isLinearPhase(step.id) : step.id.rawValue < StepId.starlessStretch.rawValue)
        if step.id == .starlessStretch { suggestSymmetryPoint(step); updateStretchNote(step) }
        // Crop: the image is the selection's canvas – the input (not yet cropped) is shown with the selection.
        isSelectionMode = step.id == .crop || step.id == .starlessStretch
        dimOutsideSelection = step.id == .crop
        selectionHint = L.t(step.id == .starlessStretch ? "mac.viewer.eyedropperHint" : "mac.viewer.selectionHint")
        if step.id == .crop { loadCropSelection(step) } else { selection = nil }
        if step.id == .starRemoval { updateStarNetNote(step) }
        if step.id == .plateSolve { updateCatalogNote(step) }
        updateFramesView(step)
        refreshPreview()
    }

    public func select(_ id: StepId) { select(step(id)) }

    public func selectNext() {
        guard let s = selectedStep, let i = steps.firstIndex(where: { $0 === s }), i + 1 < steps.count else { return }
        select(steps[i + 1])
    }

    public func selectPrevious() {
        guard let s = selectedStep, let i = steps.firstIndex(where: { $0 === s }), i > 0 else { return }
        select(steps[i - 1])
    }

    /// Sets the boost without the side effects of the user toggling it (select() refreshes anyway).
    private func autoStretchInternal(_ value: Bool) {
        if autoStretch == value { return }
        suppressAutoStretch = true
        autoStretch = value
        suppressAutoStretch = false
        syncPresetWithAutoStretch()
    }
    @ObservationIgnored private var suppressAutoStretch = false

    private func onAutoStretchChanged() {
        syncPresetWithAutoStretch()
        if !suppressAutoStretch { refreshPreview() }
    }

    /// Keeps the menu in sync: off ↔ the last chosen strength.
    private func syncPresetWithAutoStretch() {
        let wanted = autoStretch ? lastStretchKey : "off"
        if stretchPresetKey != wanted {
            suppressPreset = true
            stretchPresetKey = wanted
            suppressPreset = false
        }
    }
    @ObservationIgnored private var suppressPreset = false

    private func onStretchPresetChanged() {
        if suppressPreset { return }
        if stretchPresetKey == "off" { autoStretch = false; return }
        lastStretchKey = stretchPresetKey
        UserSettings.set(Self.stretchSettingKey, stretchPresetKey)
        if !autoStretch { autoStretch = true } else { refreshPreview() }
    }

    // MARK: - Running steps

    /// Runs the step; afterwards the next pending step is selected (unless `stay`).
    public func apply(_ step: StepModel, stay: Bool = false) async {
        if isBusy { return }
        // The stretch step commits the slider settings into its history and starts the next one clean.
        if step.id == .starlessStretch {
            StarlessStretchStep.commit(step.entry.parameters)
            for p in step.parameters { p.reload() }
        }
        let token = CancellationToken()
        cancel = token
        isBusy = true
        isError = false
        progress = 0
        statusText = L.f("ui.status.running", step.name)
        let reporter = ProgressThrottle { [weak self] f, m in
            guard let self, self.isBusy else { return }
            self.progress = f
            self.statusText = m
        }
        defer {
            isBusy = false
            progress = 0
            cancel = nil
        }
        do {
            let result = try await workflow.run(step.id, progress: { p in reporter.report(p.fraction, p.message) }, cancellation: token)
            reporter.stop()
            onWorkflowChanged()
            if let f = result.frames { loadFrames(f) }
            if let notes = result.frameNotes {
                for item in frames {
                    guard let note = notes[item.info.path] else { continue }
                    item.status = note.text; item.isUsed = note.used
                    item.stars = note.stars; item.starSize = note.starSize; item.background = note.background; item.angle = note.angle
                }
                hasQuality = frames.contains { $0.stars != nil }
                qualityVersion += 1
                if let s = selectedStep { updateFramesView(s) }
            }
            showWelcome = false
            statusText = L.f("ui.status.done", step.name, result.summary)
            updateImageInfo()
            if step.id == .starlessStretch { followBackground(step); updateStretchNote(step) }
            let next = steps.first { $0.id == workflow.nextPending }
            if !stay, let next, next.id.rawValue > step.id.rawValue { select(next) } else { refreshPreview() }
        } catch is CancellationError {
            reporter.stop()
            statusText = L.t("ui.status.cancelled")
        } catch {
            reporter.stop()
            isError = true
            statusText = error.localizedDescription
        }
    }

    public func applySelected() async {
        if let s = selectedStep { await apply(s) }
    }

    public func skip(_ step: StepModel) {
        do {
            try workflow.skip(step.id)
            onWorkflowChanged()
            if let next = steps.first(where: { $0.id == workflow.nextPending }) { select(next) }
        } catch {
            isError = true
            statusText = error.localizedDescription
        }
    }

    public func resetParameters(_ step: StepModel) {
        for p in step.parameters { p.reset() }
        if step.id == .crop { selection = cropBase }
        scheduleLivePreview()
    }

    public func cancelRunning() { cancel?.cancel() }

    /// Load and stack in one go (drag and drop, Open…, a path given at start).
    public func loadPath(_ path: String) async {
        let load = step(.loadFrames)
        load.parameter(LoadFramesStep.folderKey)?.text = path
        showWelcome = false
        select(load)
        await apply(load)
        if load.isDone { await apply(step(.stack)) }
    }

    public func closeWelcome() { showWelcome = false }

    public func goToCrop() { select(.crop) }

    // MARK: - Stretch step

    /// First visit: the symmetry point at the background level, where a nebula stretch usually starts.
    private func suggestSymmetryPoint(_ step: StepModel) {
        let p = step.entry.parameters
        if !StarlessStretchStep.history(p).isEmpty || p.getDouble(StarlessStretchStep.spKey) > 0 { return }
        guard let img = workflow.imageBefore(step.id) else { return }
        p.set(StarlessStretchStep.spKey, Double(averageMedian(img)).roundedTo(3))
        step.parameter(StarlessStretchStep.spKey)?.reload()
    }

    /// After a commit, undo or auto stretch the sliders refine the new image: the pivot moves to its background.
    private func followBackground(_ step: StepModel) {
        guard let stretched = workflow.imageAfter(step.id) else { return }
        step.entry.parameters.set(StarlessStretchStep.spKey, Double(averageMedian(stretched)).roundedTo(3))
        step.parameter(StarlessStretchStep.spKey)?.reload()
    }

    private func averageMedian(_ img: AstroImage) -> Float {
        let m = ImageStats.computeAll(img).map(\.median)
        return Float(m.reduce(0.0) { $0 + Double($1) } / Double(m.count))
    }

    private func updateStretchNote(_ step: StepModel) {
        let history = StarlessStretchStep.history(step.entry.parameters)
        step.note = history.isEmpty ? L.t("step.ghs.none") : L.f("step.ghs.applied", history.count, history[history.count - 1].describe())
        step.noteActionText = history.isEmpty ? nil : L.t("step.ghs.undo")
        step.noteAction = { [weak self] in
            guard let self, StarlessStretchStep.undo(step.entry.parameters) else { return }
            Task { await self.apply(step, stay: true) }   // undo: keep refining here
        }
        step.secondaryActionText = L.t("step.ghs.auto")
        step.secondaryAction = { [weak self] in
            guard let self else { return }
            guard let base = step.isDone ? self.workflow.imageAfter(step.id) : self.workflow.imageBefore(step.id) else { return }
            let preset = self.preset.isOff ? DisplayStretch.presetByKey(DisplayStretch.defaultPresetKey) : self.preset
            if !StarlessStretchStep.commitAuto(step.entry.parameters, base, preset: preset) { self.statusText = L.t("step.ghs.autoBright"); return }
            Task { await self.apply(step, stay: true) }   // the wand is the starting point for the sliders
        }
    }

    nonisolated private static func buildHistogram(_ input: AstroImage, _ output: AstroImage, _ stretches: [GhsParams], _ p: GhsParams) -> HistogramData {
        let transforms = stretches.map(GhsTransform.init)
        var curve = [Float](repeating: 0, count: 128)
        for i in 0 ..< curve.count {
            var v = Float(i) / Float(curve.count - 1)
            for t in transforms { v = t.apply(v) }
            curve[i] = v
        }
        return HistogramData(input: Histogram.compute(input, stride: 2), output: Histogram.compute(output, stride: 2), curve: curve,
                             lp: p.lp, sp: p.sp, hp: p.hp, bp: p.type == .linear ? p.bp : 0, showMarkers: true)
    }

    // MARK: - Crop

    private func onCropOrientationChanged(_ crop: StepModel) {
        guard selectedStep?.id == .crop else { return }
        cropBaseImage = nil                 // the covered rectangle is recomputed for the new orientation
        let keep = selection                // the frame stays where the user put it; the image moves underneath
        loadCropSelection(crop)
        if let keep { selection = keep }
        refreshPreview()
    }

    private func loadCropSelection(_ step: StepModel) {
        if step.noteAction == nil { step.noteAction = { [weak self] in self?.selection = self?.cropBase } }
        let img = workflow.imageBefore(.crop)
        let p = step.entry.parameters
        if CropStep.hasSelection(p) {
            selection = CGRect(x: p.getDouble(CropStep.selLeftKey), y: p.getDouble(CropStep.selTopKey),
                               width: p.getDouble(CropStep.selWidthKey), height: p.getDouble(CropStep.selHeightKey))
            if img === cropBaseImage { updateCropNote(step); return }
        }
        guard let img else { selection = nil; updateCropNote(step); return }
        if img === cropBaseImage { if selection == nil { selection = cropBase }; updateCropNote(step); return }

        // The covered rectangle on a small oriented copy (fast, and it matches the preview).
        cropBaseImage = img
        let o = CropStep.orientation(p)
        cropBaseOrientation = (o.angle, o.flipH, o.flipV)
        step.note = L.t("ui.crop.computing")
        Task { [weak self] in
            let rect = await Task.detached(priority: .userInitiated) { () -> CGRect in
                let small = img.downsample(4)
                let oriented = CropStep.orient(small, o.angle, o.flipH, o.flipV)
                guard let r = Coverage.largestFilledRectangle(oriented, downsample: 1) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
                return CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            }.value
            guard let self, img === self.cropBaseImage, self.cropBaseOrientation == (o.angle, o.flipH, o.flipV) else { return }
            self.cropBase = rect
            if self.selectedStep?.id == .crop && self.selection == nil { self.selection = rect }
            if self.selectedStep?.id == .crop { self.updateCropNote(step) }
        }
    }

    /// Waits until the covered rectangle of the crop step is known (tests).
    public func waitForCropBase() async {
        for _ in 0 ..< 200 where step(.crop).note == L.t("ui.crop.computing") { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func updateCropNote(_ step: StepModel) {
        guard let sel = selection, let img = workflow.imageBefore(.crop) else {
            step.note = L.t("ui.crop.noSelection")
            step.noteActionText = cropBase.width < 1 ? L.t("ui.crop.covered") : nil
            return
        }
        let isBase = abs(sel.minX - cropBase.minX) < 1e-6 && abs(sel.minY - cropBase.minY) < 1e-6
            && abs(sel.width - cropBase.width) < 1e-6 && abs(sel.height - cropBase.height) < 1e-6
        let (ow, oh) = CropStep.orientedSize(img.width, img.height, CropStep.orientation(step.entry.parameters).angle)
        step.note = L.f("ui.crop.selection", (sel.width * Double(ow)).rounded(), (sel.height * Double(oh)).rounded())
            + (isBase && cropBase.width < 1 ? L.t("ui.crop.noCorners") : "")
        step.noteActionText = L.t(isBase ? "ui.crop.clear" : "ui.crop.covered")
        step.noteAction = isBase ? { [weak self] in self?.selection = nil } : { [weak self] in self?.selection = self?.cropBase }
    }

    private func onSelectionChanged() {
        if let ghs = selectedStep, ghs.id == .starlessStretch, let value = selection, value.width > 0.002, value.height > 0.002 {
            guard let base = ghs.isDone ? workflow.imageAfter(ghs.id) : workflow.imageBefore(ghs.id) else { return }
            let sp = StarlessStretchStep.regionMedian(base, value.minX, value.minY, value.width, value.height)
            ghs.entry.parameters.set(StarlessStretchStep.spKey, Double(sp).roundedTo(3))
            ghs.parameter(StarlessStretchStep.spKey)?.reload()
            scheduleLivePreview()
            return
        }
        guard let step = selectedStep, step.id == .crop else { return }
        let p = step.entry.parameters
        let v = selection
        p.set(CropStep.selLeftKey, Double(v?.minX ?? 0))
        p.set(CropStep.selTopKey, Double(v?.minY ?? 0))
        p.set(CropStep.selWidthKey, Double(v?.width ?? 0))
        p.set(CropStep.selHeightKey, Double(v?.height ?? 0))
        updateCropNote(step)
    }

    // MARK: - Notes of the StarNet and catalogue steps

    public func updateStarNetNote(_ step: StepModel) {
        let exe = StarNet.locate()
        step.note = exe.map { L.f("step.starremoval.found", (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/" + ($0 as NSString).lastPathComponent) }
            ?? L.t("step.starremoval.missing")
        step.noteActionText = L.t(exe == nil ? "step.starremoval.setup" : "step.starremoval.change")
        step.noteAction = { [weak self] in self?.showStarNetSetup = true }
    }

    public func updateCatalogNote(_ step: StepModel) {
        let file = LocalGaiaCatalog.locate()
        step.note = file.map { L.f("step.platesolve.offline", ($0 as NSString).lastPathComponent) } ?? L.t("step.platesolve.online")
        step.noteActionText = L.t(file == nil ? "step.platesolve.setup" : "step.platesolve.change")
        step.noteAction = { [weak self] in self?.showCatalogSetup = true }
    }

    /// After the setup sheets closed.
    public func refreshNotes() {
        updateStarNetNote(step(.starRemoval))
        updateCatalogNote(step(.plateSolve))
    }

    // MARK: - Frames

    private func updateFramesView(_ step: StepModel) {
        isStackView = step.id == .stack
        isFramesView = step.id == .loadFrames || step.id == .stack
        framesTitle = L.t(isStackView ? "ui.frames.stackTitle" : "ui.frames.loadedTitle")
        framesSubtitle = isStackView ? L.t(hasQuality ? "ui.frames.stackedSub" : "ui.frames.stackSub") : L.t("ui.frames.loadedSub")
    }

    private func loadFrames(_ set: FrameSet) {
        frames = set.frames.map(FrameItem.init)
        hasQuality = false
        qualityVersion += 1
        hasFrames = !frames.isEmpty
        windowTitle = L.f("ui.app.titleWithFolder", (set.folder as NSString).lastPathComponent)
        prefillObjectName(set)
    }

    /// Plate solving: the object name from the header (or the folder name), so the user sees what will be looked up.
    private func prefillObjectName(_ set: FrameSet) {
        guard let param = step(.plateSolve).parameter(PlateSolveStep.objectKey), let name = ObjectNameGuess.from(set) else { return }
        param.text = name
    }

    public func previewFrame(_ frame: FrameItem) async {
        previewedFrame = frame
        isFramePreview = true
        let index = frames.firstIndex { $0 === frame } ?? 0
        framePreviewTitle = L.f("ui.frames.previewTitle", frame.fileName, index + 1, frames.count)
        isError = false
        statusText = L.f("ui.frames.previewLoading", frame.fileName)
        let preset = self.preset
        do {
            let path = frame.info.path
            let rendered = try await Task.detached(priority: .userInitiated) {
                try PreviewRenderer.render(try ImageFiles.load(path), autoStretch: true, preset: preset)
            }.value
            guard previewedFrame === frame, isFramePreview else { return }
            show(rendered, before: nil)
            statusText = L.f("ui.frames.previewInfo", frame.fileName, rendered.sourceWidth, rendered.sourceHeight) + (frame.status.map { " · \($0)" } ?? "")
        } catch {
            isError = true
            statusText = L.f("ui.frames.openFailed", error.localizedDescription)
        }
    }

    public func exitFramePreview() {
        isFramePreview = false
        previewedFrame = nil
        refreshPreview()
    }

    public func nextFrame() async { await stepFrame(1) }
    public func previousFrame() async { await stepFrame(-1) }

    private func stepFrame(_ delta: Int) async {
        guard let current = previewedFrame, !frames.isEmpty, let i = frames.firstIndex(where: { $0 === current }) else { return }
        await previewFrame(frames[(i + delta + frames.count) % frames.count])
    }

    private func refreshStackThumbnail(_ ct: CancellationToken) {
        guard isStackView, let stack = workflow.imageAfter(.stack) else { stackThumbnail = nil; return }
        if stack === thumbnailSource && stackThumbnail != nil { return }
        thumbnailSource = stack
        let preset = self.preset
        Task { [weak self] in
            let frame = try? await Task.detached(priority: .userInitiated) {
                try PreviewRenderer.render(stack, autoStretch: true, preset: preset, maxWidth: 900, ct)
            }.value
            guard let self, let frame, !ct.isCancelled else { return }
            self.stackThumbnail = frame.image
        }
    }

    private func updateImageInfo() {
        guard let img = workflow.current else { imageInfo = ""; return }
        imageInfo = L.f("ui.status.imageInfo", img.width, img.height, L.t(img.isColor ? "ui.status.color" : "ui.status.mono"))
    }

    // MARK: - Preview

    /// Re-renders the live preview shortly after the last slider change.
    private func scheduleLivePreview() {
        guard let sel = selectedStep, sel.id == .starlessStretch || sel.id == .starStretch || sel.entry.step is LivePreviewStep else { return }
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            self?.refreshPreview()
        }
    }

    private func smallStars(_ stars: AstroImage, _ factor: Int) -> AstroImage {
        if let c = starsSmall, c.source === stars, c.factor == factor { return c.small }
        let small = factor > 1 ? stars.downsample(factor) : stars
        starsSmall = (stars, factor, small)
        return small
    }

    /// Renders the preview in the background; an older rendering is cancelled.
    public func refreshPreview() {
        if isFramePreview, let f = previewedFrame { Task { await previewFrame(f) }; return }
        previewCancel.cancel()
        let ct = CancellationToken()
        previewCancel = ct
        guard let step = selectedStep else { return }

        // Steps 1–2 show the frame list (folder contents, then the stack and its statistics); the large
        // image first appears at the crop.
        if step.id == .loadFrames || step.id == .stack {
            previewImage = nil
            beforeImage = nil
            showHistogram = false
            refreshStackThumbnail(ct)
            return
        }
        var after: AstroImage? = showOriginal ? workflow.original
            : step.id == .crop ? workflow.imageBefore(step.id)
            : step.isDone ? workflow.imageAfter(step.id) : workflow.imageBefore(step.id)
        // Split view: a finished step compares its own input and output; a step not run yet compares the
        // previous finished step's input with the current image (so right after Apply the change shows).
        var before: AstroImage?
        if splitView && !showOriginal {
            before = step.isDone || step.id == .crop ? workflow.imageBefore(step.id)
                : workflow.lastImageStepBefore(step.id).flatMap { workflow.imageBefore($0) }
        }
        guard let afterImage = after else {
            previewImage = nil
            beforeImage = nil
            showHistogram = false
            return
        }
        after = afterImage
        let stretch = autoStretch
        let preset = self.preset
        // The stretch step previews the slider settings live on top of its committed result.
        let liveStretch = step.id == .starlessStretch && !showOriginal
        let current = liveStretch ? StarlessStretchStep.currentAll(step.entry.parameters) : []
        let ghsMarkers = StarlessStretchStep.current(step.entry.parameters)
        var transform: (@Sendable (AstroImage) throws -> AstroImage)?
        if !current.isEmpty { transform = { try GhsTransform.applyAll($0, current, ct) } }
        // Star step: the full-strength star layer added to the starless base with the slider's strength.
        if step.id == .starStretch, !showOriginal, let starsFull = StarLayerStore.starsStretched,
           let starlessBase = workflow.imageBefore(step.id), StarLayerStore.hasStretched(for: starlessBase) {
            after = starlessBase
            let amount = step.entry.parameters.getFloat(StarStretchStep.amountKey, StarStretchStep.defaultAmount)
            // The preview's downsampling factor (the star layer has the size of the starless image).
            let factor = max(1, Int((Double(starsFull.width) / Double(starlessBase.width / starlessBase.downsampleFactor(PreviewRenderer.maxPreviewWidth))).rounded()))
            let small = smallStars(starsFull, factor)
            transform = { try StarStretchStep.addStars($0, small, amount, ct) }
        } else if let live = step.entry.step as? LivePreviewStep, !showOriginal, let liveBase = workflow.imageBefore(step.id) {
            // Per-pixel steps: the sliders previewed live on the step's input.
            after = liveBase
            let prms = step.entry.parameters.clone()
            transform = { try live.preview($0, prms, ct) }
        }
        // Crop: rotation and mirroring previewed exactly as the step will apply them.
        if step.id == .crop && !showOriginal {
            let o = CropStep.orientation(step.entry.parameters)
            if abs(o.angle) > 1e-9 || o.flipH || o.flipV { transform = { CropStep.orient($0, o.angle, o.flipH, o.flipV) } }
        }
        let renderAfter = after!, renderBefore = before, renderTransform = transform
        let newImage = !(renderAfter === lastRendered)
        lastRendered = renderAfter
        previewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PreviewRenderer.Frame, PreviewRenderer.Frame?, HistogramData?)? in
                do {
                    var hist: HistogramData?
                    let a = try PreviewRenderer.render(renderAfter, autoStretch: stretch, preset: preset, ct, transform: renderTransform,
                                                       smallOut: liveStretch ? { src, dst in hist = Self.buildHistogram(src, dst, current, ghsMarkers) } : nil)
                    let b = try renderBefore.flatMap { $0 === renderAfter ? nil : try PreviewRenderer.render($0, autoStretch: stretch, preset: preset, ct) }
                    return (a, b, hist)
                } catch { return nil }
            }.value
            guard let self, !ct.isCancelled, let (a, b, hist) = result else { return }
            self.histogram = hist
            self.showHistogram = liveStretch
            self.show(a, before: b?.image ?? (self.splitView ? a.image : nil), newImage: newImage)
        }
    }
    @ObservationIgnored private weak var lastRendered: AstroImage?

    /// Waits for the preview rendering in flight (tests).
    public func waitForPreview() async {
        await previewTask?.value
    }

    private func show(_ frame: PreviewRenderer.Frame, before: CGImage?, newImage: Bool = true) {
        previewScale = Double(frame.sourceWidth) / Double(frame.width)
        previewImage = frame.image
        beforeImage = before
        if newImage || lastShownSize != (frame.width, frame.height) {
            lastShownSize = (frame.width, frame.height)
            imageGeneration += 1
        }
    }
}

extension Double {
    func roundedTo(_ digits: Int) -> Double {
        let f = pow(10.0, Double(digits))
        return (self * f).rounded(.toNearestOrEven) / f
    }
}

/// Throttles progress reports from the worker threads onto the main actor (at most ~20 per second).
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (Double, String)?
    private var scheduled = false
    private var stopped = false
    private let sink: @MainActor (Double, String) -> Void

    init(_ sink: @escaping @MainActor (Double, String) -> Void) { self.sink = sink }

    func report(_ fraction: Double, _ message: String) {
        lock.lock()
        pending = (fraction, message)
        let schedule = !scheduled && !stopped
        if schedule { scheduled = true }
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if let p = self.take() { self.sink(p.0, p.1) }
        }
    }

    private func take() -> (Double, String)? {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        return stopped ? nil : pending
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
}
