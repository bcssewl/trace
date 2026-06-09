import Foundation
import XCTest

@testable import CoachModule
@testable import SharedCore

// MARK: - Test doubles

private struct StageError: Error, CustomStringConvertible {
    let description = "scripted stage failure"
}

/// A classifier whose failure mode can be toggled mid-test.
private actor ToggleClassifier: UtteranceClassifying {
    var failing: Bool
    init(failing: Bool) { self.failing = failing }
    func setFailing(_ value: Bool) { failing = value }
    func classify(utterance: String, regexHits: Set<RegexDetector.Marker>) async throws -> UtteranceClass {
        if failing { throw StageError() }
        return .question
    }
}

private struct FailingSmartRouter: SmartRouting {
    func decide(_ input: SmartRoutingInput) async throws -> SmartRoutingOutput {
        throw StageError()
    }
}

/// An embedding provider whose failure mode can be toggled mid-test.
private actor ToggleEmbeddingProvider: EmbeddingProvider {
    nonisolated let embeddingKind: EmbeddingProviderKind = .ollama
    var failing: Bool
    init(failing: Bool) { self.failing = failing }
    func setFailing(_ value: Bool) { failing = value }
    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        if failing { throw StageError() }
        return texts.map { _ in [Float(1), 0, 0] }
    }
}

/// Collects health events off the orchestrator's stream for assertion.
actor HealthEventCollector {
    private(set) var events: [CoachHealthEvent] = []
    func append(_ event: CoachHealthEvent) { events.append(event) }
}

/// Polls `condition` until true or the timeout elapses; returns the final state.
func waitUntil(
    timeoutSeconds: TimeInterval = 5, _ condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

// MARK: - Orchestrator health emission

final class CoachOrchestratorHealthTests: XCTestCase {
    private var tempDir: URL!
    private var db: SqliteDatabase!
    private var cache: KbCache!
    private var vectorSearch: VectorSearch!
    private let cfg = EmbeddingConfig(
        provider: "ollama",
        baseURL: URL(string: "http://localhost:11434"),
        model: "nomic-embed-text",
        normalization: .unitL2
    )

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coach-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("c.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await SchemaV19.bootstrap(database: db)
        cache = KbCache(db: db)
        vectorSearch = VectorSearch(cache: cache, config: cfg)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeEmbedder(provider: any EmbeddingProvider) async -> EmbeddingClient {
        let router = ModelRouter()
        await router.register(provider: provider)
        return EmbeddingClient(router: router, config: cfg)
    }

    private func manualUtterance(_ text: String = "What does the annual pricing look like?") -> CoachUtterance {
        CoachUtterance(speakerId: "you", text: text, userRequested: true)
    }

    /// A dead classifier emits exactly ONE `stageUnavailable(.classifier)` no
    /// matter how many utterances fail — the rate limit — and exactly one
    /// `stageRecovered` once it works again.
    func testClassifierOutageEmitsOneUnavailableThenOneRecovered() async throws {
        let classifier = ToggleClassifier(failing: true)
        let embedder = await makeEmbedder(provider: ToggleEmbeddingProvider(failing: false))
        let orchestrator = CoachOrchestrator(
            embeddingDetector: EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch),
            classifier: classifier,
            smartRouter: ScriptedSmartRouter(
                outcome: SmartRoutingOutput(
                    mode: .general, title: "T", lead: "Say this.", attribution: "AI", usedChunkIds: []
                ))
        )
        let collector = HealthEventCollector()
        let stream = await orchestrator.healthEvents()
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        for _ in 0..<3 {
            do {
                _ = try await orchestrator.ingest(utterance: manualUtterance())
                XCTFail("ingest must rethrow the classifier failure")
            } catch { /* expected — failure is surfaced via the health stream */  }
        }
        await classifier.setFailing(false)
        _ = try await orchestrator.ingest(utterance: manualUtterance())

        let settled = await waitUntil { await collector.events.count >= 2 }
        XCTAssertTrue(settled, "expected unavailable + recovered events")
        let events = await collector.events
        XCTAssertEqual(events.count, 2, "edge-triggered: one event per outage, one per recovery — got \(events)")
        guard case .stageUnavailable(let stage, _) = events[0] else {
            return XCTFail("first event must be stageUnavailable, got \(events[0])")
        }
        XCTAssertEqual(stage, .classifier)
        XCTAssertEqual(events[1], .stageRecovered(stage: .classifier))
    }

    /// A dead router (the second LLM stage) is classified as `.router`, not
    /// blamed on the classifier.
    func testRouterOutageEmitsRouterUnavailable() async throws {
        let embedder = await makeEmbedder(provider: ToggleEmbeddingProvider(failing: false))
        let orchestrator = CoachOrchestrator(
            embeddingDetector: EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch),
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: FailingSmartRouter()
        )
        let collector = HealthEventCollector()
        let stream = await orchestrator.healthEvents()
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        do {
            _ = try await orchestrator.ingest(utterance: manualUtterance())
            XCTFail("ingest must rethrow the router failure")
        } catch { /* expected */  }

        let settled = await waitUntil { await collector.events.isEmpty == false }
        XCTAssertTrue(settled)
        let events = await collector.events
        guard case .stageUnavailable(let stage, _) = events[0] else {
            return XCTFail("expected stageUnavailable, got \(events[0])")
        }
        XCTAssertEqual(stage, .router)
    }

    /// Embedding failure keeps its graceful degrade — the pipeline continues and
    /// a card still surfaces — but the degrade is no longer silent: the FIRST
    /// failure emits `stageUnavailable(.embedding)` (and only the first).
    func testEmbeddingOutageDegradesGracefullyButEmitsOnce() async throws {
        let provider = ToggleEmbeddingProvider(failing: true)
        let embedder = await makeEmbedder(provider: provider)
        let orchestrator = CoachOrchestrator(
            embeddingDetector: EmbeddingDetector(embedder: embedder, vectorSearch: vectorSearch),
            classifier: ScriptedUtteranceClassifier(outcome: .question),
            smartRouter: ScriptedSmartRouter(
                outcome: SmartRoutingOutput(
                    mode: .reframe, title: "Reframe", lead: "Ask about scope.",
                    attribution: "AI", usedChunkIds: []
                ))
        )
        let collector = HealthEventCollector()
        let stream = await orchestrator.healthEvents()
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        let first = try await orchestrator.ingest(utterance: manualUtterance())
        XCTAssertNotNil(first.card, "embedding failure must degrade, not kill the card")
        let second = try await orchestrator.ingest(utterance: manualUtterance("And the seat licence terms?"))
        XCTAssertNotNil(second.card)

        let settled = await waitUntil { await collector.events.isEmpty == false }
        XCTAssertTrue(settled)
        let events = await collector.events
        XCTAssertEqual(events.count, 1, "two failing ingests, ONE embedding event — got \(events)")
        guard case .stageUnavailable(let stage, _) = events[0] else {
            return XCTFail("expected stageUnavailable, got \(events[0])")
        }
        XCTAssertEqual(stage, .embedding)

        // Recovery emits exactly once too.
        await provider.setFailing(false)
        _ = try await orchestrator.ingest(utterance: manualUtterance("What about onboarding time?"))
        let recovered = await waitUntil { await collector.events.count >= 2 }
        XCTAssertTrue(recovered)
        let all = await collector.events
        XCTAssertEqual(all.last, .stageRecovered(stage: .embedding))
    }
}

// MARK: - Banner model (dismissal + rate-limit rules)

final class CoachHealthBannerModelTests: XCTestCase {
    func testHealthyHasNoMessage() {
        XCTAssertNil(CoachHealthBannerModel().activeMessage)
    }

    func testModelStageFailureShowsPausedMessageInBritishEnglish() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .classifier, reason: "x"))
        XCTAssertEqual(model.activeMessage, "Coach paused — model unavailable. Check Settings → Models.")
    }

    func testEmbeddingOnlyFailureShowsDegradedMessage() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .embedding, reason: "x"))
        XCTAssertEqual(
            model.activeMessage,
            "Coach can't search your documents — automatic cues are limited to obvious triggers, and asking directly still works. Check Settings → Models."
        )
    }

    func testModelStageOutranksEmbedding() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .embedding, reason: "x"))
        model.apply(.stageUnavailable(stage: .router, reason: "x"))
        XCTAssertEqual(model.activeMessage, "Coach paused — model unavailable. Check Settings → Models.")
    }

    func testDismissHidesUntilSituationChanges() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .classifier, reason: "x"))
        model.dismissCurrent()
        XCTAssertNil(model.activeMessage, "dismissed")
        // Same failing set → stays dismissed (no banner per utterance).
        model.apply(.stageUnavailable(stage: .classifier, reason: "again"))
        XCTAssertNil(model.activeMessage, "unchanged situation must not re-raise a dismissed banner")
        // A NEW failing stage is new information → banner returns.
        model.apply(.stageUnavailable(stage: .embedding, reason: "x"))
        XCTAssertNotNil(model.activeMessage, "a new failing stage must re-raise the banner")
    }

    func testRecoveryClearsBannerAndDismissal() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .classifier, reason: "x"))
        model.dismissCurrent()
        model.apply(.stageRecovered(stage: .classifier))
        XCTAssertNil(model.activeMessage)
        // A fresh outage after full recovery shows again despite the old dismissal.
        model.apply(.stageUnavailable(stage: .classifier, reason: "x"))
        XCTAssertNotNil(model.activeMessage)
    }

    func testSkippedCueMessagesSingularAndPlural() {
        var model = CoachHealthBannerModel()
        XCTAssertNil(model.skippedCueMessage)
        model.apply(.cueSkipped(totalSkippedThisMeeting: 1))
        XCTAssertEqual(model.skippedCueMessage, "1 cue skipped under load")
        model.apply(.cueSkipped(totalSkippedThisMeeting: 3))
        XCTAssertEqual(model.skippedCueMessage, "3 cues skipped under load")
    }

    func testResetForNewMeetingClearsEverything() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .router, reason: "x"))
        model.apply(.cueSkipped(totalSkippedThisMeeting: 4))
        model.dismissCurrent()
        model.resetForNewMeeting()
        XCTAssertNil(model.activeMessage)
        XCTAssertNil(model.skippedCueMessage)
        XCTAssertEqual(model.skippedCueCount, 0)
        XCTAssertTrue(model.failingStages.isEmpty)
    }
}

// MARK: - Dismiss-for-meeting state

final class CoachOverlayDismissStateTests: XCTestCase {
    func testDefaultsToAcceptingCards() {
        XCTAssertTrue(CoachOverlayDismissState().acceptsCards)
        XCTAssertFalse(CoachOverlayDismissState().isDismissedForMeeting)
    }

    func testDismissForMeetingStopsAcceptingCards() {
        var state = CoachOverlayDismissState()
        state.dismissForMeeting()
        XCTAssertTrue(state.isDismissedForMeeting)
        XCTAssertFalse(state.acceptsCards, "dismissed means hidden for the meeting — no cards pop")
    }

    func testReopenRestoresAcceptance() {
        var state = CoachOverlayDismissState()
        state.dismissForMeeting()
        state.reopen()
        XCTAssertTrue(state.acceptsCards)
        XCTAssertFalse(state.isDismissedForMeeting)
    }
}

// MARK: - RecentTrigger label hygiene

final class RecentTriggerLabelTests: XCTestCase {
    func testNormalTitlePreserved() {
        let trigger = RecentTrigger(label: "Pricing question", mode: .general, wasSurfaced: true)
        XCTAssertEqual(trigger.label, "Pricing question")
    }

    func testEmptyTitleClampsToModeName() {
        XCTAssertEqual(
            RecentTrigger(label: "", mode: .general, wasSurfaced: true).label, "General cue")
        XCTAssertEqual(
            RecentTrigger(label: "", mode: .grounded, wasSurfaced: true).label, "Grounded cue")
    }

    func testSynthesizedFallbackUsesBritishSpelling() {
        XCTAssertEqual(
            RecentTrigger(label: "   ", mode: .synthesized, wasSurfaced: false).label,
            "Synthesised cue")
    }

    func testWhitespaceAndPunctuationOnlyTitleClampsToModeName() {
        XCTAssertEqual(
            RecentTrigger(label: " \n\t …—-· ", mode: .reframe, wasSurfaced: false).label,
            "Reframe cue")
    }

    func testNewlinesCollapseToSingleSpaces() {
        let trigger = RecentTrigger(
            label: "What they\nasked   about\tpricing", mode: .general, wasSurfaced: true)
        XCTAssertEqual(trigger.label, "What they asked about pricing")
    }

    func testControlCharactersStripped() {
        let trigger = RecentTrigger(
            label: "Bad\u{0007}model\u{0000}output", mode: .general, wasSurfaced: true)
        XCTAssertEqual(trigger.label, "Badmodeloutput")
    }

    func testOverlongTitleTruncatesWithEllipsis() {
        let long = String(repeating: "word ", count: 40)  // 200 chars
        let trigger = RecentTrigger(label: long, mode: .general, wasSurfaced: true)
        XCTAssertLessThanOrEqual(trigger.label.count, 80)
        XCTAssertTrue(trigger.label.hasSuffix("…"))
    }
}
