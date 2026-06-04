import Foundation
import SharedCore

public enum UtteranceClass: String, Sendable, Codable, Hashable {
    case question
    case claim
    case objection
    case commitment
    case topicShift
    case none
}

public protocol UtteranceClassifying: Sendable {
    func classify(utterance: String, regexHits: Set<RegexDetector.Marker>) async throws -> UtteranceClass
}

public actor AppleFmUtteranceClassifier: UtteranceClassifying {
    private let router: ModelRouter

    public init(router: ModelRouter) {
        self.router = router
    }

    public func classify(
        utterance: String, regexHits: Set<RegexDetector.Marker>
    ) async throws -> UtteranceClass {
        let wrapped = AntiInjectionGuard.wrap(utterance, source: .transcript)
        let hitsHint = regexHits.map(\.rawValue).sorted().joined(separator: ",")
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: """
                        Classify the utterance as exactly one of: question | claim | objection | commitment | topicShift | none.
                        Use the regex hints as priors but trust the content. Respond with only the lowercase keyword.
                        """),
                LLMMessage(
                    role: .user,
                    content: """
                        Regex hints: \(hitsHint)

                        Utterance:
                        \(wrapped)
                        """),
            ],
            taskClass: .coachSmartRouting,
            temperature: 0.0,
            maxTokens: 16
        )
        let response = try await router.generate(request)
        let raw = response.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return UtteranceClass(rawValue: raw) ?? .none
    }
}

public struct ScriptedUtteranceClassifier: UtteranceClassifying {
    public let outcome: UtteranceClass
    public init(outcome: UtteranceClass) { self.outcome = outcome }
    public func classify(
        utterance: String, regexHits: Set<RegexDetector.Marker>
    ) async throws -> UtteranceClass {
        outcome
    }
}
