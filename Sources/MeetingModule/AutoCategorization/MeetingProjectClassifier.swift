import Foundation
import SharedCore

/// The configurable LLM "final classifier" for meeting auto-categorization
/// (design §8.2, BAS-9): given the candidate projects and the meeting transcript,
/// the model picks the best-matching project (or abstains).
///
/// Routed through the
/// `ModelRoutingFacade` seam on the `.projectCategorization` task class, so the
/// user chooses the provider/model (default Apple FM, all-local). The transcript
/// is anti-injection wrapped, and the JSON reply is parsed tolerantly so
/// non-Apple-FM models (which may fence or prose-wrap JSON) work too.
public struct MeetingProjectClassifier: Sendable {

    public struct Pick: Sendable, Hashable {
        public let projectID: UUID
        public let confidence: Double
        public init(projectID: UUID, confidence: Double) {
            self.projectID = projectID
            self.confidence = confidence
        }
    }

    private let router: any ModelRoutingFacade

    public init(router: any ModelRoutingFacade) {
        self.router = router
    }

    /// Pick the best project for the meeting, or `nil` (no projects, too little
    /// transcript, the model abstains/errs, or an unparseable / out-of-range reply).
    public func classify(
        transcriptPrefix: String, calendarTitle: String?, projects: [ProjectCandidate]
    ) async -> Pick? {
        guard !projects.isEmpty else { return nil }
        let trimmed = transcriptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count >= 6 else { return nil }

        let numbered = projects.enumerated()
            .map { "\($0.offset + 1). \($0.element.name)" }
            .joined(separator: "\n")
        var body = ""
        if let calendarTitle, !calendarTitle.isEmpty {
            body += "Calendar event: \(calendarTitle)\n\n"
        }
        body += "Projects:\n\(numbered)\n\nMeeting transcript:\n"
        body += AntiInjectionGuard.wrap(String(trimmed.prefix(2000)), source: .transcript)

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: Self.systemPrompt),
                LLMMessage(role: .user, content: body),
            ],
            taskClass: .projectCategorization,
            temperature: 0.0,
            maxTokens: 40,
            responseFormat: .json
        )

        var text = ""
        do {
            for try await delta in router.stream(request, routeOverride: nil) {
                text += delta.textIncrement
            }
        } catch {
            return nil
        }

        guard let object = JSONExtraction.objectDictionary(from: text),
            let index = (object["index"] as? NSNumber)?.intValue,
            index >= 1, index <= projects.count
        else { return nil }
        let confidence = min(1.0, max(0.0, (object["confidence"] as? NSNumber)?.doubleValue ?? 0))
        return Pick(projectID: projects[index - 1].id, confidence: confidence)
    }

    static let systemPrompt = """
        You match a meeting to the project it belongs to. Given a numbered list of \
        projects and the meeting transcript, reply with ONLY a JSON object: \
        {"index": <project number, or 0 if none clearly match>, "confidence": <0.0-1.0>}. \
        Be conservative — use index 0 when unsure.
        """
}
