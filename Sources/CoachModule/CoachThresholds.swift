import Foundation

/// The coach pipeline's tuning constants, gathered in one place so their
/// relationships are explicit instead of scattered magic numbers.
///
/// The pipeline spends money (LLM calls) in stages, and each constant below is a
/// gate on that spend or a pacing weight. The load-bearing relationships:
///
/// 1. `synthesizableMinCosine (0.50) ≤ ragAttentionMinCosine (0.55)`
///    The attention gate (does this utterance deserve an LLM at all, absent a
///    regex marker or manual trigger?) is deliberately STRICTER than the router's
///    synthesizable floor. Consequence: in the no-regex auto path, RAG hits in the
///    [0.50, 0.55) band never reach the router on their own — that band only
///    matters when a regex marker or a manual trigger has already justified the
///    call. This is intentional: a borderline embedding match alone is not worth
///    an LLM round-trip, but once one is happening anyway the router may as well
///    use a borderline hit.
///
/// 2. `ragAttentionMinCosine (0.55) < strongGroundedCosine (0.78)`
///    Between the two, hits are "synthesizable" (the router asks an LLM to write a
///    card from several of them); at/above `strongGroundedCosine` a single hit is
///    surfaced verbatim with no LLM rewrite. Verbatim surfacing demands a much
///    stronger match because a wrong verbatim dump is worse than a hedged
///    synthesis (BAS-76: raised from 0.7).
///
/// 3. Burst weights: `burstQuestionWeight (0.4) + burstKbWeight (0.6) = 1.0`,
///    so `burstScore` stays in [0, 1] and the tier cutoffs below are absolute.
///    Derived facts the tier cutoffs encode ON PURPOSE:
///    - KB relevance alone maxes the score at 0.6 < `burstHotThreshold` (0.7):
///      a document match without a question can never be "hot" (zero-spacing).
///    - A question alone scores 0.4 < `burstMediumThreshold` (0.5): a bare
///      question is "cold" (12 s spacing) unless the KB also lights up.
///    - A question + a strong grounded hit (1.0·0.4 + 0.78·0.6 ≈ 0.87) is
///      comfortably hot — the moment the coach exists for.
///
/// 4. `topicShiftCosine (0.55)` happens to equal `ragAttentionMinCosine` but is a
///    DIFFERENT comparison: it is the cosine between two consecutive
///    conversation-window embeddings (below it = the topic moved), not between an
///    utterance and the knowledge base. They are named separately so tuning one
///    never silently retunes the other.
public enum CoachThresholds {

    // MARK: Retrieval (utterance ↔ knowledge base cosine)

    /// Minimum cosine for a RAG hit to be worth feeding the router's
    /// synthesis prompt at all (`AppleFmSmartRouter`).
    public static let synthesizableMinCosine: Float = 0.50

    /// Minimum top-hit cosine for an utterance with NO regex marker and NO manual
    /// trigger to proceed past the cheap gates into the LLM stages
    /// (`CoachOrchestrator.ingest`). Stricter than `synthesizableMinCosine` —
    /// see relationship 1 above.
    public static let ragAttentionMinCosine: Float = 0.55

    /// Cosine above which a single hit is a verbatim grounded card (no LLM
    /// rewrite). See relationship 2 above.
    public static let strongGroundedCosine: Float = 0.78

    // MARK: Topic tracking (window ↔ previous window cosine)

    /// Below this cosine between consecutive conversation-window embeddings, the
    /// topic is considered to have shifted. Same value as
    /// `ragAttentionMinCosine` by coincidence, distinct knob by design — see
    /// relationship 4 above.
    public static let topicShiftCosine: Float = 0.55

    // MARK: Burst pacing (BurstDecayThrottle)

    /// Weight of question density in the burst score.
    public static let burstQuestionWeight: Double = 0.4
    /// Weight of knowledge-base relevance in the burst score.
    /// `burstQuestionWeight + burstKbWeight == 1` keeps the score in [0, 1].
    public static let burstKbWeight: Double = 0.6
    /// Above this burst score the throttle tier is hot (zero minimum spacing).
    public static let burstHotThreshold: Double = 0.7
    /// At or above this burst score (and ≤ hot) the tier is medium (4 s spacing);
    /// below it, cold (12 s spacing).
    public static let burstMediumThreshold: Double = 0.5
}
