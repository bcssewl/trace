import Foundation

public struct ProjectCandidate: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CategorizationSignals: Sendable, Hashable, Codable {
    public let regex: Double
    public let attendee: Double
    public let content: Double
    public let recurring: Double
    public let manualHistory: Double

    public init(regex: Double, attendee: Double, content: Double, recurring: Double, manualHistory: Double) {
        self.regex = regex
        self.attendee = attendee
        self.content = content
        self.recurring = recurring
        self.manualHistory = manualHistory
    }
}

public struct CategorizationScore: Sendable, Hashable, Codable {
    public let project: ProjectCandidate
    public let confidence: Double

    public init(project: ProjectCandidate, confidence: Double) {
        self.project = project
        self.confidence = confidence
    }
}

public enum CategorizationBucket: Sendable, Hashable, Codable {
    case autoAssign
    case askUser
    case inbox
    case manualOverride
}

public struct CategorizationResult: Sendable, Hashable, Codable {
    public let bucket: CategorizationBucket
    public let scores: [CategorizationScore]

    public init(bucket: CategorizationBucket, scores: [CategorizationScore]) {
        self.bucket = bucket
        self.scores = scores
    }
}

public struct MeetingCategorizationInput: Sendable, Hashable, Codable {
    public let manualOverride: Bool
    public let transcriptPrefix: String
    public let attendeeEmails: [String]

    public init(manualOverride: Bool, transcriptPrefix: String, attendeeEmails: [String]) {
        self.manualOverride = manualOverride
        self.transcriptPrefix = transcriptPrefix
        self.attendeeEmails = attendeeEmails
    }
}

public protocol CategorizationSignalProviding: Sendable {
    func signals(
        for meeting: MeetingCategorizationInput, project: ProjectCandidate
    ) async throws -> CategorizationSignals
}

public actor ProjectCategorizer {
    public static let autoAssignThreshold = 0.75
    public static let askUserThreshold = 0.4

    private let signalProvider: any CategorizationSignalProviding

    public init(signalProvider: any CategorizationSignalProviding) {
        self.signalProvider = signalProvider
    }

    public func categorize(
        _ meeting: MeetingCategorizationInput, projects: [ProjectCandidate]
    ) async throws -> CategorizationResult {
        guard !meeting.manualOverride else {
            return CategorizationResult(bucket: .manualOverride, scores: [])
        }
        var scores: [CategorizationScore] = []
        for project in projects {
            let signals = try await signalProvider.signals(for: meeting, project: project)
            scores.append(Self.score(project: project, signals: signals))
        }
        scores.sort { $0.confidence > $1.confidence }
        let top = scores.first?.confidence ?? 0
        let bucket: CategorizationBucket
        if top > Self.autoAssignThreshold {
            bucket = .autoAssign
        } else if top >= Self.askUserThreshold {
            bucket = .askUser
        } else {
            bucket = .inbox
        }
        return CategorizationResult(bucket: bucket, scores: scores)
    }

    public static func score(project: ProjectCandidate, signals: CategorizationSignals) -> CategorizationScore {
        let confidence =
            signals.regex * 0.30
            + signals.attendee * 0.25
            + signals.content * 0.25
            + signals.recurring * 0.15
            + signals.manualHistory * 0.05
        return CategorizationScore(project: project, confidence: confidence)
    }
}
