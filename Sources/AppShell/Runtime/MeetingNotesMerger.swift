import Foundation
import SharedCore

/// The augmented-notes merge for finalized meetings — the meeting analog of
/// `FileSummarizer`.
///
/// Where `FileSummarizer` runs a one-shot transcription with
/// empty context, `MeetingNotesMerger` populates the full augmented context:
/// the diarized transcript, the user's scratchpad, calendar, prior notes, and
/// conversation-state, then merges them into a template-structured note via the
/// LLM router, streaming tokens out as they arrive.
///
/// Every EXTERNAL source (transcript, scratchpad, calendar, prior notes) is
/// wrapped through `AntiInjectionGuard` so prompt-injection embedded in those
/// untrusted fields is presented to the model as data, never as instructions.
/// `conversationState` is app-generated, not external, so it is passed through
/// untouched.
///
/// `MeetingNotesMerger` is a `struct` because all state lives inside
/// `MergeEngine`; this mirrors `FileSummarizer` exactly.
public struct MeetingNotesMerger: Sendable {

    /// Above this transcript length (characters), the transcript is first
    /// condensed via `HierarchicalNotesSummarizer` (map-reduce) so the merge
    /// LLM's context window isn't blown.
    ///
    /// Below it, the transcript is merged
    /// verbatim — exactly as before.
    private static let condenseThreshold = 12_000

    private let engine: MergeEngine
    /// Direct router handle used for the per-chunk summarize calls in the
    /// long-transcript condensation path. `nil` when constructed via
    /// `init(engine:)`, in which case condensation is skipped (the merge still
    /// runs verbatim through `engine`).
    private let router: (any ModelRoutingFacade)?

    public init(router: any ModelRoutingFacade) {
        self.engine = MergeEngine(router: router)
        self.router = router
    }

    public init(engine: MergeEngine) {
        self.engine = engine
        self.router = nil
    }

    /// Builds a `RenderContext` (wrapping each non-empty EXTERNAL source via
    /// `AntiInjectionGuard`), runs `MergeEngine.stream`, forwards tokens to
    /// `onToken`, and returns the assembled note plus the resolved route
    /// description.
    ///
    /// `AntiInjectionGuard.wrap` returns an empty string for empty input, so
    /// empty sources contribute nothing to the rendered context — there is no
    /// need to guard non-empty here.
    public func generate(
        template: Template,
        transcript: String,
        scratchpad: String,
        calendarText: String,
        priorNotes: String,
        conversationState: String,
        projectID: UUID?,
        steer: String = "",
        onToken: (@Sendable (String) async -> Void)?
    ) async throws -> FileSummaryResult {
        // Long transcripts are condensed via map-reduce BEFORE the template
        // merge so the merge LLM's context isn't blown. Short transcripts (the
        // common case) flow through unchanged. The full transcript is never
        // mutated on disk — only the string fed into the merge is condensed.
        let mergeTranscript = try await condenseIfNeeded(transcript)

        let context = RenderContext(
            transcript: AntiInjectionGuard.wrap(mergeTranscript, source: .transcript),
            scratchpad: AntiInjectionGuard.wrap(scratchpad, source: .scratchpad),
            calendarUntrusted: AntiInjectionGuard.wrap(calendarText, source: .calendar),
            priorNotesUntrusted: AntiInjectionGuard.wrap(priorNotes, source: .priorNotes),
            projectVocab: "",
            conversationState: conversationState
        )

        Loggers.meeting.info(
            "MeetingNotesMerger: starting augmented merge for template \(template.name, privacy: .public)"
        )

        var route = "default route for meetingAugmentedMerge"
        var assembled = ""
        for try await delta in engine.stream(
            template: template, context: context, projectId: projectID, steer: steer
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
                Loggers.meeting.error(
                    "MeetingNotesMerger: merge failed: \(err.localizedDescription, privacy: .public)"
                )
                throw err
            }
        }
        return FileSummaryResult(markdown: assembled, routeDescription: route)
    }

    /// Returns the transcript to feed into the merge.
    ///
    /// When the transcript is
    /// short (≤ `condenseThreshold`) or no direct router is available, the
    /// transcript is returned unchanged. Otherwise it is condensed via
    /// `HierarchicalNotesSummarizer`: each chunk is summarized through the
    /// router, then the chunk-summaries are joined into a single condensed
    /// transcript. On any condensation failure we fall back to the original
    /// transcript so a long meeting still produces a note (the merge step will
    /// apply its own `SmartCap` trimming downstream).
    private func condenseIfNeeded(_ transcript: String) async throws -> String {
        guard transcript.count > Self.condenseThreshold, let router else {
            return transcript
        }
        Loggers.meeting.info(
            "MeetingNotesMerger: transcript \(transcript.count, privacy: .public) chars exceeds threshold; condensing via map-reduce"
        )
        do {
            return try await HierarchicalNotesSummarizer().condense(
                transcript,
                summarizeChunk: { chunk, index in
                    try await Self.summarizeChunk(chunk, index: index, router: router)
                },
                synthesize: { summaries in
                    // Join the per-chunk summaries in order into a single
                    // condensed transcript; the merge LLM treats this as the
                    // (still untrusted) transcript source.
                    summaries.joined(separator: "\n\n")
                }
            )
        } catch {
            Loggers.meeting.error(
                "MeetingNotesMerger: condensation failed, falling back to raw transcript: \(error.localizedDescription, privacy: .public)"
            )
            return transcript
        }
    }

    /// Summarizes a single transcript chunk via the router, collecting the
    /// streamed deltas into one string.
    ///
    /// Routes through `.meetingSummary`, the
    /// same task class the live rolling summary uses.
    private static func summarizeChunk(
        _ chunk: String, index: Int, router: any ModelRoutingFacade
    ) async throws -> String {
        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: chunkSummaryPrompt),
                LLMMessage(role: .user, content: AntiInjectionGuard.wrap(chunk, source: .transcript)),
            ],
            taskClass: .meetingSummary,
            temperature: 0.2
        )
        var summary = ""
        for try await delta in router.stream(request, routeOverride: nil) {
            summary += delta.textIncrement
            if delta.isFinal { break }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let chunkSummaryPrompt = """
        You are a meeting transcript condensation function — NOT a chat assistant. \
        Summarize the transcript segment below into a faithful, compact set of bullet \
        points capturing decisions, open questions, action items, and key facts. \
        Summarize only what the segment states; do not invent, speculate, or address \
        the participants. Preserve speaker attribution where it matters. Be concise.
        """
}
