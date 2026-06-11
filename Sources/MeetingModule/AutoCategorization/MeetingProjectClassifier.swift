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
    ///
    /// `meetingTitle` is the generated meeting title (available because title
    /// generation runs before categorization) and `recentTitlesByProject` holds a
    /// few titles of meetings already filed in each project — both are far more
    /// reliable evidence than the raw transcript, whose ASR text can come out
    /// garbled or in the wrong language entirely (a Spanish lesson once
    /// auto-filed into "Romanian classes" off transcript noise alone).
    public func classify(
        transcriptPrefix: String,
        meetingTitle: String? = nil,
        calendarTitle: String?,
        projects: [ProjectCandidate],
        recentTitlesByProject: [UUID: [String]] = [:]
    ) async -> Pick? {
        guard !projects.isEmpty else { return nil }
        let trimmed = transcriptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count >= 6 else { return nil }

        let numbered = projects.enumerated()
            .map { offset, project in
                let examples = (recentTitlesByProject[project.id] ?? [])
                    .map { Self.sanitisedExample($0) }
                    .filter { !$0.isEmpty }
                    .prefix(3)
                let suffix = examples.isEmpty
                    ? ""
                    : " (already contains: \(examples.map { "“\($0)”" }.joined(separator: "; ")))"
                return "\(offset + 1). \(project.name)\(suffix)"
            }
            .joined(separator: "\n")
        var body = ""
        if let calendarTitle, !calendarTitle.isEmpty {
            body += "Calendar event: \(calendarTitle)\n\n"
        }
        body += "Projects:\n\(numbered)\n\n"
        var untrusted = ""
        if let meetingTitle = meetingTitle.map(Self.sanitisedExample), !meetingTitle.isEmpty {
            untrusted += "Meeting title: \(meetingTitle)\n\n"
        }
        untrusted += "Transcript excerpts:\n\(String(trimmed.prefix(2000)))"
        body += AntiInjectionGuard.wrap(untrusted, source: .transcript)

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
        You match a meeting to the project it belongs to. You are given a numbered \
        list of the user's projects (some with titles of meetings already filed in \
        them), and the meeting's own evidence: its title and transcript excerpts. \
        Reply with ONLY a JSON object: \
        {"index": <project number, or 0 if none clearly match>, "confidence": <0.0-1.0>}. \
        Weigh the evidence in this order: the meeting title and calendar event are \
        the most reliable; the per-project example titles show what kind of meeting \
        lives in each project; the transcript is automatic speech recognition output \
        and may be garbled or even come out in the wrong language — when it \
        conflicts with the title, trust the title. \
        Be conservative — use index 0 when unsure.
        """

    /// One-line, length-clamped form of an LLM-derived title so it can sit
    /// inside the prompt without control garbage or runaway length.
    static func sanitisedExample(_ raw: String) -> String {
        let collapsed =
            raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(90))
    }
}
