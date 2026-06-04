import Foundation

public struct ConversationStateModel: Sendable, Codable, Hashable {
    public var topic: String
    public var summary: String
    public var openQuestions: [String]
    public var activeTensions: [String]
    public var recentDecisions: [String]

    public init(
        topic: String, summary: String,
        openQuestions: [String], activeTensions: [String], recentDecisions: [String]
    ) {
        self.topic = topic
        self.summary = summary
        self.openQuestions = openQuestions
        self.activeTensions = activeTensions
        self.recentDecisions = recentDecisions
    }

    public static let empty = ConversationStateModel(
        topic: "", summary: "",
        openQuestions: [], activeTensions: [], recentDecisions: []
    )

    /// A compact, labeled rendering for injection into the coach smart-router
    /// prompt (as `SmartRoutingInput.conversationState`).
    ///
    /// Empty fields are
    /// omitted and list fields are joined with "; ", so an `.empty` state renders
    /// to "" and contributes nothing to the prompt.
    public var digest: String {
        var lines: [String] = []
        if !topic.isEmpty { lines.append("Topic: \(topic)") }
        if !summary.isEmpty { lines.append("Summary: \(summary)") }
        if !openQuestions.isEmpty {
            lines.append("Open questions: \(openQuestions.joined(separator: "; "))")
        }
        if !activeTensions.isEmpty {
            lines.append("Active tensions: \(activeTensions.joined(separator: "; "))")
        }
        if !recentDecisions.isEmpty {
            lines.append("Recent decisions: \(recentDecisions.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    /// A single compact line for the coach overlay's conversation-state row
    /// (BAS-48), e.g. `Now: pricing · open: can we discount?`.
    ///
    /// Leads with the
    /// current topic, then the most pressing open question (or, lacking one, an
    /// active tension). Empty when there's no topic yet, so the overlay row hides
    /// instead of showing a bare `Now:`.
    public var overlayLine: String {
        let topic = Self.condense(self.topic)
        guard !topic.isEmpty else { return "" }
        var line = "Now: \(topic)"
        if let open = Self.firstNonEmptyCondensed(openQuestions) {
            line += " · open: \(open)"
        } else if let tension = Self.firstNonEmptyCondensed(activeTensions) {
            line += " · tension: \(tension)"
        }
        return line
    }

    /// The first item that survives `condense` (non-empty after trim+clip), so a
    /// blank/whitespace-only entry doesn't suppress a later one or the fallback.
    private static func firstNonEmptyCondensed(_ items: [String]) -> String? {
        for item in items {
            let condensed = condense(item)
            if !condensed.isEmpty { return condensed }
        }
        return nil
    }

    /// Trim + clip a field so the overlay line stays on one row.
    private static func condense(_ text: String, max: Int = 48) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

public protocol ConversationStateModeling: Sendable {
    func generateConversationStateJSON(prompt: String) async throws -> String
}
