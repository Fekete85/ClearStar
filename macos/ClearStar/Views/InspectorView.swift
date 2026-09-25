import ClearStarAppModel
import ClearStarCore
import SwiftUI
import UniformTypeIdentifiers

/// The selected step's card: explanation, settings (built from the step's parameter definitions),
/// advanced settings, the step's note and actions, Apply / Skip / Reset.
struct InspectorView: View {
    @Bindable var model: AppModel
    @Bindable var step: StepModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !step.isImplemented {
                    Text(L.t("ui.step.notImplemented")).font(.callout).foregroundStyle(.orange)
                }
                ForEach(step.basicParameters) { ParameterView(model: model, parameter: $0) }
                if let note = step.note {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let action = step.noteActionText {
                            Button(action) { step.noteAction?() }.buttonStyle(.link)
                        }
                    }
                }
                if let secondary = step.secondaryActionText {
                    Button {
                        step.secondaryAction?()
                    } label: {
                        Text(secondary).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
                if step.hasAdvanced {
                    DisclosureGroup(L.t("ui.step.advanced"), isExpanded: $step.showAdvanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(step.advancedParameters) { ParameterView(model: model, parameter: $0) }
                        }
                        .padding(.top, 8)
                    }
                }
                actions
                if step.id.rawValue <= StepId.denoise.rawValue && step.parameters.contains(where: { $0.kind == .model }) {
                    Text(L.t("ui.model.license")).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(step.number). \(step.name)").font(.title2.weight(.semibold))
                if let tech = step.technicalName { Text(tech).font(.callout).foregroundStyle(.secondary) }
            }
            Text(step.descriptionText).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let meta = step.metaText {
                Label(meta, systemImage: step.isDone ? "checkmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(step.isStale ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                Task { await model.apply(step) }
            } label: {
                Text(step.primaryButtonText).frame(minWidth: 90)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isBusy)
            if step.canSkip {
                Button(L.t("ui.step.skip")) { model.skip(step) }
                    .controlSize(.large)
                    .disabled(model.isBusy)
            }
            Spacer()
            if step.hasParameters {
                Button(L.t("ui.step.reset")) { model.resetParameters(step) }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
            }
        }
        .padding(.top, 4)
    }
}

/// One setting: slider with tick labels, switch, choice, folder or image, text, AI model.
struct ParameterView: View {
    @Bindable var model: AppModel
    @Bindable var parameter: ParameterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch parameter.kind {
            case .slider: slider
            case .toggle: Toggle(parameter.label, isOn: $parameter.isOn).toggleStyle(.switch)
            case .choice: choice
            case .folder: folder
            case .text:
                Text(parameter.label).font(.callout)
                TextField(parameter.label, text: $parameter.text).textFieldStyle(.roundedBorder).labelsHidden()
            case .model:
                if let m = parameter.model { ModelPickerView(label: parameter.label, model: m) }
            case .hidden:
                EmptyView()
            }
            if let help = parameter.help {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var slider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.label).font(.callout)
                Spacer()
                Text(parameter.valueLabel).font(.callout.monospacedDigit()).foregroundStyle(Color.accentColor)
            }
            Slider(value: $parameter.number, in: parameter.minimum ... max(parameter.maximum, parameter.minimum + 1e-9))
            let ticks = parameter.tickLabels
            if ticks.contains(where: { !$0.isEmpty }) {
                HStack {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                        Text(t).font(.caption2).foregroundStyle(.tertiary)
                        if i < ticks.count - 1 { Spacer() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var choice: some View {
        let options = parameter.choices
        if options.count <= 3 && options.allSatisfy({ $0.label.count < 14 }) {
            Text(parameter.label).font(.callout)
            Picker(parameter.label, selection: $parameter.choice) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            Picker(parameter.label, selection: $parameter.choice) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(parameter.label).font(.callout)
            Text(parameter.text.isEmpty ? L.t("ui.step.noPath") : parameter.text)
                .font(.caption)
                .foregroundStyle(parameter.text.isEmpty ? .tertiary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Button(L.t("ui.step.chooseFolder")) {
                    if let url = Panels.chooseFolder(title: parameter.label, start: parameter.text) { parameter.text = url.path }
                }
                if model.selectedStep?.id == .loadFrames {
                    Button(L.t("ui.step.singleImage")) {
                        if let url = Panels.chooseFile(title: L.t("ui.step.pickImage"), types: Panels.imageTypes) { parameter.text = url.path }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

/// The AI model picker: models on this Mac, download from the mirror or a URL, import.
struct ModelPickerView: View {
    let label: String
    @Bindable var model: ModelChoiceModel
    @State private var askUrl = false
    @State private var url = "https://"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: $model.selectedPath) {
                ForEach(model.choices, id: \.path) { Text($0.label).tag($0.path) }
            }
            Text(model.statusText).font(.caption).foregroundStyle(model.isMissing ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isDownloading { ProgressView(value: model.downloadProgress) }
            HStack {
                Button(L.t("ui.model.download")) { Task { await model.downloadFromMirror() } }
                    .disabled(model.isDownloading)
                Button(L.t("ui.model.browse")) {
                    if let u = Panels.chooseFile(title: L.f("mac.model.pickTitle", AiModelStore.kindName(model.kind)),
                                                 types: [UTType(filenameExtension: "mlpackage") ?? .package, .zip]) {
                        model.importModel(u)
                    }
                }
                Menu {
                    Button(L.t("ui.model.downloadUrl")) { askUrl = true }
                    Button(L.t("ui.model.refresh")) { model.refresh() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .alert(L.t("ui.model.downloadTitle"), isPresented: $askUrl) {
            TextField("https://", text: $url)
            Button(L.t("ui.dialog.ok")) {
                if let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.scheme != nil, url != "https://" {
                    Task { await model.download(from: u) }
                }
            }
            Button(L.t("ui.dialog.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("mac.model.downloadPrompt"))
        }
    }
}
