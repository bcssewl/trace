import Foundation
import SharedCore

/// A throttled rolling meeting summary engine. As utterances stream in during a
/// live meeting it accumulates them into a transcript buffer, then — on a
/// configurable cadence — asks the `ModelRouter` for a concise rolling summary
/// (Decisions / Open Questions / Action Items) and emits it via `onSummary`
/// with `isFinal: false`. On stop, `finalize` forces one last summary tagged
/// `isFinal: true`.
///
/// Fully decoupled from the UI: the only output channel is the injected
/// `onSummary` closure, which the orchestrator wires to the AI-Summary column.
///
/// Uses the existing `.meetingSummary` `LLMTaskClass` route (see
/// `ModelRouter.defaultLLMRoutes`). When no router is supplied or the model
/// call throws, the engine logs and silently does nothing — it never emits a
/// partial or final summary in that case.
public actor LiveSummaryEngine {
    private let router: ModelRouter?
    private let cadenceSeconds: Double
    private let onSummary: @Sendable (_ text: String, _ isFinal: Bool) async -> Void

    /// Accumulated "speaker: text" lines for the meeting so far.
    private var transcript: [String] = []
    /// Set when new utterances have arrived since the last successful summary.
    private var hasNewContent: Bool = false
    /// Timestamp of the last run that produced an emitted summary (or attempt).
    private var lastRun: Date?

    public init(
        router: ModelRouter?,
        cadenceSeconds: Double = 60,
        onSummary: @escaping @Sendable (_ text: String, _ isFinal: Bool) async -> Void
    ) {
        self.router = router
        self.cadenceSeconds = cadenceSeconds
        self.onSummary = onSummary
    }

    /// Clear all accumulated state.
    ///
    /// Call when a new meeting begins.
    public func reset() {
        transcript.removeAll()
        hasNewContent = false
        lastRun = nil
    }

    /// Append one utterance to the rolling transcript and mark that there is new
    /// content to summarize on the next eligible tick.
    public func noteUtterance(speaker: String, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let trimmedSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmedSpeaker.isEmpty ? trimmedText : "\(trimmedSpeaker): \(trimmedText)"
        transcript.append(line)
        hasNewContent = true
    }

    /// Generate and emit a rolling (non-final) summary iff the cadence gate is
    /// open.
    ///
    /// No-op otherwise.
    public func tick(now: Date) async {
        guard
            Self.shouldSummarize(
                now: now,
                lastRun: lastRun,
                cadenceSeconds: cadenceSeconds,
                hasNewContent: hasNewContent
            )
        else { return }
        await run(now: now, isFinal: false)
    }

    /// Force a final summary if there is any content.
    ///
    /// Always attempts (bypasses
    /// the cadence gate) and emits with `isFinal: true` on a non-empty result.
    public func finalize(now: Date) async {
        guard !transcript.isEmpty else { return }
        await run(now: now, isFinal: true)
    }

    /// Pure, testable cadence gate.
    ///
    /// Returns `true` iff there is new content AND either this is the first run
    /// (`lastRun == nil`) or at least `cadenceSeconds` have elapsed since the
    /// last run.
    public static func shouldSummarize(
        now: Date,
        lastRun: Date?,
        cadenceSeconds: Double,
        hasNewContent: Bool
    ) -> Bool {
        guard hasNewContent else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= cadenceSeconds
    }

    // MARK: - Internals

    private func run(now: Date, isFinal: Bool) async {
        let body = transcript.joined(separator: "\n")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let router else {
            Loggers.meeting.info("LiveSummaryEngine: no router configured, skipping summary")
            return
        }

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: Self.systemPrompt(isFinal: isFinal)),
                LLMMessage(role: .user, content: trimmed),
            ],
            taskClass: .meetingSummary,
            temperature: 0.2
        )

        do {
            let response = try await router.generate(request)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Advance the cadence clock and clear the new-content flag regardless
            // of whether the result was usable, so an empty model reply doesn't
            // cause a tight retry loop on the next tick.
            lastRun = now
            hasNewContent = false
            guard !text.isEmpty else {
                Loggers.meeting.info(
                    "LiveSummaryEngine: empty summary from \(response.provider, privacy: .public), not emitting")
                return
            }
            Loggers.meeting.info(
                "LiveSummaryEngine summary (final=\(isFinal, privacy: .public)) via \(response.provider, privacy: .public)/\(response.model, privacy: .public)"
            )
            await onSummary(text, isFinal)
        } catch {
            Loggers.meeting.warning(
                "LiveSummaryEngine summary failed, skipping: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func systemPrompt(isFinal: Bool) -> String {
        let framing =
            isFinal
            ? "The meeting has ended. Produce the final summary of the entire transcript below."
            : "The meeting is ongoing. Produce a concise rolling summary of the transcript so far."
        return """
            You are a meeting summarization function — NOT a chat assistant. \(framing)

            The user's message is a running speaker-attributed transcript. Summarize \
            only what the transcript states; do not invent, speculate, or address the \
            participants. Be concise.

            Output exactly these three sections, each with bullet points (use "- (none yet)" \
            if a section is empty):

            Decisions
            - <decisions reached so far>

            Open Questions
            - <unresolved questions or topics still under discussion>

            Action Items
            - <concrete tasks, with owner if stated>
            """
    }
}
