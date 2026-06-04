import Foundation
import SharedCore

/// Maintains a *rolling* conversation-state summary for a live meeting. Each
/// `update` re-summarizes from the prior state plus the latest transcript window,
/// so still-relevant open questions / tensions / decisions persist across the
/// whole meeting and the topic stays current — without ever sending the full
/// (unbounded) transcript to the model. Call `reset()` at meeting start.
public actor ConversationStateExtractor {
    private let model: any ConversationStateModeling
    /// The running state, carried across ticks as the prior context for the next
    /// update.
    ///
    /// Starts (and is reset to) `.empty`.
    private var current: ConversationStateModel = .empty

    public init(model: any ConversationStateModeling) {
        self.model = model
    }

    /// Clear the running state.
    ///
    /// Call at meeting start so a prior meeting's state
    /// never carries into the next.
    public func reset() {
        current = .empty
    }

    /// Roll the running state forward by merging the prior state with the latest
    /// transcript window.
    ///
    /// Updates and returns the new state; on a decode failure
    /// the prior state is left untouched (the last good state survives).
    public func update(withRecentTranscript transcript: String) async throws -> ConversationStateModel {
        let json = try await model.generateConversationStateJSON(
            prompt: Self.prompt(previous: current, transcript: transcript)
        )
        let next = try Self.decodeState(from: json)
        current = next
        return next
    }

    /// Builds the user prompt: the prior state (as a compact digest) plus the
    /// latest transcript.
    ///
    /// The model is instructed (via its system prompt) to merge
    /// them — carrying forward what still matters and dropping stale items. The
    /// transcript is anti-injection wrapped (BAS-33): it's untrusted meeting audio
    /// that flows into the digest and then the coach router prompt, so a participant
    /// can't smuggle instructions through it.
    static func prompt(previous: ConversationStateModel, transcript: String) -> String {
        let prior =
            previous.digest.isEmpty
            ? "(none yet — this is the first update)"
            : previous.digest
        return """
            Prior state:
            \(prior)

            Latest transcript:
            \(AntiInjectionGuard.wrap(transcript, source: .transcript))
            """
    }

    /// Decode the model's reply tolerantly (BAS-33): the full text first, else the
    /// outermost `{…}` span — so a routed model that wraps its JSON in code fences
    /// or prose still updates the state instead of silently skipping the tick.
    ///
    /// Throws (leaving the prior state intact) only when no JSON object is present.
    static func decodeState(from json: String) throws -> ConversationStateModel {
        if let state = JSONExtraction.decode(ConversationStateModel.self, from: json) {
            return state
        }
        // Nothing parseable — decode the raw text so the thrown error is meaningful
        // (the caller leaves the prior state intact on throw).
        return try JSONDecoder().decode(ConversationStateModel.self, from: Data(json.utf8))
    }
}
