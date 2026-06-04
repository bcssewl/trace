import Foundation

public struct SessionMetadata: Sendable, Codable, Hashable {
    public let sessionId: String
    public let projectId: String?
    public let title: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var templateId: String?
    public var calendarEventId: String?
    public var autoCategorizedConfidence: Double?
    public var manualOverride: Bool
    public let sessionDirPath: String

    public init(
        sessionId: String,
        projectId: String? = nil,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        templateId: String? = nil,
        calendarEventId: String? = nil,
        autoCategorizedConfidence: Double? = nil,
        manualOverride: Bool = false,
        sessionDirPath: String
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.templateId = templateId
        self.calendarEventId = calendarEventId
        self.autoCategorizedConfidence = autoCategorizedConfidence
        self.manualOverride = manualOverride
        self.sessionDirPath = sessionDirPath
    }
}
