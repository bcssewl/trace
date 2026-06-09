import Foundation
import XCTest
import os

@testable import CoachModule
@testable import SharedCore

private final class TestClock: @unchecked Sendable {
    private let box: OSAllocatedUnfairLock<Date>
    init(_ initial: Date) { self.box = OSAllocatedUnfairLock(initialState: initial) }
    var now: Date { box.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { box.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

final class CoachModuleTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(CoachModule.moduleName, "CoachModule")
    }
}

final class RegexDetectorTests: XCTestCase {
    func testDetectsQuestionMarker() {
        let hits = RegexDetector.detect("What does the discount look like?")
        XCTAssertTrue(hits.contains(.question))
    }

    func testDetectsCurrencyMarker() {
        let hits = RegexDetector.detect("We can offer $1,200/year for the seat license.")
        XCTAssertTrue(hits.contains(.currency))
    }

    func testDetectsCommitmentMarker() {
        let hits = RegexDetector.detect("I will send the SOC2 report by Friday.")
        XCTAssertTrue(hits.contains(.commitment))
    }

    func testDetectsObjectionMarker() {
        let hits = RegexDetector.detect("That sounds too expensive for our budget right now.")
        XCTAssertTrue(hits.contains(.objection))
    }

    func testPlainStatementHasNoHits() {
        let hits = RegexDetector.detect("Hello, nice to meet you.")
        XCTAssertTrue(hits.isEmpty || !hits.contains(.objection))
    }
}

final class BurstDecayThrottleTests: XCTestCase {
    func testHotTierAllowsImmediateSurface() async {
        let throttle = BurstDecayThrottle()
        let first = await throttle.evaluate(candidateScore: 0.9)
        let second = await throttle.evaluate(candidateScore: 0.95)
        XCTAssertTrue(first.allow)
        XCTAssertEqual(first.tier, .hot)
        XCTAssertTrue(second.allow)
    }

    func testColdTierRequiresSpacing() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let throttle = BurstDecayThrottle(clock: { clock.now })
        let first = await throttle.evaluate(candidateScore: 0.3)
        XCTAssertTrue(first.allow)
        XCTAssertEqual(first.tier, .cold)
        clock.advance(1)
        let second = await throttle.evaluate(candidateScore: 0.3)
        XCTAssertFalse(second.allow)
        clock.advance(15)
        let third = await throttle.evaluate(candidateScore: 0.3)
        XCTAssertTrue(third.allow)
    }

    func testStrongerCandidatePreempts() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let throttle = BurstDecayThrottle(clock: { clock.now })
        _ = await throttle.evaluate(candidateScore: 0.5)
        clock.advance(1)
        let stronger = await throttle.evaluate(candidateScore: 0.75)
        XCTAssertTrue(stronger.allow, "preempt rule: score+delta beats minimum spacing")
    }

    func testUserRequestedAlwaysAllows() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let throttle = BurstDecayThrottle(clock: { clock.now })
        _ = await throttle.evaluate(candidateScore: 0.9)
        let manual = await throttle.evaluate(candidateScore: 0.1, userRequested: true)
        XCTAssertTrue(manual.allow)
        XCTAssertTrue(manual.reason.contains("user-requested"))
    }

    func testBurstScoreFormula() {
        let score = BurstDecayThrottle.burstScore(questionDensity: 0.5, kbRelevance: 0.8)
        XCTAssertEqual(score, 0.5 * 0.4 + 0.8 * 0.6, accuracy: 0.0001)
    }
}

/// Pins the documented relationships between the pipeline's tuning constants
/// (CoachThresholds) so a future retune that breaks an invariant fails a test
/// pointing at the explanation, instead of silently changing behaviour.
final class CoachThresholdsTests: XCTestCase {
    /// Relationship 1: the no-regex attention gate is stricter than the router's
    /// synthesizable floor — the [floor, gate) band is reachable only when a
    /// regex marker or manual trigger already justified the LLM call.
    func testAttentionGateIsAtLeastAsStrictAsSynthesizableFloor() {
        XCTAssertGreaterThanOrEqual(
            CoachThresholds.ragAttentionMinCosine, CoachThresholds.synthesizableMinCosine)
    }

    /// Relationship 2: verbatim grounded surfacing demands a much stronger match
    /// than synthesis.
    func testStrongGroundedIsStricterThanAttentionGate() {
        XCTAssertGreaterThan(
            CoachThresholds.strongGroundedCosine, CoachThresholds.ragAttentionMinCosine)
    }

    /// Relationship 3: burst weights sum to 1 so the score stays in [0, 1] and
    /// the tier cutoffs are absolute.
    func testBurstWeightsSumToOne() {
        XCTAssertEqual(
            CoachThresholds.burstQuestionWeight + CoachThresholds.burstKbWeight, 1.0,
            accuracy: 0.0001)
    }

    /// Derived fact: KB relevance alone (even a perfect 1.0 match) can never make
    /// an utterance "hot" — zero-spacing is reserved for question moments.
    func testKbRelevanceAloneCannotReachHotTier() {
        let score = BurstDecayThrottle.burstScore(questionDensity: 0, kbRelevance: 1.0)
        XCTAssertLessThan(score, CoachThresholds.burstHotThreshold)
        XCTAssertEqual(BurstDecayThrottle.tier(forBurstScore: score), .medium)
    }

    /// Derived fact: a bare question with no KB signal is cold-tier (12 s
    /// spacing) — questions only get urgent when the knowledge base lights up.
    func testQuestionAloneIsColdTier() {
        let score = BurstDecayThrottle.burstScore(questionDensity: 1.0, kbRelevance: 0)
        XCTAssertLessThan(score, CoachThresholds.burstMediumThreshold)
        XCTAssertEqual(BurstDecayThrottle.tier(forBurstScore: score), .cold)
    }

    /// Derived fact: a question + a strong grounded hit is comfortably hot — the
    /// moment the coach exists for surfaces with zero spacing.
    func testQuestionWithStrongGroundedHitIsHotTier() {
        let score = BurstDecayThrottle.burstScore(
            questionDensity: 1.0, kbRelevance: Double(CoachThresholds.strongGroundedCosine))
        XCTAssertGreaterThan(score, CoachThresholds.burstHotThreshold)
        XCTAssertEqual(BurstDecayThrottle.tier(forBurstScore: score), .hot)
    }

    /// The legacy public constants forward to CoachThresholds — the single home —
    /// so tuning there is tuning everywhere.
    func testLegacyConstantsForwardToCoachThresholds() {
        XCTAssertEqual(EmbeddingDetector.topicShiftCosineThreshold, CoachThresholds.topicShiftCosine)
        XCTAssertEqual(AppleFmSmartRouter.strongGroundedCosine, CoachThresholds.strongGroundedCosine)
        XCTAssertEqual(AppleFmSmartRouter.synthesizableMinCosine, CoachThresholds.synthesizableMinCosine)
    }
}

actor CountingEmbeddingProvider: EmbeddingProvider {
    nonisolated let embeddingKind: EmbeddingProviderKind = .ollama
    var calls = 0
    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        calls += 1
        return texts.map { _ in [Float(1), 0, 0] }
    }
}

/// A `SmartRouting` test double that records the last `SmartRoutingInput` it
/// received, so tests can assert what context (e.g. conversation state) the
/// orchestrator fed into routing.
actor CapturingSmartRouter: SmartRouting {
    let outcome: SmartRoutingOutput
    private(set) var lastInput: SmartRoutingInput?
    init(outcome: SmartRoutingOutput) { self.outcome = outcome }
    func decide(_ input: SmartRoutingInput) async throws -> SmartRoutingOutput {
        lastInput = input
        return outcome
    }
}

final class CoachConfigCodableTests: XCTestCase {
    /// Conversation-state extraction defaults on (spec §5: stage default ON).
    func testDefaultConversationStateEnabledIsTrue() {
        XCTAssertTrue(CoachConfig().conversationStateEnabled)
    }

    /// Conversation-state refresh cadence defaults to 30s (spec §5/§407 "~30s").
    func testDefaultConversationStateIntervalIs30() {
        XCTAssertEqual(CoachConfig().conversationStateIntervalSeconds, 30)
    }

    /// Configs persisted before `conversationStateEnabled` existed must still
    /// decode — defaulting the new field to true and preserving every legacy
    /// field — rather than throwing and silently resetting the user's whole
    /// Coach config to defaults.
    ///
    /// NOTE the `"pacing"` key in the fixture: it is a DEAD key from the removed
    /// live-pacing mode (the owner cut pacing/talk-time coaching entirely). It is
    /// kept here deliberately — a real persisted config from that era contains
    /// it, and the tolerant decoder must keep ignoring it forever. The explicit
    /// contract is pinned by `testUnknownKeysAreIgnoredOnPurpose` below.
    func testDecodesLegacyJSONWithoutConversationStateField() throws {
        let legacy = """
            {"enabled":true,"surfaceBudget":5,"adaptiveThrottle":false,"antiFabricationPostCheck":true,
             "modes":{"grounded":false,"synthesized":true,"general":true,"reframe":true,"pacing":true,"agenda":true},
             "manualTrigger":{"enabled":true,"modifierKeyCode":61,"tapCount":3,"windowMilliseconds":500}}
            """
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(cfg.conversationStateEnabled, "missing field must default to true")
        XCTAssertEqual(cfg.conversationStateIntervalSeconds, 30, "missing interval must default to 30")
        XCTAssertEqual(cfg.surfaceBudget, 5)
        XCTAssertFalse(cfg.adaptiveThrottle)
        XCTAssertTrue(cfg.antiFabricationPostCheck)
        XCTAssertFalse(cfg.modes.grounded)
    }

    /// The contract the legacy fixture above relies on, stated explicitly:
    /// unknown keys — both top-level and inside `modes` — are ignored ON
    /// PURPOSE. That's what lets a config written by an older build (with since-
    /// removed features like the pacing mode) or a NEWER build (with fields this
    /// build doesn't know yet) decode cleanly instead of resetting the user's
    /// Coach config. Known fields must decode unaffected by the strangers
    /// around them.
    func testUnknownKeysAreIgnoredOnPurpose() throws {
        let json = """
            {"enabled":true,"surfaceBudget":3,"someFutureTopLevelKey":42,
             "modes":{"grounded":true,"synthesized":false,"general":true,"reframe":true,"agenda":true,
                      "pacing":true,"someFutureMode":false}}
            """
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(json.utf8))
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.surfaceBudget, 3)
        XCTAssertTrue(cfg.modes.grounded)
        XCTAssertFalse(cfg.modes.synthesized, "known mode values must survive unknown siblings")
        XCTAssertTrue(cfg.modes.agenda)
    }

    func testConversationStateEnabledRoundTrips() throws {
        var cfg = CoachConfig()
        cfg.conversationStateEnabled = false
        let decoded = try JSONDecoder().decode(CoachConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertFalse(decoded.conversationStateEnabled)
    }
}

final class CoachOrchestratorTests: XCTestCase {
    private var tempDir: URL!
    private var db: SqliteDatabase!
    private var cache: KbCache!
    private var embedder: EmbeddingClient!
    private var vectorSearch: VectorSearch!
    private let cfg = EmbeddingConfig(
        provider: "ollama",
        baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text",
        normalization: .unitL2
    )

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("c.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        cache = KbCache(db: db)
        let router = ModelRouter()
        await router.register(provider: CountingEmbeddingProvider())
        embedder = EmbeddingClient(router: router, config: cfg)
        vectorSearch = VectorSearch(cache: cache, config: cfg)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    func testDisabledCoachReturnsEmptyResult() async throws {
        var config = CoachConfig()
        config.enabled = false
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let orchestrator = CoachOrchestrator(
            config: config, embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: ScriptedSmartRouter(outcome: groundedOutput())
        )
        let result = try await orchestrator.ingest(
            utterance: CoachUtterance(speakerId: "remote_1", text: "What is the price?")
        )
        XCTAssertNil(result.card)
    }

    func testNoSignalsAndNoUserRequestProducesNoCard() async throws {
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let orchestrator = CoachOrchestrator(
            embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .none),
            smartRouter: ScriptedSmartRouter(outcome: silentOutput())
        )
        let result = try await orchestrator.ingest(
            utterance: CoachUtterance(speakerId: "remote_1", text: "Hello.")
        )
        XCTAssertNil(result.card)
    }

    func testStrongRagHitProducesGroundedCard() async throws {
        let chunk = KbChunk(sourceFile: "sales.md", breadcrumb: "Pricing", text: "Annual is $1,200.", sourceSha256: "h")
        let normalized = EmbeddingClient.unitL2([1, 0, 0])
        try await cache.upsert(
            chunk: chunk,
            embedding: KbEmbedding(chunkId: chunk.id, vector: normalized, configFingerprint: cfg.fingerprint),
            config: cfg
        )
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let orchestrator = CoachOrchestrator(
            embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: ScriptedSmartRouter(
                outcome: SmartRoutingOutput(
                    mode: .grounded, title: "Pricing", body: "Annual is $1,200.",
                    attribution: "playbook · sales.md", usedChunkIds: [chunk.id]
                ))
        )
        let result = try await orchestrator.ingest(
            utterance: CoachUtterance(speakerId: "remote_1", text: "What is the annual price?")
        )
        XCTAssertNotNil(result.card)
        XCTAssertEqual(result.card?.mode, .grounded)
        XCTAssertEqual(result.card?.surface, .passive)
        XCTAssertEqual(result.card?.sourceChunkIds, [chunk.id])
    }

    func testManualTriggerForcesCardEvenWithLowSignal() async throws {
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let orchestrator = CoachOrchestrator(
            embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: ScriptedSmartRouter(
                outcome: SmartRoutingOutput(
                    mode: .reframe, title: "Reframe", body: "Consider asking about scope.",
                    attribution: "AI · suggested framing", usedChunkIds: []
                ))
        )
        let result = try await orchestrator.ingest(
            utterance: CoachUtterance(
                speakerId: "you", text: "Hmm.", userRequested: true
            )
        )
        XCTAssertNotNil(result.card)
        XCTAssertEqual(result.card?.mode, .reframe)
    }

    func testDisabledModeSuppressesEvenStrongCandidate() async throws {
        var config = CoachConfig()
        config.modes.grounded = false
        let chunk = KbChunk(sourceFile: "x.md", breadcrumb: "S", text: "data.", sourceSha256: "h")
        let normalized = EmbeddingClient.unitL2([1, 0, 0])
        try await cache.upsert(
            chunk: chunk,
            embedding: KbEmbedding(chunkId: chunk.id, vector: normalized, configFingerprint: cfg.fingerprint),
            config: cfg
        )
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let orchestrator = CoachOrchestrator(
            config: config, embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: ScriptedSmartRouter(
                outcome: SmartRoutingOutput(
                    mode: .grounded, title: "S", body: "data.",
                    attribution: "playbook · x.md", usedChunkIds: [chunk.id]
                ))
        )
        let result = try await orchestrator.ingest(
            utterance: CoachUtterance(speakerId: "remote_1", text: "What is X?")
        )
        XCTAssertNil(result.card)
    }

    /// The conversation-state digest fed via `updateConversationState` must reach
    /// the smart router as `SmartRoutingInput.conversationState` (the seam BAS-16's
    /// ~30s extractor ticker feeds).
    func testConversationStateFlowsIntoRouting() async throws {
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let router = CapturingSmartRouter(outcome: silentOutput())
        let orchestrator = CoachOrchestrator(
            config: CoachConfig(), embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: router
        )
        await orchestrator.updateConversationState("Topic: pricing")
        _ = try await orchestrator.ingest(
            utterance: CoachUtterance(speakerId: "remote_1", text: "What discount can you do?", userRequested: true)
        )
        let captured = await router.lastInput
        XCTAssertEqual(captured?.conversationState, "Topic: pricing")
    }

    /// Conversation state is per-meeting context; `beginMeeting()` must clear it so
    /// a prior meeting's state never bleeds into the next one's routing prompts.
    func testBeginMeetingResetsConversationState() async throws {
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let router = CapturingSmartRouter(outcome: silentOutput())
        let orchestrator = CoachOrchestrator(
            config: CoachConfig(), embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: router
        )
        await orchestrator.updateConversationState("stale state from a previous meeting")
        await orchestrator.beginMeeting()
        _ = try await orchestrator.ingest(
            utterance: CoachUtterance(speakerId: "remote_1", text: "What discount can you do?", userRequested: true)
        )
        let captured = await router.lastInput
        XCTAssertEqual(
            captured?.conversationState, "",
            "beginMeeting() must clear stale conversation state so it never bleeds across meetings"
        )
    }

    /// A directed "Ask the coach" intent must flow through the orchestrator into
    /// the SmartRouter input so the prompt can be steered per intent.
    func testDirectedIntentFlowsIntoRouting() async throws {
        let detector = EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch)
        let router = CapturingSmartRouter(outcome: silentOutput())
        let orchestrator = CoachOrchestrator(
            config: CoachConfig(), embeddingDetector: detector,
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: router
        )
        _ = try await orchestrator.ingest(
            utterance: CoachUtterance(
                speakerId: "you", text: "Walk me through the pricing again.",
                userRequested: true, intent: .factCheck
            )
        )
        let captured = await router.lastInput
        XCTAssertEqual(captured?.intent, .factCheck)
    }

    private func groundedOutput() -> SmartRoutingOutput {
        SmartRoutingOutput(
            mode: .grounded, title: "T", body: "B",
            attribution: "A", usedChunkIds: []
        )
    }

    private func silentOutput() -> SmartRoutingOutput {
        SmartRoutingOutput(
            mode: .silent, title: "", body: "",
            attribution: "", usedChunkIds: []
        )
    }
}
