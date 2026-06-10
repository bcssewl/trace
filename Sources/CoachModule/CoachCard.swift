import Foundation

/// What kind of help a coach card offers.
///
/// The three kinds mirror the listener's
/// output contract exactly (`{"action":"card","kind":…}`):
///
/// - `answer`: answers the question on the table — from the user's notes, from
///   earlier in this meeting, or from the model's own general knowledge.
/// - `recall`: resurfaces a relevant fact / commitment / detail from the user's
///   notes or from earlier in this meeting.
/// - `suggestion`: a concrete thing the user could say next.
public enum CoachCardKind: String, Sendable, Codable, Hashable, CaseIterable {
    case answer
    case recall
    case suggestion
}

/// One surfaced coach card.
///
/// `grounding` carries a short verbatim quote from
/// the supplied notes when the card draws on them — shown on the card so the
/// user can see exactly what it is standing on. Empty for cards built from the
/// live transcript or the model's general knowledge (those are visually marked
/// as such instead).
public struct CoachCard: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: CoachCardKind
    /// Short context label (what this card is about).
    public let title: String
    /// The card text the user reads at a glance (≤ a few sentences).
    public let body: String
    /// Verbatim quote from the supplied notes, or empty when the card is
    /// transcript-derived / general knowledge.
    public let grounding: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: CoachCardKind,
        title: String,
        body: String,
        grounding: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.grounding = grounding
        self.createdAt = createdAt
    }

    /// Whether the card draws on the user's own notes (a grounding quote is
    /// present).
    public var isGrounded: Bool {
        !grounding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A directed on-demand "Ask the coach" request (triple-tap / the Ask chips).
///
/// Each maps to an explicit directive in the listener's prompt; `nil` means an
/// undirected manual ask ("help me with this moment").
public enum CoachIntent: String, Sendable, Codable, Hashable, CaseIterable {
    /// Answer the question / point on the table.
    case answer
    /// An objection-handling / persuasive reframe the user can say back.
    case reframe
    /// A crisp, credible talking point that elevates the current point.
    case soundSmart
    /// Check the most recent salient claim against the notes / transcript /
    /// general knowledge.
    case factCheck
}
