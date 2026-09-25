import ClearStarCore
import Foundation
import Observation

/// One setting on the step's card. Changes go straight into the step's parameters.
@MainActor @Observable
public final class ParameterModel: Identifiable {
    public let definition: ParameterDefinition
    @ObservationIgnored let parameters: StepParameters
    /// Called after the user changed the value (live preview, crop selection…).
    @ObservationIgnored var onChange: (() -> Void)?

    public nonisolated var id: String { definition.key }
    public var key: String { definition.key }
    public var label: String { definition.label }
    public var help: String? { definition.help }
    public var isAdvanced: Bool { definition.advanced }
    public var isHidden: Bool { definition.kind == .hidden }
    public var kind: ParameterKind { definition.kind }

    public var number: Double { didSet { if number != oldValue { parameters.set(key, number); onChange?() } } }
    public var isOn: Bool { didSet { if isOn != oldValue { parameters.set(key, isOn); onChange?() } } }
    public var choice: String { didSet { if choice != oldValue { parameters.set(key, choice); onChange?() } } }
    public var text: String { didSet { if text != oldValue { parameters.set(key, text); onChange?() } } }

    /// The model picker's state (kind .model only).
    public let model: ModelChoiceModel?

    init(_ d: ParameterDefinition, _ p: StepParameters) {
        definition = d
        parameters = p
        number = Self.defaultNumber(d, p)
        isOn = Self.defaultBool(d, p)
        choice = Self.defaultText(d, p)
        text = Self.defaultText(d, p)
        model = d.kind == .model ? ModelChoiceModel(d, p) : nil
    }

    private static func defaultNumber(_ d: ParameterDefinition, _ p: StepParameters) -> Double {
        if case .number(let v) = d.defaultValue { return p.getDouble(d.key, v) }
        return p.getDouble(d.key)
    }
    private static func defaultBool(_ d: ParameterDefinition, _ p: StepParameters) -> Bool {
        if case .bool(let v) = d.defaultValue { return p.getBool(d.key, v) }
        return false
    }
    private static func defaultText(_ d: ParameterDefinition, _ p: StepParameters) -> String { p.getString(d.key, d.defaultValue.description) }

    public var minimum: Double { definition.min }
    public var maximum: Double { definition.max }
    public var tickLabels: [String] { definition.tickLabels ?? ["", "", ""] }
    public var choices: [(value: String, label: String)] { (definition.choices ?? []).map { ($0, definition.labelFor($0)) } }

    /// The label nearest to the slider position – the beginner sees this instead of a number.
    public var valueLabel: String {
        if let format = definition.valueFormat { return DotNetFormatter.format(format, number) }
        let ticks = tickLabels
        if ticks.isEmpty || maximum <= minimum { return "" }
        let t = (number - minimum) / (maximum - minimum)
        let i = Int((t * Double(ticks.count - 1)).rounded(.toNearestOrEven))
        return ticks[min(max(i, 0), ticks.count - 1)]
    }

    /// Back to the default value.
    public func reset() {
        switch definition.defaultValue {
        case .number(let v): number = v
        case .bool(let v): isOn = v
        case .text(let v): if kind == .choice { choice = v } else { text = v }
        }
        if kind == .hidden { parameters[key] = definition.defaultValue }
        if kind == .model { parameters.set(key, ""); model?.refresh() }
    }

    /// Re-reads the value after the model changed the parameters (e.g. a committed stretch).
    public func reload() {
        let cb = onChange
        onChange = nil
        switch kind {
        case .slider: number = Self.defaultNumber(definition, parameters)
        case .toggle: isOn = Self.defaultBool(definition, parameters)
        case .choice: choice = Self.defaultText(definition, parameters)
        default: text = Self.defaultText(definition, parameters)
        }
        onChange = cb
    }
}

/// Formats a slider value with a .NET format string such as "{0:+0.0;−0.0;0}°".
public enum DotNetFormatter {
    public static func format(_ template: String, _ value: Double) -> String {
        DotNetFormat.format(template, [value], locale: .current)
    }
}

/// The AI model picker of a step: the models on this Mac, download from ClearStar's mirror or a URL,
/// import of a .mlpackage / zip. Empty value = the newest available model; the choice goes to the settings.
@MainActor @Observable
public final class ModelChoiceModel {
    public let kind: AiModelKind
    @ObservationIgnored let key: String
    @ObservationIgnored let parameters: StepParameters
    public private(set) var choices: [(label: String, path: String)] = []
    public var selectedPath: String = "" { didSet { if selectedPath != oldValue { select(selectedPath) } } }
    public private(set) var statusText = ""
    public private(set) var isMissing = false
    public private(set) var isDownloading = false
    public private(set) var downloadProgress = 0.0

    init(_ d: ParameterDefinition, _ p: StepParameters) {
        kind = AiModelKind(rawValue: d.tag ?? "") ?? .backgroundExtraction
        key = d.key
        parameters = p
        refresh()
    }

    private func select(_ path: String) {
        parameters.set(key, path)
        AiModelStore.setPreferred(kind, path.isEmpty ? nil : path)
        updateStatus()
    }

    private func updateStatus() {
        let resolved = AiModelStore.resolve(kind)
        isMissing = resolved == nil
        statusText = resolved.map { L.f("ui.model.using", $0.version, $0.source) } ?? L.t("mac.model.missing")
    }

    public func refresh() {
        let current = parameters.getString(key)
        var list: [(label: String, path: String)] = [(L.t("ui.model.auto"), "")]
        for m in AiModelStore.listAvailable(kind) { list.append((L.f("ui.model.fromFolder", m.version, m.source), m.path)) }
        if !current.isEmpty && !list.contains(where: { $0.path == current }) && FileManager.default.fileExists(atPath: current) {
            list.append((L.f("ui.model.ownFile", (current as NSString).lastPathComponent), current))
        }
        choices = list
        let wanted = list.contains { $0.path == current } ? current : ""
        if selectedPath != wanted { selectedPath = wanted } else { updateStatus() }
    }

    /// Import of a chosen package or zip.
    public func importModel(_ url: URL) {
        do {
            let info = try AiModelStore.importModel(kind, from: url)
            parameters.set(key, info.path)
            refresh()
        } catch {
            statusText = L.f("ui.model.loadFailed", error.localizedDescription)
        }
    }

    /// The newest model of the kind from the mirror; nothing is downloaded when that version is here.
    public func downloadFromMirror() async {
        if isDownloading { return }
        isDownloading = true
        downloadProgress = 0
        statusText = L.t("ui.model.mirrorChecking")
        defer { isDownloading = false }
        do {
            guard let latest = try await AiModelStore.latestOnMirror(kind) else { statusText = L.t("ui.model.mirrorNone"); return }
            if let present = AiModelStore.listAvailable(kind).first(where: { $0.version == latest.version }) {
                statusText = L.f("ui.model.upToDate", present.version, present.source)
                return
            }
            statusText = L.f("ui.model.downloadingMirror", latest.version, latest.size / (1024 * 1024))
            let info = try await AiModelStore.downloadFromMirror(latest) { p in Task { @MainActor in self.downloadProgress = p } }
            parameters.set(key, info.path)
            refresh()
        } catch {
            statusText = L.f("ui.model.downloadFailed", error.localizedDescription)
        }
    }

    public func download(from url: URL) async {
        if isDownloading { return }
        isDownloading = true
        downloadProgress = 0
        statusText = L.t("ui.model.downloading")
        defer { isDownloading = false }
        do {
            let info = try await AiModelStore.download(kind, from: url) { p in Task { @MainActor in self.downloadProgress = p } }
            parameters.set(key, info.path)
            refresh()
        } catch {
            statusText = L.f("ui.model.downloadFailed", error.localizedDescription)
        }
    }
}

/// A step's card in the sidebar and the inspector.
@MainActor @Observable
public final class StepModel: Identifiable {
    @ObservationIgnored public let entry: WorkflowEntry
    public nonisolated let id: StepId
    public let parameters: [ParameterModel]

    public private(set) var state: StepState = .pending
    public private(set) var summary: String?
    /// Extra line on the card (e.g. the crop selection) and its action.
    public var note: String?
    public var noteActionText: String?
    @ObservationIgnored public var noteAction: (() -> Void)?
    /// A second, prominent action under the parameters (e.g. "Auto stretch").
    public var secondaryActionText: String?
    @ObservationIgnored public var secondaryAction: (() -> Void)?
    public var showAdvanced = false

    init(_ entry: WorkflowEntry) {
        self.entry = entry
        id = entry.id
        parameters = entry.definition.parameters.map { ParameterModel($0, entry.parameters) }
        refresh()
    }

    public var definition: StepDefinition { entry.definition }
    public var number: Int { definition.number }
    public var name: String { definition.name }
    public var technicalName: String? { definition.technicalName.map { "(\($0))" } }
    public var descriptionText: String { definition.description }
    public var isImplemented: Bool { entry.step.isImplemented }
    public var canSkip: Bool { !(id == .loadFrames || id == .stack || id == .save) }
    public var basicParameters: [ParameterModel] { parameters.filter { !$0.isAdvanced && !$0.isHidden } }
    public var advancedParameters: [ParameterModel] { parameters.filter { $0.isAdvanced && !$0.isHidden } }
    public var hasAdvanced: Bool { parameters.contains { $0.isAdvanced } }
    public var hasParameters: Bool { parameters.contains { !$0.isHidden } }

    public var isDone: Bool { state == .done }
    public var isSkipped: Bool { state == .skipped }
    public var isStale: Bool { state == .stale }
    public var isPending: Bool { state == .pending }

    func refresh() {
        state = entry.state
        summary = entry.summary
    }

    /// The short text on the right of the header.
    public var metaText: String? {
        switch state {
        case .skipped: return L.t("ui.step.skipped")
        case .stale: return L.t("ui.step.stale")
        case .done: return summary
        case .pending: return nil
        }
    }

    public var primaryButtonText: String {
        switch id {
        case .loadFrames: return L.t("ui.step.btnLoad")
        case .stack: return L.t("ui.step.btnStack")
        case .save: return L.t("ui.step.btnSave")
        // The stretch and star steps are previewed live and move on after Apply: never "apply again".
        case .starlessStretch, .starStretch: return L.t("ui.step.btnApply")
        default: return L.t(state == .done ? "ui.step.btnReapply" : "ui.step.btnApply")
        }
    }

    public func parameter(_ key: String) -> ParameterModel? { parameters.first { $0.key == key } }
}

/// One loaded frame in the list.
@MainActor @Observable
public final class FrameItem: Identifiable {
    public nonisolated let id: String
    public let info: FrameInfo
    public let typeName: String
    public let detail: String
    public var status: String?
    public var isUsed: Bool?
    public var stars: Int?
    public var starSize: Float?
    public var background: Float?
    public var angle: Float?

    init(_ info: FrameInfo) {
        self.info = info
        id = info.path
        switch info.type {
        case .light: typeName = L.t("ui.frames.typeLight")
        case .dark: typeName = L.t("ui.frames.typeDark")
        case .flat: typeName = L.t("ui.frames.typeFlat")
        case .bias: typeName = L.t("ui.frames.typeBias")
        case .unknown: typeName = "?"
        }
        detail = info.exposureSeconds > 0 ? L.f("ui.frames.seconds", info.exposureSeconds) : ""
    }

    public var fileName: String { info.fileName }
}
