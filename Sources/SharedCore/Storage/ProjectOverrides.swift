import Foundation

/// Per-project configuration overrides — the editable, persisted subset of the
/// design's `Project` model (§8.1) beyond name/color/coach. Stored as JSON in
/// `projects.overrides_json` (schema v30) and applied by the routers:
///
/// - `modelRouteOverrides` — per-LLM-task route; consulted by `ModelRouter`
///   (project route wins over the global preset).
/// - `asrRouteOverrides` — per-ASR-task route; consulted by `ASRRouter`
///   (`route(for:projectID:)`); the sensitive-local-only guard still applies.
/// - `vocabulary` — project-specific terms (names, jargon) for transcription /
///   notes biasing.
/// - `calendarMatchers` — rules used by auto-categorization to file meetings
///   into this project.
///
/// The decoder is tolerant (each field defaults when absent) so the `'{}'`
/// column default — and configs written by an older build — decode cleanly
/// instead of failing and resetting the project.
public struct ProjectOverrides: Sendable, Codable, Hashable {
    public var modelRouteOverrides: [LLMTaskClass: LLMRoute]
    public var asrRouteOverrides: [ASRTaskClass: ASRRoute]
    public var vocabulary: [String]
    public var calendarMatchers: [CalendarMatcher]

    public init(
        modelRouteOverrides: [LLMTaskClass: LLMRoute] = [:],
        asrRouteOverrides: [ASRTaskClass: ASRRoute] = [:],
        vocabulary: [String] = [],
        calendarMatchers: [CalendarMatcher] = []
    ) {
        self.modelRouteOverrides = modelRouteOverrides
        self.asrRouteOverrides = asrRouteOverrides
        self.vocabulary = vocabulary
        self.calendarMatchers = calendarMatchers
    }

    public static let empty = ProjectOverrides()

    public var isEmpty: Bool {
        modelRouteOverrides.isEmpty && asrRouteOverrides.isEmpty
            && vocabulary.isEmpty && calendarMatchers.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case modelRouteOverrides, asrRouteOverrides, vocabulary, calendarMatchers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.modelRouteOverrides =
            try c.decodeIfPresent([LLMTaskClass: LLMRoute].self, forKey: .modelRouteOverrides) ?? [:]
        self.asrRouteOverrides = try c.decodeIfPresent([ASRTaskClass: ASRRoute].self, forKey: .asrRouteOverrides) ?? [:]
        self.vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        self.calendarMatchers = try c.decodeIfPresent([CalendarMatcher].self, forKey: .calendarMatchers) ?? []
    }

    /// Decode from the stored JSON string, falling back to `.empty` on any
    /// failure so a malformed blob never crashes project loading.
    public static func decode(json: String) -> ProjectOverrides {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(ProjectOverrides.self, from: data)
        else { return .empty }
        return decoded
    }

    /// Encode to a JSON string for storage.
    ///
    /// Returns `"{}"` on failure.
    public func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
