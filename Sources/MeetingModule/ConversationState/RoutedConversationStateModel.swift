import Foundation
import SharedCore

/// `ConversationStateModeling` backed by the app's `ModelRouter`.
///
/// Maintains a
/// rolling JSON state of the meeting: given the prior state plus the latest
/// transcript (assembled by `ConversationStateExtractor`), it returns the updated
/// state. Routed via the `.conversationStateExtractor` task class — so the actual
/// model is whatever the user has configured for that stage (Apple FM by default,
/// or a larger local / cloud model). A thin adapter over `ModelRouter`;
/// `ConversationStateExtractor` decodes the returned JSON.
public struct RoutedConversationStateModel: ConversationStateModeling {
    private let router: ModelRouter

    public init(router: ModelRouter) {
        self.router = router
    }

    public func generateConversationStateJSON(prompt: String) async throws -> String {
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: """
                        You maintain a running, compact JSON summary of a live meeting. You are given the \
                        PRIOR state and the LATEST transcript excerpt. Return the UPDATED state: keep \
                        "topic" current, carry forward open questions / active tensions / recent decisions \
                        that still matter, integrate new ones from the transcript, and drop items that are \
                        resolved or stale. Ground every field in the prior state or the transcript — never \
                        invent. Respond ONLY with a single JSON object, no prose or code fences:
                        {"topic":"...","summary":"...","openQuestions":[...],"activeTensions":[...],"recentDecisions":[...]}
                        Use "" or [] when a field has nothing to report.
                        """),
                LLMMessage(role: .user, content: prompt),
            ],
            taskClass: .conversationStateExtractor,
            temperature: 0.1,
            // Headroom for a rolling state that accumulates across a long meeting,
            // so a capable model isn't clipped mid-summary; the prompt still asks
            // for a compact digest.
            maxTokens: 500,
            responseFormat: .json
        )
        let response = try await router.generate(request)
        return response.text
    }
}
