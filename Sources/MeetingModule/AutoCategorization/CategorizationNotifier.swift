import Foundation
import UserNotifications

public struct CategorizationAction: Sendable, Hashable {
    public let projectID: UUID
    public let title: String

    public init(projectID: UUID, title: String) {
        self.projectID = projectID
        self.title = title
    }
}

public protocol CategorizationNotificationSink: Sendable {
    func send(title: String, body: String, actions: [CategorizationAction]) async throws
}

public struct CategorizationNotifier: Sendable {
    private let sink: any CategorizationNotificationSink
    public let maxActionCount: Int

    public init(
        sink: any CategorizationNotificationSink = UserNotificationCategorizationSink(),
        maxActionCount: Int = 3
    ) {
        self.sink = sink
        self.maxActionCount = maxActionCount
    }

    public func notifyIfNeeded(result: CategorizationResult, meetingTitle: String) async throws {
        guard result.bucket == .askUser else { return }
        let actions = result.scores.prefix(maxActionCount).map {
            CategorizationAction(projectID: $0.project.id, title: $0.project.name)
        }
        try await sink.send(title: "Choose project", body: meetingTitle, actions: actions)
    }
}

public struct UserNotificationCategorizationSink: CategorizationNotificationSink {
    public init() {}

    public func send(title: String, body: String, actions: [CategorizationAction]) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
    }
}
