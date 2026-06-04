import Foundation
import SharedCore

public enum CoachCardMode: String, Sendable, Codable, Hashable, CaseIterable {
    case grounded
    case synthesized
    case general
    case reframe
    case agenda
    case silent
}

public enum CoachCardSurface: String, Sendable, Codable, Hashable {
    case passive
    case interactive
}

public struct CoachCard: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let mode: CoachCardMode
    public let title: String
    /// One short "say this" line — the glanceable headline the overlay accents.
    ///
    /// Prefer this over `body`; falls back to `body` when empty (back-compat).
    public let lead: String
    /// ≤3 short supporting bullets (key facts / angles).
    public let points: [String]
    public let body: String
    public let attribution: String
    public let surface: CoachCardSurface
    public let burstScore: Double
    public let sourceChunkIds: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        mode: CoachCardMode,
        title: String,
        lead: String = "",
        points: [String] = [],
        body: String = "",
        attribution: String,
        surface: CoachCardSurface,
        burstScore: Double,
        sourceChunkIds: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.title = title
        self.lead = lead
        self.points = points
        self.body = body
        self.attribution = attribution
        self.surface = surface
        self.burstScore = burstScore
        self.sourceChunkIds = sourceChunkIds
        self.createdAt = createdAt
    }
}

/// A directed on-demand "Ask the coach" request.
///
/// Each maps to a distinct prompt
/// strategy in `SmartRouter`. Carried by a user-requested `CoachUtterance`; `nil`
/// for passive auto-surfaced utterances (the default smart routing applies).
public enum CoachIntent: String, Sendable, Codable, Hashable, CaseIterable {
    /// Answer the question / point on the table (grounded if RAG hits, else general).
    case answer
    /// Force an objection-handling / persuasive reframe.
    case reframe
    /// A crisp, credible talking point to elevate what the user is saying.
    case soundSmart
    /// Verify the most recent salient claim via RAG + anti-fabrication checker.
    case factCheck
}

public struct CoachUtterance: Sendable, Hashable {
    public let speakerId: String
    public let text: String
    public let timestamp: Date
    public let userRequested: Bool
    /// When set, a directed "Ask the coach" request that steers the prompt; `nil`
    /// for passive auto-surfaced utterances.
    public let intent: CoachIntent?

    public init(
        speakerId: String,
        text: String,
        timestamp: Date = Date(),
        userRequested: Bool = false,
        intent: CoachIntent? = nil
    ) {
        self.speakerId = speakerId
        self.text = text
        self.timestamp = timestamp
        self.userRequested = userRequested
        self.intent = intent
    }
}
