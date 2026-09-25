import Foundation

public enum ParameterKind: Sendable { case slider, toggle, choice, folder, text, hidden, model }

/// A parameter value: number, switch or text (the C# object values double / bool / string).
public enum ParameterValue: Sendable, Equatable, CustomStringConvertible {
    case number(Double)
    case bool(Bool)
    case text(String)

    public var description: String {
        switch self {
        case .number(let d): return formatR(d)
        case .bool(let b): return b ? "True" : "False"
        case .text(let s): return s
        }
    }
}

/// Description of one setting for the UI. Labels come from the language database; sliders get
/// "Weak – Medium – Strong" style tick labels (the beginner never sees the raw number). Choice values
/// are language-independent keys, their labels are `choiceLabels`.
public struct ParameterDefinition: Sendable {
    public var key: String
    public var label: String
    public var kind: ParameterKind
    public var defaultValue: ParameterValue
    public var min: Double = 0
    public var max: Double = 1
    public var tickLabels: [String]?
    public var choices: [String]?
    public var advanced = false
    public var help: String?
    public var tag: String?
    public var choiceLabels: [String]?
    public var valueFormat: String?

    public init(key: String, label: String, kind: ParameterKind, defaultValue: ParameterValue, min: Double = 0, max: Double = 1,
                tickLabels: [String]? = nil, choices: [String]? = nil, advanced: Bool = false, help: String? = nil, tag: String? = nil,
                choiceLabels: [String]? = nil, valueFormat: String? = nil) {
        self.key = key; self.label = label; self.kind = kind; self.defaultValue = defaultValue; self.min = min; self.max = max
        self.tickLabels = tickLabels; self.choices = choices; self.advanced = advanced; self.help = help; self.tag = tag
        self.choiceLabels = choiceLabels; self.valueFormat = valueFormat
    }

    /// The label of a choice value (the value itself when there is none).
    public func labelFor(_ choice: String) -> String {
        guard let choices, let choiceLabels, let i = choices.firstIndex(of: choice), i < choiceLabels.count else { return choice }
        return choiceLabels[i]
    }
}

/// Static description of a step: name, group, plain explanation, parameters.
public struct StepDefinition: Sendable {
    public var id: StepId
    public var group: StepGroup
    public var name: String
    public var technicalName: String?
    public var description: String
    public var parameters: [ParameterDefinition]

    public var number: Int { id.rawValue }

    public init(id: StepId, group: StepGroup, name: String, technicalName: String?, description: String, parameters: [ParameterDefinition]) {
        self.id = id; self.group = group; self.name = name; self.technicalName = technicalName; self.description = description
        self.parameters = parameters
    }

    /// Definition from the language database: step.&lt;key&gt;.name / .tech / .desc.
    public static func fromLanguage(_ id: StepId, _ group: StepGroup, _ key: String, _ parameters: [ParameterDefinition]) -> StepDefinition {
        StepDefinition(id: id, group: group, name: L.t("step.\(key).name"), technicalName: L.has("step.\(key).tech") ? L.t("step.\(key).tech") : nil,
                       description: L.t("step.\(key).desc"), parameters: parameters)
    }

    public static func groupName(_ g: StepGroup) -> String { L.t("group.\(g.rawValue)") }
}

/// The current settings of a step as key–value pairs, with typed getters (case-insensitive keys).
public final class StepParameters: @unchecked Sendable {
    private var values: [String: (key: String, value: ParameterValue)] = [:]
    private let lock = NSLock()

    public init() {}

    public init(_ definitions: [ParameterDefinition]) {
        for d in definitions { self[d.key] = d.defaultValue }
    }

    public subscript(key: String) -> ParameterValue? {
        get { lock.lock(); defer { lock.unlock() }; return values[key.lowercased()]?.value }
        set {
            lock.lock(); defer { lock.unlock() }
            if let newValue { values[key.lowercased()] = (values[key.lowercased()]?.key ?? key, newValue) }
            else { values.removeValue(forKey: key.lowercased()) }
        }
    }

    public func set(_ key: String, _ value: Double) { self[key] = .number(value) }
    public func set(_ key: String, _ value: Bool) { self[key] = .bool(value) }
    public func set(_ key: String, _ value: String) { self[key] = .text(value) }

    public var all: [(key: String, value: ParameterValue)] {
        lock.lock(); defer { lock.unlock() }
        return values.values.map { ($0.key, $0.value) }
    }

    public func getDouble(_ key: String, _ fallback: Double = 0) -> Double {
        switch self[key] {
        case .number(let d): return d
        case .text(let s): return parseDouble(s) ?? fallback
        default: return fallback
        }
    }

    public func getFloat(_ key: String, _ fallback: Float = 0) -> Float { Float(getDouble(key, Double(fallback))) }

    public func getBool(_ key: String, _ fallback: Bool = false) -> Bool {
        switch self[key] {
        case .bool(let b): return b
        case .text(let s):
            switch s.lowercased() { case "true": return true; case "false": return false; default: return fallback }
        default: return fallback
        }
    }

    public func getString(_ key: String, _ fallback: String = "") -> String { self[key]?.description ?? fallback }

    public func clone() -> StepParameters {
        let p = StepParameters()
        lock.lock(); p.values = values; lock.unlock()
        return p
    }

    public func valuesEqual(_ other: StepParameters) -> Bool {
        let a = all, b = Dictionary(other.all.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { x, _ in x })
        return a.count == b.count && a.allSatisfy { b[$0.key.lowercased()] == $0.value }
    }
}
