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
        await throttle.reset()
        await embeddingDetector.setProjectScope(projectID)
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
        // pipeline — regex hits + manual triggers must still surface cards.
        let embedding: EmbeddingDetector.Result
        do {
            embedding = try await embeddingDetector.evaluate(
                utterance: utterance.text, windowText: windowText
            )
        } catch {
            embedding = EmbeddingDetector.Result(topHits: [], topScore: 0, topicShifted: false)
        }
        if regexHits.isEmpty && embedding.topScore < EmbeddingDetector.topicShiftCosineThreshold
            && !utterance.userRequested
        {
            return PipelineResult(
                utterance: utterance, regexHits: regexHits,
                embeddingResult: embedding, classification: .none,
                routingOutput: nil, card: nil, throttleDecision: nil
            )
        }
        let classification = try await classifier.classify(
            utterance: utterance.text, regexHits: regexHits
        )
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
        let routing = try await smartRouter.decide(routingInput)
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
