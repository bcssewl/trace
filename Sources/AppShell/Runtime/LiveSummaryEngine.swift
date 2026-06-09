import Foundation
import SharedCore

/// A throttled rolling meeting summary engine. As utterances stream in during a
/// live meeting it accumulates them into a transcript buffer, then — on a
/// configurable cadence — asks the routing facade for a concise rolling summary
/// (Decisions / Open Questions / Action Items) and emits it via `onSummary`
/// with `isFinal: false`. On stop, `finalize` forces one last summary tagged
/// `isFinal: true`.
///
/// Memory is bounded for multi-hour meetings: once the buffered transcript
/// exceeds `maxBufferChars`, the most recent emitted summary is carried forward
/// as condensed context for the earlier discussion and the raw lines are
/// released. Every summary therefore still covers the whole meeting so far —
/// "summary of the meeting so far + new transcript" is the rolling window.
/// A hard cap (2 × `maxBufferChars`) bounds the pathological case where the
/// model keeps failing, by dropping the oldest raw lines.
///
/// Fully decoupled from the UI: the only output channel is the injected
/// `onSummary` closure, which the orchestrator wires to the AI-Summary column.
///
/// Routed via the `ModelRoutingFacade` seam (the `.meetingSummary`
/// `LLMTaskClass`), so it is user-routable and testable with a scripted router.
/// The transcript is untrusted external content and is wrapped through
/// `AntiInjectionGuard` before being sent, exactly like `MeetingNotesMerger`.
/// When no router is supplied or the model call throws, the engine logs and
/// silently does nothing — it never emits a partial or final summary in that
/// case.
public actor LiveSummaryEngine {
    private let router: (any ModelRoutingFacade)?
    private let cadenceSeconds: Double
    /// Soft bound on the buffered raw transcript (characters). Crossing it
    /// triggers compaction into `carriedSummary` after the next successful
    /// summary; 2× this is the hard cap enforced even when the model fails.
    private let maxBufferChars: Int
    private let onSummary: @Sendable (_ text: String, _ isFinal: Bool) async -> Void

    /// Accumulated "speaker: text" lines since the last compaction.
    private var transcript: [String] = []
    /// Running character count of `transcript` (lines + joining newlines), kept
    /// incrementally so `noteUtterance` stays O(1).
    private var bufferChars: Int = 0
    /// Condensed context for everything already released from `transcript`: the
    /// last emitted rolling summary (which covered the entire meeting up to that
    /// point). Empty until the first compaction.
    private var carriedSummary: String = ""
    /// Set when new utterances have arrived since the last successful summary.
    private var hasNewContent: Bool = false
    /// Timestamp of the last run that produced an emitted summary (or attempt).
    private var lastRun: Date?
    /// Consecutive failed ticks — gates the staleness notice to once per streak.
    private var failureStreak = 0
    /// Optional health hook: called with a plain notice string when ticks start
    /// failing (the rolling summary is going stale — the column would otherwise
    /// just quietly freeze), and with nil when a later tick succeeds again.
    public var onHealthNotice: (@Sendable (String?) async -> Void)?

    /// Set the health hook after construction (actor-isolated property).
    public func setOnHealthNotice(_ hook: @escaping @Sendable (String?) async -> Void) {
        onHealthNotice = hook
    }

    public init(
        router: (any ModelRoutingFacade)?,
        cadenceSeconds: Double = 60,
        maxBufferChars: Int = 16_000,
        onSummary: @escaping @Sendable (_ text: String, _ isFinal: Bool) async -> Void
    ) {
        self.router = router
        self.cadenceSeconds = cadenceSeconds
        self.maxBufferChars = max(1, maxBufferChars)
        self.onSummary = onSummary
    }

    /// Clear all accumulated state.
    ///
    /// Call when a new meeting begins.
    public func reset() {
        transcript.removeAll()
        bufferChars = 0
        carriedSummary = ""
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
        bufferChars += line.count + (transcript.count > 1 ? 1 : 0)
        hasNewContent = true
        enforceHardCap()
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
        guard !transcript.isEmpty || !carriedSummary.isEmpty else { return }
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

    // MARK: - Test seams (internal; visible via @testable)

    var bufferedCharCount: Int { bufferChars }
    var bufferedLineCount: Int { transcript.count }
    var carriedContext: String { carriedSummary }

    // MARK: - Internals

    /// Hard bound: when the model has been failing (no compaction via emitted
    /// summaries), drop the oldest raw lines once the buffer doubles the soft
    /// bound, so a multi-hour meeting can never grow memory without limit.
    /// Loud in the log; the truncation is also stated in the carried context so
    /// later summaries don't silently pretend to cover the lost stretch.
    private func enforceHardCap() {
        guard bufferChars > maxBufferChars * 2 else { return }
        var dropped = 0
        while bufferChars > maxBufferChars, transcript.count > 1 {
            let removed = transcript.removeFirst()
            bufferChars -= removed.count + 1
            dropped += 1
        }
        if carriedSummary.isEmpty {
            carriedSummary =
                "(The earliest part of the meeting could not be summarised in time and has been dropped from the rolling-summary buffer.)"
        }
        Loggers.meeting.warning(
            "LiveSummaryEngine: hard cap hit — dropped \(dropped, privacy: .public) oldest transcript line(s); rolling summaries were not landing"
        )
    }

    private func run(now: Date, isFinal: Bool) async {
        let body = transcript.joined(separator: "\n")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !carriedSummary.isEmpty else { return }

        guard let router else {
            Loggers.meeting.info("LiveSummaryEngine: no router configured, skipping summary")
            return
        }

        // The carried summary is app-generated (model output), so — like
        // `conversationState` in MeetingNotesMerger — it is presented as context
        // rather than wrapped. The raw transcript is untrusted external content
        // and is always wrapped.
        var userSections: [String] = []
        if !carriedSummary.isEmpty {
            userSections.append(
                "SUMMARY OF THE MEETING SO FAR (earlier transcript, already condensed):\n\(carriedSummary)"
            )
        }
        if !trimmed.isEmpty {
            userSections.append(AntiInjectionGuard.wrap(trimmed, source: .transcript))
        }

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: Self.systemPrompt(isFinal: isFinal)),
                LLMMessage(role: .user, content: userSections.joined(separator: "\n\n")),
            ],
            taskClass: .meetingSummary,
            temperature: 0.2
        )

        do {
            var text = ""
            for try await delta in router.stream(request, routeOverride: nil) {
                text += delta.textIncrement
                if delta.isFinal { break }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Advance the cadence clock and clear the new-content flag regardless
            // of whether the result was usable, so an empty model reply doesn't
            // cause a tight retry loop on the next tick.
            lastRun = now
            hasNewContent = false
            guard !text.isEmpty else {
                Loggers.meeting.info("LiveSummaryEngine: empty summary from router, not emitting")
                return
            }
            // Compaction: the emitted summary covers the entire meeting so far
            // (carried context + buffered lines), so once the raw buffer is over
            // budget it can be released and replaced by this summary.
            if bufferChars > maxBufferChars {
                carriedSummary = text
                transcript.removeAll()
                bufferChars = 0
            }
            Loggers.meeting.info(
                "LiveSummaryEngine summary (final=\(isFinal, privacy: .public)) emitted (\(text.count, privacy: .public) chars)"
            )
            if failureStreak > 0 {
                failureStreak = 0
                await onHealthNotice?(nil)
            }
            await onSummary(text, isFinal)
        } catch {
            Loggers.meeting.warning(
                "LiveSummaryEngine summary failed, skipping: \(String(describing: error), privacy: .public)"
            )
            // The column silently freezing is exactly the ghost-staleness the
            // product rules forbid — say it once per streak, clear on recovery.
            failureStreak += 1
            if failureStreak == 1 {
                await onHealthNotice?(
                    "Live summary paused — its model isn't responding, so this column may fall behind."
                )
            }
        }
    }

    private static func systemPrompt(isFinal: Bool) -> String {
        let framing =
            isFinal
            ? "The meeting has ended. Produce the final summary of the entire meeting."
            : "The meeting is ongoing. Produce a concise rolling summary of the meeting so far."
        return """
            You are a meeting summarization function — NOT a chat assistant. \(framing)

            The user's message contains a running speaker-attributed transcript, and may \
            also begin with a condensed summary of the earlier part of the meeting. When \
            that condensed summary is present, merge it with the new transcript so your \
            output covers the ENTIRE meeting so far. Summarize only what the transcript \
            and condensed summary state; do not invent, speculate, or address the \
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
