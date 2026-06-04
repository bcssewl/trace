import Foundation

public struct ProjectBinding: Sendable, Hashable, Codable {
    public let projectId: UUID
    public var isDefault: Bool

    public init(projectId: UUID, isDefault: Bool) {
        self.projectId = projectId
        self.isDefault = isDefault
    }
}
