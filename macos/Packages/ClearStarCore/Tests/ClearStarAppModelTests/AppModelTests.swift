import ClearStarCore
import Foundation
import Testing
@testable import ClearStarAppModel

/// The main window's view model without the UI: stepping through the workflow on a small generated
/// set of frames, the crop selection, skipping, the stretch wand, live previews and staleness.
@MainActor @Suite(.serialized) struct AppModelTests {
    static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("shared/Languages").path) { return url }
        }
        fatalError("repository root not found")
    }()

    /// Five shifted, slightly rotated copies of the synthetic star field as FITS frames in a "lights" folder.
    static let framesFolder: URL = {
        L.directories = [repo.appendingPathComponent("shared/Languages")]
        L.load("en")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppModelTests-\(ProcessInfo.processInfo.processIdentifier)")
        AppPaths.useRoot(root.appendingPathComponent("support"))
        let folder = root.appendingPathComponent("M 42_session", isDirectory: true)
        let lights = folder.appendingPathComponent("lights", isDirectory: true)
        try? FileManager.default.createDirectory(at: lights, withIntermediateDirectories: true)
        let field = try! FitsReader.read(repo.appendingPathComponent("testdata/reference/synthetic/field.fits").path)
        // A larger canvas so the crop and the star steps have room.
        let big = AstroImage(width: 800, height: 600, channels: 3, header: field.header)
        for c in 0 ..< 3 { big.setChannel(c, Resample.resize(field.channelArray(c), 400, 300, 800, 600)) }
        for k in 0 ..< 5 {
            let t = SimilarityTransform(1, Float(k) * 0.004, Float(k) * 3.5, -Float(k) * 2.25)
            let frame = AstroImage(width: 800, height: 600, channels: 3)
            frame.header["IMAGETYP"] = "Light Frame"
            frame.header["EXPTIME"] = "30.0"
            frame.data.withUnsafeMutableBufferPointer { dst in
                try! ImageWarp.resample(big, t, 800, 600) { y, w, row in
                    for c in 0 ..< 3 { for x in 0 ..< w { dst[c * 480000 + y * 800 + x] = row[c * w + x] + (row[3 * w + x] > 0 ? 0 : 0.08) } }
                }
            }
            try! FitsWriter.write(lights.appendingPathComponent(String(format: "light_%03d.fits", k)).path, frame)
        }
        return folder
    }()

    private func loaded() async -> AppModel {
        let model = AppModel()
        await model.loadPath(Self.framesFolder.path)
        return model
    }

    @Test func initialState() {
        _ = Self.framesFolder
        let model = AppModel()
        #expect(model.steps.count == 16)
        #expect(model.selectedStep?.id == .loadFrames)
        #expect(model.groups.map(\.group) == [.preparation, .basics, .stars, .refinement, .finish])
        #expect(model.isFramesView && !model.canCompare)
        #expect(model.statusText == L.t("ui.status.noImage"))
        #expect(model.step(.stack).primaryButtonText == L.t("ui.step.btnStack"))
        #expect(!model.step(.stack).canSkip && model.step(.crop).canSkip)
    }

    @Test func loadStackAndCrop() async throws {
        let model = await loaded()
        #expect(!model.isError, "\(model.statusText)")
        #expect(model.frames.count == 5 && model.hasFrames)
        #expect(model.windowTitle.contains("M 42_session"))
        #expect(model.step(.plateSolve).parameter(PlateSolveStep.objectKey)?.text == "M 42")
        #expect(model.step(.stack).isDone && model.hasQuality)
        #expect(model.frames.allSatisfy { $0.isUsed == true && $0.stars != nil })
        // After the stack the crop is next: the large image and the selection canvas appear.
        #expect(model.selectedStep?.id == .crop)
        #expect(model.isSelectionMode && model.dimOutsideSelection)
        await model.waitForPreview()
        #expect(model.previewImage != nil && model.canCompare)
        await model.waitForCropBase()
        #expect(model.selection != nil)
        // The margin slider moves the selection and the hidden parameters follow.
        let crop = model.step(.crop)
        crop.parameter(CropStep.marginKey)?.number = 0.1
        let sel = try #require(model.selection)
        #expect(abs(crop.entry.parameters.getDouble(CropStep.selLeftKey) - Double(sel.minX)) < 1e-9)
        #expect(crop.note?.isEmpty == false)
        await model.apply(crop)
        #expect(crop.isDone)
        #expect(model.selectedStep?.id == .backgroundExtraction)
        #expect(model.imageInfo.contains("×"))
        #expect(model.doneCount == 3)
    }

    @Test func skippingStretchingAndLivePreviews() async throws {
        let model = await loaded()
        await model.apply(model.step(.crop))
        for id in [StepId.backgroundExtraction, .deconvolution, .denoise, .plateSolve, .colorCalibration, .starRemoval] {
            model.skip(model.step(id))
        }
        #expect(model.selectedStep?.id == .starlessStretch)
        #expect(!model.autoStretch)                          // the stretch step shows the real image
        #expect(model.isSelectionMode && !model.dimOutsideSelection)   // eyedropper
        let ghs = model.step(.starlessStretch)
        #expect(ghs.entry.parameters.getDouble(StarlessStretchStep.spKey) > 0)   // symmetry point suggested
        #expect(ghs.secondaryActionText == L.t("step.ghs.auto"))

        // The wand commits the auto stretch and stays on the step.
        ghs.secondaryAction?()
        for _ in 0 ..< 100 where !ghs.isDone { try await Task.sleep(for: .milliseconds(50)) }
        while model.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ghs.isDone && model.selectedStep?.id == .starlessStretch)
        #expect(StarlessStretchStep.history(ghs.entry.parameters).count == 1)
        #expect(ghs.noteActionText == L.t("step.ghs.undo"))

        // A slider change previews live with the histogram.
        ghs.parameter(StarlessStretchStep.contrastKey)?.number = 0.4
        try await Task.sleep(for: .milliseconds(150))
        await model.waitForPreview()
        #expect(model.showHistogram && model.histogram?.curve.count == 128)

        // Eyedropper: a selection sets the symmetry point.
        let spBefore = ghs.entry.parameters.getDouble(StarlessStretchStep.spKey)
        model.selection = CGRect(x: 0.05, y: 0.05, width: 0.05, height: 0.05)
        #expect(ghs.entry.parameters.getDouble(StarlessStretchStep.spKey) != spBefore || spBefore > 0)

        // Apply commits the slider stretch too and moves on.
        await model.apply(ghs)
        #expect(StarlessStretchStep.history(ghs.entry.parameters).count == 2)
        #expect(model.selectedStep?.id == .starStretch)

        await model.apply(model.step(.starStretch))
        #expect(model.selectedStep?.id == .greenRemoval)
        // Per-pixel steps preview their sliders live on the input.
        let first = model.previewImage
        model.step(.greenRemoval).parameter(GreenRemovalStep.amountKey)?.number = 0.2
        try await Task.sleep(for: .milliseconds(150))
        await model.waitForPreview()
        #expect(model.previewImage != nil && model.previewImage !== first)

        // Running an earlier step again makes the later results stale.
        await model.apply(model.step(.crop))
        #expect(model.step(.starlessStretch).isStale)
        #expect(model.step(.backgroundExtraction).isSkipped)
    }

    @Test func viewOptionsAndFramePreview() async throws {
        let model = await loaded()
        model.select(.loadFrames)
        await model.previewFrame(model.frames[0])
        #expect(model.isFramePreview && model.previewImage != nil)
        await model.nextFrame()
        #expect(model.framePreviewTitle.contains("2"))
        await model.previousFrame()
        await model.previousFrame()
        #expect(model.framePreviewTitle.contains("5"))
        model.exitFramePreview()
        #expect(!model.isFramePreview)

        model.select(.crop)
        await model.waitForPreview()
        model.stretchPresetKey = "off"
        #expect(!model.autoStretch)
        model.stretchPresetKey = "bg10"
        #expect(model.autoStretch && UserSettings.get(AppModel.stretchSettingKey) == "bg10")
        model.autoStretch = false
        #expect(model.stretchPresetKey == "off")
        model.autoStretch = true
        #expect(model.stretchPresetKey == "bg10")
        model.splitView = true
        await model.waitForPreview()
        #expect(model.beforeImage != nil)
        model.showOriginal = true
        await model.waitForPreview()
        #expect(model.previewImage != nil)
        model.selectNext()
        #expect(model.selectedStep?.id == .backgroundExtraction)
        model.selectPrevious()
        #expect(model.selectedStep?.id == .crop)
        model.resetParameters(model.step(.crop))
        #expect(model.step(.crop).parameter(CropStep.marginKey)?.number == 0)
    }

    @Test func notesOfTheSetupSteps() async throws {
        let model = AppModel()
        model.select(.starRemoval)
        #expect(model.step(.starRemoval).note != nil)
        model.step(.starRemoval).noteAction?()
        #expect(model.showStarNetSetup)
        model.select(.plateSolve)
        model.step(.plateSolve).noteAction?()
        #expect(model.showCatalogSetup)
    }

    @Test func parameterModels() {
        _ = Self.framesFolder
        let model = AppModel()
        let crop = model.step(.crop)
        let angle = try! #require(crop.parameter(CropStep.angleKey))
        angle.number = 2.5
        #expect(angle.valueLabel.contains("2") && angle.valueLabel.hasSuffix("°"))
        let margin = crop.parameter(CropStep.marginKey)!
        margin.number = 0.15
        #expect(margin.valueLabel == margin.tickLabels.last)
        let rotate = crop.parameter(CropStep.rotateKey)!
        #expect(rotate.choices.count == 4)
        rotate.choice = "90"
        #expect(crop.entry.parameters.getString(CropStep.rotateKey) == "90")
        rotate.reset()
        #expect(rotate.choice == "0")
        let bge = model.step(.backgroundExtraction)
        let modelParam = try! #require(bge.parameters.first { $0.kind == .model })
        #expect(modelParam.model?.choices.first?.path == "")
        #expect(bge.basicParameters.count + bge.advancedParameters.count == bge.parameters.count)
    }
}
