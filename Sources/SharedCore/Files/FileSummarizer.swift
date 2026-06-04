import Foundation

/// Outcome of one summary pass — the assembled markdown plus the resolved
/// route description so the audit log surfaces which provider answered.
public struct FileSummaryResult: Sendable, Hashable {
    public let markdown: String
    public let routeDescription: String

    public init(markdown: String, routeDescription: String) {
        self.markdown = markdown
        self.routeDescription = routeDescription
    }
}

/// Wraps `MergeEngine` for file-batch consumers.
///
/// Drives a single template
/// over a transcript and collects the final markdown. The streaming nature of
/// `MergeEngine` is preserved internally so the controller can surface partial
/// progress through `ProcessingState`.
///
/// `FileSummarizer` is a `struct` because all state lives inside `MergeEngine`.
public struct FileSummarizer: Sendable {

    private let engine: MergeEngine

    public init(router: any ModelRoutingFacade) {
        self.engine = MergeEngine(router: router)
    }

    public init(engine: MergeEngine) {
        self.engine = engine
    }

    /// Runs the merge against the file's transcript.
    ///
    /// Any untrusted context
    /// (prior notes, scratchpad) is empty by design — file batch is one-shot
    /// transcription, not the augmented-notes flow.
    public func summarize(
        transcript: String,
        template: Template,
        projectID: UUID? = nil,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> FileSummaryResult {
        let context = RenderContext(
            transcript: AntiInjectionGuard.wrap(transcript, source: .transcript),
            scratchpad: "",
            calendarUntrusted: "",
            priorNotesUntrusted: "",
            projectVocab: "",
            conversationState: ""
        )

        var route = "default route for meetingAugmentedMerge"
        var assembled = ""
        for try await delta in engine.stream(
            template: template, context: context, projectId: projectID
        ) {
            switch delta {
            case .began(_, _, let routeDescription):
                route = routeDescription
            case .token(let text):
                assembled += text
                await onToken?(text)
            case .sectionStarted:
                break
            case .completed(let final):
                assembled = final
            case .failed(let err):
                throw err
            }
        }
        return FileSummaryResult(markdown: assembled, routeDescription: route)
    }
}
