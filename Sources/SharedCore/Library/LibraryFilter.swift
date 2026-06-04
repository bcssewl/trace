import Foundation

public struct LibraryFilter: Sendable, Hashable {
    public var query: String?
    public var startedOnOrAfter: Date?
    public var startedOnOrBefore: Date?
    public var templateId: String?

    public init(
        query: String? = nil,
        startedOnOrAfter: Date? = nil,
        startedOnOrBefore: Date? = nil,
        templateId: String? = nil
    ) {
        self.query = query
        self.startedOnOrAfter = startedOnOrAfter
        self.startedOnOrBefore = startedOnOrBefore
        self.templateId = templateId
    }
}

public enum LibrarySort: Sendable, Hashable {
    case startedAtAscending
    case startedAtDescending
    case titleAscending
    case titleDescending
}

public struct LibrarySearchScope: Sendable, Hashable {
    public var projectIds: [String]?
    public var lastNDays: Int?
    public var sources: Set<LibraryItem.Source>

    public init(
        projectIds: [String]? = nil,
        lastNDays: Int? = nil,
        sources: Set<LibraryItem.Source> = []
    ) {
        self.projectIds = projectIds
        self.lastNDays = lastNDays
        self.sources = sources
    }

    /// The "older than this is out of scope" cutoff for `lastNDays`, or nil when
    /// recency is unconstrained.
    ///
    /// One home for the day→Date math.
    public var cutoffDate: Date? {
        lastNDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
    }
}
