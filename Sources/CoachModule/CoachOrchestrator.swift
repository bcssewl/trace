import Foundation
import SharedCore

public actor CoachOrchestrator {

    public struct PipelineResult: Sendable, Hashable {
        public let utterance: CoachUtterance
        public let regexHits: Set<RegexDetector.Marker>
        public let embeddingResult: EmbeddingDetector.Result?
        public let classification: UtteranceClass
        public let routingOutput: SmartRoutingOutput?
        public let card: CoachCard?
        public let throttleDecision: BurstDecayThrottle.Decision?

        public init(
            utterance: CoachUtterance,
            regexHits: Set<RegexDetector.Marker>,
            embeddingResult: EmbeddingDetector.Result?,
            classification: UtteranceClass,
            routingOutput: SmartRoutingOutput?,
            card: CoachCard?,
            throttleDecision: BurstDecayThrottle.Decision?
        ) {
            self.utterance = utterance
            self.regexHits = regexHits
            self.embeddingResult = embeddingResult
            self.classification = classification
            self.routingOutput = routingOutput
            self.card = card
            self.throttleDecision = throttleDecision
        }
    }

    private var config: CoachConfig
    private let embeddingDetector: EmbeddingDetector
    private let classifier: any UtteranceClassifying
    private let smartRouter: any SmartRouting
    private let throttle: BurstDecayThrottle
    private let antiFabChecker: (any AntiFabricationChecking)?
    private var conversationState: String = ""

    // MARK: Health events (loud failure surfacing)

    /// Live subscribers to `healthEvents()`.
    private var healthContinuations: [UUID: AsyncStream<CoachHealthEvent>.Continuation] = [:]
    /// Stages currently known to be failing — emission is edge-triggered off this
    /// set, so a dead model produces ONE `stageUnavailable` per outage (the rate
    /// limit), then ONE `stageRecovered` when it works again.
    private var failingHealthStages: Set<CoachPipelineStage> = []

    // MARK: Bounded in-flight ingestion (see `enqueue`)

    /// Hard cap on concurrently running auto-ingest pipelines. Each pipeline can
    /// hold several LLM calls (classifier + router + synthesis), so 2 in flight
    /// already means up to ~4–6 outstanding model calls in a fast meeting.
    /// Configurable via `CoachConfig.maxConcurrentIngests` (Advanced setting);
    /// clamped here so a bad persisted value can never unbound the load.
    private var maxConcurrentIngests: Int { min(4, max(1, config.maxConcurrentIngests)) }
    private var inFlightIngests = 0
    /// The single "next up" slot: when saturated, the NEWEST waiting utterance
    /// sits here and any previous occupant is superseded (latest-wins — for
    /// real-time help, fresher context always beats a backlog).
    private var pendingIngestWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    /// Cues superseded under load this meeting. Reset by `beginMeeting()`.
    public private(set) var skippedCueCount = 0
    /// Count of cards auto-surfaced in the current meeting — gated by
    /// `config.surfaceBudget`.
    ///
    /// Reset by `beginMeeting()`. Manual (user-requested)
    /// triggers neither count against nor respect the budget.
    private var surfacedThisMeeting = 0
    /// Anti-spam pacing for AUTO cards: a minimum gap between cards and a cap per
    /// rolling window, so the coach can't fire several back-to-back (the burst
    /// throttle allows zero spacing for "hot" utterances).
    ///
    /// Manual triggers exempt.
    private var lastAutoSurfaceAt: Date?
    private var recentAutoSurfaces: [Date] = []
    private static let minSecondsBetweenCards: TimeInterval = 25
    private static let maxCardsPerWindow = 2
    private static let cardWindowSeconds: TimeInterval = 180

    public init(
        config: CoachConfig = CoachConfig(),
        embeddingDetector: EmbeddingDetector,
        classifier: any UtteranceClassifying,
        smartRouter: any SmartRouting,
        throttle: BurstDecayThrottle = BurstDecayThrottle(),
        antiFabChecker: (any AntiFabricationChecking)? = nil
    ) {
        self.config = config
        self.embeddingDetector = embeddingDetector
        self.classifier = classifier
        self.smartRouter = smartRouter
        self.throttle = throttle
        self.antiFabChecker = antiFabChecker
    }

    public func updateConfig(_ next: CoachConfig) {
        self.config = next
    }

    /// Reset per-meeting state (the surface-budget counter, the throttle's pacing
    /// history, and the conversation-state digest) so each meeting starts fresh
    /// and a prior meeting's context never bleeds into the next.
    ///
    /// Call at meeting
    /// start.
    ///
    /// `projectID` scopes grounded retrieval to the current meeting's project (plus
    /// global playbooks): without it the coach searches EVERY past meeting across
    /// all projects and surfaces unrelated advice — e.g. work-meeting notes during a
    /// language lesson (BAS cross-meeting bleed). `nil` scopes to unfiled meetings +
    /// playbooks.
    public func beginMeeting(projectID: String? = nil) async {
        surfacedThisMeeting = 0
        lastAutoSurfaceAt = nil
        recentAutoSurfaces = []
        conversationState = ""
        skippedCueCount = 0
        // Fresh health baseline: a still-dead model re-emits its (single)
        // unavailable event on the new meeting's first failure.
        failingHealthStages = []
        await throttle.reset()
        await embeddingDetector.setProjectScope(projectID)
    }

    // MARK: Health events

    /// Subscribe to the orchestrator's health: per-stage model failures and
    /// recoveries, plus load-shedding notices.
    ///
    /// Emission is edge-triggered (one
    /// `stageUnavailable` per outage, one `stageRecovered` per recovery), so the
    /// subscriber can drive a banner directly without its own rate limiting.
    /// Multiple subscribers each get every event; a cancelled subscriber is
    /// cleaned up automatically.
    public func healthEvents() -> AsyncStream<CoachHealthEvent> {
        AsyncStream { continuation in
            let id = UUID()
            healthContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHealthContinuation(id) }
            }
        }
    }

    private func removeHealthContinuation(_ id: UUID) {
        healthContinuations[id] = nil
    }

    private func emitHealth(_ event: CoachHealthEvent) {
        for continuation in healthContinuations.values {
            continuation.yield(event)
        }
    }

    /// Record a stage failure; emits `stageUnavailable` only on the
    /// healthy→failing edge.
    private func noteStageFailure(_ stage: CoachPipelineStage, _ error: Error) {
        guard !failingHealthStages.contains(stage) else { return }
        failingHealthStages.insert(stage)
        emitHealth(.stageUnavailable(stage: stage, reason: String(describing: error)))
    }

    /// Record a stage success; emits `stageRecovered` only on the
    /// failing→healthy edge.
    private func noteStageSuccess(_ stage: CoachPipelineStage) {
        guard failingHealthStages.contains(stage) else { return }
        failingHealthStages.remove(stage)
        emitHealth(.stageRecovered(stage: stage))
    }

    // MARK: Bounded in-flight ingestion

    /// `ingest` behind a bounded in-flight policy for the AUTO path: at most
    /// `maxConcurrentIngests` pipelines run at once; when saturated the newest
    /// utterance waits in a single "next" slot and supersedes whatever was
    /// already waiting there (latest-wins — for real-time help a fresh cue beats
    /// a backlog).
    ///
    /// Returns nil when THIS utterance was superseded; that is never
    /// silent — the skip increments `skippedCueCount` and emits a
    /// `.cueSkipped` health event.
    ///
    /// Manual (`userRequested`) utterances bypass
    /// the cap entirely: the user explicitly asked for help right now, and they
    /// are rare enough not to threaten the load this cap exists to bound.
    public func enqueue(utterance: CoachUtterance, windowText: String? = nil) async throws -> PipelineResult? {
        if utterance.userRequested {
            return try await ingest(utterance: utterance, windowText: windowText)
        }
        guard await admitIngest() else {
            skippedCueCount += 1
            emitHealth(.cueSkipped(totalSkippedThisMeeting: skippedCueCount))
            return nil
        }
        defer { releaseIngestSlot() }
        return try await ingest(utterance: utterance, windowText: windowText)
    }

    /// Number of pipelines currently in flight via `enqueue` (test/diagnostic
    /// visibility for the cap).
    public var inFlightIngestCount: Int { inFlightIngests }
    /// Whether an utterance is waiting in the single "next" slot.
    public var hasQueuedCue: Bool { pendingIngestWaiter != nil }

    /// Take an ingest slot, waiting in the single latest-wins pending slot when
    /// saturated. Returns false when superseded by a newer utterance.
    private func admitIngest() async -> Bool {
        if inFlightIngests < maxConcurrentIngests {
            inFlightIngests += 1
            return true
        }
        // Saturated: occupy the pending slot, superseding any current occupant.
        if let superseded = pendingIngestWaiter {
            pendingIngestWaiter = nil
            superseded.continuation.resume(returning: false)
        }
        // Admission (true) arrives via slot transfer in `releaseIngestSlot`, so
        // the in-flight count is already accounted for — don't increment here.
        return await withCheckedContinuation { continuation in
            pendingIngestWaiter = (UUID(), continuation)
        }
    }

    private func releaseIngestSlot() {
        // Only transfer the slot while within the (possibly just-lowered) cap —
        // a mid-meeting cap reduction drains down to the new bound naturally.
        if inFlightIngests <= maxConcurrentIngests, let waiter = pendingIngestWaiter {
            // Transfer this slot to the waiter (count stays the same) — this
            // ordering means no third pipeline can slip in between release and
            // the waiter's resumption.
            pendingIngestWaiter = nil
            waiter.continuation.resume(returning: true)
        } else {
            inFlightIngests -= 1
        }
    }

    public func updateConversationState(_ next: String) {
        self.conversationState = next
    }

    public func ingest(utterance: CoachUtterance, windowText: String? = nil) async throws -> PipelineResult {
        guard config.enabled else {
            return PipelineResult(
                utterance: utterance, regexHits: [],
                embeddingResult: nil, classification: .none,
                routingOutput: nil, card: nil, throttleDecision: nil
            )
        }
        let regexHits = RegexDetector.detect(utterance.text)
        // Cheap substance gate BEFORE the expensive embedding (BAS-76 follow-up):
        // a throwaway backchannel ("yeah" / "ok" / "um" / "嗯") never produces a
        // useful card, but run per-utterance it drove the embedding storm that
        // cooked the machine. Skip it here so it never reaches the embedder or the
        // LLM. A regex marker (e.g. a question) or an explicit user trigger overrides.
        if !utterance.userRequested, regexHits.isEmpty, !Self.isSubstantive(utterance.text) {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: nil, classification: .none,
                routingOutput: nil, card: nil, throttleDecision: nil
            )
        }
        // RAG is optional infrastructure (embeddings route to Ollama). If it's
        // unavailable, degrade to "no RAG hits" rather than failing the whole
        // pipeline — regex hits + manual triggers must still surface cards. The
        // degradation is NOT silent: the first failure emits an
        // `embeddingUnavailable` health event so the overlay can say so.
        let embedding: EmbeddingDetector.Result
        do {
            embedding = try await embeddingDetector.evaluate(
                utterance: utterance.text, windowText: windowText
            )
            noteStageSuccess(.embedding)
        } catch {
            noteStageFailure(.embedding, error)
            embedding = EmbeddingDetector.Result(topHits: [], topScore: 0, topicShifted: false)
        }
        // Attention gate for the no-regex auto path: only an utterance whose top
        // RAG hit clears `ragAttentionMinCosine` earns the LLM stages. Note this
        // is deliberately stricter than the router's `synthesizableMinCosine` —
        // see CoachThresholds for the relationship.
        if regexHits.isEmpty && embedding.topScore < CoachThresholds.ragAttentionMinCosine
            && !utterance.userRequested
        {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: .none,
                routingOutput: nil, card: nil, throttleDecision: nil
            )
        }
        // The classifier and router are REQUIRED stages: a failure here means no
        // card can be produced, so classify it for the health stream (one event
        // per outage) and rethrow — the caller's catch stays in charge of the
        // per-utterance flow, but the failure is no longer invisible.
        let classification: UtteranceClass
        do {
            classification = try await classifier.classify(
                utterance: utterance.text, regexHits: regexHits
            )
            noteStageSuccess(.classifier)
        } catch {
            noteStageFailure(.classifier, error)
            throw error
        }
        if classification == .none && !utterance.userRequested {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: classification,
                routingOutput: nil, card: nil, throttleDecision: nil
            )
        }
        let routingInput = SmartRoutingInput(
            utterance: utterance.text, utteranceClass: classification,
            regexHits: regexHits, topRagHits: embedding.topHits,
            conversationState: conversationState, userRequested: utterance.userRequested,
            intent: utterance.intent
        )
        let routing: SmartRoutingOutput
        do {
            routing = try await smartRouter.decide(routingInput)
            noteStageSuccess(.router)
        } catch {
            noteStageFailure(.router, error)
            throw error
        }
        guard routing.mode != .silent, modeEnabled(routing.mode) else {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: classification,
                routingOutput: routing, card: nil, throttleDecision: nil
            )
        }
        // A non-silent card with no user-facing text (empty lead AND points AND
        // body) is a "ghost" — a fast model raising its hand with nothing to say.
        // Suppress it here instead of surfacing it: otherwise it would burn the
        // surface budget and bump the pill's count, while the overlay (which gates
        // display on the same emptiness) collapses to the pill showing nothing.
        guard Self.hasDisplayableContent(routing) else {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: classification,
                routingOutput: routing, card: nil, throttleDecision: nil
            )
        }
        // Apple FM (the default coach model) sometimes returns a guardrail refusal
        // ("I cannot help with that request") instead of a card — especially when
        // fed fragmented transcript. Suppress it rather than surface garbage; the
        // user can route coach card content to a different model in Settings (BAS-76).
        guard !Self.isLikelyRefusal(routing.title), !Self.isLikelyRefusal(routing.body),
            !Self.isLikelyRefusal(routing.lead)
        else {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: classification,
                routingOutput: routing, card: nil, throttleDecision: nil
            )
        }
        let questionDensity = regexHits.contains(.question) ? 1.0 : 0.0
        let kbRelevance = Double(embedding.topScore)
        let burstScore = BurstDecayThrottle.burstScore(
            questionDensity: questionDensity, kbRelevance: kbRelevance
        )
        // Adaptive throttle (BurstDecay) spaces cards by conversation heat. When
        // the user turns it off, every candidate passes the pacing gate (the
        // surface budget still applies). A manual trigger always overrides spacing.
        let decision: BurstDecayThrottle.Decision
        if config.adaptiveThrottle {
            decision = await throttle.evaluate(
                candidateScore: burstScore, userRequested: utterance.userRequested
            )
        } else {
            decision = BurstDecayThrottle.Decision(allow: true, tier: .hot, reason: "adaptive throttle off")
        }
        guard decision.allow else {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: classification,
                routingOutput: routing, card: nil, throttleDecision: decision
            )
        }
        // Per-meeting surface budget — a hard cap on auto-surfaced cards regardless
        // of triggers. A manual trigger (userRequested) ignores the cap: the user
        // explicitly asked for help right now.
        if !utterance.userRequested && surfacedThisMeeting >= config.surfaceBudget {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: classification,
                routingOutput: routing, card: nil, throttleDecision: decision
            )
        }
        // Minimum gap + per-window cap so auto cards can't fire back-to-back (the
        // burst throttle allows zero spacing for "hot" utterances). Manual triggers
        // bypass this — the user explicitly asked for help right now.
        if !utterance.userRequested {
            let now = utterance.timestamp
            let windowStart = now.addingTimeInterval(-Self.cardWindowSeconds)
            let tooSoon = lastAutoSurfaceAt.map { now.timeIntervalSince($0) < Self.minSecondsBetweenCards } ?? false
            let windowFull = recentAutoSurfaces.filter { $0 > windowStart }.count >= Self.maxCardsPerWindow
            if tooSoon || windowFull {
                return PipelineResult(
                    utterance: utterance, regexHits: regexHits,
                    embeddingResult: embedding, classification: classification,
                    routingOutput: routing, card: nil, throttleDecision: decision
                )
            }
        }
        // Optional anti-fabrication post-check on AI-authored cards (general /
        // synthesized). Grounded cards are verbatim playbook text, and reframe /
        // pacing / agenda assert no user-specific facts — so only the AI-authored
        // modes are verified. Fails open (the checker returns true on error), so it
        // never silently eats a card.
        if config.antiFabricationPostCheck,
            let antiFabChecker,
            routing.mode == .general || routing.mode == .synthesized
        {
            let support = antiFabricationSupport(windowText: windowText, hits: embedding.topHits)
            // Verify the user-facing claim text: prefer the new lead+points, fall
            // back to the legacy flat body.
            let claim =
                routing.lead.isEmpty && routing.points.isEmpty
                ? routing.body
                : ([routing.lead] + routing.points).joined(separator: " ")
            let grounded = await antiFabChecker.verify(claim: claim, support: support)
            if !grounded {
                return PipelineResult(
                    utterance: utterance, regexHits: regexHits,
                    embeddingResult: embedding, classification: classification,
                    routingOutput: routing, card: nil, throttleDecision: decision
                )
            }
        }
        let surface = Self.surface(for: routing.mode)
        let card = CoachCard(
            mode: routing.mode, title: routing.title,
            lead: routing.lead, points: routing.points, body: routing.body,
            attribution: routing.attribution, surface: surface,
            burstScore: burstScore, sourceChunkIds: routing.usedChunkIds,
            createdAt: utterance.timestamp
        )
        surfacedThisMeeting += 1
        if !utterance.userRequested {
            lastAutoSurfaceAt = utterance.timestamp
            let windowStart = utterance.timestamp.addingTimeInterval(-Self.cardWindowSeconds)
            recentAutoSurfaces = recentAutoSurfaces.filter { $0 > windowStart } + [utterance.timestamp]
        }
        return PipelineResult(
            utterance: utterance, regexHits: regexHits,
            embeddingResult: embedding, classification: classification,
            routingOutput: routing, card: card, throttleDecision: decision
        )
    }

    /// Whether a generated card is actually a model refusal (Apple FM's guardrail
    /// "I cannot help with that request" and friends) rather than coaching — so we
    /// suppress it instead of surfacing it as a card (BAS-76).
    static func isLikelyRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "i cannot help", "i can't help", "cannot help with that", "can't help with that",
            "unable to help", "unable to assist", "i cannot assist", "i can't assist",
            "i cannot answer", "i can't answer", "i'm not able to", "i am not able to",
            "i cannot provide", "i can't provide", "i'm sorry, but i cannot", "i'm sorry, i cannot",
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Whether a routing result has any text the overlay can actually show — a
    /// non-empty lead, body, or at least one non-blank point.
    ///
    /// Mirrors the overlay's
    /// `CoachCard.isEmpty` so the surface gate and the display gate agree.
    static func hasDisplayableContent(_ routing: SmartRoutingOutput) -> Bool {
        func blank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !blank(routing.lead) { return true }
        if !blank(routing.body) { return true }
        return routing.points.contains { !blank($0) }
    }

    /// Whether an utterance is worth spending an embedding + LLM on.
    ///
    /// Skips short
    /// backchannels / filler ("yeah", "ok", "um", "嗯", "对") that never produce a
    /// useful card but, run per-utterance, drove the embedding storm (BAS-76). Counts
    /// letters so it works for spaced AND non-spaced (CJK) languages; a regex marker
    /// or explicit user trigger bypasses this in `ingest`. Tunable.
    static func isSubstantive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let backchannels: Set<String> = [
            "yeah", "yep", "yes", "no", "ok", "okay", "uh", "um", "mm", "mhm", "hmm",
            "right", "sure", "cool", "nice", "exactly", "true", "got it", "i see",
            "嗯", "对", "好", "好的", "是", "是的", "对对", "嗯嗯",
        ]
        if backchannels.contains(trimmed) { return false }
        let letterCount = trimmed.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        return letterCount >= 12
    }

    /// Builds the support text the anti-fabrication checker verifies a card
    /// against: the recent transcript window plus the top retrieved playbook
    /// chunk texts.
    private func antiFabricationSupport(windowText: String?, hits: [VectorSearch.Hit]) -> String {
        var parts: [String] = []
        if let windowText, !windowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(windowText)
        }
        for hit in hits.prefix(4) {
            parts.append(hit.chunk.text)
        }
        return parts.joined(separator: "\n")
    }

    private func modeEnabled(_ mode: CoachCardMode) -> Bool {
        switch mode {
        case .grounded: return config.modes.grounded
        case .synthesized: return config.modes.synthesized
        case .general: return config.modes.general
        case .reframe: return config.modes.reframe
        case .agenda: return config.modes.agenda
        case .silent: return false
        }
    }

    private static func surface(for mode: CoachCardMode) -> CoachCardSurface {
        switch mode {
        case .agenda: return .interactive
        default: return .passive
        }
    }
}
