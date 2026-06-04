import Foundation

public struct Template: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var description: String
    public var isBuiltIn: Bool
    public var version: SemVer
    public var forkedFrom: UUID?

    public var systemPrompt: String
    public var outputSections: [String]
    /// When true, the merge engine lets the model choose its own content-fitting
    /// section headings (and omit empty topics) instead of emitting the fixed
    /// `outputSections`.
    ///
    /// The single live meeting template sets this; fixed-section
    /// templates leave it false.
    public var dynamicSections: Bool
    public var modelRouteOverride: LLMRoute?
    public var knobs: TemplateKnobs

    public var calendarMatchers: [CalendarMatcher]
    public var projectBindings: [ProjectBinding]

    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: UUID, name: String, description: String, isBuiltIn: Bool, version: SemVer,
        forkedFrom: UUID?, systemPrompt: String, outputSections: [String],
        modelRouteOverride: LLMRoute?, knobs: TemplateKnobs,
        calendarMatchers: [CalendarMatcher], projectBindings: [ProjectBinding],
        createdAt: Int64, updatedAt: Int64, dynamicSections: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.version = version
        self.forkedFrom = forkedFrom
        self.systemPrompt = systemPrompt
        self.outputSections = outputSections
        self.modelRouteOverride = modelRouteOverride
        self.knobs = knobs
        self.calendarMatchers = calendarMatchers
        self.projectBindings = projectBindings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dynamicSections = dynamicSections
    }

    public static func makeBuiltIn(
        id: UUID, name: String, description: String,
        systemPrompt: String, outputSections: [String],
        knobs: TemplateKnobs = .default,
        calendarMatchers: [CalendarMatcher] = [],
        dynamicSections: Bool = false
    ) -> Template {
        let now = Int64(Date().timeIntervalSince1970)
        return Template(
            id: id, name: name, description: description,
            isBuiltIn: true, version: SemVer(major: 1, minor: 0, patch: 0),
            forkedFrom: nil, systemPrompt: systemPrompt, outputSections: outputSections,
            modelRouteOverride: nil, knobs: knobs,
            calendarMatchers: calendarMatchers, projectBindings: [],
            createdAt: now, updatedAt: now, dynamicSections: dynamicSections
        )
    }

    public func cloned() -> Template {
        let suffix = " (Custom)"
        let newName = name.hasSuffix(suffix) ? name : name + suffix
        let now = Int64(Date().timeIntervalSince1970)
        return Template(
            id: UUID(), name: newName, description: description,
            isBuiltIn: false, version: version, forkedFrom: id,
            systemPrompt: systemPrompt, outputSections: outputSections,
            modelRouteOverride: modelRouteOverride, knobs: knobs,
            calendarMatchers: calendarMatchers, projectBindings: projectBindings,
            createdAt: now, updatedAt: now, dynamicSections: dynamicSections
        )
    }
}
